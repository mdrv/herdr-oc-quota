//! herdr-oc-quota — GLM / Z.AI Coding Plan quota indicator for the Herdr tab bar.
//!
//! Subcommands:
//!   status            print ONE status line for tab_bar_right (fetches if stale)
//!   refresh [--force] fetch now (blocking lock) and print the status line
//!
//! The Z.AI key is read from OpenCode's auth store
//! (~/.local/share/opencode/auth.json, provider `zai-coding-plan`); OpenCode
//! itself does not need to be running.
//!
//! State:  ~/.local/state/herdr-oc-quota/state.json  (atomic tmp+rename writes)
//! Config: ~/.config/herdr/oc-quota.toml (sibling of herdr's own config.toml)
//!
//! `status` never fails: errors are rendered inline so the tab bar segment is
//! never blanked by a transient problem; `!` marks stale (last-good) data.

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::exit;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

// ---------- config ----------

struct Config {
    refresh_interval_secs: i64,
    request_timeout_secs: u64,
    label: String,
    show_reset: bool,
    reset_style: String,
    show_age: bool,
    right_margin: String,
    auth_json_path: Option<PathBuf>,
}

fn home_path(rel: &str) -> PathBuf {
    let home = std::env::var_os("HOME") // unix
        .or_else(|| std::env::var_os("USERPROFILE")) // windows
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    home.join(rel)
}

/// Plugin config file: sibling of herdr's config.toml, mirroring herdr's own
/// resolution (HERDR_CONFIG_PATH, then XDG_CONFIG_HOME, then ~/.config).
fn config_file() -> PathBuf {
    if let Some(p) = std::env::var_os("HERDR_OC_QUOTA_CONFIG") {
        return PathBuf::from(p);
    }
    if let Some(p) = std::env::var_os("HERDR_CONFIG_PATH") {
        if let Some(dir) = PathBuf::from(&p).parent() {
            return dir.join("oc-quota.toml");
        }
    }
    if let Some(xdg) = std::env::var_os("XDG_CONFIG_HOME") {
        if !xdg.is_empty() {
            return PathBuf::from(xdg).join("herdr/oc-quota.toml");
        }
    }
    home_path(".config/herdr/oc-quota.toml")
}

/// Pre-`~/.config/herdr/oc-quota.toml` location, still read as a fallback.
fn legacy_config_file() -> PathBuf {
    if let Some(p) = std::env::var_os("HERDR_OC_QUOTA_CONFIG_DIR") {
        return PathBuf::from(p).join("config.toml");
    }
    home_path(".config/herdr-oc-quota/config.toml")
}

