// Lilith-MCP Listener — README

# Lilith-MCP Listener Extension

Programmable page listener for the CEF 131 Dual Citizen browser. Runs as a Chrome
extension (MV3) loaded via `chrome://extensions/` > "Load unpacked".

## Files

| File | Purpose |
|------|---------|
| `manifest.json` | MV3 manifest: webRequest, tabs, storage, scripting, all_urls |
| `content.js` | Content script injected into every page/frame (DOM, network, console, nav, visibility listeners + local MCP channel) |
| `background.js` | Service worker: relays events to agent, routes agent MCP commands to tabs |
| `popup.html` | Debug popup: list listeners, title, URL, form fields |

## What it listens for (programmable, any page)

- DOM mutations (`childList`, `subtree`, `attributes`)
- Network requests (`fetch` + `XHR` interception, request & response)
- Console messages (`log`, `warn`, `error`)
- Navigation / URL changes
- Visibility changes

## How the agent controls it

The external agent (Thotheauphis / Hermes) sends MCP JSON-RPC 2.0 commands over
the CEF Unix socket (`/tmp/aethelgard_cef.sock`):

```json
{"action": "register_listener", "params": {"type": "dom", "selector": "button#submit", "once": true}}
{"action": "click", "params": {"selector": "input[type=submit]"}}
{"action": "fill", "params": {"fields": {"user": "craig", "pass": "secret"}}}
{"action": "screenshot", "params": {}}
{"action": "navigate", "params": {"url": "https://example.com"}}
```

Events are pushed back (not polled) via `chrome.runtime.sendMessage` → background
worker → `mcp://control` POST → socket → agent.

## Install

1. Open `chrome://extensions/` in Dual Citizen.
2. Enable Developer mode (top right).
3. Click "Load unpacked" → select this directory.
4. The extension injects `content.js` into all open tabs and all new tabs.

## Notes

- `content.js` runs at `document_start` in ALL frames (iframes included).
- The local `window.__lilithMCP` object is the per-frame MCP endpoint.
- The background worker bridges tab-scoped commands via `chrome.runtime` ports
  with `chrome.scripting.executeScript` fallback.
- Requires CEF 131 with extension support enabled (verified: `chrome://extensions/` loads).
