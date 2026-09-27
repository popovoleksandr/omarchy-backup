# omarchy-backup create: saves the Omarchy setup into one .tar.zst file.
# shellcheck shell=bash
#
# The file holds manifest.json (packages, services, theme, the list of saved
# files, ...) followed by home/<path> for files from the home folder and
# system/etc/<path> for files from /etc.

# Only removed defaults in these folders are remembered: deleting a web app or
# an autostart entry is a choice, while a missing config file may just predate
# the Omarchy version that added it.
REMOVAL_ROOTS=(.local/share/applications .config/autostart)

# Omarchy's own packages follow the channel (stable/rc: omarchy, edge: omarchy-dev)
# and are always installed, so a restore leaves them alone.
CHANNEL_PACKAGES='omarchy(-settings)?(-dev)?'

# Paths under ~ whose files are compared with /etc/skel: everything Omarchy puts
# in a new home, then the includes from the paths files.
home_roots() {
  local entry
  for entry in "$SKEL_DIR"/.[!.]* "$SKEL_DIR"/*; do
    [[ -f $entry && ! -L $entry ]] && printf '%s\n' "${entry#"$SKEL_DIR"/}"
  done
  for entry in "$SKEL_DIR"/.config/.[!.]* "$SKEL_DIR"/.config/*; do
    [[ -e $entry || -L $entry ]] && printf '%s\n' "${entry#"$SKEL_DIR"/}"
  done
  [[ -d $SKEL_DIR/.local/share/applications ]] && echo .local/share/applications
  for entry in "${INCLUDES[@]}"; do
    [[ $entry == "$HOME"/* ]] && printf '%s\n' "${entry#"$HOME"/}"
  done
  return 0
}


# True if a path is inside a git repository that is saved by its URL.
in_repo() {
  local path=$1 repo
  for repo in "${REPO_DIRS[@]}"; do
    [[ $path == "$repo" || $path == "$repo"/* ]] && return 0
  done
  return 1
}

# Themes and plugins installed with `omarchy theme install` / `omarchy plugin add`
# are git clones. They are saved as URL + commit, plus any files changed or added
# locally, so a restore clones them again: Omarchy only trusts a theme without a
# .git folder to run code, so copying the files alone would change that.
find_repos() {
  local gitpath repo url
  while IFS= read -r -d '' gitpath; do
    repo=${gitpath%/.git}
    in_repo "$repo" && continue
    excluded "$repo" && continue
    url=$(git -C "$repo" remote get-url origin 2>/dev/null) || url=
    if [[ -z $url ]]; then
      warn "$(tilde "$repo") is a git repository without an origin remote; saving its files without the history"
      continue
    fi
    REPO_DIRS+=("$repo")
    save_repo "$repo" "$url"
  done < <(find "$1" \( -false "${PRUNE[@]}" \) -prune -o -name .git -print0 -prune 2>/dev/null | sort -z)
}

save_repo() {
  local repo=$1 url=$2 commit branch entry status path changed=()
  commit=$(git -C "$repo" rev-parse -q --verify HEAD 2>/dev/null) || commit=
  branch=$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null) || branch=
  while IFS= read -r -d '' entry; do
    status=${entry:0:2}
    path=${entry:3}
    # A rename is followed by its old name.
    [[ $status == R* || $status == C* ]] && IFS= read -r -d '' _
    [[ -f $repo/$path || -L $repo/$path ]] || continue
    excluded "$repo/$path" && continue
    changed+=("$path")
    printf '%s\0' "${repo#/}/$path" >>"$WORK/tar.list"
  done < <(git -C "$repo" status --porcelain=v1 -z --untracked-files=all 2>/dev/null)
  jq -nc --arg path "${repo#"$HOME"/}" --arg url "$url" --arg commit "$commit" --arg branch "$branch" \
    '{path: $path, url: $url, commit: $commit, branch: $branch, changed: $ARGS.positional}' \
    --args "${changed[@]}" >>"$WORK/repos.jsonl"
}

# With force (a file named on its own in an include), excludes don't apply.
consider_home_file() {
  local file=$1 force=${2:-false} rel status
  rel=${file#"$HOME"/}
  [[ -n ${SEEN[$rel]:-} ]] && return 0
  in_repo "$file" && return 0
  if ! $force && excluded "$file"; then return 0; fi
  if [[ $rel == *$'\n'* || $rel == *$'\t'* ]]; then
    warn "skipping $(tilde "$file"): its name has a tab or a line break"
    return 0
  fi
  if [[ -e $SKEL_DIR/$rel || -L $SKEL_DIR/$rel ]]; then
    if same_file "$file" "$SKEL_DIR/$rel"; then
      $FULL || return 0
      status=default
    else
      status=changed
    fi
  else
    status=added
  fi
  if [[ ! -L $file && ! -r $file ]]; then
    warn "can't read $(tilde "$file"); skipping it"
    return 0
  fi
  if [[ ! -L $file ]] && ((MAX_FILE_MB > 0)) && (($(stat -c %s "$file") > MAX_FILE_MB * 1024 * 1024)); then
    warn "skipping $(tilde "$file") ($(human_size "$(stat -c %s "$file")")): bigger than MAX_FILE_MB=$MAX_FILE_MB (set it in $(tilde "$USER_CONFIG_FILE"))"
    return 0
  fi
  SEEN[$rel]=1
  printf '%s\0' "${file#/}" >>"$WORK/tar.list"
  printf '%s\t%s\n' "$status" "$rel" >>"$WORK/home.tsv"
}

# Defaults in REMOVAL_ROOTS that were deleted from the home folder.
find_removed() {
  local root file rel
  for root in "${REMOVAL_ROOTS[@]}"; do
    [[ -d $SKEL_DIR/$root ]] || continue
    while IFS= read -r -d '' file; do
      rel=${file#"$SKEL_DIR"/}
      [[ -e $HOME/$rel || -L $HOME/$rel ]] && continue
      excluded "$HOME/$rel" && continue
      printf '%s\n' "$rel" >>"$WORK/removed.txt"
    done < <(find "$SKEL_DIR/$root" \( -type f -o -type l \) -print0 2>/dev/null)
  done
}

collect_home() {
  local root abs file
  while read -r root; do
    abs=$HOME/$root
    [[ -e $abs || -L $abs ]] || continue
    if [[ -d $abs && ! -L $abs ]]; then
      excluded "$abs" && continue
      find_repos "$abs"
      while IFS= read -r -d '' file; do
        consider_home_file "$file"
      done < <(find "$abs" \( -name .git "${PRUNE[@]}" \) -prune -o \( -type f -o -type l \) -print0 2>/dev/null)
    else
      consider_home_file "$abs" true
    fi
  done < <(home_roots | awk '!seen[$0]++')
  find_removed
}

add_etc_file() {
  local file=$1 unowned_only=$2
  [[ -n ${SEEN[$file]:-} ]] && return 0
  SEEN[$file]=1
  excluded "$file" && return 0
  # Package files come back with the package.
  if $unowned_only && pacman -Qqo "$file" >/dev/null 2>&1; then
    return 0
  fi
  if [[ ! -L $file && ! -r $file ]]; then
    warn "can't read $file without root; it isn't in the backup"
    return 0
  fi
  printf '%s\0' "${file#/}" >>"$WORK/tar.list"
  printf '%s\n' "$file" >>"$WORK/etc.txt"
}

# Unowned files in the /etc folders from the paths files. A single file named
# there is saved even when a package owns it.
collect_etc() {
  local include file
  for include in "${INCLUDES[@]}"; do
    if [[ $include != /etc/* ]]; then
      [[ $include == "$HOME"/* ]] || warn "ignoring \"include $include\": only paths in your home folder and /etc can be saved"
      continue
    fi
    if [[ -d $include && ! -L $include ]]; then
      while IFS= read -r -d '' file; do
        add_etc_file "$file" true
      done < <(find "$include" \( -type f -o -type l \) -print0 2>/dev/null | sort -z)
    elif [[ -e $include || -L $include ]]; then
      add_etc_file "$include" false
    fi
  done
}

collect_packages() {
  local base_list="$OMARCHY_PATH/install/omarchy-base.packages" base=()
  pacman -Qqen 2>/dev/null | grep -vxE "$CHANNEL_PACKAGES" >"$WORK/repo.txt" || true
  pacman -Qqem 2>/dev/null >"$WORK/aur.txt" || true
  # Packages every Omarchy install starts with that aren't here any more
  # (pacman -T also counts a package that provides the name).
  if [[ -f $base_list ]]; then
    mapfile -t base < <(grep -vE '^[[:space:]]*(#|$)' "$base_list" | awk '{print $1}')
    ((${#base[@]} == 0)) || pacman -T "${base[@]}" >"$WORK/removed-defaults.txt" 2>/dev/null || true
  fi
  if command -v flatpak >/dev/null; then
    flatpak list --app --columns=application,origin,installation 2>/dev/null >"$WORK/flatpak.tsv" || true
  fi
  systemctl list-unit-files --state=enabled --type=service,timer,socket,path --no-legend --no-pager 2>/dev/null |
    awk '$1 !~ /@\./ {print $1}' >"$WORK/services-system.txt" || true
  systemctl --user list-unit-files --state=enabled --type=service,timer,socket,path --no-legend --no-pager 2>/dev/null |
    awk '$1 !~ /@\./ {print $1}' >"$WORK/services-user.txt" || true
  id -nG | tr ' ' '\n' | grep -vx "$(id -un)" >"$WORK/groups.txt" || true
}

# Editors that share VS Code's extension CLI.
EDITOR_CLIS=(codium code code-insiders cursor windsurf)

# Extensions of VS Code-family editors (reinstalled by name on restore; their
# files are big and come from the marketplace), and the GNOME/GTK app settings
# kept in dconf's binary database, as text.
collect_apps() {
  local cli
  : >"$WORK/editors.jsonl"
  for cli in "${EDITOR_CLIS[@]}"; do
    command -v "$cli" >/dev/null || continue
    timeout 120 "$cli" --list-extensions --show-versions 2>/dev/null |
      jq -Rnc --arg cli "$cli" '{cli: $cli, extensions: [inputs | select(test("^[^ ]+\\.[^ ]+$"))]}' >>"$WORK/editors.jsonl" ||
      warn "couldn't list all $cli extensions"
  done
  if command -v dconf >/dev/null; then
    dconf dump / >"$WORK/dconf.ini" 2>/dev/null || true
  fi
  [[ -s $WORK/dconf.ini ]] || rm -f "$WORK/dconf.ini"
}

# JSON array of a file's non-empty lines.
json_lines() {
  [[ -f $1 ]] || { echo '[]'; return; }
  jq -Rn '[inputs | select(length > 0)]' <"$1"
}

write_manifest() {
  local theme background font version channel timezone
  theme=$(cat "$OMARCHY_STATE/current/theme.name" 2>/dev/null) || theme=
  background=$(readlink "$OMARCHY_STATE/current/background" 2>/dev/null) && background=$(tilde "$background") || background=
  font=$(omarchy-font-current 2>/dev/null) || font=
  version=$(omarchy-version 2>/dev/null) || version=
  channel=$(omarchy-channel-current 2>/dev/null) || channel=
  timezone=$(timedatectl show -p Timezone --value 2>/dev/null) || timezone=

  touch "$WORK/home.tsv" "$WORK/repos.jsonl" "$WORK/flatpak.tsv" "$WORK/editors.jsonl"
  jq -n \
    --arg format "$FORMAT" --argjson format_version "$FORMAT_VERSION" --arg tool_version "$VERSION" \
    --arg created "$(date --iso-8601=seconds)" --arg host "$(uname -n)" --arg user "$(id -un)" --arg home "$HOME" \
    --arg omarchy_version "$version" --arg channel "$channel" \
    --arg theme "$theme" --arg background "$background" --arg font "$font" --arg timezone "$timezone" \
    --argjson full "$FULL" \
    --slurpfile repo <(json_lines "$WORK/repo.txt") \
    --slurpfile aur <(json_lines "$WORK/aur.txt") \
    --slurpfile removed_defaults <(json_lines "$WORK/removed-defaults.txt") \
    --slurpfile flatpak <(jq -Rn '[inputs | select(length > 0) | split("\t") | {id: .[0], origin: .[1], installation: (.[2] // "system")}]' <"$WORK/flatpak.tsv") \
    --slurpfile services_system <(json_lines "$WORK/services-system.txt") \
    --slurpfile services_user <(json_lines "$WORK/services-user.txt") \
    --slurpfile groups <(json_lines "$WORK/groups.txt") \
    --slurpfile home_files <(jq -Rn '[inputs | select(length > 0) | split("\t") | {status: .[0], path: .[1]}]' <"$WORK/home.tsv") \
    --slurpfile removed <(json_lines "$WORK/removed.txt") \
    --slurpfile etc <(json_lines "$WORK/etc.txt") \
    --slurpfile repos <(jq -s . "$WORK/repos.jsonl") \
    --slurpfile editors <(jq -s 'map(select(.extensions | length > 0))' "$WORK/editors.jsonl") \
    --argjson dconf "$([[ -f $WORK/dconf.ini ]] && echo true || echo false)" \
    '{
      format: $format, format_version: $format_version, kind: "backup", tool_version: $tool_version,
      created: $created, host: $host, user: $user, home: $home, full: $full,
      omarchy: {version: $omarchy_version, channel: $channel, theme: $theme, background: $background, font: $font},
      packages: {repo: $repo[0], aur: $aur[0], flatpak: $flatpak[0], removed_defaults: $removed_defaults[0]},
      services: {system: $services_system[0], user: $services_user[0]},
      system: {timezone: $timezone, groups: $groups[0]},
      files: {home: $home_files[0], removed: $removed[0], etc: $etc[0]},
      repos: $repos[0],
      apps: {editors: $editors[0], dconf: $dconf}
    }' >"$WORK/manifest.json"
}

# Writes manifest.json, then every listed file, into one zstd-compressed tar.
# Paths in tar.list are relative to /; the transforms file them under home/
# and system/.
write_archive() {
  local out=$1 home_re status
  home_re=$(printf '%s' "${HOME#/}" | sed 's/[][\.*^$,]/\\&/g')
  touch "$WORK/tar.list"
  set +e
  tar --create --file=- --format=gnu \
    --directory="$WORK" manifest.json $([[ -f $WORK/dconf.ini ]] && echo dconf.ini) \
    --directory=/ --null --no-recursion --ignore-failed-read --warning=no-file-changed \
    --transform="s,^$home_re/,home/,S" --transform='s,^etc/,system/etc/,S' \
    --files-from="$WORK/tar.list" | zstd -q -T0 -o "$out"
  status=("${PIPESTATUS[@]}")
  set -e
  ((status[1] == 0)) || die "compressing the backup failed"
  ((status[0] <= 1)) || die "tar failed while writing the backup (exit ${status[0]})"
  ((status[0] == 0)) || warn "some files changed or vanished while being saved; the backup has what tar read"
}

cmd_create() {
  local output=$1 out name size pattern
  require_tools jq tar zstd pacman
  command -v omarchy >/dev/null || warn "omarchy isn't installed; saving what's there anyway"

  name="omarchy-backup-$(uname -n)-$(date +%Y-%m-%d-%H%M%S).tar.zst"
  if [[ -z $output ]]; then
    out="$BACKUP_DIR/$name"
  elif [[ -d $output || $output == */ ]]; then
    out="${output%/}/$name"
  else
    out=$output
  fi
  mkdir -p "$(dirname "$out")" "$CACHE_DIR"
  out=$(realpath -m "$out")

  WORK=$(mktemp -d "$CACHE_DIR/create.XXXXXX")
  OUT_PARTIAL="$out.partial"
  trap 'rm -rf "$WORK" "$OUT_PARTIAL"' EXIT
  declare -gA SEEN=()
  REPO_DIRS=()
  load_paths
  # find arguments that skip excluded folders instead of walking them.
  PRUNE=()
  for pattern in "${EXCLUDES[@]}"; do PRUNE+=(-o -path "$pattern"); done

  step "Backing up the Omarchy setup of $(id -un)@$(uname -n)"
  info "Finding configuration that differs from a fresh Omarchy install..."
  collect_home
  info "Finding system drop-ins in /etc..."
  collect_etc
  info "Listing packages, services and settings..."
  collect_packages
  info "Listing editor extensions and GNOME/GTK app settings..."
  collect_apps
  write_manifest

  info "Writing $(tilde "$out")..."
  umask 077
  write_archive "$out.partial"
  chmod 600 "$out.partial"
  mv "$out.partial" "$out"
  size=$(stat -c %s "$out")

  step "Saved $(tilde "$out") ($(human_size "$size"))"
  summarize "$WORK/manifest.json"
  echo
  info "Copy it somewhere safe (a USB drive, cloud storage) to restore on a fresh install:"
  info "  install omarchy-backup there, then run System > Omarchy Backup > Restore"
  info "  or: omarchy-backup restore $(basename "$out")"
  info "It holds your configs as they are, so keep it private."
}
