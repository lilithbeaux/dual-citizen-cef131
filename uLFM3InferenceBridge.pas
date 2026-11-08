unit uLFM3InferenceBridge;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser,
  uCEFInterfaces, uCEFTypes, uCEFConstants,
  uCEFBrowser, uCEFFrame,
  baseunix, unix;

const
  LFM3_IPC_SOCKET = '/tmp/dual-citizen-inference.sock';
  IPC_MAGIC = $4C464D33; // 'LFM3' in hex
  MAX_IPC_MESSAGE = 10 * 1024 * 1024; // 10MB

type
  TLFM3MessageType = (
    mtInferenceRequest,
    mtCaptureFrame,
    mtSetGoal,
    mtExecuteAction,
    mtGetStatus,
    mtActionResult,
    mtFrameReady,
    mtError
  );

  TLFM3InferenceBridge = class
  private
    FIpcSocket: LongInt;
    FConnected: Boolean;
    FBuffer: string;
    FPendingRequests: TStringList; // request_id -> TJSONObject
    FOnActionReceived: TNotifyEvent;
    FOnFrameRequested: TNotifyEvent;
    FLastError: string;
    
    function ConnectSocket: Boolean;
    procedure DisconnectSocket;
    function SendMessage(const Msg: TJSONObject): Boolean;
    function ReceiveMessage(out Msg: TJSONObject): Boolean;
    function ReadExact(var Buffer; Count: SizeInt): Boolean;
    function WriteExact(const Buffer; Count: SizeInt): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    
    function Initialize: Boolean;
    procedure Shutdown;
    
    // High-level operations
    function RequestInference(const TabId, Goal: string; const Frames: TJSONArray): TJSONObject;
    function SendFrame(const TabId: string; const FrameData: TJSONObject): TJSONObject;
    function SetGoal(const TabId, Goal: string): TJSONObject;
    function ExecuteAction(const TabId: string; const Action: TJSONObject): TJSONObject;
    function GetStatus: TJSONObject;
    
    // Async message processing (call from timer)
    procedure ProcessMessages;
    
    property Connected: Boolean read FConnected;
    property LastError: string read FLastError;
    property OnActionReceived: TNotifyEvent read FOnActionReceived write FOnActionReceived;
    property OnFrameRequested: TNotifyEvent read FOnFrameRequested write FOnFrameRequested;
  end;

  // Global instance
  function LFM3Bridge: TLFM3InferenceBridge;

implementation

var
  FLFM3Bridge: TLFM3InferenceBridge = nil;

function LFM3Bridge: TLFM3InferenceBridge;
begin
  if FLFM3Bridge = nil then
    FLFM3Bridge := TLFM3InferenceBridge.Create;
  Result := FLFM3Bridge;
end;

{ TLFM3InferenceBridge }

constructor TLFM3InferenceBridge.Create;
begin
  inherited Create;
  FIpcSocket := -1;
  FConnected := False;
  FBuffer := '';
  FPendingRequests := TStringList.Create;
  FPendingRequests.Sorted := True;
  FPendingRequests.Duplicates := dupIgnore;
end;

destructor TLFM3InferenceBridge.Destroy;
begin
  Shutdown;
  FPendingRequests.Free;
  inherited Destroy;
end;

function TLFM3InferenceBridge.ConnectSocket: Boolean;
var
  Addr: sockaddr_un;
  Flags: LongInt;
begin
  Result := False;
  FLastError := '';
  
  // Clean up any existing socket
  if FIpcSocket >= 0 then
  begin
    fpClose(FIpcSocket);
    FIpcSocket := -1;
  end;
  
  FIpcSocket := fpSocket(AF_UNIX, SOCK_STREAM, 0);
  if FIpcSocket < 0 then
  begin
    FLastError := 'Socket creation failed: ' + StrError(fpGetErrNo);
    Exit;
  end;
  
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sun_family := AF_UNIX;
  StrPCopy(Addr.sun_path, LFM3_IPC_SOCKET);
  
  if fpConnect(FIpcSocket, @Addr, SizeOf(Addr)) < 0 then
  begin
    FLastError := 'Connection failed: ' + StrError(fpGetErrNo);
    fpClose(FIpcSocket);
    FIpcSocket := -1;
    Exit;
  end;
  
  // Set non-blocking
  Flags := fpFcntl(FIpcSocket, F_GETFL, 0);
  if Flags >= 0 then
    fpFcntl(FIpcSocket, F_SETFL, Flags or O_NONBLOCK);
  
  FConnected := True;
  Result := True;
end;

