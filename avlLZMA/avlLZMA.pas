unit avlLZMA;

{
  Inno Setup
  Copyright (C) 1997-2006 Jordan Russell
  Portions by Martijn Laan
  For conditions of distribution and use, see LICENSE.TXT.

  Interface to the LZMA compression DLL and the LZMA SDK decompression OBJ

  Source code for the decompression OBJ can found in the LzmaDecode
  subdirectory.
  Source code for the compression DLL can found at:
    http://cvs.jrsoftware.org/view/iscompress/lzma/

  $jrsoftware: issrc/Projects/LZMA.pas,v 1.24 2006/10/06 20:58:28 jr Exp $
}

interface

{$I VERSION.INC}

uses
  Windows, AvL, avlCompress, avlInt64Em;

function LZMAInitCompressFunctions(Module: HMODULE): Boolean;
function LZMAGetLevel(const Value: String; var Level: Integer): Boolean;

const
  clLZMAFast = 1;
  clLZMANormal = 2;
  clLZMAMax = 3;
  clLZMAUltra = 4;

type
  TLZMAInStream = class;
  TLZMAOutStream = class;
  TLZMAProgressInfo = class;
  TLZMAWorkerThread = class;

  TLZMACompressor = class(TCustomCompressor)
  private
    FLZMAHandle: Pointer;
    FInStream: TLZMAInStream;
    FOutStream: TLZMAOutStream;
    FProgressInfo: TLZMAProgressInfo;
    FNextIn, FNextOut: Pointer;
    FAvailIn, FAvailOut: Cardinal;
    FWorkerThread: TLZMAWorkerThread;
    FEncodeFinished: BOOL;
    FEncodeResult: HRESULT;
    FLastProgressTick: DWORD;
    FBuffer: array[0..65535] of Byte;
    function FillBuffer(const FillBuf2: Boolean; Buf1: Pointer; Size1: Cardinal;
      var Buf2: Pointer; var Size2: Cardinal; var ProcessedSize: Cardinal): HRESULT;
    procedure FlushBuffer;
    function ProgressMade(const TotalBytesProcessed: Integer64): HRESULT;
    function Read(var Data; Size: Cardinal; var ProcessedSize: Cardinal): HRESULT;
    function Write(const Data; Size: Cardinal; var ProcessedSize: Cardinal): HRESULT;
    procedure WorkerThreadProc;
  public
    constructor Create(AWriteProc: TCompressorWriteProc;
      AProgressProc: TCompressorProgressProc; CompressionLevel: Integer); override;
    destructor Destroy; override;
    procedure Compress(const Buffer; Count: Longint); override;
    procedure Finish; override;
  end;

  { Internally-used record }
  TLZMAInternalDecoderState = record
    { NOTE: None of these fields are ever accessed directly by this unit.
      They are exposed purely for debugging purposes. }
    opaque_Properties: record
      lc: Integer;
      lp: Integer;
      pb: Integer;
      DictionarySize: LongWord;
    end;
    opaque_Probs: Pointer;
    opaque_Buffer: Pointer;
    opaque_BufferLim: Pointer;
    opaque_Dictionary: Pointer;
    opaque_Range: LongWord;
    opaque_Code: LongWord;
    opaque_DictionaryPos: LongWord;
    opaque_GlobalPos: LongWord;
    opaque_DistanceLimit: LongWord;
    opaque_Reps: array[0..3] of LongWord;
    opaque_State: Integer;
    opaque_RemainLen: Integer;
    opaque_TempDictionary: array[0..3] of Byte;
  end;

  TLZMADecompressor = class(TCustomDecompressor)
  private
    FReachedEnd: Boolean;
    FHeaderProcessed: Boolean;
    FDecoderState: TLZMAInternalDecoderState;
    FHeapBase: Pointer;
    FHeapSize: Cardinal;
    FBuffer: array[0..65535] of Byte;
    procedure DestroyHeap;
    procedure DoRead(var Buffer: Pointer; var BufferSize: Cardinal);
    procedure ProcessHeader;
  public
    destructor Destroy; override;
    procedure DecompressInto(var Buffer; Count: Longint); override;
    procedure Reset; override;
  end;

  { Internally-used interfaces }
  I7zUnknown = class
  public
    function QueryInterface(const iid; var obj): HRESULT; virtual; stdcall;
    function AddRef: Longint; virtual; stdcall;
    function Release: Longint; virtual; stdcall;
  end;
  I7zSequentialInStream = class(I7zUnknown)
  public
    function Read(var data; size: LongWord; var processedSize: LongWord): HRESULT; virtual; stdcall; abstract;
  end;
  I7zSequentialOutStream = class(I7zUnknown)
  public
    function Write(const data; size: LongWord; var processedSize: LongWord): HRESULT; virtual; stdcall; abstract;
  end;
  I7zCompressProgressInfo = class(I7zUnknown)
  public
    function SetRatioInfo(const inSize, outSize: Integer64): HRESULT; virtual; stdcall; abstract;
  end;

  { Internally-used classes }
  TLZMAReadProc = function(var Data; Size: Cardinal; var ProcessedSize: Cardinal): HRESULT of object;
  TLZMAInStream = class(I7zSequentialInStream)
  private
    FReadProc: TLZMAReadProc;
  public
    function Read(var data; size: LongWord; var processedSize: LongWord): HRESULT; override;
  end;
  TLZMAWriteProc = function(const Data; Size: Cardinal; var ProcessedSize: Cardinal): HRESULT of object;
  TLZMAOutStream = class(I7zSequentialOutStream)
  private
    FWriteProc: TLZMAWriteProc;
  public
    function Write(const data; size: LongWord; var processedSize: LongWord): HRESULT; override;
  end;
  TLZMAProgressProc = function(const TotalBytesProcessed: Integer64): HRESULT of object;
  TLZMAProgressInfo = class(I7zCompressProgressInfo)
  private
    FProgressProc: TLZMAProgressProc;
  public
    function SetRatioInfo(const inSize, outSize: Integer64): HRESULT; override;
  end;
  TLZMAWorkerThreadProc = procedure of object;
  TLZMAWorkerThread = class
  private
    FWorkerThreadProc: TLZMAWorkerThreadProc;
    FProgressProc: TCompressorProgressProc;
    FWorkerResumeEvent, FWorkerIsPausedEvent: THandle;
    FThread: THandle;
    FTerminateThread: BOOL;
    FCallProgressProc: BOOL;
    FTotalBytes, FLastTotalBytes: Integer64;
  public
    constructor Create(AWorkerThreadProc: TLZMAWorkerThreadProc;
      AProgressProc: TCompressorProgressProc);
    destructor Destroy; override;
    procedure ReturnToMain;
    procedure SwitchToWorker;
  end;