fn state_dir() -> PathBuf {
    std::env::var_os("HERDR_OC_QUOTA_STATE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| home_path(".local/state/herdr-oc-quota"))
}

fn auth_json_path(cfg: &Config) -> PathBuf {
    if let Some(p) = std::env::var_os("HERDR_OC_QUOTA_AUTH_PATH") {
        return PathBuf::from(p);
    }
    if let Some(p) = &cfg.auth_json_path {
        return p.clone();
    }
    home_path(".local/share/opencode/auth.json")
}

fn api_url() -> String {
    std::env::var("HERDR_OC_QUOTA_API_URL")
        .unwrap_or_else(|_| "https://api.z.ai/api/monitor/usage/quota/limit".to_string())
}

impl Config {
    fn load() -> Config {
        let mut cfg = Config {
            refresh_interval_secs: 300,
            request_timeout_secs: 20,
            label: "GLM".to_string(),
            show_reset: true,
            reset_style: "clock".to_string(),
            show_age: true,
            right_margin: "\u{2800}".to_string(),
            auth_json_path: None,
        };
        let text = match fs::read_to_string(config_file()) {
            Ok(text) => text,
            // graceful fallback for pre-migration installs
            Err(_) => fs::read_to_string(legacy_config_file()).unwrap_or_default(),
        };
        if text.is_empty() {
            return cfg;
        }
        let Ok(value) = text.parse::<toml::Value>() else {
            return cfg; // malformed config → defaults
        };
        let Some(table) = value.as_table() else {
            return cfg;
        };
        if let Some(v) = table
            .get("refresh_interval_secs")
            .and_then(toml::Value::as_integer)
        {
            if v > 0 {
                cfg.refresh_interval_secs = v;
            }
        }
        if let Some(v) = table
            .get("request_timeout_secs")
            .and_then(toml::Value::as_integer)
        {
            if v > 0 {
                cfg.request_timeout_secs = v as u64;
            }
        }
        if let Some(v) = table.get("label").and_then(toml::Value::as_str) {
            if !v.is_empty() {
                cfg.label = v.to_string();
            }
        }
        if let Some(v) = table.get("show_reset").and_then(toml::Value::as_bool) {
            cfg.show_reset = v;
        }
        if let Some(v) = table.get("reset_style").and_then(toml::Value::as_str) {
            if v == "duration" {
                cfg.reset_style = "duration".to_string();
            } // "clock" (or unknown) keeps the default
        }
        if let Some(v) = table.get("show_age").and_then(toml::Value::as_bool) {
            cfg.show_age = v;
        }
        if let Some(v) = table.get("right_margin").and_then(toml::Value::as_str) {
            cfg.right_margin = v.to_string(); // "" disables the margin
        }
        if let Some(v) = table.get("auth_json_path").and_then(toml::Value::as_str) {
            if !v.is_empty() {
                cfg.auth_json_path = Some(PathBuf::from(v));
            }
        }
        cfg
    }
}

// ---------- time / formatting ----------

fn now_s() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Compact human duration: `45s`, `7m`, `3h12m`, `1d4h`.
fn fmt_dur(s: i64) -> String {
    let s = s.max(0);
    let (d, h, m) = (s / 86400, s % 86400 / 3600, s % 3600 / 60);
    if d >= 1 {
        format!("{d}d{h}h")
    } else if h >= 1 {
        format!("{h}h{m}m")
    } else if m >= 1 {
        format!("{m}m")
    } else {
        format!("{s}s")
    }
}

/// Local wall-clock time `HH:mm:ss` for an epoch instant (honors $TZ on unix;
/// uses the system timezone on windows).
#[cfg(unix)]
fn fmt_local_hms(epoch_s: i64) -> String {
    let t = epoch_s as libc::time_t;
    // SAFETY: localtime_r writes into `tm`, returning NULL only on failure.
    let tm = unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&t, &mut tm).is_null() {
            return "??:??:??".to_string();
        }
        tm
    };
    format!("{:02}:{:02}:{:02}", tm.tm_hour, tm.tm_min, tm.tm_sec)
}

#[cfg(windows)]
fn fmt_local_hms(epoch_s: i64) -> String {
    let t = epoch_s as libc::time_t;
    // SAFETY: localtime_s writes into `tm`, returning nonzero only on failure.
    let tm = unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_s(&mut tm, &t) != 0 {
            return "??:??:??".to_string();
        }
        tm
    };
    format!("{:02}:{:02}:{:02}", tm.tm_hour, tm.tm_min, tm.tm_sec)
}

fn fmt_pct(p: f64) -> String {
    let r = p.round();
    if (p - r).abs() < 1e-9 {
        format!("{}", r as i64)
    } else {
        format!("{p:.1}")
    }
}

/// Collapse to one line, trim, cap length (char-boundary safe).
fn one_line(s: &str, max_chars: usize) -> String {
    let flat: String = s
        .chars()
        .map(|c| {
            if c == '\n' || c == '\r' || c == '\t' {
                ' '
            } else {
                c
            }
        })
        .collect();
    let trimmed = flat.trim();
    if trimmed.chars().count() <= max_chars {
        trimmed.to_string()
    } else {
        trimmed.chars().take(max_chars).collect()
    }
}

// ---------- state ----------

fn state_file() -> PathBuf {
    state_dir().join("state.json")
}

fn read_state() -> Option<Value> {
    fs::read_to_string(state_file())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
}

