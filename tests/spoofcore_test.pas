program spoofcore_test;

// ─────────────────────────────────────────────────────────────────────────────
// Head-less regression test for the Aethelgard / Dual Citizen spoof race.
//
// Build & run (no CEF, no LCL, no X11, no browser, no network):
//     fpc -Fu.. -FE/tmp -FU/tmp tests/spoofcore_test.pas
//     /tmp/spoofcore_test
//
// It exercises the EXACT functions the browser's IPC handler calls
// (ucontrollerbrowser.pas -> SpoofCore), so the logic proved here is the logic
// that ships.  The test is what makes the "spoofing silently fails while IPC
// reports success" defect unrepeatable: every failure mode must produce a
// non-"ok" reply, and a spoof is only "verified" when the user agent read back
// from the live page equals the one the profile asked for.
// ─────────────────────────────────────────────────────────────────────────────

{$mode objfpc}{$H+}

uses
  SysUtils, SpoofCore;

var
  Passed, Failed: Integer;

procedure Check(const AName: string; ACondition: Boolean; const ADetail: string = '');
begin
  if ACondition then
  begin
    Inc(Passed);
    WriteLn('  PASS  ', AName);
  end
  else
  begin
    Inc(Failed);
    WriteLn('  FAIL  ', AName);
    if ADetail <> '' then WriteLn('        -> ', ADetail);
  end;
end;

function Contains(const AHaystack, ANeedle: string): Boolean;
begin
  Result := (Pos(ANeedle, AHaystack) > 0);
end;

const
  REAL_UA = 'Mozilla/5.0 (X11; Linux x86_64; rv:131.0) Gecko/20100101 Firefox/131.0';
  SP_UA   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:142.0) Gecko/20100101 Firefox/142.0';

var
  dec: TSpoofDecision;
  v: TSpoofVerify;
  reply: string;
  pf, tf, hd, ap: Boolean;
  violations: Integer;
  total: Integer;

