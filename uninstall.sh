#!/bin/sh
# uninstall.sh — remove the herdr-oc-quota plugin and restore the Herdr config.
#
# 1. removes our tab_bar_* lines from the Herdr config and restores the user
#    values backed up at first install (<herdr-config>.herdr-oc-quota.bak);
#    if we created the [ui] section ourselves and it is now empty, it is
#    removed too.
# 2. validates with `herdr config check` (reverts on failure)
# 3. herdr plugin unlink + herdr server reload-config
# 4. removes state (~/.local/state/herdr-oc-quota); keeps the plugin config
#    (~/.config/herdr/oc-quota.toml — delete it manually if you want)
#
# Flags (mainly for testing): --no-unlink
# Herdr config location follows HERDR_CONFIG_PATH, default ~/.config/herdr/config.toml.

set -eu

PLUGIN_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)

NO_UNLINK=0
for _arg in "$@"; do
    case $_arg in
        --no-unlink) NO_UNLINK=1 ;;
        *) printf 'unknown option: %s\n' "$_arg" >&2; exit 2 ;;
    esac
done

HERDR_CONFIG="${HERDR_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml}"
BACKUP="$HERDR_CONFIG.herdr-oc-quota.bak"

if [ -f "$HERDR_CONFIG" ] && [ -f "$BACKUP" ]; then
    SNAP=$(mktemp)
    trap 'rm -f "$SNAP"' EXIT
    cp "$HERDR_CONFIG" "$SNAP"

    CREATED=$(sed -n '1s/^#!created-ui$/1/p' "$BACKUP")

    TMP="$HERDR_CONFIG.tmp.$$"
    awk -v created="${CREATED:-0}" '
        FNR == 1 { f++ }
        f == 1 {                       # backup file: marker line, then user lines
            if (FNR == 1) next
            ub[ubn++] = $0
            next
        }
        /^[ \t]*\[/ { if ($0 !~ /^[ \t]*\[ui\][ \t]*(#.*)?$/) in_ui = 0 }
        /^[ \t]*tab_bar_right[ \t]*=.*# herdr-oc-quota[ \t]*$/ {
            if (ubn > 0 && !ui_done) { # restore user values at our line position
                for (i = 0; i < ubn; i++) print ub[i]
                ui_done = 1
            }
            next
        }
        /# herdr-oc-quota[ \t]*$/ { next }   # drop our other marked lines
        buffering {                          # inside the [ui] section we created
            if ($0 ~ /^[ \t]*\[/) {          # next section ends it
                flush()
                print
                next
            }
            if ($0 ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_.-]*[ \t]*=/) ui_has_keys = 1
            buf[bn++] = $0
            next
        }
        $0 ~ /^[ \t]*\[ui\][ \t]*(#.*)?$/ {
            ui_seen = 1; in_ui = 1
            if (created && !ui_done) {       # we added this section: drop if empty
                buffering = 1
                buf[bn++] = $0
                next
            }
            print
            next
        }
        { print }
        END {
            if (buffering) flush()
            else if (ubn > 0 && !ui_done) {
                # lost the [ui] header or our marked line; restore at end of file
                if (!in_ui) {
                    print ""
                    print "[ui]"
                }
                for (i = 0; i < ubn; i++) print ub[i]
            }
        }
        function flush() {
            if (ui_has_keys) {
                for (i = 0; i < bn; i++) print buf[i]
            } else {
                for (i = 0; i < bn; i++)
                    if (buf[i] !~ /^[ \t]*\[ui\][ \t]*(#.*)?$/) print buf[i]
            }
            buffering = 0
            ui_done = 1
        }
    ' "$BACKUP" "$HERDR_CONFIG" > "$TMP" && mv "$TMP" "$HERDR_CONFIG"

    if command -v herdr >/dev/null 2>&1; then
        if ! herdr config check >/dev/null 2>&1; then
            cp "$SNAP" "$HERDR_CONFIG"
            printf 'ERROR: `herdr config check` rejected the restored config; reverted (backup kept at %s).\n' "$BACKUP" >&2
            exit 1
        fi
    fi
    rm -f "$BACKUP"
    printf 'restored %s\n' "$HERDR_CONFIG"
else
    printf 'no herdr-oc-quota lines to restore in %s\n' "$HERDR_CONFIG"
fi

if [ "$NO_UNLINK" = 0 ] && command -v herdr >/dev/null 2>&1; then
    herdr plugin unlink "$PLUGIN_DIR" || printf '(plugin was not linked)\n'
    herdr server reload-config >/dev/null 2>&1 \
        || printf '(herdr server not running)\n'
fi

rm -rf "${HERDR_OC_QUOTA_STATE_DIR:-$HOME/.local/state/herdr-oc-quota}"
printf 'done. Kept %s (delete it manually if you want).\n' \
    "${HERDR_OC_QUOTA_CONFIG:-$(dirname -- "$HERDR_CONFIG")/oc-quota.toml}"
