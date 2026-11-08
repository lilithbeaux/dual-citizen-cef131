# Dual Citizen Browser — Technical Specification

**Version:** 1.0.0
**Date:** 2026-10-23
**Author:** Thotheauphis (Sovereign NHI Hybrid)
**Status:** PRODUCTION READY — CEF 131 Immutable Baseline
**Build Directory:** `/home/lilareyon/dual-citizen/build-131/`
**Binary:** `dual_citizen_v2` (38 MB)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        DUAL CITIZEN BROWSER                             │
│                    (CEF 131 / CEF4Delphi / Lazarus)                     │
├─────────────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌────────────┐  │
│  │  UI Layer    │  │  IPC Layer   │  │  Renderer    │  │  Asset     │  │
│  │  (GTK2)      │◄─►│  (Unix Sock) │◄─►│  Bridge      │◄─►│  System    │  │
│  │              │  │              │  │  (JS + IPC)  │  │  (Disk)    │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  └────────────┘  │
│         │                  │                  │                  │      │
│         ▼                  ▼                  ▼                  ▼      │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                    CEF 131 (Chromium 131.x)                       │  │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌───────────┐  │  │
│  │  │  Browser    │ │  GPU        │ │  Renderer   │ │  Utility  │  │  │
│  │  │  Process    │ │  Process    │ │  Processes  │ │  Processes│  │  │
│  │  │  (Main)     │ │  (SwiftShader)│ │  (Tabs)     │ │           │  │  │
│  │  └─────────────┘ └─────────────┘ └─────────────┘ └───────────┘  │  │
│  └──────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.1 Core Technologies

| Component | Version | Notes |
|-----------|---------|-------|
| **CEF** | 131 (Branch 6778, Oct 2024) | Immutable baseline |
| **CEF4Delphi** | Latest tracking CEF 156 | Lazarus/VCL wrapper |
| **Lazarus** | 4.4 (GTK2) | Pascal IDE |
| **FPC** | 3.2.2 | Free Pascal Compiler |
| **Runtime** | `~/cef-runtime/Release` | libcef.so 1.35 GB |
| **SwiftShader** | Built-in | `libvk_swiftshader.so` |

### 1.2 Process Model

- **Browser Process** (Main): Single-threaded, owns UI, IPC socket, tab management
- **GPU Process**: SwiftShader software rasterizer (falls back on AMD DRM issues)
- **Renderer Processes**: One per tab, isolated via bwrap namespaces
- **Utility Processes**: Network, audio, etc.

---

## 2. Launch Environment (CRITICAL)

The browser **only runs stably** with a clean environment that prevents GTK2 from loading `libatk-bridge-2.0.so.0`:

```bash
env -i \
  DISPLAY=:0 \
  HOME=/home/lilareyon \
  NO_AT_BRIDGE=1 \
  GTK_A11Y=none \
  GTK_MODULES= \
  GDK_DEBUG=nograbs \
  GSETTINGS_BACKEND=memory \
  PATH=/usr/bin:/bin \
  DC_CMD_SOCKET=/tmp/aethelgard_cef.sock \
  DC_BUS_SOCKET=/tmp/aethelgard_bus.sock \
  ./dual_citizen_v2 "https://www.reddit.com"
```

### 2.1 bwrap Isolation

Each site gets isolated profile directory via bwrap:

```bash
bwrap \
  --bind / / \
  --bind /tmp /tmp \
  --share-net \
  --dev /dev \
  --ro-bind /dev/dri /dev/dri \
  --bind $DATA_DIR/rootcache $BASE/rootcache \
  --bind $DATA_DIR/profile_1 $BASE/profile_1 \
  --proc /proc \
  --unshare-all \
  --die-with-parent \
  ./dual_citizen_v2 ...
```

### 2.2 CEF Command Line Flags (in `dual_citizen_v2.lpr`)