fn write_state(v: &Value) {
    let dir = state_dir();
    if fs::create_dir_all(&dir).is_err() {
        return;
    }
    let tmp = dir.join(".state.tmp");
    let ok = (|| -> std::io::Result<()> {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(serde_json::to_string_pretty(v)?.as_bytes())?;
        f.sync_all()?;
        Ok(())
    })()
    .is_ok();
    if ok {
        let _ = fs::rename(&tmp, state_file());
    }
}

fn state_i64(v: &Value, key: &str) -> i64 {
    v.get(key).and_then(Value::as_i64).unwrap_or(0)
}

fn state_str(v: &Value, key: &str) -> String {
    v.get(key).and_then(Value::as_str).unwrap_or("").to_string()
}

/// Record a fetch failure while keeping the last good snapshot.
fn store_error(msg: &str) {
    let mut st = read_state().unwrap_or_else(|| {
        json!({"fetched_at": 0, "percentage": null, "next_reset_ms": null,
               "level": null, "error": null, "error_at": null})
    });
    st["error"] = Value::String(one_line(msg, 100));
    st["error_at"] = json!(now_s());
    write_state(&st);
}

// ---------- locking ----------
// Advisory exclusive non-blocking lock over the state "lock" file, so
// concurrent status/refresh processes serialize (flock on unix, LockFileEx
// via std's file-locking API on windows).

#[cfg(unix)]
fn try_flock(file: &fs::File) -> bool {
    use std::os::unix::io::AsRawFd;
    unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) == 0 }
}

#[cfg(windows)]
fn try_flock(file: &fs::File) -> bool {
    file.try_lock().is_ok()
}

fn with_state_lock(blocking: bool, f: impl FnOnce()) {
    if fs::create_dir_all(state_dir()).is_err() {
        f(); // best effort without lock
        return;
    }
    let Ok(file) = fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .open(state_dir().join("lock"))
    else {
        f();
        return;
    };
    let acquired = if blocking {
        // up to ~60s, retrying every 100ms
        (0..600).any(|_| {
            if try_flock(&file) {
                true
            } else {
                std::thread::sleep(Duration::from_millis(100));
                false
            }
        })
    } else {
        try_flock(&file)
    };
    if acquired {
        f(); // lock released when `file` drops
    } else if blocking {
        eprintln!("herdr-oc-quota: could not acquire state lock");
    }
}

// ---------- fetch ----------

fn read_api_key(cfg: &Config) -> Result<String, String> {
    let path = auth_json_path(cfg);
    let text = fs::read_to_string(&path)
        .map_err(|_| "cannot read OpenCode auth.json (log in via opencode once)".to_string())?;
    let v: Value =
        serde_json::from_str(&text).map_err(|_| "auth.json is not valid JSON".to_string())?;
    // NOTE: the key is never printed/logged.
    v.get("zai-coding-plan")
        .and_then(|p| p.get("key"))
        .and_then(Value::as_str)
        .filter(|k| !k.is_empty())
        .map(str::to_string)
        .ok_or_else(|| "no zai-coding-plan key in auth.json".to_string())
}

fn parse_and_store(body: &str) -> Result<(), String> {
    let v: Value = serde_json::from_str(body).map_err(|_| "invalid JSON from API".to_string())?;
    if let Some(data) = v.get("data") {
        let limits = data
            .get("limits")
            .and_then(Value::as_array)
            .ok_or_else(|| "no limits array in response".to_string())?;
        let limit = limits
            .iter()
            .find(|l| l.get("type").and_then(Value::as_str) == Some("TOKENS_LIMIT"))
            .ok_or_else(|| "no TOKENS_LIMIT entry in response".to_string())?;
        let pct = limit
            .get("percentage")
            .and_then(Value::as_f64)
            .ok_or_else(|| "no percentage in TOKENS_LIMIT".to_string())?;
        let next_reset_ms = limit
            .get("nextResetTime")
            .and_then(Value::as_f64)
            .map(|x| x as i64)
            .unwrap_or(0);
        let level = data
            .get("level")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        write_state(&json!({
            "fetched_at": now_s(),
            "percentage": pct,
            "next_reset_ms": next_reset_ms,
            "level": level,
            "error": null,
            "error_at": null,
        }));
        return Ok(());
    }
    // error-shape response: {code, msg}
    let code = v.get("code").and_then(Value::as_i64);
    let msg = v.get("msg").and_then(Value::as_str).unwrap_or("");
    if !msg.is_empty() {
        Err(format!(
            "API error: {}{}",
            msg,
            code.map(|c| format!(" (code {c})")).unwrap_or_default()
        ))
    } else {
        Err("unexpected response shape".to_string())
    }
}