implementation

{$IFNDEF Delphi3orHigher}
{ Must include Ole2 in the 'uses' clause on D2, and after Windows, because
  it redefines E_* constants in Windows that are incorrect. E_OUTOFMEMORY,
  for example, is defined as $80000002 in Windows, instead of $8007000E. }
uses
  Ole2;
{$ENDIF}

const
  SLZMADataError = 'lzma: Compressed data is corrupted (%d)';

type
  TOutFunc = function(const P; Count: Integer): Integer; stdcall;
  TInFunc = function(var P; var Count: Integer): Integer; stdcall;

var
  LZMA_Init: function(var Handle: Pointer): HRESULT; stdcall;
  LZMA_SetProps: function(handle: Pointer; algorithm, dicSize, numFastBytes: Cardinal;
    matchFinder: PWideChar): HRESULT; stdcall;
  LZMA_Encode: function(handle: Pointer; in_stream: I7zSequentialInStream;
    out_stream: I7zSequentialOutStream; progress: I7zCompressProgressInfo): HRESULT; stdcall;
  LZMA_End: function(handle: Pointer): HRESULT; stdcall;

procedure OutOfMemoryError;
begin
  raise EOutOfMemory.Create('Out of memory');
end;

function LZMAInitCompressFunctions(Module: HMODULE): Boolean;
begin
  LZMA_Init := GetProcAddress(Module, 'LZMA_Init');
  LZMA_SetProps := GetProcAddress(Module, 'LZMA_SetProps');
  LZMA_Encode := GetProcAddress(Module, 'LZMA_Encode2');
  LZMA_End := GetProcAddress(Module, 'LZMA_End');
  Result := Assigned(LZMA_Init) and Assigned(LZMA_SetProps) and
    Assigned(LZMA_Encode) and Assigned(LZMA_End);
  if not Result then begin
    LZMA_Init := nil;
    LZMA_SetProps := nil;
    LZMA_Encode := nil;
    LZMA_End := nil;
  end;
