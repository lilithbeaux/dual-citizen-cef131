# Tier 2 — CEF 131 Native Plugin Specification
**Dual Citizen / Aethelgard Browser — Lilith-MCP Extension+Plugin**
Generated: 2026-10-28 | Status: Draft | Path: `/home/lilareyon/dual-citizen/build-131/PLUGIN_SPEC.md`

---

## 1. Overview

The plugin layer runs **inside the browser process** (Pascal side of `dual_citizen_v2`), exposing process-level dominion that no regular Chrome extension can touch:
- Request interception before bytes leave (`DoBeforeResourceLoad`)
- Custom scheme handlers (`mcp://`, `aethelgard://`, `agent://`) — already live
- V8 object injection (`window.__dc_plugin`) into every frame
- Frame/tab enumeration and per-tab control
- MCP JSON-RPC bridge over Unix socket (`/tmp/aethelgard_cef.sock`)

The extension (Tier 1) runs as a Chrome MV3 extension inside pages. Extension + plugin talk via MCP over the socket. The agent (Thotheauphis/Hermes) talks to both via the same socket.

---

## 2. Existing primitives (verified live)

| Primitive | Location | Status |
|-----------|----------|--------|
| Unix socket JSON-RPC (`/tmp/aethelgard_cef.sock`) | `ucontrollerbrowser.pas:ProcessCommands` / `HandleCommand` | Live, binary running PID 2801427 |
| Custom schemes `mcp://`, `aethelgard://`, `agent://` | `uCEFSchemeHandler.pas` | Live, 3 handlers registered via `CefRegisterSchemeHandlerFactory` |
| `dc_agent.js` MCPRegistry + JSON-RPC 2.0 | Injected into pages | Live |
| `cefQuery` router | `umessagebridge.pas` | Live (unit has pre-existing compile errors, blocks rebuild) |
| `MSG_TYPE_SCREENSHOT` plumbing | `umessagebridge.pas:646` | Present but not wired to socket commands |

**Research notes (CEF extension loading):**
- `--load-extension` command-line switch works with CEF but is being removed from Chrome 137+ branded builds. Our binary does not pass it at launch — extensions are loaded via `chrome://extensions/` UI instead, which is confirmed working (title "Extensions" resolved).
- Extensions loaded via `--load-extension` are marked with `kCommandLine` location; UI-loaded extensions use `kNormal`/`kDevelopment` locations.

---\n\n## 3. New primitives to add (Tier 2)

### 3.1 `DoBeforeResourceLoad` interception (new)

Add a `TCefResourceRequestHandler` to the form that intercepts every resource load **before** the request is issued. CEF4Delphi exposes `IChromiumEvents.DoBeforeResourceLoad` — hook it via `SetupRendererBridge` / `InjectRendererBridge` pattern already used.

**Pascal signature** (to add to `TControllerForm` private section):

```pascal
procedure DoBeforeResourceLoad(
  const browser: ICefBrowser; const frame: ICefFrame;
  const request: ICefRequest; const callback: ICefResourceRequestHandlerCallback;
  var result: TCefReturnValue);
```

**Behavior:**
- Examine `request.URL`, `request.Method`, headers
- Return `RV_CONTINUE` to proceed, `RV_CANCEL` to block, or modify `request` in place (redirect URL, inject headers, set post data)
- Correlate with pending MCP `screenshot` / `navigate` / `intercept` commands

**Interception modes** (MCP command params):
```json
{"action":"intercept","url_pattern":"*","mode":"cancel|redirect|modify","redirect_to":"...","headers":{"X-Dominion":"1"}}
```

### 3.2 `window.__dc_plugin` V8 injection (new)

Inject a global JS object into every frame's V8 context at `document_start`. Expose process-level API:

