unit SpoofCoreCodeGen;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, SpoofCore;

type
  // ═══════════════════════════════════════════════════════════════════════════
  // 1. TProfileData — in-memory mirror of the JSON profile stored in profiles.json
  //    This is the struct that codegen turns into/from JSON schema.
  // ═══════════════════════════════════════════════════════════════════════════
  TAddressData = record
    Lat: Double;
    Lng: Double;
    HasLatLng: Boolean;
  end;

  TBrowserData = record
    UserAgent: string;
    Platform: string;
    Language: string;
    ScreenResolution: string;  // "WxH"
    Timezone: string;
  end;

  TProfileData = record
    Name: string;
    Browser: TBrowserData;
    Address: TAddressData;
    // Raw JSON so codegen can round-trip fields it doesn't model explicitly.
    RawJSON: string;
  end;

  // JSON schema version emitted by the generator for new profile files.
  const PROFILE_SCHEMA_VERSION = '1.0';

  // ═══════════════════════════════════════════════════════════════════════════
  // 2. SpoofDecisionFromFlags → decision tree (re-exported for codegen consumers)
  //    The browser's IPC handler calls exactly these; codegen should not
  //    re-implement them, it should delegate to SpoofCore.
  // ═══════════════════════════════════════════════════════════════════════════
type
  TSpoofDecisionTree = record
    ProfileFound: Boolean;
    TabFound: Boolean;
    HasData: Boolean;
    AppliedNow: Boolean;
    JSBytes: Integer;
    Phase: TSpoofPhase;   // spError | spPending | spApplied
    ErrorCode: string;
    ErrorMsg: string;
    JSBytesOut: Integer;
  end;

function BuildSpoofDecisionTree(const AProfileFound, ATabFound, AHasData,
  AAppliedNow: Boolean; AJSBytes: Integer): TSpoofDecisionTree;

// ════════════════════════════════════════════════════════════════════════════
// 3. JS injection timing modes
// ════════════════════════════════════════════════════════════════════════════
type
  TJSSpoofTiming = (jtDoLoadEnd, jtOnAfterCreated, jtExecuteJavaScript);

const
  JSSpoofTimingNames: array[TJSSpoofTiming] of string = (
    'DoLoadEnd',
    'OnAfterCreated',
    'ExecuteJavaScript'
  );

  // Recommended timing per injection point (commentary for generated code):
  //   DoLoadEnd     — frame is committed; safe to mutate navigator/screen/Intl.
  //                   Runs on every navigation of the main frame.
  //                   Risk: re-applies if the page navigates after spoof armed.
  //   OnAfterCreated — browser process exists but page may not have committed.
  //                    navigator properties are writeable pre-commit but can be
  //                    clobbered by a later navigation; use as an early arm,
  //                    then re-assert on DoLoadEnd.
  //   ExecuteJavaScript — immediate, imperative call from the IPC handler.
  //                    Only works if a main frame already exists; otherwise
  //                    the JS is stored and applied on the next DoLoadEnd.
  //                   This is the path SpoofTab() takes when AppliedNow=true.

function JSSpoofTimingDescription(ATiming: TJSSpoofTiming): string;

// ════════════════════════════════════════════════════════════════════════════
// 4. verify_spoof IPC protocol
// ════════════════════════════════════════════════════════════════════════════
type
  TVerifySpoofRequest = record
    CmdId: string;
    ProfileName: string;
    TabId: Integer;
    ExpectedUA: string;
  end;

  TVerifySpoofReply = record
    CmdId: string;
    Status: string;        // 'ok' | 'pending' | 'error'
    Method: string;        // 'verify_spoof'
    Verified: Boolean;
    ObservedUA: string;
    ExpectedUA: string;
    ErrorCode: string;     // '' unless error
  end;

function BuildVerifySpoofRequest(const ACmdId, AProfileName: string;
  ATabId: Integer; const AExpectedUA: string): TVerifySpoofRequest;

function BuildVerifySpoofReply(const ACmdId: string; const AV: TSpoofVerify): TVerifySpoofReply;

function VerifySpoofReplyToJSON(const AVReply: TVerifySpoofReply): string;

// ════════════════════════════════════════════════════════════════════════════
// 5. Profile templates (reddit, facebook, google, custom)
// ════════════════════════════════════════════════════════════════════════════
type
  TProfileTemplateKind = (ptReddit, ptFacebook, ptGoogle, ptCustom);

