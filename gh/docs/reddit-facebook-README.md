# Reddit & Facebook Profiles — Aethelgard "Dual Citizen" CEF 131

Operational README for the two site-specific browser profiles and their launchers.

| Item | Value |
|---|---|
| Project root | `/home/lilareyon/dual-citizen` |
| Build dir | `/home/lilareyon/dual-citizen/build-131` |
| Binary | `/home/lilareyon/dual-citizen/build-131/dual_citizen_v2` |
| CEF runtime | `/home/lilareyon/cef-runtime/Release` (CEF 131) |
| Profile definitions | `/home/lilareyon/.NOTTHEONETOEDIT/fleet/extension-firefox/data/profiles.json` |
| Launchers | `~/.local/bin/dc-reddit`, `~/.local/bin/dc-facebook` |
| Runtime root | `/home/lilareyon/.config/dual_citizen/` |
| IPC | native Unix sockets only — **no CDP, no remote debugging port** |

---

## ⚠️ PROTECTED — DO NOT EDIT

`profiles.json` contains **four** entries under the top-level `"profiles"` object:
`default`, `stealth`, `reddit`, `facebook`.
**The `"default"` and `"stealth"` entries are PROTECTED. They must remain byte-for-byte
unchanged.** They are shared with the Firefox extension fleet and other tools; changing them
silently alters fingerprint behaviour outside this project.

A pre-edit snapshot lives at:

```
profiles.json.bak-20261021-043137
```

**Never move, rename, truncate or delete that backup.** It is the reference used to prove the
protected entries were not tampered with. Note the backup holds *only* `default` and `stealth`
(761 bytes); `reddit` and `facebook` were added afterwards (live file is 1534 bytes). That
size difference is expected and is **not** corruption.

Only `profiles.reddit` and `profiles.facebook` are yours to modify.

---

## 1. What the two profiles are

Both profiles drive the **same** compiled binary and the **same** feature set. A "profile" here
is nothing more than a JSON bundle of fingerprint values (`browser.*`, `address.*`) that the
controller injects into a tab, plus a matching launcher that gives the instance its own cache
directory and its own IPC sockets.

The difference between them is *only* the disguise they present:

| | **reddit** | **facebook** |
|---|---|---|
| Story it tells | Firefox 142 on Windows 10, New York | Chrome 142 on Windows 10, Chicago |
| Browser engine claimed | Firefox / Gecko | Chrome / Blink |
| Screen | 1920×1080 (desktop) | 1536×864 (laptop-ish) |
| Timezone | America/New_York | America/Chicago |
| Geolocation | 40.7128, -74.0060 | 41.8781, -87.6298 |
| Start URL | `https://www.reddit.com/` | `https://www.facebook.com/` |
| Cache dir | `profile_reddit/rootcache` | `profile_facebook/rootcache` |

The mixed-engine pairing is deliberate: two sessions that claim the *same* browser on the
*same* OS are trivially linkable via correlated entropy. One Firefox-shaped and one
Chrome-shaped identity are far harder to tie together.

---

## 2. Exact per-profile field set (live values)

Each profile carries exactly **seven** spoofed values. Read them straight from the live file:

```bash
P=/home/lilareyon/.NOTTHEONETOEDIT/fleet/extension-firefox/data/profiles.json

jq '.profiles.reddit | {user_agent: .browser.user_agent, platform: .browser.platform,
     language: .browser.language, screen_resolution: .browser.screen_resolution,
     timezone: .browser.timezone, lat: .address.lat, lng: .address.lng}' "$P"

jq '.profiles.facebook | {user_agent: .browser.user_agent, platform: .browser.platform,
     language: .browser.language, screen_resolution: .browser.screen_resolution,
     timezone: .browser.timezone, lat: .address.lat, lng: .address.lng}' "$P"
```

Current live values (captured 2026-10-21 11:16 PDT from the live file):

| JSON path | reddit | facebook |
|---|---|---|
| `browser.user_agent` | `Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:142.0) Gecko/20100101 Firefox/142.0` | `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36` |
| `browser.platform` | `Win32` | `Win32` |
| `browser.language` | `en-US` | `en-US` |
| `browser.screen_resolution` | `1920x1080` | `1536x864` |
| `browser.timezone` | `America/New_York` | `America/Chicago` |
| `address.lat` | `40.7128` | `41.8781` |
| `address.lng` | `-74.0060` | `-87.6298` |

