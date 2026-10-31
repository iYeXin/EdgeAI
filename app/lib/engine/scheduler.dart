// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'edge_ai.dart';

/// Policy for the single-resident-model scheduler.
///
/// The scheduler is deliberately conservative: it reserves headroom before
/// loading, caps the context, unloads on background/idle, and refuses a load
/// that cannot fit instead of letting the OS kill the process.
class SchedulerPolicy {
  const SchedulerPolicy({
    this.backend = ComputeBackend.auto,
    this.threads = 4,
    this.minContext = 512,
    this.maxContext = 32768,
    this.memoryHeadroomBytes = 0,
    this.maxMemoryBudgetBytes = 0,
    this.idleUnloadAfter = const Duration(minutes: 10),
    this.unloadOnBackground = true,
    this.strictMemory = false,
    this.watchdogInterval = const Duration(seconds: 15),
  });

  final ComputeBackend backend;
  final int threads;
  final int minContext;
  final int maxContext;

  /// 0 = max(1 GiB, total RAM * 10%).
  final int memoryHeadroomBytes;

  /// 0 = current available system memory.
  final int maxMemoryBudgetBytes;
  final Duration idleUnloadAfter;
  final bool unloadOnBackground;
  final bool strictMemory;
  final Duration watchdogInterval;

  SchedulerPolicy copyWith({
    ComputeBackend? backend,
    int? threads,
    int? minContext,
    int? maxContext,
    int? memoryHeadroomBytes,
    int? maxMemoryBudgetBytes,
    Duration? idleUnloadAfter,
    bool? unloadOnBackground,
    bool? strictMemory,
    Duration? watchdogInterval,
  }) {
    return SchedulerPolicy(
      backend: backend ?? this.backend,
      threads: threads ?? this.threads,
      minContext: minContext ?? this.minContext,
      maxContext: maxContext ?? this.maxContext,
      memoryHeadroomBytes: memoryHeadroomBytes ?? this.memoryHeadroomBytes,
      maxMemoryBudgetBytes: maxMemoryBudgetBytes ?? this.maxMemoryBudgetBytes,
      idleUnloadAfter: idleUnloadAfter ?? this.idleUnloadAfter,
      unloadOnBackground: unloadOnBackground ?? this.unloadOnBackground,
      strictMemory: strictMemory ?? this.strictMemory,
      watchdogInterval: watchdogInterval ?? this.watchdogInterval,
    );
  }
}

class ModelSpec {
  const ModelSpec({required this.id, required this.path, this.mmprojPath});

  final String id;
  final String path;
  final String? mmprojPath;

  @override
  bool operator ==(Object other) =>
      other is ModelSpec &&
      other.id == id &&
      other.path == path &&
      other.mmprojPath == mmprojPath;

  @override
  int get hashCode => Object.hash(id, path, mmprojPath);
}

enum SchedulerState {
  idle,
  loading,
  ready,
  generating,
  unloading,
  failed,
  disposed,
}

class SchedulerSnapshot {
  const SchedulerSnapshot({
    required this.state,
    required this.model,
    required this.info,
    required this.reservedBytes,
    required this.headroomBytes,
    required this.lastError,
  });

  final SchedulerState state;
  final ModelSpec? model;
  final EngineInfo? info;
  final int reservedBytes;
  final int headroomBytes;
  final String? lastError;
}

sealed class SchedulerEvent {
  const SchedulerEvent();
}

class SchedulerStateChanged extends SchedulerEvent {
  const SchedulerStateChanged(this.state);
  final SchedulerState state;
}

class ModelLoadedEvent extends SchedulerEvent {
  const ModelLoadedEvent(this.model, this.info);
  final ModelSpec model;
  final EngineInfo info;
}

class ModelUnloadedEvent extends SchedulerEvent {
  const ModelUnloadedEvent(this.model, this.reason);
  final ModelSpec? model;
  final String reason;
}

class MemoryPressureEvent extends SchedulerEvent {
  const MemoryPressureEvent(this.availableBytes, this.headroomBytes);
  final int availableBytes;
  final int headroomBytes;
}

class SchedulerFailureEvent extends SchedulerEvent {
  const SchedulerFailureEvent(this.message, {this.fatal = false});
  final String message;
  final bool fatal;
}

