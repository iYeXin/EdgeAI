import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../engine/edge_ai.dart';
import '../models/model_manager.dart';
import '../session/session_store.dart';

class InferenceSettings {
  const InferenceSettings({
    this.backend = ComputeBackend.vulkan,
    this.threads = 4,
    this.contextSize = 0,
    this.memoryBudgetMb = 0,
    this.maxTokens = 512,
    this.thinking = false,
  });

  final ComputeBackend backend;
  final int threads;
  final int contextSize;
  final int memoryBudgetMb;
  final int maxTokens;
  final bool thinking;

  InferenceSettings copyWith({
    ComputeBackend? backend,
    int? threads,
    int? contextSize,
    int? memoryBudgetMb,
    int? maxTokens,
    bool? thinking,
  }) {
    return InferenceSettings(
      backend: backend ?? this.backend,
      threads: threads ?? this.threads,
      contextSize: contextSize ?? this.contextSize,
      memoryBudgetMb: memoryBudgetMb ?? this.memoryBudgetMb,
      maxTokens: maxTokens ?? this.maxTokens,
      thinking: thinking ?? this.thinking,
    );
  }
}

/// Small bridge between the chat page (which owns the engine) and the
/// models/settings tabs.
class ChatPageController extends ChangeNotifier {
  SessionStore? store;
  ModelManager? manager;
  String? modelPath;
  String? mmprojPath;
  String? modelName;
  bool loading = false;
  bool loaded = false;
  String? loadError;
  EngineInfo? info;
  InferenceSettings settings = const InferenceSettings();
  VoidCallback? onOpenModels;

  LocalModel? _pendingModel;
  InferenceSettings? _pendingSettings;
  Future<void> Function(LocalModel model)? _selectModel;
  Future<void> Function(InferenceSettings settings)? _applySettings;
  Future<void> Function()? _reload;
  Future<void> Function()? _clearState;

  void bind({
    required SessionStore store,
    required ModelManager manager,
    required InferenceSettings settings,
    required Future<void> Function(LocalModel model) selectModel,
    required Future<void> Function(InferenceSettings settings) applySettings,
    required Future<void> Function() reload,
    required Future<void> Function() clearState,
  }) {
    this.store = store;
    this.manager = manager;
    this.settings = settings;
    _selectModel = selectModel;
    _applySettings = applySettings;
    _reload = reload;
    _clearState = clearState;
    _pendingModel = null;
    _pendingSettings = null;
    notifyListeners();
  }

  void sync({
    String? modelPath,
    String? mmprojPath,
    String? modelName,
    bool? loading,
    bool? loaded,
    String? loadError,
    EngineInfo? info,
    InferenceSettings? settings,
  }) {
    if (modelPath != null) this.modelPath = modelPath;
    if (mmprojPath != null) this.mmprojPath = mmprojPath;
    if (modelName != null) this.modelName = modelName;
    if (loading != null) this.loading = loading;
    if (loaded != null) this.loaded = loaded;
    if (loadError != null) this.loadError = loadError;
    if (info != null) this.info = info;
    if (settings != null) this.settings = settings;
    notifyListeners();
  }

  void clearError() {
    loadError = null;
    notifyListeners();
  }

  void selectModel(LocalModel model) {
    if (_selectModel == null) {
      _pendingModel = model;
    } else {
      _selectModel!(model);
    }
    notifyListeners();
  }

  void applySettings(InferenceSettings value) {
    settings = value;
    if (_applySettings == null) {
      _pendingSettings = value;
    } else {
      _applySettings!(value);
    }
    notifyListeners();
  }

  Future<void> reload() async {
    await _reload?.call();
  }

  Future<void> clearState() async {
    await _clearState?.call();
  }

  LocalModel? get pendingModel => _pendingModel;
  InferenceSettings? get pendingSettings => _pendingSettings;

  void consumePending() {
    final model = _pendingModel;
    final settings = _pendingSettings;
    _pendingModel = null;
    _pendingSettings = null;
    if (model != null) _selectModel?.call(model);
    if (settings != null) _applySettings?.call(settings);
  }
}
