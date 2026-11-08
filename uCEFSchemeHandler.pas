unit uCEFSchemeHandler;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, uCEFInterfaces, uCEFTypes, uCEFConstants,
  fpjson, jsonparser,
  uCEFSchemeHandlerFactory, uCEFResourceHandler, uCEFRequest,
  uCEFResponse, uCEFCallback,
  uCEFBrowser, uCEFFrame,
  uCEFMiscFunctions;

type
  TLilithMCPResourceHandler = class(TCefResourceHandlerOwn)
  protected
    FRequest: ICefRequest;
    FURL: string;
    FMethod: string;
    FResponseData: string;
    FResponseMimeType: string;
    FResponseStatus: Integer;
    FReadOffset: Int64;
    function ProcessRequest(const request: ICefRequest; const callback: ICefCallback): Boolean; override;
    procedure GetResponseHeaders(const response: ICefResponse; out responseLength: Int64; out redirectUrl: ustring); override;
    function ReadResponse(const dataOut: Pointer; bytesToRead: Integer; var bytesRead: Integer; const callback: ICefCallback): Boolean; override;
  public
    constructor Create(const browser: ICefBrowser; const frame: ICefFrame; const schemeName: ustring; const request: ICefRequest); override;
    destructor Destroy; override;
  end;

  procedure RegisterLilithMCPSchemes;
  procedure RegisterLilithMCPSchemesLate(const browser: ICefBrowser);

implementation

{ TLilithMCPResourceHandler }

constructor TLilithMCPResourceHandler.Create(const browser: ICefBrowser; const frame: ICefFrame; const schemeName: ustring; const request: ICefRequest);
begin
  inherited Create(browser, frame, schemeName, request);
  FRequest := request;
  if request <> nil then
  begin
    FURL := request.URL;
    FMethod := request.Method;
  end;
  FResponseData := '';
  FResponseMimeType := 'application/json';
  FResponseStatus := 200;
  FReadOffset := 0;
end;

destructor TLilithMCPResourceHandler.Destroy;
begin
  inherited Destroy;
end;

function TLilithMCPResourceHandler.ProcessRequest(const request: ICefRequest; const callback: ICefCallback): Boolean;
var
  jsonResp: TJSONObject;
  logFile: TextFile;
  url: string;
begin
  Result := False;
  url := request.URL;
  
  // Debug log
  AssignFile(logFile, '/tmp/lilith_mcp_scheme_debug.log');
  if FileExists('/tmp/lilith_mcp_scheme_debug.log') then
    Append(logFile)
  else
    Rewrite(logFile);
  WriteLn(logFile, '[Lilith-MCP] ProcessRequest: ', url);
  CloseFile(logFile);

  jsonResp := TJSONObject.Create;
  try
    jsonResp.Strings['jsonrpc'] := '2.0';
    jsonResp.Integers['id'] := 1;
    jsonResp.Add('result', TJSONObject.Create([
      'status', 'ok',
      'message', 'Lilith-MCP scheme handler active',
      'url', FURL,
      'method', FMethod,
      'scheme', Copy(FURL, 1, Pos('://', FURL) - 1)
    ]));
    FResponseData := jsonResp.AsJSON;
    Result := True;
    if callback <> nil then callback.Cont;
  finally
    jsonResp.Free;
  end;
end;

procedure TLilithMCPResourceHandler.GetResponseHeaders(const response: ICefResponse; out responseLength: Int64; out redirectUrl: ustring);
begin
  if response <> nil then
  begin
    response.MimeType := FResponseMimeType;
    response.Status := FResponseStatus;
  end;
  responseLength := Length(FResponseData);
  redirectUrl := '';
  FReadOffset := 0;
end;

function TLilithMCPResourceHandler.ReadResponse(const dataOut: Pointer; bytesToRead: Integer; var bytesRead: Integer; const callback: ICefCallback): Boolean;
var
  avail: Integer;
  src: PByte;
begin
  Result := False;
  bytesRead := 0;
  if (dataOut = nil) or (FReadOffset >= Length(FResponseData)) then
  begin
    Result := False;
    Exit;
  end;
  avail := Length(FResponseData) - FReadOffset;
  if bytesToRead < avail then avail := bytesToRead;
  if avail > 0 then
  begin
    src := @FResponseData[FReadOffset + 1];
    Move(src^, dataOut^, avail);
    FReadOffset := FReadOffset + avail;
    bytesRead := avail;
    Result := True;
  end
  else
    Result := False;
  if callback <> nil then callback.Cont;
end;

procedure RegisterLilithMCPSchemes;
begin
  CefRegisterSchemeHandlerFactory('mcp', '', TLilithMCPResourceHandler);
  CefRegisterSchemeHandlerFactory('aethelgard', '', TLilithMCPResourceHandler);
  CefRegisterSchemeHandlerFactory('agent', '', TLilithMCPResourceHandler);
end;

procedure RegisterLilithMCPSchemesLate(const browser: ICefBrowser);
var
  factory: ICefSchemeHandlerFactory;
  reqContext: ICefRequestContext;
begin
  if (browser = nil) or (browser.Host = nil) or (browser.Host.RequestContext = nil) then Exit;
  reqContext := browser.Host.RequestContext;
  factory := TCefSchemeHandlerFactoryOwn.Create(TLilithMCPResourceHandler);
  reqContext.RegisterSchemeHandlerFactory('mcp', '', factory);
  reqContext.RegisterSchemeHandlerFactory('aethelgard', '', factory);
  reqContext.RegisterSchemeHandlerFactory('agent', '', factory);
end;

end.
