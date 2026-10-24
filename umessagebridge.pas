unit uMessageBridge;

{$mode objfpc}{$H+}
{$I /home/lilareyon/CEF4Delphi/source/cef.inc}

interface

uses
  Classes, SysUtils, SyncObjs, Contnrs, fpjson, jsonparser,
  uCEFConstants, uCEFTypes, uCEFInterfaces, uCEFChromiumEvents,
  uCEFChromium, uCEFWindowParent, uCEFApplication,
  SpoofCore;

const
  { Message types }
  MSG_TYPE_REQUEST    = 'request';
  MSG_TYPE_RESPONSE   = 'response';
  MSG_TYPE_EVENT      = 'event';
  MSG_TYPE_ERROR      = 'error';
  MSG_TYPE_SCREENSHOT = 'screenshot';

  { Default timeout in milliseconds }
  DEFAULT_REQUEST_TIMEOUT = 30000;

  { Message Router configuration }
  JS_QUERY_FUNCTION  = 'cefQuery';
  JS_CANCEL_FUNCTION = 'cefQueryCancel';

type
  { Forward declarations }
  TMessageBridge = class;
  TRequestContext = class;

  { Reply callback type for async responses }
  TReplyCallback = procedure(const ARequestId: string; const AResponse: string; const AError: string) of object;

  { Request context for correlation }
  TRequestContext = class(TObject)
  private
    FRequestId: string;
    FBrowser: ICefBrowser;
    FFrame: ICefFrame;
    FCallback: ICefMessageRouterBrowserSideCallback;
    FPersistent: Boolean;
    FStartTime: TDateTime;
    FTimeout: Integer;
    FReplyCallback: TReplyCallback;
    FUserData: TObject;
  public
    constructor Create(const ARequestId: string; const ABrowser: ICefBrowser;
      const AFrame: ICefFrame; const ACallback: ICefMessageRouterBrowserSideCallback;
      APersistent: Boolean; ATimeout: Integer; AReplyCallback: TReplyCallback);
    destructor Destroy; override;

    property RequestId: string read FRequestId;
    property Browser: ICefBrowser read FBrowser;
    property Frame: ICefFrame read FFrame;
    property Callback: ICefMessageRouterBrowserSideCallback read FCallback;
    property Persistent: Boolean read FPersistent;
    property StartTime: TDateTime read FStartTime;
    property Timeout: Integer read FTimeout write FTimeout;
    property ReplyCallback: TReplyCallback read FReplyCallback write FReplyCallback;
    property UserData: TObject read FUserData write FUserData;

    function IsTimedOut: Boolean;
    function ElapsedMs: Int64;
  end;

  { Thread-safe request map for correlation }
  TRequestMap = class(TObject)
  private
    FList: TFPList;
    FCriticalSection: TCriticalSection;
    FNextId: Int64;
    function GenerateId: string;
  public
    constructor Create;
    destructor Destroy; override;

    function Add(const AContext: TRequestContext): string;
    function Remove(const ARequestId: string): TRequestContext;
    function Find(const ARequestId: string): TRequestContext;
    function Count: Integer;
    procedure CleanupTimedOut;
    procedure ClearAll;
  end;

  { Message Bridge Handler - implements ICefMessageRouterBrowserSideHandler }
  TMessageBridgeHandler = class(TInterfacedObject, ICefMessageRouterBrowserSideHandler)
  private
    FBridge: TMessageBridge;
  public
    constructor Create(ABridge: TMessageBridge);

    // ICefMessageRouterBrowserSideHandler
    function OnQuery(const browser: ICefBrowser; const frame: ICefFrame;
      const request_id: Int64; const request: ustring; persistent: Boolean;
      const callback: ICefMessageRouterBrowserSideCallback): Boolean;
    procedure OnQueryCanceled(const browser: ICefBrowser; const frame: ICefFrame;
      const request_id: Int64);
  end;

  { Main Message Bridge Unit }
  TMessageBridge = class(TObject)
  private
    FMessageRouter: ICefMessageRouterBrowserSide;
    FHandler: TMessageBridgeHandler;
    FRequestMap: TRequestMap;
    FConfig: TCefMessageRouterConfig;
    FTimeoutTimer: TTimer;
    FDefaultTimeout: Integer;
    FOnMessageReceived: TNotifyEvent;
    FOnScreenshotReceived: TNotifyEvent;
    FLastScreenshot: string;
    FLastScreenshotTabId: Integer;

    procedure DoTimeoutTimer(Sender: TObject);
    procedure HandleRequest(const ARequestId: string; const AContext: TRequestContext;
      const ARequest: string);
    procedure HandleScreenshot(const ARequestId: string; const AContext: TRequestContext;
      const ARequest: string);
    procedure SendResponse(const AContext: TRequestContext; const AResponse: string; const AError: string = '');
    procedure SendError(const AContext: TRequestContext; const AErrorCode: Integer; const AErrorMsg: string);
    function DecodeBase64(const AData: string): TBytes;
    function EncodeBase64(const AData: TBytes): string;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Initialize(const AConfig: TCefMessageRouterConfig = nil);
    procedure Shutdown;

    { Register with a browser instance }
    procedure RegisterBrowser(const ABrowser: ICefBrowser);
    procedure UnregisterBrowser(const ABrowser: ICefBrowser);

    { Process messages from CEF (call from OnProcessMessageReceived) }
    function OnProcessMessageReceived(const browser: ICefBrowser;
      const frame: ICefFrame; source_process: TCefProcessId;
      const message: ICefProcessMessage): Boolean;

    { Call from OnContextCreated }
    procedure OnContextCreated(const browser: ICefBrowser;
      const frame: ICefFrame; const context: ICefv8Context);

    { Call from OnContextReleased }
    procedure OnContextReleased(const browser: ICefBrowser;
      const frame: ICefFrame; const context: ICefv8Context);

    { Send message to renderer (fire-and-forget) }
    function SendToRenderer(const ABrowser: ICefBrowser; const AFrame: ICefFrame;
      const AMessage: string): Boolean; overload;
    function SendToRenderer(const ABrowser: ICefBrowser; const AFrame: ICefFrame;
      const AMessage: TJSONObject): Boolean; overload;

    { Send request and wait for response (with callback) }
    function SendRequest(const ABrowser: ICefBrowser; const AFrame: ICefFrame;
      const ARequest: string; ATimeout: Integer = DEFAULT_REQUEST_TIMEOUT;
      AReplyCallback: TReplyCallback = nil): string;

    { Send request with JSON payload }
    function SendRequestJSON(const ABrowser: ICefBrowser; const AFrame: ICefFrame;
      const ARequest: TJSONObject; ATimeout: Integer = DEFAULT_REQUEST_TIMEOUT;
      AReplyCallback: TReplyCallback = nil): string;

    { Cancel a pending request }
    procedure CancelRequest(const ARequestId: string);

    { Base64 utilities for screenshots }
    function DecodeScreenshot(const ABase64Data: string): TBytes;
    function EncodeScreenshot(const AImageData: TBytes): string;

    { Properties }
    property MessageRouter: ICefMessageRouterBrowserSide read FMessageRouter;
    property RequestMap: TRequestMap read FRequestMap;
    property DefaultTimeout: Integer read FDefaultTimeout write FDefaultTimeout;
    property OnMessageReceived: TNotifyEvent read FOnMessageReceived write FOnMessageReceived;
    property OnScreenshotReceived: TNotifyEvent read FOnScreenshotReceived write FOnScreenshotReceived;
    property LastScreenshot: string read FLastScreenshot;
    property LastScreenshotTabId: Integer read FLastScreenshotTabId;
  end;

  { Global instance accessor }
  function MessageBridge: TMessageBridge;

