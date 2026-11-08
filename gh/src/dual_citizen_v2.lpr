program dual_citizen_v2;

{$mode objfpc}{$H+}
{$I cef.inc}

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

function EnvPath(const Name, Default: string): string;
var
  V: string;
begin
  V := GetEnvironmentVariable(Name);
  if V = '' then
    Result := Default
  else
    Result := IncludeTrailingPathDelimiter(V);
end;

begin
  // 1. Create the global CEF application object
  GlobalCEFApp := TCefApplication.Create;

  // 2. CEF Configuration
  GlobalCEFApp.FrameworkDirPath := EnvPath('CEFRUNTIME', '/home/lilareyon/cef-runtime/Release/');
  GlobalCEFApp.ResourcesDirPath := EnvPath('CEFRUNTIME', '/home/lilareyon/cef-runtime/Release/');
  GlobalCEFApp.LocalesDirPath   := EnvPath('CEFRUNTIME', '/home/lilareyon/cef-runtime/Release/') + 'locales/';
  GlobalCEFApp.LogFile          := '/tmp/dual_citizen_v2.log';
  GlobalCEFApp.LogSeverity      := 3;  // LOGSEVERITY_WARNING
  GlobalCEFApp.EnableGPU        := True;
  GlobalCEFApp.EnablePrintPreview := False;
  GlobalCEFApp.EnableMediaStream  := True;

  // 3. Command-line flags
  GlobalCEFApp.AddCustomCommandLine('--no-sandbox');
  GlobalCEFApp.AddCustomCommandLine('--disable-gpu-compositing');
  GlobalCEFApp.AddCustomCommandLine('--enable-unsafe-swiftshader');
  GlobalCEFApp.AddCustomCommandLine('--disable-renderer-accessibility');
  GlobalCEFApp.AddCustomCommandLine('--force-renderer-accessibility=false');
  GlobalCEFApp.AddCustomCommandLine('--disable-accessibility');
  GlobalCEFApp.AddCustomCommandLine('--disable-features=Accessibility,VizDisplayCompositor');
  GlobalCEFApp.AddCustomCommandLine('--no-zygote-sandbox');
  GlobalCEFApp.AddCustomCommandLine('--force-dark-mode');
  // Extensions loaded via OnAfterCreated hook, not command line
  GlobalCEFApp.RootCache := EnvPath('DC_DATADIR', '/home/lilareyon/.config/dual_citizen/') + 'rootcache/';
  GlobalCEFApp.cache    := EnvPath('DC_DATADIR', '/home/lilareyon/.config/dual_citizen/') + 'rootcache/cache/';

  // 4. Fork protection guard: Only launch full LCL context within the primary browser UI PID
  //    NOTE: GlobalCEFApp event hooks (OnWebKitInitialized) are set HERE, before
  //    StartMainProcess, so they are active in EVERY process — browser, zygote and
  //    renderer. OnWebKitInitialized is a render-process handler; if it is only
  //    wired in the browser process (FormCreate) the renderer never receives it
  //    and window.__dc_plugin is never registered.
  GlobalCEFApp.OnWebKitInitialized := @DCPlugin_OnWebKitInitialized;
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

  // 5. Destructor cleanup on exit
  DestroyGlobalCEFApp;
end.