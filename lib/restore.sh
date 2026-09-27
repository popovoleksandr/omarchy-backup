# omarchy-backup restore: puts a backup back, step by step.
# shellcheck shell=bash

# Steps in the order they run. Later steps rely on earlier ones: services
# and the theme need their packages and files first.
STEP_KEYS=(packages aur flatpak repos files tools claude apps etc look system prune)
# Steps that change nothing outside the home folder unless asked for.
STEP_OPT_IN=(etc prune)
FLATHUB_URL=https://dl.flathub.org/repo/flathub.flatpakrepo
AUR_RPC=https://aur.archlinux.org/rpc/v5/info

m() { jq -r "$@" "$WORK/manifest.json"; }

# ------------------------------------------------------------ choosing a file

# Backups in the usual places, newest first.
find_backups() {
  local file
  {
    for file in "$BACKUP_DIR"/*.tar.zst "$HOME"/Downloads/omarchy-backup-*.tar.zst "$HOME"/omarchy-backup-*.tar.zst \
      /run/media/"$USER"/*/omarchy-backup-*.tar.zst /run/media/"$USER"/*/*/omarchy-backup-*.tar.zst \
      /mnt/*/omarchy-backup-*.tar.zst; do
      [[ -f $file ]] && printf '%s %s\n' "$(stat -c %Y "$file")" "$(realpath "$file")"
    done
  } | sort -rn | awk '!seen[$2]++ { sub(/^[0-9]+ /, ""); print }'
}

pick_backup() {
  local file label choice start browse="Browse for another file..."
  local -A by_label=()
  local labels=()
  interactive || die "which backup? run: $CMD restore <file>"
  command -v gum >/dev/null || die "which backup? run: $CMD restore <file>"
  while IFS= read -r file; do
    label="$(date -d "@$(stat -c %Y "$file")" '+%Y-%m-%d %H:%M')  $(human_size "$(stat -c %s "$file")")  $(tilde "$file")"
    by_label[$label]=$file
    labels+=("$label")
  done < <(find_backups)
  labels+=("$browse")
  choice=$(gum choose --header "Restore which backup?" "${labels[@]}") || exit 130
  if [[ $choice == "$browse" ]]; then
    start=$HOME
    [[ -d /run/media/$USER ]] && start=/run/media/$USER
    choice=$(gum file --file "$start") || exit 130
    printf '%s\n' "$choice"
  else
    printf '%s\n' "${by_label[$choice]}"
  fi
}

# --------------------------------------------------------------- undo files

# Everything a restore replaces or deletes is copied here first, then packed
# into an undo backup that restores like any other.
save_existing_home() {
  local rel=$1 dest=$HOME/$1
  [[ -e $dest || -L $dest ]] || return 0
  [[ -e $UNDO/home/$rel || -L $UNDO/home/$rel ]] && return 0
  mkdir -p "$UNDO/home/$(dirname "$rel")"
  cp -a "$dest" "$UNDO/home/$rel"
}

save_existing_etc() {
  local path=$1
  sudo test -e "$path" || sudo test -L "$path" || return 0
  mkdir -p "$UNDO/system$(dirname "$path")"
  if sudo test -L "$path"; then
    ln -sfn "$(sudo readlink "$path")" "$UNDO/system$path"
  else
    sudo cat "$path" >"$UNDO/system$path"
    chmod "$(sudo stat -c %a "$path")" "$UNDO/system$path"
  fi
}

write_undo() {
  local out
  $DRY_RUN && return 0
  [[ -n $(find "$UNDO" \( -type f -o -type l \) -print -quit 2>/dev/null) ]] || return 0
  mkdir -p "$STATE_DIR"
  umask 077
  out="$STATE_DIR/undo-$(date +%Y-%m-%d-%H%M%S).tar.zst"
  (cd "$UNDO" && find home \( -type f -o -type l \) -printf '%P\n' 2>/dev/null) >"$WORK/undo-home.txt" || true
  (cd "$UNDO" && find system \( -type f -o -type l \) -printf '/%P\n' 2>/dev/null) >"$WORK/undo-etc.txt" || true
  jq -n --arg format "$FORMAT" --argjson format_version "$FORMAT_VERSION" --arg tool_version "$VERSION" \
    --arg created "$(date --iso-8601=seconds)" --arg host "$(uname -n)" --arg user "$(id -un)" --arg home "$HOME" \
    --slurpfile home_files <(jq -Rn '[inputs | select(length > 0) | {status: "undo", path: .}]' <"$WORK/undo-home.txt") \
    --slurpfile etc <(jq -Rn '[inputs | select(length > 0)]' <"$WORK/undo-etc.txt") \
    '{format: $format, format_version: $format_version, kind: "undo", tool_version: $tool_version,
      created: $created, host: $host, user: $user, home: $home, omarchy: {}, packages: {}, services: {}, system: {},
      files: {home: $home_files[0], removed: [], etc: $etc[0]}, repos: []}' >"$UNDO/manifest.json"
  (cd "$UNDO" && tar --create --file=- --format=gnu manifest.json $([[ -d home ]] && echo home) $([[ -d system ]] && echo system)) |
    zstd -q -T0 -o "$out"
  chmod 600 "$out"
  UNDO_FILE=$out
}

# ---------------------------------------------------------------- packages

load_package_sets() {
  local name
  declare -gA INSTALLED=() SYNC=()
  while read -r name; do INSTALLED[$name]=1; done < <(pacman -Qq)
  while read -r name; do SYNC[$name]=1; done < <(pacman -Slq 2>/dev/null)
}

plan_packages() {
  local name
  PKG_INSTALL=()
  PKG_UNAVAILABLE=()
  while read -r name; do
    [[ -z $name || -n ${INSTALLED[$name]:-} ]] && continue
    if [[ -n ${SYNC[$name]:-} ]]; then
      PKG_INSTALL+=("$name")
    else
      PKG_UNAVAILABLE+=("$name")
    fi
  done < <(m '.packages.repo[]?')
}

# Lets the user drop packages that don't fit this machine (another GPU's
# drivers, say) before anything is installed.
review_packages() {
  local picked
  ((${#PKG_INSTALL[@]} > 0)) || return 0
  interactive && ! $ASSUME_YES && command -v gum >/dev/null || return 0
  confirm "Review the $(count ${#PKG_INSTALL[@]} package) to install first?" false || return 0
  picked=$(gum choose --no-limit --selected='*' --height=20 \
    --header "Packages to install (space toggles, enter confirms)" "${PKG_INSTALL[@]}") || exit 130
  mapfile -t PKG_INSTALL < <(printf '%s\n' "$picked" | sed '/^$/d')
}

# Installs packages with pacman, one at a time if the batch fails, so one
# conflict doesn't stop the rest.
pacman_install() {
  local name
  (($# > 0)) || return 0
  run sudo pacman -S --needed --noconfirm "$@" && return 0
  warn "installing them together failed; trying one at a time"
  for name in "$@"; do
    run sudo pacman -S --needed --noconfirm "$name" || problem "couldn't install $name"
  done
}

do_packages() {
  if ((${#PKG_INSTALL[@]} == 0)); then
    ok "all $(m '.packages.repo | length') packages are installed"
  else
    info "Installing $(count ${#PKG_INSTALL[@]} package): ${PKG_INSTALL[*]}"
    pacman_install "${PKG_INSTALL[@]}"
  fi
  if ((${#PKG_UNAVAILABLE[@]} > 0)); then
    problem "not in the package repos, so not installed: ${PKG_UNAVAILABLE[*]}"
  fi
  return 0
}

# Names from the list that the AUR knows.
aur_known() {
  local args=() name
  for name in "$@"; do args+=(--data-urlencode "arg[]=$name"); done
  curl -fsS --max-time 30 -G "$AUR_RPC" "${args[@]}" | jq -r '.results[].Name'
}

do_aur() {
  local name wanted=() from_repo=() known=() unknown=() found
  load_package_sets
  while read -r name; do
    [[ -z $name || -n ${INSTALLED[$name]:-} ]] && continue
    # Some AUR packages move to the official repos.
    if [[ -n ${SYNC[$name]:-} ]]; then from_repo+=("$name"); else wanted+=("$name"); fi
  done < <(m '.packages.aur[]?')

  if ((${#from_repo[@]} + ${#wanted[@]} == 0)); then
    ok "all $(m '.packages.aur | length') AUR packages are installed"
    return 0
  fi
  if ((${#from_repo[@]} > 0)); then
    info "Installing from the repos now: ${from_repo[*]}"
    pacman_install "${from_repo[@]}"
  fi
  ((${#wanted[@]} > 0)) || return 0
  if ! command -v yay >/dev/null; then
    problem "yay is missing, so these AUR packages weren't installed: ${wanted[*]}"
    return 0
  fi

  if found=$(aur_known "${wanted[@]}"); then
    for name in "${wanted[@]}"; do
      if grep -qxF -- "$name" <<<"$found"; then known+=("$name"); else unknown+=("$name"); fi
    done
  else
    warn "couldn't reach the AUR to check the names; trying them all"
    known=("${wanted[@]}")
  fi
  if ((${#unknown[@]} > 0)); then
    problem "not on the AUR (installed from a file or another repo?), install them yourself: ${unknown[*]}"
  fi
  ((${#known[@]} > 0)) || return 0

  info "Installing $(count ${#known[@]} "AUR package"): ${known[*]}"
  run yay -S --needed --noconfirm "${known[@]}" && return 0
  warn "installing them together failed; trying one at a time"
  for name in "${known[@]}"; do
    run yay -S --needed --noconfirm "$name" || problem "couldn't install $name from the AUR"
  done
}

do_flatpak() {
  local id origin installation scope sudo_cmd missing=0
  if ! command -v flatpak >/dev/null; then
    pacman_install flatpak
    $DRY_RUN || command -v flatpak >/dev/null || { problem "flatpak isn't installed; skipped the Flatpak apps"; return 0; }
  fi
  while IFS=$'\t' read -r id origin installation; do
    [[ -n $id ]] || continue
    if flatpak info "$id" >/dev/null 2>&1; then continue; fi
    missing=$((missing + 1))
    if [[ $installation == user ]]; then scope=--user sudo_cmd=(); else scope=--system sudo_cmd=(sudo); fi
    if [[ $origin == flathub ]]; then
      run "${sudo_cmd[@]}" flatpak remote-add "$scope" --if-not-exists flathub "$FLATHUB_URL" ||
        problem "couldn't add the Flathub remote"
    fi
    info "Installing $id from $origin"
    run "${sudo_cmd[@]}" flatpak install "$scope" -y --noninteractive "$origin" "$id" ||
      problem "couldn't install the Flatpak app $id"
  done < <(m '.packages.flatpak[]? | [.id, .origin, .installation] | @tsv')
  ((missing > 0)) || ok "all $(m '.packages.flatpak | length') Flatpak apps are installed"
}

# ------------------------------------------------------------------- files

# The backup's version of a symlink, pointed at this home folder if it pointed
# into the old one.
link_target() {
  local target
  target=$(readlink "$1")
  if [[ -n $OLD_HOME && ($target == "$OLD_HOME" || $target == "$OLD_HOME"/*) ]]; then
    target=$HOME${target#"$OLD_HOME"}
  fi
  printf '%s\n' "$target"
}

# True if ~/<rel> already matches the backup.
home_file_current() {
  local rel=$1 src=$WORK/home/$1 dest=$HOME/$1
  if [[ -L $src ]]; then
    [[ -L $dest && $(readlink "$dest") == "$(link_target "$src")" ]]
  else
    [[ -f $dest && ! -L $dest ]] && cmp -s "$src" "$dest"
  fi
}

install_home_file() {
  local rel=$1 src=$WORK/home/$1 dest=$HOME/$1 verb=update
  safe_rel "$rel" || { problem "skipped a file with an unsafe path in the backup: $rel"; return 0; }
  [[ -e $src || -L $src ]] || return 0
  home_file_current "$rel" && return 0
  if [[ -d $dest && ! -L $dest ]]; then
    problem "~/$rel is a folder here, so the file from the backup wasn't put there"
    return 0
  fi
  [[ -e $dest || -L $dest ]] || verb=add
  if $DRY_RUN; then
    info "would $verb ~/$rel"
    FILES_CHANGED=$((FILES_CHANGED + 1))
    return 0
  fi
  save_existing_home "$rel"
  if ! mkdir -p "$(dirname "$dest")" 2>/dev/null; then
    problem "couldn't create the folder for ~/$rel"
    return 0
  fi
  rm -f "$dest"
  if [[ -L $src ]]; then
    ln -s "$(link_target "$src")" "$dest"
  else
    cp -p "$src" "$dest"
  fi
  FILES_CHANGED=$((FILES_CHANGED + 1))
}

in_backup_repo() {
  local rel=$1 repo
  for repo in "${REPO_PATHS[@]}"; do
    [[ $rel == "$repo" || $rel == "$repo"/* ]] && return 0
  done
  return 1
}

do_files() {
  local rel dest
  FILES_CHANGED=0
  [[ -d $WORK/home ]] || { ok "no files in the backup"; return 0; }
  while IFS= read -r -d '' rel; do
    in_backup_repo "$rel" && continue
    install_home_file "$rel"
  done < <(cd "$WORK/home" && find . \( -type f -o -type l \) -printf '%P\0' | sort -z)

  # Defaults that were deleted before the backup, if they're still untouched here.
  while IFS= read -r rel; do
    safe_rel "$rel" || continue
    dest=$HOME/$rel
    [[ -e $dest || -L $dest ]] || continue
    if ! same_file "$dest" "$SKEL_DIR/$rel"; then
      info "kept ~/$rel: it was removed before the backup but has been changed here"
      continue
    fi
    if $DRY_RUN; then
      info "would remove ~/$rel"
      FILES_CHANGED=$((FILES_CHANGED + 1))
      continue
    fi
    save_existing_home "$rel"
    rm -f "$dest"
    FILES_CHANGED=$((FILES_CHANGED + 1))
  done < <(m '.files.removed[]?')

  if ((FILES_CHANGED == 0)); then
    ok "all files already match the backup"
    return 0
  fi
  $DRY_RUN && return 0
  ok "restored $(count $FILES_CHANGED file)"
  refresh_desktop
}

# Lets the running session notice restored launchers, icons, fonts, units and configs.
refresh_desktop() {
  update-desktop-database -q "$HOME/.local/share/applications" >/dev/null 2>&1 || true
  [[ -d $HOME/.local/share/icons/hicolor ]] && gtk-update-icon-cache -q -t -f "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1
  [[ -d $HOME/.local/share/fonts ]] && fc-cache -f >/dev/null 2>&1
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then hyprctl reload >/dev/null 2>&1 || true; fi
  omarchy-menu refresh >/dev/null 2>&1 || true
}

do_repos() {
  local repo path url commit branch dest file plugins_added=false
  while IFS= read -r repo; do
    path=$(jq -r .path <<<"$repo")
    url=$(jq -r .url <<<"$repo")
    commit=$(jq -r '.commit // ""' <<<"$repo")
    branch=$(jq -r '.branch // ""' <<<"$repo")
    if ! safe_rel "$path"; then
      problem "skipped a git repo with an unsafe path in the backup: \"$path\""
      continue
    fi
    dest=$HOME/$path
    if [[ -e $dest/.git ]] && [[ $(git -C "$dest" remote get-url origin 2>/dev/null) == "$url" ]]; then
      ok "~/$path is already cloned"
    else
      if command -v omarchy-git-url-check >/dev/null && ! omarchy-git-url-check "$url" >/dev/null 2>&1; then
        problem "refused to clone ~/$path from \"$url\""
        continue
      fi
      info "Cloning $url into ~/$path"
      if $DRY_RUN; then
        info "would clone it at ${commit:0:12}"
      else
        if [[ -e $dest || -L $dest ]]; then
          save_existing_home "$path"
          rm -rf "$dest"
        fi
        mkdir -p "$(dirname "$dest")"
        if ! GIT_TERMINAL_PROMPT=0 git clone --quiet -- "$url" "$dest"; then
          problem "couldn't clone $url into ~/$path"
          continue
        fi
        if [[ -n $commit ]]; then
          if [[ -n $branch ]]; then
            git -C "$dest" checkout --quiet -B "$branch" "$commit" 2>/dev/null
          else
            git -C "$dest" checkout --quiet "$commit" 2>/dev/null
          fi || warn "commit ${commit:0:12} isn't in $url any more; ~/$path has the latest version"
        fi
      fi
      if [[ $path == .config/omarchy/plugins/* ]]; then
        plugins_added=true
        if ! $DRY_RUN && command -v omarchy-plugin-validate >/dev/null && ! omarchy-plugin-validate "$dest" >/dev/null 2>&1; then
          problem "Omarchy says the plugin in ~/$path isn't valid for this version; check it with: omarchy plugin validate ~/$path"
        fi
      fi
    fi
    # Files that were changed or added in the clone before the backup.
    while IFS= read -r file; do
      [[ -n $file ]] && install_home_file "$path/$file"
    done < <(jq -r '.changed[]?' <<<"$repo")
  done < <(m -c '.repos[]?')
  # Like `omarchy plugin add`: let the running shell find new plugins. Whether
  # each one is on comes from ~/.config/omarchy/shell.json, which the files step restores.
  if $plugins_added && [[ -n ${WAYLAND_DISPLAY:-} ]] && command -v omarchy-shell >/dev/null; then
    run omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  fi
  return 0
}

# Tools from the backup's ~/.config/mise/config.toml, such as claude, codex,
# gh and node. Omarchy's launchers in ~/.local/bin would install them on first
# use; this installs them now.
mise_tools() {
  local config=$WORK/home/.config/mise/config.toml
  [[ -f $config ]] || return 0
  awk '/^[[:space:]]*\[/ { tools = ($0 ~ /^[[:space:]]*\[tools\][[:space:]]*$/); next }
    tools && /=/ { sub(/[[:space:]]*=.*/, ""); gsub(/["[:space:]]/, ""); print }' "$config"
}

do_tools() {
  if ! command -v mise >/dev/null; then
    pacman_install mise
    $DRY_RUN || command -v mise >/dev/null || { problem "mise isn't installed; skipped: $(mise_tools | paste -sd' ')"; return 0; }
  fi
  info "Installing with mise: $(mise_tools | paste -sd' ')"
  run env MISE_MINIMUM_RELEASE_AGE=0 mise --cd "$HOME" install --yes ||
    problem "mise couldn't install every tool; see what's missing with: mise ls --missing"
}

# Claude Code plugins. The backup's plugin list points at plugin files that a
# new machine doesn't have (Claude then says "failed to load"), so each
# marketplace is added and each plugin installed again. Both are no-ops when
# already done.
claude_marketplaces() {
  local list=$WORK/home/.claude/plugins/known_marketplaces.json
  [[ -f $list ]] || return 0
  jq -r 'to_entries[] | [.key, (.value.source | .repo // .url // .path // "")] | @tsv' "$list" 2>/dev/null
}

claude_plugins() {
  local list=$WORK/home/.claude/plugins/installed_plugins.json
  [[ -f $list ]] || return 0
  jq -r '.plugins // {} | to_entries[] | select(any(.value[]?; .scope == "user")) | .key' "$list" 2>/dev/null
}

do_claude() {
  local name source plugin
  if ! $DRY_RUN && ! command -v claude >/dev/null; then
    problem "Claude Code isn't installed, so its plugins weren't: $(claude_plugins | paste -sd' ')"
    return 0
  fi
  while IFS=$'\t' read -r name source; do
    [[ -n $name ]] || continue
    if [[ -z $source ]]; then
      problem "the backup doesn't say where the Claude marketplace $name comes from; add it with: claude plugin marketplace add <source>"
      continue
    fi
    info "Adding the Claude marketplace $name ($source)"
    run claude plugin marketplace add "$source" || problem "couldn't add the Claude marketplace $name ($source)"
  done < <(claude_marketplaces)
  while IFS= read -r plugin; do
    [[ -n $plugin ]] || continue
    info "Installing the Claude plugin $plugin"
    run claude plugin install "$plugin" || problem "couldn't install the Claude plugin $plugin; try: claude plugin install $plugin"
  done < <(claude_plugins)
}

# Editor extensions by name, and GNOME/GTK app settings with `dconf load`,
# which only sets the keys in the backup and leaves the others alone.
do_apps() {
  local editor cli ext installed missing args
  if [[ -f $WORK/dconf.ini ]]; then
    if ! command -v dconf >/dev/null; then
      problem "dconf isn't installed, so the GNOME/GTK app settings weren't loaded"
    elif $DRY_RUN; then
      info "would load $(grep -c '^\[' "$WORK/dconf.ini") sections of GNOME/GTK app settings with dconf load"
    else
      info "Loading GNOME/GTK app settings (dconf)"
      dconf load / <"$WORK/dconf.ini" || problem "couldn't load the GNOME/GTK app settings"
    fi
  fi
  while IFS= read -r editor; do
    cli=$(jq -r .cli <<<"$editor")
    if ! command -v "$cli" >/dev/null; then
      problem "$cli isn't installed, so its extensions weren't: $(jq -r '[.extensions[] | sub("@.*$"; "")] | join(" ")' <<<"$editor")"
      continue
    fi
    installed=$("$cli" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]') || installed=
    missing=()
    while IFS= read -r ext; do
      grep -qxF -- "${ext,,}" <<<"$installed" || missing+=("$ext")
    done < <(jq -r '.extensions[] | sub("@.*$"; "")' <<<"$editor")
    if ((${#missing[@]} == 0)); then
      ok "all $(jq -r '.extensions | length' <<<"$editor") $cli extensions are installed"
      continue
    fi
    info "Installing $(count ${#missing[@]} "$cli extension"): ${missing[*]}"
    args=()
    for ext in "${missing[@]}"; do args+=(--install-extension "$ext"); done
    run "$cli" "${args[@]}" || true
    $DRY_RUN && continue
    installed=$("$cli" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]') || installed=
    args=()
    for ext in "${missing[@]}"; do
      grep -qxF -- "${ext,,}" <<<"$installed" || args+=("$ext")
    done
    ((${#args[@]} == 0)) || problem "couldn't install these $cli extensions (not in its marketplace?): ${args[*]}"
  done < <(m -c '.apps.editors[]?')
}

# System files go to /etc owned by root, with the mode they had.
do_etc() {
  local rel src dest changed=0 udev=false sysctl=false
  [[ -d $WORK/system/etc ]] || { ok "no /etc files in the backup"; return 0; }
  while IFS= read -r -d '' rel; do
    src=$WORK/system/$rel
    dest=/$rel
    if [[ -L $src ]]; then
      [[ -L $dest && $(readlink "$dest") == "$(readlink "$src")" ]] && continue
    elif [[ -r $dest ]] && cmp -s "$src" "$dest"; then
      continue
    fi
    info "$([[ -e $dest ]] && echo Updating || echo Adding) $dest"
    changed=$((changed + 1))
    [[ $rel == etc/udev/* ]] && udev=true
    [[ $rel == etc/sysctl.d/* ]] && sysctl=true
    $DRY_RUN || save_existing_etc "$dest"
    if [[ -L $src ]]; then
      run sudo mkdir -p "$(dirname "$dest")"
      run sudo ln -sfn "$(readlink "$src")" "$dest" || problem "couldn't write $dest"
    else
      run sudo install -D -m "$(stat -c %a "$src")" -o root -g root "$src" "$dest" || problem "couldn't write $dest"
    fi
  done < <(cd "$WORK/system" && find etc \( -type f -o -type l \) -print0 | sort -z)
  if ((changed == 0)); then
    ok "all /etc files already match the backup"
    return 0
  fi
  run sudo systemctl daemon-reload || true
  if $udev; then run sudo udevadm control --reload || true; fi
  if $sysctl; then run sudo sysctl --quiet --system || true; fi
  NEEDS_REBOOT=true
}

theme_installed() {
  [[ -d $OMARCHY_PATH/themes/$1 || -d $HOME/.config/omarchy/themes/$1 ]]
}

do_look() {
  local theme background font current_theme current_background did=false
  theme=$(m '.omarchy.theme // ""')
  background=$(untilde "$(m '.omarchy.background // ""')")
  font=$(m '.omarchy.font // ""')
  current_theme=$(cat "$OMARCHY_STATE/current/theme.name" 2>/dev/null) || current_theme=
  # Without a running session, set the theme's files only.
  [[ -n ${WAYLAND_DISPLAY:-} ]] || export OMARCHY_THEME_HEADLESS=1

  if [[ -n $theme && $theme != "$current_theme" ]]; then
    if theme_installed "$theme"; then
      info "Setting the theme to $theme"
      run omarchy-theme-set "$theme" || problem "couldn't set the theme $theme"
      did=true
    else
      problem "the theme $theme isn't installed; install it and pick it in Style > Theme"
    fi
  fi

  current_background=$(readlink "$OMARCHY_STATE/current/background" 2>/dev/null) || current_background=
  if [[ -n $background && $background != "$current_background" ]]; then
    if [[ -f $background ]]; then
      info "Setting the background to $(tilde "$background")"
      if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
        run omarchy-theme-bg-set "$background" || problem "couldn't set the background"
      else
        run ln -nsf "$background" "$OMARCHY_STATE/current/background"
      fi
      did=true
    else
      problem "the background $(tilde "$background") isn't on this machine"
    fi
  fi

  if [[ -n $font && $font != "$(omarchy-font-current 2>/dev/null)" ]]; then
    if fc-list | grep -Fqi -- "$font"; then
      info "Setting the font to $font"
      run omarchy-font-set "$font" || problem "couldn't set the font $font"
      did=true
    else
      problem "the font $font isn't installed; install it and pick it in Style > Font"
    fi
  fi
  $did || ok "the theme, background and font already match"
}

do_system() {
  local unit state group enable_system=() enable_user=() add_groups=() timezone missing=0
  local -A system_state=() user_state=()
  while read -r unit state _; do system_state[$unit]=$state; done < <(systemctl list-unit-files --no-legend --no-pager 2>/dev/null)
  while read -r unit state _; do user_state[$unit]=$state; done < <(systemctl --user list-unit-files --no-legend --no-pager 2>/dev/null)

  while read -r unit; do
    [[ -n $unit ]] || continue
    state=${system_state[$unit]:-}
    if [[ -z $state ]]; then missing=$((missing + 1)); continue; fi
    [[ $state == enabled || $state == static || $state == alias || $state == generated ]] || enable_system+=("$unit")
  done < <(m '.services.system[]?')
  while read -r unit; do
    [[ -n $unit ]] || continue
    state=${user_state[$unit]:-}
    if [[ -z $state ]]; then missing=$((missing + 1)); continue; fi
    [[ $state == enabled || $state == static || $state == alias || $state == generated ]] || enable_user+=("$unit")
  done < <(m '.services.user[]?')

  if ((${#enable_system[@]} > 0)); then
    info "Enabling system services: ${enable_system[*]}"
    run sudo systemctl enable "${enable_system[@]}" || problem "couldn't enable all of: ${enable_system[*]}"
    NEEDS_REBOOT=true
  fi
  if ((${#enable_user[@]} > 0)); then
    info "Enabling user services: ${enable_user[*]}"
    run systemctl --user enable "${enable_user[@]}" || problem "couldn't enable all of: ${enable_user[*]}"
  fi
  ((missing == 0)) || info "$(count $missing "enabled service") from the backup $( ((missing == 1)) && echo "isn't" || echo "aren't") installed here (not restored with the packages)"

  while read -r group; do
    [[ -n $group ]] || continue
    getent group "$group" >/dev/null || continue
    id -nG | tr ' ' '\n' | grep -qxF -- "$group" || add_groups+=("$group")
  done < <(m '.system.groups[]?')
  if ((${#add_groups[@]} > 0)); then
    info "Adding $(id -un) to the groups: ${add_groups[*]}"
    run sudo usermod -aG "$(IFS=,; echo "${add_groups[*]}")" "$(id -un)" || problem "couldn't add you to: ${add_groups[*]}"
    NEEDS_REBOOT=true
  fi

  timezone=$(m '.system.timezone // ""')
  if [[ -n $timezone && $timezone != "$(timedatectl show -p Timezone --value 2>/dev/null)" ]]; then
    info "Setting the timezone to $timezone"
    run sudo timedatectl set-timezone "$timezone" || problem "couldn't set the timezone $timezone"
  fi

  if ((${#enable_system[@]} + ${#enable_user[@]} + ${#add_groups[@]} == 0)) && [[ -z $timezone || $timezone == "$(timedatectl show -p Timezone --value 2>/dev/null)" ]]; then
    ok "services, groups and timezone already match"
  fi
}

do_prune() {
  local name remove=()
  load_package_sets
  while read -r name; do
    [[ -n $name && -n ${INSTALLED[$name]:-} ]] && remove+=("$name")
  done < <(m '.packages.removed_defaults[]?')
  if ((${#remove[@]} == 0)); then
    ok "none of them are installed"
    return 0
  fi
  info "Removing: ${remove[*]}"
  run sudo pacman -Rns --noconfirm "${remove[@]}" && return 0
  warn "removing them together failed; trying one at a time"
  for name in "${remove[@]}"; do
    run sudo pacman -Rns --noconfirm "$name" || problem "couldn't remove $name (something else needs it)"
  done
}

# ----------------------------------------------------------------- the flow

step_label() {
  local n
  case $1 in
  packages) echo "Packages from the Arch and Omarchy repos ($(m '.packages.repo | length'))" ;;
  aur) echo "AUR packages ($(m '.packages.aur | length'))" ;;
  flatpak) echo "Flatpak apps ($(m '.packages.flatpak | length'))" ;;
  repos) echo "Themes and plugins from git ($(m '[.repos[]?.path | split("/") | last] | join(" ")'))" ;;
  files)
    n=$(m '.files.removed | length')
    echo "Config files ($(m '.files.home | length') files$( ((n > 0)) && echo " + $n removed launchers"))"
    ;;
  tools) echo "Tools from mise ($(mise_tools | paste -sd' '))" ;;
  claude) echo "Claude Code plugins ($(claude_plugins | sed 's/@.*//' | paste -sd' '))" ;;
  apps) echo "Editor extensions + GNOME/GTK app settings ($(m '[(.apps.editors // [])[] | "\(.extensions | length) \(.cli)"] + (if .apps.dconf then ["dconf"] else [] end) | join(" + ")'))" ;;
  etc) echo "System files in /etc ($(m '.files.etc | length') files; needs sudo)" ;;
  look) echo "Theme $(m '.omarchy.theme // "-"') + background + font" ;;
  system) echo "Enabled services + groups + timezone" ;;
  prune) echo "Uninstall Omarchy defaults you had removed ($(m '.packages.removed_defaults | join(" ")'))" ;;
  esac
}

step_has_content() {
  case $1 in
  packages) (($(m '.packages.repo // [] | length') > 0)) ;;
  aur) (($(m '.packages.aur // [] | length') > 0)) ;;
  flatpak) (($(m '.packages.flatpak // [] | length') > 0)) ;;
  repos) (($(m '.repos // [] | length') > 0)) ;;
  files) (($(m '(.files.home // []) + (.files.removed // []) | length') > 0)) ;;
  tools) [[ -n $(mise_tools) ]] ;;
  claude) [[ -n $(claude_plugins) ]] ;;
  apps) [[ -f $WORK/dconf.ini ]] || (($(m '.apps.editors // [] | length') > 0)) ;;
  etc) (($(m '.files.etc // [] | length') > 0)) ;;
  look) [[ -n $(m '(.omarchy.theme // "") + (.omarchy.background // "") + (.omarchy.font // "")') ]] ;;
  system) (($(m '(.services.system // []) + (.services.user // []) + (.system.groups // []) | length') > 0)) || [[ -n $(m '.system.timezone // ""') ]] ;;
  prune) (($(m '.packages.removed_defaults // [] | length') > 0)) ;;
  esac
}