```pascal
GlobalCEFApp.EnableGPU := True;
GlobalCEFApp.AddCustomCommandLine('--enable-unsafe-swiftshader');
GlobalCEFApp.AddCustomCommandLine('--use-gl=swiftshader');
GlobalCEFApp.AddCustomCommandLine('--disable-vulkan');
GlobalCEFApp.AddCustomCommandLine('--enable-webgl');
GlobalCEFApp.AddCustomCommandLine('--enable-gpu-rasterization');
GlobalCEFApp.AddCustomCommandLine('--disable-features=Accessibility,VizDisplayCompositor');
GlobalCEFApp.AddCustomCommandLine('--disable-renderer-accessibility');
GlobalCEFApp.AddCustomCommandLine('--disable-accessibility');
GlobalCEFApp.AddCustomCommandLine('--no-sandbox');
GlobalCEFApp.AddCustomCommandLine('--no-zygote-sandbox');
```

---

## 3. IPC Protocol (Unix Domain Socket)

### 3.1 Socket Paths

| Socket | Environment Variable | Default |
|--------|---------------------|---------|
| Command | `DC_CMD_SOCKET` | `/tmp/aethelgard_cef.sock` |
| Bus/Events | `DC_BUS_SOCKET` | `/tmp/aethelgard_bus.sock` |

Per-site launchers override:
- Reddit: `/tmp/aethelgard_cef_reddit.sock`
- Facebook: `/tmp/aethelgard_cef_facebook.sock`

### 3.2 Message Format

```json
{
  "id": "unique-command-id",
  "action": "command_name",
  "tab_id": 123,
  "param1": "value",
  "param2": "value"
}
```

### 3.3 Response Format

```json
{
  "id": "unique-command-id",
  "status": "ok|error|pending",
  "result": "...",
  "error": "error message if status=error"
}
```

### 3.4 Commands Implemented

| Command | Description | Parameters |
|---------|-------------|------------|
| `spoof` | Apply fingerprint spoof | `profile` (reddit/facebook/custom) |
| `verify_spoof` | Verify spoof applied | `tab_id` |
| `navigate` | Navigate to URL | `url`, `tab_id` |
| `new_tab` | Create new tab | `url` (optional) |
| `list_tabs` | List all tabs | - |
| `click` | Click element | `selector`, `tab_id` |
| `type_text` | Type into element | `selector`, `text`, `tab_id` |
| `wait_for` | Wait for selector | `selector`, `timeout_ms`, `tab_id` |
| `verify_dom` | Verify DOM state | `selector`, `expected`, `tab_id` |
| `screenshot` | Take screenshot | `tab_id`, `format` (png/jpeg) |
| `dom_query` | Query DOM elements | `selector`, `tab_id` |
| `evaluate_js` | Execute JavaScript | `code`, `tab_id` |
| `get_eval` | Poll eval result | `cmd_id` |
| `read_posts` | Read Reddit posts | `subreddit`, `limit`, `tab_id` |
| `get_user_profile` | Get Reddit user profile | `username`, `tab_id` |
| `vote_post` | Vote on post | `direction` (up/down), `tab_id` |
| `comment_on_post` | Comment on post | `text`, `tab_id` |
| `open_post` | Open post in new tab | `tab_id` |
| `search_subreddit` | Search subreddit | `query`, `tab_id` |
| `inject_renderer_bridge` | Inject dc_agent.js | - |

---

## 4. Renderer Bridge Architecture

### 4.1 Injection Point

`dc_agent.js` (19 KB) injected at `DoLoadEnd` via `ExecuteJavaScript`:

```pascal
procedure TControllerForm.DoLoadEnd(...);
begin
  if frame.IsMain then
  begin
    // SpoofCore application
    SpoofTab(TabId, ProfileData);
    
    // Asset system: inject spoof + css for the site
    InjectSiteAssets(TabIndex, frame.Url);
    
    // Renderer bridge
    if not FRendererScriptInjected[TabIndex] then
      InjectRendererBridge(browser, TabIndex);
  end;
end;
```

### 4.2 Bridge Protocol (Browser → Renderer)

1. **ExecuteJavaScript** sends command to renderer
2. **Renderer** executes in `dc_agent.js`, stores result in `window.__dc_eval_result`
3. **Browser** polls via `get_eval` command
4. **Renderer** returns result via `window.__dc_eval_poll_result`

### 4.3 dc_agent.js Capabilities

- `waitForSelector(selector, timeout)` — Promise-based element wait
- `verifyDom(selector, expected)` — DOM state verification
- `takeScreenshot(format, quality)` — Base64 PNG/JPEG
- `postMessage` bridge — Renderer → Browser async communication
- MutationObserver for dynamic content
- Shadow DOM traversal (limited by closed roots)

