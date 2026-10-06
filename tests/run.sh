#!/usr/bin/env bash
# Backs up a made-up home folder and restores it into a fresh one. Nothing
# touches your own: the homes, the skel folder and the backups all live in a
# temporary folder, and only the files and repos steps run.
#
# Usage: tests/run.sh

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
passed=0 failed=0

check() {
  local what=$1
  shift
  if "$@" >/dev/null 2>&1; then
    passed=$((passed + 1))
    printf '  \e[32mok\e[0m    %s\n' "$what"
  else
    failed=$((failed + 1))
    printf '  \e[31mFAIL\e[0m  %s\n' "$what"
  fi
}

# Runs omarchy-backup as the user of the home folder $1.
ob() {
  local home=$1
  shift
  env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_CACHE_HOME -u XDG_DATA_HOME \
    -u HYPRLAND_INSTANCE_SIGNATURE -u WAYLAND_DISPLAY \
    HOME="$home" OMARCHY_BACKUP_SKEL="$t/skel" OMARCHY_BACKUP_DIR="$t/backups" PATH="$t/bin:$PATH" \
    "$root/bin/omarchy-backup" "$@"
}

manifest() { tar --zstd -xOf "$archive" manifest.json | jq -e "$@"; }

git_() { git -c user.name=test -c user.email=test@example.com -c init.defaultBranch=main "$@"; }

echo "Setting up"
# Stand-ins for codium and dconf that keep their state in the home folder.
mkdir -p "$t/bin"
cat >"$t/bin/codium" <<'FAKE'
#!/bin/bash
list=$HOME/.fake-codium
case $1 in
--list-extensions) [[ -f $list ]] && if [[ ${2:-} == --show-versions ]]; then cat "$list"; else sed 's/@.*//' "$list"; fi ;;
--install-extension)
  while (($# > 0)); do
    [[ $1 == --install-extension ]] && shift && continue
    [[ $1 == bad.* ]] || echo "${1,,}@9.9.9" >>"$list"
    shift
  done
  ;;
esac
exit 0
FAKE
cat >"$t/bin/dconf" <<'FAKE'
#!/bin/bash
case $1 in
dump) [[ -f $HOME/.fake-dconf ]] && cat "$HOME/.fake-dconf" ;;
load) cat >"$HOME/.fake-dconf" ;;
esac
exit 0
FAKE
printf '#!/bin/bash\necho "$1" >"$HOME/.edited"\n' >"$t/bin/omarchy-launch-editor"
chmod +x "$t/bin/codium" "$t/bin/dconf" "$t/bin/omarchy-launch-editor"
# What Omarchy seeds into a new home.
mkdir -p "$t/skel/.config/hypr" "$t/skel/.config/omarchy/extensions" "$t/skel/.local/share/applications"
echo 'default hyprland' >"$t/skel/.config/hypr/hyprland.lua"
echo 'default input' >"$t/skel/.config/hypr/input.lua"
echo 'default bashrc' >"$t/skel/.bashrc"
printf '{\n}\n' >"$t/skel/.config/omarchy/extensions/omarchy-menu.jsonc"
printf '[Desktop Entry]\nName=Maps\n' >"$t/skel/.local/share/applications/Maps.desktop"
printf '[Desktop Entry]\nName=Chat\n' >"$t/skel/.local/share/applications/Chat.desktop"

# A theme installed from git, with a local change and a new file.
git_ init -q --bare "$t/theme.git"
git_ clone -q "$t/theme.git" "$t/theme-work" 2>/dev/null
echo 'accent = "#ff0000"' >"$t/theme-work/colors.toml"
git_ -C "$t/theme-work" add colors.toml
git_ -C "$t/theme-work" commit -qm theme
git_ -C "$t/theme-work" push -q origin HEAD 2>/dev/null

