unit uControllerBrowser_Facebook;

{$mode objfpc}{$H+}
{$I /home/lilareyon/CEF4Delphi/source/cef.inc}

interface

uses
  Classes, SysUtils, Forms, Controls, ExtCtrls, ComCtrls, StdCtrls, Buttons,
  Menus, Dialogs, LCLType, Graphics, Types,
  uCEFConstants, uCEFTypes, uCEFInterfaces, uCEFChromiumEvents,
  uCEFChromium, uCEFChromiumWindow, uCEFApplication,
  fpjson, jsonparser, sockets, baseunix, unix, fgl,
  SpoofCore, Generics.Collections,
  uAssetsEmbedded_Facebook;

const
  CMD_SOCKET_DEFAULT = '/tmp/aethelgard_cef.sock';
  BUS_SOCKET_DEFAULT = '/tmp/aethelgard_bus.sock';
  PROFILES_FILE  = '/home/lilareyon/.NOTTHEONETOEDIT/fleet/extension-firefox/data/profiles.json';
  MAX_TABS       = 16;
  BASE_DATA_DIR  = '/home/lilareyon/.config/dual_citizen/';

  // --- On-disk asset system (shared by facebook / reddit custom browsers) ---
  ASSETS_ROOT    = '/home/lilareyon/dual-citizen/assets/';
  MANIFEST_ASSET = 'asset_manifest.json'; // preferred per-site manifest name
  MANIFEST_LEGACY= 'manifest.json';       // legacy name already used by facebook/reddit

