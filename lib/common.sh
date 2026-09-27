# Shared paths and helpers for omarchy-backup.
# shellcheck shell=bash
#
# The caller sets ROOT: the directory holding bin/, lib/ and share/. That is the
# git checkout, or /usr/share/omarchy-backup when installed as a package.

VERSION=$(cat "$ROOT/VERSION" 2>/dev/null || echo unknown)
FORMAT=omarchy-backup
FORMAT_VERSION=1

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-backup"
USER_PATHS_FILE="$CONFIG_DIR/paths"
USER_CONFIG_FILE="$CONFIG_DIR/config"
MENU_OPTOUT="$CONFIG_DIR/no-menu"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-backup"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-backup"
OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}
OMARCHY_STATE="$HOME/.local/state/omarchy"
# What Omarchy copies into every new home. Files identical to their copy here
# are defaults, so a backup leaves them out.
SKEL_DIR=${OMARCHY_BACKUP_SKEL:-/etc/skel}
MENU_FILE="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
MENU_BEGIN="// >>> omarchy-backup >>>"
MENU_END="// <<< omarchy-backup <<<"
MENU_ID=system.omarchy-backup

# BACKUP_DIR=... in ~/.config/omarchy-backup/config, or OMARCHY_BACKUP_DIR,
# moves where backups go.
BACKUP_DIR="$HOME/Backups/omarchy"
# Bigger files are skipped with a warning; 0 means no limit.
MAX_FILE_MB=100
# shellcheck source=/dev/null
[[ -f $USER_CONFIG_FILE ]] && source "$USER_CONFIG_FILE"
BACKUP_DIR=${OMARCHY_BACKUP_DIR:-$BACKUP_DIR}
BACKUP_DIR=${BACKUP_DIR/#\~/$HOME}

# The menu runs `omarchy-backup` when it is on PATH (the package), and the
# checkout's full path otherwise.
if [[ $(realpath "$(command -v omarchy-backup 2>/dev/null)" 2>/dev/null) == "$(realpath "$ROOT/bin/omarchy-backup")" ]]; then
  CMD=omarchy-backup
else
  CMD="$ROOT/bin/omarchy-backup"
fi

ASSUME_YES=${ASSUME_YES:-false}
DRY_RUN=${DRY_RUN:-false}
PROBLEMS=()

if [[ -t 1 ]]; then
  BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' RESET=$'\e[0m'
else
  BOLD='' DIM='' RED='' GREEN='' YELLOW='' RESET=''
fi

step() { printf '\n%s==> %s%s\n' "$BOLD$GREEN" "$*" "$RESET"; }
info() { printf '    %s\n' "$*"; }
ok() { printf '    %sok%s  %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '    %swarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() {
  printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}

# Remembers something that needs the user's attention for the closing summary.
problem() {
  PROBLEMS+=("$*")
  warn "$*"
}

interactive() {
  [[ -t 0 && -t 1 ]]
}

# Asks a yes/no question. --yes answers yes; without a terminal it's no.
confirm() {
  local question=$1 default=${2:-true} answer
  $ASSUME_YES && return 0
  interactive || return 1
  if command -v gum >/dev/null; then
    gum confirm --default="$default" "$question"
  else
    read -rp "$question [$([[ $default == true ]] && echo Y/n || echo y/N)] " answer
    [[ ${answer:-$([[ $default == true ]] && echo y || echo n)} == [yY]* ]]
  fi
}

# Runs a command that changes the system, or only prints it with --dry-run.
run() {
  if $DRY_RUN; then
    printf '    %swould run:%s' "$DIM" "$RESET"
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# Asks for the sudo password once and keeps it fresh until the script exits.
SUDO_KEEPALIVE_PID=
sudo_start() {
  $DRY_RUN && return 0
  [[ -n $SUDO_KEEPALIVE_PID ]] && return 0
  info "Some steps need administrator rights; enter your password if sudo asks."
  sudo -v || die "sudo is needed for the selected steps"
  while true; do
    sudo -n true
    sleep 50
  done 2>/dev/null &
  SUDO_KEEPALIVE_PID=$!
}

sudo_stop() {
  [[ -n $SUDO_KEEPALIVE_PID ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
  SUDO_KEEPALIVE_PID=
  return 0
}

# "1 file", "2 files".
count() {
  if (($1 == 1)); then echo "$1 $2"; else echo "$1 ${3:-$2s}"; fi
}

human_size() {
  numfmt --to=iec --suffix=B --format='%.1f' "$1" 2>/dev/null || echo "$1 bytes"
}

# True if a relative path from a manifest stays inside the folder it's
# relative to: not empty, not absolute, no . or .. parts.
safe_rel() {
  [[ -n $1 && $1 != /* && /$1/ != */../* && /$1/ != */./* && /$1/ != *//* ]]
}

# ~/... for paths in the home folder, so a backup reads the same for any user.
tilde() {
  local path=$1
  if [[ $path == "$HOME" || $path == "$HOME"/* ]]; then
    printf '~%s\n' "${path#"$HOME"}"
  else
    printf '%s\n' "$path"
  fi
}

untilde() {
  local path=$1
  printf '%s\n' "${path/#\~/$HOME}"
}

# Reads the include/exclude lines of the bundled paths file, then the user's.
# Sets INCLUDES (absolute paths; a pattern in an include is expanded here) and
# EXCLUDES (patterns on absolute paths).
load_paths() {
  local file kind path matches
  INCLUDES=()
  EXCLUDES=()
  for file in "$ROOT/share/paths" "$USER_PATHS_FILE"; do
    [[ -f $file ]] || continue
    while read -r kind path; do
      [[ -z $kind || $kind == \#* ]] && continue
      path=$(untilde "$path")
      case $kind in
      include)
        if [[ $path == *[*?[]* ]]; then
          mapfile -t matches < <(compgen -G "$path" || true)
          ((${#matches[@]} == 0)) || INCLUDES+=("${matches[@]%/}")
        else
          INCLUDES+=("${path%/}")
        fi
        ;;
      exclude) EXCLUDES+=("${path%/}") ;;
      *) warn "$(tilde "$file"): ignoring \"$kind $path\" (lines start with include or exclude)" ;;
      esac
    done <"$file"
  done
  # Never back up the backups.
  EXCLUDES+=("$BACKUP_DIR" "$STATE_DIR" "$CACHE_DIR")
}

# True if an absolute path, or a folder above it, matches an exclude pattern.
# A * in a pattern also matches across /.
excluded() {
  local path=$1 pattern
  for pattern in "${EXCLUDES[@]}"; do
    # shellcheck disable=SC2053
    [[ $path == $pattern || $path == $pattern/* ]] && return 0
  done
  return 1
}

# Reads manifest.json of a backup without unpacking the rest.
read_manifest() {
  local archive=$1
  tar --zstd -xOf "$archive" --occurrence=1 manifest.json 2>/dev/null
}

# True if a JSONC file parses the way the Omarchy menu reads it: full-line //
# comments and trailing commas are dropped, the rest must be a JSON object.
menu_jsonc_valid() {
  sed -E '/^[[:space:]]*\/\//d' "$1" | sed -zE 's/,([[:space:]]*[]}])/\1/g' | jq -e 'type == "object"' >/dev/null 2>&1
}

require_tools() {
  local tool missing=()
  for tool in "$@"; do
    command -v "$tool" >/dev/null || missing+=("$tool")
  done
  ((${#missing[@]} == 0)) || die "missing: ${missing[*]} (install with: sudo pacman -S ${missing[*]})"
}

# True if two paths are the same file, or symlinks to the same place.
same_file() {
  local a=$1 b=$2
  if [[ -L $a || -L $b ]]; then
    [[ -L $a && -L $b && $(readlink "$a") == "$(readlink "$b")" ]]
  else
    [[ -f $a && -f $b ]] && cmp -s "$a" "$b"
  fi
}

# Prints what a manifest holds, one line per area.
summarize() {
  jq -r '
    def n(a): (a // []) | length;
    def plural(k; word): "\(k) \(word)\(if k == 1 then "" else "s" end)";
    (.files.home // []) as $f |
    [
      "Omarchy  \(.omarchy.version // "?") (\(.omarchy.channel // "?")) on \(.host) by \(.user), \(.created | sub("T"; " ") | .[0:16])",
      "Look     theme \(.omarchy.theme // "-" | if . == "" then "-" else . end), font \(.omarchy.font // "-" | if . == "" then "-" else . end)",
      "Files    \(plural($f | length; "file")) (\($f | map(select(.status == "changed")) | length) changed, \($f | map(select(.status == "added")) | length) added)" +
        (if n(.files.removed) > 0 then ", \(plural(n(.files.removed); "removed default"))" else "" end) +
        (if n(.repos) > 0 then ", \(plural(n(.repos); "theme/plugin repo"))" else "" end) +
        (if n(.files.etc) > 0 then ", \(plural(n(.files.etc); "file")) in /etc" else "" end),
      "Packages \(n(.packages.repo)) from repos, \(n(.packages.aur)) AUR, \(n(.packages.flatpak)) Flatpak" +
        (if n(.packages.removed_defaults) > 0 then ", \(n(.packages.removed_defaults)) Omarchy defaults removed" else "" end),
      "System   \(n(.services.system)) system + \(n(.services.user)) user services enabled, groups: \((.system.groups // []) | join(" ") | if . == "" then "-" else . end), timezone \(.system.timezone // "-")",
      (if n(.apps.editors) > 0 or .apps.dconf then
        "Apps     " + ([(.apps.editors // [])[] | "\(.extensions | length) \(.cli) extensions"] + (if .apps.dconf then ["GNOME/GTK app settings (dconf)"] else [] end) | join(", "))
      else empty end)
    ] | .[] | "    " + .
  ' "$1"
}
