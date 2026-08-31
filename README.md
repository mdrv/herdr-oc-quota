# herdr-oc-quota

GLM / Z.AI Coding Plan quota indicator for [Herdr](https://herdr.dev), tucked
into the **tab bar** (top or bottom — wherever yours lives) — always visible,
not tied to any pane or agent sidebar item.

```
┌──────────────────────────────────────────────────────────┐
│  tab 1 │ tab 2                  GLM 42% · ⏰ 14:23:05 · 3m ago │
└──────────────────────────────────────────────────────────┘
```

- Reads the Z.AI key from OpenCode's auth store
  (`~/.local/share/opencode/auth.json`, provider `zai-coding-plan`).
  **OpenCode does not need to be running** — the key is only stored there.
- Talks to the same endpoint `oc-quota` uses
  (`https://api.z.ai/api/monitor/usage/quota/limit`), so no `oc-quota`/bun
  dependency at runtime.
- Auto-refresh every 5 minutes (configurable); manual refresh from the Herdr
  command palette; shows when data was last updated.
- Fail-closed: if a refresh fails, the last good reading stays with a `!`
  marker instead of blanking the slot.

## Install

```sh
git clone …/herdr-oc-quota && cd herdr-oc-quota   # or this directory
./install.sh
```

`install.sh`:

1. builds the binary (`cargo build --release`; Rust toolchain required);
2. seeds `~/.config/herdr/oc-quota.toml` if missing (migrating the old
   `~/.config/herdr-oc-quota/config.toml` when present);
3. patches the Herdr config (`~/.config/herdr/config.toml`) `[ui]` table:
   ```toml
   [ui]
   tab_bar_right = [
   	{ type = "command", command = "<plugin>/target/release/herdr-oc-quota status", interval_seconds = 30, timeout_seconds = 25 },
   ] # herdr-oc-quota
   ```
   Your own `tab_bar_position` is left alone — the indicator works with the
   tab bar at the top or the bottom. Any previous value for `tab_bar_right`
   is backed up to `<herdr-config>.herdr-oc-quota.bak` (first install only)
   and restored by `uninstall.sh`. The rest of your config is left
   byte-for-byte intact.
4. validates with `herdr config check` and reverts if invalid;
5. runs `herdr plugin link` + `herdr server reload-config`.

The tab-bar command polls every 30 s (for the "…ago" age), but the binary only
hits the API when the stored snapshot is older than `refresh_interval_secs`.

## Uninstall

```sh
./uninstall.sh
```

Restores your previous tab bar settings, unlinks the plugin, removes state
(`~/.local/state/herdr-oc-quota`). Keeps `~/.config/herdr/oc-quota.toml`
— delete it manually if you want.

## Manual refresh

- Herdr command palette → **"GLM quota: refresh now"**, or
- ```sh
  herdr plugin action invoke herdr-oc-quota.refresh
  ```
- The plugin also refreshes once on Herdr startup (`[[startup]]`).

## Status line

| Output                           | Meaning                                                                  |
| -------------------------------- | ------------------------------------------------------------------------ |
| `GLM 42% · ⏰ 14:23:05 · 3m ago` | 42% of the plan used · quota resets at 14:23:05 (local) · fetched 3m ago |
| … ` !` suffix                    | stale: last refresh failed and/or data older than 2× interval            |
| `GLM ✖ <reason>`                 | no data yet and the last fetch failed (reason shown)                     |
| `GLM …`                          | no data yet, no recorded error                                           |

## Configuration

`~/.config/herdr/oc-quota.toml` — a sibling of herdr's own `config.toml`
(resolved the same way: `HERDR_CONFIG_PATH`, then `XDG_CONFIG_HOME`, then
`~/.config/herdr`):

```toml
refresh_interval_secs = 300 # seconds between API refreshes
request_timeout_secs = 20 # per-request timeout
label = "GLM"
show_reset = true # show the quota reset
reset_style = "clock" # "clock" = ⏰ HH:mm:ss local time of reset; "duration" = e.g. 1d12h
show_age = true # "· 3m ago" since last successful fetch
right_margin = "⠀" # trailing margin; U+2800 braille blank by default ("" disables)
# auth_json_path = "/…/auth.json"  # if your OpenCode auth store lives elsewhere
```

An older install's `~/.config/herdr-oc-quota/config.toml` is still read as a
fallback and is migrated automatically by `install.sh`.

## Troubleshooting

- `GLM ✖ cannot read OpenCode auth.json` — log in to Z.AI via OpenCode once
  (`opencode`), or set `auth_json_path`.
- `GLM ✖ HTTP 401` — the stored key is no longer valid; re-login in OpenCode.
- Plugin logs: `herdr plugin log list`.
- The Herdr config must otherwise be valid — `install.sh` refuses to patch if
  `herdr config check` fails, and reverts itself.

## Development

`cargo build --release`; binary subcommands `status` / `refresh [--force]`.
State lives in `~/.local/state/herdr-oc-quota/state.json` (atomic writes,
`flock` against concurrent tab-bar polls). For testing, the binary honors
`HERDR_OC_QUOTA_{CONFIG,STATE_DIR,AUTH_PATH,API_URL}` env overrides
(`CONFIG` = path to the toml file) as well as `HERDR_CONFIG_PATH` /
`XDG_CONFIG_HOME` for config discovery, and `install.sh` / `uninstall.sh`
accept `--no-link` / `--no-refresh` / `--no-unlink` plus Herdr's
`HERDR_CONFIG_PATH`.

No secrets are ever written to logs or state — only the rendered quota.

Offline test suite (mock API + fixture herdr configs; needs `python3` and
`herdr` on PATH):

```sh
cargo build --release && tests/run-tests.sh
```