procedure TLFM3InferenceBridge.DisconnectSocket;
begin
  if FIpcSocket >= 0 then
  begin
    fpClose(FIpcSocket);
    FIpcSocket := -1;
  end;
  FConnected := False;
end;

function TLFM3InferenceBridge.Initialize: Boolean;
begin
  if FConnected then Exit(True);
  Result := ConnectSocket;
  if not Result then
    WriteLn('[LFM3Bridge] Failed to connect: ', FLastError);
end;

procedure TLFM3InferenceBridge.Shutdown;
begin
  DisconnectSocket;
end;

function TLFM3InferenceBridge.ReadExact(var Buffer; Count: SizeInt): Boolean;
var
  TotalRead: SizeInt;
  Ptr: PByte;
  BytesRead: SizeInt;
begin
  Result := False;
  TotalRead := 0;
  Ptr := @Buffer;
  
  while TotalRead < Count do
  begin
    BytesRead := fpRead(FIpcSocket, Ptr + TotalRead, Count - TotalRead);
    if BytesRead <= 0 then
    begin
      if (fpGetErrNo = EAGAIN) or (fpGetErrNo = EWOULDBLOCK) then
      begin
        // Would block, wait a bit
        fpSelect(FIpcSocket + 1, @FD_SET(FIpcSocket), nil, nil, 1000); // 1ms
        Continue;
      end;
      Exit;
    end;
    Inc(TotalRead, BytesRead);
  end;
  Result := True;
end;

function TLFM3InferenceBridge.WriteExact(const Buffer; Count: SizeInt): Boolean;
var
  TotalWritten: SizeInt;
  Ptr: PByte;
  BytesWritten: SizeInt;
begin
  Result := False;
  TotalWritten := 0;
  Ptr := @Buffer;
  
  while TotalWritten < Count do
  begin
    BytesWritten := fpWrite(FIpcSocket, Ptr + TotalWritten, Count - TotalWritten);
    if BytesWritten <= 0 then
    begin
      if (fpGetErrNo = EAGAIN) or (fpGetErrNo = EWOULDBLOCK) then
      begin
        fpSelect(FIpcSocket + 1, nil, @FD_SET(FIpcSocket), nil, 1000);
        Continue;
      end;
      Exit;
    end;
    Inc(TotalWritten, BytesWritten);
  end;
  Result := True;
end;

function TLFM3InferenceBridge.SendMessage(const Msg: TJSONObject): Boolean;
var
  JsonStr: string;
  JsonBytes: TBytes;
  Len: LongWord;
begin
  Result := False;
  
  if not FConnected then
  begin
    if not ConnectSocket then Exit;
  end;
  
  JsonStr := Msg.AsJSON;
  JsonBytes := BytesOf(JsonStr);
  Len := Length(JsonBytes);
  
  if Len > MAX_IPC_MESSAGE then
  begin
    FLastError := 'Message too large: ' + IntToStr(Len);
    Exit;
  end;
  
  // Send length prefix (4 bytes little-endian) + JSON
  if not WriteExact(Len, SizeOf(Len)) then
  begin
    FLastError := 'Failed to write length prefix';
    DisconnectSocket;
    Exit;
  end;
  
  if not WriteExact(JsonBytes[0], Len) then
  begin
    FLastError := 'Failed to write message body';
    DisconnectSocket;
    Exit;
  end;
  
  Result := True;
end;

function TLFM3InferenceBridge.ReceiveMessage(out Msg: TJSONObject): Boolean;
var
  Len: LongWord;
  JsonBytes: TBytes;
  JsonStr: string;
begin
  Result := False;
  Msg := nil;
  
  if not FConnected then Exit;
  
  // Read length prefix
  if not ReadExact(Len, SizeOf(Len)) then Exit;
  
  if Len > MAX_IPC_MESSAGE then
  begin
    FLastError := 'Incoming message too large: ' + IntToStr(Len);
    DisconnectSocket;
    Exit;
  end;
  
  SetLength(JsonBytes, Len);
  if not ReadExact(JsonBytes[0], Len) then Exit;
  
  JsonStr := StringOf(JsonBytes);
  
  try
    Msg := TJSONObject(GetJSON(JsonStr));
    Result := True;
  except
    on E: Exception do
      FLastError := 'JSON parse error: ' + E.Message;
  end;
end;

function TLFM3InferenceBridge.RequestInference(const TabId, Goal: string; const Frames: TJSONArray): TJSONObject;
var
  Msg, Response: TJSONObject;
  Payload: TJSONObject;