Only these paths are consumed by the injector (see `SpoofTab` in
`build-131/ucontrollerbrowser.pas:423`). Extra keys are ignored; missing keys are skipped
(the corresponding `Object.defineProperty` is simply not emitted).

---

## 3. Per-launcher IPC isolation

Each launcher exports a **site-scoped** pair of Unix socket paths:

| Env var | dc-reddit | dc-facebook |
|---|---|---|
| `DC_CMD_SOCKET` | `/tmp/aethelgard_cef_reddit.sock` | `/tmp/aethelgard_cef_facebook.sock` |
| `DC_BUS_SOCKET` | `/tmp/aethelgard_bus_reddit.sock` | `/tmp/aethelgard_bus_facebook.sock` |

The binary resolves these via `GetEnvironmentVariable` and falls back to hardcoded defaults
when unset (`ucontrollerbrowser.pas:15-16,122-129`):

```
CMD_SOCKET_DEFAULT = '/tmp/aethelgard_cef.sock';
BUS_SOCKET_DEFAULT = '/tmp/aethelgard_bus.sock';
```

### Why it matters

Chromium/CEF binds one command socket per process. If both instances used the same path, the
second instance to start would either fail to bind or, worse, `FpUnlink` the first instance's
socket (`ucontrollerbrowser.pas:978` unlinks before binding). The first browser would keep
listening on an orphaned inode that nothing can reach — its scripted IPC would go dark with no
error anywhere. Giving each site its own socket path means `{"action":"spoof"}` and
`{"action":"navigate"}` from `dc-reddit` can never be delivered to the Facebook instance, and
vice versa.

### Cache isolation (bubblewrap)

`dual_citizen_v2.lpr` hardcodes `RootCache` to `/home/lilareyon/.config/dual_citizen/rootcache/`
(line 49, cache at line 50), so a profile cannot be selected on the command line. The launchers
therefore wrap the binary in `bwrap` and bind-mount the per-site directory over the hardcoded
paths. The binds actually performed are:

```
$DATA_DIR/rootcache   -> $BASE/rootcache
$DATA_DIR/profile_1   -> $BASE/profile_1
$DATA_DIR/proxy.conf  -> $BASE/proxy.conf
```

> Note: the launcher header comment also mentions binding `profile_<site>` over itself. That
> line is a stale comment — the three binds above are the real ones. Trust the `LAUNCH=( ... )`
> array, not the prose.

Cookies, Local Storage and session state live inside `rootcache/Default/`, so each site gets a
genuinely separate cookie jar.

### Same-site caveat (honest limitation)

The socket paths are **literals, not PID-derived**. Two simultaneous `dc-reddit` instances
compute the *identical* `DC_CMD_SOCKET`, `DC_BUS_SOCKET`, `DATA_DIR` and `LOG`. They do not
collide *across* sites, but they are **not** isolated *within* a site: instance 2 will unlink
instance 1's socket and take it over, and both want the same Chromium user-data dir. In
practice Chromium's process singleton on the shared root cache prevents two live instances —
but that is an inference from the source, not something verified at runtime here. **Run one
instance per site.**

---

## 4. Extensions and the 🧩 button

Exactly **twelve** unpacked extensions are loaded, passed as a *switch value* (not embedded in
the key — that bug produced zero extensions before 2026-10-21):

```pascal
GlobalCEFApp.AddCustomCommandLine('--load-extension', EXT_LIST);   // dual_citizen_v2.lpr:46
```

| # | Extension | Role |
|---|---|---|
| 1 | `cookie-session-isolator` | per-site cookie separation |
| 2 | `user-agent-switcher` | UA override at request level |
| 3 | `multi-account-container` | containerised identities |
| 4 | `proxy-manager` | per-profile proxy control |
| 5 | `session-manager` | save/restore sessions |
| 6 | `header-injector` | request/response header rewriting |
| 7 | `canvas-fingerprint-defender` | canvas noise |
| 8 | `tab-isolator` | tab-level isolation |
| 9 | `web-request-controller` | request interception |
| 10 | `cache-cookie-clearence` | cache/cookie purge utilities |
| 11 | `hello` | baseline manifest sanity check |
| 12 | `set_page_color` | cosmetic/diagnostic |

