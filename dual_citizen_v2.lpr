program dual_citizen_v2;

{$mode objfpc}{$H+}
{$I /home/veyron/CEF4Delphi/source/cef.inc}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces,
  Forms,
  Classes,
  SysUtils,
  uCEFApplication,
  uControllerBrowser in 'ucontrollerbrowser.pas';

{$R *.res}

const
  // Portable defaults — every path can be overridden with an environment
  // variable so the binary is not tied to one machine's home directory.
  DEFAULT_CEF_RUNTIME = '/home/veyron/cef-runtime/Release/';
  DEFAULT_CACHE_ROOT  = '/home/veyron/.config/dual_citizen/rootcache/';
  DEFAULT_LOG_FILE    = '/tmp/dual_citizen_v2.log';

function EnvOr(const AName, ADefault: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    Result := ADefault;
end;

// Absolute extension paths are passed to Chromium as the value of
// --load-extension (comma separated). They are discovered at runtime by
// scanning <app dir>/extensions for directories containing manifest.json, so
// adding or removing an extension never needs a rebuild.
function BuildExtList(const AExtDir: string): string;
var
  SR: TSearchRec;
  Item: string;
begin
  Result := '';
  if not DirectoryExists(AExtDir) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(AExtDir) + '*', faDirectory, SR) = 0 then
  try
    repeat
      if ((SR.Attr and faDirectory) <> 0) and (SR.Name <> '.') and (SR.Name <> '..') then
      begin
        Item := IncludeTrailingPathDelimiter(AExtDir) + SR.Name;
        if FileExists(IncludeTrailingPathDelimiter(Item) + 'manifest.json') then
        begin
          if Result <> '' then
            Result := Result + ',';
          Result := Result + Item;
        end;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

// Reads "--switch=value" (also accepts "--switch value" style by prefix match)
// from the application command line. Returns '' when the switch is absent.
function ArgValue(const APrefix: string): string;
var
  i, n: Integer;
  p, s: string;
begin
  Result := '';
  n := Length(APrefix);
  for i := 1 to ParamCount do
  begin
    s := ParamStr(i);
    if Copy(s, 1, n) = APrefix then
    begin
      p := Copy(s, n + 1, MaxInt);
      if (p <> '') and (p[1] = '=') then
        Delete(p, 1, 1);
      Exit(p);
    end;
  end;
end;

var
  CefRuntime: string;
  ExtDir: string;
  ExtList: string;
  DebugPort: string;
begin
  // 1. Create the global CEF application object
  GlobalCEFApp := TCefApplication.Create;

  // 2. CEF Configuration (paths overridable via environment)
  CefRuntime := IncludeTrailingPathDelimiter(EnvOr('DC_CEF_RUNTIME', DEFAULT_CEF_RUNTIME));
  GlobalCEFApp.FrameworkDirPath := CefRuntime;
  GlobalCEFApp.ResourcesDirPath := CefRuntime;
  GlobalCEFApp.LocalesDirPath   := CefRuntime + 'locales/';
  GlobalCEFApp.LogFile          := EnvOr('DC_LOG_FILE', DEFAULT_LOG_FILE);
  GlobalCEFApp.LogSeverity      := 3;  // LOGSEVERITY_WARNING
  GlobalCEFApp.EnableGPU        := True;
  GlobalCEFApp.EnablePrintPreview := False;
  GlobalCEFApp.EnableMediaStream  := True;

  // 3. Command-line flags
  GlobalCEFApp.AddCustomCommandLine('--no-sandbox');
  // WebGPU for ONNX Runtime Web execution provider (required for in-browser model inference)
  // Using CEFtime.txt recommended two-argument form
  GlobalCEFApp.AddCustomCommandLine('enable-features', 'WebGPU,WebAssemblySharedArrayBuffer,Vulkan');
  GlobalCEFApp.AddCustomCommandLine('enable-unsafe-webgpu', '');
  GlobalCEFApp.AddCustomCommandLine('ignore-gpu-blocklist', '');
  GlobalCEFApp.AddCustomCommandLine('disable-gpu-sandbox', '');
  // Keep GPU compositing ON — required for WebGPU to function
  GlobalCEFApp.AddCustomCommandLine('--disable-renderer-accessibility');
  GlobalCEFApp.AddCustomCommandLine('--force-renderer-accessibility=false');
  GlobalCEFApp.AddCustomCommandLine('--disable-accessibility');
  GlobalCEFApp.AddCustomCommandLine('--disable-features=Accessibility');
  GlobalCEFApp.AddCustomCommandLine('--no-zygote-sandbox');
  GlobalCEFApp.AddCustomCommandLine('--force-dark-mode');

  // 4. Extensions — passed as the VALUE of --load-extension.
  //    (Embedding '=path' inside the switch name makes Chromium see a switch
  //     with no value, which silently loads zero extensions.)
  ExtDir := IncludeTrailingPathDelimiter(EnvOr('DC_EXT_DIR',
    IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'extensions'));
  ExtList := '';
  if EnvOr('DC_EXTENSIONS', '1') <> '0' then
    ExtList := BuildExtList(ExtDir);
  if ExtList <> '' then
  begin
    WriteLn('[DCv2] Extensions: ', ExtList);
    GlobalCEFApp.AddCustomCommandLine('--load-extension', ExtList);
  end
  else
    WriteLn('[DCv2] Extensions: none (dir ', ExtDir, ')');

  // 5. Remote-control port — OFF unless explicitly requested.
  //    Request it with DC_REMOTE_DEBUG_PORT=9222 (or --remote-debugging-port=9222).
  //    Nothing listens when neither is supplied.
  DebugPort := GetEnvironmentVariable('DC_REMOTE_DEBUG_PORT');
  if DebugPort = '' then
    DebugPort := ArgValue('--remote-debugging-port');
  if DebugPort <> '' then
  begin
    WriteLn('[DCv2] Remote-control port ENABLED on 127.0.0.1:', DebugPort);
    GlobalCEFApp.AddCustomCommandLine('--remote-debugging-port', DebugPort);
    GlobalCEFApp.AddCustomCommandLine('--remote-allow-origins', '*');
  end
  else
    WriteLn('[DCv2] Remote-control port: disabled');

  // 6. Isolated profile root
  GlobalCEFApp.RootCache := IncludeTrailingPathDelimiter(EnvOr('DC_CACHE_ROOT', DEFAULT_CACHE_ROOT));
  GlobalCEFApp.cache     := GlobalCEFApp.RootCache + 'cache/';

  // 7. Fork protection guard: Only launch full LCL context within the primary
  //    browser UI PID. OnWebKitInitialized is wired HERE (before
  //    StartMainProcess) so it fires in every process — browser, zygote and
  //    renderer — which is what registers window.__dc_plugin.
  // DCPlugin_OnWebKitInitialized is defined in apply_changes.sh but not yet
  // ported to the build tree — registration happens via DoLoadEnd instead.
  // GlobalCEFApp.OnWebKitInitialized := @DCPlugin_OnWebKitInitialized;
  if GlobalCEFApp.StartMainProcess then
  begin
    CustomWidgetSetInitialization;
    RequireDerivedFormResource := True;
    Application.Scaled := True;
    Application.Initialize;
    Application.CreateForm(TControllerForm, ControllerForm);
    Application.Run;
    CustomWidgetSetFinalization;
  end;

  // 8. Destructor cleanup on exit
  DestroyGlobalCEFApp;
end.