```js
window.__dc_plugin = {
  // Request interception (process level)
  intercept: (spec) => mcp.call("intercept", spec),
  // Frame enumeration
  frames: () => mcp.call("frame_list"),
  // Tab control
  tab: { id, url, title, goBack, goForward, reload, navigate },
  // Screenshot (process level, base64 PNG)
  screenshot: () => mcp.call("screenshot", {tab_id}).then(r => r.result),
  // Custom scheme fetch
  fetchMcp: (path) => fetch(`mcp://${path}`),
  // Eval with correlation (uses Tier 0 fixed channel)
  eval: (code) => mcp.call("evaluate_js", {code, tab_id}),
};
```

**CEF V8 injection research:** `CefRegisterExtension(name, code, ICefV8Handler)` registers a native JS extension available in every frame's context (CEF4Delphi `uCEFMiscFunctions.pas:144`). CEF Forum confirms this pattern for native JS↔Pascal bindings. Alternative: MV3 content script `world: "MAIN"` runs in page's JS context.

**MV3 content script notes** (for `content.js`):
- `run_at: "document_start"` — injects before any DOM/resources
- `all_frames: true` — injects into all iframes
- `world: "ISOLATED"` (default) — sandboxed from page scripts, shares DOM only
- `world: "MAIN"` — runs in page's JS context, can call page functions directly
- Service worker background cannot access DOM/window — use content script or offscreen document for DOM ops

### 3.3 Frame enumeration & per-tab control (new)

**Pascal signatures:**

```pascal
function FrameList(tabId: Integer): TJSONArray;  // [{frame_id, url, is_main, name}]
function TabControl(tabId: Integer; action: string; params: TJSONObject): string;
// actions: navigate, reload, go_back, go_forward, close, screenshot, eval
```

---

## 4. Extension ↔ Plugin communication

Both sides speak MCP JSON-RPC 2.0 over `/tmp/aethelgard_cef.sock`:

```
Extension content script → background.js → socket → HandleCommand → plugin/action → response → socket → background.js → content script
```

**Command flow:**
1. Content script calls `__lilithMCP.intercept({...})` → MCP command `intercept`
2. `background.js` forwards to socket → `HandleCommand` → Pascal `DoBeforeResourceLoad` registers pattern
3. Plugin intercepts matching resource → replies via socket → extension notified

**Event push** (for "listener" purpose):
- Plugin fires `DoTitleChange`, `DoAddressChange`, `OnBeforeResourceLoad` → `SendBusJSON('browser.event', ...)` → socket → extension background → content script on matching pages

---

## 5. Integration with dc_agent.js MCPRegistry

Existing methods (from `dc_agent.js`):
- `navigate`, `execute_javascript`, `get_title`, `get_url`, `click`, `form_fill`, `get_form_fields`, `go_back`, `go_forward`, `set_proxy`, `get_proxy`, `spoof`, `screenshot`, `get_screenshot`, `get_eval`

New plugin methods to register:
- `intercept` — register request interception pattern
- `frame_list` — enumerate frames in a tab
- `tab_control` — per-tab process-level action
- `plugin_eval` — eval via V8 injection channel

**Registration pattern** (content script):
```js
__lilithMCP.registerMethod("intercept", async (params) => {
  // forward to plugin via socket
  return await window.__lilithMCP.callAgentMethod("intercept", params);
});
```

---

## 6. What can be built now vs requires rebuild

| Can build now (no rebuild) | Requires rebuild |
|---------------------------|------------------|
| Extension loaded unpacked via `chrome://extensions/` | `DoBeforeResourceLoad` Pascal handler |
| `window.__lilithMCP` listener API on pages | `window.__dc_plugin` V8 injection |
| MCP commands via existing socket (`navigate`, `click`, `eval`, `screenshot` after Tier 0 fix) | `intercept`, `frame_list`, `tab_control` plugin methods |
| Extension background ↔ content script messaging | Rebuild of `ucontrollerbrowser.pas` + `umessagebridge.pas` |
| `chrome://extensions/` Load unpacked | Fix `umessagebridge.pas` pre-existing CEF message-router type errors |

---

## 7. Build blocker

`umessagebridge.pas` references `ICefMessageRouterBrowserSideCallback`, `ICefMessageRouterBrowserSide`, `TCefMessageRouterConfig` which do not exist in the installed CEF4Delphi version → **project cannot rebuild**. `ucontrollerbrowser.pas` compiles cleanly alone. Until `umessagebridge.pas` is fixed or excluded, plugin-side changes that depend on it cannot be compiled into the binary.

---

## 8. Recommended build order

1. **Fix `umessagebridge.pas`** (replace missing message-router types with cefQuery-based fallback) OR exclude it from the project
2. **Rebuild** with Tier 0 eval channel fix + Tier 2 `DoBeforeResourceLoad` + `window.__dc_plugin`
3. **Load unpacked extension** via `chrome://extensions/` → `extensions/lilith-mcp-listener/`
4. **Verify** `__lilithMCP` and `__dc_plugin` on a test page via socket

---