end;

procedure LZMAInternalError(const Msg: String);
begin
  raise ECompressInternalError.Create('lzma: ' + Msg);
end;

procedure LZMADataError(const Id: Integer);
begin
  raise ECompressDataError.CreateFmt(SLZMADataError, [Id]);
end;

function LZMAGetLevel(const Value: String; var Level: Integer): Boolean;
begin
  Result := True;
  if CompareText(Value, 'fast') = 0 then
    Level := clLZMAFast
  else if CompareText(Value, 'normal') = 0 then
    Level := clLZMANormal
  else if CompareText(Value, 'max') = 0 then
    Level := clLZMAMax
  else if CompareText(Value, 'ultra') = 0 then
    Level := clLZMAUltra
  else
    Result := False;
end;

{ TLZMAWorkerThread }

constructor TLZMAWorkerThread.Create(AWorkerThreadProc: TLZMAWorkerThreadProc;
  AProgressProc: TCompressorProgressProc);
begin
  inherited Create;
  FWorkerThreadProc := AWorkerThreadProc;
  FProgressProc := AProgressProc;
  FWorkerResumeEvent := CreateEvent(nil, False, False, nil);
  FWorkerIsPausedEvent := CreateEvent(nil, False, False, nil);
  if (FWorkerResumeEvent = 0) or (FWorkerIsPausedEvent = 0) then
    LZMAInternalError('CreateEvent failed');
end;

destructor TLZMAWorkerThread.Destroy;
begin
  if FThread <> 0 then begin
    { Resume the worker thread and wait for it to terminate }
    FTerminateThread := True;
    SetEvent(FWorkerResumeEvent);
    WaitForSingleObject(FThread, INFINITE);
    CloseHandle(FThread);
    FThread := 0;
  end;
  if FWorkerIsPausedEvent <> 0 then
    CloseHandle(FWorkerIsPausedEvent);
  if FWorkerResumeEvent <> 0 then
    CloseHandle(FWorkerResumeEvent);
  inherited;
end;

function WorkerThreadFunc(Parameter: Pointer): Integer;
begin
  try
    TLZMAWorkerThread(Parameter).FWorkerThreadProc;
  except
  end;
  Result := 0;
end;

procedure TLZMAWorkerThread.SwitchToWorker;
{ Called from main thread }
var
  ThreadID: DWORD;
  H: array[0..1] of THandle;
  Bytes: Integer64;
