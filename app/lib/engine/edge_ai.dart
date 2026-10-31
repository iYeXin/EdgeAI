import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

import 'edge_ai_bindings.dart';

enum ComputeBackend { auto, vulkan, cpu }

extension ComputeBackendValue on ComputeBackend {
  int get value => switch (this) {
    ComputeBackend.auto => 0,
    ComputeBackend.vulkan => 1,
    ComputeBackend.cpu => 2,
  };

  String get label => switch (this) {
    ComputeBackend.auto => 'Auto',
    ComputeBackend.vulkan => 'Vulkan GPU',
    ComputeBackend.cpu => 'CPU',
  };
}

enum FlashAttention { auto, on, off }

extension FlashAttentionValue on FlashAttention {
  int get value => switch (this) {
    FlashAttention.auto => -1,
    FlashAttention.on => 1,
    FlashAttention.off => 0,
  };
}

enum StopReason { none, eos, maxTokens, stopSequence, cancelled, error }

StopReason _stopReason(int value) => switch (value) {
  1 => StopReason.eos,
  2 => StopReason.maxTokens,
  3 => StopReason.stopSequence,
  4 => StopReason.cancelled,
  5 => StopReason.error,
  _ => StopReason.none,
};

class EngineConfig {
  const EngineConfig({
    required this.modelPath,
    this.mmprojPath,
    this.backend = ComputeBackend.auto,
    this.threads = 4,
    this.batchSize = 512,
    this.ubatchSize = 512,
    this.contextSize = 0,
    this.minContext = 512,
    this.maxContext = 8192,
    this.memoryBudgetBytes,
    this.memoryReserveBytes = 0,
    this.allowCpuFallback = true,
    this.strictMemory = false,
    this.useMmap = true,
    this.useMlock = false,
    this.flashAttention = FlashAttention.auto,
  });

  final String modelPath;
  final String? mmprojPath;
  final ComputeBackend backend;
  final int threads;
  final int batchSize;
  final int ubatchSize;

  /// 0 means auto: derive from the memory budget and model geometry.
  final int contextSize;
  final int minContext;
  final int maxContext;

  /// null / 0 means use available system memory.
  final int? memoryBudgetBytes;

  /// Memory kept free for the app/runtime. 0 uses a conservative default.
  final int memoryReserveBytes;
  final bool allowCpuFallback;
  final bool strictMemory;
  final bool useMmap;
  final bool useMlock;
  final FlashAttention flashAttention;

  Map<String, Object?> toMap() => {
    'modelPath': modelPath,
    'mmprojPath': mmprojPath,
    'backend': backend.value,
    'threads': threads,
    'batchSize': batchSize,
    'ubatchSize': ubatchSize,
    'contextSize': contextSize,
    'minContext': minContext,
    'maxContext': maxContext,
    'memoryBudgetBytes': memoryBudgetBytes ?? 0,
    'memoryReserveBytes': memoryReserveBytes,
    'allowCpuFallback': allowCpuFallback,
    'strictMemory': strictMemory,
    'useMmap': useMmap,
    'useMlock': useMlock,
    'flashAttention': flashAttention.value,
  };
}

class DeviceMemory {
  const DeviceMemory({
    required this.totalBytes,
    required this.availBytes,
    required this.thresholdBytes,
    required this.lowMemory,
    required this.maxHeapBytes,
  });

  final int totalBytes;
  final int availBytes;
  final int thresholdBytes;
  final bool lowMemory;
  final int maxHeapBytes;

