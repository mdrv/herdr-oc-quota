#!/bin/sh
# install.sh — build the binary, link the herdr-oc-quota plugin, and wire it
# into the Herdr tab bar.
#
# What it does:
#   1. cargo build --release
#   2. seeds ~/.config/herdr/oc-quota.toml (if missing), migrating the old
#      ~/.config/herdr-oc-quota/config.toml when present
#   3. patches the Herdr config [ui] table:
#        tab_bar_right   = [ { type="command", ...} ]  # herdr-oc-quota
#      (tab bar position is left to the user — top or bottom both work)
#      Pre-existing user values for these keys (plus tab_bar_right_separator
#      and, from older installs, tab_bar_position) are backed up (first
#      install only) to <herdr-config>.herdr-oc-quota.bak; uninstall.sh restores.
#   4. validates with `herdr config check` (reverts on failure)
#   5. herdr plugin link + herdr server reload-config
#   6. performs an initial refresh
#
# Flags (mainly for testing): --no-link  --no-refresh
# Herdr config location follows HERDR_CONFIG_PATH, default ~/.config/herdr/config.toml.

set -eu

PLUGIN_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
BIN="$PLUGIN_DIR/target/release/herdr-oc-quota"

NO_LINK=0
NO_REFRESH=0
for _arg in "$@"; do
    case $_arg in
        --no-link) NO_LINK=1 ;;
        --no-refresh) NO_REFRESH=1 ;;
        *) printf 'unknown option: %s\n' "$_arg" >&2; exit 2 ;;
    esac
done

# 1. build
if ! command -v cargo >/dev/null 2>&1; then
    printf 'ERROR: cargo is required to build this plugin.\n' >&2
    exit 1
fi
printf 'building (cargo build --release)...\n'
cargo build --release --manifest-path "$PLUGIN_DIR/Cargo.toml"
[ -x "$BIN" ] || { printf 'ERROR: build did not produce %s\n' "$BIN" >&2; exit 1; }

# 2. seed plugin config (sibling of herdr's config.toml) + migrate old location
HERDR_CONFIG="${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}"
HERDR_CFG_DIR=$(dirname -- "$HERDR_CONFIG")
PLUGIN_CFG="$HERDR_CFG_DIR/oc-quota.toml"
mkdir -p "$HERDR_CFG_DIR"

LEGACY_CFG_DIR="${HERDR_OC_QUOTA_CONFIG_DIR:-$HOME/.config/herdr-oc-quota}"
if [ ! -f "$PLUGIN_CFG" ] && [ -f "$LEGACY_CFG_DIR/config.toml" ]; then
    mv "$LEGACY_CFG_DIR/config.toml" "$PLUGIN_CFG"
    rmdir "$LEGACY_CFG_DIR" 2>/dev/null || true
    printf 'migrated %s -> %s\n' "$LEGACY_CFG_DIR/config.toml" "$PLUGIN_CFG"
fi

if [ ! -f "$PLUGIN_CFG" ]; then
    cat > "$PLUGIN_CFG" <<'EOF'
# herdr-oc-quota settings — GLM / Z.AI Coding Plan quota for the Herdr tab bar.
# Simple `key = value` pairs; strings may be double-quoted.

# Seconds between API refreshes (default 300 = 5 minutes).
refresh_interval_secs = 300

# Timeout for one API call, in seconds.
request_timeout_secs = 20

# Tab bar label prefix.
label = "GLM"

# Show the quota reset ("· ⏰ 14:23:05").
show_reset = true

# How to show the quota reset:
#   "clock"    = local wall-clock time it resets, e.g. "· ⏰ 14:23:05"
#   "duration" = time remaining, e.g. "· 1d12h"
reset_style = "clock"

# Show when data was last fetched ("· 3m ago").
show_age = true

# Trailing margin after the segment (keeps it off the screen edge).
# Default is one U+2800 \"braille blank\" — renders like a space but is NOT
# whitespace, so Herdr's output trimming keeps it. \"\" disables it;
# a plain ASCII space gets trimmed away by Herdr and shows no margin.
right_margin = "⠀"

# OpenCode auth store, if not at ~/.local/share/opencode/auth.json.
# auth_json_path = "/home/you/.local/share/opencode/auth.json"
EOF
    printf 'created %s\n' "$PLUGIN_CFG"
fi

# 3. patch herdr config [ui]
[ -f "$HERDR_CONFIG" ] || : > "$HERDR_CONFIG"