const
  PROFILE_TEMPLATE_REDDIT = '{' +
    '"name":"reddit",' +
    '"browser":{' +
      '"user_agent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:142.0) Gecko/20100101 Firefox/142.0",' +
      '"platform":"Win32",' +
      '"language":"en-US",' +
      '"screen_resolution":"1920x1080",' +
      '"timezone":"America/New_York"' +
    '},' +
    '"address":{' +
      '"lat":40.7128,' +
      '"lng":-74.0060' +
    '}' +
  '}';

  PROFILE_TEMPLATE_FACEBOOK = '{' +
    '"name":"facebook",' +
    '"browser":{' +
      '"user_agent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36",' +
      '"platform":"Win32",' +
      '"language":"en-US",' +
      '"screen_resolution":"1536x864",' +
      '"timezone":"America/Chicago"' +
    '},' +
    '"address":{' +
      '"lat":41.8781,' +
      '"lng":-87.6298' +
    '}' +
  '}';

  PROFILE_TEMPLATE_GOOGLE = '{' +
    '"name":"google",' +
    '"browser":{' +
      '"user_agent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36",' +
      '"platform":"Win32",' +
      '"language":"en-US",' +
      '"screen_resolution":"1920x1080",' +
      '"timezone":"America/Los_Angeles"' +
    '},' +
    '"address":{' +
      '"lat":37.4056,' +
      '"lng":-122.0775' +
    '}' +
  '}';

function ProfileTemplateToJSON(AKind: TProfileTemplateKind): string;

// TProfileData <-> JSON schema conversion (the codegen entry points)
function ProfileDataToJSON(const AProfile: TProfileData): string;
function ProfileDataFromJSON(const AJSON: string): TProfileData;
function ProfileJSONSchema(const AProfileName: string): string;

// Generate a complete profile JSON file (schema + template) for codegen output.
function GenerateProfileFile(const AProfileName: string; AKind: TProfileTemplateKind): string;

implementation

uses
  StrUtils;

function BuildSpoofDecisionTree(const AProfileFound, ATabFound, AHasData,
  AAppliedNow: Boolean; AJSBytes: Integer): TSpoofDecisionTree;
var
  dec: TSpoofDecision;
begin
  dec := SpoofDecisionFromFlags(AProfileFound, ATabFound, AHasData, AAppliedNow, AJSBytes);
  Result.ProfileFound := AProfileFound;
  Result.TabFound := ATabFound;
  Result.HasData := AHasData;
  Result.AppliedNow := AAppliedNow;
  Result.JSBytes := AJSBytes;
  Result.Phase := dec.Phase;
  Result.ErrorCode := dec.ErrorCode;
  Result.ErrorMsg := dec.ErrorMsg;
  Result.JSBytesOut := dec.JSBytes;
end;

function JSSpoofTimingDescription(ATiming: TJSSpoofTiming): string;
begin
  case ATiming of
    jtDoLoadEnd:
      Result := 'On main-frame load commit. Safe to mutate navigator/screen/Intl; re-applies on each navigation.';
    jtOnAfterCreated:
      Result := 'Browser process created; page may not have committed yet. Use as an early arm, re-assert on DoLoadEnd.';
    jtExecuteJavaScript:
      Result := 'Imperative call from IPC handler. Works only if a main frame exists now; otherwise JS is stored for next LoadEnd.';
    else
      Result := '';
  end;
end;

function BuildVerifySpoofRequest(const ACmdId, AProfileName: string;
  ATabId: Integer; const AExpectedUA: string): TVerifySpoofRequest;
begin
  Result.CmdId := ACmdId;
  Result.ProfileName := AProfileName;
  Result.TabId := ATabId;
  Result.ExpectedUA := AExpectedUA;
end;

function BuildVerifySpoofReply(const ACmdId: string; const AV: TSpoofVerify): TVerifySpoofReply;
begin
  Result.CmdId := ACmdId;
  Result.Method := 'verify_spoof';
  case AV.Phase of
    svVerified:
      begin
        Result.Status := 'ok';
        Result.Verified := True;
      end;
    svMismatch:
      begin
        Result.Status := 'error';
        Result.Verified := False;
        Result.ErrorCode := 'ua_mismatch';
      end;
    svNoSpoof:
      begin
        Result.Status := 'error';
        Result.Verified := False;
        Result.ErrorCode := 'no_spoof_armed';
      end;
    else  // svPending
      begin
        Result.Status := 'pending';
        Result.Verified := False;
      end;
  end;
  Result.ObservedUA := AV.ObservedUA;
  Result.ExpectedUA := AV.ExpectedUA;
end;

function VerifySpoofReplyToJSON(const AVReply: TVerifySpoofReply): string;
var
  vPhase: TSpoofVerifyPhase;
begin
  if AVReply.Status = 'ok' then
    vPhase := svVerified
  else if AVReply.Status = 'error' then
    vPhase := svMismatch
  else
    vPhase := svPending;
  Result := SpoofVerifyReplyJSON(AVReply.CmdId, MakeVerify(
    vPhase,
    AVReply.ObservedUA,
    AVReply.ExpectedUA
  ));