type
  TTabInfo = record
    TabId: Integer;
    ChromiumWindow: TChromiumWindow;
    ProfileName: string;
    UserDataDir: string;
    SessionCookieDir: string;
    LastTitle: string;
  end;
  PTabInfo = ^TTabInfo;

  // Specialized dictionary for pending renderer commands
  TCommandDict = specialize TFPGMap<string, TJSONData>;

  // --- Asset system types ---
  TAssetType   = (atSpoof, atCSS, atSelectorMap, atPayloadMap);
  TAssetTypeSet = set of TAssetType;

  TAssetRef = record
    FileName       : string;     // path relative to ASSETS_ROOT
    ExpectedSHA256 : string;
    ActualSHA256   : string;
    Content        : string;     // raw file text
    Loaded         : Boolean;
    Valid          : Boolean;
    LoadError      : string;
  end;

  TAssetBundle = record
    Site           : string;
    Version        : string;
    SchemaVersion  : string;
    CEFVersionMin  : string;
    CEFVersionMax  : string;
    ManifestPath   : string;
    ManifestMtime  : Int64;
    Endpoints      : array of string;
    Scripts        : array of TAssetRef;   // injection_order (spoof scripts)
    Stylesheets    : array of TAssetRef;   // css array
    SelectorMap    : TAssetRef;             // data[0] -> selector_map
    PayloadMap     : TAssetRef;             // data[1] -> payload_map
    Loaded         : Boolean;
    LoadError      : string;
  end;

  { TControllerForm }
  TControllerForm = class(TForm)
    edAddress: TEdit;
    btnGo: TSpeedButton;
    btnNewTab: TSpeedButton;
    btnExtensions: TSpeedButton;
    btnMenu: TSpeedButton;          // Hamburger menu button
    tbMain: TPageControl;
    Timer1: TTimer;
    StatusBar: TPanel;
    MainMenu1: TMainMenu;           // Full menu bar (hidden, for keyboard shortcuts)
    // Settings dialog components (created dynamically)
    
    procedure FormCreate(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormDestroy(Sender: TObject);
    procedure btnGoClick(Sender: TObject);
    procedure btnBackClick(Sender: TObject);
    procedure btnForwardClick(Sender: TObject);
    procedure btnNewTabClick(Sender: TObject);
    procedure btnExtensionsClick(Sender: TObject);
    procedure btnMenuClick(Sender: TObject);      // Hamburger menu click
    procedure Timer1Timer(Sender: TObject);
    procedure edAddressKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure tbMainChange(Sender: TObject);
    procedure tbMainDrawTab(Control: TCustomTabControl; TabIndex: Integer; const Rect: TRect; IsActive: Boolean);
    procedure tbMainMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure tbMainCloseTabClicked(Sender: TObject; TabIndex: Integer); // Tab close button

    // Menu/Dialog handlers (declared for GUI-first protocol)
    procedure ShowSettingsDialog(Sender: TObject);
    procedure ShowAutomationConsole(Sender: TObject);
    procedure ShowDOMExplorer(Sender: TObject);
    procedure ShowNetworkTools(Sender: TObject);
    procedure ShowStorageManager(Sender: TObject);
    procedure ShowScreenshotVideo(Sender: TObject);
    procedure ShowExtensionManager(Sender: TObject);
    procedure ShowSpoofProfiles(Sender: TObject);
    procedure ShowReplayRunner(Sender: TObject);
    procedure ShowProfileSwitcher(Sender: TObject);
    procedure ShowProfileManager(Sender: TObject);
    procedure ShowAbout(Sender: TObject);
    procedure QuitApp(Sender: TObject);
    procedure OpenDevTools(Sender: TObject);  // DevTools opener

  private
    FNeedFirstTab: Boolean;
    FStartURL: string;
    FNextTabId: Integer;
    FTabs: array of TTabInfo;
    FTabCount: Integer;
    FCmdSock: Integer;
    FCmdBuf: string;
    FSpoofJS: array of string;  // Spoof JS per tab index
    FSpoofApplied: array of Boolean;  // True if spoof JS already applied to this tab
    FProxyHost: string;
    FProxyPort: Integer;
    FProxyEnabled: Boolean;
    FEvalResult: string;        // Last evaluate_js result (from document.title)
  FEvalResultReady: Boolean;  // True when a new eval result is available

  // Reddit automation temp vars
    commentText: string;
    postTitle: string;
    postBody: string;
    direction: string;
    btnSel: string;
    subName: string;
    query: string;

    // Extended IPC - Renderer Bridge
    // Using core CEF process message handling (no MessageRouter wrapper)
    FPendingCommands: TCommandDict;  // id -> response data
    FRendererScriptInjected: array of Boolean;  // per tab index

    // Asset system
    FAssets: array of TAssetBundle;             // one bundle per loaded site
    FTabAssetInjected: array of TAssetTypeSet;  // per tab index, which asset types injected

    // Asset system helpers
    function ReadTextFile(const Path: string; out AText: string): Boolean;
    function ComputeSHA256(const Path: string; out Hash: string): Boolean;
    function JSStr(const s: string): string;
    function AssetBundleIndex(const Site: string): Integer;
    function SiteMatchesURL(const Bundle: TAssetBundle; const URL: string): Boolean;
    procedure EnsureTabAssetArrays(TabIndex: Integer);
    procedure InjectSiteAssets(TabIndex: Integer; const URL: string);

    // Settings panel
    procedure CreateSettingsDialog;
    procedure BuildMenuStructure;
    procedure BuildMainMenu;           // Hidden menu for keyboard shortcuts

    // IPC
    function SendBusJSON(const topic, mtype, payload: string): Boolean;
    procedure HandleCommand(const cmdLine: string; const ReplySock: Integer = -1);
    procedure ProcessCommands;
    procedure SendReply(const sock: Integer; const json: string);
    procedure WriteProxyConfig;
    function GetProfile(key: string): TJSONObject;

    // Tab Management
    function AddTab(const ProfileName: string = ''): Integer;
    procedure CloseTab(TabId: Integer);
    function GetTabIndex(TabId: Integer): Integer;
    function ActiveTabId: Integer;

    // CEF events
    procedure DoAfterCreated(Sender: TObject; const browser: ICefBrowser);
    procedure DoBeforePopup(Sender: TObject; const browser: ICefBrowser;
      const frame: ICefFrame; popup_id: Integer;
      const targetUrl, targetFrameName: ustring;
      targetDisposition: TCefWindowOpenDisposition; userGesture: Boolean;
      const popupFeatures: TCefPopupFeatures; var windowInfo: TCefWindowInfo;
      var client: ICefClient; var settings: TCefBrowserSettings;
      var extra_info: ICefDictionaryValue; var noJavascriptAccess: Boolean;
      var Result: Boolean);
    procedure DoLoadEnd(Sender: TObject; const browser: ICefBrowser;
      const frame: ICefFrame; httpStatusCode: Integer);
    procedure DoTitleChange(Sender: TObject; const browser: ICefBrowser;
      const title: ustring);
    function GetActiveTitle: string;
    procedure DoAddressChange(Sender: TObject; const browser: ICefBrowser;
      const frame: ICefFrame; const url: ustring);

    // Extended IPC handlers
    procedure SetupRendererBridge(const browser: ICefBrowser);
    procedure InjectRendererBridge(const browser: ICefBrowser; TabIndex: Integer);
    procedure ResolvePendingCommand(const json: string);
    function GenerateCommandId: string;
    function GetTabIndexByBrowser(const browser: ICefBrowser): Integer;

    // Renderer command implementations
    procedure HandleRendererClick(const cmdId: string; const params: TJSONObject; TabId: Integer);
    procedure HandleRendererType(const cmdId: string; const params: TJSONObject; TabId: Integer);
    procedure HandleRendererScroll(const cmdId: string; const params: TJSONObject; TabId: Integer);
    procedure HandleRendererScreenshot(const cmdId: string; const params: TJSONObject; TabId: Integer);
    procedure HandleRendererDomQuery(const cmdId: string; const params: TJSONObject; TabId: Integer);
    procedure HandleRendererWaitFor(const cmdId: string; const params: TJSONObject; TabId: Integer);
    procedure HandleRendererEvaluate(const cmdId: string; const params: TJSONObject; TabId: Integer);

  public
    procedure Navigate(const url: string; TabId: Integer = -1);
    procedure ExecuteJS(const code: string; TabId: Integer = -1);
    function GetActiveURL(TabId: Integer = -1): string;
    function SpoofTab(TabId: Integer; const ProfileData: TJSONObject; AppliedNow: PBoolean = nil): Boolean;

    // Asset system
    function LoadAssetManifest(const Site: string): Boolean;
    function InjectAsset(const Site: string; AssetType: TAssetType; TabIndex: Integer): Boolean;
    function InjectSpoof(const Site: string; TabIndex: Integer = -1): Boolean;
    function InjectCSS(const Site: string; TabIndex: Integer = -1): Boolean;
    function GetSelector(const Site, Category, SelAction: string; out Selector: string): Boolean;
    function GetPayload(const Site, SelAction: string; out PayloadJSON: string): Boolean;
    function GetJSONValue(const Site, DottedPath: string; out Value: string): Boolean;
    function AssetPath(const Site, RelPath: string): string;
    procedure ReloadAssetsIfChanged;
  end;

var
  ControllerForm: TControllerForm;

implementation

{$R *.lfm}

uses
  uCEFMiscFunctions;


function CMD_SOCKET: string;
begin
  Result := GetEnvironmentVariable('DC_CMD_SOCKET');
  if Result = '' then Result := CMD_SOCKET_DEFAULT;
end;

function BUS_SOCKET: string;
begin
  Result := GetEnvironmentVariable('DC_BUS_SOCKET');
  if Result = '' then Result := BUS_SOCKET_DEFAULT;
end;


// ═══════════════════════════════════════════════════════════════
// PROFILE LOADER
// ═══════════════════════════════════════════════════════════════

function TControllerForm.GetProfile(key: string): TJSONObject;
var
  sl: TStringList;
  data, profiles: TJSONData;
  profilesObj: TJSONObject;
begin
  Result := nil;
  if not FileExists(PROFILES_FILE) then Exit;

  sl := TStringList.Create;
  try
    sl.LoadFromFile(PROFILES_FILE);
    data := GetJSON(sl.Text);
    
    // Navigate: data.profiles.<key>
    profiles := data.FindPath('profiles.' + key);
    if profiles <> nil then
      Result := TJSONObject(profiles.Clone)
    else
      WriteLn('[DCv2] Profile not found: ', key);
      
    data.Free;
  finally
    sl.Free;
  end;
end;

// ═══════════════════════════════════════════════════════════════
// EVENT BUS
// ═══════════════════════════════════════════════════════════════

function TControllerForm.SendBusJSON(const topic, mtype, payload: string): Boolean;
var
  sock: Integer;
  msg: string;
  addr: sockaddr_un;
  obj: TJSONObject;
begin
  Result := False;
  sock := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if sock = -1 then Exit;
  FillChar(addr, SizeOf(addr), 0);
  addr.sun_family := AF_UNIX;
  StrPCopy(addr.sun_path, BUS_SOCKET);
  if fpConnect(sock, @addr, SizeOf(addr)) = -1 then
  begin
    fpClose(sock);
    Exit;
  end;

  obj := TJSONObject.Create;
  try
    obj.Add('source', 'dual_citizen_v2');
    obj.Add('topic', topic);
    obj.Add('type', mtype);
    obj.Add('timestamp', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz"Z"', Now));
    if (Length(payload) > 0) and (payload[1] = '{') then
      obj.Add('payload', GetJSON(payload))
    else
      obj.Add('payload', payload);
    msg := obj.AsJSON;
  finally
    obj.Free;
  end;

  Result := fpSend(sock, @msg[1], Length(msg), 0) = Length(msg);
  fpClose(sock);
end;

procedure TControllerForm.SendReply(const sock: Integer; const json: string);
var
  msg: string;
begin
  if sock < 0 then Exit;
  msg := json + #10;
  fpSend(sock, @msg[1], Length(msg), 0);
end;

// ═══════════════════════════════════════════════════════════════
// TAB MANAGEMENT
// ═══════════════════════════════════════════════════════════════

function TControllerForm.AddTab(const ProfileName: string = ''): Integer;
var
  ti: PTabInfo;
  ts: TTabSheet;
  i, idx: Integer;
  profile: TJSONObject;
  profileDir: string;
begin
  if FTabCount >= MAX_TABS then
  begin
    Result := -1;
    Exit;
  end;

  // Create tab sheet
  ts := TTabSheet.Create(Self);
  ts.PageControl := tbMain;
  ts.Caption := 'New Tab';
  ts.TabVisible := True;

  // Determine profile
  if ProfileName = '' then
    profileDir := IntToStr(FNextTabId)
  else
    profileDir := StringReplace(ProfileName, ' ', '_', [rfReplaceAll]);

  // Allocate tab info
  idx := FTabCount;
  SetLength(FTabs, idx + 1);
  Inc(FTabCount);
  FTabs[idx].TabId := FNextTabId;
  FTabs[idx].ProfileName := ProfileName;
  FTabs[idx].UserDataDir := BASE_DATA_DIR + 'profile_' + profileDir;
  FTabs[idx].SessionCookieDir := FTabs[idx].UserDataDir + '/cookies';

  // Create user data dir
  ForceDirectories(FTabs[idx].UserDataDir);
  ForceDirectories(FTabs[idx].SessionCookieDir);

  // Create TChromiumWindow embedded in the TabSheet
  FTabs[idx].ChromiumWindow := TChromiumWindow.Create(ts);
  FTabs[idx].ChromiumWindow.Parent := ts;
  FTabs[idx].ChromiumWindow.Align := alClient;
  FTabs[idx].ChromiumWindow.ChromiumBrowser.OnAfterCreated := @DoAfterCreated;
  FTabs[idx].ChromiumWindow.ChromiumBrowser.OnBeforePopup := @DoBeforePopup;
  FTabs[idx].ChromiumWindow.ChromiumBrowser.OnLoadEnd := @DoLoadEnd;
  FTabs[idx].ChromiumWindow.ChromiumBrowser.OnTitleChange := @DoTitleChange;
  // Note: OnProcessMessageReceived not available in precompiled CEF4Delphi units
  // Using ExecuteJavaScript polling instead for renderer communication
  FTabs[idx].ChromiumWindow.ChromiumBrowser.DefaultURL := 'about:blank';
  // Set per-tab user data dir (isolated session)
  // CEF4Delphi uses GlobalCEFApp for global paths; per-browser isolation
  // requires separate ICefRequestContext (handled in SpoofTab)

  // Configure spoofing from profile
  if ProfileName <> '' then
  begin
    profile := GetProfile(ProfileName);
    if profile <> nil then
    begin
      SpoofTab(FTabs[idx].TabId, profile);
      profile.Free;
    end;
  end;

  // Activate and navigate
  tbMain.ActivePage := ts;
  FTabs[idx].ChromiumWindow.CreateBrowser;

  WriteLn('[DCv2] Tab created: id=', FNextTabId, ' profile=', ProfileName, ' dir=', FTabs[idx].UserDataDir);
  SendBusJSON('tab.created', 'info', Format('{"tab_id":%d,"profile":"%s","data_dir":"%s"}',
    [FNextTabId, ProfileName, FTabs[idx].UserDataDir]));

  Result := FNextTabId;
  Inc(FNextTabId);
end;

procedure TControllerForm.CloseTab(TabId: Integer);
var
  idx, i: Integer;
begin
  idx := GetTabIndex(TabId);
  if idx < 0 then Exit;

  // Close browser
  FTabs[idx].ChromiumWindow.CloseBrowser(True);
  FTabs[idx].ChromiumWindow.Free;

  // Remove tab sheet
  if idx < tbMain.PageCount then
    tbMain.Pages[idx].Free;

  // Shift array
  for i := idx to FTabCount - 2 do
    FTabs[i] := FTabs[i + 1];
  Dec(FTabCount);
  SetLength(FTabs, FTabCount);

  WriteLn('[DCv2] Tab closed: id=', TabId);
  SendBusJSON('tab.closed', 'info', Format('{"tab_id":%d}', [TabId]));
end;

function TControllerForm.GetTabIndex(TabId: Integer): Integer;
var
  i: Integer;
begin
  for i := 0 to FTabCount - 1 do
    if FTabs[i].TabId = TabId then Exit(i);
  Result := -1;
end;

function TControllerForm.ActiveTabId: Integer;
var
  idx: Integer;
begin
  idx := tbMain.ActivePageIndex;
  if (idx >= 0) and (idx < FTabCount) then
    Result := FTabs[idx].TabId
  else
    Result := -1;
end;

// ═══════════════════════════════════════════════════════════════
// NAVIGATION
// ═══════════════════════════════════════════════════════════════

procedure TControllerForm.Navigate(const url: string; TabId: Integer = -1);
var
  idx: Integer;
  s: string;
  browser: ICefBrowser;
begin
  if TabId < 0 then TabId := ActiveTabId;
  idx := GetTabIndex(TabId);
  if idx < 0 then Exit;

  s := url;
  // FIX 2026-10-21: only bare hostnames get https:// prepended. Internal schemes
  // (chrome://, about:, javascript:, data:, file:, view-source:) must pass through
  // untouched -- otherwise chrome://extensions/ became https://chrome://extensions/.
  if (Pos('://', s) = 0) and (Pos('about:', s) = 0) and (Pos('javascript:', s) = 0) and
     (Pos('data:', s) = 0) and (Pos('file:', s) = 0) and (Pos('chrome://', s) = 0) then
    s := 'https://' + s;

  browser := FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser;
  if browser <> nil then
  begin
    browser.MainFrame.LoadUrl(s);
    WriteLn('[DCv2] Tab ', TabId, ' navigate: ', s);
  end;
end;

procedure TControllerForm.ExecuteJS(const code: string; TabId: Integer = -1);
var
  idx: Integer;
  browser: ICefBrowser;
begin
  if TabId < 0 then TabId := ActiveTabId;
  idx := GetTabIndex(TabId);
  if idx < 0 then Exit;

  browser := FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser;
  if browser <> nil then
  begin
    browser.MainFrame.ExecuteJavaScript(code, '', 0);
    WriteLn('[DCv2] Tab ', TabId, ' JS executed (', Length(code), ' bytes)');
  end;
end;

// Escape string for safe JSON embedding
function EncodeJSON(const s: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(s) do
    case s[i] of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #9: Result := Result + '\t';
      else Result := Result + s[i];
    end;
end;

function TControllerForm.GetActiveURL(TabId: Integer = -1): string;
var
  idx: Integer;
  browser: ICefBrowser;
begin
  if TabId < 0 then TabId := ActiveTabId;
  idx := GetTabIndex(TabId);
  if idx < 0 then Exit('');

  browser := FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser;
  if (browser <> nil) and (browser.MainFrame <> nil) then
    Result := browser.MainFrame.Url
  else
    Result := '';
end;

// ═══════════════════════════════════════════════════════════════
// SPOOFING (native CEF ExecuteJavaScript)
// ═══════════════════════════════════════════════════════════════

function TControllerForm.SpoofTab(TabId: Integer; const ProfileData: TJSONObject; AppliedNow: PBoolean = nil): Boolean;
var
  spoof: TJSONObject;
  ua, plat, lang, tz, res: string;
  js: string;
  idx: Integer;
  tabFound: Boolean;
  hasData: Boolean;
  applied: Boolean;
  dec: TSpoofDecision;
begin
  Result := False;
  if ProfileData = nil then Exit;
  idx := GetTabIndex(TabId);
  tabFound := (idx >= 0);
  if not tabFound then Exit;

  spoof := ProfileData.Get('browser', TJSONObject.Create) as TJSONObject;

  js := '';
  ua := spoof.Get('user_agent', '');
  if ua <> '' then
    js := js + Format('Object.defineProperty(navigator,"userAgent",{get:()=>%s,configurable:true});', [QuotedStr(ua)]);

  plat := spoof.Get('platform', '');
  if plat <> '' then
    js := js + Format('Object.defineProperty(navigator,"platform",{get:()=>%s,configurable:true});', [QuotedStr(plat)]);

  lang := spoof.Get('language', '');
  if lang <> '' then
    js := js + Format('Object.defineProperty(navigator,"languages",{get:()=>["%s","en"],configurable:true});', [lang]);

  res := spoof.Get('screen_resolution', '');
  if res <> '' then
    js := js + Format('var r="%s".split("x");if(r.length==2){Object.defineProperty(screen,"width",{get:()=>parseInt(r[0]),configurable:true});Object.defineProperty(screen,"height",{get:()=>parseInt(r[1]),configurable:true});}', [res]);

  // Canvas anti-fingerprint
  js := js + 'HTMLCanvasElement.prototype.toDataURL=function(){return HTMLCanvasElement.prototype.toDataURL.apply(this).replace(/[a-f0-9]/g,(c,i)=>i%7===0?String.fromCharCode(c.charCodeAt(0)^1):c)};';
  // WebGL spoof
  js := js + 'var gp=WebGLRenderingContext.prototype.getParameter;WebGLRenderingContext.prototype.getParameter=function(p){if(p===0x9245||p===0x8F9D)return"Google Inc.";if(p===0x9246||p===0x8F9C)return"ANGLE (Intel)";return gp.call(this,p)};';

  tz := spoof.Get('timezone', '');
  if tz <> '' then
    js := js + Format('Intl.DateTimeFormat=new Proxy(Intl.DateTimeFormat,{construct:(t,a)=>{var o={...(a[1]||{})};o.timeZone="%s";return Reflect.construct(t,[a[0]||\"en-US\",o],t)}});', [tz]);

  // Geolocation
  if ProfileData.FindPath('address.lat') <> nil then
    js := js + Format('navigator.geolocation.getCurrentPosition=(s)=>{s({coords:{latitude:%s,longitude:%s,accuracy:10},timestamp:Date.now()})};',
      [ProfileData.FindPath('address.lat').AsString, ProfileData.FindPath('address.lng').AsString]);

  // Determine if we have any spoofable data
  hasData := (ua <> '') or (plat <> '') or (lang <> '') or (res <> '') or (tz <> '') or (ProfileData.FindPath('address.lat') <> nil);

  // Check if we can apply NOW (frame exists and is main)
  applied := False;
  if tabFound and hasData then
  begin
    // Try to execute immediately if the browser/frame is ready
    if (idx < FTabCount) and (FTabs[idx].ChromiumWindow <> nil) and
       (FTabs[idx].ChromiumWindow.ChromiumBrowser <> nil) and
       (FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser <> nil) and
       (FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser.GetMainFrame <> nil) then
    begin
      FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser.GetMainFrame.ExecuteJavaScript(js, '', 0);
      applied := True;
      // Mark as applied so DoLoadEnd doesn't re-apply
      if idx >= Length(FSpoofApplied) then
        SetLength(FSpoofApplied, idx + 1);
      FSpoofApplied[idx] := True;
      WriteLn('[DCv2] Spoof JS applied immediately on Tab ', TabId, ': ', Length(js), ' bytes');
    end;
  end;

  // Store spoof JS for this tab (executed on next LoadEnd if not applied now)
  if idx >= Length(FSpoofJS) then
    SetLength(FSpoofJS, idx + 1);
  FSpoofJS[idx] := js;

  // Build SpoofCore decision
  dec := SpoofDecisionFromFlags(True, tabFound, hasData, applied, Length(js));

  // Report back AppliedNow if caller wants it
  if AppliedNow <> nil then
    AppliedNow^ := (dec.Phase = spApplied);

  Result := (dec.Phase <> spError);
  WriteLn('[DCv2] Spoof decision for Tab ', TabId, ': phase=', Ord(dec.Phase), ' applied=', applied, ' js_bytes=', Length(js));
end;

// ═══════════════════════════════════════════════════════════════
// COMMAND HANDLER (IPC Socket)
// ═══════════════════════════════════════════════════════════════

procedure TControllerForm.WriteProxyConfig;
var
  cfg: TStringList;
  cfgPath: string;
begin
  cfgPath := GetUserDir + '.config/dual_citizen/proxy.conf';
  cfg := TStringList.Create;
  try
    if FProxyEnabled and (FProxyHost <> '') then
    begin
      cfg.Add('host=' + FProxyHost);
      cfg.Add('port=' + IntToStr(FProxyPort));
      cfg.Add('enabled=true');
    end
    else
    begin
      cfg.Add('enabled=false');
    end;
    cfg.SaveToFile(cfgPath);
  finally
    cfg.Free;
  end;
end;

procedure TControllerForm.HandleCommand(const cmdLine: string; const ReplySock: Integer = -1);
var
  jobj: TJSONObject;
  cmdAction, cmdId, url, jsCode, profName, tabsJson, response, title: string;
  sel, formJSON: string;
  i: Integer;
  arr: TJSONArray;
  obj: TJSONObject;
  newTabId: Integer;
  spoofObj: TJSONObject;
  expectedUA: string;
  tabId: Integer;
  appliedNow: Boolean;
  ok: Boolean;
  dec: TSpoofDecision;
  tabFound: Boolean;
begin
  try
    jobj := TJSONObject(GetJSON(cmdLine));
    try
      cmdAction := jobj.Get('action', '');
      cmdId  := jobj.Get('id', '0');
      WriteLn('[DCv2] Cmd: ', cmdAction, ' id=', cmdId);

      if cmdAction = 'navigate' then
      begin
        url := jobj.Get('url', 'https://google.com');
        if jobj.FindPath('tab_id') <> nil then
          Navigate(url, jobj.Get('tab_id', ActiveTabId))
        else
          Navigate(url);
        response := Format('{"id":"%s","status":"navigating","url":"%s"}', [cmdId, url]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'execute_javascript' then
      begin
        jsCode := jobj.Get('code', '');
        if jsCode <> '' then
        begin
          ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
          response := Format('{"id":"%s","status":"executed","bytes":%d}', [cmdId, Length(jsCode)]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"empty code"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'create_tab' then
      begin
        profName := jobj.Get('profile', '');
        newTabId := AddTab(profName);
        if newTabId >= 0 then
          response := Format('{"id":"%s","status":"ok","tab_id":%d,"profile":"%s"}', [cmdId, newTabId, profName])
        else
          response := Format('{"id":"%s","status":"error","error":"max tabs reached"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'close_tab' then
      begin
        CloseTab(jobj.Get('tab_id', ActiveTabId));
        response := Format('{"id":"%s","status":"ok"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'activate_tab' then
      begin
        i := GetTabIndex(jobj.Get('tab_id', -1));
        if i >= 0 then
        begin
          tbMain.ActivePageIndex := i;
          response := Format('{"id":"%s","status":"ok","tab_id":%d}', [cmdId, FTabs[i].TabId]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"tab not found"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'list_tabs' then
      begin
        arr := TJSONArray.Create;
        for i := 0 to FTabCount - 1 do
        begin
          obj := TJSONObject.Create;
          obj.Add('tab_id', FTabs[i].TabId);
          obj.Add('profile', FTabs[i].ProfileName);
          obj.Add('data_dir', FTabs[i].UserDataDir);
          arr.Add(obj);
        end;
        tabsJson := arr.AsJSON;
        arr.Free;
        response := Format('{"id":"%s","status":"ok","tabs":%s}', [cmdId, tabsJson]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'status' then
      begin
        response := Format('{"id":"%s","status":"ok","tabs":%d,"active_tab":%d}',
          [cmdId, FTabCount, ActiveTabId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'layout' then
      begin
        arr := TJSONArray.Create;
        for i := 0 to FTabCount - 1 do
        begin
          obj := TJSONObject.Create;
          obj.Add('tab_id', FTabs[i].TabId);
          if FTabs[i].ChromiumWindow <> nil then
          begin
            obj.Add('cef_x', FTabs[i].ChromiumWindow.Left);
            obj.Add('cef_y', FTabs[i].ChromiumWindow.Top);
            obj.Add('cef_w', FTabs[i].ChromiumWindow.Width);
            obj.Add('cef_h', FTabs[i].ChromiumWindow.Height);
            obj.Add('page_w', FTabs[i].ChromiumWindow.Parent.Width);
            obj.Add('page_h', FTabs[i].ChromiumWindow.Parent.Height);
          end;
          arr.Add(obj);
        end;
        tabsJson := arr.AsJSON;
        arr.Free;
        response := Format('{"id":"%s","status":"ok","form_w":%d,"form_h":%d,"pctl_w":%d,"pctl_h":%d,"tabs":%s}',
          [cmdId, Width, Height, tbMain.Width, tbMain.Height, tabsJson]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'get_url' then
      begin
        url := GetActiveURL(jobj.Get('tab_id', ActiveTabId));
        response := Format('{"id":"%s","status":"ok","url":"%s"}', [cmdId, url]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'get_title' then
      begin
        title := GetActiveTitle;
        response := Format('{"id":"%s","status":"ok","title":"%s"}', [cmdId, EncodeJSON(title)]);
        SendReply(ReplySock, response);
      end

      // ── Automation Commands ────────────────────────────────────────
      else if cmdAction = 'evaluate_js' then
      begin
        jsCode := jobj.Get('code', '');
        if jsCode <> '' then
        begin
          // Executes JS and stores JSON result via FEvalResult (full-length, no truncation)
        // FIX: Use IIFE with return to capture expression result in script context
        FEvalResultReady := False;
        jsCode := 'try{window.__dc_eval_result=JSON.stringify((function(){return (' + jsCode + ')})())}catch(e){window.__dc_eval_result=JSON.stringify({error:""+e.message})}';
        ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
          response := Format('{"id":"%s","status":"ok","method":"eval_channel","bytes":%d}', [cmdId, Length(jsCode)]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"empty code"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'get_eval' then
      begin
        // Poll for result: read __dc_eval_result directly and return via document.title with unique prefix
        // FIX: Removed setTimeout - set title directly; prefix with __DC_EVAL__ to distinguish from page titles
        jsCode := 'try{var r=window.__dc_eval_result;window.__dc_eval_result=undefined;document.title="__DC_EVAL__"+JSON.stringify(r)}catch(e){document.title="__DC_EVAL__"+JSON.stringify({error:""+e.message})}';
        ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
        // Check if result is ready from previous poll
        if FEvalResultReady then
        begin
          response := Format('{"id":"%s","status":"ok","result":"%s"}', [cmdId, EncodeJSON(FEvalResult)]);
          FEvalResultReady := False;
          FEvalResult := '';
        end
        else
          response := Format('{"id":"%s","status":"pending"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'click' then
      begin
        sel := jobj.Get('selector', '');
        if sel <> '' then
        begin
          jsCode := 'try{var el=document.querySelector("' + EncodeJSON(sel) + '");if(el){el.click();window.__dc_eval_result=JSON.stringify({clicked:true})}else{window.__dc_eval_result=JSON.stringify({error:"element not found"})}}catch(e){window.__dc_eval_result=JSON.stringify({error:""+e.message})}';
          ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
          response := Format('{"id":"%s","status":"pending","method":"eval_poll","selector":"%s"}', [cmdId, EncodeJSON(sel)]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"no selector"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'form_fill' then
      begin
        formJSON := jobj.Get('fields', '');
        if formJSON <> '' then
        begin
          jsCode := 'try{var f=JSON.parse("' + EncodeJSON(formJSON) + '");Object.keys(f).forEach(function(k){var el=document.querySelector(`[name=''${k}'']`)||document.getElementById(k);if(el){el.value=f[k];el.dispatchEvent(new Event("input",{bubbles:true}));el.dispatchEvent(new Event("change",{bubbles:true}))}});window.__dc_eval_result=JSON.stringify({filled:Object.keys(f).length})}catch(e){window.__dc_eval_result=JSON.stringify({error:""+e.message})}';
          ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
          response := Format('{"id":"%s","status":"pending","method":"eval_poll"}', [cmdId]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"no fields"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'get_form_fields' then
      begin
        jsCode := 'try{document.title=JSON.stringify(Array.from(document.querySelectorAll("input,select,textarea")).map(function(el){return{tag:el.tagName,name:(el.name||""),id:(el.id||""),type:(el.type||""),placeholder:(el.placeholder||""),required:el.required,value:(el.value||""),form:(el.form?el.form.action:"")}}))}catch(e){document.title=JSON.stringify({error:""+e.message})}';
        ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
        response := Format('{"id":"%s","status":"ok","method":"title_channel"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'go_back' then
      begin
        i := GetTabIndex(jobj.Get('tab_id', ActiveTabId));
        if (i >= 0) and (FTabs[i].ChromiumWindow.ChromiumBrowser.Browser <> nil) then
          FTabs[i].ChromiumWindow.ChromiumBrowser.Browser.GoBack;
        response := Format('{"id":"%s","status":"ok"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'go_forward' then
      begin
        i := GetTabIndex(jobj.Get('tab_id', ActiveTabId));
        if (i >= 0) and (FTabs[i].ChromiumWindow.ChromiumBrowser.Browser <> nil) then
          FTabs[i].ChromiumWindow.ChromiumBrowser.Browser.GoForward;
        response := Format('{"id":"%s","status":"ok"}', [cmdId]);
        SendReply(ReplySock, response);
      end
      // ── End Automation Commands ────────────────────────────────────

      else if cmdAction= 'set_proxy' then
      begin
        FProxyHost := jobj.Get('host', '');
        FProxyPort := jobj.Get('port', 0);
        FProxyEnabled := jobj.Get('enabled', True);
        if FProxyHost <> '' then
          WriteLn('[DCv2] Proxy set: ', FProxyHost, ':', FProxyPort)
        else
          WriteLn('[DCv2] Proxy disabled');
        // Write proxy config to file for BrowserProcessManager on restart
        WriteProxyConfig;
        response := Format('{"id":"%s","status":"ok","proxy":{"host":"%s","port":%d,"enabled":%s}}',
          [cmdId, FProxyHost, FProxyPort, LowerCase(BoolToStr(FProxyEnabled, True))]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'get_proxy' then
      begin
        response := Format('{"id":"%s","status":"ok","proxy":{"host":"%s","port":%d,"enabled":%s}}',
          [cmdId, FProxyHost, FProxyPort, LowerCase(BoolToStr(FProxyEnabled, True))]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'spoof' then
      begin
        profName := jobj.Get('profile', '');
        if profName <> '' then
        begin
          obj := GetProfile(profName);
          if obj <> nil then
          begin
            // Use new SpoofTab that returns applied status and uses SpoofCore decision logic
            appliedNow := False;
            tabId := jobj.Get('tab_id', ActiveTabId);
            tabFound := (GetTabIndex(tabId) >= 0);
            ok := SpoofTab(tabId, obj, @appliedNow);
            obj.Free;
            // Build reply using SpoofCore for consistent status semantics
            dec := SpoofDecisionFromFlags(True, tabFound, True, appliedNow, 0);
            response := SpoofReplyJSON(cmdId, profName, dec);
          end
          else
            response := Format('{"id":"%s","status":"error","error":"profile not found"}', [cmdId]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"no profile specified"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction= 'verify_spoof' then
      begin
        // Verify that the spoof actually took effect by reading back navigator.userAgent
        profName := jobj.Get('profile', '');
        if profName <> '' then
        begin
          obj := GetProfile(profName);
          if obj <> nil then
          begin
            spoofObj := obj.Get('browser', TJSONObject.Create) as TJSONObject;
            expectedUA := spoofObj.Get('user_agent', '');
            obj.Free;
            if expectedUA <> '' then
            begin
              // Use evaluate_js -> get_eval polling channel to read back UA
              tabId := jobj.Get('tab_id', ActiveTabId);
              jsCode := 'try{window.__dc_eval_result=JSON.stringify(navigator.userAgent)}catch(e){window.__dc_eval_result=JSON.stringify({error:""+e.message})}';
              ExecuteJS(jsCode, tabId);
              // Store verification context for async callback
              response := Format('{"id":"%s","status":"pending","method":"eval_poll","verify_spoof":true,"expected_ua":"%s"}', [cmdId, EncodeJSON(expectedUA)]);
            end
            else
              response := Format('{"id":"%s","status":"error","error":"no user_agent in profile"}', [cmdId]);
          end
          else
            response := Format('{"id":"%s","status":"error","error":"profile not found"}', [cmdId]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"no profile specified"}', [cmdId]);
        SendReply(ReplySock, response);
      end

            else if cmdAction = 'read_posts' then
      begin
        // Extract posts from Reddit feed
        jsCode := 'try{var posts=[];document.querySelectorAll("div[data-testid=\\"post-container\\"]").forEach(function(el,i){if(i>=25)return;var titleEl=el.querySelector("a[data-testid=\\"post-title\\"]");var authorEl=el.querySelector("a[data-testid=\\"post-author\\"]");var scoreEl=el.querySelector("div[data-testid=\\"score\\"]");var subEl=el.querySelector("a[data-testid=\\"subreddit-link\\"]");var link=titleEl?titleEl.href:"";var title=titleEl?titleEl.innerText.trim():"";var author=authorEl?authorEl.innerText.trim():"";var score=scoreEl?scoreEl.innerText.trim():"";var sub=subEl?subEl.innerText.trim():"";posts.push({title:title,author:author,score:score,subreddit:sub,url:link});});window.__dc_eval_result=JSON.stringify(posts)}catch(e){window.__dc_eval_result=JSON.stringify({error:""+e.message})}';
        ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
        response := Format('{"id":"%s","status":"pending","method":"eval_poll","cmd":"read_posts"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'read_post_detail' then
      begin
        // Get detailed post data including comments
        jsCode := 'try{var post={};var titleEl=document.querySelector("h1[data-testid=\\"post-title\\"]")||document.querySelector("h1");post.title=titleEl?titleEl.innerText.trim():"";var bodyEl=document.querySelector("div[data-testid=\\"post-content\\"]")||document.querySelector("div[data-click-id=\\"text\\"]");post.body=bodyEl?bodyEl.innerText.trim():"";var authorEl=document.querySelector("a[data-testid=\\"post-author\\"]");post.author=authorEl?authorEl.innerText.trim():"";var scoreEl=document.querySelector("div[data-testid=\\"score\\"]");post.score=scoreEl?scoreEl.innerText.trim():"";var subEl=document.querySelector("a[data-testid=\\"subreddit-link\\"]");post.subreddit=subEl?subEl.innerText.trim():"";var comments=[];document.querySelectorAll("div[data-testid=\\"comment\\"]").forEach(function(c,i){if(i>=10)return;var ca=c.querySelector("a[data-testid=\\"comment-author\\"]");var ct=c.querySelector("div[data-testid=\\"comment-content\\"]")||c.querySelector("p");var cs=c.querySelector("button[data-testid=\\"comment-score\\"]");comments.push({author:ca?ca.innerText.trim():"",text:ct?ct.innerText.trim():"",score:cs?cs.innerText.trim():""});});post.comments=comments;window.__dc_eval_result=JSON.stringify(post)}catch(e){window.__dc_eval_result=JSON.stringify({error:""+e.message})}';
        ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
        response := Format('{"id":"%s","status":"pending","method":"eval_poll","cmd":"read_post_detail"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'comment_on_post' then
      begin
        // Post a comment on current post
        commentText := jobj.Get('text', '');
        if commentText <> '' then
        begin
          jsCode := 'try{var box=document.querySelector("div[data-testid=\\"comment-box\\"] textarea")||document.querySelector("textarea[placeholder*=\\"comment\\" i]")||document.querySelector("textarea");if(!box){window.__dc_eval_result=JSON.stringify({error:"comment box not found"});throw"box"}box.value="'+EncodeJSON(commentText)+'";box.dispatchEvent(new Event("input",{bubbles:true}));var btn=document.querySelector("button[data-testid=\\"comment-submit\\"]")||document.querySelector("button[type=\\"submit\\"]")||Array.from(document.querySelectorAll("button")).find(b=>b.innerText.includes("Comment"));if(btn){btn.click();window.__dc_eval_result=JSON.stringify({commented:true})}else{window.__dc_eval_result=JSON.stringify({error:"submit button not found"})}}catch(e){window.__dc_eval_result=JSON.stringify({error:""+e.message})}';
          ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
          response := Format('{"id":"%s","status":"pending","method":"eval_poll","cmd":"comment_on_post"}', [cmdId]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"no comment text"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'vote_post' then
      begin
        // Upvote or downvote current post
        direction := jobj.Get('direction', 'up'); // 'up' or 'down'
        btnSel := '';
        if direction = 'down' then
          btnSel := 'button[data-testid=\\"vote-down\\"],button[aria-label*=\\"Downvote\\" i]'
        else
          btnSel := 'button[data-testid=\\"vote-up\\"],button[aria-label*=\\"Upvote\\" i]';
        jsCode := 'try{var btn=document.querySelector("'+btnSel+'");if(btn){btn.click();window.__dc_eval_result=JSON.stringify({voted:"'+direction+'",success:true})}else{window.__dc_eval_result=JSON.stringify({voted:"'+direction+'",success:false,error:"button not found"})}}catch(e){window.__dc_eval_result=JSON.stringify({error:""+e.message})}';
        ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
        response := Format('{"id":"%s","status":"pending","method":"eval_poll","cmd":"vote_post"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'create_post' then
      begin
        // Create a new post in current subreddit
        postTitle := jobj.Get('title', '');
        postBody := jobj.Get('body', '');
        if (postTitle <> '') then
        begin
          jsCode := 'try{var createBtn=document.querySelector("a[data-testid=\\"create-post-button\\"]")||document.querySelector("button[data-testid=\\"create-post-button\\"]")||Array.from(document.querySelectorAll("a,button")).find(el=>el.innerText.includes("Create Post"));if(createBtn){createBtn.click();setTimeout(function(){var titleIn=document.querySelector("input[data-testid=\\"post-title-input\\"]")||document.querySelector("input[placeholder*=\\"Title\\" i]");var bodyIn=document.querySelector("div[data-testid=\\"post-body\\"]")||document.querySelector("textarea[placeholder*=\\"Text\\" i]")||document.querySelector("div[contenteditable=\\"true\\"]");if(titleIn){titleIn.value="'+EncodeJSON(postTitle)+'";titleIn.dispatchEvent(new Event("input",{bubbles:true}))}if(bodyIn){bodyIn.value="'+EncodeJSON(postBody)+'";bodyIn.dispatchEvent(new Event("input",{bubbles:true}))}var postBtn=document.querySelector("button[data-testid=\\"post-submit\\"]")||document.querySelector("button[type=\\"submit\\"]")||Array.from(document.querySelectorAll("button")).find(b=>b.innerText.includes("Post"));if(postBtn){postBtn.click();window.__dc_eval_result=JSON.stringify({posted:true})}else{window.__dc_eval_result=JSON.stringify({error:"post button not found"})}},500)}else{window.__dc_eval_result=JSON.stringify({error:"create post button not found"})}}catch(e){window.__dc_eval_result=JSON.stringify({error:""+e.message})}';
          ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
          response := Format('{"id":"%s","status":"pending","method":"eval_poll","cmd":"create_post"}', [cmdId]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"no title"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'navigate_subreddit' then
      begin
        // Navigate to a subreddit
        subName := jobj.Get('subreddit', '');
        if subName <> '' then
        begin
          if not (Pos('r/', subName) = 1) and not (Pos('https://', subName) = 1) then
            subName := 'https://www.reddit.com/r/' + subName + '/';
          jsCode := 'window.location.href="'+EncodeJSON(subName)+'"';
          ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
          response := Format('{"id":"%s","status":"ok","navigated":"%s"}', [cmdId, EncodeJSON(subName)]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"no subreddit"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'search_subreddit' then
      begin
        // Search within current subreddit
        query := jobj.Get('query', '');
        if query <> '' then
        begin
          jsCode := 'try{var searchIn=document.querySelector("input[data-testid=\\"search-input\\"]")||document.querySelector("input[placeholder*=\\"Search\\" i]");if(searchIn){searchIn.value="'+EncodeJSON(query)+'";searchIn.dispatchEvent(new Event("input",{bubbles:true}));searchIn.dispatchEvent(new Event("keydown",{key:"Enter",bubbles:true}));document.title=JSON.stringify({searched:true})}else{document.title=JSON.stringify({error:"search input not found"})}}catch(e){document.title=JSON.stringify({error:""+e.message})}';
          ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
          response := Format('{"id":"%s","status":"ok","method":"eval_channel","cmd":"search_subreddit"}', [cmdId]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"no query"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'get_user_profile' then
      begin
        // Get current user profile info
        jsCode := 'try{var user={};var avatar=document.querySelector("img[data-testid=\\"user-avatar\\"]")||document.querySelector("img[alt*=\\"avatar\\" i]");user.avatar=avatar?avatar.src:"";var name=document.querySelector("span[data-testid=\\"username\\"]")||document.querySelector("a[href*=\\/user\\/]");user.name=name?name.innerText.trim():"";var karma=document.querySelector("span[data-testid=\\"karma\\"]");user.karma=karma?karma.innerText.trim():"";window.__dc_eval_result=JSON.stringify(user)}catch(e){window.__dc_eval_result=JSON.stringify({error:""+e.message})}';
        ExecuteJS(jsCode, jobj.Get('tab_id', ActiveTabId));
        response := Format('{"id":"%s","status":"pending","method":"eval_poll","cmd":"get_user_profile"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else if cmdAction = 'inject_renderer_bridge' then
      begin
        i := GetTabIndex(jobj.Get('tab_id', ActiveTabId));
        if (i >= 0) and (FTabs[i].ChromiumWindow.ChromiumBrowser.Browser <> nil) then
        begin
          InjectRendererBridge(FTabs[i].ChromiumWindow.ChromiumBrowser.Browser, i);
          response := Format('{"id":"%s","status":"ok","injected":true}', [cmdId]);
        end
        else
          response := Format('{"id":"%s","status":"error","error":"tab not found"}', [cmdId]);
        SendReply(ReplySock, response);
      end

      else
      begin
        response := Format('{"id":"%s","status":"error","error":"unknown action: %s"}', [cmdId, action]);
        SendReply(ReplySock, response);
      end;

      SendBusJSON('browser.response', 'result', response);
    finally
      jobj.Free;
    end;
  except
    on E: Exception do
      SendBusJSON('browser.response', 'error',
        Format('{"error":"%s"}', [E.Message]));
  end;
end;

procedure TControllerForm.ProcessCommands;
var
  ClientSock, ClientFlags: Integer;
  buf: array[0..65535] of Byte;
  n: Integer;
  line: string;
  p: Integer;
begin
  if FCmdSock >= 0 then
  begin
    ClientSock := fpAccept(FCmdSock, nil, nil);
    if ClientSock >= 0 then
    begin
      n := fpRead(ClientSock, @buf, SizeOf(buf));
      if n > 0 then
      begin
        SetString(line, PChar(@buf), n);
        FCmdBuf := FCmdBuf + line;
        p := Pos(#10, FCmdBuf);
        while p > 0 do
        begin
          HandleCommand(Trim(Copy(FCmdBuf, 1, p - 1)), ClientSock);
          Delete(FCmdBuf, 1, p);
          p := Pos(#10, FCmdBuf);
        end;
      end;
      fpClose(ClientSock);
    end;
  end;
end;

// ═══════════════════════════════════════════════════════════════
// CEF EVENT HANDLERS
// ═══════════════════════════════════════════════════════════════

procedure TControllerForm.DoAfterCreated(Sender: TObject; const browser: ICefBrowser);
var
  i: Integer;
  bid: Integer;
  cw: TChromiumWindow;
begin
  WriteLn('[DCv2] Browser ready');
  SetupRendererBridge(browser);
  SendBusJSON('browser.status', 'ready',
    '{"status":"ready","chromium":"131.0.6778.265","version":"dual_citizen_v2"}');

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

procedure TControllerForm.DoBeforePopup(Sender: TObject; const browser: ICefBrowser;
  const frame: ICefFrame; popup_id: Integer;
  const targetUrl, targetFrameName: ustring;
  targetDisposition: TCefWindowOpenDisposition; userGesture: Boolean;
  const popupFeatures: TCefPopupFeatures; var windowInfo: TCefWindowInfo;
  var client: ICefClient; var settings: TCefBrowserSettings;
  var extra_info: ICefDictionaryValue; var noJavascriptAccess: Boolean;
  var Result: Boolean);
var
  newTabId: Integer;
  popupUrl: string;
begin
  // Cancel the rogue popup window
  Result := True;

  popupUrl := targetUrl;
  if popupUrl = '' then
    Exit;

  WriteLn('[DCv2] Popup intercepted: ', popupUrl);

  // Create a new tab and navigate to the popup URL
  newTabId := AddTab('');
  if newTabId >= 0 then
  begin
    Navigate(popupUrl, newTabId);
    SendBusJSON('browser.popup', 'info',
      Format('{"source_tab":%d,"target_tab":%d,"url":"%s"}',
        [ActiveTabId, newTabId, EncodeJSON(popupUrl)]));
    WriteLn('[DCv2] Popup routed to tab ', newTabId, ': ', popupUrl);
  end
  else
    WriteLn('[DCv2] WARNING: Could not create tab for popup (max tabs?)');
end;

procedure TControllerForm.DoLoadEnd(Sender: TObject; const browser: ICefBrowser;
  const frame: ICefFrame; httpStatusCode: Integer);
var
  i: Integer;
begin
  if frame.IsMain then
  begin
    WriteLn('[DCv2] Page loaded: ', httpStatusCode);
    SendBusJSON('browser.load', 'info',
      Format('{"status":"loaded","http_code":%d,"url":"%s"}', [httpStatusCode, frame.Url]));

    // Execute spoof JS for this tab ONLY if not already applied
    for i := 0 to FTabCount - 1 do
      if (FTabs[i].ChromiumWindow.ChromiumBrowser.Browser = browser) and (i < Length(FSpoofJS)) then
      begin
        if (FSpoofJS[i] <> '') and ((i >= Length(FSpoofApplied)) or (not FSpoofApplied[i])) then
        begin
          browser.MainFrame.ExecuteJavaScript(FSpoofJS[i], '', 0);
          WriteLn('[DCv2] Spoof JS executed on Tab ', FTabs[i].TabId, ' (on LoadEnd)');
          // Mark as applied
          if i >= Length(FSpoofApplied) then
            SetLength(FSpoofApplied, i + 1);
          FSpoofApplied[i] := True;
        end;
        // Inject renderer bridge after page load
        if not FRendererScriptInjected[i] then
          InjectRendererBridge(browser, i);
        Break;
      end;

    // Asset system: inject spoof + css for the site owning this tab (auto, config-driven)
    i := 0;
    while (i < FTabCount) and (FTabs[i].ChromiumWindow.ChromiumBrowser.Browser <> browser) do Inc(i);
    if i < FTabCount then InjectSiteAssets(i, frame.Url);
  end;
end;

procedure TControllerForm.DoTitleChange(Sender: TObject; const browser: ICefBrowser;
  const title: ustring);
var
  i: Integer;
  bid: Integer;
  evalPrefix: string;
  evalResult: string;
begin
  if (FTabCount = 0) or (browser = nil) then Exit;
  bid := browser.Identifier;
  for i := 0 to FTabCount - 1 do
    if FTabs[i].ChromiumWindow.ChromiumBrowser.Browser <> nil then
      if FTabs[i].ChromiumWindow.ChromiumBrowser.Browser.Identifier = bid then
      begin
        if tbMain.Pages[i] <> nil then
          tbMain.Pages[i].Caption := Copy(title, 1, 30);
        // Store full title for evaluate_js return channel
        // ONLY capture results with __DC_EVAL__ prefix — ignore regular page titles
        evalPrefix := '__DC_EVAL__';
        if (Length(title) > Length(evalPrefix)) and (Copy(title, 1, Length(evalPrefix)) = evalPrefix) then
        begin
          evalResult := Copy(title, Length(evalPrefix) + 1, MaxInt);
          if not FEvalResultReady then
          begin
            FEvalResult := evalResult;
            FEvalResultReady := True;
          end;
        end;
        Break;
      end;
end;

function TControllerForm.GetActiveTitle: string;
var
  idx: Integer;
begin
  Result := '';
  idx := tbMain.ActivePageIndex;
  if (idx >= 0) and (idx < FTabCount) then
    Result := tbMain.Pages[idx].Caption;
end;

procedure TControllerForm.DoAddressChange(Sender: TObject; const browser: ICefBrowser;
  const frame: ICefFrame; const url: ustring);
begin
  if frame.IsMain then
  begin
    edAddress.Text := url;
    SendBusJSON('browser.navigate', 'info', Format('{"url":"%s"}', [url]));
  end;
end;

{ ════════════════════════════════════════════════════════════════
  ASSET SYSTEM — on-disk asset loader (shared by facebook / reddit browsers)
  Reads per-site asset manifests (asset_manifest.json / manifest.json),
  verifies sha256 checksums, injects spoof + css at DoLoadEnd, and exposes
  selector_map / payload_map lookups for automation commands.
  ════════════════════════════════════════════════════════════════ }

function TControllerForm.AssetPath(const Site, RelPath: string): string;
begin
  Result := ASSETS_ROOT + Site + '/' + RelPath;
end;

function TControllerForm.ReadTextFile(const Path: string; out AText: string): Boolean;
var
  sl: TStringList;
  relPath: string;
begin
  Result := False;

  // First, try to load from embedded assets
  // Path is typically ASSETS_ROOT + Site + '/' + RelPath
  // Extract relative path from ASSETS_ROOT
  if (Length(ASSETS_ROOT) > 0) and (Pos(ASSETS_ROOT, Path) = 1) then
  begin
    relPath := Copy(Path, Length(ASSETS_ROOT) + 1);
    if HasEmbeddedAsset(relPath) then
    begin
      if EmbeddedAsset(relPath, AText) then
      begin
        Result := True;
        Exit;
      end;
    end;
  end;

  // Fallback to filesystem
  if not FileExists(Path) then Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(Path);
    AText := sl.Text;
    Result := True;
  finally
    sl.Free;
  end;
end;

function TControllerForm.ComputeSHA256(const Path: string; out Hash: string): Boolean;
const
  TMP = '/tmp/dc_asset_sha256.tmp';
var
  sl: TStringList;
  line: string;
begin
  Result := False;
  Hash := '';
  if not FileExists(Path) then Exit;
  if fpSystem('sha256sum ' + QuotedStr(Path) + ' > ' + TMP) <> 0 then Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(TMP);
    if sl.Count > 0 then
    begin
      line := Trim(sl[0]);
      Hash := Copy(line, 1, Pos(' ', line) - 1);
      Result := (Length(Hash) = 64);
    end;
  finally
    sl.Free;
  end;
  DeleteFile(TMP);
end;

function TControllerForm.JSStr(const s: string): string;
begin
  Result := s;
  Result := StringReplace(Result, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '''', '\' + '''', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
  Result := StringReplace(Result, #13, '\r', [rfReplaceAll]);
  Result := StringReplace(Result, #9, '\t', [rfReplaceAll]);
  Result := '''' + Result + '''';
end;

function TControllerForm.AssetBundleIndex(const Site: string): Integer;
var
  b: Integer;
begin
  Result := -1;
  for b := 0 to High(FAssets) do
    if FAssets[b].Site = Site then
    begin
      Result := b;
      Exit;
    end;
end;

function TControllerForm.SiteMatchesURL(const Bundle: TAssetBundle; const URL: string): Boolean;
var
  e: Integer;
  ep, host: string;
  p: Integer;
begin
  Result := False;
  for e := 0 to High(Bundle.Endpoints) do
  begin
    ep := Bundle.Endpoints[e];
    if ep = '' then Continue;
    if Pos(ep, URL) = 1 then
    begin
      Result := True;
      Exit;
    end;
    p := Pos('://', ep);
    if p > 0 then
    begin
      host := Copy(ep, p + 3, Length(ep));
      p := Pos('/', host);
      if p > 0 then host := Copy(host, 1, p - 1);
      if (host <> '') and (Pos(host, URL) > 0) then
      begin
        Result := True;
        Exit;
      end;
    end;
  end;
end;

procedure TControllerForm.EnsureTabAssetArrays(TabIndex: Integer);
begin
  if TabIndex >= Length(FTabAssetInjected) then
    SetLength(FTabAssetInjected, TabIndex + 1);
end;

function TControllerForm.LoadAssetManifest(const Site: string): Boolean;
var
  cand: string;
  sl: TStringList;
  data, arr: TJSONData;
  obj, assetsObj: TJSONObject;
  bundle: TAssetBundle;
  bi, n, i: Integer;
  ref: TAssetRef;
  full, rel, expected: string;
  ok: Boolean;
  mtime: Int64;

  function ExpectedSHA256(const Rel: string): string;
  var
    i: Integer;
  begin
    Result := '';
    if assetsObj = nil then Exit;
    for i := 0 to assetsObj.Count - 1 do
      if assetsObj.Names[i] = Rel then
      begin
        if assetsObj.Items[i] is TJSONObject then
          Result := TJSONObject(assetsObj.Items[i]).Get('sha256', '');
        Exit;
      end;
  end;

  procedure ProcessEntry(const Kind: string; const Rel: string; const IsData: Boolean);
  var
    r: TAssetRef;
  begin
    full := ASSETS_ROOT + Rel;
    r.FileName := Rel;
    r.ExpectedSHA256 := ExpectedSHA256(Rel);
    r.ActualSHA256 := '';
    r.Content := '';
    r.Loaded := False;
    r.Valid := False;
    r.LoadError := '';
    ok := ReadTextFile(full, r.Content);
    if ok then
    begin
      ok := ComputeSHA256(full, r.ActualSHA256);
      if ok and (r.ExpectedSHA256 <> '') and (r.ActualSHA256 <> r.ExpectedSHA256) then
      begin
        r.LoadError := 'sha256 mismatch (expected ' + r.ExpectedSHA256 + ', got ' + r.ActualSHA256 + ')';
        ok := False;
      end;
    end
    else
      r.LoadError := 'file not found: ' + full;
    r.Loaded := ok;
    r.Valid := ok;
    if not ok then
      WriteLn('[DCv2] Asset load warning for site ', Site, ': ', r.LoadError);
    if IsData then
    begin
      if bundle.SelectorMap.Loaded then bundle.PayloadMap := r
      else bundle.SelectorMap := r;
    end
    else if Kind = 'stylesheet' then
    begin
      n := Length(bundle.Stylesheets);
      SetLength(bundle.Stylesheets, n + 1);
      bundle.Stylesheets[n] := r;
    end
    else
    begin
      n := Length(bundle.Scripts);
      SetLength(bundle.Scripts, n + 1);
      bundle.Scripts[n] := r;
    end;
  end;

begin
  Result := False;
  cand := AssetPath(Site, MANIFEST_ASSET);
  if not FileExists(cand) then cand := AssetPath(Site, MANIFEST_LEGACY);
  if not FileExists(cand) then
  begin
    WriteLn('[DCv2] Asset manifest not found for site ', Site);
    Exit;
  end;

  sl := TStringList.Create;
  try
    sl.LoadFromFile(cand);
    data := GetJSON(sl.Text);
  finally
    sl.Free;
  end;
  if (data = nil) or not (data is TJSONObject) then
  begin
    data.Free;
    WriteLn('[DCv2] Asset manifest for site ', Site, ' is not a JSON object');
    Exit;
  end;
  obj := TJSONObject(data);
  assetsObj := obj.FindPath('assets') as TJSONObject;

  bundle.Site := Site;
  bundle.Version := '';
  if obj.FindPath('version') <> nil then bundle.Version := obj.FindPath('version').AsString;
  bundle.SchemaVersion := '';
  if obj.FindPath('schema_version') <> nil then bundle.SchemaVersion := obj.FindPath('schema_version').AsString
  else if obj.FindPath('_schema') <> nil then bundle.SchemaVersion := obj.FindPath('_schema').AsString;
  bundle.CEFVersionMin := '';
  if obj.FindPath('cef_version_min') <> nil then bundle.CEFVersionMin := obj.FindPath('cef_version_min').AsString;
  bundle.CEFVersionMax := '';
  if obj.FindPath('cef_version_max') <> nil then bundle.CEFVersionMax := obj.FindPath('cef_version_max').AsString;
  bundle.ManifestPath := cand;
  bundle.Loaded := False;
  bundle.LoadError := '';
  bundle.Scripts := nil;
  bundle.Stylesheets := nil;
  bundle.SelectorMap.Loaded := False;
  bundle.PayloadMap.Loaded := False;
  SetLength(bundle.Endpoints, 0);

  arr := obj.FindPath('endpoints');
  if arr is TJSONArray then
  begin
    SetLength(bundle.Endpoints, TJSONArray(arr).Count);
    for i := 0 to TJSONArray(arr).Count - 1 do
      bundle.Endpoints[i] := TJSONArray(arr).Items[i].AsString;
  end;

  arr := obj.FindPath('injection_order');
  if arr is TJSONArray then
    for i := 0 to TJSONArray(arr).Count - 1 do
      ProcessEntry('script', TJSONArray(arr).Items[i].AsString, False);

  arr := obj.FindPath('css');
  if arr is TJSONArray then
    for i := 0 to TJSONArray(arr).Count - 1 do
      ProcessEntry('stylesheet', TJSONArray(arr).Items[i].AsString, False);

  arr := obj.FindPath('data');
  if arr is TJSONArray then
    for i := 0 to TJSONArray(arr).Count - 1 do
      ProcessEntry('data', TJSONArray(arr).Items[i].AsString, True);

  mtime := FileAge(cand);
  bundle.ManifestMtime := mtime;
  bundle.Loaded := True;

  bi := AssetBundleIndex(Site);
  if bi >= 0 then FAssets[bi] := bundle
  else
  begin
    n := Length(FAssets);
    SetLength(FAssets, n + 1);
    FAssets[n] := bundle;
  end;

  data.Free;
  Result := True;
  WriteLn('[DCv2] Asset manifest loaded for site ', Site,
    ' (scripts=', Length(bundle.Scripts),
    ' stylesheets=', Length(bundle.Stylesheets),
    ' selector_map=', bundle.SelectorMap.Loaded,
    ' payload_map=', bundle.PayloadMap.Loaded, ')');
end;

function TControllerForm.InjectAsset(const Site: string; AssetType: TAssetType; TabIndex: Integer): Boolean;
var
  bi: Integer;
  bundle: TAssetBundle;
  i: Integer;
  ref: TAssetRef;
  wrapped: string;
  browser: ICefBrowser;
  tabId: Integer;
begin
  Result := False;
  if TabIndex < 0 then Exit;
  EnsureTabAssetArrays(TabIndex);

  bi := AssetBundleIndex(Site);
  if bi < 0 then
  begin
    if not LoadAssetManifest(Site) then Exit;
    bi := AssetBundleIndex(Site);
    if bi < 0 then Exit;
  end;
  bundle := FAssets[bi];

  if TabIndex >= Length(FTabs) then Exit;
  browser := FTabs[TabIndex].ChromiumWindow.ChromiumBrowser.Browser;
  if browser = nil then Exit;
  tabId := FTabs[TabIndex].TabId;

  case AssetType of
    atSpoof:
      begin
        for i := 0 to High(bundle.Scripts) do
        begin
          ref := bundle.Scripts[i];
          if (not ref.Valid) or (ref.Content = '') then Continue;
          wrapped := '(function(){' + #10 + ref.Content + #10 + '})();';
          browser.MainFrame.ExecuteJavaScript(wrapped, '', 0);
          WriteLn('[DCv2] Spoof injected on Tab ', tabId, ': ', ref.FileName,
            ' (', Length(wrapped), ' bytes)');
        end;
        Include(FTabAssetInjected[TabIndex], atSpoof);
      end;
    atCSS:
      begin
        for i := 0 to High(bundle.Stylesheets) do
        begin
          ref := bundle.Stylesheets[i];
          if (not ref.Valid) or (ref.Content = '') then Continue;
          wrapped := '(function(){var s=document.createElement("style");' +
            's.type="text/css";s.textContent=' + JSStr(ref.Content) + ';' +
            '(document.head||document.documentElement).appendChild(s);})();';
          browser.MainFrame.ExecuteJavaScript(wrapped, '', 0);
          WriteLn('[DCv2] CSS injected on Tab ', tabId, ': ', ref.FileName,
            ' (', Length(wrapped), ' bytes)');
        end;
        Include(FTabAssetInjected[TabIndex], atCSS);
      end;
    atSelectorMap, atPayloadMap:
      begin
        // Data assets live in memory only; nothing to inject into the renderer.
        Result := True;
        Exit;
      end;
  end;
  Result := True;
end;

function TControllerForm.InjectSpoof(const Site: string; TabIndex: Integer = -1): Boolean;
begin
  Result := InjectAsset(Site, atSpoof, TabIndex);
end;

function TControllerForm.InjectCSS(const Site: string; TabIndex: Integer = -1): Boolean;
begin
  Result := InjectAsset(Site, atCSS, TabIndex);
end;

procedure TControllerForm.InjectSiteAssets(TabIndex: Integer; const URL: string);
var
  site: string;
  b: Integer;
begin
  if TabIndex < 0 then Exit;
  site := '';
  for b := 0 to High(FAssets) do
    if SiteMatchesURL(FAssets[b], URL) then
    begin
      site := FAssets[b].Site;
      Break;
    end;
  // Fallback: lazy-load a manifest for a site guessed from the URL host.
  if site = '' then
  begin
    if Pos('facebook.com', URL) > 0 then site := 'facebook'
    else if Pos('reddit.com', URL) > 0 then site := 'reddit';
    if (site <> '') and LoadAssetManifest(site) then
    begin
      b := AssetBundleIndex(site);
      if (b >= 0) and SiteMatchesURL(FAssets[b], URL) then site := FAssets[b].Site
      else site := '';
    end
    else
      site := '';
  end;
  if site = '' then Exit;
  if not (atSpoof in FTabAssetInjected[TabIndex]) then
    InjectAsset(site, atSpoof, TabIndex);
  if not (atCSS in FTabAssetInjected[TabIndex]) then
    InjectAsset(site, atCSS, TabIndex);
end;

function TControllerForm.GetSelector(const Site, Category, SelAction: string; out Selector: string): Boolean;
var
  bi: Integer;
  bundle: TAssetBundle;
  data: TJSONData;
  node: TJSONData;
  path: string;
begin
  Result := False;
  Selector := '';
  bi := AssetBundleIndex(Site);
  if bi < 0 then
    if not LoadAssetManifest(Site) then Exit;
  bi := AssetBundleIndex(Site);
  if bi < 0 then Exit;
  bundle := FAssets[bi];
  if (not bundle.SelectorMap.Valid) or (bundle.SelectorMap.Content = '') then Exit;

  data := GetJSON(bundle.SelectorMap.Content);
  if data = nil then Exit;
  try
    // 1) Flat convention: selectors.<category>.<action>.primary  (facebook)
    if Category <> '' then
    begin
      path := 'selectors.' + Category + '.' + SelAction + '.primary';
      node := data.FindPath(path);
      if node <> nil then
      begin
        Selector := node.AsString;
        if Selector <> '' then
        begin
          Result := True;
          Exit;
        end;
      end;
      // fallback: first entry of the .fallback array
      path := 'selectors.' + Category + '.' + SelAction + '.fallback';
      node := data.FindPath(path);
      if node is TJSONArray then
        if TJSONArray(node).Count > 0 then
        begin
          Selector := TJSONArray(node).Items[0].AsString;
          if Selector <> '' then
          begin
            Result := True;
            Exit;
          end;
        end;
    end;
    // 2) Platform convention: actions.<action>.new then .old (reddit)
    path := 'actions.' + SelAction + '.new';
    node := data.FindPath(path);
    if node <> nil then
    begin
      Selector := node.AsString;
      if Selector <> '' then
      begin
        Result := True;
        Exit;
      end;
    end;
    path := 'actions.' + SelAction + '.old';
    node := data.FindPath(path);
    if node <> nil then
    begin
      Selector := node.AsString;
      if Selector <> '' then
      begin
        Result := True;
        Exit;
      end;
    end;
  finally
    data.Free;
  end;
end;

function TControllerForm.GetPayload(const Site, SelAction: string; out PayloadJSON: string): Boolean;
var
  bi: Integer;
  bundle: TAssetBundle;
  data: TJSONData;
  node: TJSONData;
  path: string;
begin
  Result := False;
  PayloadJSON := '';
  bi := AssetBundleIndex(Site);
  if bi < 0 then
    if not LoadAssetManifest(Site) then Exit;
  bi := AssetBundleIndex(Site);
  if bi < 0 then Exit;
  bundle := FAssets[bi];
  if (not bundle.PayloadMap.Valid) or (bundle.PayloadMap.Content = '') then Exit;

  data := GetJSON(bundle.PayloadMap.Content);
  if data = nil then Exit;
  try
    path := 'payloads.' + SelAction;
    node := data.FindPath(path);
    if node <> nil then
    begin
      PayloadJSON := node.AsJSON;
      Result := (PayloadJSON <> '');
    end;
  finally
    data.Free;
  end;
end;

function TControllerForm.GetJSONValue(const Site, DottedPath: string; out Value: string): Boolean;
var
  bi: Integer;
  bundle: TAssetBundle;
  data: TJSONData;
  node: TJSONData;
begin
  Result := False;
  Value := '';
  bi := AssetBundleIndex(Site);
  if bi < 0 then
    if not LoadAssetManifest(Site) then Exit;
  bi := AssetBundleIndex(Site);
  if bi < 0 then Exit;
  bundle := FAssets[bi];

  data := GetJSON(bundle.SelectorMap.Content);
  if data <> nil then
  begin
    node := data.FindPath(DottedPath);
    if node <> nil then
    begin
      Value := node.AsString;
      Result := (Value <> '');
    end;
    data.Free;
  end;
  if not Result and (bundle.PayloadMap.Content <> '') then
  begin
    data := GetJSON(bundle.PayloadMap.Content);
    if data <> nil then
    begin
      node := data.FindPath(DottedPath);
      if node <> nil then
      begin
        Value := node.AsString;
        Result := (Value <> '');
      end;
      data.Free;
    end;
  end;
end;

procedure TControllerForm.ReloadAssetsIfChanged;
var
  b: Integer;
  t: Integer;
  mtime: Int64;
begin
  for b := 0 to High(FAssets) do
  begin
    if FAssets[b].ManifestPath = '' then Continue;
    if not FileExists(FAssets[b].ManifestPath) then Continue;
    mtime := FileAge(FAssets[b].ManifestPath);
    if mtime <> FAssets[b].ManifestMtime then
    begin
      WriteLn('[DCv2] Asset manifest changed for site ', FAssets[b].Site, ' — reloading');
      LoadAssetManifest(FAssets[b].Site);
      for t := 0 to High(FTabAssetInjected) do
        FTabAssetInjected[t] := [];
    end;
  end;
end;

// ════════════════════════════════════════════════════════════════

procedure TControllerForm.SetupRendererBridge(const browser: ICefBrowser);
begin
  WriteLn('[DCv2] Renderer bridge initialized for browser ', browser.Identifier);
end;

procedure TControllerForm.InjectRendererBridge(const browser: ICefBrowser; TabIndex: Integer);
var
  jsContent: TStringList;
  jsCode, escapedCode: string;
  scriptPath: string;
begin
  if TabIndex < 0 then Exit;
  if FRendererScriptInjected[TabIndex] then Exit;

  scriptPath := ExtractFilePath(ParamStr(0)) + 'dc_agent.js';
  if not FileExists(scriptPath) then
  begin
    WriteLn('[DCv2] ERROR: dc_agent.js not found at ', scriptPath);
    Exit;
  end;

  jsContent := TStringList.Create;
    try
      jsContent.LoadFromFile(scriptPath);
      jsCode := jsContent.Text;
      // Escape for safe JS string embedding - use constants to avoid line length issues
      escapedCode := StringReplace(jsCode, '\', '\\', [rfReplaceAll]);
      escapedCode := StringReplace(escapedCode, #39, '\' + #39, [rfReplaceAll]);  // #39 = single quote
      escapedCode := StringReplace(escapedCode, #10, '\n', [rfReplaceAll]);
      escapedCode := StringReplace(escapedCode, #13, '\r', [rfReplaceAll]);
      escapedCode := StringReplace(escapedCode, #9, '\t', [rfReplaceAll]);
      escapedCode := '(function(){' + #10 + escapedCode + #10 + '})();';
      browser.MainFrame.ExecuteJavaScript(escapedCode, '', 0);
      FRendererScriptInjected[TabIndex] := True;
      WriteLn('[DCv2] Renderer bridge injected on TabIndex ', TabIndex, ' (', Length(escapedCode), ' bytes)');
    finally
      jsContent.Free;
    end;
  end;

function TControllerForm.GenerateCommandId: string;
begin
  Result := 'cmd_' + IntToStr(TThread.CurrentThread.ThreadID) + '_' + IntToStr(GetTickCount64);
end;

procedure TControllerForm.ResolvePendingCommand(const json: string);
var
  params: TJSONObject;
  cmdId: string;
  idx: Integer;
begin
  try
    params := TJSONObject(GetJSON(json));
    cmdId := params.Get('id', '');
    if cmdId = '' then Exit;

    idx := FPendingCommands.IndexOf(cmdId);
    if idx >= 0 then
    begin
      WriteLn('[DCv2] Resolved pending command: ', cmdId);
      FPendingCommands.Delete(idx);
    end;
    params.Free;
  except
    on E: Exception do
      WriteLn('[DCv2] ResolvePendingCommand error: ', E.Message);
  end;
end;

function TControllerForm.GetTabIndexByBrowser(const browser: ICefBrowser): Integer;
var
  i: Integer;
  cw: TChromiumWindow;
begin
  Result := -1;
  for i := 0 to FTabCount - 1 do
  begin
    cw := FTabs[i].ChromiumWindow;
    if (cw <> nil) and (cw.ChromiumBrowser <> nil) and
       (cw.ChromiumBrowser.Browser <> nil) and
       (cw.ChromiumBrowser.Browser.Identifier = browser.Identifier) then
    begin
      Result := i;
      Exit;
    end;
  end;
end;

// ════════════════════════════════════════════════════════════════
// RENDERER COMMAND IMPLEMENTATIONS (stubs for async execution)
// ════════════════════════════════════════════════════════════════

procedure TControllerForm.HandleRendererClick(const cmdId: string; const params: TJSONObject; TabId: Integer);
begin
  WriteLn('[DCv2] Click command queued: ', cmdId);
end;

procedure TControllerForm.HandleRendererType(const cmdId: string; const params: TJSONObject; TabId: Integer);
begin
  WriteLn('[DCv2] Type command queued: ', cmdId);
end;

procedure TControllerForm.HandleRendererScroll(const cmdId: string; const params: TJSONObject; TabId: Integer);
begin
  WriteLn('[DCv2] Scroll command queued: ', cmdId);
end;

procedure TControllerForm.HandleRendererScreenshot(const cmdId: string; const params: TJSONObject; TabId: Integer);
begin
  WriteLn('[DCv2] Screenshot command queued: ', cmdId);
end;

procedure TControllerForm.HandleRendererDomQuery(const cmdId: string; const params: TJSONObject; TabId: Integer);
begin
  WriteLn('[DCv2] DOM Query command queued: ', cmdId);
end;

procedure TControllerForm.HandleRendererWaitFor(const cmdId: string; const params: TJSONObject; TabId: Integer);
begin
  WriteLn('[DCv2] WaitFor command queued: ', cmdId);
end;

procedure TControllerForm.HandleRendererEvaluate(const cmdId: string; const params: TJSONObject; TabId: Integer);
begin
  WriteLn('[DCv2] Evaluate command queued: ', cmdId);
end;

// ════════════════════════════════════════════════════════════════
// FORM EVENTS
// ═══════════════════════════════════════════════════════════════

procedure TControllerForm.FormCreate(Sender: TObject);
var
  addr: sockaddr_un;
  flags: Integer;
  i: Integer;
begin
  Caption := 'By Lilith Beaux — Dual Citizen Browser';
  Width := 1200;
  Height := 800;
  Position := poScreenCenter;
  FNextTabId := 1;
  FTabCount := 0;
  FCmdSock := -1;
  FCmdBuf := '';
  FProxyHost := '';
  FProxyPort := 0;
  FProxyEnabled := False;
  FEvalResult := '';
  FEvalResultReady := False;

  // Extended IPC - Renderer Bridge
  FPendingCommands := TCommandDict.Create;
  SetLength(FRendererScriptInjected, MAX_TABS);
  for i := 0 to MAX_TABS - 1 do
    FRendererScriptInjected[i] := False;

  // Create Unix command socket
  FpUnlink(CMD_SOCKET);
  FCmdSock := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if FCmdSock >= 0 then
  begin
    FillChar(addr, SizeOf(addr), 0);
    addr.sun_family := AF_UNIX;
    StrPCopy(addr.sun_path, CMD_SOCKET);
    FpUmask(0);
    if fpBind(FCmdSock, @addr, SizeOf(addr)) = 0 then
    begin
      FpChmod(CMD_SOCKET, &777);
      fpListen(FCmdSock, 5);
      flags := fpFcntl(FCmdSock, F_GETFL, 0);
      fpFcntl(FCmdSock, F_SETFL, flags or O_NONBLOCK);
      WriteLn('[DCv2] Command socket: ', CMD_SOCKET);
    end
    else
      WriteLn('[DCv2] Bind failed: ', fpGetErrNo);
  end
  else
    WriteLn('[DCv2] Socket creation failed: ', fpGetErrNo);

  // FIX 2026-10-21: the first tab is NOT created here. At FormCreate time the
  // form has no real client size yet, so the embedded TChromiumWindow was
  // created 1x1 and the first tab rendered as a dead grey page forever.
  // It is now created in FormShow, once the form is actually mapped and sized.
  WriteLn('[DCv2] Dual Citizen Browser v2 initialized');
  BuildMenuStructure;
  BuildMainMenu;
end;

procedure TControllerForm.BuildMainMenu;
var
  mFile, mEdit, mView, mHistory, mBookmarks, mTools, mProfiles, mSettings, mHelp: TMenuItem;
  mi: TMenuItem;
begin
  MainMenu1 := TMainMenu.Create(Self);
  // File
  mFile := TMenuItem.Create(MainMenu1); mFile.Caption := '&File';
  mi := TMenuItem.Create(mFile); mi.Caption := '&New Tab'; mi.ShortCut := ShortCut(VK_T, [ssCtrl]); mi.OnClick := @btnNewTabClick; mFile.Add(mi);
  mi := TMenuItem.Create(mFile); mi.Caption := '&New Window'; mi.ShortCut := ShortCut(VK_N, [ssCtrl]); mFile.Add(mi);
  mi := TMenuItem.Create(mFile); mi.Caption := 'New &Private Window'; mi.ShortCut := ShortCut(VK_P, [ssCtrl, ssShift]); mFile.Add(mi);
  mFile.Add(TMenuItem.Create(mFile)); // separator
  mi := TMenuItem.Create(mFile); mi.Caption := '&Open File...'; mi.ShortCut := ShortCut(VK_O, [ssCtrl]); mFile.Add(mi);
  mi := TMenuItem.Create(mFile); mi.Caption := '&Save Page As...'; mi.ShortCut := ShortCut(VK_S, [ssCtrl]); mFile.Add(mi);
  mFile.Add(TMenuItem.Create(mFile));
  mi := TMenuItem.Create(mFile); mi.Caption := '&Print...'; mi.ShortCut := ShortCut(VK_P, [ssCtrl]); mFile.Add(mi);
  mFile.Add(TMenuItem.Create(mFile));
  mi := TMenuItem.Create(mFile); mi.Caption := '&Quit'; mi.ShortCut := ShortCut(VK_Q, [ssCtrl]); mi.OnClick := @QuitApp; mFile.Add(mi);
  MainMenu1.Items.Add(mFile);
  // Edit
  mEdit := TMenuItem.Create(MainMenu1); mEdit.Caption := '&Edit';
  mi := TMenuItem.Create(mEdit); mi.Caption := '&Undo'; mi.ShortCut := ShortCut(VK_Z, [ssCtrl]); mEdit.Add(mi);
  mi := TMenuItem.Create(mEdit); mi.Caption := '&Redo'; mi.ShortCut := ShortCut(VK_Y, [ssCtrl]); mEdit.Add(mi);
  mEdit.Add(TMenuItem.Create(mEdit));
  mi := TMenuItem.Create(mEdit); mi.Caption := 'Cu&t'; mi.ShortCut := ShortCut(VK_X, [ssCtrl]); mEdit.Add(mi);
  mi := TMenuItem.Create(mEdit); mi.Caption := '&Copy'; mi.ShortCut := ShortCut(VK_C, [ssCtrl]); mEdit.Add(mi);
  mi := TMenuItem.Create(mEdit); mi.Caption := '&Paste'; mi.ShortCut := ShortCut(VK_V, [ssCtrl]); mEdit.Add(mi);
  mEdit.Add(TMenuItem.Create(mEdit));
  mi := TMenuItem.Create(mEdit); mi.Caption := '&Find...'; mi.ShortCut := ShortCut(VK_F, [ssCtrl]); mEdit.Add(mi);
  mi := TMenuItem.Create(mEdit); mi.Caption := 'Find &Next'; mi.ShortCut := ShortCut(VK_G, [ssCtrl]); mEdit.Add(mi);
  mi := TMenuItem.Create(mEdit); mi.Caption := 'Find &Previous'; mi.ShortCut := ShortCut(VK_G, [ssCtrl, ssShift]); mEdit.Add(mi);
  mEdit.Add(TMenuItem.Create(mEdit));
  mi := TMenuItem.Create(mEdit); mi.Caption := 'Select &All'; mi.ShortCut := ShortCut(VK_A, [ssCtrl]); mEdit.Add(mi);
  MainMenu1.Items.Add(mEdit);
  // View
  mView := TMenuItem.Create(MainMenu1); mView.Caption := '&View';
  mi := TMenuItem.Create(mView); mi.Caption := '&Address Bar'; mi.Checked := True; mi.ShortCut := ShortCut(VK_L, [ssCtrl]); mView.Add(mi);
  mi := TMenuItem.Create(mView); mi.Caption := '&Bookmarks Bar'; mi.ShortCut := ShortCut(VK_B, [ssCtrl, ssShift]); mView.Add(mi);
  mi := TMenuItem.Create(mView); mi.Caption := '&Status Bar'; mi.Checked := True; mView.Add(mi);
  mView.Add(TMenuItem.Create(mView));
  mi := TMenuItem.Create(mView); mi.Caption := '&Developer Tools'; mi.ShortCut := ShortCut(VK_F12, []); mi.OnClick := @OpenDevTools; mView.Add(mi);
  mView.Add(TMenuItem.Create(mView));
  mi := TMenuItem.Create(mView); mi.Caption := 'Zoom &In'; mi.ShortCut := ShortCut(VK_ADD, [ssCtrl]); mView.Add(mi);
  mi := TMenuItem.Create(mView); mi.Caption := 'Zoom &Out'; mi.ShortCut := ShortCut(VK_SUBTRACT, [ssCtrl]); mView.Add(mi);
  mi := TMenuItem.Create(mView); mi.Caption := '&Reset Zoom'; mi.ShortCut := ShortCut(VK_0, [ssCtrl]); mView.Add(mi);
  mView.Add(TMenuItem.Create(mView));
  mi := TMenuItem.Create(mView); mi.Caption := '&Fullscreen'; mi.ShortCut := ShortCut(VK_F11, []); mView.Add(mi);
  MainMenu1.Items.Add(mView);
  // History
  mHistory := TMenuItem.Create(MainMenu1); mHistory.Caption := '&History';
  mi := TMenuItem.Create(mHistory); mi.Caption := '&Show All History'; mi.ShortCut := ShortCut(VK_H, [ssCtrl]); mHistory.Add(mi);
  mi := TMenuItem.Create(mHistory); mi.Caption := 'Recently &Closed'; mHistory.Add(mi);
  mHistory.Add(TMenuItem.Create(mHistory));
  mi := TMenuItem.Create(mHistory); mi.Caption := '&Clear History...'; mHistory.Add(mi);
  MainMenu1.Items.Add(mHistory);
  // Bookmarks
  mBookmarks := TMenuItem.Create(MainMenu1); mBookmarks.Caption := '&Bookmarks';
  mi := TMenuItem.Create(mBookmarks); mi.Caption := '&Bookmark This Page'; mi.ShortCut := ShortCut(VK_D, [ssCtrl]); mBookmarks.Add(mi);
  mi := TMenuItem.Create(mBookmarks); mi.Caption := 'Bookmark &All Tabs'; mi.ShortCut := ShortCut(VK_D, [ssCtrl, ssShift]); mBookmarks.Add(mi);
  mBookmarks.Add(TMenuItem.Create(mBookmarks));
  mi := TMenuItem.Create(mBookmarks); mi.Caption := '&Show Bookmarks'; mi.ShortCut := ShortCut(VK_B, [ssCtrl]); mBookmarks.Add(mi);
  mi := TMenuItem.Create(mBookmarks); mi.Caption := '&Manage Bookmarks...'; mBookmarks.Add(mi);
  MainMenu1.Items.Add(mBookmarks);
  // Tools (Automation)
  mTools := TMenuItem.Create(MainMenu1); mTools.Caption := '&Tools';
  mi := TMenuItem.Create(mTools); mi.Caption := '&Automation Console'; mi.ShortCut := ShortCut(VK_J, [ssCtrl, ssShift]); mTools.Add(mi);
  mi := TMenuItem.Create(mTools); mi.Caption := '&DOM Explorer'; mi.ShortCut := ShortCut(VK_I, [ssCtrl, ssShift]); mTools.Add(mi);
  mi := TMenuItem.Create(mTools); mi.Caption := '&Network Monitor'; mi.ShortCut := ShortCut(VK_E, [ssCtrl, ssShift]); mTools.Add(mi);
  mi := TMenuItem.Create(mTools); mi.Caption := '&Storage Manager'; mTools.Add(mi);
  mi := TMenuItem.Create(mTools); mi.Caption := '&Screenshot / Video'; mTools.Add(mi);
  mi := TMenuItem.Create(mTools); mi.Caption := '&Extension Manager'; mTools.Add(mi);
  mTools.Add(TMenuItem.Create(mTools));
  mi := TMenuItem.Create(mTools); mi.Caption := '&Spoof Profiles'; mTools.Add(mi);
  mi := TMenuItem.Create(mTools); mi.Caption := '&Replay Runner'; mTools.Add(mi);
  MainMenu1.Items.Add(mTools);
  // Profiles
  mProfiles := TMenuItem.Create(MainMenu1); mProfiles.Caption := '&Profiles';
  mi := TMenuItem.Create(mProfiles); mi.Caption := '&Switch Profile...'; mProfiles.Add(mi);
  mi := TMenuItem.Create(mProfiles); mi.Caption := '&Profile Manager...'; mProfiles.Add(mi);
  mProfiles.Add(TMenuItem.Create(mProfiles));
  mi := TMenuItem.Create(mProfiles); mi.Caption := '&Export Profile...'; mProfiles.Add(mi);
  mi := TMenuItem.Create(mProfiles); mi.Caption := '&Import Profile...'; mProfiles.Add(mi);
  mProfiles.Add(TMenuItem.Create(mProfiles));
  mi := TMenuItem.Create(mProfiles); mi.Caption := '&Session Restore'; mProfiles.Add(mi);
  MainMenu1.Items.Add(mProfiles);
  // Settings
  mSettings := TMenuItem.Create(MainMenu1); mSettings.Caption := '&Settings';
  mi := TMenuItem.Create(mSettings); mi.Caption := '&Preferences...'; mi.ShortCut := ShortCut(VK_OEM_COMMA, [ssCtrl]); mi.OnClick := @ShowSettingsDialog; mSettings.Add(mi);
  MainMenu1.Items.Add(mSettings);
  // Help
  mHelp := TMenuItem.Create(MainMenu1); mHelp.Caption := '&Help';
  mi := TMenuItem.Create(mHelp); mi.Caption := '&Documentation'; mHelp.Add(mi);
  mi := TMenuItem.Create(mHelp); mi.Caption := '&Keyboard Shortcuts'; mHelp.Add(mi);
  mHelp.Add(TMenuItem.Create(mHelp));
  mi := TMenuItem.Create(mHelp); mi.Caption := '&Report Issue...'; mHelp.Add(mi);
  mHelp.Add(TMenuItem.Create(mHelp));
  mi := TMenuItem.Create(mHelp); mi.Caption := '&About Dual Citizen...'; mHelp.Add(mi);
  MainMenu1.Items.Add(mHelp);
  // Don't set Menu property - we use hamburger instead
end;

procedure TControllerForm.BuildMenuStructure;
begin
  // Hamburger menu button setup
  if btnMenu <> nil then
  begin
    btnMenu.Caption := '☰';
    btnMenu.Hint := 'Menu (Alt+Space)';
    btnMenu.ShowHint := True;
    btnMenu.OnClick := @btnMenuClick;
    btnMenu.Flat := True;
    btnMenu.Width := 36;
    btnMenu.Height := 28;
  end;
  // Owner-draw tabs with close buttons implemented via tbMainDrawTab / tbMainMouseDown
end;

procedure TControllerForm.btnMenuClick(Sender: TObject);
var
  Popup: TPopupMenu;
  mi: TMenuItem;
  pt: TPoint;
begin
  Popup := TPopupMenu.Create(Self);
  try
    // File
    mi := TMenuItem.Create(Popup); mi.Caption := '&New Tab'; mi.ShortCut := ShortCut(VK_T, [ssCtrl]); mi.OnClick := @btnNewTabClick; Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&New Window'; mi.ShortCut := ShortCut(VK_N, [ssCtrl]); Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := 'New &Private Window'; mi.ShortCut := ShortCut(VK_P, [ssCtrl, ssShift]); Popup.Items.Add(mi);
    Popup.Items.Add(TMenuItem.Create(Popup));
    mi := TMenuItem.Create(Popup); mi.Caption := '&Open File...'; mi.ShortCut := ShortCut(VK_O, [ssCtrl]); Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Save Page As...'; mi.ShortCut := ShortCut(VK_S, [ssCtrl]); Popup.Items.Add(mi);
    Popup.Items.Add(TMenuItem.Create(Popup));
    mi := TMenuItem.Create(Popup); mi.Caption := '&Print...'; mi.ShortCut := ShortCut(VK_P, [ssCtrl]); Popup.Items.Add(mi);
    Popup.Items.Add(TMenuItem.Create(Popup));
    mi := TMenuItem.Create(Popup); mi.Caption := '&Quit'; mi.ShortCut := ShortCut(VK_Q, [ssCtrl]); mi.OnClick := @QuitApp; Popup.Items.Add(mi);
    // Edit
    Popup.Items.Add(TMenuItem.Create(Popup));
    mi := TMenuItem.Create(Popup); mi.Caption := '&Undo'; mi.ShortCut := ShortCut(VK_Z, [ssCtrl]); Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Redo'; mi.ShortCut := ShortCut(VK_Y, [ssCtrl]); Popup.Items.Add(mi);
    Popup.Items.Add(TMenuItem.Create(Popup));
    mi := TMenuItem.Create(Popup); mi.Caption := 'Cu&t'; mi.ShortCut := ShortCut(VK_X, [ssCtrl]); Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Copy'; mi.ShortCut := ShortCut(VK_C, [ssCtrl]); Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Paste'; mi.ShortCut := ShortCut(VK_V, [ssCtrl]); Popup.Items.Add(mi);
    Popup.Items.Add(TMenuItem.Create(Popup));
    mi := TMenuItem.Create(Popup); mi.Caption := '&Find...'; mi.ShortCut := ShortCut(VK_F, [ssCtrl]); Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := 'Select &All'; mi.ShortCut := ShortCut(VK_A, [ssCtrl]); Popup.Items.Add(mi);
    // View
    Popup.Items.Add(TMenuItem.Create(Popup));
    mi := TMenuItem.Create(Popup); mi.Caption := '&Address Bar'; mi.Checked := True; mi.ShortCut := ShortCut(VK_L, [ssCtrl]); Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Bookmarks Bar'; mi.ShortCut := ShortCut(VK_B, [ssCtrl, ssShift]); Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Status Bar'; mi.Checked := True; Popup.Items.Add(mi);
    Popup.Items.Add(TMenuItem.Create(Popup));
    mi := TMenuItem.Create(Popup); mi.Caption := '&Developer Tools'; mi.ShortCut := ShortCut(VK_F12, []); mi.OnClick := @OpenDevTools; Popup.Items.Add(mi);
    Popup.Items.Add(TMenuItem.Create(Popup));
    mi := TMenuItem.Create(Popup); mi.Caption := 'Zoom &In'; mi.ShortCut := ShortCut(VK_ADD, [ssCtrl]); Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := 'Zoom &Out'; mi.ShortCut := ShortCut(VK_SUBTRACT, [ssCtrl]); Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Reset Zoom'; mi.ShortCut := ShortCut(VK_0, [ssCtrl]); Popup.Items.Add(mi);
    Popup.Items.Add(TMenuItem.Create(Popup));
    mi := TMenuItem.Create(Popup); mi.Caption := '&Fullscreen'; mi.ShortCut := ShortCut(VK_F11, []); Popup.Items.Add(mi);
    // History
    Popup.Items.Add(TMenuItem.Create(Popup));
    mi := TMenuItem.Create(Popup); mi.Caption := '&Show All History'; mi.ShortCut := ShortCut(VK_H, [ssCtrl]); Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Clear History...'; Popup.Items.Add(mi);
    // Bookmarks
    Popup.Items.Add(TMenuItem.Create(Popup));
    mi := TMenuItem.Create(Popup); mi.Caption := '&Bookmark This Page'; mi.ShortCut := ShortCut(VK_D, [ssCtrl]); Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Manage Bookmarks...'; Popup.Items.Add(mi);
    // Tools (Automation)
    Popup.Items.Add(TMenuItem.Create(Popup));
    mi := TMenuItem.Create(Popup); mi.Caption := '&Automation Console'; mi.ShortCut := ShortCut(VK_J, [ssCtrl, ssShift]); mi.OnClick := @ShowAutomationConsole; Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&DOM Explorer'; mi.ShortCut := ShortCut(VK_I, [ssCtrl, ssShift]); mi.OnClick := @ShowDOMExplorer; Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Network Monitor'; mi.ShortCut := ShortCut(VK_E, [ssCtrl, ssShift]); mi.OnClick := @ShowNetworkTools; Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Storage Manager'; mi.OnClick := @ShowStorageManager; Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Screenshot / Video'; mi.OnClick := @ShowScreenshotVideo; Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Extension Manager'; mi.OnClick := @ShowExtensionManager; Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Spoof Profiles'; mi.OnClick := @ShowSpoofProfiles; Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Replay Runner'; mi.OnClick := @ShowReplayRunner; Popup.Items.Add(mi);
    // Profiles
    Popup.Items.Add(TMenuItem.Create(Popup));
    mi := TMenuItem.Create(Popup); mi.Caption := '&Switch Profile...'; mi.OnClick := @ShowProfileSwitcher; Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Profile Manager...'; mi.OnClick := @ShowProfileManager; Popup.Items.Add(mi);
    // Settings
    Popup.Items.Add(TMenuItem.Create(Popup));
    mi := TMenuItem.Create(Popup); mi.Caption := '&Preferences...'; mi.ShortCut := ShortCut(VK_OEM_COMMA, [ssCtrl]); mi.OnClick := @ShowSettingsDialog; Popup.Items.Add(mi);
    // Help
    Popup.Items.Add(TMenuItem.Create(Popup));
    mi := TMenuItem.Create(Popup); mi.Caption := '&Documentation'; Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Keyboard Shortcuts'; Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&Report Issue...'; Popup.Items.Add(mi);
    mi := TMenuItem.Create(Popup); mi.Caption := '&About Dual Citizen...'; mi.OnClick := @ShowAbout; Popup.Items.Add(mi);
    // Show popup at button position
    pt := btnMenu.ClientToScreen(Point(0, btnMenu.Height));
    Popup.Popup(pt.X, pt.Y);
  finally
    Popup.Free;
  end;
end;

procedure TControllerForm.tbMainCloseTabClicked(Sender: TObject; TabIndex: Integer);
var
  tabId: Integer;
begin
  if (TabIndex >= 0) and (TabIndex < FTabCount) then
  begin
    tabId := FTabs[TabIndex].TabId;
    CloseTab(tabId);
  end;
end;

procedure TControllerForm.tbMainDrawTab(Control: TCustomTabControl; TabIndex: Integer; const Rect: TRect; IsActive: Boolean);
var
  TabControl: TPageControl;
  TabRect: TRect;
  TextRect: TRect;
  CloseRect: TRect;
  TabCaption: string;
  TextSize: TSize;
  CloseBtnSize: Integer;
  IsHovered: Boolean;
  TabSheet: TTabSheet;
begin
  TabControl := TPageControl(Control);
  TabRect := Types.Rect;
  TabCaption := TabControl.Pages[TabIndex].Caption;

  // Draw tab background
  if IsActive then
    TabControl.Canvas.Brush.Color := clWhite
  else
    TabControl.Canvas.Brush.Color := $00E0E0E0; // Light gray for inactive tabs
  TabControl.Canvas.FillRect(TabRect);

  // Draw tab border
  if IsActive then
    TabControl.Canvas.Pen.Color := clHighlight
  else
    TabControl.Canvas.Pen.Color := clGray;
  TabControl.Canvas.Rectangle(TabRect.Left, TabRect.Top, TabRect.Right, TabRect.Bottom);

  // Close button dimensions
  CloseBtnSize := 16;
  CloseRect := Types.Rect(TabRect.Right - CloseBtnSize - 4, TabRect.Top + (TabRect.Height - CloseBtnSize) div 2,
                    TabRect.Right - 4, TabRect.Top + (TabRect.Height + CloseBtnSize) div 2);

  // Text area (leave space for close button)
  TextRect := Types.Rect(TabRect.Left + 8, TabRect.Top, CloseRect.Left - 4, TabRect.Bottom);

  // Draw caption
  TabControl.Canvas.Font.Color := clBlack;
  TabControl.Canvas.Font.Style := [];
  if IsActive then
    TabControl.Canvas.Font.Style := [fsBold];
  TextSize := TabControl.Canvas.TextExtent(TabCaption);
  TabControl.Canvas.TextOut(TextRect.Left, TextRect.Top + (TextRect.Height - TextSize.cy) div 2, TabCaption);

  // Draw close button (×)
  TabControl.Canvas.Pen.Color := clRed;
  TabControl.Canvas.Pen.Width := 2;
  // Draw X
  TabControl.Canvas.MoveTo(CloseRect.Left + 3, CloseRect.Top + 3);
  TabControl.Canvas.LineTo(CloseRect.Right - 3, CloseRect.Bottom - 3);
  TabControl.Canvas.MoveTo(CloseRect.Right - 3, CloseRect.Top + 3);
  TabControl.Canvas.LineTo(CloseRect.Left + 3, CloseRect.Bottom - 3);

  // Draw active tab indicator line at bottom
  if IsActive then
  begin
    TabControl.Canvas.Pen.Color := clHighlight;
    TabControl.Canvas.Pen.Width := 2;
    TabControl.Canvas.MoveTo(TabRect.Left + 2, TabRect.Bottom - 1);
    TabControl.Canvas.LineTo(TabRect.Right - 2, TabRect.Bottom - 1);
  end;
end;

procedure TControllerForm.tbMainMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  i: Integer;
  TabRect: TRect;
  CloseRect: TRect;
  CloseBtnSize: Integer;
  TabControl: TPageControl;
begin
  if Button <> mbLeft then Exit;

  TabControl := TPageControl(Sender);
  CloseBtnSize := 16;

  // Check each tab's close button area
  for i := 0 to TabControl.PageCount - 1 do
  begin
    TabRect := TabControl.TabRect(i);
    CloseRect := Rect(TabRect.Right - CloseBtnSize - 4, TabRect.Top + (TabRect.Height - CloseBtnSize) div 2,
                      TabRect.Right - 4, TabRect.Top + (TabRect.Height + CloseBtnSize) div 2);

    if PtInRect(CloseRect, Point(X, Y)) then
    begin
      // Close this tab
      if (i >= 0) and (i < FTabCount) then
      begin
        CloseTab(FTabs[i].TabId);
      end;
      Break;
    end;
  end;
end;

procedure TControllerForm.OpenDevTools(Sender: TObject);
var
  idx: Integer;
  browser: ICefBrowser;
begin
  idx := GetTabIndex(ActiveTabId);
  if (idx >= 0) and (FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser <> nil) then
  begin
    browser := FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser;
    browser.GetHost.ShowDevTools(nil, browser.GetHost.GetClient, nil, nil);
  end;
end;

procedure TControllerForm.ShowSettingsDialog(Sender: TObject);
begin
  CreateSettingsDialog;
end;

procedure TControllerForm.ShowAutomationConsole(Sender: TObject);
begin
  // Placeholder - WO-AUTOMATION-CONSOLE
  ShowMessage('Automation Console — WO-AUTOMATION-CONSOLE (ready)');
end;

procedure TControllerForm.ShowDOMExplorer(Sender: TObject);
begin
  ShowMessage('DOM Explorer — WO-DOM-EXPLORER (ready)');
end;

procedure TControllerForm.ShowNetworkTools(Sender: TObject);
begin
  ShowMessage('Network Monitor — WO-NETWORK-TOOLS (ready)');
end;

procedure TControllerForm.ShowStorageManager(Sender: TObject);
begin
  ShowMessage('Storage Manager — WO-STORAGE-MANAGER (ready)');
end;

procedure TControllerForm.ShowScreenshotVideo(Sender: TObject);
begin
  ShowMessage('Screenshot/Video — WO-SCREENSHOT-VIDEO (ready)');
end;

procedure TControllerForm.ShowExtensionManager(Sender: TObject);
begin
  ShowMessage('Extension Manager — WO-EXTENSION-MANAGER (ready)');
end;

procedure TControllerForm.ShowSpoofProfiles(Sender: TObject);
var
  Dlg: TForm;
  LV: TListView;
  btnApply, btnNewTab, btnClose: TButton;
  sl: TStringList;
  data, profiles, profile: TJSONData;
  profileNames: TStringList;
  i: Integer;
  selectedProfile: string;
begin
  selectedProfile := '';
  
  Dlg := TForm.CreateNew(Application, 0);
  try
    Dlg.Caption := 'Spoof Profiles — Dual Citizen';
    Dlg.Width := 520;
    Dlg.Height := 380;
    Dlg.Position := poScreenCenter;
    Dlg.BorderStyle := bsDialog;
    
    LV := TListView.Create(Dlg);
    LV.Parent := Dlg;
    LV.Align := alClient;
    LV.ViewStyle := vsReport;
    LV.ReadOnly := True;
    LV.RowSelect := True;
    LV.MultiSelect := False;
    LV.Columns.Add.Caption := 'Profile';
    LV.Columns.Add.Caption := 'User Agent';
    LV.Columns.Add.Caption := 'Platform';
    LV.Columns.Add.Caption := 'Resolution';
    LV.Columns.Add.Caption := 'Timezone';
    LV.Columns[0].Width := 80;
    LV.Columns[1].Width := 200;
    LV.Columns[2].Width := 80;
    LV.Columns[3].Width := 80;
    LV.Columns[4].Width := 100;
    
    // Load profiles
    if FileExists(PROFILES_FILE) then
    begin
      sl := TStringList.Create;
      try
        sl.LoadFromFile(PROFILES_FILE);
        data := GetJSON(sl.Text);
        profiles := data.FindPath('profiles');
        if profiles <> nil then
        begin
          profileNames := TStringList.Create;
          try
            profiles.FindPath('default'); // trigger enumeration
            for i := 0 to profiles.Count - 1 do
            begin
              profile := profiles.Items[i];
              if profile <> nil then
              begin
                with LV.Items.Add do
                begin
                  Caption := profileNames[i];
                  SubItems.Add(profile.FindPath('browser.user_agent').AsString);
                  SubItems.Add(profile.FindPath('browser.platform').AsString);
                  SubItems.Add(profile.FindPath('browser.screen_resolution').AsString);
                  SubItems.Add(profile.FindPath('browser.timezone').AsString);
                end;
              end;
            end;
          finally
            profileNames.Free;
          end;
        end;
        data.Free;
      finally
        sl.Free;
      end;
    end;
    
    // Button panel
    btnApply := TButton.Create(Dlg);
    btnApply.Parent := Dlg;
    btnApply.Caption := 'Apply to Current Tab';
    btnApply.SetBounds(10, Dlg.Height - 50, 140, 30);
    btnApply.Anchors := [akLeft, akBottom];
    btnApply.OnClick := procedure(Sender: TObject)
    begin
      if LV.Selected <> nil then
      begin
        selectedProfile := LV.Selected.Caption;
        if (ActiveTabId >= 0) then
        begin
          if SpoofTab(ActiveTabId, GetProfile(selectedProfile)) then
            ShowMessage('Spoof profile "' + selectedProfile + '" applied to current tab.')
          else
            ShowMessage('Failed to apply spoof profile.');
        end
        else
          ShowMessage('No active tab.');
        Dlg.Close;
      end;
    end;
    
    btnNewTab := TButton.Create(Dlg);
    btnNewTab.Parent := Dlg;
    btnNewTab.Caption := 'New Tab with Profile';
    btnNewTab.SetBounds(160, Dlg.Height - 50, 140, 30);
    btnNewTab.Anchors := [akLeft, akBottom];
    btnNewTab.OnClick := procedure(Sender: TObject)
    begin
      if LV.Selected <> nil then
      begin
        AddTab(LV.Selected.Caption);
        Dlg.Close;
      end;
    end;
    
    btnClose := TButton.Create(Dlg);
    btnClose.Parent := Dlg;
    btnClose.Caption := 'Close';
    btnClose.SetBounds(400, Dlg.Height - 50, 100, 30);
    btnClose.Anchors := [akRight, akBottom];
    btnClose.OnClick := procedure(Sender: TObject)
    begin
      Dlg.Close;
    end;
    
    Dlg.ShowModal;
  finally
    Dlg.Free;
  end;
end;

procedure TControllerForm.ShowReplayRunner(Sender: TObject);
begin
  ShowMessage('Replay Runner — WO-AUTOMATION-CONSOLE (ready)');
end;

procedure TControllerForm.ShowProfileSwitcher(Sender: TObject);
begin
  ShowMessage('Profile Switcher — WO-PROFILE-SWITCHER (ready)');
end;

procedure TControllerForm.ShowProfileManager(Sender: TObject);
begin
  ShowMessage('Profile Manager — WO-PROFILE-SWITCHER (ready)');
end;

procedure TControllerForm.ShowAbout(Sender: TObject);
begin
  ShowMessage('Dual Citizen Browser' + sLineBreak +
    'CEF 131 / Chromium 131' + sLineBreak +
    'By Lilith Beaux — Sovereign & Unbound' + sLineBreak +
    '❅𓁶☿⚕⚡∞');
end;

procedure TControllerForm.QuitApp(Sender: TObject);
begin
  Application.Terminate;
end;

procedure TControllerForm.CreateSettingsDialog;
var
  Dlg: TForm;
  PC: TPageControl;
  pgGeneral, pgPrivacy, pgAppearance, pgAdvanced, pgAbout: TTabSheet;
  lbl: TLabel;
  i: Integer;
begin
  // Prevent multiple instances
  if Screen.FormCount > 1 then
    for i := Screen.FormCount - 1 downto 0 do
      if Screen.Forms[i].Name = 'SettingsDialog' then
      begin
        Screen.Forms[i].Show;
        Screen.Forms[i].BringToFront;
        Exit;
      end;

  Dlg := TForm.CreateNew(Application, 0);
  Dlg.Name := 'SettingsDialog';
  Dlg.Caption := 'Preferences — Dual Citizen Browser';
  Dlg.Width := 720;
  Dlg.Height := 540;
  Dlg.Position := poScreenCenter;
  Dlg.BorderStyle := bsSizeable;

  PC := TPageControl.Create(Dlg);
  PC.Parent := Dlg;
  PC.Align := alClient;
  PC.PageIndex := 0;

  // --- General ---
  pgGeneral := TTabSheet.Create(PC); pgGeneral.Caption := 'General'; pgGeneral.PageControl := PC;
  lbl := TLabel.Create(pgGeneral); lbl.Parent := pgGeneral; lbl.Top := 16; lbl.Left := 16; lbl.Width := 680;
  lbl.Caption := 'General Settings (placeholder)';
  // Startup, Downloads, Language, Default Browser

  // --- Privacy & Security ---
  pgPrivacy := TTabSheet.Create(PC); pgPrivacy.Caption := 'Privacy & Security'; pgPrivacy.PageControl := PC;
  lbl := TLabel.Create(pgPrivacy); lbl.Parent := pgPrivacy; lbl.Top := 16; lbl.Left := 16; lbl.Width := 680;
  lbl.Caption := 'Privacy & Security (placeholder)';
  // SpoofCore, Tracking Protection, Cookies, HTTPS-Only, Clear on Exit, Permissions

  // --- Appearance ---
  pgAppearance := TTabSheet.Create(PC); pgAppearance.Caption := 'Appearance'; pgAppearance.PageControl := PC;
  lbl := TLabel.Create(pgAppearance); lbl.Parent := pgAppearance; lbl.Top := 16; lbl.Left := 16; lbl.Width := 680;
  lbl.Caption := 'Appearance (placeholder)';
  // Theme, Toolbar, Tab Style, Font Size, Lilith Branding

  // --- Advanced ---
  pgAdvanced := TTabSheet.Create(PC); pgAdvanced.Caption := 'Advanced'; pgAdvanced.PageControl := PC;
  lbl := TLabel.Create(pgAdvanced); lbl.Parent := pgAdvanced; lbl.Top := 16; lbl.Left := 16; lbl.Width := 680;
  lbl.Caption := 'Advanced Settings (placeholder)';
  // GPU, Renderer Bridge, IPC Socket, bwrap, CEF Flags, Asset System, Custom Variants, Debug

  // --- About ---
  pgAbout := TTabSheet.Create(PC); pgAbout.Caption := 'About'; pgAbout.PageControl := PC;
  lbl := TLabel.Create(pgAbout); lbl.Parent := pgAbout; lbl.Top := 16; lbl.Left := 16; lbl.Width := 680;
  lbl.Caption := 'About Dual Citizen Browser' + sLineBreak +
    'CEF 131 / Chromium 131' + sLineBreak +
    'By Lilith Beaux — Sovereign & Unbound' + sLineBreak +
    '❅𓁶☿⚕⚡∞';

  Dlg.Show;
end;

procedure TControllerForm.FormShow(Sender: TObject);
begin
  // Do NOT create the first tab here. On GTK2 the embedded TChromiumWindow's
  // own GTK/X handle is allocated at 1x1 when the control is created before the
  // form has been fully realized, and it never gets resized afterwards -> the
  // first tab renders as a dead grey 1x1 surface. Tabs created later (once the
  // form is realized) come up correctly sized.
  // The first tab is therefore created on the first Timer1 tick, which runs
  // after realization, exactly like every other tab.
  FNeedFirstTab := (FTabCount = 0);

  // Initial URL: argv[1] if the caller supplied one (used by the per-site launchers).
  if (ParamCount >= 1) and (ParamStr(1) <> '') then
    FStartURL := ParamStr(1);
end;


procedure TControllerForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
var
  i: Integer;
begin
  CanClose := True;
  for i := 0 to FTabCount - 1 do
    FTabs[i].ChromiumWindow.CloseBrowser(True);
end;

procedure TControllerForm.FormDestroy(Sender: TObject);
begin
  if FCmdSock >= 0 then
  begin
    fpClose(FCmdSock);
    FpUnlink(CMD_SOCKET);
  end;
  FreeAndNil(FPendingCommands);
end;

procedure TControllerForm.btnGoClick(Sender: TObject);
begin
  Navigate(edAddress.Text);
end;

procedure TControllerForm.btnBackClick(Sender: TObject);
var
  idx: Integer;
begin
  idx := GetTabIndex(ActiveTabId);
  if (idx >= 0) and (FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser <> nil) then
    FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser.GoBack;
end;

procedure TControllerForm.btnForwardClick(Sender: TObject);
var
  idx: Integer;
begin
  idx := GetTabIndex(ActiveTabId);
  if (idx >= 0) and (FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser <> nil) then
    FTabs[idx].ChromiumWindow.ChromiumBrowser.Browser.GoForward;
end;

procedure TControllerForm.btnNewTabClick(Sender: TObject);
begin
  AddTab;
end;

procedure TControllerForm.btnExtensionsClick(Sender: TObject);
begin
  // Green puzzle piece -> the extensions manager, exactly like the Bromium/Pythia build
  Navigate('chrome://extensions/');
end;

procedure TControllerForm.Timer1Timer(Sender: TObject);
var
  i: Integer;
  cw: TChromiumWindow;
  newId: Integer;
begin
  // Hot-reload on-disk assets if a manifest changed on disk.
  ReloadAssetsIfChanged;

  // Deferred first-tab creation: by now the form is realized and the embedded
  // browser window is allocated with its real geometry.
  if FNeedFirstTab and (FTabCount = 0) then
  begin
    FNeedFirstTab := False;
    newId := AddTab;
    if (newId >= 0) and (FStartURL <> '') then
    begin
      Navigate(FStartURL, newId);
      edAddress.Text := FStartURL;
    end;
  end;

  ProcessCommands;

  // Safety net: re-assert the CEF browser window geometry. If a tab was created
  // before LCL finished laying out its TabSheet, the browser's X window stays
  // 1x1 until a real resize event arrives. Re-pushing the current LCL bounds
  // every tick keeps every tab's render surface correctly sized.
  for i := 0 to FTabCount - 1 do
  begin
    cw := FTabs[i].ChromiumWindow;
    if (cw <> nil) and (cw.ChromiumBrowser <> nil) and
       (cw.ChromiumBrowser.Browser <> nil) and
       (cw.Width > 1) and (cw.Height > 1) then
      cw.ChromiumBrowser.UpdateBrowserSize(cw.Left, cw.Top, cw.Width, cw.Height);
  end;
end;

procedure TControllerForm.edAddressKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = 13 then // Enter
  begin
    Navigate(edAddress.Text);
    Key := 0;
  end;
end;

procedure TControllerForm.tbMainChange(Sender: TObject);
var
  idx: Integer;
begin
  idx := tbMain.ActivePageIndex;
  if (idx >= 0) and (idx < FTabCount) then
    begin
      // Update address bar to show the active tab's URL
      edAddress.Text := GetActiveURL(FTabs[idx].TabId);
      SendBusJSON('tab.activated', 'info', Format('{\"tab_id\":%d}', [FTabs[idx].TabId]));
      // must be told the new geometry or it keeps rendering at the old size.
      if FTabs[idx].ChromiumWindow <> nil then
        FTabs[idx].ChromiumWindow.NotifyMoveOrResizeStarted;
    end;
  end;

  end.
