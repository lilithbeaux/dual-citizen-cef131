program dual_citizen_reddit;

{$mode objfpc}{$H+}
{$I /home/lilareyon/CEF4Delphi/source/cef.inc}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces,
  Forms,
  uControllerBrowser in 'ucontrollerbrowser.pas',
  uCEFApplication,
  uAssetsEmbedded in 'uAssetsEmbedded.pas';

{$R *.res}

const
  EXT_LIST = '/home/lilareyon/dual-citizen/build-131/extensions/cookie-session-isolator,/home/lilareyon/dual-citizen/build-131/extensions/user-agent-switcher,/home/lilareyon/dual-citizen/build-131/extensions/multi-account-container,/home/lilareyon/dual-citizen/build-131/extensions/proxy-manager,/home/lilareyon/dual-citizen/build-131/extensions/session-manager,/home/lilareyon/dual-citizen/build-131/extensions/header-injector,/home/lilareyon/dual-citizen/build-131/extensions/canvas-fingerprint-defender,/home/lilareyon/dual-citizen/build-131/extensions/tab-isolator,/home/lilareyon/dual-citizen/build-131/extensions/web-request-controller,/home/lilareyon/dual-citizen/build-131/extensions/cache-cookie-clearence,/home/lilareyon/dual-citizen/build-131/extensions/hello,/home/lilareyon/dual-citizen/build-131/extensions/set_page_color';

begin
  GlobalCEFApp := TCefApplication.Create;

  // ── CEF Configuration ────────────────────────────────────
  GlobalCEFApp.FrameworkDirPath := '/home/lilareyon/cef-runtime/Release/';
  GlobalCEFApp.ResourcesDirPath := '/home/lilareyon/cef-runtime/Release/';
  GlobalCEFApp.LocalesDirPath   := '/home/lilareyon/cef-runtime/Release/locales/';
  GlobalCEFApp.LogFile          := '/tmp/dual_citizen_reddit.log';
  GlobalCEFApp.LogSeverity      := 3;  // LOGSEVERITY_WARNING
  GlobalCEFApp.EnableGPU        := True;
  GlobalCEFApp.EnablePrintPreview := False;
  GlobalCEFApp.EnableMediaStream  := True;

  // ── Command-line flags ───────────────────────────────────
  GlobalCEFApp.AddCustomCommandLine('--no-sandbox');
  // --disable-gpu REMOVED: causes views::DesktopWindowTreeHostPlatform crash
  // SwiftShader works WITH GPU process enabled (software GL path)
  GlobalCEFApp.AddCustomCommandLine('--disable-gpu-compositing');
  GlobalCEFApp.AddCustomCommandLine('--enable-unsafe-swiftshader');
  // Disable accessibility to prevent atk-bridge crashes in CEF's views code
  GlobalCEFApp.AddCustomCommandLine('--disable-renderer-accessibility');
  GlobalCEFApp.AddCustomCommandLine('--force-renderer-accessibility=false');
  GlobalCEFApp.AddCustomCommandLine('--disable-accessibility');
  GlobalCEFApp.AddCustomCommandLine('--disable-features=Accessibility,VizDisplayCompositor');
  // NOTE: --disable-software-rasterizer was REMOVED because it blocks ALL rendering
  // when GPU is disabled. Software rasterization is the only render path left.
  // --disable-extensions REMOVED 2026-10-21: the 12 extensions must load
  GlobalCEFApp.AddCustomCommandLine('--no-zygote-sandbox');
  // FIX 2026-10-21: pass the extension list as a SWITCH VALUE, not embedded in the key.
  // CEF4Delphi's AddCustomCommandLine(aCommandLine, aValue) -> ReplaceSwitch ->
  // commandLine.AppendSwitchWithValue(key,value). Embedding '=value' in the key made
  // Chromium see a switch named 'load-extension' with NO value -> zero extensions.
  // GlobalCEFApp.AddCustomCommandLine('--load-extension', EXT_LIST);  // DISABLED for debugging
  // Dedicated profile root: avoids the 'root_cache_path' process-singleton warning
  // and stops the browser sharing/locking state with any other instance.
  GlobalCEFApp.RootCache := '/home/lilareyon/.config/dual_citizen_reddit/rootcache/';
  GlobalCEFApp.cache    := '/home/lilareyon/.config/dual_citizen_reddit/rootcache/cache/';
  // CDP REMOVED 2026-10-21: no remote debugging port (permanent no-CDP rule)

  // ── Start CEF ────────────────────────────────────────────
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

  DestroyGlobalCEFApp;
end.