begin
  Result := nil;
  
  Msg := TJSONObject.Create;
  try
    Msg.Strings['type'] := 'inference_request';
    Msg.Strings['tab_id'] := TabId;
    
    Payload := TJSONObject.Create;
    Payload.Strings['goal'] := Goal;
    Payload.Arrays['frames'] := Frames;
    Msg.Add('payload', Payload);
    
    if SendMessage(Msg) and ReceiveMessage(Response) then
      Result := Response
    else
      FLastError := 'IPC send/receive failed';
  finally
    Msg.Free;
  end;
end;

function TLFM3InferenceBridge.SendFrame(const TabId: string; const FrameData: TJSONObject): TJSONObject;
var
  Msg, Response: TJSONObject;
  Payload: TJSONObject;
begin
  Result := nil;
  
  Msg := TJSONObject.Create;
  try
    Msg.Strings['type'] := 'capture_frame';
    Msg.Strings['tab_id'] := TabId;
    
    Payload := TJSONObject.Create;
    Payload.Add('base64', FrameData.Clone); // base64 string
    Payload.Integers['timestamp'] := FrameData.Ints['timestamp'];
    Payload.Strings['url'] := FrameData.Strings['url'];
    Payload.Strings['dom_hash'] := FrameData.Strings['dom_hash'];
    Msg.Add('payload', Payload);
    
    if SendMessage(Msg) and ReceiveMessage(Response) then
      Result := Response
    else
      FLastError := 'IPC send/receive failed';
  finally
    Msg.Free;
  end;
end;

function TLFM3InferenceBridge.SetGoal(const TabId, Goal: string): TJSONObject;
var
  Msg, Response: TJSONObject;
  Payload: TJSONObject;
begin
  Result := nil;
  
  Msg := TJSONObject.Create;
  try
    Msg.Strings['type'] := 'set_goal';
    Msg.Strings['tab_id'] := TabId;
    
    Payload := TJSONObject.Create;
    Payload.Strings['goal'] := Goal;
    Msg.Add('payload', Payload);
    
    if SendMessage(Msg) and ReceiveMessage(Response) then
      Result := Response
    else
      FLastError := 'IPC send/receive failed';
  finally
    Msg.Free;
  end;
end;

function TLFM3InferenceBridge.ExecuteAction(const TabId: string; const Action: TJSONObject): TJSONObject;
var
  Msg, Response: TJSONObject;
  Payload: TJSONObject;
begin
  Result := nil;
  
  Msg := TJSONObject.Create;
  try
    Msg.Strings['type'] := 'execute_action';
    Msg.Strings['tab_id'] := TabId;
    
    Payload := TJSONObject.Create;
    Payload.Add('action', Action.Clone);
    Msg.Add('payload', Payload);
    
    if SendMessage(Msg) and ReceiveMessage(Response) then
      Result := Response
    else
      FLastError := 'IPC send/receive failed';
  finally
    Msg.Free;
  end;
end;

function TLFM3InferenceBridge.GetStatus: TJSONObject;
var
  Msg, Response: TJSONObject;
begin
  Result := nil;
  
  Msg := TJSONObject.Create;
  try
    Msg.Strings['type'] := 'get_status';
    
    if SendMessage(Msg) and ReceiveMessage(Response) then
      Result := Response
    else
      FLastError := 'IPC send/receive failed';
  finally
    Msg.Free;
  end;
end;

procedure TLFM3InferenceBridge.ProcessMessages;
var
  Msg: TJSONObject;
  MsgType: string;
  TabId: string;
  Payload: TJSONObject;
begin
  if not FConnected then
  begin
    if not ConnectSocket then Exit;
  end;
  
  // Non-blocking read loop
  while True do
  begin
    // Check if data available
    if not ReceiveMessage(Msg) then
      Break; // No more data or error
    
    try
      MsgType := Msg.Strings['type'];
      TabId := Msg.Strings['tab_id'];
      Payload := TJSONObject(Msg.Find('payload'));
      
      if MsgType = 'action_result' then
      begin
        // Inference service returned an action to execute
        if Assigned(FOnActionReceived) then
          FOnActionReceived(Self); // Payload in Msg
      end
      else if MsgType = 'frame_requested' then
      begin
        // Bridge needs a frame
        if Assigned(FOnFrameRequested) then
          FOnFrameRequested(Self);
      end
      else if MsgType = 'error' then
      begin
        FLastError := Payload.Strings['message'];
        WriteLn('[LFM3Bridge] Error from bridge: ', FLastError);
      end;
    finally
      Msg.Free;
    end;
  end;
end;

initialization
finalization
  if FLFM3Bridge <> nil then
  begin
    FLFM3Bridge.Free;
    FLFM3Bridge := nil;
  end;

end.