end;

function ProfileTemplateToJSON(AKind: TProfileTemplateKind): string;
begin
  case AKind of
    ptReddit:    Result := PROFILE_TEMPLATE_REDDIT;
    ptFacebook:  Result := PROFILE_TEMPLATE_FACEBOOK;
    ptGoogle:    Result := PROFILE_TEMPLATE_GOOGLE;
    ptCustom:    Result := '{"name":"custom","browser":{},"address":{}}';
    else         Result := '{"name":"","browser":{},"address":{}}';
  end;
end;

function ProfileDataToJSON(const AProfile: TProfileData): string;
var
  obj: TJSONObject;
  browser: TJSONObject;
  addr: TJSONObject;
begin
  obj := TJSONObject.Create;
  try
    obj.Add('name', AProfile.Name);
    obj.Add('schema_version', PROFILE_SCHEMA_VERSION);

    browser := TJSONObject.Create;
    if AProfile.Browser.UserAgent <> '' then browser.Add('user_agent', AProfile.Browser.UserAgent);
    if AProfile.Browser.Platform <> '' then browser.Add('platform', AProfile.Browser.Platform);
    if AProfile.Browser.Language <> '' then browser.Add('language', AProfile.Browser.Language);
    if AProfile.Browser.ScreenResolution <> '' then browser.Add('screen_resolution', AProfile.Browser.ScreenResolution);
    if AProfile.Browser.Timezone <> '' then browser.Add('timezone', AProfile.Browser.Timezone);
    obj.Add('browser', browser);

    addr := TJSONObject.Create;
    if AProfile.Address.HasLatLng then
    begin
      addr.Add('lat', AProfile.Address.Lat);
      addr.Add('lng', AProfile.Address.Lng);
    end;
    obj.Add('address', addr);

    Result := obj.AsJSON;
  finally
    obj.Free;
  end;
end;

function ProfileDataFromJSON(const AJSON: string): TProfileData;
var
  data: TJSONData;
  obj: TJSONObject;
  browser: TJSONObject;
  addr: TJSONObject;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Address.HasLatLng := False;

  data := GetJSON(AJSON);
  if data = nil then Exit;
  if data.JsonType = jtObject then
  begin
    obj := TJSONObject(data);
    Result.Name := obj.Get('name', '');

    browser := obj.Get('browser', TJSONObject.Create) as TJSONObject;
    Result.Browser.UserAgent := browser.Get('user_agent', '');
    Result.Browser.Platform := browser.Get('platform', '');
    Result.Browser.Language := browser.Get('language', '');
    Result.Browser.ScreenResolution := browser.Get('screen_resolution', '');
    Result.Browser.Timezone := browser.Get('timezone', '');

    addr := obj.Get('address', TJSONObject.Create) as TJSONObject;
    if addr.FindPath('lat') <> nil then
    begin
      Result.Address.Lat := addr.Get('lat', 0.0);
      Result.Address.Lng := addr.Get('lng', 0.0);
      Result.Address.HasLatLng := True;
    end;
  end;
  data.Free;
end;

function ProfileJSONSchema(const AProfileName: string): string;
begin
  Result := '{' +
    '"$schema":"http://json-schema.org/draft-07/schema#",' +
    '"title":"Spoof Profile",' +
    '"type":"object",' +
    '"required":["name","browser"],' +
    '"properties":{' +
      '"name":{"type":"string"},' +
      '"schema_version":{"type":"string"},' +
      '"browser":{"type":"object","properties":{' +
        '"user_agent":{"type":"string"},' +
        '"platform":{"type":"string"},' +
        '"language":{"type":"string"},' +
        '"screen_resolution":{"type":"string","pattern":"^[0-9]+x[0-9]+$"},' +
        '"timezone":{"type":"string"}' +
      '}},' +
      '"address":{"type":"object","properties":{' +
        '"lat":{"type":"number"},' +
        '"lng":{"type":"number"}' +
      '}}' +
    '}' +
  '}';
end;

function GenerateProfileFile(const AProfileName: string; AKind: TProfileTemplateKind): string;
var
  tmpl: string;
  data: TJSONData;
  obj: TJSONObject;
begin
  tmpl := ProfileTemplateToJSON(AKind);
  data := GetJSON(tmpl);
  if data = nil then
  begin
    Result := ProfileTemplateToJSON(ptCustom);
    Exit;
  end;
  try
    obj := TJSONObject(data);
    obj.Add('name', AProfileName);
    obj.Add('schema_version', PROFILE_SCHEMA_VERSION);
    Result := obj.AsJSON;
  finally
    data.Free;
  end;
end;

end.