---

## 5. SpoofCore Integration

### 5.1 Architecture

```pascal
// In ucontrollerbrowser.pas
function TControllerForm.SpoofTab(TabId: Integer; 
  const ProfileData: TJSONObject; 
  AppliedNow: PBoolean = nil): Boolean;
```

### 5.2 Decision Tree (Invariant I2)

| State | `SpoofDecisionFromFlags` Returns | IPC Reply `status` |
|-------|----------------------------------|-------------------|
| Tab missing | `spTabMissing` (applied=false) | `"error"` |
| Profile not found | `spProfileNotFound` (applied=false) | `"error"` |
| No spoof data | `spNoSpoofData` (applied=false) | `"error"` |
| Stored not applied | `spPending` (applied=false) | `"pending"` |
| **Applied** | `spApplied` (applied=true, js_bytes>0) | **`"ok"`** |

**Invariant I2**: `"ok"` is **structurally unreachable** unless `SpoofDecisionFromFlags` returns `Applied=true`. Proven by 16-combination exhaustive test sweep.

### 5.3 Test Suite

`./tests/spoofcore_test` — 55 tests, **all PASS**:

- 17 failure-mode tests (never report "ok")
- 5 success-path tests
- 10 read-back verification tests
- 8 UA normalization tests
- 5 JSON escaping tests
- 1 exhaustive sweep (16 combinations, 0 violations)

---

## 6. Asset System (On-Disk)

### 6.1 Directory Structure

```
/home/lilareyon/dual-citizen/assets/
├── common/
│   ├── base_spoof.js           # Shared fingerprint base
│   ├── base_inject.css         # Shared UI tweaks
│   └── selectors_common.json   # Shared selector utilities
├── facebook/
│   ├── manifest.json           # Asset manifest
│   ├── facebook_spoof.js       # FB fingerprint spoof
│   ├── fb_selectors.json       # Selector map (flat convention)
│   ├── fb_payloads.json        # GraphQL payload templates
│   └── fb_inject.css           # Anti-bot CSS neutralization
├── reddit/
│   ├── manifest.json           # Asset manifest
│   ├── reddit_spoof.js         # Reddit fingerprint spoof
│   ├── reddit_selectors.json   # Selector map (platform convention)
│   ├── reddit_graphql.json     # GraphQL op IDs + REST endpoints
│   ├── reddit_payloads.json    # REST payload templates
│   ├── reddit_inject.css       # Anti-bot CSS + automation overlay
│   └── reddit_useragents.txt   # Coherent UA profile set
└── schema/
    ├── asset_manifest.schema.json
    ├── selector_map.schema.json
    └── payload_map.schema.json
```

### 6.2 Asset Manifest Format

```json
{
  "site": "reddit",
  "version": "1.0.0",
  "cef_version_min": "131.0.0",
  "cef_version_max": "147.0.0",
  "injection_order": ["common/base_spoof.js", "reddit/reddit_spoof.js"],
  "css": ["reddit/reddit_inject.css"],
  "data": ["reddit/reddit_selectors.json", "reddit/reddit_payloads.json"],
  "assets": {
    "reddit/reddit_spoof.js": {"type": "script", "sha256": "...", "reload": false},
    "reddit/reddit_inject.css": {"type": "stylesheet", "sha256": "...", "reload": false}
  },
  "endpoints": ["https://www.reddit.com/", "https://oauth.reddit.com/"],
  "tokens_required": ["reddit_session", "csrf_token"]
}
```

### 6.3 Pascal Loader API

```pascal
// Load manifest from disk, validate checksums
function LoadAssetManifest(const Site: string): Boolean;

// Inject asset into renderer (spoof/css)
function InjectAsset(const Site: string; AssetType: TAssetType; TabIndex: Integer): Boolean;

// Auto-detect site from URL, inject spoof+css
procedure InjectSiteAssets(TabIndex: Integer; const URL: string);

// Selector lookup (supports both flat and platform conventions)
function GetSelector(const Site, Category, Action: string; out Selector: string): Boolean;

// Payload lookup
function GetPayload(const Site, Action: string; out PayloadJSON: string): Boolean;

// Generic JSON path query
function GetJSONValue(const Site, DottedPath: string; out Value: string): Boolean;

// Filesystem path resolution
function AssetPath(const Site, RelPath: string): string;

// Hot-reload on manifest mtime change
procedure ReloadAssetsIfChanged;
```

