# Plugin Spec: `window.__dc_plugin`

## Registration

Registered in the renderer's `OnWebKitInitialized` via `RegisterDCPlugin()`,
which calls `cef_register_extension` directly (bypassing CEF4Delphi's
`CefRegisterExtension` wrapper, which rejects `ptZygote` processes).

```pascal
procedure DCPlugin_OnWebKitInitialized(browser: ICefBrowser; frame: ICefFrame;
  const context: ICefv8context; const entrypoint: string);
begin
  RegisterDCPlugin(browser, frame);
end;
```

## Exposed API

```js
window.__dc_plugin.version          // "1.0.0"
window.__dc_plugin.sendToPascal(msg) // → IPC → browser OnProcessMessageReceived
window.__dc_plugin.getTabInfo()     // → {id, url, title}
window.__dc_plugin.executeJS(code)  // → ExecuteJavaScript in page
```

## Handler

`TDCPluginV8Handler` implements `CefV8Handler::Execute(name, obj, arguments,
retval, exception)`:

| `name` | Action |
|--------|--------|
| `SendToPascal` | `frame.SendProcessMessage(PID_BROWSER, 'dc.plugin.message')` |
| `GetTabInfo` | Returns `{id, url, title}` for the current frame |
| `ExecuteJS` | `browser.MainFrame.ExecuteJavaScript(code)` |

## Known quirk

`CefRegisterExtension()` in CEF4Delphi refuses to run unless
`GlobalCEFApp.ProcessType == ptRenderer`, but this build spawns renderer-equivalent
processes as `--type=zygote` (`ptZygote`), so the wrapper always returns `False`.
`RegisterDCPlugin()` calls `cef_register_extension` directly.

## IPC

Renderer → browser via `frame.SendProcessMessage(PID_BROWSER, 'dc.plugin.message')`.
Browser receives in `OnProcessMessageReceived`. The command socket
(`/tmp/aethelgard_cef.sock`) is **single-shot per connection**: `ProcessCommands`
accepts one connection, reads one newline-delimited JSON line, closes the socket.
Clients must reconnect for every command.

## Verification

Under Xvfb `:99`, live test confirmed:

```
list_tabs   -> ok, tab_id 1, profile_1
version     -> ok (window.__dc_plugin v1.0.0)
sendToPascal -> ok (IPC delivered)
get_eval    -> ok (poll 2)
```