implementation

uses
  uCEFMiscFunctions;

var
  GMessageBridge: TMessageBridge = nil;

function MessageBridge: TMessageBridge;
begin
  if GMessageBridge = nil then
    GMessageBridge := TMessageBridge.Create;
  Result := GMessageBridge;
end;

{ TRequestContext }

constructor TRequestContext.Create(const ARequestId: string; const ABrowser: ICefBrowser;
  const AFrame: ICefFrame; const ACallback: ICefMessageRouterBrowserSideCallback;
  APersistent: Boolean; ATimeout: Integer; AReplyCallback: TReplyCallback);
begin
  inherited Create;
  FRequestId := ARequestId;
  FBrowser := ABrowser;
  FFrame := AFrame;
  FCallback := ACallback;
  FPersistent := APersistent;
  FStartTime := Now;
  FTimeout := ATimeout;
  FReplyCallback := AReplyCallback;
  FUserData := nil;
end;

destructor TRequestContext.Destroy;
begin
  FUserData.Free;
  inherited;
end;

function TRequestContext.IsTimedOut: Boolean;
begin
  Result := (MilliSecondsBetween(Now, FStartTime) >= FTimeout);
end;

function TRequestContext.ElapsedMs: Int64;
begin
  Result := MilliSecondsBetween(Now, FStartTime);