# The old home: a fresh one, then customized.
old=$t/old-home
mkdir -p "$old"
cp -a "$t/skel/." "$old/"
echo 'my hyprland' >"$old/.config/hypr/hyprland.lua"
echo 'my bindings' >"$old/.config/hypr/extra.lua"
chmod 600 "$old/.config/hypr/extra.lua"
ln -s "$old/.config/hypr/hyprland.lua" "$old/.config/hypr/link.lua"
echo 'stale' >"$old/.config/hypr/hyprland.lua.bak"
rm "$old/.local/share/applications/Maps.desktop"
git_ clone -q "$t/theme.git" "$old/.config/omarchy/themes/mytheme" 2>/dev/null
echo 'foreground = "#eeeeee"' >>"$old/.config/omarchy/themes/mytheme/colors.toml"
echo 'extra' >"$old/.config/omarchy/themes/mytheme/extra.toml"
mkdir -p "$old/.config/omarchy-backup" "$old/notes"
echo 'include ~/notes/todo.txt' >"$old/.config/omarchy-backup/paths"
echo 'todo' >"$old/notes/todo.txt"
# Claude Code, mise, and a file over the size limit.
mkdir -p "$old/.claude/projects/-home-me/memory" "$old/.claude/skills/synced/x" "$old/.config/mise" "$old/.local/bin"
echo '{"theme": "dark"}' >"$old/.claude/settings.json"
echo 'secret' >"$old/.claude/.credentials.json"
echo '{}' >"$old/.claude/history.jsonl"
echo '{}' >"$old/.claude/projects/-home-me/session.jsonl"
echo 'remember this' >"$old/.claude/projects/-home-me/memory/MEMORY.md"
echo 'synced' >"$old/.claude/skills/synced/x/SKILL.md"
printf '[tools]\nclaude = "latest"\n"npm:foo" = "1"\n\n[settings]\nx = 1\n' >"$old/.config/mise/config.toml"
echo 'MAX_FILE_MB=1' >"$old/.config/omarchy-backup/config"
mkdir -p "$old/.claude/plugins"
echo '{"version": 2, "plugins": {"lsp@acme": [{"scope": "user"}], "local@acme": [{"scope": "project"}]}}' >"$old/.claude/plugins/installed_plugins.json"
echo '{"acme": {"source": {"source": "github", "repo": "acme/claude-plugins"}}}' >"$old/.claude/plugins/known_marketplaces.json"
# An Omarchy shell plugin installed with `omarchy plugin add`.
git_ init -q --bare "$t/plugin.git"
git_ clone -q "$t/plugin.git" "$t/plugin-work" 2>/dev/null
echo '{"id": "myplugin"}' >"$t/plugin-work/manifest.json"
git_ -C "$t/plugin-work" add manifest.json
git_ -C "$t/plugin-work" commit -qm plugin
git_ -C "$t/plugin-work" push -q origin HEAD 2>/dev/null
git_ clone -q "$t/plugin.git" "$old/.config/omarchy/plugins/myplugin" 2>/dev/null
head -c 2000000 /dev/zero >"$old/.local/bin/big"
# App settings, an app cache, a login, and extensions.
mkdir -p "$old/.config/someapp/Cache" "$old/.config/gh" "$old/.config/Signal"
echo 'zoom = 2' >"$old/.config/someapp/settings.conf"
echo 'cached' >"$old/.config/someapp/Cache/data"
echo 'oauth' >"$old/.config/someapp/credentials.json"
echo 'token: x' >"$old/.config/gh/hosts.yml"
echo 'db' >"$old/.config/Signal/db.sqlite"
echo 'include ~/.config/gh/hosts.yml' >>"$old/.config/omarchy-backup/paths"
printf 'Pub.Ext-A@1.2.3\npub.ext-b@0.1.0\nbad.gone@1.0.0\n' >"$old/.fake-codium"
printf '[org/gnome/nautilus/preferences]\ndefault-folder-viewer=%s\n' "'list-view'" >"$old/.fake-dconf"
echo 'echo hi' >"$old/.local/bin/mine"