step_needs_sudo() {
  case $1 in
  packages) ((${#PKG_INSTALL[@]} > 0)) ;;
  files | repos | look | claude | apps) return 1 ;;
  tools) ! command -v mise >/dev/null ;;
  *) return 0 ;;
  esac
}

# Sets SELECTED from --only/--skip, or from a checklist in a terminal.
choose_steps() {
  local key label defaults=() labels=() picked
  local -A key_of=()
  SELECTED=()
  if [[ -n $ONLY ]]; then
    for key in ${ONLY//,/ }; do
      [[ " ${STEP_KEYS[*]} " == *" $key "* ]] || die "unknown step \"$key\"; steps: ${STEP_KEYS[*]}"
    done
  fi
  for key in ${SKIP//,/ }; do
    [[ " ${STEP_KEYS[*]} " == *" $key "* ]] || die "unknown step \"$key\"; steps: ${STEP_KEYS[*]}"
  done

  for key in "${STEP_KEYS[@]}"; do
    step_has_content "$key" || continue
    if [[ -n $ONLY ]]; then
      [[ ",$ONLY," == *",$key,"* ]] && SELECTED+=("$key")
      continue
    fi
    [[ ",$SKIP," == *",$key,"* ]] && continue
    label=$(step_label "$key")
    key_of[$label]=$key
    labels+=("$label")
    [[ " ${STEP_OPT_IN[*]} " == *" $key "* ]] || defaults+=("$label")
  done
  [[ -n $ONLY ]] && return 0

  if interactive && ! $ASSUME_YES && command -v gum >/dev/null; then
    picked=$(gum choose --no-limit --height=12 --header "Restore what? (space toggles, enter confirms)" \
      --selected="$(IFS=,; echo "${defaults[*]}")" "${labels[@]}") || exit 130
    while IFS= read -r label; do
      [[ -n $label ]] && SELECTED+=("${key_of[$label]}")
    done <<<"$picked"
  else
    for label in "${defaults[@]}"; do SELECTED+=("${key_of[$label]}"); done
  fi
}

selected() {
  [[ " ${SELECTED[*]} " == *" $1 "* ]]
}

cmd_restore() {
  local archive=$1 key kind fv title
  require_tools jq tar zstd
  [[ -n $archive ]] || archive=$(pick_backup)
  [[ -f $archive ]] || die "no such file: $archive"
  archive=$(realpath "$archive")
  read_manifest "$archive" | jq -e '.format == "omarchy-backup"' >/dev/null 2>&1 ||
    die "$(tilde "$archive") isn't an omarchy-backup file"

  mkdir -p "$CACHE_DIR"
  WORK=$(mktemp -d "$CACHE_DIR/restore.XXXXXX")
  UNDO=$WORK/undo
  mkdir -p "$UNDO"
  trap 'sudo_stop; rm -rf "$WORK"' EXIT
  tar --zstd -xpf "$archive" -C "$WORK" --no-same-owner || die "couldn't unpack $(tilde "$archive")"
  fv=$(m '.format_version')
  ((fv <= FORMAT_VERSION)) || die "this backup needs a newer omarchy-backup (format $fv); update it first"
  kind=$(m '.kind // "backup"')
  OLD_HOME=$(m '.home // ""')
  REPO_PATHS=()
  mapfile -t REPO_PATHS < <(m '.repos[]?.path')
  NEEDS_REBOOT=false
  FILES_CHANGED=0
  UNDO_FILE=

  title="Restoring $(tilde "$archive")"
  [[ $kind == undo ]] && title="Putting back the files replaced by a restore ($(tilde "$archive"))"
  step "$title"
  [[ $kind == undo ]] || summarize "$WORK/manifest.json"
  if [[ $kind != undo && $(m '.omarchy.channel // ""') != "" ]]; then
    local here
    here=$(omarchy-channel-current 2>/dev/null) || here=
    if [[ -n $here && $here != "$(m '.omarchy.channel')" ]]; then
      info "The backup comes from the $(m '.omarchy.channel') channel and this system is on $here;"
      info "switch with: omarchy channel set $(m '.omarchy.channel')"
    fi
  fi
  echo

  choose_steps
  ((${#SELECTED[@]} > 0)) || { info "Nothing selected; nothing changed."; return 0; }

  if selected packages; then
    load_package_sets
    plan_packages
    review_packages
  fi

  echo
  info "Steps: ${SELECTED[*]}$($DRY_RUN && echo " (dry run: nothing changes)")"
  if ! $DRY_RUN && ! confirm "Start the restore?" true; then
    info "Cancelled; nothing changed."
    return 0
  fi
  for key in "${SELECTED[@]}"; do
    if step_needs_sudo "$key"; then
      sudo_start
      break
    fi
  done

  for key in "${STEP_KEYS[@]}"; do
    selected "$key" || continue
    step "$(step_label "$key")"
    "do_$key"
  done
  sudo_stop
  write_undo

  step "$($DRY_RUN && echo "Dry run finished; nothing changed" || echo "Restore finished")"
  if ((${#PROBLEMS[@]} > 0)); then
    printf '    %sNeeds your attention:%s\n' "$YELLOW" "$RESET"
    printf '    - %s\n' "${PROBLEMS[@]}"
  fi
  if [[ -n $UNDO_FILE ]]; then
    info "Files it replaced or removed are saved in $(tilde "$UNDO_FILE")"
    info "Put them back with: $CMD restore $(tilde "$UNDO_FILE")"
  fi
  $DRY_RUN && return 0
  if $NEEDS_REBOOT; then
    info "Reboot so the services, groups and system files take effect."
  else
    info "Log out and back in so every app picks up the restored settings."
  fi
}