end;

{ TRequestMap }

constructor TRequestMap.Create;
begin
  inherited;
  FList := TFPList.Create;
  FCriticalSection := TCriticalSection.Create;
  FNextId := 0;
end;

destructor TRequestMap.Destroy;
begin
  ClearAll;
  FList.Free;
  FCriticalSection.Free;
  inherited;
end;

function TRequestMap.GenerateId: string;
begin
  FCriticalSection.Enter;
  try
    Inc(FNextId);
    Result := Format('req_%d_%d', [GetCurrentThreadId, FNextId]);
  finally
    FCriticalSection.Leave;
  end;
end;

function TRequestMap.Add(const AContext: TRequestContext): string;
begin
  FCriticalSection.Enter;
  try
    Result := AContext.RequestId;
    if Result = '' then
      Result := GenerateId;
    FList.Add(AContext);
  finally
    FCriticalSection.Leave;
  end;
end;

function TRequestMap.Remove(const ARequestId: string): TRequestContext;
var
  i: Integer;
  ctx: TRequestContext;
begin
  Result := nil;
  FCriticalSection.Enter;
  try
    for i := 0 to FList.Count - 1 do
    begin
      ctx := TRequestContext(FList[i]);
      if ctx.RequestId = ARequestId then
      begin
        Result := ctx;
        FList.Delete(i);
        Break;
      end;
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

function TRequestMap.Find(const ARequestId: string): TRequestContext;
var
  i: Integer;
  ctx: TRequestContext;
begin
  Result := nil;
  FCriticalSection.Enter;
  try
    for i := 0 to FList.Count - 1 do
    begin
      ctx := TRequestContext(FList[i]);
      if ctx.RequestId = ARequestId then
      begin
        Result := ctx;
        Break;
      end;
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

function TRequestMap.Count: Integer;
begin
  FCriticalSection.Enter;
  try
    Result := FList.Count;
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TRequestMap.CleanupTimedOut;
var
  i: Integer;
  ctx: TRequestContext;
begin
  FCriticalSection.Enter;
  try
    i := 0;
    while i < FList.Count do
    begin
      ctx := TRequestContext(FList[i]);
      if ctx.IsTimedOut then
      begin
        if Assigned(ctx.ReplyCallback) then
          ctx.ReplyCallback(ctx.RequestId, '', 'Request timed out');
        FList.Delete(i);
        ctx.Free;
      end
      else
        Inc(i);
    end;
  finally
    FCriticalSection.Leave;
  end;
end;

procedure TRequestMap.ClearAll;
var
  i: Integer;
  ctx: TRequestContext;
begin
  FCriticalSection.Enter;
  try
    for i := 0 to FList.Count - 1 do
    begin
      ctx := TRequestContext(FList[i]);
      if Assigned(ctx.ReplyCallback) then
        ctx.ReplyCallback(ctx.RequestId, '', 'Bridge shutting down');
      ctx.Free;
    end;
    FList.Clear;
  finally
    FCriticalSection.Leave;
  end;
end;

{ TMessageBridgeHandler }

constructor TMessageBridgeHandler.Create(ABridge: TMessageBridge);
begin
  inherited Create;
  FBridge := ABridge;