class SchedulerBusyException implements Exception {
  const SchedulerBusyException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ResourceExhaustedException implements Exception {
  const ResourceExhaustedException({
    required this.requiredBytes,
    required this.availableBytes,
    required this.headroomBytes,
  });

  final int requiredBytes;
  final int availableBytes;
  final int headroomBytes;

  @override
  String toString() =>
      '内存不足：需要 ${_mb(requiredBytes)} MB，可用 ${_mb(availableBytes)} MB，'
      '预留 ${_mb(headroomBytes)} MB。请关闭其他应用或降低 context。';
}

String _mb(int bytes) => (bytes / (1024 * 1024)).round().toString();

/// Single-resident-model scheduler.
///
/// Invariants:
/// - At most one model handle is loaded.
/// - A load is admitted only if file + headroom fits in the current budget.
/// - No load while generating; no unload while generating (deferred instead).
/// - Background/idle/pressure unloads are automatic.
class InferenceScheduler {
  InferenceScheduler(
    this._engine, {
    SchedulerPolicy policy = const SchedulerPolicy(),
  }) : _policy = policy {
    _engineSub = _engine.events.listen(_onEngineEvent);
  }

  final EdgeAiEngine _engine;
  SchedulerPolicy _policy;
  StreamSubscription<EngineEvent>? _engineSub;
  final StreamController<SchedulerEvent> _events =
      StreamController<SchedulerEvent>.broadcast();

  SchedulerState _state = SchedulerState.idle;
  ModelSpec? _model;
  ModelSpec? _configuredModel;
  EngineInfo? _info;
  int _reservedBytes = 0;
  int _headroomBytes = 0;
  String? _lastError;
  bool _generating = false;
  bool _disposed = false;
  bool _unloadWhenIdle = false;
  int _loadedContext = 0;
  int _loadedMaxContext = 0;
  int _policyRevision = 0;
  int _loadedRevision = -1;
  bool _pressureNotified = false;
  Timer? _idleTimer;
  Timer? _watchdog;
  Future<void> _tail = Future<void>.value();

  Stream<EngineEvent> get generationEvents => _engine.events;
  Stream<SchedulerEvent> get events => _events.stream;
  SchedulerPolicy get policy => _policy;

  SchedulerSnapshot get snapshot => SchedulerSnapshot(
    state: _state,
    model: _model,
    info: _info,
    reservedBytes: _reservedBytes,
    headroomBytes: _headroomBytes,
    lastError: _lastError,
  );

  void updatePolicy(SchedulerPolicy policy) {
    _policy = policy;
    _policyRevision++;
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final previous = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    return previous.then((_) => action()).whenComplete(gate.complete);
  }

  Future<EngineInfo> ensureLoaded(
    ModelSpec spec, {
    int contextSize = 0,
    int? maxContext,
    int? memoryBudgetBytes,
  }) {
    if (_disposed) throw StateError('scheduler disposed');
    return _serialize(
      () => _loadLocked(
        spec,
        contextSize: contextSize,
        maxContext: maxContext,
        memoryBudgetBytes: memoryBudgetBytes,
      ),
    );
  }

