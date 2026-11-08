#!/bin/bash
set -e

FILE="/home/lilareyon/dual-citizen/build-131/ucontrollerbrowser.pas"

# 1. Add FExtensionLoaded field
sed -i '/FEvalResultReady: Boolean;/a\    FExtensionLoaded: Boolean;  // Track if extension loaded via OnAfterCreated' "$FILE"

# 2. Add OnProcessMessageReceived method declaration
sed -i '/procedure HandleEvalResult/a\    procedure OnProcessMessageReceived(Sender: TObject; const browser: ICefBrowser; const frame: ICefFrame; sourceProcess: TCefProcessId; const message: ICefProcessMessage; out Result: Boolean);' "$FILE"

# 3. Add OnWebKitInitialized hook in FormCreate
sed -i '/WriteLn.*Command socket/a\
\
  // Hook V8 plugin - runs once when WebKit initializes\
  GlobalCEFApp.OnWebKitInitialized := @DCPlugin_OnWebKitInitialized;\
  WriteLn('\''[DCv2] V8 plugin registered for window.__dc_plugin'\'');' "$FILE"

# 4. Add OnProcessMessageReceived hook to each tab's Chromium
sed -i '/OnTitleChange := @DoTitleChange;/a\  FTabs[idx].ChromiumWindow.ChromiumBrowser.OnProcessMessageReceived := @OnProcessMessageReceived;' "$FILE"

# 5. Update DoAfterCreated with extension loading
cat > /tmp/doaftercreated.patch <<'PATCH'
procedure TControllerForm.DoAfterCreated(Sender: TObject; const browser: ICefBrowser);
var
  i: Integer;
  bid: Integer;
  cw: TChromiumWindow;
  ExtPath: string;
  ExtHandler: ICefExtensionRequestContextHandler;
begin
  WriteLn('[DCv2] Browser ready');
  SetupRendererBridge(browser);
  SendBusJSON('browser.status', 'ready',
    '{"status":"ready","chromium":"131.0.6778.265","version":"dual_citizen_v2"}');

  // ═══════════════════════════════════════════════════════════════
  // SAFE LINUX EXTENSION LOADING — runs inside OnAfterCreated safety window
  // ═══════════════════════════════════════════════════════════════
  if not FExtensionLoaded then
  begin
    ExtPath := ExtractFilePath(ParamStr(0)) + 'extensions/lilith-mcp-listener';
    if DirectoryExists(ExtPath) then
    begin
      ExtHandler := TCefExtensionRequestContextHandlerRef.New;
      if (browser <> nil) and (browser.Host <> nil) and (browser.Host.RequestContext <> nil) then
      begin
        browser.Host.RequestContext.LoadExtension(ExtPath, ExtHandler);
        FExtensionLoaded := True;
        WriteLn('[DCv2] Lilith-MCP Listener extension loaded: ', ExtPath);
      end;
    end
    else
      WriteLn('[DCv2] Extension path not found: ', ExtPath);
  end;

  // Linux/CEF: the browser's own X window is created at 1x1 when the browser is
  // created before LCL has laid the TabSheet out. TChromiumWindow.UpdateSize is
  // a no-op on Linux (only Windows resizes the child HWND), so the geometry is
  // pushed explicitly here via Chromium.UpdateBrowserSize once the browser
  // exists and the LCL control has its real bounds. Without this the first tab
  // renders as a 1x1 dead/grey surface.
  if (browser = nil) or (FTabCount = 0) then Exit;
  bid := browser.Identifier;
  for i := 0 to FTabCount - 1 do
  begin
    cw := FTabs[i].ChromiumWindow;
    if cw = nil then Continue;
    if (cw.ChromiumBrowser <> nil) and
       (cw.ChromiumBrowser.Browser <> nil) and
       (cw.ChromiumBrowser.Browser.Identifier = bid) then
    begin
      cw.ChromiumBrowser.UpdateBrowserSize(cw.Left, cw.Top, cw.Width, cw.Height);
      cw.NotifyMoveOrResizeStarted;
      Exit;
    end;
  end;
end;
PATCH

# Find the line number of DoAfterCreated and replace it
START_LINE=$(grep -n "^procedure TControllerForm.DoAfterCreated" "$FILE" | head -1 | cut -d: -f1)
END_LINE=$(awk -v start="$START_LINE" 'NR > start && /^end;$/ {print NR; exit}' "$FILE")

if [ -n "$START_LINE" ] && [ -n "$END_LINE" ]; then
  sed -i "${START_LINE},${END_LINE}d" "$FILE"
  sed -i "${START_LINE}i\\$(cat /tmp/doaftercreated.patch)" "$FILE"