BACKUP="$HERDR_CONFIG.herdr-oc-quota.bak"
SNAP=$(mktemp)
trap 'rm -f "$SNAP"' EXIT
cp "$HERDR_CONFIG" "$SNAP"

RIGHT_LINE="tab_bar_right = [ { type = \"command\", command = \"$BIN status\", interval_seconds = 30, timeout_seconds = 25 } ] # herdr-oc-quota"

# First install: back up displaced user values into $BACKUP (marker + lines).
# Reinstall: backup exists, strip only our marked lines, keep backup as-is.
if [ -f "$BACKUP" ]; then
    BK_ARG=""
else
    BK_ARG="$BACKUP"
fi

TMP="$HERDR_CONFIG.tmp.$$"
awk -v right="$RIGHT_LINE" -v bf="$BK_ARG" '
    BEGIN { in_ui = 0; skip = 0; inserted = 0; ubn = 0; ui_existed = 0 }
    skip > 0 {  # consuming a multi-line value we are removing
        if (bf != "" && $0 !~ /# herdr-oc-quota[ \t]*$/) ub[ubn++] = $0
        n = gsub(/\[/, "[", $0); m = gsub(/\]/, "]", $0)
        skip += n - m
        if (skip <= 0) skip = 0
        next
    }
    {
        if (in_ui && $0 ~ /^[ \t]*\[/) {  # leaving [ui]: insert before the next table
            if (!inserted) { print right; inserted = 1 }
            in_ui = 0
        }
        if (!in_ui && $0 ~ /^[ \t]*\[ui\][ \t]*(#.*)?$/) {
            ui_existed = 1; in_ui = 1
            print
            next
        }
        if (in_ui && $0 ~ /^[ \t]*tab_bar_right[ \t]*=/) {  # replace in place
            if (bf != "" && $0 !~ /# herdr-oc-quota[ \t]*$/) ub[ubn++] = $0
            n = gsub(/\[/, "[", $0); m = gsub(/\]/, "]", $0)
            if (n - m > 0) skip = n - m  # value continues on following lines
            print right
            inserted = 1
            next
        }
        if (in_ui && $0 ~ /^[ \t]*(tab_bar_position|tab_bar_right_separator)[ \t]*=/ && $0 ~ /# herdr-oc-quota[ \t]*$/) {
            n = gsub(/\[/, "[", $0); m = gsub(/\]/, "]", $0)
            if (n - m > 0) skip = n - m
            next
        }
        print
    }
    END {
        if (!inserted) {
            if (ui_existed) print right  # [ui] was the last table in the file
            else { print ""; print "[ui]"; print right }
        }
        if (bf != "") {
            printf "%s\n", (ui_existed ? "#!ui-existed" : "#!created-ui") > bf
            for (i = 0; i < ubn; i++) print ub[i] > bf
            close(bf)
        }
    }
' "$HERDR_CONFIG" > "$TMP" && mv "$TMP" "$HERDR_CONFIG"

# 4. validate; revert if broken
if command -v herdr >/dev/null 2>&1; then
    if ! herdr config check >/dev/null 2>&1; then
        cp "$SNAP" "$HERDR_CONFIG"
        [ -n "$BK_ARG" ] && rm -f "$BACKUP"
        printf 'ERROR: `herdr config check` rejected the patched config; reverted.\n' >&2
        exit 1
    fi
fi
printf 'patched %s\n' "$HERDR_CONFIG"
[ -n "$BK_ARG" ] && printf 'previous tab_bar settings backed up to %s\n' "$BACKUP"

# 5. link plugin + reload
if [ "$NO_LINK" = 0 ] && command -v herdr >/dev/null 2>&1; then
    herdr plugin link "$PLUGIN_DIR"
    herdr server reload-config >/dev/null 2>&1 \
        || printf '(herdr server not running; changes apply on next start)\n'
fi

# 6. initial refresh
if [ "$NO_REFRESH" = 0 ]; then
    _out=$("$BIN" refresh 2>/dev/null || true)
    if [ -n "$_out" ]; then
        printf 'current status: %s\n' "$_out"
        case $_out in
            *'✖'*) printf 'note: fetch failed — log in to OpenCode once (`opencode` → Z.AI), or set auth_json_path in %s\n' "$PLUGIN_CFG" ;;
        esac
    fi
fi

printf 'done. The quota indicator appears in the tab bar, top or bottom — wherever yours lives (poll every 30s; API refresh every refresh_interval_secs).\n'