  Future<EngineInfo> _loadLocked(
    ModelSpec spec, {
    required int contextSize,
    int? maxContext,
    int? memoryBudgetBytes,
  }) async {
    if (_generating) throw const SchedulerBusyException('正在生成，不能切换模型');

    final desiredMax =
        maxContext ?? (contextSize > 0 ? contextSize : _policy.maxContext);
    _configuredModel = spec;
    if (_info != null &&
        _model == spec &&
        _loadedContext == contextSize &&
        _loadedMaxContext == desiredMax &&
        _loadedRevision == _policyRevision) {
      _touch();
      return _info!;
    }

    final memory = await DeviceMemory.read();
    if (memory.totalBytes <= 0) {
      throw const ResourceExhaustedException(
        requiredBytes: 0,
        availableBytes: 0,
        headroomBytes: 0,
      );
    }

    var headroom = _policy.memoryHeadroomBytes > 0
        ? _policy.memoryHeadroomBytes
        : math.max(1024 * 1024 * 1024, (memory.totalBytes * 0.10).round());

    final file = File(spec.path);
    final fileBytes = await file.length();
    final mmprojBytes = spec.mmprojPath != null && spec.mmprojPath!.isNotEmpty
        ? await File(spec.mmprojPath!).length()
        : 0;
    if (fileBytes <= 0) {
      throw FileSystemException('模型文件为空或不存在', spec.path);
    }

    int budget;
    if (memoryBudgetBytes != null && memoryBudgetBytes > 0) {
      budget = math.min(
        memoryBudgetBytes,
        memory.availBytes > 0 ? memory.availBytes : memory.totalBytes,
      );
    } else if (_policy.maxMemoryBudgetBytes > 0) {
      budget = math.min(
        _policy.maxMemoryBudgetBytes,
        memory.availBytes > 0 ? memory.availBytes : memory.totalBytes,
      );
    } else {
      budget = memory.availBytes > 0 ? memory.availBytes : memory.totalBytes;
    }

    if (budget <= headroom || fileBytes + mmprojBytes + headroom > budget) {
      throw ResourceExhaustedException(
        requiredBytes: fileBytes + mmprojBytes + headroom,
        availableBytes: budget,
        headroomBytes: headroom,
      );
    }

    if (_info != null) {
      _setState(SchedulerState.unloading);
      await _engine.unload();
      _clearModel();
      // Give the OS a moment to reclaim the mmap/Vulkan allocations.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final refreshed = await DeviceMemory.read();
      if (refreshed.availBytes > 0) {
        budget = memoryBudgetBytes != null && memoryBudgetBytes > 0
            ? math.min(memoryBudgetBytes, refreshed.availBytes)
            : _policy.maxMemoryBudgetBytes > 0
            ? math.min(_policy.maxMemoryBudgetBytes, refreshed.availBytes)
            : refreshed.availBytes;
        if (budget <= headroom || fileBytes + mmprojBytes + headroom > budget) {
          throw ResourceExhaustedException(
            requiredBytes: fileBytes + mmprojBytes + headroom,
            availableBytes: budget,
            headroomBytes: headroom,
          );
        }
      }
    }

    _headroomBytes = headroom;
    _setState(SchedulerState.loading);
    _lastError = null;

    final info = await _engine.load(
      EngineConfig(
        modelPath: spec.path,
        mmprojPath: spec.mmprojPath,
        backend: _policy.backend,
        threads: _policy.threads,
        contextSize: contextSize,
        minContext: _policy.minContext,
        maxContext: desiredMax,
        memoryBudgetBytes: budget,
        memoryReserveBytes: headroom,
        allowCpuFallback: true,
        strictMemory: _policy.strictMemory,
        flashAttention: FlashAttention.auto,
      ),
    );

    final required = info.modelBytes + info.kvBytes + headroom + mmprojBytes;
    if (required > budget) {
      await _engine.unload();
      _clearModel();
      _setState(SchedulerState.idle);
      throw ResourceExhaustedException(
        requiredBytes: required,
        availableBytes: budget,
        headroomBytes: headroom,
      );
    }

    _model = spec;
    _info = info;
    _reservedBytes = required;
    _loadedContext = contextSize;
    _loadedMaxContext = desiredMax;
    _loadedRevision = _policyRevision;
    _unloadWhenIdle = false;
    _setState(SchedulerState.ready);
    _events.add(ModelLoadedEvent(spec, info));
    _touch();
    _startWatchdog();
    return info;
  }

  Future<void> generate(ChatRequest request) async {
    if (_disposed) throw StateError('scheduler disposed');
    final spec = _configuredModel;
    if (spec == null) throw StateError('没有已配置的模型');
    if (_generating) throw const SchedulerBusyException('已有生成任务');
    if (_info == null) {
      await ensureLoaded(
        spec,
        contextSize: _loadedContext,
        maxContext: _loadedMaxContext,
      );
    }
    if (_generating) throw const SchedulerBusyException('已有生成任务');
    _generating = true;
    _unloadWhenIdle = false;
    _idleTimer?.cancel();
    _setState(SchedulerState.generating);
    try {
      await _engine.generate(request);
    } catch (_) {
      _generating = false;
      _setState(SchedulerState.ready);
      rethrow;
    }
  }

  Future<void> cancel() => _engine.cancel();

  Future<int> stateSize() async {
    if (_info == null) return 0;
    return _engine.stateSize();
  }

  Future<void> saveState(String path) async {
    if (_generating) throw const SchedulerBusyException('生成中不能保存 state');
    if (_info == null) throw StateError('model not loaded');
    await _engine.saveState(path);
  }

