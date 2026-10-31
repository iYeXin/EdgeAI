// ignore_for_file: library_private_types_in_public_api

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

final class EdgeAiConfig extends Struct {
  @Uint32()
  external int structSize;
  external Pointer<Utf8> modelPath;

  @Int32()
  external int backend;
  @Int32()
  external int nGpuLayers;
  @Int32()
  external int nCtx;
  @Int32()
  external int nBatch;
  @Int32()
  external int nUbatch;
  @Int32()
  external int nThreads;
  @Int32()
  external int nThreadsBatch;
  @Int32()
  external int flashAttn;
  @Int32()
  external int useMmap;
  @Int32()
  external int useMlock;
  @Int32()
  external int allowCpuFallback;
  @Int32()
  external int strictMemory;
  @Int32()
  external int kvTypeK;
  @Int32()
  external int kvTypeV;

  @Uint64()
  external int memoryBudgetBytes;
  @Uint64()
  external int memoryReserveBytes;
  @Int32()
  external int minCtx;
  @Int32()
  external int maxCtx;
}

final class EdgeAiModelInfo extends Struct {
  @Uint32()
  external int structSize;

  @Int32()
  external int nCtx;
  @Int32()
  external int nCtxTrain;
  @Int32()
  external int nBatch;
  @Int32()
  external int nUbatch;
  @Int32()
  external int nThreads;
  @Int32()
  external int nLayer;
  @Int32()
  external int nHead;
  @Int32()
  external int nHeadKv;
  @Int32()
  external int nEmbd;
  @Int32()
  external int nVocab;
  @Int32()
  external int nGpuLayers;
  @Int32()
  external int isGpu;
  @Int32()
  external int recommendedCtx;

  @Uint64()
  external int nParams;
  @Uint64()
  external int modelBytes;
  @Uint64()
  external int kvBytesPerToken;
  @Uint64()
  external int kvBytes;
  @Uint64()
  external int computeMarginBytes;
  @Uint64()
  external int totalRam;
  @Uint64()
  external int availRam;
  @Uint64()
  external int rssBytes;
  @Uint64()
  external int peakRssBytes;
  @Uint64()
  external int budgetBytes;
  @Uint64()
  external int reserveBytes;

  @Array(256)
  external Array<Uint8> desc;
  @Array(256)
  external Array<Uint8> backend;
  @Array(64)
  external Array<Uint8> arch;
}

final class EdgeAiChatMessage extends Struct {
  external Pointer<Utf8> role;
  external Pointer<Utf8> content;
}

final class EdgeAiChatMessageV3 extends Struct {
  external Pointer<Utf8> role;
  external Pointer<Utf8> content;
  external Pointer<Utf8> imagePath;
}

final class EdgeAiChatMessageV4 extends Struct {
  external Pointer<Utf8> role;
  external Pointer<Utf8> content;
  external Pointer<Pointer<Utf8>> imagePaths;
  @Int32()
  external int nImagePaths;
  @Int32()
  external int reserved;
}

final class EdgeAiChatPlan extends Struct {
  @Uint32()
  external int structSize;
  @Int32()
  external int promptTokens;
  @Int32()
  external int maxOutputTokens;
  @Int32()
  external int nCtx;
  @Int32()
  external int droppedMessages;
  @Int32()
  external int totalMessages;
  @Int32()
  external int fits;
  @Int32()
  external int promptBytes;
}

final class EdgeAiGenParams extends Struct {
  @Uint32()
  external int structSize;

  @Int32()
  external int maxTokens;
  @Int32()
  external int topK;
  @Int32()
  external int repeatLastN;
  @Int32()
  external int ignoreEos;

  @Uint32()
  external int seed;

  @Float()
  external double temperature;
  @Float()
  external double topP;
  @Float()
  external double minP;
  @Float()
  external double repeatPenalty;
  @Float()
  external double frequencyPenalty;
  @Float()
  external double presencePenalty;

  external Pointer<Pointer<Utf8>> stopSequences;
  @Int32()
  external int nStopSequences;
}

final class EdgeAiStats extends Struct {
  @Uint32()
  external int structSize;
  @Int32()
  external int promptTokens;
  @Int32()
  external int generatedTokens;
  @Int32()
  external int stopReason;

  @Double()
  external double prefillMs;
  @Double()
  external double decodeMs;
  @Double()
  external double loadMs;
  @Double()
  external double tokensPerSecond;
}