end;

function TMessageBridgeHandler.OnQuery(const browser: ICefBrowser; const frame: ICefFrame;
  const request_id: Int64; const request: ustring; persistent: Boolean;
  const callback: ICefMessageRouterBrowserSideCallback): Boolean;
var
  reqId: string;
  ctx: TRequestContext;
begin
  Result := False;
  if FBridge = nil then Exit;

  reqId := IntToStr(request_id);
  ctx := TRequestContext.Create(reqId, browser, frame, callback, persistent,
    FBridge.FDefaultTimeout, nil);

  FBridge.FRequestMap.Add(ctx);
  FBridge.HandleRequest(reqId, ctx, request);
  Result := True;
end;

procedure TMessageBridgeHandler.OnQueryCanceled(const browser: ICefBrowser;
  const frame: ICefFrame; const request_id: Int64);
var
  reqId: string;
  ctx: TRequestContext;
begin
  if FBridge = nil then Exit;

  reqId := IntToStr(request_id);
  ctx := FBridge.FRequestMap.Remove(reqId);
  if ctx <> nil then
  begin
    if Assigned(ctx.ReplyCallback) then
      ctx.ReplyCallback(ctx.RequestId, '', 'Query canceled');
    ctx.Free;
  end;
end;

{ TMessageBridge }

constructor TMessageBridge.Create;
begin
  inherited;
  FRequestMap := TRequestMap.Create;
  FDefaultTimeout := DEFAULT_REQUEST_TIMEOUT;

  // Create timeout timer (UI thread only)
  FTimeoutTimer := TTimer.Create(nil);
  FTimeoutTimer.Enabled := False;
  FTimeoutTimer.Interval := 1000; // Check every second
  FTimeoutTimer.OnTimer := @DoTimeoutTimer;
end;

destructor TMessageBridge.Destroy;
begin
  Shutdown;
  FTimeoutTimer.Free;
  FRequestMap.Free;
  inherited;
end;

procedure TMessageBridge.Initialize(const AConfig: TCefMessageRouterConfig);
begin
  if FMessageRouter <> nil then Exit;

  if AConfig <> nil then
    FConfig := AConfig
  else
  begin
    CefMessageRouterConfigInit(FConfig);
    FConfig.js_query_function := JS_QUERY_FUNCTION;
    FConfig.js_cancel_function := JS_CANCEL_FUNCTION;
    FConfig.message_size_threshold := 65536; // 64KB threshold for shared memory
  end;

  FHandler := TMessageBridgeHandler.Create(Self);
  FMessageRouter := TCefMessageRouterBrowserSideRef.New(FConfig);
  FMessageRouter.AddHandler(FHandler, True);

  FTimeoutTimer.Enabled := True;
  WriteLn('[MsgBridge] Initialized');
end;

procedure TMessageBridge.Shutdown;
begin
  if FMessageRouter = nil then Exit;

  FTimeoutTimer.Enabled := False;
  FRequestMap.ClearAll;

  if FMessageRouter <> nil then
  begin
    FMessageRouter.RemoveHandler(FHandler);
    FMessageRouter := nil;
  end;

  FHandler := nil;
  WriteLn('[MsgBridge] Shutdown');
end;

procedure TMessageBridge.DoTimeoutTimer(Sender: TObject);
begin
  // Runs on UI thread via TTimer
  FRequestMap.CleanupTimedOut;
end;

procedure TMessageBridge.RegisterBrowser(const ABrowser: ICefBrowser);
begin
  if FMessageRouter <> nil then
    FMessageRouter.OnBrowserCreated(ABrowser);
end;

procedure TMessageBridge.UnregisterBrowser(const ABrowser: ICefBrowser);
begin
  if FMessageRouter <> nil then
    FMessageRouter.OnBrowserDestroyed(ABrowser);
end;

function TMessageBridge.OnProcessMessageReceived(const browser: ICefBrowser;
  const frame: ICefFrame; source_process: TCefProcessId;
  const message: ICefProcessMessage): Boolean;