echo "Backing up"
ob "$old" create >"$t/create.log" 2>&1 || { cat "$t/create.log"; exit 1; }
archive=$(find "$t/backups" -name 'omarchy-backup-*.tar.zst' | head -n 1)
check "the backup is in the backup folder" test -f "$archive"
check "only you can read it" test "$(stat -c %a "$archive")" = 600
check "manifest.json comes first" test "$(tar --zstd -tf "$archive" | head -n 1)" = manifest.json
check "a changed default is saved" manifest '.files.home | any(.path == ".config/hypr/hyprland.lua" and .status == "changed")'
check "an added file is saved" manifest '.files.home | any(.path == ".config/hypr/extra.lua" and .status == "added")'
check "an untouched default is left out" manifest '.files.home | all(.path != ".config/hypr/input.lua")'
check "*.bak files are left out" manifest '.files.home | all(.path | endswith(".bak") | not)'
check "a symlink is saved" manifest '.files.home | any(.path == ".config/hypr/link.lua")'
check "a removed default launcher is remembered" manifest '.files.removed == [".local/share/applications/Maps.desktop"]'
check "an include from ~/.config/omarchy-backup/paths is saved" manifest '.files.home | any(.path == "notes/todo.txt")'
check "the git theme is saved by URL" manifest --arg url "$t/theme.git" '.repos | any(.path == ".config/omarchy/themes/mytheme" and .url == $url)'
check "with its local changes" manifest '.repos | map(select(.path | endswith("mytheme")))[0].changed | sort == ["colors.toml", "extra.toml"]'
check "an Omarchy plugin from git is saved by URL" manifest --arg url "$t/plugin.git" '.repos | any(.path == ".config/omarchy/plugins/myplugin" and .url == $url)'
check "and not as plain files" manifest '.files.home | all(.path | startswith(".config/omarchy/themes/") | not)'
check "Claude settings are saved" manifest '.files.home | any(.path == ".claude/settings.json")'
check "Claude project memory is saved (a pattern include)" manifest '.files.home | any(.path == ".claude/projects/-home-me/memory/MEMORY.md")'
check "the Claude login is left out" manifest '.files.home | all(.path != ".claude/.credentials.json")'
check "Claude chats and history are left out" manifest '.files.home | all(.path | endswith(".jsonl") | not)'
check "skills synced from claude.ai are left out" manifest '.files.home | all(.path | startswith(".claude/skills/synced") | not)'
check "your scripts in ~/.local/bin are saved" manifest '.files.home | any(.path == ".local/bin/mine")'
check "a file over MAX_FILE_MB is skipped" manifest '.files.home | all(.path != ".local/bin/big")'
check "app settings in ~/.config are saved" manifest '.files.home | any(.path == ".config/someapp/settings.conf")'
check "app caches are left out" manifest '.files.home | all(.path != ".config/someapp/Cache/data")'
check "credential files are left out" manifest '.files.home | all(.path != ".config/someapp/credentials.json")'
check "Signal is left out" manifest '.files.home | all(.path | startswith(".config/Signal") | not)'
check "a login named on its own in an include is saved anyway" manifest '.files.home | any(.path == ".config/gh/hosts.yml")'
check "editor extensions are listed" manifest '.apps.editors == [{cli: "codium", extensions: ["Pub.Ext-A@1.2.3", "pub.ext-b@0.1.0", "bad.gone@1.0.0"]}]'
check "dconf settings are saved as text" bash -c "tar --zstd -xOf '$archive' dconf.ini | grep -q list-view"
check "show summarizes it" ob "$old" show "$archive"

echo "Restoring into a fresh home"
new=$t/new-home
mkdir -p "$new"
cp -a "$t/skel/." "$new/"
ob "$new" restore "$archive" --only files,repos --yes >"$t/restore.log" 2>&1 || { cat "$t/restore.log"; exit 1; }
check "a changed default comes back" grep -qx 'my hyprland' "$new/.config/hypr/hyprland.lua"
check "an added file comes back with its mode" test "$(stat -c %a "$new/.config/hypr/extra.lua")" = 600
check "a symlink into the old home points into the new one" test "$(readlink "$new/.config/hypr/link.lua")" = "$new/.config/hypr/hyprland.lua"
check "a removed default launcher is removed again" test ! -e "$new/.local/share/applications/Maps.desktop"
check "other default launchers stay" test -f "$new/.local/share/applications/Chat.desktop"
check "the git theme is cloned" test -d "$new/.config/omarchy/themes/mytheme/.git"
check "with its local change" grep -q foreground "$new/.config/omarchy/themes/mytheme/colors.toml"
check "and its new file" test -f "$new/.config/omarchy/themes/mytheme/extra.toml"
check "the extra include comes back" test -f "$new/notes/todo.txt"
check "the Omarchy plugin is cloned" test -f "$new/.config/omarchy/plugins/myplugin/manifest.json"
ob "$new" restore "$archive" --only claude --dry-run --yes >"$t/claude.log" 2>&1 || true
check "the claude step lists the user plugins" grep -q 'Claude Code plugins (lsp)' "$t/claude.log"
check "and would add their marketplace" grep -q 'claude plugin marketplace add acme/claude-plugins' "$t/claude.log"
check "and install them again" grep -q 'claude plugin install lsp@acme' "$t/claude.log"
check "but not project plugins" bash -c "! grep -q 'local@acme' '$t/claude.log'"
ob "$new" restore "$archive" --only apps --yes >"$t/apps.log" 2>&1 || { cat "$t/apps.log"; exit 1; }
check "the apps step loads the dconf settings" grep -q list-view "$new/.fake-dconf"
check "and installs the missing extensions" test "$(sed 's/@.*//' "$new/.fake-codium" | sort | paste -sd' ')" = "pub.ext-a pub.ext-b"
check "and reports the ones it couldn't" grep -q "couldn't install these codium extensions.*bad.gone" "$t/apps.log"
ob "$new" restore "$archive" --only apps --yes >"$t/apps2.log" 2>&1 || true
check "installed extensions aren't installed twice" test "$(wc -l <"$new/.fake-codium")" = 2
check "Claude memory comes back" grep -qx 'remember this' "$new/.claude/projects/-home-me/memory/MEMORY.md"
ob "$new" restore "$archive" --only tools --dry-run --yes >"$t/tools.log" 2>&1 || true
check "the tools step lists the mise tools" grep -q 'Tools from mise (claude npm:foo)' "$t/tools.log"
check "and would run mise install" grep -q "mise --cd $new install --yes" "$t/tools.log"
undo=$(find "$new/.local/state/omarchy-backup" -name 'undo-*.tar.zst' | head -n 1)
check "an undo file is written" test -f "$undo"