begin
  repeat
    FCallProgressProc := False;

    { Create worker thread, or resume existing one }
    if FThread = 0 then begin
      ResetEvent(FWorkerResumeEvent);
      ResetEvent(FWorkerIsPausedEvent);
      FThread := BeginThread(nil, 0, WorkerThreadFunc, Self, 0, ThreadID);
      if FThread = 0 then
        LZMAInternalError('BeginThread failed');
    end
    else
      SetEvent(FWorkerResumeEvent);

    { Wait until worker thread is paused }
    H[0] := FWorkerIsPausedEvent;
    H[1] := FThread;
    case WaitForMultipleObjects(2, @H, False, INFINITE) of
      WAIT_OBJECT_0 + 0: ;
      WAIT_OBJECT_0 + 1:
        begin
          { Uh oh - the worker thread has terminated?!
            We don't try to re-create the thread because a) it should never get
            here in the first place, and b) it might just die again (and then
            we'd be in an infinite loop). }
          LZMAInternalError('Worker thread terminated unexpectedly');
        end;
    else
      LZMAInternalError('WaitForMultipleObjects failed');
    end;

    { If control was returned here because ProgressProc needed to be called,
      call it then loop back }
    if FCallProgressProc and Assigned(FProgressProc) then begin
      Bytes := FTotalBytes;
      Dec6464(Bytes, FLastTotalBytes);
      FLastTotalBytes := FTotalBytes;
      FProgressProc(Bytes.Lo);
    end;
  until not FCallProgressProc;
end;

procedure TLZMAWorkerThread.ReturnToMain;
{ Called from worker thread }
begin
  SetEvent(FWorkerIsPausedEvent);
  if WaitForSingleObject(FWorkerResumeEvent, INFINITE) <> WAIT_OBJECT_0 then
    FTerminateThread := True;  { ...should never get here }
end;

{ TLZMACompressor }

constructor TLZMACompressor.Create(AWriteProc: TCompressorWriteProc;
  AProgressProc: TCompressorProgressProc; CompressionLevel: Integer);
const
  algorithm: array [clLZMAFast..clLZMAUltra] of Cardinal = (0, 1, 1, 1);
  dicSize: array [clLZMAFast..clLZMAUltra] of Cardinal = (32 shl 10, 2 shl 20, 8 shl 20, 32 shl 20);
  numFastBytes: array [clLZMAFast..clLZMAUltra] of Cardinal = (32, 32, 64, 64);
  matchFinder: array [clLZMAFast..clLZMAUltra] of PWideChar = ('HC4', 'BT4', 'BT4', 'BT4');
var
  Res: HRESULT;
begin
  inherited;
  FNextOut := @FBuffer;
  FAvailOut := SizeOf(FBuffer);
  FInStream := TLZMAInStream.Create;
  FInStream.FReadProc := Read;
  FOutStream := TLZMAOutStream.Create;
  FOutStream.FWriteProc := Write;
  FProgressInfo := TLZMAProgressInfo.Create;
  FProgressInfo.FProgressProc := ProgressMade;
  FWorkerThread := TLZMAWorkerThread.Create(WorkerThreadProc, AProgressProc);
  Res := LZMA_Init(FLZMAHandle);
  if Res = E_OUTOFMEMORY then
    OutOfMemoryError;
  if Res <> S_OK then
    LZMAInternalError(Format('LZMA_Init failed with code 0x%.8x', [Res]));
  if (CompressionLevel < Low(algorithm)) or (CompressionLevel > High(algorithm)) then
    LZMAInternalError('TLZMACompressor.Create got invalid CompressionLevel ' + IntToStr(CompressionLevel));
  if LZMA_SetProps(FLZMAHandle, algorithm[CompressionLevel], dicSize[CompressionLevel],
     numFastBytes[CompressionLevel], matchFinder[CompressionLevel]) <> S_OK then
    LZMAInternalError('LZMA_SetProps failed');
end;

destructor TLZMACompressor.Destroy;
begin
  FWorkerThread.Free;
  if Assigned(FLZMAHandle) then
    LZMA_End(FLZMAHandle);
  FProgressInfo.Free;
  FOutStream.Free;
  FInStream.Free;
  inherited;
end;

procedure TLZMACompressor.FlushBuffer;
begin
  if FAvailOut < SizeOf(FBuffer) then begin
    WriteProc(FBuffer, SizeOf(FBuffer) - FAvailOut);
    FNextOut := @FBuffer;
    FAvailOut := SizeOf(FBuffer);
  end;
end;

procedure TLZMACompressor.Compress(const Buffer; Count: Longint);
begin
  FNextIn := @Buffer;
  FAvailIn := Count;
  while FAvailIn > 0 do begin
    FWorkerThread.SwitchToWorker;
    if FEncodeFinished then begin
      if FEncodeResult = E_OUTOFMEMORY then
        OutOfMemoryError;
      LZMAInternalError(Format('Compress: LZMA_Encode failed with code 0x%.8x',
        [FEncodeResult]));
    end;
    if FAvailOut = 0 then
      FlushBuffer;
  end;
end;

procedure TLZMACompressor.Finish;
begin
  FNextIn := nil;
  FAvailIn := 0;
  repeat
    FWorkerThread.SwitchToWorker;
    FlushBuffer;
  until FEncodeFinished;
  case FEncodeResult of
    S_OK: ;
    E_OUTOFMEMORY: OutOfMemoryError;
  else
    LZMAInternalError(Format('Finish: LZMA_Encode failed with code 0x%.8x',
      [FEncodeResult]));
  end;
end;

procedure TLZMACompressor.WorkerThreadProc;
{ Worker thread main procedure }
begin
  FEncodeResult := LZMA_Encode(FLZMAHandle, FInStream, FOutStream, FProgressInfo);
  FEncodeFinished := True;
  if not FWorkerThread.FTerminateThread then
    FWorkerThread.ReturnToMain;
end;

function TLZMACompressor.FillBuffer(const FillBuf2: Boolean;
  Buf1: Pointer; Size1: Cardinal; var Buf2: Pointer; var Size2: Cardinal;
  var ProcessedSize: Cardinal): HRESULT;
{ Called from worker thread }
var
  Bytes: Cardinal;
begin
  if Assigned(@ProcessedSize) then
    ProcessedSize := 0;
  if FWorkerThread.FTerminateThread then begin
    { In case this method gets called again after a previous call already
      returned E_ABORT, return E_ABORT again. (This is known to happen with
      the LZMA decoder; not sure about the encoder.) }
    Result := E_ABORT;
    Exit;
  end;
  while Size1 > 0 do begin
    if Size2 = 0 then begin
      { Return control to the main thread so that Buf2 may be refilled }
      FWorkerThread.ReturnToMain;
      if FWorkerThread.FTerminateThread then begin
        Result := E_ABORT;
        Exit;
      end;
      if Size2 = 0 then
        Break;
    end;

    if Size1 <= Size2 then
      Bytes := Size1
    else
      Bytes := Size2;
    if FillBuf2 then
      Move(Buf1^, Buf2^, Bytes)
    else
      Move(Buf2^, Buf1^, Bytes);

    Inc(Cardinal(Buf1), Bytes);
    Dec(Size1, Bytes);
    Inc(Cardinal(Buf2), Bytes);
    Dec(Size2, Bytes);
    if Assigned(@ProcessedSize) then
      Inc(ProcessedSize, Bytes);
  end;
  Result := S_OK;
end;

function TLZMACompressor.Read(var Data; Size: Cardinal;
  var ProcessedSize: Cardinal): HRESULT;
{ Called from worker thread }
begin
  Result := FillBuffer(False, @Data, Size, FNextIn, FAvailIn, ProcessedSize);
end;

function TLZMACompressor.Write(const Data; Size: Cardinal;
  var ProcessedSize: Cardinal): HRESULT;
{ Called from worker thread }
begin
  Result := FillBuffer(True, @Data, Size, FNextOut, FAvailOut, ProcessedSize);
end;

function TLZMACompressor.ProgressMade(const TotalBytesProcessed: Integer64): HRESULT;
{ Called from worker thread }
var
  T: DWORD;
begin
  FWorkerThread.FTotalBytes := TotalBytesProcessed;
  if FWorkerThread.FTerminateThread then begin
    { In case this method gets called after a previous call already returned
      E_ABORT, return E_ABORT again. May not be necessary. }
    Result := E_ABORT;
    Exit;
  end;
  T := GetTickCount;
  if T - FLastProgressTick >= 100 then begin
    FLastProgressTick := T;
    FWorkerThread.FCallProgressProc := True;
    FWorkerThread.ReturnToMain;
    if FWorkerThread.FTerminateThread then begin
      Result := E_ABORT;
      Exit;
    end;
  end;
  Result := S_OK;
end;

{ TLZMADecompressor }

{$L LzmaDecode\LzmaDecodeInno.obj}

type
  TLzmaInCallback = record
    Read: function(obj: Pointer; var buffer: Pointer; var bufferSize: Cardinal): Integer;
  end;

const
  LZMA_RESULT_OK = 0;
  LZMA_RESULT_DATA_ERROR = 1;

  LZMA_PROPERTIES_SIZE = 5;

function LzmaMyDecodeProperties(var vs: TLZMAInternalDecoderState;
  vsSize: Integer; const propsData; propsDataSize: Integer;
  var outPropsSize: LongWord; var outDictionarySize: LongWord): Integer; external;
procedure LzmaMyDecoderInit(var vs: TLZMAInternalDecoderState;
  probsPtr: Pointer; dictionaryPtr: Pointer); external;
function LzmaDecode(var vs: TLZMAInternalDecoderState;
  var inCallback: TLzmaInCallback; var outStream; outSize: Cardinal;
  var outSizeProcessed: Cardinal): Integer; external;

type
  TLZMADecompressorCallbackData = record
    Callback: TLzmaInCallback;
    Instance: TLZMADecompressor;
  end;

function ReadFunc(obj: Pointer; var buffer: Pointer; var bufferSize: Cardinal): Integer;
begin
  TLZMADecompressorCallbackData(obj^).Instance.DoRead(buffer, bufferSize);
  { Don't bother returning any sort of failure code, because if DoRead failed,
    it would've raised an exception }
  Result := LZMA_RESULT_OK;
end;

destructor TLZMADecompressor.Destroy;
begin
  DestroyHeap;
  inherited;
end;

procedure TLZMADecompressor.DestroyHeap;
begin
  FHeapSize := 0;
  if Assigned(FHeapBase) then begin
    VirtualFree(FHeapBase, 0, MEM_RELEASE);
    FHeapBase := nil;
  end;
end;

procedure TLZMADecompressor.DoRead(var Buffer: Pointer; var BufferSize: Cardinal);
begin
  Buffer := @FBuffer;
  BufferSize := 0;
  if not FReachedEnd then begin
    BufferSize := ReadProc(FBuffer, SizeOf(FBuffer));
    if BufferSize = 0 then
      FReachedEnd := True;  { not really necessary, but for consistency }
  end;
end;

procedure TLZMADecompressor.ProcessHeader;
var
  Props: array[0..LZMA_PROPERTIES_SIZE-1] of Byte;
  ProbsSize, DictionarySize: LongWord;
  NewHeapSize: Cardinal;
begin
  { Read header fields }
  if ReadProc(Props, SizeOf(Props)) <> SizeOf(Props) then
    LZMADataError(1);

  { Initialize the LZMA decoder state structure, and calculate the size of
    the Probs and Dictionary }
  FillChar(FDecoderState, SizeOf(FDecoderState), 0);
  if LzmaMyDecodeProperties(FDecoderState, SizeOf(FDecoderState), Props,
     SizeOf(Props), ProbsSize, DictionarySize) <> LZMA_RESULT_OK then
    LZMADataError(3);
  if DictionarySize > LongWord(32 shl 20) then
    { sanity check: we only use dictionary sizes <= 32 MB }
    LZMADataError(7);

  { Allocate memory for the Probs and Dictionary, and pass the pointers over }
  NewHeapSize := ProbsSize + DictionarySize;
  if FHeapSize <> NewHeapSize then begin
    DestroyHeap;
    FHeapBase := VirtualAlloc(nil, NewHeapSize, MEM_COMMIT, PAGE_READWRITE);
    if FHeapBase = nil then
      OutOfMemoryError;
    FHeapSize := NewHeapSize;
  end;
  LzmaMyDecoderInit(FDecoderState, FHeapBase, Pointer(Cardinal(FHeapBase) + ProbsSize));

  FHeaderProcessed := True;
end;

procedure TLZMADecompressor.DecompressInto(var Buffer; Count: Longint);
var
  CallbackData: TLZMADecompressorCallbackData;
  Code: Integer;
  OutProcessed: Cardinal;
begin
  if not FHeaderProcessed then
    ProcessHeader;
  CallbackData.Callback.Read := ReadFunc;
  CallbackData.Instance := Self;
  Code := LzmaDecode(FDecoderState, CallbackData.Callback, Buffer, Count,
    OutProcessed);
  case Code of
    LZMA_RESULT_OK: ;
    LZMA_RESULT_DATA_ERROR: LZMADataError(5);
  else
    LZMAInternalError(Format('LzmaDecode failed (%d)', [Code]));
  end;
  if OutProcessed <> Cardinal(Count) then
    LZMADataError(6);
end;

procedure TLZMADecompressor.Reset;
begin
  FHeaderProcessed := False;
  FReachedEnd := False;
end;

{ I7zUnknown }

function I7zUnknown.QueryInterface(const iid; var obj): HRESULT;
begin
  Pointer(obj) := nil;
  Result := E_NOINTERFACE;
end;

function I7zUnknown.AddRef: Longint;
begin
  Result := 1;
end;

function I7zUnknown.Release: Longint;
begin
  Result := 1;
end;

{ TLZMAInStream }

function TLZMAInStream.Read(var data; size: LongWord;
  var processedSize: LongWord): HRESULT;
begin
  Result := FReadProc(data, size, processedSize);
end;

{ TLZMAOutStream }

function TLZMAOutStream.Write(const data; size: LongWord;
  var processedSize: LongWord): HRESULT;
begin
  Result := FWriteProc(data, size, processedSize);
end;

{ TLZMAProgressInfo }

function TLZMAProgressInfo.SetRatioInfo(const inSize, outSize: Integer64): HRESULT;
begin
  Result := FProgressProc(inSize);
end;

end.
