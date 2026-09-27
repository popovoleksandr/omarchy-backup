# System > Omarchy Backup in the Omarchy menu.
# shellcheck shell=bash
#
# The Omarchy menu reads one user file, ~/.config/omarchy/extensions/omarchy-menu.jsonc,
# so the entries go into it as a block between two marker comments.

# Prints a menu file without omarchy-backup's block (matched with or without
# indentation).
strip_menu_block() {
  awk -v b="$MENU_BEGIN" -v e="$MENU_END" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    line == b { skip = 1 }
    !skip { print }
    line == e { skip = 0 }
  ' "$1"
}

# setup adds or refreshes the block. With --auto (the login autostart) it
# stays quiet and does nothing after `unsetup` or outside Omarchy 4.
cmd_setup() {
  local auto=${1:-false} tmp
  if $auto; then
    [[ -f $MENU_OPTOUT ]] && return 0
    [[ -f $OMARCHY_PATH/default/omarchy/omarchy-menu.jsonc ]] || return 0
  else
    rm -f "$MENU_OPTOUT"
    [[ -f $OMARCHY_PATH/default/omarchy/omarchy-menu.jsonc ]] ||
      warn "this doesn't look like Omarchy 4 (no $OMARCHY_PATH/default/omarchy/omarchy-menu.jsonc); adding the entries anyway"
  fi
  [[ $CMD != *[\"\'\\]* ]] || die "can't add menu entries for a path with quotes: $CMD"
  mkdir -p "$(dirname "$MENU_FILE")"
  [[ -s $MENU_FILE ]] || printf '{\n}\n' >"$MENU_FILE"

  tmp=$(mktemp)
  strip_menu_block "$MENU_FILE" >"$tmp"
  # Insert right after the opening brace. Every entry ends with a comma, which
  # is valid before other entries and dropped by the menu parser before "}".
  if ! grep -qE '^[[:space:]]*\{[[:space:]]*$' "$tmp"; then
    rm -f "$tmp"
    $auto && return 0
    die "$MENU_FILE has no line with just \"{\" to add the entries after; add them by hand from $ROOT/share/menu.jsonc"
  fi
  awk -v block="$(sed "s|@CMD@|$CMD|g" "$ROOT/share/menu.jsonc" | sed 's/^/  /')" \
    '!done && /^[[:space:]]*\{[[:space:]]*$/ { print; print block; done = 1; next } { print }' "$tmp" >"$tmp.new"
  rm -f "$tmp"
  if ! menu_jsonc_valid "$tmp.new"; then
    rm -f "$tmp.new"
    $auto && return 0
    die "adding the entries would break $MENU_FILE; it is unchanged"
  fi

  if cmp -s "$tmp.new" "$MENU_FILE"; then
    rm -f "$tmp.new"
    $auto || echo "System > Omarchy Backup is already in $(tilde "$MENU_FILE")"
    return 0
  fi
  cp "$MENU_FILE" "$MENU_FILE.bak.omarchy-backup"
  cat "$tmp.new" >"$MENU_FILE"
  rm -f "$tmp.new"
  omarchy-menu refresh >/dev/null 2>&1 || true
  $auto || echo "Added System > Omarchy Backup to $(tilde "$MENU_FILE") (backup: $(tilde "$MENU_FILE").bak.omarchy-backup)"
}

cmd_unsetup() {
  local tmp
  mkdir -p "$CONFIG_DIR"
  touch "$MENU_OPTOUT"
  if ! grep -qF "$MENU_BEGIN" "$MENU_FILE" 2>/dev/null; then
    echo "System > Omarchy Backup isn't in $(tilde "$MENU_FILE")"
    return 0
  fi
  tmp=$(mktemp)
  strip_menu_block "$MENU_FILE" >"$tmp"
  menu_jsonc_valid "$tmp" || {
    rm -f "$tmp"
    die "removing the entries would break $MENU_FILE; it is unchanged"
  }
  cat "$tmp" >"$MENU_FILE"
  rm -f "$tmp"
  omarchy-menu refresh >/dev/null 2>&1 || true
  echo "Removed System > Omarchy Backup from $(tilde "$MENU_FILE"); \`$CMD setup\` adds it back"
}

# Opening the launcher app is asking for the menu, so it adds the entries
# back even after `unsetup`.
cmd_menu() {
  cmd_setup false >/dev/null
  exec omarchy-menu summon "$MENU_ID"
}