ob "$new" restore "$archive" --only files,repos --yes >"$t/restore2.log" 2>&1
check "restoring again changes nothing" grep -q 'all files already match' "$t/restore2.log"

ob "$new" restore "$undo" --yes >"$t/undo.log" 2>&1 || { cat "$t/undo.log"; exit 1; }
check "the undo file puts the default back" grep -qx 'default hyprland' "$new/.config/hypr/hyprland.lua"
check "and the removed launcher" test -f "$new/.local/share/applications/Maps.desktop"

echo "A backup with unsafe paths"
mkdir -p "$t/evil"
tar --zstd -xf "$archive" -C "$t/evil"
jq --arg url "$t/theme.git" '.repos += [{path: "", url: $url, commit: "", branch: "", changed: []},
  {path: "..", url: $url, commit: "", branch: "", changed: []}] | .files.removed += ["../outside.txt"]' \
  "$t/evil/manifest.json" >"$t/evil/m" && mv "$t/evil/m" "$t/evil/manifest.json"
(cd "$t/evil" && tar --create --file=- manifest.json home | zstd -q -o "$t/evil.tar.zst")
echo 'outside' >"$t/outside.txt"
ob "$new" restore "$t/evil.tar.zst" --only repos,files --yes >"$t/evil.log" 2>&1 || true
check "an empty repo path is refused" grep -q 'unsafe path in the backup: ""' "$t/evil.log"
check "and the home folder is still there" test -f "$new/.config/hypr/hyprland.lua"
check "a .. repo path is refused" grep -q 'unsafe path in the backup: ".."' "$t/evil.log"
check "a removal outside the home folder is ignored" test -f "$t/outside.txt"

echo "Menu"
menu=$new/.config/omarchy/extensions/omarchy-menu.jsonc
cp "$t/skel/.config/omarchy/extensions/omarchy-menu.jsonc" "$menu"
ob "$new" setup >/dev/null
check "setup adds System > Omarchy Backup" grep -q '"system.omarchy-backup":' "$menu"
check "the menu file stays valid" bash -c "ROOT='$root'; source '$root/lib/common.sh'; menu_jsonc_valid '$menu'"
check "with a row to choose what's saved" grep -q "\"system.omarchy-backup.paths\".*$root/bin/omarchy-backup edit" "$menu"
cp "$menu" "$t/menu-1"
ob "$new" setup >/dev/null
check "setup twice adds it once" cmp -s "$menu" "$t/menu-1"
ob "$new" unsetup >/dev/null
check "unsetup removes it" bash -c "! grep -q omarchy-backup '$menu'"
ob "$new" setup --auto >/dev/null
check "the login autostart respects unsetup" bash -c "! grep -q omarchy-backup '$menu'"
ob "$new" setup >/dev/null
check "setup adds it back" grep -q '"system.omarchy-backup":' "$menu"

echo "Editing the paths file"
rm -f "$new/.config/omarchy-backup/paths"
ob "$new" edit
check "edit starts the paths file with a guide" grep -q '^#   include ~/.ssh/config' "$new/.config/omarchy-backup/paths"
check "and opens it in Omarchy's editor" grep -qx "$new/.config/omarchy-backup/paths" "$new/.edited"
echo 'include ~/notes.txt' >>"$new/.config/omarchy-backup/paths"
ob "$new" edit
check "edit keeps what's already there" grep -qx 'include ~/notes.txt' "$new/.config/omarchy-backup/paths"

echo
echo "$passed passed, $failed failed"
((failed == 0))
