unit SpoofCore;

// ─────────────────────────────────────────────────────────────────────────────
// SpoofCore -- pure spoof state machine for the Aethelgard / Dual Citizen
// CEF 131 browser (build-131).
//
// WHY THIS EXISTS
// ───────────────
// The "spoof" IPC handler used to reply  {"id":"..","status":"ok"}  UNCONDITIONALLY,
// even when the spoof had silently done nothing.  Two failure modes were
// reachable in normal operation:
//
//   1. RACE (the confirmed startup race): the command socket is bound in
//      FormCreate, but the first tab is not created until the first Timer1 tick
//      (500 ms later, and only once the form is realized).  A "spoof" command
//      arriving inside that window found no tab; SpoofTab() silently returned;
//      the client was told "ok".  The page then loaded with the REAL user agent.
//
//   2. NEVER-APPLIED: SpoofTab() only *stored* the JS for application on the
//      next LoadEnd.  If the page had already loaded and no further navigation
//      happened, the stored JS was never executed -- again, IPC said "ok".
//
// This unit holds the decision logic as PURE functions with no CEF, LCL, X11 or
// filesystem dependency, so it can be unit-tested head-lessly (see
// tests/spoofcore_test.pas).  The browser form calls exactly these functions
// to build its replies, so the tested logic IS the shipped logic.
//
// INVARIANTS (both asserted by the test suite):
//   I1. status "ok" is emitted if and only if the spoof JS was actually applied
//       to a live frame.  Every other outcome is "pending" or "error".
//   I2. a spoof is reported "verified" if and only if the user agent read back
//       from the live page equals the user agent the profile asked for.
// ─────────────────────────────────────────────────────────────────────────────

{$mode objfpc}{$H+}

interface

type
  // ── the "arm / apply" decision (the spoof command) ──────────────────────
  TSpoofPhase = (spError, spPending, spApplied);

  TSpoofDecision = record
    Phase: TSpoofPhase;
    ErrorCode: string;   // '' unless Phase = spError
    ErrorMsg: string;    // '' unless Phase = spError
    JSBytes: Integer;    // size of the generated spoof JS
  end;

  // ── the "verify" decision (the read-back check) ──────────────────────────
  TSpoofVerifyPhase = (svPending, svVerified, svMismatch, svNoSpoof);

  TSpoofVerify = record
    Phase: TSpoofVerifyPhase;
    ObservedUA: string;  // user agent actually read back from the live page
    ExpectedUA: string;  // user agent the profile asked for
  end;

const
  ERR_PROFILE_NOT_FOUND  = 'profile_not_found';
  ERR_TAB_NOT_FOUND      = 'tab_not_found';
  ERR_NO_PROFILE         = 'no_profile';
  ERR_NO_SPOOF_DATA      = 'no_spoof_data';
  ERR_NO_PROFILE_NAME    = 'no_profile_name';

// ── arm/apply ──────────────────────────────────────────────────────────────
function MakeSpoofError(const ACode, AMsg: string): TSpoofDecision;
function MakeSpoofPending(AJSBytes: Integer): TSpoofDecision;
function MakeSpoofApplied(AJSBytes: Integer): TSpoofDecision;

// Core decision.  AProfileFound / ATabFound describe the *observed* state;
// AHasData says the profile carried at least one spoofable field;
// AAppliedNow says the JS was executed against a live frame right now.
function SpoofDecisionFromFlags(ProfileFound, TabFound, HasData, AppliedNow: Boolean;
  AJSBytes: Integer): TSpoofDecision;

// Reply builder used verbatim by the IPC handler.
function SpoofReplyJSON(const ACmdId, AProfileName: string;
  const ADec: TSpoofDecision): string;

// True only for a decision that actually applied the spoof.
function SpoofDecisionIsSuccess(const ADec: TSpoofDecision): Boolean;

// ── verify ─────────────────────────────────────────────────────────────────
function MakeVerify(APhase: TSpoofVerifyPhase; const AObserved, AExpected: string): TSpoofVerify;
function VerifyDecisionFromFlags(Armed, Applied, HasObservation: Boolean;
  const AObserved, AExpected: string): TSpoofVerify;
function SpoofVerifyReplyJSON(const ACmdId: string; const AV: TSpoofVerify): string;
function SpoofVerifyIsSuccess(const AV: TSpoofVerify): Boolean;

// ── shared helpers ─────────────────────────────────────────────────────────
// UA comparison used by the launcher's post-load read-back verification.
function NormalizeUA(const S: string): string;
function UAMatches(const AProfileUA, ALiveUA: string): Boolean;

function JsonEscape(const S: string): string;

implementation

uses SysUtils;

function JsonEscape(const S: string): string;
var
  i: Integer;
  c: Char;
  res: string;
begin
  res := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if c = '"' then
      res := res + '\"'
    else if c = '\' then
      res := res + '\\'
    else if c = #8 then
      res := res + '\b'
    else if c = #9 then
      res := res + '\t'
    else if c = #10 then
      res := res + '\n'
    else if c = #12 then
      res := res + '\f'
    else if c = #13 then
      res := res + '\r'
    else if (Ord(c) < 32) then
      res := res + '\u' + LowerCase(IntToHex(Ord(c), 4))
    else
      res := res + c;
  end;
  Result := res;
end;

function MakeSpoofError(const ACode, AMsg: string): TSpoofDecision;
begin
  Result.Phase := spError;
  Result.ErrorCode := ACode;
  Result.ErrorMsg := AMsg;
  Result.JSBytes := 0;
