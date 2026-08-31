#!/bin/sh
# Test suite for herdr-oc-quota (offline mock API + fixture herdr configs).
set -u
PLUGIN=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=$PLUGIN/target/release/herdr-oc-quota
T=${TMPDIR:-/tmp}/herdr-oc-quota-tests.$$
rm -rf "$T"; mkdir -p "$T"
[ -x "$BIN" ] || { echo "binary missing: $BIN (run: cargo build --release)" >&2; exit 1; }
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1"; }
check() { # name expected actual
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected [$2] got [$3]"; fi
}

# ---------- mock auth ----------
cat > "$T/auth.json" <<'EOF'
{"zai-coding-plan": {"key": "mock-key-not-real"}}
EOF

# ---------- mock API server ----------
cat > "$T/server.py" <<'EOF'
import http.server, json, time
def quota_body(nr=None):
    if nr is None:
        nr = int((time.time() + 36*3600) * 1000)
    return {"code": 0, "msg": "ok", "data": {"limits": [
        {"type": "CONCURRENCY", "number": 5},
        {"type": "TOKENS_LIMIT", "percentage": 42, "nextResetTime": nr,
         "remaining": 58000, "number": 100000}], "level": "lite"}}
class H(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body):
        payload = json.dumps(body).encode()
        self.send_response(code); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload))); self.end_headers()
        self.wfile.write(payload)
    def do_GET(self):
        auth = self.headers.get('Authorization') or ''
        if self.path == '/ok':
            self.reply(200, quota_body())
        elif self.path == '/fixed':
            # fixed far-future reset: 2100-01-01T00:00:00Z -> ⏰ 00:00:00 under TZ=UTC
            self.reply(200, quota_body(4102444800000))
        elif self.path == '/err':
            self.reply(200, {"code": 1002, "msg": "request too fast"})
        elif self.path == '/500':
            self.send_response(500); self.end_headers(); self.wfile.write(b'boom')
        elif self.path == '/checkauth':
            # success ONLY for a raw (non-Bearer), non-empty key
            if auth and not auth.startswith('Bearer '):
                self.reply(200, quota_body())
            else:
                self.send_response(500); self.end_headers()
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', 8931), H).serve_forever()
EOF
python3 "$T/server.py" &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
sleep 0.5

MB=$'\u2800' # default right_margin (braille blank) — not whitespace, must be stripped for exact compares
fl() { sed "s/[ ${MB}]*\$//"; } # strip trailing ASCII spaces and braille blanks
run() { # url args...
    _u=$1; shift
    HERDR_OC_QUOTA_API_URL="$_u" HERDR_OC_QUOTA_AUTH_PATH="$T/auth.json" \
    HERDR_OC_QUOTA_CONFIG="$T/cfg/config.toml" HERDR_OC_QUOTA_STATE_DIR="$T/state" \
    "$BIN" "$@" | fl
}
fresh_dirs() { rm -rf "$T/cfg" "$T/state"; mkdir -p "$T/cfg" "$T/state"; }

# ---------- 1. success path ----------
fresh_dirs
OUT=$(run http://127.0.0.1:8931/ok refresh --force)
case "$OUT" in
    "GLM 42% · ⏰ "[0-9][0-9]":"[0-9][0-9]":"[0-9][0-9]" · "*" ago") ok "refresh success format: $OUT" ;;
    *) bad "refresh success format: got [$OUT]" ;;
esac
grep -q '"percentage": *42' "$T/state/state.json" && ok "state percentage stored" || bad "state percentage missing"
grep -q '"level": *"lite"' "$T/state/state.json" && ok "state level stored" || bad "state level missing"

# 2. status within interval = no refetch, still renders
OUT2=$(run http://127.0.0.1:8931/500 status)
case "$OUT2" in
    "GLM 42% · ⏰ "[0-9][0-9]":"[0-9][0-9]":"[0-9][0-9]" · "*" ago") ok "fresh status does not refetch (500 url ignored)" ;;
    *) bad "fresh status refetched or wrong: [$OUT2]" ;;
esac

# 3. stale data + failing API -> keep last good, mark '!'
python3 - "$T/state/state.json" <<'EOF'
import json, sys, time
p = sys.argv[1]
st = json.load(open(p))
st["fetched_at"] = int(time.time()) - 700
json.dump(st, open(p, "w"))
EOF
OUT3=$(run http://127.0.0.1:8931/err status)
case "$OUT3" in
    "GLM 42%"*" !") ok "stale keeps last good + '!': $OUT3" ;;
    *) bad "stale handling: [$OUT3]" ;;
esac
grep -q 'API error: request too fast (code 1002)' "$T/state/state.json" && ok "error recorded in state" || bad "error not recorded"