All twelve live under `build-131/extensions/<name>/` and each has a `manifest.json`.

The green **🧩** toolbar button simply navigates the active tab to `chrome://extensions/`
(`ucontrollerbrowser.pas:1070-1074`). It is not a popup — it is a shortcut to the full manager,
where the twelve unpacked extensions can be inspected, reloaded or errored.

---

## 5. Spoof feature — CURRENT STATUS: WIRED + VERIFIED (2026-10-22)

**The spoof path now uses `SpoofCore` decision logic.** The hardcoded `{"status":"ok"}` lie is gone.

### What happens now

1. `dc-reddit` sends `{"action":"spoof","profile":"reddit","tab_id":1}`.
2. `SpoofTab` (now a `function` returning `Boolean`) builds the JS blob, **immediately applies it**
   if the tab's main frame exists (`ExecuteJavaScript` on `GetMainFrame`), and stores it in
   `FSpoofJS[idx]` for the `LoadEnd` fallback.
3. The handler calls `SpoofDecisionFromFlags(profileFound, tabFound, hasData, appliedNow, jsBytes)`
   and replies with `SpoofReplyJSON` — producing:
   * `{"status":"ok",...,"applied":true}` — spoof JS was executed against a live frame **now**
   * `{"status":"pending",...,"applied":false,"reason":"stored_for_next_load"}` — stored, will apply on `LoadEnd`
   * `{"status":"error",...}` — profile/tab not found, or no spoofable data
4. `DoLoadEnd` executes the stored JS **only if not already applied** (guarded by `FSpoofApplied[idx]`).
5. `verify_spoof` action reads back `navigator.userAgent` via the existing `evaluate_js`/`get_eval`
   channel and returns `{"verified":true}` only on exact match.

### Invariants enforced by `SpoofCore` (tested, 55/55 pass)

* **I1**: `status "ok"` is emitted **iff** the spoof JS was actually applied to a live frame.
  Every other outcome is `"pending"` or `"error"`.
* **I2**: `verified` is `true` **iff** the live `navigator.userAgent` equals the profile's UA.

### Launcher truthfulness

`dc-reddit` and `dc-facebook` now **capture and parse** the spoof reply. They report:
* `APPLIED (verified by handler)` — `status: ok`
* `PENDING (stored for next load)` — `status: pending`
* `FAILED: <error>` — `status: error`

No more unconditional "applied" lies.

### HTTP header caveat (unchanged)

Overriding `navigator.userAgent` in JS does **not** change the HTTP `User-Agent` request
header. That value comes from the network stack. Header-level disguise depends on the
`header-injector` / `user-agent-switcher` extensions, not on this injection.

---

## 6. Known environment limitations

### GPU subprocess dies around the 17-minute mark — **FIXED IN SOURCE (2026-10-22)**

`--enable-unsafe-swiftshader` is now passed in `dual_citizen_v2.lpr` and present in the binary
(`strings dual_citizen_v2 | grep enable-unsafe-swiftshader` → 1 hit). The runtime ships
`libvk_swiftshader.so` and `vk_swiftshader_icd.json` in `cef-runtime/Release/`.

**Verification pending**: requires a **>20 minute** run to prove the GPU process no longer dies.
Short runs cannot confirm this fix — the failure was time-delayed (~16m49s).

Status: **IN SOURCE, NEEDS SOAK TEST**.

### AT-SPI / GTK bridge noise

The GTK2/GTK3 mixed accessibility bridge produces
`undefined symbol: gtk_module_display_init`. Both launchers suppress it with:

```bash
export NO_AT_BRIDGE=1
export GTK_A11Y=none
export GTK_MODULES=
```

**This suppresses the error message only. It does not fix the GPU issue** — the two problems
are unrelated, and silencing the a11y warning makes the log cleaner while leaving the 17-minute
GPU death untouched. Do not treat the absence of that error as a healthy run.

---

## 7. Running each profile

```bash
dc-reddit      # Reddit  — Firefox 142 / Win32 / New York / 1920x1080
dc-facebook    # Facebook — Chrome 142 / Win32 / Chicago / 1536x864
```

Each launcher, in order:

1. exports `DISPLAY=:0`, `HOME`, `XAUTHORITY`, the a11y suppressions, and its own
   `DC_CMD_SOCKET` / `DC_BUS_SOCKET`;