begin
  WriteLn('=========================================================');
  WriteLn(' SpoofCore regression suite');
  WriteLn(' Invariant: status "ok" <=> spoof actually applied');
  WriteLn('=========================================================');

  // ─────────────────────────────────────────────────────────────────────────
  WriteLn;
  WriteLn('[1] Failure modes must NEVER report status "ok"');

  // 1a. The startup race: socket is bound, but the tab does not exist yet.
  dec := SpoofDecisionFromFlags(True, False, True, False, 1234);
  Check('race (tab missing) is not spApplied', dec.Phase <> spApplied);
  Check('race (tab missing) is spError', dec.Phase = spError);
  Check('race (tab missing) reports tab_not_found',
    dec.ErrorCode = ERR_TAB_NOT_FOUND, dec.ErrorCode);
  reply := SpoofReplyJSON('7', 'reddit', dec);
  Check('race reply is not status ok', not Contains(reply, '"status":"ok"'), reply);
  Check('race reply says error', Contains(reply, '"status":"error"'), reply);
  Check('race reply carries applied:false', Contains(reply, '"applied":false'), reply);
  Check('SpoofDecisionIsSuccess(race) is false', not SpoofDecisionIsSuccess(dec));

  // 1b. Profile missing from profiles.json.
  dec := SpoofDecisionFromFlags(False, True, True, False, 1234);
  Check('missing profile is not spApplied', dec.Phase <> spApplied);
  Check('missing profile reports profile_not_found',
    dec.ErrorCode = ERR_PROFILE_NOT_FOUND, dec.ErrorCode);
  reply := SpoofReplyJSON('8', 'reddit', dec);
  Check('missing profile reply is not status ok', not Contains(reply, '"status":"ok"'), reply);

  // 1c. Profile exists but carries no spoofable fields.
  dec := SpoofDecisionFromFlags(True, True, False, False, 0);
  Check('no spoof data is not spApplied', dec.Phase <> spApplied);
  Check('no spoof data reports no_spoof_data',
    dec.ErrorCode = ERR_NO_SPOOF_DATA, dec.ErrorCode);
  reply := SpoofReplyJSON('9', 'reddit', dec);
  Check('no spoof data reply is not status ok', not Contains(reply, '"status":"ok"'), reply);

  // 1d. JS stored but not yet applied to a live frame -> pending, not ok.
  dec := SpoofDecisionFromFlags(True, True, True, False, 777);
  Check('stored-but-not-applied is spPending', dec.Phase = spPending);
  reply := SpoofReplyJSON('10', 'reddit', dec);
  Check('pending reply is not status ok', not Contains(reply, '"status":"ok"'), reply);
  Check('pending reply says pending', Contains(reply, '"status":"pending"'), reply);
  Check('pending reply carries applied:false', Contains(reply, '"applied":false'), reply);
  Check('pending reply explains the reason',
    Contains(reply, 'stored_for_next_load'), reply);

  // ─────────────────────────────────────────────────────────────────────────
  WriteLn;
  WriteLn('[2] The success path');

  // 2a. Applied to a live frame -> ok, and only then.
  dec := SpoofDecisionFromFlags(True, True, True, True, 2048);
  Check('applied is spApplied', dec.Phase = spApplied);
  Check('SpoofDecisionIsSuccess(applied) is true', SpoofDecisionIsSuccess(dec));
  reply := SpoofReplyJSON('11', 'reddit', dec);
  Check('applied reply is status ok', Contains(reply, '"status":"ok"'), reply);
  Check('applied reply carries applied:true', Contains(reply, '"applied":true'), reply);
  Check('applied reply reports the byte count',
    Contains(reply, '"js_bytes":2048'), reply);
  Check('applied reply names the profile',
    Contains(reply, '"profile":"reddit"'), reply);

  // ─────────────────────────────────────────────────────────────────────────
  WriteLn;
  WriteLn('[3] Read-back verification (the spoof actually took effect)');

  // 3a. Read-back matches the requested UA -> verified.
  v := VerifyDecisionFromFlags(True, True, True, SP_UA, SP_UA);
  Check('matching UA is svVerified', v.Phase = svVerified);
  Check('SpoofVerifyIsSuccess(matching) is true', SpoofVerifyIsSuccess(v));
  reply := SpoofVerifyReplyJSON('12', v);
  Check('verify reply is status ok', Contains(reply, '"status":"ok"'), reply);
  Check('verify reply carries verified:true', Contains(reply, '"verified":true'), reply);

  // 3b. Read-back returns the REAL UA -> mismatch, never "ok".
  v := VerifyDecisionFromFlags(True, True, True, REAL_UA, SP_UA);
  Check('mismatching UA is svMismatch', v.Phase = svMismatch);
  Check('SpoofVerifyIsSuccess(mismatch) is false', not SpoofVerifyIsSuccess(v));
  reply := SpoofVerifyReplyJSON('13', v);
  Check('mismatch reply is not status ok', not Contains(reply, '"status":"ok"'), reply);
  Check('mismatch reply carries verified:false',
    Contains(reply, '"verified":false'), reply);
  Check('mismatch reply names ua_mismatch',
    Contains(reply, '"error":"ua_mismatch"'), reply);
  Check('mismatch reply shows what was actually observed',
    Contains(reply, 'Firefox/131.0'), reply);

  // 3c. Not applied yet -> pending, never "ok".
  v := VerifyDecisionFromFlags(True, False, False, '', SP_UA);
  Check('not-applied verify is svPending', v.Phase = svPending);
  reply := SpoofVerifyReplyJSON('14', v);
  Check('not-applied verify reply is not status ok',
    not Contains(reply, '"status":"ok"'), reply);

  // 3d. No spoof armed at all -> error, never "ok".
  v := VerifyDecisionFromFlags(False, False, False, '', SP_UA);
  Check('unarmed verify is svNoSpoof', v.Phase = svNoSpoof);
  reply := SpoofVerifyReplyJSON('15', v);
  Check('unarmed verify reply is not status ok',
    not Contains(reply, '"status":"ok"'), reply);

  // 3e. Observation not yet available -> pending, never "ok".
  v := VerifyDecisionFromFlags(True, True, False, '', SP_UA);
  Check('no-observation verify is svPending', v.Phase = svPending);
  reply := SpoofVerifyReplyJSON('16', v);
  Check('no-observation verify reply is not status ok',
    not Contains(reply, '"status":"ok"'), reply);

  // ─────────────────────────────────────────────────────────────────────────
  WriteLn;
  WriteLn('[4] UA normalisation (whitespace / case tolerant comparison)');

  Check('UAMatches on identical strings', UAMatches(SP_UA, SP_UA));
  Check('UAMatches ignores case', UAMatches(SP_UA, LowerCase(SP_UA)));
  Check('UAMatches ignores repeated spaces',
    UAMatches('Mozilla/5.0 (X11)', 'Mozilla/5.0  (X11)'));
  Check('UAMatches trims edges', UAMatches('  Mozilla/5.0  ', 'Mozilla/5.0'));
  Check('UAMatches rejects different UA', not UAMatches(SP_UA, REAL_UA));
  Check('UAMatches rejects empty expected', not UAMatches('', REAL_UA));
  Check('UAMatches rejects empty observed', not UAMatches(SP_UA, ''));
  Check('NormalizeUA collapses whitespace',
    NormalizeUA('  a   b ') = 'a b', NormalizeUA('  a   b '));

  // ─────────────────────────────────────────────────────────────────────────
  WriteLn;
  WriteLn('[5] Reply JSON is well-formed and safely escaped');

  dec := MakeSpoofError(ERR_NO_PROFILE, 'quote " and backslash \ and newline' + #10);
  reply := SpoofReplyJSON('id"1', 'pro"file', dec);
  Check('reply escapes the cmd id quote', not Contains(reply, 'id"1'), reply);
  Check('reply escapes the profile quote', not Contains(reply, 'pro"file'), reply);
  Check('reply escapes the backslash', Contains(reply, '\\'), reply);
  Check('reply escapes the newline', not Contains(reply, #10), reply);
  Check('reply still has a status field', Contains(reply, '"status":'), reply);

  // ─────────────────────────────────────────────────────────────────────────
  WriteLn;
  WriteLn('[6] Exhaustive sweep: "ok" is impossible unless actually applied');

  violations := 0;
  total := 0;
    for pf := False to True do
      for tf := False to True do
        for hd := False to True do
          for ap := False to True do
          begin
            Inc(total);
            dec := SpoofDecisionFromFlags(pf, tf, hd, ap, 1);
            reply := SpoofReplyJSON('x', 'p', dec);
            // The ONLY combination allowed to produce "ok" is:
            // profile found + tab found + has data + applied right now.
            if Contains(reply, '"status":"ok"') then
              if not (pf and tf and hd and ap) then
              begin
                Inc(violations);
                WriteLn('        VIOLATION pf=', pf, ' tf=', tf, ' hd=', hd, ' ap=', ap, ' -> ', reply);
              end;
            // And whenever the decision says "applied", the reply MUST say ok.
            if (dec.Phase = spApplied) and not Contains(reply, '"status":"ok"') then
            begin
              Inc(violations);
              WriteLn('        VIOLATION (applied but not ok) -> ', reply);
            end;
          end;
    Check('exhaustive sweep: 16 combinations, zero violations',
      violations = 0, 'violations=' + IntToStr(violations));
  Check('exhaustive sweep covered 16 combinations', total = 16,
    'total=' + IntToStr(total));

  // ─────────────────────────────────────────────────────────────────────────
  WriteLn;
  WriteLn('=========================================================');
  WriteLn(' Passed: ', Passed, '   Failed: ', Failed);
  WriteLn('=========================================================');
  if Failed > 0 then
  begin
    WriteLn(' RESULT: FAIL');
    Halt(1);
  end;
  WriteLn(' RESULT: PASS');
  Halt(0);
end.