begin
  Result := False;
  if FMessageRouter <> nil then
    Result := FMessageRouter.OnProcessMessageReceived(browser, frame, source_process, message);
end;

procedure TMessageBridge.OnContextCreated(const browser: ICefBrowser;
  const frame: ICefFrame; const context: ICefv8Context);
begin
  if FMessageRouter <> nil then
    FMessageRouter.OnContextCreated(browser, frame, context);
end;

procedure TMessageBridge.OnContextReleased(const browser: ICefBrowser;
  const frame: ICefFrame; const context: ICefv8Context);
begin
  if FMessageRouter <> nil then
    FMessageRouter.OnContextReleased(browser, frame, context);
end;

function TMessageBridge.SendToRenderer(const ABrowser: ICefBrowser;
  const AFrame: ICefFrame; const AMessage: string): Boolean;
var
  msg: ICefProcessMessage;
begin
  Result := False;
  if (ABrowser = nil) or (AFrame = nil) then Exit;

  msg := TCefProcessMessageRef.New('message_bridge');
  if msg <> nil then
  begin
    msg.Arguments.SetString(0, AMessage);
    Result := AFrame.SendProcessMessage(PID_RENDERER, msg);
  end;
end;

function TMessageBridge.SendToRenderer(const ABrowser: ICefBrowser;
  const AFrame: ICefFrame; const AMessage: TJSONObject): Boolean;
begin
  Result := SendToRenderer(ABrowser, AFrame, AMessage.AsJSON);
end;

function TMessageBridge.SendRequest(const ABrowser: ICefBrowser; const AFrame: ICefFrame;
  const ARequest: string; ATimeout: Integer; AReplyCallback: TReplyCallback): string;
var
  reqId: string;
  ctx: TRequestContext;
  callback: ICefMessageRouterBrowserSideCallback;
begin
  Result := '';
  if (FMessageRouter = nil) or (ABrowser = nil) or (AFrame = nil) then Exit;

  reqId := FRequestMap.GenerateId;

  // Create a callback that will be invoked when renderer responds
  // Note: In CEF message router, the callback is provided by OnQuery
  // For outgoing requests, we use a different mechanism - send via process message
  // and track via RequestMap with a synthetic callback

  ctx := TRequestContext.Create(reqId, ABrowser, AFrame, nil, False, ATimeout, AReplyCallback);
  FRequestMap.Add(ctx);

  // Send via process message (not via cefQuery)
  if not SendToRenderer(ABrowser, AFrame, ARequest) then
  begin
    FRequestMap.Remove(reqId);
    ctx.Free;
    Exit;
  end;

  Result := reqId;
end;

function TMessageBridge.SendRequestJSON(const ABrowser: ICefBrowser; const AFrame: ICefFrame;
  const ARequest: TJSONObject; ATimeout: Integer; AReplyCallback: TReplyCallback): string;
begin
  Result := SendRequest(ABrowser, AFrame, ARequest.AsJSON, ATimeout, AReplyCallback);
end;

procedure TMessageBridge.CancelRequest(const ARequestId: string);
var
  ctx: TRequestContext;
begin
  ctx := FRequestMap.Remove(ARequestId);
  if ctx <> nil then
  begin
    if Assigned(ctx.ReplyCallback) then
      ctx.ReplyCallback(ctx.RequestId, '', 'Canceled');
    ctx.Free;
  end;
end;

procedure TMessageBridge.HandleRequest(const ARequestId: string; const AContext: TRequestContext;
  const ARequest: string);
var
  json: TJSONData;
  obj: TJSONObject;
  msgType, action: string;
begin
  try
    json := GetJSON(ARequest);
    if json = nil then
    begin
      SendError(AContext, -32700, 'Parse error');
      Exit;
    end;

    try
      if not (json is TJSONObject) then
      begin
        SendError(AContext, -32600, 'Invalid request format');
        Exit;
      end;

      obj := TJSONObject(json);
      msgType := obj.Get('type', MSG_TYPE_REQUEST);
      action := obj.Get('action', '');

      if msgType = MSG_TYPE_SCREENSHOT then
      begin
        HandleScreenshot(ARequestId, AContext, ARequest);
        Exit;
      end;

      // Handle other message types
      if Assigned(FOnMessageReceived) then
        FOnMessageReceived(Self);

      // Default: echo back for now
      SendResponse(AContext, Format('{"type":"%s","action":"%s","status":"received"}', [msgType, action]));

    finally
      json.Free;
    end;
  except
    on E: Exception do
      SendError(AContext, -32603, 'Internal error: ' + E.Message);
  end;