fi

# 6. Add HandleEvalResult implementation
sed -i '/^procedure TControllerForm.HandleEvalResult/,/^end;$/d' "$FILE"
sed -i '/^procedure TControllerForm.HandleCommand/i\
procedure TControllerForm.HandleEvalResult(const cmdId, result: string);\
begin\
  // Called from OnProcessMessageReceived when renderer sends back eval result\
  FEvalResult := result;\
  FEvalResultReady := True;\
  WriteLn('\''[DCv2] Eval result received for cmdId: '\'' + cmdId);\
end;\
' "$FILE"

# 7. Add OnProcessMessageReceived implementation
sed -i '/^procedure TControllerForm.OnProcessMessageReceived/,/^end;$/d' "$FILE"
sed -i '/^procedure TControllerForm.HandleEvalResult/a\
\
procedure TControllerForm.OnProcessMessageReceived(Sender: TObject; const browser: ICefBrowser;\
  const frame: ICefFrame; sourceProcess: TCefProcessId; const message: ICefProcessMessage; out Result: Boolean);\
var\
  Payload: string;\
begin\
  Result := False;\
  if (message = nil) or (message.Name <> DC_PLUGIN_MESSAGE) then Exit;\
  Payload := message.ArgumentList.GetString(0);\
  WriteLn('\''[DCv2] Plugin message received: '\'' + Payload);\
  if (Payload <> '\'''\'') then Result := True;\
end;\
' "$FILE"

# 8. Append V8 plugin implementation at end of file (before final end.)
sed -i '$d' "$FILE"  # Remove final end.
cat >> "$FILE" <<'PASCALEOF'

// ═══════════════════════════════════════════════════════════════
// NATIVE V8 PLUGIN + IPC HANDLERS (correct CEF4Delphi API)
// ═══════════════════════════════════════════════════════════════

const
  DC_PLUGIN_MESSAGE = 'dc.plugin.message';

type
  // V8 Handler for window.__dc_plugin native functions
  TDCPluginV8Handler = class(TCefv8HandlerOwn)
  protected
    function Execute(const name: ustring; const obj: ICefv8Value; const arguments: TCefv8ValueArray;
      var retval: ICefv8Value; var exception: ustring): Boolean; override;
  end;

function TDCPluginV8Handler.Execute(const name: ustring; const obj: ICefv8Value;
  const arguments: TCefv8ValueArray; var retval: ICefv8Value; var exception: ustring): Boolean;
var
  Msg: ICefProcessMessage;
  Frame: ICefFrame;
  Payload: string;
begin
  Result := False;

  if (name = 'sendToPascal') and (arguments.Length > 0) then
  begin
    Payload := arguments.GetValue(0).GetStringValue;
    Msg := TCefProcessMessageRef.New(DC_PLUGIN_MESSAGE);
    Msg.ArgumentList.SetString(0, Payload);

    Frame := TCefv8ContextRef.Current.Browser.MainFrame;
    if (Frame <> nil) and Frame.IsValid then
      Frame.SendProcessMessage(PID_BROWSER, Msg);

    retval := TCefv8ValueRef.NewString('OK');
    Result := True;
  end
  else if (name = 'getTabInfo') then
  begin
    retval := TCefv8ValueRef.NewString('{"tab_id":0,"url":"' + TCefv8ContextRef.Current.Browser.MainFrame.Url + '"}');
    Result := True;
  end
  else if (name = 'executeJS') and (arguments.Length > 0) then
  begin
    retval := TCefv8ValueRef.NewString('not_implemented');
    Result := True;
  end;
end;

// Plain procedure for GlobalCEFApp.OnWebKitInitialized
procedure DCPlugin_OnWebKitInitialized;
var
  PluginCode: ustring;
  Handler: ICefv8Handler;
begin
  Handler := TDCPluginV8Handler.Create;

  PluginCode :=
    'var __dc_plugin = {};' + #10 +
    '__dc_plugin.version = "1.0.0";' + #10 +
    '__dc_plugin.sendToPascal = function(message) {' + #10 +
    '  native function sendToPascal(message);' + #10 +
    '  return sendToPascal(JSON.stringify(message));' + #10 +
    '};' + #10 +
    '__dc_plugin.getTabInfo = function() {' + #10 +
    '  native function getTabInfo();' + #10 +
    '  return getTabInfo();' + #10 +
    '};' + #10 +
    '__dc_plugin.executeJS = function(code) {' + #10 +
    '  native function executeJS(code);' + #10 +
    '  return executeJS(code);' + #10 +
    '};' + #10;

  CefRegisterExtension('dc.plugin', PluginCode, Handler);
end.

PASCALEOF