end;

function MakeSpoofPending(AJSBytes: Integer): TSpoofDecision;
begin
  Result.Phase := spPending;
  Result.ErrorCode := '';
  Result.ErrorMsg := '';
  Result.JSBytes := AJSBytes;
end;

function MakeSpoofApplied(AJSBytes: Integer): TSpoofDecision;
begin
  Result.Phase := spApplied;
  Result.ErrorCode := '';
  Result.ErrorMsg := '';
  Result.JSBytes := AJSBytes;
end;

function SpoofDecisionFromFlags(ProfileFound, TabFound, HasData, AppliedNow: Boolean;
  AJSBytes: Integer): TSpoofDecision;
begin
  if not ProfileFound then
    Result := MakeSpoofError(ERR_PROFILE_NOT_FOUND,
      'profile not present in profiles.json')
  else if not TabFound then
    Result := MakeSpoofError(ERR_TAB_NOT_FOUND,
      'target tab does not exist yet (not created, or already closed)')
  else if not HasData then
    Result := MakeSpoofError(ERR_NO_SPOOF_DATA,
      'profile produced no spoofable browser fields')
  else if AppliedNow then
    Result := MakeSpoofApplied(AJSBytes)
  else
    Result := MakeSpoofPending(AJSBytes);
end;

function SpoofDecisionIsSuccess(const ADec: TSpoofDecision): Boolean;
begin
  Result := (ADec.Phase = spApplied);
end;

function SpoofReplyJSON(const ACmdId, AProfileName: string;
  const ADec: TSpoofDecision): string;
begin
  case ADec.Phase of
    spApplied:
      Result := Format('{"id":"%s","status":"ok","profile":"%s","applied":true,"js_bytes":%d}',
        [JsonEscape(ACmdId), JsonEscape(AProfileName), ADec.JSBytes]);
    spPending:
      Result := Format('{"id":"%s","status":"pending","profile":"%s","applied":false,' +
        '"js_bytes":%d,"reason":"stored_for_next_load"}',
        [JsonEscape(ACmdId), JsonEscape(AProfileName), ADec.JSBytes]);
  else
    Result := Format('{"id":"%s","status":"error","error":"%s","message":"%s","applied":false}',
      [JsonEscape(ACmdId), JsonEscape(ADec.ErrorCode), JsonEscape(ADec.ErrorMsg)]);
  end;
end;

// ── verify ─────────────────────────────────────────────────────────────────

function MakeVerify(APhase: TSpoofVerifyPhase; const AObserved, AExpected: string): TSpoofVerify;
begin
  Result.Phase := APhase;
  Result.ObservedUA := AObserved;
  Result.ExpectedUA := AExpected;
end;

function VerifyDecisionFromFlags(Armed, Applied, HasObservation: Boolean;
  const AObserved, AExpected: string): TSpoofVerify;
begin
  if not Armed then
    Result := MakeVerify(svNoSpoof, AObserved, AExpected)
  else if (not Applied) or (not HasObservation) then
    Result := MakeVerify(svPending, AObserved, AExpected)
  else if UAMatches(AExpected, AObserved) then
    Result := MakeVerify(svVerified, AObserved, AExpected)
  else
    Result := MakeVerify(svMismatch, AObserved, AExpected);
end;

function SpoofVerifyReplyJSON(const ACmdId: string; const AV: TSpoofVerify): string;
begin
  case AV.Phase of
    svVerified:
      Result := Format('{"id":"%s","status":"ok","verified":true,"observed_ua":"%s","expected_ua":"%s"}',
        [JsonEscape(ACmdId), JsonEscape(AV.ObservedUA), JsonEscape(AV.ExpectedUA)]);
    svMismatch:
      Result := Format('{"id":"%s","status":"error","verified":false,"error":"ua_mismatch",' +
        '"observed_ua":"%s","expected_ua":"%s"}',
        [JsonEscape(ACmdId), JsonEscape(AV.ObservedUA), JsonEscape(AV.ExpectedUA)]);
    svNoSpoof:
      Result := Format('{"id":"%s","status":"error","verified":false,"error":"no_spoof_armed"}',
        [JsonEscape(ACmdId)]);
  else
    Result := Format('{"id":"%s","status":"pending","verified":false,"observed_ua":"%s","expected_ua":"%s"}',
      [JsonEscape(ACmdId), JsonEscape(AV.ObservedUA), JsonEscape(AV.ExpectedUA)]);
  end;
end;

function SpoofVerifyIsSuccess(const AV: TSpoofVerify): Boolean;
begin
  Result := (AV.Phase = svVerified);
end;

// ── shared helpers ─────────────────────────────────────────────────────────

function NormalizeUA(const S: string): string;
var
  i: Integer;
  c: Char;
  res: string;
  prevSpace: Boolean;
begin
  res := '';
  prevSpace := True;
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if (c = ' ') or (c = #9) or (c = #10) or (c = #13) then
    begin
      if not prevSpace then
      begin
        res := res + ' ';
        prevSpace := True;
      end;
    end
    else
    begin
      res := res + c;
      prevSpace := False;
    end;
  end;
  Result := Trim(res);
end;

function UAMatches(const AProfileUA, ALiveUA: string): Boolean;
begin
  Result := (Trim(AProfileUA) <> '') and (Trim(ALiveUA) <> '') and
            (AnsiCompareText(NormalizeUA(AProfileUA), NormalizeUA(ALiveUA)) = 0);
end;

end.