end;

procedure TMessageBridge.HandleScreenshot(const ARequestId: string; const AContext: TRequestContext;
  const ARequest: string);
var
  json: TJSONData;
  obj: TJSONObject;
  b64Data, mimeType: string;
  imgData: TBytes;
begin
  try
    json := GetJSON(ARequest);
    if json = nil then
    begin
      SendError(AContext, -32700, 'Parse error');
      Exit;
    end;

    try
      obj := TJSONObject(json);
      b64Data := obj.Get('data', '');
      mimeType := obj.Get('mime', 'image/png');

      if b64Data = '' then
      begin
        SendError(AContext, -32602, 'Missing screenshot data');
        Exit;
      end;

      // Decode base64
      imgData := DecodeBase64(b64Data);

      // Store for retrieval
      FLastScreenshot := b64Data;
      // Extract tab ID from browser identifier
      if AContext.Browser <> nil then
        FLastScreenshotTabId := AContext.Browser.Identifier;

      // Fire event
      if Assigned(FOnScreenshotReceived) then
        FOnScreenshotReceived(Self);

      SendResponse(AContext, Format('{"type":"%s","status":"ok","bytes":%d}', [MSG_TYPE_SCREENSHOT, Length(imgData)]));

    finally
      json.Free;
    end;
  except
    on E: Exception do
      SendError(AContext, -32603, 'Screenshot error: ' + E.Message);
  end;
end;

procedure TMessageBridge.SendResponse(const AContext: TRequestContext; const AResponse: string; const AError: string);
var
  callback: ICefMessageRouterBrowserSideCallback;
begin
  if AContext.Callback <> nil then
  begin
    // Response via cefQuery callback
    if AError = '' then
      AContext.Callback.Success(AResponse)
    else
      AContext.Callback.Failure(-1, AError);
  end
  else if Assigned(AContext.ReplyCallback) then
  begin
    // Response via user callback (for process message requests)
    AContext.ReplyCallback(AContext.RequestId, AResponse, AError);
  end;
end;

procedure TMessageBridge.SendError(const AContext: TRequestContext; const AErrorCode: Integer; const AErrorMsg: string);
begin
  SendResponse(AContext, '', Format('{"code":%d,"message":"%s"}', [AErrorCode, AErrorMsg]));
end;

function TMessageBridge.DecodeBase64(const AData: string): TBytes;
var
  decoded: TBytes;
  len: Integer;
begin
  Result := nil;
  if AData = '' then Exit;

  len := Length(AData);
  SetLength(decoded, (len * 3) div 4 + 4);
  len := Base64Decode(PChar(AData), len, @decoded[0]);
  SetLength(decoded, len);
  Result := decoded;
end;

function TMessageBridge.EncodeBase64(const AData: TBytes): string;
var
  encoded: string;
  len: Integer;
begin
  Result := '';
  if Length(AData) = 0 then Exit;

  len := Base64EncodeLength(Length(AData));
  SetLength(encoded, len);
  len := Base64Encode(@AData[0], Length(AData), PChar(encoded));
  SetLength(encoded, len);
  Result := encoded;
end;

function TMessageBridge.DecodeScreenshot(const ABase64Data: string): TBytes;
begin
  Result := DecodeBase64(ABase64Data);
end;

function TMessageBridge.EncodeScreenshot(const AImageData: TBytes): string;
begin
  Result := EncodeBase64(AImageData);
end;

initialization
  // Global instance created on first access

finalization
  if GMessageBridge <> nil then
  begin
    GMessageBridge.Free;
    GMessageBridge := nil;
  end;

end.