typedef _CreateExNative = Int32 Function(
  Pointer<EdgeAiConfig>,
  Pointer<Pointer<Void>>,
  Pointer<Uint8>,
  Int32,
);
typedef _CreateExDart = int Function(
  Pointer<EdgeAiConfig>,
  Pointer<Pointer<Void>>,
  Pointer<Uint8>,
  int,
);

typedef _HandleNative = Int32 Function(Pointer<Void>);
typedef _HandleDart = int Function(Pointer<Void>);

typedef _InfoNative = Int32 Function(Pointer<Void>, Pointer<EdgeAiModelInfo>);
typedef _InfoDart = int Function(Pointer<Void>, Pointer<EdgeAiModelInfo>);

typedef _PrepareNative = Int32 Function(
  Pointer<Void>,
  Pointer<EdgeAiChatMessage>,
  Int32,
  Int32,
  Int32,
  Pointer<Uint8>,
  Int32,
  Pointer<EdgeAiChatPlan>,
);
typedef _PrepareDart = int Function(
  Pointer<Void>,
  Pointer<EdgeAiChatMessage>,
  int,
  int,
  int,
  Pointer<Uint8>,
  int,
  Pointer<EdgeAiChatPlan>,
);

typedef _StartNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<EdgeAiGenParams>,
  Pointer<Uint8>,
  Int32,
);
typedef _StartDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<EdgeAiGenParams>,
  Pointer<Uint8>,
  int,
);

typedef _NextNative = Int32 Function(
  Pointer<Void>,
  Pointer<Uint8>,
  Int32,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Uint8>,
  Int32,
);
typedef _NextDart = int Function(
  Pointer<Void>,
  Pointer<Uint8>,
  int,
  Pointer<Int32>,
  Pointer<Int32>,
  Pointer<Uint8>,
  int,
);

typedef _StatsNative = Int32 Function(Pointer<Void>, Pointer<EdgeAiStats>);
typedef _StatsDart = int Function(Pointer<Void>, Pointer<EdgeAiStats>);

typedef _LoadMmprojNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Uint8>,
  Int32,
);
typedef _LoadMmprojDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Uint8>,
  int,
);

typedef _HasVisionNative = Int32 Function(Pointer<Void>, Pointer<Int32>);
typedef _HasVisionDart = int Function(Pointer<Void>, Pointer<Int32>);

typedef _PrepareV3Native = Int32 Function(
  Pointer<Void>,
  Pointer<EdgeAiChatMessageV3>,
  Int32,
  Int32,
  Int32,
  Pointer<Uint8>,
  Int32,
  Pointer<EdgeAiChatPlan>,
);
typedef _PrepareV3Dart = int Function(
  Pointer<Void>,
  Pointer<EdgeAiChatMessageV3>,
  int,
  int,
  int,
  Pointer<Uint8>,
  int,
  Pointer<EdgeAiChatPlan>,
);

typedef _StartChatV3Native = Int32 Function(
  Pointer<Void>,
  Pointer<EdgeAiChatMessageV3>,
  Int32,
  Pointer<EdgeAiGenParams>,
  Pointer<Uint8>,
  Int32,
);
typedef _StartChatV3Dart = int Function(
  Pointer<Void>,
  Pointer<EdgeAiChatMessageV3>,
  int,
  Pointer<EdgeAiGenParams>,
  Pointer<Uint8>,
  int,
);

typedef _PrepareV4Native = Int32 Function(
  Pointer<Void>,
  Pointer<EdgeAiChatMessageV4>,
  Int32,
  Int32,
  Int32,
  Pointer<Uint8>,
  Int32,
  Pointer<EdgeAiChatPlan>,
);
typedef _PrepareV4Dart = int Function(
  Pointer<Void>,
  Pointer<EdgeAiChatMessageV4>,
  int,
  int,
  int,
  Pointer<Uint8>,
  int,
  Pointer<EdgeAiChatPlan>,
);

typedef _StartChatV4Native = Int32 Function(
  Pointer<Void>,
  Pointer<EdgeAiChatMessageV4>,
  Int32,
  Pointer<EdgeAiGenParams>,
  Pointer<Uint8>,
  Int32,
);
typedef _StartChatV4Dart = int Function(
  Pointer<Void>,
  Pointer<EdgeAiChatMessageV4>,
  int,
  Pointer<EdgeAiGenParams>,
  Pointer<Uint8>,
  int,
);