# 4. no prior data + API error shape -> inline error
fresh_dirs
OUT4=$(run http://127.0.0.1:8931/err refresh --force)
check "error-shape render" "GLM ✖ API error: request too fast (code 1002)" "$OUT4"

# 5. HTTP 500
OUT5=$(run http://127.0.0.1:8931/500 refresh --force)
check "http 500 render" "GLM ✖ HTTP 500" "$OUT5"

# 6. missing auth
fresh_dirs
OUT6=$(HERDR_OC_QUOTA_API_URL=http://127.0.0.1:8931/ok HERDR_OC_QUOTA_AUTH_PATH="$T/nope.json" \
    HERDR_OC_QUOTA_CONFIG="$T/cfg/config.toml" HERDR_OC_QUOTA_STATE_DIR="$T/state" "$BIN" refresh --force \
    | fl)
check "missing auth" "GLM ✖ cannot read OpenCode auth.json (log in via opencode once)" "$OUT6"

# 7. state exists but percentage null and no error -> ellipsis, no fetch
fresh_dirs
python3 - "$T/state/state.json" <<'EOF'
import json, sys, time
json.dump({"fetched_at": int(time.time()), "percentage": None, "next_reset_ms": None,
           "level": None, "error": None, "error_at": None}, open(sys.argv[1], "w"))
EOF
OUT7=$(run http://127.0.0.1:8931/500 status)
check "null-data ellipsis" "GLM …" "$OUT7"

# 8. Authorization header: raw key, no Bearer
fresh_dirs
OUT8=$(run http://127.0.0.1:8931/checkauth refresh --force)
case "$OUT8" in "GLM 42%"*" ago") ok "auth header raw (no Bearer)" ;; *) bad "auth header: [$OUT8]" ;; esac

# 9. config: show_reset/show_age off, label
fresh_dirs
cat > "$T/cfg/config.toml" <<'EOF'
label = "ZAI"
show_reset = false
show_age = false
refresh_interval_secs = 300
EOF
OUT9=$(run http://127.0.0.1:8931/ok refresh --force)
check "config toggles" "ZAI 42%" "$OUT9"

# 9b. reset_style default = clock: exact local time, TZ pinned
fresh_dirs
cat > "$T/cfg/config.toml" <<'EOF'
show_age = false
EOF
OUT9B=$(TZ=UTC run http://127.0.0.1:8931/fixed refresh --force)
check "reset clock style (TZ=UTC)" "GLM 42% · ⏰ 00:00:00" "$OUT9B"

# 9c. reset_style = duration keeps the old "1d12h"
fresh_dirs
cat > "$T/cfg/config.toml" <<'EOF'
reset_style = "duration"
EOF
OUT9C=$(run http://127.0.0.1:8931/ok refresh --force)
case "$OUT9C" in
    "GLM 42% · 1d12h"*" ago") ok "reset duration style: $OUT9C" ;;
    *) bad "reset duration style: [$OUT9C]" ;;
esac

# 9d. right_margin appended verbatim (byte compare, 2 spaces; direct capture)
fresh_dirs
cat > "$T/cfg/config.toml" <<'EOF'
label = "M"
show_age = false
right_margin = "  "
EOF
python3 - "$T/state/state.json" <<'EOF'
import json, sys, time
json.dump({"fetched_at": int(time.time()), "percentage": None, "next_reset_ms": None,
           "level": None, "error": None, "error_at": None}, open(sys.argv[1], "w"))
EOF
HERDR_OC_QUOTA_API_URL=http://127.0.0.1:8931/500 HERDR_OC_QUOTA_AUTH_PATH="$T/auth.json" \
HERDR_OC_QUOTA_CONFIG="$T/cfg/config.toml" HERDR_OC_QUOTA_STATE_DIR="$T/state" \
"$BIN" status > "$T/out9d" 2>/dev/null
printf 'M …  \n' > "$T/exp9d"
cmp -s "$T/exp9d" "$T/out9d" && ok "right_margin appended (2 spaces)" \
    || bad "right_margin: got $(od -An -c "$T/out9d")"

# 9h. default margin is one U+2800 braille blank (ASCII space gets trimmed by herdr)
mkdir -p "$T/hcfg"; printf 'label = "M"\n' > "$T/hcfg/config.toml"
rm -rf "$T/hstate"; mkdir -p "$T/hstate"
python3 - "$T/hstate/state.json" <<'EOF'
import json, sys, time
json.dump({"fetched_at": int(time.time()), "percentage": None, "next_reset_ms": None,
           "level": None, "error": None, "error_at": None}, open(sys.argv[1], "w"))
EOF
HERDR_OC_QUOTA_API_URL=http://127.0.0.1:8931/500 HERDR_OC_QUOTA_AUTH_PATH="$T/auth.json" \
HERDR_OC_QUOTA_CONFIG="$T/hcfg/config.toml" HERDR_OC_QUOTA_STATE_DIR="$T/hstate" \
    "$BIN" status > "$T/out9h" 2>/dev/null
printf 'M …\342\240\200\n' > "$T/exp9h"
cmp -s "$T/exp9h" "$T/out9h" && ok "default margin is U+2800 braille blank" \
    || bad "default margin: got $(od -An -tx1 "$T/out9h")"

# 9e. config discovery: sibling of HERDR_CONFIG_PATH
fresh_dirs
mkdir -p "$T/h"
printf 'label = "SIB"\n' > "$T/h/oc-quota.toml"
python3 - "$T/state/state.json" <<'EOF'
import json, sys, time
json.dump({"fetched_at": int(time.time()), "percentage": None, "next_reset_ms": None,
           "level": None, "error": None, "error_at": None}, open(sys.argv[1], "w"))
EOF
OUT9E=$(HERDR_OC_QUOTA_API_URL=http://127.0.0.1:8931/500 HERDR_OC_QUOTA_AUTH_PATH="$T/auth.json" \
    HERDR_OC_QUOTA_STATE_DIR="$T/state" HERDR_CONFIG_PATH="$T/h/config.toml" "$BIN" status \
    | fl)
check "config sibling of HERDR_CONFIG_PATH" "SIB …" "$OUT9E"

# 9f. config discovery: XDG_CONFIG_HOME/herdr/oc-quota.toml
H2="$T/home2"
mkdir -p "$T/xdg/herdr" "$H2"
printf 'label = "XDG"\n' > "$T/xdg/herdr/oc-quota.toml"
OUT9F=$(env -u HERDR_OC_QUOTA_CONFIG -u HERDR_CONFIG_PATH HOME="$H2" XDG_CONFIG_HOME="$T/xdg" \
    HERDR_OC_QUOTA_API_URL=http://127.0.0.1:8931/500 HERDR_OC_QUOTA_AUTH_PATH="$T/auth.json" \
    HERDR_OC_QUOTA_STATE_DIR="$T/state" "$BIN" status | fl)
check "config via XDG_CONFIG_HOME" "XDG …" "$OUT9F"

# 9g. config discovery: legacy ~/.config/herdr-oc-quota fallback
mkdir -p "$H2/.config/herdr-oc-quota"
printf 'label = "OLD"\n' > "$H2/.config/herdr-oc-quota/config.toml"
OUT9G=$(env -u HERDR_OC_QUOTA_CONFIG -u HERDR_CONFIG_PATH -u XDG_CONFIG_HOME HOME="$H2" \
    HERDR_OC_QUOTA_API_URL=http://127.0.0.1:8931/500 HERDR_OC_QUOTA_AUTH_PATH="$T/auth.json" \
    HERDR_OC_QUOTA_STATE_DIR="$T/state" "$BIN" status | fl)
check "legacy config fallback" "OLD …" "$OUT9G"
rm -rf "$H2/.config/herdr-oc-quota"

# 10. concurrent status calls (flock non-blocking, single fetch, no hang)
fresh_dirs
PIDS=""
for i in 1 2 3 4 5; do
    HERDR_OC_QUOTA_API_URL=http://127.0.0.1:8931/ok HERDR_OC_QUOTA_AUTH_PATH="$T/auth.json" \
    HERDR_OC_QUOTA_CONFIG="$T/cfg/config.toml" HERDR_OC_QUOTA_STATE_DIR="$T/state" \
    "$BIN" status >/dev/null 2>&1 & PIDS="$PIDS $!"
done
for p in $PIDS; do wait "$p"; done
OUT10=$(run http://127.0.0.1:8931/ok status)
case "$OUT10" in "GLM 42%"*" ago") ok "concurrent status ok: $OUT10" ;; *) bad "concurrent: [$OUT10]" ;; esac

# ---------- install / uninstall fixtures ----------
strip_trailing_blanks() { awk ' {lines[++n]=$0} END{for(i=n;i>0;i--){if(lines[i]~/^[ \t]*$/)n--;else break} for(i=1;i<=n;i++)print lines[i]}' "$1"; }
toml_has() { # file [expected_pos|absent]
    python3 -c "
import sys, tomllib
d = tomllib.load(open(sys.argv[1], 'rb'))
ui = d.get('ui', {})
r = ui.get('tab_bar_right', [])
want = sys.argv[2] if len(sys.argv) > 2 else 'absent'
if want == 'absent': assert 'tab_bar_position' not in ui, 'pos should be absent'
else: assert ui.get('tab_bar_position') == want, 'pos ' + want
assert r and r[0]['type'] == 'command' and r[0]['interval_seconds'] == 30 and r[0]['timeout_seconds'] == 25, 'right'
assert '/target/release/herdr-oc-quota status' in r[0]['command'], 'cmd'
print('OK')" "$@"; }

fixture_test() { # name [expected_pos]
    FIX="$T/$1.toml"; ORIG="$T/$1.orig"
    HERDR_CONFIG_PATH="$FIX" "$PLUGIN/install.sh" --no-link --no-refresh >/dev/null 2>&1
    if [ ! -f "$FIX.herdr-oc-quota.bak" ]; then bad "$1: no backup created"; return; fi
    V=$(toml_has "$FIX" "${2:-absent}" 2>&1) && ok "$1: toml structure" || bad "$1: toml structure: $V"
    [ -f "$T/oc-quota.toml" ] && ok "$1: plugin config seeded in herdr dir" || bad "$1: oc-quota.toml missing"
    HERDR_CONFIG_PATH="$FIX" timeout 15 herdr config check >/dev/null 2>&1 && ok "$1: herdr config check" || bad "$1: herdr config check"
    HERDR_CONFIG_PATH="$FIX" "$PLUGIN/install.sh" --no-link --no-refresh >/dev/null 2>&1
    N=$(grep -c 'herdr-oc-quota' "$FIX")
    [ "$N" = 1 ] && ok "$1: reinstall idempotent (1 marked line)" || bad "$1: reinstall has $N marked lines"
    HERDR_CONFIG_PATH="$FIX" "$PLUGIN/uninstall.sh" --no-unlink >/dev/null 2>&1
    if diff <(strip_trailing_blanks "$ORIG") <(strip_trailing_blanks "$FIX") >/dev/null; then
        ok "$1: uninstall restores original"
    else
        bad "$1: uninstall mismatch"; diff <(cat "$ORIG") <(cat "$FIX") | sed 's/^/    /'
    fi
    [ ! -f "$FIX.herdr-oc-quota.bak" ] && ok "$1: backup removed" || bad "$1: backup left behind"
    [ -f "$T/oc-quota.toml" ] && ok "$1: uninstall keeps oc-quota.toml" || bad "$1: oc-quota.toml removed"
}

# herdr's schema is strict: only real [ui] keys validate, so fixtures use them.
cat > "$T/a.orig" <<'EOF'
[ui]
tab_bar_position = "top"
tab_bar_right_separator = " | "
tab_bar_right = [
  { type = "hostname" },
  { type = "datetime" },
]
EOF
cp "$T/a.orig" "$T/a.toml"
fixture_test a top

cat > "$T/b.orig" <<'EOF'
# my herdr config (no [ui] table yet)

# managed by hand
EOF
cp "$T/b.orig" "$T/b.toml"
fixture_test b

: > "$T/c.orig"
cp "$T/c.orig" "$T/c.toml"
fixture_test c

# d. install migrates legacy ~/.config/herdr-oc-quota/config.toml
rm -f "$T/oc-quota.toml"
mkdir -p "$T/home3/.config/herdr-oc-quota"
printf 'label = "MIG"\nrefresh_interval_secs = 120\n' > "$T/home3/.config/herdr-oc-quota/config.toml"
printf '[ui]\ntab_bar_position = "top"\n' > "$T/d.toml"
# capture the real toolchain homes BEFORE overriding HOME (assignments in one
# command prefix are sequential; later ones would see the overridden $HOME)
REAL_CARGO="${CARGO_HOME:-$HOME/.cargo}"
REAL_RUSTUP="${RUSTUP_HOME:-$HOME/.rustup}"
HOME="$T/home3" CARGO_HOME="$REAL_CARGO" RUSTUP_HOME="$REAL_RUSTUP" \
    HERDR_CONFIG_PATH="$T/d.toml" "$PLUGIN/install.sh" --no-link --no-refresh >/dev/null 2>&1
grep -q 'tab_bar_position = "top"' "$T/d.toml" \
    && ok "user's tab_bar_position preserved (no forced bottom)" || bad "user tab_bar_position clobbered"
[ -f "$T/oc-quota.toml" ] && grep -q 'label = "MIG"' "$T/oc-quota.toml" \
    && ok "install migrates legacy config" || bad "install migration failed"
[ ! -e "$T/home3/.config/herdr-oc-quota" ] && ok "legacy config dir removed" || bad "legacy dir kept"

printf '\nPASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