  static Future<DeviceMemory> read() async {
    try {
      final result = await const MethodChannel('edge_ai/paths')
          .invokeMapMethod<String, dynamic>('getMemoryInfo');
      return DeviceMemory(
        totalBytes: (result?['totalBytes'] as num?)?.toInt() ?? 0,
        availBytes: (result?['availBytes'] as num?)?.toInt() ?? 0,
        thresholdBytes: (result?['thresholdBytes'] as num?)?.toInt() ?? 0,
        lowMemory: result?['lowMemory'] as bool? ?? false,
        maxHeapBytes: (result?['maxHeapBytes'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return const DeviceMemory(
        totalBytes: 0,
        availBytes: 0,
        thresholdBytes: 0,
        lowMemory: false,
        maxHeapBytes: 0,
      );
    }
  }
}

class EngineInfo {
  const EngineInfo({
    required this.nCtx,
    required this.nCtxTrain,
    required this.nBatch,
    required this.nUbatch,
    required this.nThreads,
    required this.nLayer,
    required this.nHead,
    required this.nHeadKv,
    required this.nEmbd,
    required this.nVocab,
    required this.nGpuLayers,
    required this.isGpu,
    required this.recommendedCtx,
    required this.nParams,
    required this.modelBytes,
    required this.kvBytesPerToken,
    required this.kvBytes,
    required this.totalRamBytes,
    required this.availRamBytes,
    required this.rssBytes,
    required this.peakRssBytes,
    required this.budgetBytes,
    required this.reserveBytes,
    required this.desc,
    required this.backend,
    required this.arch,
    this.hasVision = false,
  });

  final int nCtx;
  final int nCtxTrain;
  final int nBatch;
  final int nUbatch;
  final int nThreads;
  final int nLayer;
  final int nHead;
  final int nHeadKv;
  final int nEmbd;
  final int nVocab;
  final int nGpuLayers;
  final bool isGpu;
  final int recommendedCtx;
  final int nParams;
  final int modelBytes;
  final int kvBytesPerToken;
  final int kvBytes;
  final int totalRamBytes;
  final int availRamBytes;
  final int rssBytes;
  final int peakRssBytes;
  final int budgetBytes;
  final int reserveBytes;
  final String desc;
  final String backend;
  final String arch;
  final bool hasVision;

  factory EngineInfo.fromMap(Map<dynamic, dynamic> map) => EngineInfo(
    nCtx: (map['nCtx'] as num?)?.toInt() ?? 0,
    nCtxTrain: (map['nCtxTrain'] as num?)?.toInt() ?? 0,
    nBatch: (map['nBatch'] as num?)?.toInt() ?? 0,
    nUbatch: (map['nUbatch'] as num?)?.toInt() ?? 0,
    nThreads: (map['nThreads'] as num?)?.toInt() ?? 0,
    nLayer: (map['nLayer'] as num?)?.toInt() ?? 0,
    nHead: (map['nHead'] as num?)?.toInt() ?? 0,
    nHeadKv: (map['nHeadKv'] as num?)?.toInt() ?? 0,
    nEmbd: (map['nEmbd'] as num?)?.toInt() ?? 0,
    nVocab: (map['nVocab'] as num?)?.toInt() ?? 0,
    nGpuLayers: (map['nGpuLayers'] as num?)?.toInt() ?? 0,
    isGpu: map['isGpu'] == true,
    recommendedCtx: (map['recommendedCtx'] as num?)?.toInt() ?? 0,
    nParams: (map['nParams'] as num?)?.toInt() ?? 0,
    modelBytes: (map['modelBytes'] as num?)?.toInt() ?? 0,
    kvBytesPerToken: (map['kvBytesPerToken'] as num?)?.toInt() ?? 0,
    kvBytes: (map['kvBytes'] as num?)?.toInt() ?? 0,
    totalRamBytes: (map['totalRamBytes'] as num?)?.toInt() ?? 0,
    availRamBytes: (map['availRamBytes'] as num?)?.toInt() ?? 0,
    rssBytes: (map['rssBytes'] as num?)?.toInt() ?? 0,
    peakRssBytes: (map['peakRssBytes'] as num?)?.toInt() ?? 0,
    budgetBytes: (map['budgetBytes'] as num?)?.toInt() ?? 0,
    reserveBytes: (map['reserveBytes'] as num?)?.toInt() ?? 0,
    desc: map['desc'] as String? ?? '',
    backend: map['backend'] as String? ?? '',
    arch: map['arch'] as String? ?? '',
    hasVision: map['hasVision'] == true,
  );
}

class ContextPlan {
  const ContextPlan({
    required this.promptTokens,
    required this.maxOutputTokens,
    required this.nCtx,
    required this.droppedMessages,
    required this.totalMessages,
    required this.fits,
    required this.promptBytes,
  });

  final int promptTokens;
  final int maxOutputTokens;
  final int nCtx;
  final int droppedMessages;
  final int totalMessages;
  final bool fits;
  final int promptBytes;

  double get usage => nCtx > 0 ? promptTokens / nCtx : 0;

  factory ContextPlan.fromMap(Map<dynamic, dynamic> map) => ContextPlan(
    promptTokens: (map['promptTokens'] as num?)?.toInt() ?? 0,
    maxOutputTokens: (map['maxOutputTokens'] as num?)?.toInt() ?? 0,
    nCtx: (map['nCtx'] as num?)?.toInt() ?? 0,
    droppedMessages: (map['droppedMessages'] as num?)?.toInt() ?? 0,
    totalMessages: (map['totalMessages'] as num?)?.toInt() ?? 0,
    fits: map['fits'] == true,
    promptBytes: (map['promptBytes'] as num?)?.toInt() ?? 0,
  );
}

class ChatTurn {
  const ChatTurn(this.role, this.content, {this.imagePaths = const <String>[]});
  final String role;
  final String content;
  final List<String> imagePaths;

  Map<String, Object?> toMap() => {
    'role': role,
    'content': content,
    if (imagePaths.isNotEmpty) 'imagePaths': imagePaths,
  };
}

class GenerationParams {
  const GenerationParams({
    this.maxTokens = 256,
    this.temperature = 0.7,
    this.topP = 0.95,
    this.topK = 40,
    this.minP = 0.05,
    this.repeatPenalty = 1.1,
    this.frequencyPenalty = 0.0,
    this.presencePenalty = 0.0,
    this.repeatLastN = 64,
    this.seed = 0,
    this.ignoreEos = false,
    this.stopSequences = const <String>[],
  });

  final int maxTokens;
  final double temperature;
  final double topP;
  final int topK;
  final double minP;
  final double repeatPenalty;
  final double frequencyPenalty;
  final double presencePenalty;
  final int repeatLastN;
  final int seed;
  final bool ignoreEos;
  final List<String> stopSequences;

  Map<String, Object?> toMap() => {
    'maxTokens': maxTokens,
    'temperature': temperature,
    'topP': topP,
    'topK': topK,
    'minP': minP,
    'repeatPenalty': repeatPenalty,
    'frequencyPenalty': frequencyPenalty,
    'presencePenalty': presencePenalty,
    'repeatLastN': repeatLastN,
    'seed': seed,
    'ignoreEos': ignoreEos,
    'stopSequences': stopSequences,
  };
}

class ChatRequest {
  const ChatRequest({
    required this.messages,
    this.params = const GenerationParams(),
    this.enableThinking = false,
  });

  final List<ChatTurn> messages;
  final GenerationParams params;
  final bool enableThinking;

  Map<String, Object?> toMap() => {
    'messages': messages.map((m) => m.toMap()).toList(),
    'params': params.toMap(),
    'enableThinking': enableThinking,
  };
}

class GenerationStats {
  const GenerationStats({
    required this.promptTokens,
    required this.generatedTokens,
    required this.prefillMs,
    required this.decodeMs,
    required this.loadMs,
    required this.tokensPerSecond,
    required this.stopReason,
  });

  final int promptTokens;
  final int generatedTokens;
  final double prefillMs;
  final double decodeMs;
  final double loadMs;
  final double tokensPerSecond;
  final StopReason stopReason;

  factory GenerationStats.fromMap(Map<dynamic, dynamic> map) => GenerationStats(
    promptTokens: (map['promptTokens'] as num?)?.toInt() ?? 0,
    generatedTokens: (map['generatedTokens'] as num?)?.toInt() ?? 0,
    prefillMs: (map['prefillMs'] as num?)?.toDouble() ?? 0,
    decodeMs: (map['decodeMs'] as num?)?.toDouble() ?? 0,
    loadMs: (map['loadMs'] as num?)?.toDouble() ?? 0,
    tokensPerSecond: (map['tokensPerSecond'] as num?)?.toDouble() ?? 0,
    stopReason: _stopReason((map['stopReason'] as num?)?.toInt() ?? 0),
  );
}

sealed class EngineEvent {
  const EngineEvent();
}

class EngineLoaded extends EngineEvent {
  const EngineLoaded(this.info);
  final EngineInfo info;
}

class PlanReady extends EngineEvent {
  const PlanReady(this.plan);
  final ContextPlan plan;
}

class TokenReceived extends EngineEvent {
  const TokenReceived(this.text);
  final String text;
}

class GenerationFinished extends EngineEvent {
  const GenerationFinished(this.stats);
  final GenerationStats stats;
}

class EngineFailure extends EngineEvent {
  const EngineFailure(this.code, this.message, {this.fatal = false});
  final int code;
  final String message;
  final bool fatal;
}

class EdgeAiException implements Exception {
  const EdgeAiException(this.code, this.message);
  final int code;
  final String message;

  @override
  String toString() => 'EdgeAiException($code): $message';
}

class EdgeAiEngine {
  EdgeAiEngine._(this._isolate, this._receivePort) {
    _receivePort.listen(_onMessage);
  }

  static Future<EdgeAiEngine> spawn() async {
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerMain,
      receivePort.sendPort,
      onError: receivePort.sendPort,
      onExit: receivePort.sendPort,
      errorsAreFatal: true,
      debugName: 'edge-ai-engine',
    );
    return EdgeAiEngine._(isolate, receivePort);
  }

  final Isolate _isolate;
  final ReceivePort _receivePort;
  final StreamController<EngineEvent> _events =
      StreamController<EngineEvent>.broadcast();
  final Completer<SendPort> _ready = Completer<SendPort>();
  final Map<int, Completer<dynamic>> _pending = <int, Completer<dynamic>>{};
  int _nextId = 1;
  bool _disposed = false;
  bool _workerFailed = false;
  EngineInfo? _lastInfo;

  Stream<EngineEvent> get events => _events.stream;

  EngineInfo? get lastInfo => _lastInfo;

  Future<SendPort> get _sendPort => _ready.future;

  void _failWorker(String message) {
    if (_workerFailed || _disposed) return;
    _workerFailed = true;
    final error = EdgeAiException(11, message);
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
    if (!_events.isClosed) {
      _events.add(EngineFailure(11, message, fatal: true));
    }
  }

  void _onMessage(dynamic message) {
    if (message == null) {
      if (!_disposed) _failWorker('inference worker exited');
      return;
    }
    if (message is List) {
      final detail = message.isEmpty
          ? 'unknown isolate error'
          : message.first.toString();
      if (!_disposed) _failWorker('inference worker crashed: $detail');
      return;
    }
    if (message is SendPort) {
      if (!_ready.isCompleted) _ready.complete(message);
      return;
    }
    if (message is! Map) return;

    final id = (message['id'] as num?)?.toInt();
    final op = message['op'] as String?;
    if (id != null && _pending.containsKey(id)) {
      final completer = _pending.remove(id)!;
      if (message['ok'] == true) {
        completer.complete(message);
      } else {
        completer.completeError(
          EdgeAiException(
            (message['code'] as num?)?.toInt() ?? 11,
            message['message'] as String? ?? 'native error',
          ),
        );
      }
      return;
    }

    switch (op) {
      case 'plan':
        _events.add(PlanReady(ContextPlan.fromMap(message['plan'] as Map)));
      case 'token':
        _events.add(TokenReceived(message['text'] as String? ?? ''));
      case 'done':
        _events.add(
          GenerationFinished(GenerationStats.fromMap(message['stats'] as Map)),
        );
      case 'error':
        _events.add(
          EngineFailure(
            (message['code'] as num?)?.toInt() ?? 11,
            message['message'] as String? ?? 'unknown error',
            fatal: message['fatal'] == true,
          ),
        );
      case 'loaded':
        final info = EngineInfo.fromMap(message['info'] as Map);
        _lastInfo = info;
        _events.add(EngineLoaded(info));
    }
  }

  Future<dynamic> _request(String op, [Map<String, Object?>? payload]) async {
    final send = await _sendPort;
    final id = _nextId++;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    send.send(<String, Object?>{'op': op, 'id': id, ...?payload});
    try {
      return await completer.future.timeout(const Duration(minutes: 5));
    } on TimeoutException {
      _pending.remove(id);
      throw const EdgeAiException(11, 'native request timed out');
    }
  }

  Future<EngineInfo> load(EngineConfig config) async {
    final response = await _request('load', {'config': config.toMap()});
    final info = EngineInfo.fromMap(response['info'] as Map);
    _lastInfo = info;
    return info;
  }

  Future<ContextPlan> estimate(ChatRequest request) async {
    final response = await _request('estimate', {'request': request.toMap()});
    return ContextPlan.fromMap(response['plan'] as Map);
  }

  Future<void> generate(ChatRequest request) async {
    final send = await _sendPort;
    send.send(<String, Object?>{'op': 'generate', 'request': request.toMap()});
  }

  Future<void> cancel() async {
    if (_disposed) return;
    final send = await _sendPort;
    send.send(<String, Object?>{'op': 'cancel'});
  }

  Future<void> unload() async {
    await _request('unload');
    _lastInfo = null;
  }

  Future<int> stateSize() async {
    final response = await _request('state_size');
    return (response['bytes'] as num?)?.toInt() ?? 0;
  }

  Future<void> saveState(String path) async {
    if (path.isEmpty) throw const EdgeAiException(1, 'empty state path');
    await _request('state_save', {'path': path});
  }

  Future<void> loadState(String path) async {
    if (path.isEmpty) throw const EdgeAiException(1, 'empty state path');
    await _request('state_load', {'path': path});
  }

  Future<void> clearState() async {
    await _request('state_clear');
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      final send = await _ready.future.timeout(const Duration(seconds: 2));
      send.send(<String, Object?>{'op': 'dispose'});
    } catch (_) {
      // Worker never became ready.
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _receivePort.close();
    _isolate.kill(priority: Isolate.immediate);
    await _events.close();
  }
}

Future<void> _workerMain(SendPort out) async {
  final inbox = ReceivePort();
  out.send(inbox.sendPort);

  EdgeAiBindings? bindings;
  Pointer<Void>? handle;
  bool busy = false;
  bool cancelRequested = false;

  void send(Map<String, Object?> message) => out.send(message);

  try {
    bindings = EdgeAiBindings.open();
  } catch (error) {
    send({
      'op': 'error',
      'code': 11,
      'message': 'load libedge_ai.so failed: $error',
      'fatal': true,
    });
    inbox.close();
    return;
  }
  final ffi = bindings;

  Map<String, Object?> infoMap(Pointer<Void> h) {
    final info = calloc<EdgeAiModelInfo>();
    final visionPtr = calloc<Int32>();
    try {
      info.ref.structSize = sizeOf<EdgeAiModelInfo>();
      final status = ffi.getModelInfo(h, info);
      if (status != 0) throw StateError('getModelInfo failed: $status');
      ffi.hasVision(h, visionPtr);
      return {
        'nCtx': info.ref.nCtx,
        'nCtxTrain': info.ref.nCtxTrain,
        'nBatch': info.ref.nBatch,
        'nUbatch': info.ref.nUbatch,
        'nThreads': info.ref.nThreads,
        'nLayer': info.ref.nLayer,
        'nHead': info.ref.nHead,
        'nHeadKv': info.ref.nHeadKv,
        'nEmbd': info.ref.nEmbd,
        'nVocab': info.ref.nVocab,
        'nGpuLayers': info.ref.nGpuLayers,
        'isGpu': info.ref.isGpu != 0,
        'recommendedCtx': info.ref.recommendedCtx,
        'nParams': info.ref.nParams,
        'modelBytes': info.ref.modelBytes,
        'kvBytesPerToken': info.ref.kvBytesPerToken,
        'kvBytes': info.ref.kvBytes,
        'totalRamBytes': info.ref.totalRam,
        'availRamBytes': info.ref.availRam,
        'rssBytes': info.ref.rssBytes,
        'peakRssBytes': info.ref.peakRssBytes,
        'budgetBytes': info.ref.budgetBytes,
        'reserveBytes': info.ref.reserveBytes,
        'desc': EdgeAiBindings.readCharArray(info.ref.desc, 256),
        'backend': EdgeAiBindings.readCharArray(info.ref.backend, 256),
        'arch': EdgeAiBindings.readCharArray(info.ref.arch, 64),
        'hasVision': visionPtr.value != 0,
      };
    } finally {
      calloc.free(info);
      calloc.free(visionPtr);
    }
  }

  ({Pointer<Uint8> prompt, Pointer<EdgeAiChatPlan> plan, int status}) prepare(
    Pointer<Void> h,
    Map<dynamic, dynamic> request,
  ) {
    final messages = (request['messages'] as List?) ?? const [];
    final params = (request['params'] as Map?) ?? const {};
    final maxOutput = (params['maxTokens'] as num?)?.toInt() ?? 256;
    final enableThinking = request['enableThinking'] == true ? 1 : 0;

    final messageArray = calloc<EdgeAiChatMessage>(messages.length);
    final nativeStrings = <Pointer<Utf8>>[];
    try {
      for (var i = 0; i < messages.length; i++) {
        final item = messages[i] as Map;
        final role = (item['role'] as String? ?? 'user').toNativeUtf8();
        final content = (item['content'] as String? ?? '').toNativeUtf8();
        nativeStrings.add(role);
        nativeStrings.add(content);
        messageArray[i].role = role;
        messageArray[i].content = content;
      }

      final plan = calloc<EdgeAiChatPlan>();
      plan.ref.structSize = sizeOf<EdgeAiChatPlan>();
      final err = calloc<Uint8>(EdgeAiBindings.errCap);
      try {
        var status = ffi.prepareChat(
          h,
          messageArray,
          messages.length,
          maxOutput,
          enableThinking,
          nullptr,
          0,
          plan,
        );
        if (status != 10 && status != 0) {
          throw EdgeAiException(status, EdgeAiBindings.readError(err));
        }
        if (plan.ref.fits == 0) {
          throw EdgeAiException(
            5,
            'context overflow (${plan.ref.promptTokens} tokens)',
          );
        }
        final buffer = calloc<Uint8>(plan.ref.promptBytes + 1);
        status = ffi.prepareChat(
          h,
          messageArray,
          messages.length,
          maxOutput,
          enableThinking,
          buffer,
          plan.ref.promptBytes + 1,
          plan,
        );
        if (status != 0) {
          calloc.free(buffer);
          throw EdgeAiException(status, EdgeAiBindings.readError(err));
        }
        return (prompt: buffer, plan: plan, status: status);
      } finally {
        calloc.free(err);
      }
    } finally {
      for (final string in nativeStrings) {
        malloc.free(string);
      }
      calloc.free(messageArray);
    }
  }

  Map<String, Object?> planMap(Pointer<EdgeAiChatPlan> plan) => {
    'promptTokens': plan.ref.promptTokens,
    'maxOutputTokens': plan.ref.maxOutputTokens,
    'nCtx': plan.ref.nCtx,
    'droppedMessages': plan.ref.droppedMessages,
    'totalMessages': plan.ref.totalMessages,
    'fits': plan.ref.fits != 0,
    'promptBytes': plan.ref.promptBytes,
  };

  Future<void> runVisionGeneration(
    Pointer<Void> h,
    Map<dynamic, dynamic> request,
  ) async {
    if (busy) {
      send({'op': 'error', 'code': 3, 'message': 'generation already running'});
      return;
    }
    busy = true;
    cancelRequested = false;

    final messages = (request['messages'] as List?) ?? const [];
    final params = (request['params'] as Map?) ?? const {};
    final messageArray = calloc<EdgeAiChatMessageV4>(messages.length);
    final nativeStrings = <Pointer<Utf8>>[];
    final imageArrays = <Pointer<Pointer<Utf8>>>[];
    final stopStrings = <Pointer<Utf8>>[];
    final stopPtrs = calloc<Pointer<Utf8>>(
      ((params['stopSequences'] as List?) ?? const []).length,
    );
    final gen = calloc<EdgeAiGenParams>();
    final err = calloc<Uint8>(EdgeAiBindings.errCap);
    final outBuffer = calloc<Uint8>(8192);
    final outLen = calloc<Int32>();
    final reason = calloc<Int32>();
    Pointer<EdgeAiChatPlan>? plan;
    try {
      for (var i = 0; i < messages.length; i++) {
        final item = messages[i] as Map;
        final role = (item['role'] as String? ?? 'user').toNativeUtf8();
        final content = (item['content'] as String? ?? '').toNativeUtf8();
        nativeStrings.add(role);
        nativeStrings.add(content);
        final rawPaths =
            (item['imagePaths'] as List?)?.cast<String>() ??
            [
              if ((item['imagePath'] as String?)?.isNotEmpty ?? false)
                item['imagePath'] as String,
            ];
        final paths = rawPaths.where((p) => p.isNotEmpty).toList();
        Pointer<Pointer<Utf8>> pathsPtr = nullptr;
        if (paths.isNotEmpty) {
          pathsPtr = calloc<Pointer<Utf8>>(paths.length);
          imageArrays.add(pathsPtr);
          for (var j = 0; j < paths.length; j++) {
            final path = paths[j].toNativeUtf8();
            nativeStrings.add(path);
            pathsPtr[j] = path;
          }
        }
        messageArray[i].role = role;
        messageArray[i].content = content;
        messageArray[i].imagePaths = pathsPtr;
        messageArray[i].nImagePaths = paths.length;
      }

      plan = calloc<EdgeAiChatPlan>();
      plan.ref.structSize = sizeOf<EdgeAiChatPlan>();
      final planStatus = ffi.prepareChatV4(
        h,
        messageArray,
        messages.length,
        (params['maxTokens'] as num?)?.toInt() ?? 256,
        request['enableThinking'] == true ? 1 : 0,
        nullptr,
        0,
        plan,
      );
      if (planStatus != 0 && planStatus != 10) {
        throw EdgeAiException(planStatus, EdgeAiBindings.readError(err));
      }
      send({'op': 'plan', 'plan': planMap(plan)});
      if (plan.ref.fits == 0) {
        throw const EdgeAiException(5, 'context overflow');
      }

      gen.ref.structSize = sizeOf<EdgeAiGenParams>();
      gen.ref.maxTokens = (params['maxTokens'] as num?)?.toInt() ?? 256;
      gen.ref.topK = (params['topK'] as num?)?.toInt() ?? 40;
      gen.ref.repeatLastN = (params['repeatLastN'] as num?)?.toInt() ?? 64;
      gen.ref.ignoreEos = params['ignoreEos'] == true ? 1 : 0;
      gen.ref.seed = (params['seed'] as num?)?.toInt() ?? 0;
      gen.ref.temperature = (params['temperature'] as num?)?.toDouble() ?? 0.7;
      gen.ref.topP = (params['topP'] as num?)?.toDouble() ?? 0.95;
      gen.ref.minP = (params['minP'] as num?)?.toDouble() ?? 0.05;
      gen.ref.repeatPenalty =
          (params['repeatPenalty'] as num?)?.toDouble() ?? 1.1;
      gen.ref.frequencyPenalty =
          (params['frequencyPenalty'] as num?)?.toDouble() ?? 0;
      gen.ref.presencePenalty =
          (params['presencePenalty'] as num?)?.toDouble() ?? 0;
      final stops =
          (params['stopSequences'] as List?)?.cast<String>() ??
          const <String>[];
      gen.ref.stopSequences = stopPtrs;
      gen.ref.nStopSequences = stops.length;
      for (var i = 0; i < stops.length; i++) {
        final p = stops[i].toNativeUtf8();
        stopStrings.add(p);
        stopPtrs[i] = p;
      }

      final startStatus = ffi.startChatV4(
        h,
        messageArray,
        messages.length,
        gen,
        err,
        EdgeAiBindings.errCap,
      );
      if (startStatus != 0) {
        throw EdgeAiException(startStatus, EdgeAiBindings.readError(err));
      }

      final decoder = _Utf8Stream();
      for (;;) {
        if (cancelRequested) ffi.cancel(h);
        final result = ffi.nextEx(
          h,
          outBuffer,
          8192,
          outLen,
          reason,
          err,
          EdgeAiBindings.errCap,
        );
        if (result != 0) {
          throw EdgeAiException(result, EdgeAiBindings.readError(err));
        }
        final count = outLen.value;
        if (count == 0) break;
        final text = decoder.add(outBuffer.asTypedList(count));
        if (text.isNotEmpty) send({'op': 'token', 'text': text});
        await Future<void>.delayed(Duration.zero);
      }

      final stats = calloc<EdgeAiStats>();
      try {
        stats.ref.structSize = sizeOf<EdgeAiStats>();
        ffi.getStats(h, stats);
        send({
          'op': 'done',
          'stats': {
            'promptTokens': stats.ref.promptTokens,
            'generatedTokens': stats.ref.generatedTokens,
            'prefillMs': stats.ref.prefillMs,
            'decodeMs': stats.ref.decodeMs,
            'loadMs': stats.ref.loadMs,
            'tokensPerSecond': stats.ref.tokensPerSecond,
            'stopReason': stats.ref.stopReason,
          },
        });
      } finally {
        calloc.free(stats);
      }
    } catch (error) {
      final code = error is EdgeAiException ? error.code : 11;
      final message = error is EdgeAiException
          ? error.message
          : error.toString();
      send({'op': 'error', 'code': code, 'message': message});
    } finally {
      for (final p in nativeStrings) {
        malloc.free(p);
      }
      for (final p in imageArrays) {
        calloc.free(p);
      }
      for (final p in stopStrings) {
        malloc.free(p);
      }
      calloc.free(messageArray);
      calloc.free(stopPtrs);
      calloc.free(gen);
      calloc.free(err);
      calloc.free(outBuffer);
      calloc.free(outLen);
      calloc.free(reason);
      if (plan != null) calloc.free(plan);
      busy = false;
      cancelRequested = false;
    }
  }

  void loadModel(Map<dynamic, dynamic> config, int id) {
    if (busy) {
      send({
        'op': 'loaded',
        'id': id,
        'ok': false,
        'code': 3,
        'message': 'generation is running',
      });
      return;
    }
    if (handle != null) {
      ffi.destroy(handle!);
      handle = null;
    }
    final path = config['modelPath'] as String? ?? '';
    final cfg = calloc<EdgeAiConfig>();
    final pathPtr = path.toNativeUtf8();
    final err = calloc<Uint8>(EdgeAiBindings.errCap);
    final handlePtr = calloc<Pointer<Void>>();
    try {
      cfg.ref.structSize = sizeOf<EdgeAiConfig>();
      cfg.ref.modelPath = pathPtr;
      cfg.ref.backend = (config['backend'] as num?)?.toInt() ?? 0;
      cfg.ref.nGpuLayers = -1;
      cfg.ref.nCtx = (config['contextSize'] as num?)?.toInt() ?? 0;
      cfg.ref.nBatch = (config['batchSize'] as num?)?.toInt() ?? 512;
      cfg.ref.nUbatch = (config['ubatchSize'] as num?)?.toInt() ?? 512;
      cfg.ref.nThreads = (config['threads'] as num?)?.toInt() ?? 4;
      cfg.ref.nThreadsBatch = cfg.ref.nThreads;
      cfg.ref.flashAttn = (config['flashAttention'] as num?)?.toInt() ?? -1;
      cfg.ref.useMmap = config['useMmap'] == false ? 0 : 1;
      cfg.ref.useMlock = config['useMlock'] == true ? 1 : 0;
      cfg.ref.allowCpuFallback = config['allowCpuFallback'] == false ? 0 : 1;
      cfg.ref.strictMemory = config['strictMemory'] == true ? 1 : 0;
      cfg.ref.kvTypeK = 0;
      cfg.ref.kvTypeV = 0;
      cfg.ref.memoryBudgetBytes =
          (config['memoryBudgetBytes'] as num?)?.toInt() ?? 0;
      cfg.ref.memoryReserveBytes =
          (config['memoryReserveBytes'] as num?)?.toInt() ?? 0;
      cfg.ref.minCtx = (config['minContext'] as num?)?.toInt() ?? 512;
      cfg.ref.maxCtx = (config['maxContext'] as num?)?.toInt() ?? 8192;

      final status = ffi.createEx(cfg, handlePtr, err, EdgeAiBindings.errCap);
      if (status != 0) {
        send({
          'op': 'loaded',
          'id': id,
          'ok': false,
          'code': status,
          'message': EdgeAiBindings.readError(err),
        });
        return;
      }
      handle = handlePtr.value;
      final mmproj = config['mmprojPath'] as String?;
      if (mmproj != null && mmproj.isNotEmpty) {
        final mmPtr = mmproj.toNativeUtf8();
        final visionStatus = ffi.loadMmproj(
          handle!,
          mmPtr,
          err,
          EdgeAiBindings.errCap,
        );
        malloc.free(mmPtr);
        if (visionStatus != 0) {
          ffi.destroy(handle!);
          handle = null;
          send({
            'op': 'loaded',
            'id': id,
            'ok': false,
            'code': visionStatus,
            'message': EdgeAiBindings.readError(err),
          });
          return;
        }
      }
      send({'op': 'loaded', 'id': id, 'ok': true, 'info': infoMap(handle!)});
    } catch (error) {
      send({
        'op': 'loaded',
        'id': id,
        'ok': false,
        'code': 11,
        'message': error.toString(),
      });
    } finally {
      calloc.free(cfg);
      malloc.free(pathPtr);
      calloc.free(err);
      calloc.free(handlePtr);
    }
  }

  Future<void> runGeneration(Map<dynamic, dynamic> request) async {
    final h = handle;
    if (h == null) {
      send({'op': 'error', 'code': 2, 'message': 'model not loaded'});
      return;
    }
    final messages = (request['messages'] as List?) ?? const [];
    if (messages.any((m) {
      final map = m as Map;
      final paths = map['imagePaths'];
      if (paths is List && paths.isNotEmpty) return true;
      final legacy = map['imagePath'];
      return legacy is String && legacy.isNotEmpty;
    })) {
      await runVisionGeneration(h, request);
      return;
    }
    if (busy) {
      send({'op': 'error', 'code': 3, 'message': 'generation already running'});
      return;
    }
    busy = true;
    cancelRequested = false;
    Pointer<Uint8>? prompt;
    Pointer<EdgeAiChatPlan>? plan;
    try {
      final prepared = prepare(h, request);
      prompt = prepared.prompt;
      final preparedPlan = prepared.plan;
      plan = preparedPlan;
      send({'op': 'plan', 'plan': planMap(preparedPlan)});

      final params = (request['params'] as Map?) ?? const {};
      final stops =
          (params['stopSequences'] as List?)?.cast<String>() ??
          const <String>[];
      final stopPtrs = calloc<Pointer<Utf8>>(stops.length);
      final stopStrings = <Pointer<Utf8>>[];
      final gen = calloc<EdgeAiGenParams>();
      final err = calloc<Uint8>(EdgeAiBindings.errCap);
      final outBuffer = calloc<Uint8>(8192);
      final outLen = calloc<Int32>();
      final reason = calloc<Int32>();
      try {
        gen.ref.structSize = sizeOf<EdgeAiGenParams>();
        gen.ref.maxTokens = (params['maxTokens'] as num?)?.toInt() ?? 256;
        gen.ref.topK = (params['topK'] as num?)?.toInt() ?? 40;
        gen.ref.repeatLastN = (params['repeatLastN'] as num?)?.toInt() ?? 64;
        gen.ref.ignoreEos = params['ignoreEos'] == true ? 1 : 0;
        gen.ref.seed = (params['seed'] as num?)?.toInt() ?? 0;
        gen.ref.temperature =
            (params['temperature'] as num?)?.toDouble() ?? 0.7;
        gen.ref.topP = (params['topP'] as num?)?.toDouble() ?? 0.95;
        gen.ref.minP = (params['minP'] as num?)?.toDouble() ?? 0.05;
        gen.ref.repeatPenalty =
            (params['repeatPenalty'] as num?)?.toDouble() ?? 1.1;
        gen.ref.frequencyPenalty =
            (params['frequencyPenalty'] as num?)?.toDouble() ?? 0;
        gen.ref.presencePenalty =
            (params['presencePenalty'] as num?)?.toDouble() ?? 0;
        gen.ref.stopSequences = stopPtrs;
        gen.ref.nStopSequences = stops.length;
        for (var i = 0; i < stops.length; i++) {
          final p = stops[i].toNativeUtf8();
          stopStrings.add(p);
          stopPtrs[i] = p;
        }

        var status = ffi.startEx(
          h,
          prompt.cast<Utf8>(),
          gen,
          err,
          EdgeAiBindings.errCap,
        );
        if (status != 0) {
          throw EdgeAiException(status, EdgeAiBindings.readError(err));
        }

        final decoder = _Utf8Stream();
        while (true) {
          if (cancelRequested) {
            ffi.cancel(h);
          }
          final result = ffi.nextEx(
            h,
            outBuffer,
            8192,
            outLen,
            reason,
            err,
            EdgeAiBindings.errCap,
          );
          if (result != 0) {
            throw EdgeAiException(result, EdgeAiBindings.readError(err));
          }
          final count = outLen.value;
          if (count == 0) break;
          final text = decoder.add(outBuffer.asTypedList(count));
          if (text.isNotEmpty) send({'op': 'token', 'text': text});
          await Future<void>.delayed(Duration.zero);
        }

        final stats = calloc<EdgeAiStats>();
        try {
          stats.ref.structSize = sizeOf<EdgeAiStats>();
          ffi.getStats(h, stats);
          send({
            'op': 'done',
            'stats': {
              'promptTokens': stats.ref.promptTokens,
              'generatedTokens': stats.ref.generatedTokens,
              'prefillMs': stats.ref.prefillMs,
              'decodeMs': stats.ref.decodeMs,
              'loadMs': stats.ref.loadMs,
              'tokensPerSecond': stats.ref.tokensPerSecond,
              'stopReason': stats.ref.stopReason,
            },
          });
        } finally {
          calloc.free(stats);
        }
      } finally {
        for (final p in stopStrings) {
          malloc.free(p);
        }
        calloc.free(stopPtrs);
        calloc.free(gen);
        calloc.free(err);
        calloc.free(outBuffer);
        calloc.free(outLen);
        calloc.free(reason);
      }
    } catch (error) {
      final code = error is EdgeAiException ? error.code : 11;
      final message = error is EdgeAiException
          ? error.message
          : error.toString();
      send({'op': 'error', 'code': code, 'message': message});
    } finally {
      if (prompt != null) calloc.free(prompt);
      if (plan != null) calloc.free(plan);
      busy = false;
      cancelRequested = false;
    }
  }

  inbox.listen((message) async {
    if (message is! Map) return;
    final op = message['op'] as String?;
    final id = (message['id'] as num?)?.toInt();

    switch (op) {
      case 'load':
        loadModel(message['config'] as Map? ?? const {}, id ?? 0);
      case 'estimate':
        final h = handle;
        if (h == null) {
          send({
            'op': 'estimate',
            'id': id,
            'ok': false,
            'code': 2,
            'message': 'model not loaded',
          });
          break;
        }
        if (busy) {
          send({
            'op': 'estimate',
            'id': id,
            'ok': false,
            'code': 3,
            'message': 'busy',
          });
          break;
        }
        try {
          final prepared = prepare(h, message['request'] as Map? ?? const {});
          final plan = prepared.plan;
          send({'op': 'estimate', 'id': id, 'ok': true, 'plan': planMap(plan)});
          calloc.free(prepared.prompt);
          calloc.free(plan);
        } catch (error) {
          final code = error is EdgeAiException ? error.code : 11;
          final text = error is EdgeAiException
              ? error.message
              : error.toString();
          send({
            'op': 'estimate',
            'id': id,
            'ok': false,
            'code': code,
            'message': text,
          });
        }
      case 'generate':
        await runGeneration(message['request'] as Map? ?? const {});
      case 'cancel':
        cancelRequested = true;
        if (handle != null) ffi.cancel(handle!);
      case 'state_size':
        final h = handle;
        if (h == null) {
          send({
            'op': 'state_size',
            'id': id,
            'ok': false,
            'code': 2,
            'message': 'model not loaded',
          });
          break;
        }
        final bytes = calloc<Uint64>();
        final status = ffi.stateSize(h, bytes);
        if (status != 0) {
          send({
            'op': 'state_size',
            'id': id,
            'ok': false,
            'code': status,
            'message': 'stateSize failed: $status',
          });
        } else {
          send({
            'op': 'state_size',
            'id': id,
            'ok': true,
            'bytes': bytes.value,
          });
        }
        calloc.free(bytes);
      case 'state_save':
        final h = handle;
        if (h == null) {
          send({
            'op': 'state_save',
            'id': id,
            'ok': false,
            'code': 2,
            'message': 'model not loaded',
          });
          break;
        }
        final path = message['path'] as String? ?? '';
        final pathPtr = path.toNativeUtf8();
        final err = calloc<Uint8>(EdgeAiBindings.errCap);
        final status = ffi.stateSave(h, pathPtr, err, EdgeAiBindings.errCap);
        send({
          'op': 'state_save',
          'id': id,
          'ok': status == 0,
          'code': status,
          'message': EdgeAiBindings.readError(err),
        });
        malloc.free(pathPtr);
        calloc.free(err);
      case 'state_load':
        final h = handle;
        if (h == null) {
          send({
            'op': 'state_load',
            'id': id,
            'ok': false,
            'code': 2,
            'message': 'model not loaded',
          });
          break;
        }
        final path = message['path'] as String? ?? '';
        final pathPtr = path.toNativeUtf8();
        final err = calloc<Uint8>(EdgeAiBindings.errCap);
        final status = ffi.stateLoad(h, pathPtr, err, EdgeAiBindings.errCap);
        send({
          'op': 'state_load',
          'id': id,
          'ok': status == 0,
          'code': status,
          'message': EdgeAiBindings.readError(err),
        });
        malloc.free(pathPtr);
        calloc.free(err);
      case 'state_clear':
        final h = handle;
        if (h == null) {
          send({
            'op': 'state_clear',
            'id': id,
            'ok': false,
            'code': 2,
            'message': 'model not loaded',
          });
          break;
        }
        final status = ffi.stateClear(h);
        send({
          'op': 'state_clear',
          'id': id,
          'ok': status == 0,
          'code': status,
          'message': '',
        });
      case 'unload':
        if (busy) {
          send({
            'op': 'unload',
            'id': id,
            'ok': false,
            'code': 3,
            'message': 'busy',
          });
          break;
        }
        if (handle != null) {
          ffi.destroy(handle!);
          handle = null;
        }
        send({'op': 'unload', 'id': id, 'ok': true});
      case 'dispose':
        cancelRequested = true;
        if (handle != null) {
          ffi.destroy(handle!);
          handle = null;
        }
        inbox.close();
        break;
    }
  });
}

class _Utf8Stream {
  final List<int> _pending = <int>[];

  String add(List<int> bytes) {
    _pending.addAll(bytes);
    if (_pending.isEmpty) return '';
    var cut = _pending.length;
    var i = cut - 1;
    while (i >= 0 && (_pending[i] & 0xC0) == 0x80) {
      i--;
    }
    if (i >= 0) {
      final lead = _pending[i];
      final need = lead < 0x80
          ? 1
          : (lead & 0xE0) == 0xC0
          ? 2
          : (lead & 0xF0) == 0xE0
          ? 3
          : (lead & 0xF8) == 0xF0
          ? 4
          : 1;
      if (cut - i < need) cut = i;
    }
    if (cut <= 0) return '';
    final complete = _pending.sublist(0, cut);
    _pending.removeRange(0, cut);
    return utf8.decode(complete, allowMalformed: true);
  }
}