typedef _StateSizeNative = Int32 Function(Pointer<Void>, Pointer<Uint64>);
typedef _StateSizeDart = int Function(Pointer<Void>, Pointer<Uint64>);
typedef _StatePathNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Uint8>,
  Int32,
);
typedef _StatePathDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Uint8>,
  int,
);

class EdgeAiBindings {
  EdgeAiBindings._(DynamicLibrary lib)
    : createEx = lib.lookupFunction<_CreateExNative, _CreateExDart>(
        'edge_ai_create_ex',
      ),
      destroy = lib.lookupFunction<_HandleNative, _HandleDart>(
        'edge_ai_destroy',
      ),
      unload = lib.lookupFunction<_HandleNative, _HandleDart>('edge_ai_unload'),
      getModelInfo = lib.lookupFunction<_InfoNative, _InfoDart>(
        'edge_ai_get_model_info',
      ),
      prepareChat = lib.lookupFunction<_PrepareNative, _PrepareDart>(
        'edge_ai_prepare_chat',
      ),
      startEx = lib.lookupFunction<_StartNative, _StartDart>(
        'edge_ai_start_ex',
      ),
      nextEx = lib.lookupFunction<_NextNative, _NextDart>('edge_ai_next_ex'),
      cancel = lib.lookupFunction<_HandleNative, _HandleDart>('edge_ai_cancel'),
      getStats = lib.lookupFunction<_StatsNative, _StatsDart>(
        'edge_ai_get_stats',
      ),
      loadMmproj = lib.lookupFunction<_LoadMmprojNative, _LoadMmprojDart>(
        'edge_ai_load_mmproj',
      ),
      hasVision = lib.lookupFunction<_HasVisionNative, _HasVisionDart>(
        'edge_ai_has_vision',
      ),
      prepareChatV3 = lib.lookupFunction<_PrepareV3Native, _PrepareV3Dart>(
        'edge_ai_prepare_chat_v3',
      ),
      startChatV3 = lib.lookupFunction<_StartChatV3Native, _StartChatV3Dart>(
        'edge_ai_start_chat_v3',
      ),
      prepareChatV4 = lib.lookupFunction<_PrepareV4Native, _PrepareV4Dart>(
        'edge_ai_prepare_chat_v4',
      ),
      startChatV4 = lib.lookupFunction<_StartChatV4Native, _StartChatV4Dart>(
        'edge_ai_start_chat_v4',
      ),
      stateSize = lib.lookupFunction<_StateSizeNative, _StateSizeDart>(
        'edge_ai_state_get_size',
      ),
      stateSave = lib.lookupFunction<_StatePathNative, _StatePathDart>(
        'edge_ai_state_save',
      ),
      stateLoad = lib.lookupFunction<_StatePathNative, _StatePathDart>(
        'edge_ai_state_load',
      ),
      stateClear = lib.lookupFunction<_HandleNative, _HandleDart>(
        'edge_ai_state_clear',
      );

  factory EdgeAiBindings.open() =>
      EdgeAiBindings._(DynamicLibrary.open('libedge_ai.so'));

  static const int errCap = 1024;

  final _CreateExDart createEx;
  final _HandleDart destroy;
  final _HandleDart unload;
  final _InfoDart getModelInfo;
  final _PrepareDart prepareChat;
  final _StartDart startEx;
  final _NextDart nextEx;
  final _HandleDart cancel;
  final _StatsDart getStats;
  final _LoadMmprojDart loadMmproj;
  final _HasVisionDart hasVision;
  final _PrepareV3Dart prepareChatV3;
  final _StartChatV3Dart startChatV3;
  final _PrepareV4Dart prepareChatV4;
  final _StartChatV4Dart startChatV4;
  final _StateSizeDart stateSize;
  final _StatePathDart stateSave;
  final _StatePathDart stateLoad;
  final _HandleDart stateClear;

  static String readError(Pointer<Uint8> ptr) {
    if (ptr.address == 0) return '';
    final chunks = <int>[];
    for (var i = 0; i < errCap; i++) {
      final byte = ptr[i];
      if (byte == 0) break;
      chunks.add(byte);
    }
    return utf8.decode(chunks, allowMalformed: true);
  }

  static String readCharArray(Array<Uint8> array, int max) {
    final bytes = <int>[];
    for (var i = 0; i < max; i++) {
      final byte = array[i];
      if (byte == 0) break;
      bytes.add(byte);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}