  Future<void> loadState(String path) async {
    if (_generating) throw const SchedulerBusyException('生成中不能加载 state');
    final spec = _configuredModel;
    if (spec == null) throw StateError('没有已配置的模型');
    if (_info == null) {
      await ensureLoaded(
        spec,
        contextSize: _loadedContext,
        maxContext: _loadedMaxContext,
      );
    }
    await _engine.loadState(path);
  }

  Future<void> clearState() async {
    if (_info == null) return;
    await _engine.clearState();
  }

  Future<void> unload({String reason = 'manual'}) {
    if (_disposed) return Future<void>.value();
    return _serialize(() async {
      if (_generating) throw const SchedulerBusyException('生成中不能卸载');
      if (_info == null) return;
      _setState(SchedulerState.unloading);
      await _engine.unload();
      final old = _model;
      _clearModel();
      _setState(SchedulerState.idle);
      _events.add(ModelUnloadedEvent(old, reason));
    });
  }

  Future<void> onBackground() async {
    if (_disposed) return;
    if (!_policy.unloadOnBackground) return;
    if (_generating) {
      _unloadWhenIdle = true;
      return;
    }
    try {
      await unload(reason: 'background');
    } catch (_) {
      // Background cleanup must never crash the app.
    }
  }

  void onForeground() {
    _unloadWhenIdle = false;
    _touch();
  }

  /// Android `onTrimMemory`: 15=running critical, 20=UI hidden,
  /// 40=background, 60=moderate, 80=complete.
  void onTrimMemory(int level) {
    if (_disposed) return;
    if (level >= 20) {
      unawaited(onBackground());
    } else if (level >= 15) {
      if (_generating) {
        _unloadWhenIdle = true;
      } else {
        unawaited(unload(reason: 'trim-memory'));
      }
    }
  }

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      case GenerationFinished():
        _generating = false;
        _setState(SchedulerState.ready);
        _touch();
        if (_unloadWhenIdle) {
          _unloadWhenIdle = false;
          unawaited(unload(reason: 'deferred'));
        }
      case EngineFailure():
        _generating = false;
        _lastError = event.message;
        _setState(event.fatal ? SchedulerState.failed : SchedulerState.ready);
        _events.add(SchedulerFailureEvent(event.message, fatal: event.fatal));
        _touch();
      case PlanReady():
      case TokenReceived():
      case EngineLoaded():
    }
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    if (_policy.watchdogInterval <= Duration.zero) return;
    _watchdog = Timer.periodic(_policy.watchdogInterval, (_) async {
      if (_disposed || _info == null || _generating) return;
      final memory = await DeviceMemory.read();
      if (memory.availBytes <= 0) return;
      final critical = math.max(512 * 1024 * 1024, _headroomBytes ~/ 2);
      if (memory.availBytes < _headroomBytes) {
        if (!_pressureNotified) {
          _pressureNotified = true;
          _events.add(MemoryPressureEvent(memory.availBytes, _headroomBytes));
        }
      } else {
        _pressureNotified = false;
      }
      if (memory.availBytes < critical) {
        if (_generating) {
          _unloadWhenIdle = true;
        } else {
          try {
            await unload(reason: 'memory-pressure');
          } catch (_) {}
        }
      }
    });
  }

  void _touch() {
    _idleTimer?.cancel();
    if (_info == null ||
        _disposed ||
        _policy.idleUnloadAfter <= Duration.zero) {
      return;
    }
    _idleTimer = Timer(_policy.idleUnloadAfter, () {
      if (_generating) {
        _unloadWhenIdle = true;
        return;
      }
      unawaited(unload(reason: 'idle'));
    });
  }

  void _clearModel() {
    _model = null;
    _info = null;
    _reservedBytes = 0;
    _idleTimer?.cancel();
    _watchdog?.cancel();
  }

  void _setState(SchedulerState state) {
    if (_state == state) return;
    _state = state;
    if (!_events.isClosed) _events.add(SchedulerStateChanged(state));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _idleTimer?.cancel();
    _watchdog?.cancel();
    await _engineSub?.cancel();
    try {
      await _engine.unload();
    } catch (_) {}
    await _engine.dispose();
    _setState(SchedulerState.disposed);
    await _events.close();
  }
}
