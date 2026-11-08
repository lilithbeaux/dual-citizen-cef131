# Architecture

## Process model

CEF 131 runs as a multi-process Chromium. Three process types are spawned:

| Process | CEF type | Role |
|---------|----------|------|
| Browser | `ptBrowser` | GTK window, `OnProcessMessageReceived`, page lifecycle |
| Renderer | `ptZygote` (2) | Executes JS, runs V8 extensions, injects `window.__dc_plugin` |
| GPU | — | SwiftShader software GL |

**Critical detail:** this build spawns renderer-equivalent processes as `--type=zygote`
(`GlobalCEFApp.ProcessType == ptZygote`), not `ptRenderer`. CEF4Delphi's
`CefRegisterExtension()` wrapper refuses to register unless `ProcessType == ptRenderer`,
so it always returns `False` here. The fix is `RegisterDCPlugin()` in
`src/ucontrollerbrowser.pas`, which calls `cef_register_extension` directly.

## V8 plugin: `window.__dc_plugin`

Registered inside `DCPlugin_OnWebKitInitialized` (the render-process handler).
Because the hook is set on `GlobalCEFApp` *before* `StartMainProcess`, it fires in
**every** process — browser, zygote and renderer.

```js
window.__dc_plugin.version          // "1.0.0"
window.__dc_plugin.sendToPascal(msg) // → IPC → browser OnProcessMessageReceived
window.__dc_plugin.getTabInfo()     // → {id, url, title}
window.__dc_plugin.executeJS(code)  // → ExecuteJavaScript in page
```

The JS world is isolated: `var __dc_plugin = {...}` with `native function` declarations
for each bridge method. The `TDCPluginV8Handler.Execute()` handler routes `SendToPascal`
into `frame.SendProcessMessage(PID_BROWSER, 'dc.plugin.message')`.

## IPC protocol

Two Unix domain sockets, newline-delimited JSON:

| Socket | Env var | Default |
|--------|---------|---------|
| Command | `DC_CMD_SOCKET` | `/tmp/aethelgard_cef.sock` |
| Bus/Events | `DC_BUS_SOCKET` | `/tmp/aethelgard_bus.sock` |

Command examples:

```json
{"action":"navigate","url":"https://example.com","tab_id":1}
{"action":"list_tabs"}
{"action":"evaluate_js","code":"document.title"}
{"action":"get_eval"}
```

## Asset embedding

`assets/{common,facebook,reddit}/` is compiled into Pascal string constants
(`uAssetsEmbedded*.pas`) by `scripts/assets_embed.py` — no runtime file reads.

## Accessibility crash avoidance

`env -i` + `NO_AT_BRIDGE=1` + `GTK_A11Y=none`. Without these, GTK2 loads
`libatk-bridge-2.0.so.0` and CEF's views code crashes.

## Chrome extensions

- `dual_citizen_v2` — **zero** Chrome extensions. V8 plugin only.
- `dual_citizen_reddit` / `dual_citizen_facebook` — 12 extensions via
  `--load-extension` switch value (built at runtime in `BuildExtList()`).

## CDP

ChromeDriver / DevTools is **disabled** in all three binaries (no `--remote-debugging-port`).
It may be re-enabled for auxiliary tooling by adding the flag back; it must not be the
primary IPC channel.