fn fetch_and_store(cfg: &Config) {
    let result = (|| -> Result<(), String> {
        let key = read_api_key(cfg)?;
        let agent = ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(cfg.request_timeout_secs))
            .build();
        let resp = agent
            .get(&api_url())
            .set("Authorization", &key) // raw key, no Bearer prefix
            .call()
            .map_err(|e| match e {
                ureq::Error::Status(code, _) => format!("HTTP {code}"),
                other => other.to_string(),
            })?;
        let body = resp.into_string().map_err(|e| e.to_string())?;
        parse_and_store(&body)
    })();
    if let Err(msg) = result {
        store_error(&msg);
    }
}

// ---------- render ----------

fn render(cfg: &Config) {
    // trailing margin (U+2800 braille blank: space-like, not whitespace, so
    // herdr's output trimming keeps it); keeps the segment off the edge
    println!("{}{}", render_line(cfg), cfg.right_margin);
}

fn render_line(cfg: &Config) -> String {
    let Some(st) = read_state() else {
        return format!("{} …", cfg.label);
    };
    let now = now_s();
    let fetched_at = state_i64(&st, "fetched_at");
    let err = state_str(&st, "error");
    let pct = st.get("percentage").and_then(Value::as_f64);

    let Some(pct) = pct else {
        if !err.is_empty() {
            return format!("{} ✖ {}", cfg.label, one_line(&err, 60));
        }
        return format!("{} …", cfg.label);
    };

    let mut out = format!("{} {}%", cfg.label, fmt_pct(pct));
    let next_reset_ms = state_i64(&st, "next_reset_ms");
    if cfg.show_reset && next_reset_ms > 0 {
        let reset_s = next_reset_ms / 1000;
        let shown = if cfg.reset_style == "duration" {
            fmt_dur(reset_s - now)
        } else {
            // ⏰ marks this as the reset time, not the current clock
            format!("⏰ {}", fmt_local_hms(reset_s))
        };
        out += &format!(" · {shown}");
    }
    if cfg.show_age && fetched_at > 0 {
        out += &format!(" · {} ago", fmt_dur(now - fetched_at));
    }
    // `!` marks stale data (last refresh failed and/or data older than 2× interval)
    if !err.is_empty() || now - fetched_at >= cfg.refresh_interval_secs * 2 {
        out += " !";
    }
    out
}

// ---------- commands ----------

fn state_is_stale(cfg: &Config) -> bool {
    match read_state() {
        None => true,
        Some(st) => now_s() - state_i64(&st, "fetched_at") >= cfg.refresh_interval_secs,
    }
}

fn cmd_status() {
    let cfg = Config::load();
    if state_is_stale(&cfg) {
        with_state_lock(false, || {
            // re-check under lock: another process may have just refreshed
            if state_is_stale(&cfg) {
                fetch_and_store(&cfg);
            }
        });
    }
    render(&cfg);
}

fn cmd_refresh(force: bool) {
    let cfg = Config::load();
    with_state_lock(true, || {
        if force || state_is_stale(&cfg) {
            fetch_and_store(&cfg);
        }
    });
    render(&cfg);
}

fn usage() {
    println!("usage: herdr-oc-quota status | refresh [--force] | --version");
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None | Some("status") => cmd_status(),
        Some("refresh") => cmd_refresh(args.get(1).map(String::as_str) == Some("--force")),
        Some("-V") | Some("--version") | Some("version") => {
            println!("herdr-oc-quota {}", env!("CARGO_PKG_VERSION"));
        }
        Some("-h") | Some("--help") | Some("help") => usage(),
        Some(other) => {
            eprintln!("herdr-oc-quota: unknown command: {other}");
            usage();
            exit(2);
        }
    }
}
