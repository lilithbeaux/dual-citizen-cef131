program dual_citizen_facebook;

{$mode objfpc}{$H+}
{$I cef.inc}

{$DEFINE EnableLibOverlay}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces,
  Forms,
  uControllerBrowser_Facebook in 'ucontrollerbrowser_facebook.pas',
  uCEFApplication,
  uAssetsEmbedded_Facebook in 'uAssetsEmbedded_Facebook.pas';

{$R *.res}

const
  EXT_LIST = '$EXTDIR/cookie-session-isolator,$EXTDIR/user-agent-switcher,$EXTDIR/multi-account-container,$EXTDIR/proxy-manager,$EXTDIR/session-manager,$EXTDIR/header-injector,$EXTDIR/canvas-fingerprint-defender,$EXTDIR/tab-isolator,$EXTDIR/web-request-controller,$EXTDIR/cache-cookie-clearence,$EXTDIR/hello,$EXTDIR/set_page_color';

begin
  GlobalCEFApp := TCefApplication.Create;

  // ── CEF Configuration ────────────────────────────────────
  GlobalCEFApp.FrameworkDirPath := '$CEFRUNTIME/';
  GlobalCEFApp.ResourcesDirPath := '$CEFRUNTIME/';
  GlobalCEFApp.LocalesDirPath   := '$CEFRUNTIME/locales/';
  GlobalCEFApp.LogFile          := '/tmp/dual_citizen_facebook.log';
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
  GlobalCEFApp.AddCustomCommandLine('--load-extension', EXT_LIST);
  // Dedicated profile root: avoids the 'root_cache_path' process-singleton warning
  // and stops the browser sharing/locking state with any other instance.
  GlobalCEFApp.RootCache := '$DATADIR/rootcache/';
  GlobalCEFApp.cache    := '$DATADIR/rootcache/cache/';
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