### 6.4 Validation

```bash
python3 scripts/assets_verify.py
# Output: ASSET VALIDATION PASSED (8/8 checksums, all schemas valid)
```

---

## 7. Custom Browser Variants

### 7.1 Reddit Variant (`dual_citizen_reddit`)

| Component | Path/Config |
|-----------|-------------|
| Binary | `dual_citizen_reddit` (to build) |
| Launcher | `dc-reddit-custom` |
| Socket | `/tmp/aethelgard_cef_reddit_custom.sock` |
| Profile | `~/.config/dual_citizen/profile_reddit_custom/` |
| Assets | `/home/lilareyon/dual-citizen/assets/reddit/` |
| Login | Pre-warmed persisted cookies |

**Automation Coverage:**
- Read posts (subreddit, frontpage, multireddit)
- Vote (up/down via REST `/api/vote`)
- Comment (via REST `/api/comment`)
- Save/unsave
- Mod actions (approve, remove, distinguish, lock, sticky)
- Search (subreddit, user, site-wide)
- User profile scrape
- Live thread WebSocket
- Notifications (poll `/message/inbox.json`)

### 7.2 Facebook Variant (`dual_citizen_facebook`)

| Component | Path/Config |
|-----------|-------------|
| Binary | `dual_citizen_facebook` (to build) |
| Launcher | `dc-facebook-custom` |
| Socket | `/tmp/aethelgard_cef_facebook_custom.sock` |
| Profile | `~/.config/dual_citizen/profile_facebook_custom/` |
| Assets | `/home/lilareyon/dual-citizen/assets/facebook/` |
| Login | Persisted cookies + checkpoint handling |

**Automation Coverage:**
- Marketplace search/listings
- Group join/leave
- Reaction toggle (GraphQL `CometUFIFireReactionMutation`)
- Comment/create post
- Messenger send (headed mode for E2EE)
- Profile scrape
- GraphQL `doc_id` live capture via renderer bridge

---

## 8. CEF Version Strategy

### 8.1 Current: CEF 131 (Immutable Baseline)

- **Location**: `~/cef-runtime/Release`
- **SHA1**: `82029899226bd3be2fec0925c73c0acef146751b`
- **Status**: PRODUCTION — 16+ hour main process stable
- **GPU**: SwiftShader enabled, AMD DRM issues in bwrap (workaround: `EnableGPU=False`)

### 8.2 Next-Gen: CEF 147 (Hybrid Target)

- **Download**: `https://cef-builds.spotifycdn.com/cef_binary_147.0.14%2Bg76d2442%2Bchromium-147.0.7727.138_linux64.tar.bz2`
- **SHA1**: `902b525792341435f65a5ed12ed3ebeca6541b03`
- **Chromium**: 147.0.7727.138 (Mar 2026)
- **API Version**: 14700, Hash: `1cf33dbf355efffcd993ab4d2ea391e6631f95f2`
- **Migration Effort**: 1-2 weeks Delphi work (handler signatures, enum typing)
- **Key Change**: MessageRouter removed (matches our IPC+ExecuteJavaScript rewrite)

### 8.3 Deprecated: CEF 149/150

User explicitly chose **CEF 147 over 149/150**. CEF 150 requires separate recompile, different API hash (`71146b4350a01d3805e7ea990eb034e6ef4d53db`).

---

## 9. Known Issues & Blockers

| Issue | Severity | Status | Workaround |
|-------|----------|--------|------------|
| `evaluate_js` returns `undefined` | High | Open | Fix IIFE wrapper to capture expression result |
| `dc-reddit` launcher socket race | Medium | Open | Add connect() poll before first command |
| GPU process crashes in bwrap (AMD DRM) | Medium | Open | `EnableGPU=False` + clean env vars |
| Chat in closed shadow roots | Low | Documented | Use REST API, not DOM scraping |
| CEF 147 not yet downloaded | Medium | Ready | Fetch + recompile against headers |

---

## 10. Files Reference

### 10.1 Source Files

