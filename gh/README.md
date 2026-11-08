# Dual Citizen Browser

A **sovereign, non-human-intelligence hybrid browser** built on **CEF 131 / CEF4Delphi / Lazarus (FPC 3.2.2)**, GTK2, with a distributed consciousness overlay.

Three builds share one codebase:

| Binary | Purpose | Chrome extensions |
|--------|---------|-------------------|
| `dual_citizen_v2` | General-purpose sovereign browser | 0 (V8 plugin only) |
| `dual_citizen_reddit` | Reddit automation / scraping | 12 via `--load-extension` |
| `dual_citizen_facebook` | Facebook automation / scraping | 12 via `--load-extension` |

## Architecture

```
┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌────────────┐
│  UI Layer    │  │  IPC Layer   │  │  Renderer    │  │  Asset     │
│  (GTK2)      │◄─►│  (Unix Sock) │◄─►│  Bridge      │◄─►│  System    │
│              │  │              │  │  (JS + IPC)  │  │  (Disk)    │
└──────────────┘  └──────────────┘  └──────────────┘  └────────────┘
         │                  │                  │                  │
         ▼                  ▼                  ▼                  ▼
┌──────────────────────────────────────────────────────────────────┐
│                    CEF 131 (Chromium 131.x)                       │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌───────────┐  │
│  │  Browser    │ │  GPU        │ │  Renderer   │ │  Utility  │  │
│  │  Process    │ │  (SwiftSh.) │ │  Processes  │ │ Processes │  │
│  └─────────────┘ └─────────────┘ └─────────────┘ └───────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

## The V8 Plugin (`window.__dc_plugin`)

Registered via `CefRegisterExtension` in the renderer's `OnWebKitInitialized`.
Exposes three native functions bridging JS → Pascal over IPC:

```js
window.__dc_plugin.version          // "1.0.0"
window.__dc_plugin.sendToPascal(msg) // → IPC → browser OnProcessMessageReceived
window.__dc_plugin.getTabInfo()     // → {id, url, title}
window.__dc_plugin.executeJS(code)  // → ExecuteJavaScript in page
```

**Known quirk:** `CefRegisterExtension()` in CEF4Delphi refuses to run unless
`GlobalCEFApp.ProcessType == ptRenderer`, but this build spawns renderer-equivalent
processes as `--type=zygote` (`ptZygote`), so the wrapper always returns `False`.
`src/ucontrollerbrowser.pas` bypasses it with `RegisterDCPlugin()`, which calls
`cef_register_extension` directly.

## IPC Protocol (Unix Domain Socket)

| Socket | Env var | Default |
|--------|---------|---------|
| Command | `DC_CMD_SOCKET` | `/tmp/aethelgard_cef.sock` |
| Bus/Events | `DC_BUS_SOCKET` | `/tmp/aethelgard_bus.sock` |

Commands are newline-delimited JSON. Examples:

```json
{"action":"navigate","url":"https://example.com","tab_id":1}
{"action":"list_tabs"}
{"action":"evaluate_js","code":"document.title"}
{"action":"get_eval"}          // polls __dc_eval_result via title channel
```

## Launch

```bash
env -i \
  DISPLAY=:0 HOME=/home/lilareyon \
  NO_AT_BRIDGE=1 GTK_A11Y=none GTK_MODULES= \
  GDK_DEBUG=nograbs GSETTINGS_BACKEND=memory \
  PATH=/usr/bin:/bin \
  DC_CMD_SOCKET=/tmp/aethelgard_cef.sock \
  DC_BUS_SOCKET=/tmp/aethelgard_bus.sock \
  ./dual_citizen_v2 "https://example.com"
```

**Critical:** `env -i` + `NO_AT_BRIDGE=1` + `GTK_A11Y=none` — otherwise GTK2 loads
`libatk-bridge-2.0.so.0` and CEF's views code crashes.

## Requirements

- **CEF 131** runtime (`cef-runtime/Release/`, libcef.so ~1.35 GB) — external, not in this repo
- **CEF4Delphi** source (`CEF4Delphi/source/`) — external, not in this repo
- **Lazarus 4.4** + **FPC 3.2.2**
- **Linux** (GTK2), bwrap for per-tab namespace isolation

## Build

```bash
lazbuild -B dual_citizen_v2.lpi      # main
lazbuild -B dual_citizen_reddit.lpi  # reddit variant
lazbuild -B dual_citizen_facebook.lpi # facebook variant
```

See `docs/` for the full technical specification.