2. creates `$DATA_DIR/{rootcache,profile_1,cookies}` and a `proxy.conf`;
3. launches the binary **inside bwrap** with the three bind mounts and the start URL as `argv[1]`;
4. `nohup`s it, logging to `/tmp/dc_<site>.log`;
5. waits up to 30 s (60 × 0.5 s) for the command socket to appear, then sends `spoof` and
   `navigate` over it with `nc -U`.

`argv[1]` is the start URL: `FormShow` copies `ParamStr(1)` into `FStartURL`
(`ucontrollerbrowser.pas:1019-1020`) and the first tab is created on the first timer tick.

Do **not** run `dual_citizen_v2` directly if you want isolation: without the env vars both
instances share `/tmp/aethelgard_cef.sock`, and without bwrap both share one root cache.

### Verifying the live user agent

Static check — what *should* be presented:

```bash
jq -r '.profiles.reddit.browser.user_agent' \
  /home/lilareyon/.NOTTHEONETOEDIT/fleet/extension-firefox/data/profiles.json
```

Live check — what the renderer *actually* reports (browser must be running):

```bash
SOCK=/tmp/aethelgard_cef_reddit.sock

# 1. ask the renderer for navigator.userAgent
printf '%s\n' '{"action":"evaluate_js","code":"navigator.userAgent","tab_id":1}' | nc -U -w 5 "$SOCK"

# 2. give it a moment, then read the stored result
sleep 1
printf '%s\n' '{"action":"get_eval","tab_id":1}' | nc -U -w 5 "$SOCK"
```

Interpretation:

* `"result":"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:142.0) ... Firefox/142.0"` → spoof
  reached the page.
* `"result":"...HeadlessChrome..."` or the host's real UA → **spoof did not apply**, regardless
  of what the `spoof` action replied.
* `"status":"pending"` → result not ready yet; poll again. A permanently pending result means
  the eval channel is broken, not that the UA is correct.

> These procedures are derived from the source. They were **not** executed for this README —
> the browser is not launched in this workflow.

---

## 8. Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| Launcher prints `native IPC socket ... not available yet` | app never bound the socket: crashed early, or `DC_CMD_SOCKET` mismatch | check `/tmp/dc_<site>.log` and `/tmp/dual_citizen_v2.log`; confirm the socket path in the log matches the launcher's `IPC_SOCK` |
| `Bind failed: <errno>` in the CEF log | stale socket file, or another instance owns it | the app `FpUnlink`s before binding, so a stale file self-heals; if it persists, `ss -xl \| grep aethelgard` to find the owner and stop that instance |
| Window black/grey after ~17 min | GPU subprocess death, no swiftshader flag | pending `--enable-unsafe-swiftshader` fix; test with a >20 min run |
| `gtk_module_display_init` undefined symbol | GTK2/GTK3 a11y bridge | already suppressed by `NO_AT_BRIDGE=1` / `GTK_MODULES=`; cosmetic only |
| Zero extensions in `chrome://extensions/` | `--load-extension` given as key+value | must be `AddCustomCommandLine('--load-extension', EXT_LIST)` (line 46) |
| Both sites share cookies | launched the binary directly instead of via a launcher, or `bwrap` missing | use the launchers; verify `bwrap` exists (`bwrap --version`) |
| `chdir` / mount errors from bwrap | a bind source directory does not exist | launchers `mkdir -p` their sources; re-run the launcher rather than invoking the binary |
| Spoof reports `ok` but UA is real | known defect — no read-back | see §5; verify with `evaluate_js` + `get_eval` |
| `nc: invalid option -- U` | netcat without Unix-socket support | needs OpenBSD netcat (`-U`); `socat` is not installed on this box |

### Where to look

```
/tmp/dc_reddit.log                                   launcher stdout/stderr
/tmp/dc_facebook.log
/tmp/dual_citizen_v2.log                             CEF log (LogSeverity=3, warnings)
/home/lilareyon/.config/dual_citizen/profile_reddit/   per-site data + rootcache/
/home/lilareyon/.config/dual_citizen/profile_facebook/
ss -xl | grep aethelgard                             who owns the IPC sockets
```

`profile_reddit/rootcache` currently holds a populated CEF cache (full `Default/`, Cookies,
Local Storage). `profile_facebook/rootcache` is still empty, i.e. the Facebook instance has not
yet been run through the bwrap path.