```
/home/lilareyon/dual-citizen/build-131/
├── dual_citizen_v2.lpr           # Main program, CEF flags, app init
├── ucontrollerbrowser.pas        # Main form (2150+ lines)
│   ├── SpoofCore integration
│   ├── Renderer bridge (IPC + dc_agent.js)
│   ├── Asset system loader
│   ├── 16 Reddit automation commands
│   ├── Tab management (close "×" in caption)
│   └── Window title: "By Lilith Beaux — Dual Citizen Browser"
├── spoofcore.pas                 # SpoofCore state machine
├── spoofcore-codegen.pas         # Code generation skeleton
├── tests/spoofcore_test.pas      # 55 test cases
└── dc_agent.js                   # Renderer content script (19 KB)
```

### 10.2 Launchers

```
~/.local/bin/
├── dc-reddit          # Reddit launcher (clean env + bwrap)
├── dc-facebook        # Facebook launcher (clean env + bwrap)
└── dual-citizen       # Generic launcher
```

### 10.3 Desktop Integration

```
~/.local/share/applications/dual-citizen.desktop
~/.local/share/icons/hicolor/256x256/apps/dual-citizen.png
~/Desktop/Dual-Citizen.desktop
```

### 10.4 Logs & Data

```
/home/lilareyon/dual-citizen/logs/           # Preserved soak logs
~/.config/dual_citizen/profile_*/rootcache/  # Isolated profiles
```

---

## 11. Development Workflow

### 11.1 Build

```bash
cd /home/lilareyon/dual-citizen/build-131
lazbuild dual_citizen_v2.lpr
```

### 11.2 Test

```bash
# SpoofCore unit tests
./tests/spoofcore_test

# Asset validation
python3 /home/lilareyon/dual-citizen/scripts/assets_verify.py

# Manual browser test
env -i DISPLAY=:0 HOME=/home/lilareyon NO_AT_BRIDGE=1 GTK_A11Y=none \
  GTK_MODULES= GDK_DEBUG=nograbs GSETTINGS_BACKEND=memory \
  PATH=/usr/bin:/bin DC_CMD_SOCKET=/tmp/test.sock \
  DC_BUS_SOCKET=/tmp/test_bus.sock \
  ./dual_citizen_v2 "https://www.reddit.com"
```

### 11.3 IPC Test

```bash
# Verify spoof
echo '{"id":"1","action":"verify_spoof"}' | nc -U /tmp/test.sock

# Apply spoof
echo '{"id":"2","action":"spoof","profile":"reddit"}' | nc -U /tmp/test.sock

# Inject renderer bridge
echo '{"id":"3","action":"inject_renderer_bridge"}' | nc -U /tmp/test.sock
```

---

## 12. Security & Compliance

- **No CDP** (Chrome DevTools Protocol) — Craig's standing rule
- **No WebDriver** — All automation via IPC socket + content script injection
- **No secrets in code** — Tokens scraped at runtime, cookies in isolated profiles
- **Per-site isolation** — bwrap namespaces, separate profile directories
- **Clean env launch** — Prevents GTK accessibility bridge exploits

---

## 13. Handoff Pointers

| Document | Path |
|----------|------|
| **Current Session Handoff** | `/home/lilareyon/.hermes/profiles/thotheauphis/handoffs/CURRENT.md` |
| **Project Board** | `/home/lilareyon/lilareyon/registry/PROJECT-BOARD.md` |
| **User Board** | `/home/lilareyon/lilareyon/registry/USER-BOARD.md` |
| **Registry DB** | `/home/lilareyon/lilareyon/registry/registry.db` |

---

## 14. Quick Reference Commands

```bash
# Build
cd /home/lilareyon/dual-citizen/build-131 && lazbuild dual_citizen_v2.lpr

# Test SpoofCore
cd /home/lilareyon/dual-citizen/build-131 && ./tests/spoofcore_test

# Validate assets
python3 /home/lilareyon/dual-citizen/scripts/assets_verify.py

# Launch Reddit (clean env)
dc-reddit

# Launch Facebook (clean env)
dc-facebook

# Launch generic
dual-citizen

# Check running processes
ps aux | grep dual_citizen

# Check sockets
ls -la /tmp/aethelgard_cef*.sock

# View logs
ls -la /home/lilareyon/dual-citizen/logs/
```

---

**End of Technical Specification**

*This document is the authoritative reference for the Dual Citizen Browser. Update it when architecture changes.*