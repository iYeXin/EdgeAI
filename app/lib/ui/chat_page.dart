import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:image_picker/image_picker.dart';

import 'core/app_theme.dart';
import '../engine/edge_ai.dart';
import '../engine/power_monitor.dart';
import '../engine/scheduler.dart';
import '../models/model_manager.dart';
import '../models/model_manager_sheet.dart';
import '../session/session_store.dart';
import '../session/thinking_content.dart';
import 'chat_page_controller.dart';
import 'session_settings_sheet.dart';
import 'widgets/app_components.dart';

const _bg = AppColors.background;
const _surface = AppColors.surface;
const _surfaceHigh = AppColors.surfaceTint;
const _accent = AppColors.primary;
const _accentSoft = AppColors.primaryStrong;
const _text = AppColors.ink;
const _muted = AppColors.muted;
const _danger = AppColors.red;
const _line = AppColors.line;

const _systemPrompt =
    'You are a helpful, concise AI assistant running fully offline on an Android phone. '
    'Answer in the same language as the user. Keep answers short unless asked for detail.';

class _PromptEditResult {
  const _PromptEditResult({required this.text, required this.applyGlobal});

  final String text;
  final bool applyGlobal;
}

class _EditMessageResult {
  const _EditMessageResult({required this.text, required this.images});

  final String text;
  final List<String> images;
}

class ChatMessage {
  ChatMessage.user(
    this.text, {
    this.imagePaths = const <String>[],
    this.nodeId,
    this.parentId,
  }) : role = 'user',
       streaming = false,
       stats = const <String, String>{},
       cancelled = false;

  ChatMessage.assistant({this.nodeId, this.parentId})
    : role = 'assistant',
      text = '',
      imagePaths = const <String>[],
      streaming = true,
      stats = const <String, String>{},
      cancelled = false;

  final String role;
  String text;
  final List<String> imagePaths;
  String? nodeId;
  String? parentId;
  String? get imagePath => imagePaths.isEmpty ? null : imagePaths.first;
  bool streaming;
  bool cancelled;
  Map<String, String> stats;
  String? powerLabel;
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, this.controller});

  final ChatPageController? controller;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  static const _channel = MethodChannel('edge_ai/paths');

  InferenceScheduler? _scheduler;
  late final ChatPageController _pageController;
  SessionStore? _sessionStore;
  ChatSession? _session;
  ModelManager? _modelManager;
  StreamSubscription<EngineEvent>? _subscription;
  StreamSubscription<SchedulerEvent>? _schedulerSub;
  final ScrollController _scroll = ScrollController();
  final TextEditingController _input = TextEditingController();
  final List<ChatMessage> _messages = <ChatMessage>[];
  Timer? _powerTimer;
  Timer? _generationWatchdog;
  final List<PowerReading> _powerReadings = <PowerReading>[];
  DateTime? _firstTokenAt;
  double? _idleWatts;

  bool _booting = true;
  String? _fatalError;
  String _modelDir = '';
  String? _modelPath;
  String? _mmprojPath;
  int _modelBytes = 0;
  String? _pendingImagePath;
  final List<String> _pendingImagePaths = <String>[];

  bool _loading = false;
  bool _loaded = false;
  String? _loadError;
  bool _generating = false;
  bool _pickingImage = false;

  ComputeBackend _backend = ComputeBackend.vulkan;
  int _threads = 4;
  int _contextSize = 0;
  int _memoryBudgetMb = 0;
  int _maxTokens = 512;
  bool _thinking = false;
  String _globalSystemPrompt = _systemPrompt;

  String _backendInfo = '';
  String _modelDesc = '';
  Map<String, String> _modelParams = const <String, String>{};
  EngineInfo? _info;
  ContextPlan? _lastPlan;
  bool _stateLoadedForCurrent = false;
  Future<void>? _stateSaveFuture;

  @override
  void initState() {
    super.initState();
    _pageController = widget.controller ?? ChatPageController();
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onTrimMemory') {
        final level = (call.arguments as num?)?.toInt() ?? 0;
        _scheduler?.onTrimMemory(level);
      }
    });
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _powerTimer?.cancel();
    _generationWatchdog?.cancel();
    _subscription?.cancel();
    _schedulerSub?.cancel();
    _scheduler?.dispose();
    _scroll.dispose();
    _input.dispose();
    if (widget.controller == null) _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _saveSession();
      _scheduler?.onBackground();
    } else if (state == AppLifecycleState.resumed) {
      _scheduler?.onForeground();
    }
  }

  Future<void> _bootstrap() async {
    try {
      final engine = await EdgeAiEngine.spawn();
      if (!mounted) {
        await engine.dispose();
        return;
      }
      final requestedBackend = await _channel.invokeMethod<String>(
        'getLaunchBackend',
      );
      if (requestedBackend == 'cpu') _backend = ComputeBackend.cpu;
      if (requestedBackend == 'vulkan') _backend = ComputeBackend.vulkan;
      final scheduler = InferenceScheduler(
        engine,
        policy: SchedulerPolicy(
          backend: _backend,
          threads: _threads,
          maxContext: 32768,
        ),
      );
      _scheduler = scheduler;
      _subscription = scheduler.generationEvents.listen(_onEngineEvent);
      _schedulerSub = scheduler.events.listen(_onSchedulerEvent);
      final launchImage = await _channel.invokeMethod<String>('getLaunchImage');
      if (launchImage != null && launchImage.isNotEmpty) {
        for (final path in launchImage.split(';')) {
          if (path.isNotEmpty && _pendingImagePaths.length < 4) {
            _pendingImagePaths.add(path);
          }
        }
        _pendingImagePath = _pendingImagePaths.isEmpty
            ? null
            : _pendingImagePaths.first;
      }
      await _resolveModel();
      final store = await SessionStore.open(_channel);
      _sessionStore = store;
      _thinking = store.thinkingEnabled;
      final storedPrompt = store.globalSystemPrompt?.trim();
      _globalSystemPrompt = (storedPrompt == null || storedPrompt.isEmpty)
          ? _systemPrompt
          : storedPrompt;
      if (_modelManager != null) {
        _pageController.bind(
          store: store,
          manager: _modelManager!,
          settings: InferenceSettings(
            backend: _backend,
            threads: _threads,
            contextSize: _contextSize,
            memoryBudgetMb: _memoryBudgetMb,
            maxTokens: _maxTokens,
            thinking: _thinking,
          ),
          selectModel: _selectModelFromPage,
          applySettings: _applySettingsFromPage,
          reload: _loadModel,
          clearState: () async => _scheduler?.clearState(),
        );
        _pageController.sync(
          modelPath: _modelPath,
          mmprojPath: _mmprojPath,
          modelName: _modelName,
          loading: _loading,
          loaded: _loaded,
        );
        _pageController.consumePending();
      }
      if (!store.stateCacheConfigured) {
        final free =
            (await _channel.invokeMethod<num>('getFreeBytes'))?.toInt() ?? 0;
        const fourGb = 4 * 1024 * 1024 * 1024;
        final availableLimit = free > 0 ? free - (1024 * 1024 * 1024) : fourGb;
        final limit = availableLimit < fourGb ? availableLimit : fourGb;
        final maxBytes = limit < 512 * 1024 * 1024 ? 512 * 1024 * 1024 : limit;
        final enabled = free == 0 || free >= 2 * 1024 * 1024 * 1024;
        await store.setStateCachePolicy(enabled: enabled, maxBytes: maxBytes);
      }
      _session =
          store.byId(store.activeId ?? '') ??
          (store.sessions.isNotEmpty
              ? store.sessions.first
              : _createSession(store));
      await store.setActive(_session!.id);
      _restoreSession(_session!);
      final preferred = _session!.modelPath;
      if (preferred != null &&
          File(preferred).existsSync() &&
          preferred != _modelPath) {
        final models = await _modelManager!.scan();
        final match = models.where((m) => m.path == preferred).firstOrNull;
        if (match != null) {
          _modelPath = match.path;
          _mmprojPath = match.mmprojPath;
          _modelBytes = match.size;
        }
      }
      if (_modelPath != null) {
        unawaited(_loadModel());
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _fatalError = error.toString();
          _booting = false;
        });
      }
    }
  }

  Future<void> _resolveModel() async {
    try {
      final dir = await _channel.invokeMethod<String>('getModelDir');
      if (dir == null) {
        throw StateError('No app storage directory');
      }
      _modelDir = dir;
      final manager = ModelManager(Directory(dir));
      await manager.ensureReady();
      _modelManager = manager;
      final models = await manager.scan();
      if (models.isNotEmpty) {
        _modelPath = models.first.path;
        _mmprojPath = models.first.mmprojPath;
        _modelBytes = models.first.size;
      }
    } catch (error) {
      _fatalError = 'Cannot access model directory: $error';
    } finally {
      if (mounted) setState(() => _booting = false);
    }
  }

  Future<void> _selectModelFromPage(LocalModel selected) async {
    if (selected.path == _modelPath && _loaded) return;
    await _scheduler?.unload(reason: 'switch-model');
    setState(() {
      _modelPath = selected.path;
      _mmprojPath = selected.mmprojPath;
      _modelBytes = selected.size;
      _loaded = false;
      _info = null;
    });
    _pageController.sync(
      modelPath: _modelPath,
      mmprojPath: _mmprojPath,
      modelName: _modelName,
      loading: true,
      loaded: false,
    );
    await _loadModel();
  }

  void _setThinking(bool value) {
    setState(() => _thinking = value);
    unawaited(_sessionStore?.setThinkingEnabled(value));
    _pageController.sync(
      settings: _pageController.settings.copyWith(thinking: value),
    );
  }

  Future<void> _applySettingsFromPage(InferenceSettings value) async {
    final requiresReload =
        value.backend != _backend ||
        value.threads != _threads ||
        value.contextSize != _contextSize ||
        value.memoryBudgetMb != _memoryBudgetMb;
    setState(() {
      _backend = value.backend;
      _threads = value.threads;
      _contextSize = value.contextSize;
      _memoryBudgetMb = value.memoryBudgetMb;
      _maxTokens = value.maxTokens;
      _thinking = value.thinking;
    });
    await _sessionStore?.setThinkingEnabled(value.thinking);
    _pageController.sync(settings: value);
    if (requiresReload && _modelPath != null) {
      await _loadModel();
    }
  }

  Future<void> _openModels() async {
    final manager = _modelManager;
    if (manager == null) return;
    if (_generating) return;
    final selected = await showModalBottomSheet<LocalModel>(
      context: context,
      backgroundColor: _surface,
      useSafeArea: true,
      barrierColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) =>
          ModelManagerSheet(manager: manager, currentPath: _modelPath),
    );
    if (selected == null || !mounted) return;
    if (selected.path == _modelPath) return;
    await _scheduler?.unload(reason: 'switch-model');
    setState(() {
      _modelPath = selected.path;
      _mmprojPath = selected.mmprojPath;
      _modelBytes = selected.size;
      _loaded = false;
      _info = null;
    });
    await _loadModel();
  }

  int _nodeSeq = 0;

  ChatMessage _chatFromStored(StoredMessage stored) {
    if (stored.role == 'assistant') {
      return ChatMessage.assistant(nodeId: stored.id, parentId: stored.parentId)
        ..text = stored.text
        ..streaming = false
        ..stats = Map<String, String>.from(stored.stats);
    }
    return ChatMessage.user(
      stored.text,
      imagePaths: stored.imagePaths,
      nodeId: stored.id,
      parentId: stored.parentId,
    )..stats = Map<String, String>.from(stored.stats);
  }

  void _restoreSession(ChatSession session) {
    _messages.clear();
    var leaf = session.activeLeafId;
    if (session.pathTo(leaf).isEmpty && session.messages.isNotEmpty) {
      final roots = session.childrenOf(null);
      if (roots.isNotEmpty) {
        leaf = session.latestLeaf(roots.first.id);
        session.activeLeafId = leaf;
      }
    }
    for (final stored in session.pathTo(leaf)) {
      _messages.add(_chatFromStored(stored));
    }
  }

  void _setPathTo(String? leafId, {bool streamLast = false}) {
    final session = _session;
    if (session == null) return;
    _messages.clear();
    for (final stored in session.pathTo(leafId)) {
      _messages.add(_chatFromStored(stored));
    }
    if (streamLast &&
        _messages.isNotEmpty &&
        _messages.last.role == 'assistant') {
      _messages.last
        ..streaming = true
        ..text = '';
    }
    session.activeLeafId = leafId;
  }

  StoredMessage _newNode({
    required String role,
    required String text,
    required String? parentId,
    List<String> imagePaths = const <String>[],
  }) {
    final session = _session!;
    final node = StoredMessage(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_nodeSeq++}',
      parentId: parentId,
      role: role,
      text: text,
      imagePaths: imagePaths,
    );
    session.messages.add(node);
    return node;
  }

  String _titleForSession(ChatSession session) {
    for (final message in session.activePath) {
      if (message.role == 'user' && message.text.trim().isNotEmpty) {
        final text = message.text.trim().replaceAll(RegExp(r'\s+'), ' ');
        return text.length > 32 ? '${text.substring(0, 32)}...' : text;
      }
    }
    return session.activePath.any((m) => m.imagePaths.isNotEmpty)
        ? '图片对话'
        : 'New chat';
  }

  Future<void> _saveSession() async {
    final store = _sessionStore;
    final session = _session;
    if (store == null || session == null) return;
    for (final message in _messages) {
      final node = session.nodeById(message.nodeId);
      if (node == null) continue;
      node.text = message.text;
      node.stats = Map<String, String>.from(message.stats);
    }
    session.activeLeafId = _messages.isEmpty ? null : _messages.last.nodeId;
    session.modelPath = _modelPath;
    session.title = _titleForSession(session);
    await store.save(session);
  }

  Future<void> _switchSession(ChatSession next) async {
    if (_generating) return;
    await _saveSession();
    final store = _sessionStore;
    if (store == null) return;
    await _scheduler?.clearState();
    setState(() {
      _session = next;
      _lastPlan = null;
      _stateLoadedForCurrent = false;
      _restoreSession(next);
    });
    await store.setActive(next.id);
    final preferred = next.modelPath;
    if (preferred != null &&
        preferred != _modelPath &&
        File(preferred).existsSync()) {
      final manager = _modelManager;
      if (manager == null) return;
      final models = await manager.scan();
      final match = models.where((m) => m.path == preferred).firstOrNull;
      if (match != null) {
        setState(() {
          _modelPath = match.path;
          _mmprojPath = match.mmprojPath;
          _modelBytes = match.size;
        });
        await _loadModel();
      }
    }
    if (preferred == null || preferred == _modelPath) {
      unawaited(_preloadStateCache());
    }
  }

  ChatSession _createSession(SessionStore store) {
    final session = store.create(modelPath: _modelPath);
    session.systemPrompt = _globalSystemPrompt;
    return session;
  }

  Future<void> _newSession() async {
    if (_generating) return;
    final store = _sessionStore;
    if (store == null) return;
    await _saveSession();
    final session = _createSession(store);
    await _scheduler?.clearState();
    setState(() {
      _session = session;
      _messages.clear();
      _lastPlan = null;
      _stateLoadedForCurrent = false;
      _pendingImagePath = null;
      _pendingImagePaths.clear();
    });
    await store.setActive(session.id);
  }

  Future<void> _deleteSession(ChatSession session) async {
    final store = _sessionStore;
    if (store == null || _generating) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _surface,
        title: const Text('删除会话？'),
        content: Text(
          session.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await store.delete(session.id);
    if (_session?.id == session.id) {
      final next = store.sessions.isNotEmpty
          ? store.sessions.first
          : _createSession(store);
      setState(() {
        _session = next;
        _restoreSession(next);
      });
      await store.setActive(next.id);
    } else {
      setState(() {});
    }
  }

  Future<void> _openSessions() async {
    final store = _sessionStore;
    if (store == null) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _surface,
      useSafeArea: true,
      barrierColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.65,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                      child: Row(
                        children: [
                          const Text(
                            '会话',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: () async {
                              Navigator.pop(sheetContext);
                              await _newSession();
                            },
                            icon: const Icon(Icons.add_rounded, size: 18),
                            label: const Text('新会话'),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(sheetContext);
                              _openSessionSettings();
                            },
                            child: const Text('参数'),
                          ),
                          if (_messages.isNotEmpty)
                            IconButton(
                              tooltip: '清空当前会话',
                              onPressed: () async {
                                Navigator.pop(sheetContext);
                                await _clearChat();
                              },
                              icon: const Icon(
                                Icons.delete_sweep_outlined,
                                color: _muted,
                                size: 20,
                              ),
                            ),
                          IconButton(
                            onPressed: () => Navigator.pop(sheetContext),
                            icon: const Icon(
                              Icons.close_rounded,
                              color: _muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: store.sessions.length,
                        separatorBuilder: (_, _) =>
                            const Divider(color: _line, height: 1),
                        itemBuilder: (context, index) {
                          final session = store.sessions[index];
                          final selected = session.id == _session?.id;
                          return ListTile(
                            selected: selected,
                            selectedTileColor: _surfaceHigh,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            title: Text(
                              session.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: selected ? _accentSoft : _text,
                                fontWeight: selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                            subtitle: Text(
                              '${session.activePath.length} 条消息 · ${_formatSessionTime(session.updatedAt)}',
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 11,
                              ),
                            ),
                            onTap: () {
                              Navigator.pop(sheetContext);
                              if (!selected) _switchSession(session);
                            },
                            trailing: IconButton(
                              onPressed: () async {
                                await _deleteSession(session);
                                if (sheetContext.mounted) setSheetState(() {});
                              },
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 19,
                                color: _muted,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _formatSessionTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    return '${time.month}/${time.day}';
  }

  String get _modelName {
    final path = _modelPath;
    if (path == null || path.isEmpty) {
      return _modelDesc.isEmpty ? 'Edge model' : _modelDesc;
    }
    final file = path.split(Platform.pathSeparator).last;
    return file.toLowerCase().endsWith('.gguf')
        ? file.substring(0, file.length - 5)
        : file;
  }

  Future<void> _loadModel() async {
    final scheduler = _scheduler;
    final path = _modelPath;
    if (scheduler == null || path == null) return;
    setState(() {
      _loading = true;
      _loaded = false;
      _loadError = null;
      _idleWatts = null;
      _lastPlan = null;
      _stateLoadedForCurrent = false;
    });
    _pageController.sync(
      modelPath: path,
      mmprojPath: _mmprojPath,
      modelName: _modelName,
      loading: true,
      loaded: false,
      loadError: null,
    );
    try {
      scheduler.updatePolicy(
        SchedulerPolicy(
          backend: _backend,
          threads: _threads,
          maxContext: _mmprojPath != null
              ? 4096
              : (_contextSize == 0 ? 32768 : _contextSize),
        ),
      );
      final visionCap = _mmprojPath != null && _contextSize == 0
          ? 4096
          : _contextSize;
      final info = await scheduler.ensureLoaded(
        ModelSpec(id: path, path: path, mmprojPath: _mmprojPath),
        contextSize: visionCap,
        maxContext: _mmprojPath != null
            ? 4096
            : (_contextSize == 0 ? 32768 : _contextSize),
        memoryBudgetBytes: _memoryBudgetMb > 0
            ? _memoryBudgetMb * 1024 * 1024
            : null,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loaded = true;
        _loadError = null;
        _info = info;
        _session?.modelPath = path;
        _backend = info.backend.toLowerCase().contains('vulkan')
            ? ComputeBackend.vulkan
            : ComputeBackend.cpu;
        _backendInfo = info.backend;
        _modelDesc = info.desc;
        _modelParams = <String, String>{
          'params': '${info.nParams}',
          'size_mb': '${(info.modelBytes / (1024 * 1024)).round()}',
          'ctx': '${info.nCtx}',
          'ngl': '${info.nGpuLayers}',
          'gpu_offload': info.isGpu ? '1' : '0',
          'kv_mb': '${(info.kvBytes / (1024 * 1024)).round()}',
        };
      });
      unawaited(_saveSession());
      _pageController.sync(
        modelPath: path,
        mmprojPath: _mmprojPath,
        modelName: _modelName,
        loading: false,
        loaded: true,
        loadError: null,
        info: info,
        settings: InferenceSettings(
          backend: _backend,
          threads: _threads,
          contextSize: _contextSize,
          memoryBudgetMb: _memoryBudgetMb,
          maxTokens: _maxTokens,
          thinking: _thinking,
        ),
      );
      _captureIdleBaselineAndPrompt();
      unawaited(_preloadStateCache());
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = error.toString();
        });
        _pageController.sync(
          loading: false,
          loaded: false,
          loadError: error.toString(),
        );
      }
    }
  }

  void _onSchedulerEvent(SchedulerEvent event) {
    if (!mounted) return;
    switch (event) {
      case MemoryPressureEvent():
        _showError('内存偏紧：后台切换会立即卸载模型，临界时会强制释放');
      case ModelUnloadedEvent():
        _stateLoadedForCurrent = false;
        break;
      case SchedulerFailureEvent():
        break;
      case ModelLoadedEvent():
      case SchedulerStateChanged():
        break;
    }
  }

  void _onEngineEvent(EngineEvent event) {
    if (!mounted) return;
    switch (event) {
      case EngineLoaded():
        setState(() {
          _info = event.info;
          _backendInfo = event.info.backend;
          _modelDesc = event.info.desc;
        });
      case PlanReady():
        _lastPlan = event.plan;
        setState(() {});
        if (event.plan.droppedMessages > 0) {
          _showError('上下文不足，已裁剪 ${event.plan.droppedMessages} 条较早消息');
        }
      case TokenReceived():
        if (_messages.isEmpty) return;
        final last = _messages.last;
        if (last.role != 'assistant' || !last.streaming) return;
        _firstTokenAt ??= DateTime.now();
        setState(() => last.text += event.text);
        _scrollToBottom(animate: false);
      case GenerationFinished():
        _powerTimer?.cancel();
        _powerTimer = null;
        _generationWatchdog?.cancel();
        final stats = event.stats;
        if (_messages.isNotEmpty) {
          final last = _messages.last;
          if (last.role == 'assistant' && last.streaming) {
            last.streaming = false;
            last.cancelled = stats.stopReason == StopReason.cancelled;
            last.stats = <String, String>{
              'backend': _info?.backend ?? _backendInfo,
              'tok_s': stats.tokensPerSecond.toStringAsFixed(2),
              'tokens': '${stats.generatedTokens}',
              'prefill_ms': '${stats.prefillMs}',
              'dropped': '${_lastPlan?.droppedMessages ?? 0}',
            };
            if (last.text.trim().isEmpty) {
              last.text = last.cancelled
                  ? 'Generation stopped.'
                  : 'No output was produced.';
            }
            _attachPowerStats(last);
          }
        }
        setState(() => _generating = false);
        _scrollToBottom();
        unawaited(_saveSession());
        _stateSaveFuture = _saveStateAfterGeneration();
      case EngineFailure():
        _powerTimer?.cancel();
        _powerTimer = null;
        _generationWatchdog?.cancel();
        if (_messages.isNotEmpty) {
          final last = _messages.last;
          if (last.role == 'assistant' && last.streaming) {
            last.streaming = false;
            last.cancelled = true;
            if (last.text.trim().isEmpty) {
              last.text = 'Inference failed.\n\n${event.message}';
            } else {
              last.text = '${last.text}\n\n[error] ${event.message}';
            }
          }
        }
        setState(() {
          _generating = false;
        });
        _showError(event.message);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, maxLines: 4, overflow: TextOverflow.ellipsis),
        backgroundColor: AppColors.primaryDeep,
      ),
    );
  }

  Future<void> _pickImage() async {
    final paths = await _pickImagesFromGallery();
    if (!mounted || paths.isEmpty) return;
    setState(() {
      for (final path in paths) {
        if (_pendingImagePaths.length >= 4) break;
        if (!_pendingImagePaths.contains(path)) {
          _pendingImagePaths.add(path);
        }
      }
      _pendingImagePath = _pendingImagePaths.isEmpty
          ? null
          : _pendingImagePaths.first;
    });
  }

  Future<List<String>> _pickImagesFromGallery() async {
    if (_pickingImage) return const <String>[];
    _pickingImage = true;
    if (mounted) setState(() {});
    try {
      final compress = _sessionStore?.imageCompressionEnabled ?? true;
      final maxWidth = (_sessionStore?.imageMaxWidth ?? 1024).toDouble();
      final picked = await ImagePicker().pickMultiImage(
        maxWidth: compress ? maxWidth : null,
        imageQuality: compress ? 88 : null,
      );
      return picked.map((file) => file.path).toList();
    } on PlatformException catch (error) {
      if (error.code == 'already_active') {
        _showError('相册正在打开，请稍后再试。');
      } else {
        _showError('无法打开相册：${error.message ?? error.code}');
      }
      return const <String>[];
    } catch (_) {
      _showError('无法打开相册，请稍后再试。');
      return const <String>[];
    } finally {
      _pickingImage = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _openImagePreview(String path) async {
    if (!File(path).existsSync()) {
      _showError('图片文件不存在');
      return;
    }
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.94),
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 5,
                child: Image.file(File(path), fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                onPressed: () => Navigator.pop(dialogContext),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black54,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadStateIfNeeded() async {
    final store = _sessionStore;
    final session = _session;
    final scheduler = _scheduler;
    if (store == null || session == null || scheduler == null) return;
    if (!store.stateCacheEnabled || _stateLoadedForCurrent) return;
    final path = session.statePath;
    final info = _info;
    if (path == null ||
        session.stateModelPath != _modelPath ||
        session.stateMmprojPath != _mmprojPath ||
        !File(path).existsSync()) {
      return;
    }
    if (info == null) return;
    // Do not reject on saved context size alone. A state file only contains
    // the KV cells that were actually used; the native loader checks those
    // cells against the current n_ctx and fails safely if they do not fit.
    try {
      await scheduler.loadState(path);
      _stateLoadedForCurrent = true;
      debugPrint(
        'state cache loaded: ${session.stateTokens} tokens, saved ctx ${session.stateCtx}, current ctx ${info.nCtx}',
      );
    } catch (error) {
      _stateLoadedForCurrent = false;
      debugPrint('state cache load failed: $error');
    }
  }

  Future<void> _preloadStateCache() async {
    if (!mounted || _info == null || _generating) return;
    final store = _sessionStore;
    if (store == null || !store.stateCacheEnabled) return;
    await _loadStateIfNeeded();
  }

  Future<void> _saveStateAfterGeneration() async {
    final store = _sessionStore;
    final session = _session;
    final scheduler = _scheduler;
    if (store == null || session == null || scheduler == null) return;
    if (!store.stateCacheEnabled || _info == null) return;
    final path = store.statePathFor(session.id);
    try {
      final bytes = await scheduler.stateSize();
      if (bytes <= 0 || bytes > store.stateCacheMaxBytes) {
        final old = File(path);
        if (await old.exists()) await old.delete();
        session.statePath = null;
        session.stateBytes = 0;
        session.stateTokens = 0;
        session.stateModelPath = null;
        session.stateMmprojPath = null;
        session.stateCtx = 0;
        session.stateUpdatedAt = null;
        await store.save(session);
        return;
      }
      final free =
          (await _channel.invokeMethod<num>('getFreeBytes'))?.toInt() ?? 0;
      if (free > 0 && bytes + 512 * 1024 * 1024 > free) {
        return;
      }
      await File(path).parent.create(recursive: true);
      await scheduler.saveState(path);
      session.statePath = path;
      session.stateBytes = bytes;
      session.stateTokens = _lastPlan?.promptTokens ?? 0;
      session.stateModelPath = _modelPath;
      session.stateMmprojPath = _mmprojPath;
      session.stateCtx = _info?.nCtx ?? 0;
      session.stateUpdatedAt = DateTime.now();
      await store.save(session);
      await store.evictStateCache(store.stateCacheMaxBytes);
    } catch (_) {
      _stateLoadedForCurrent = false;
    }
  }

  Future<void> _send() async {
    final scheduler = _scheduler;
    final text = _input.text.trim();
    final images = <String>[
      ..._pendingImagePaths,
      if (_pendingImagePaths.isEmpty && _pendingImagePath != null)
        _pendingImagePath!,
    ];
    if (scheduler == null || !_loaded || _generating) return;
    if (text.isEmpty && images.isEmpty) return;
    if (images.isNotEmpty && !(_info?.hasVision ?? false)) {
      _showError('当前模型没有加载视觉投影，无法理解图片');
      return;
    }

    final storedImages = <String>[];
    for (final image in images) {
      var stored = image;
      if (_sessionStore != null && _session != null) {
        try {
          stored = await _sessionStore!.importImage(image, _session!.id);
        } catch (_) {}
      }
      storedImages.add(stored);
    }

    if (_session == null) return;
    final parentId = _messages.isEmpty ? null : _messages.last.nodeId;
    final userNode = _newNode(
      role: 'user',
      text: text,
      parentId: parentId,
      imagePaths: storedImages,
    );
    final assistantNode = _newNode(
      role: 'assistant',
      text: '',
      parentId: userNode.id,
    );
    _session!.activeLeafId = assistantNode.id;
    setState(() {
      _messages.add(
        ChatMessage.user(
          text,
          imagePaths: storedImages,
          nodeId: userNode.id,
          parentId: userNode.parentId,
        ),
      );
      _messages.add(
        ChatMessage.assistant(
          nodeId: assistantNode.id,
          parentId: assistantNode.parentId,
        ),
      );
      _generating = true;
      _pendingImagePath = null;
      _pendingImagePaths.clear();
    });
    _input.clear();
    await _startGeneration();
  }

  Future<void> _startGeneration() async {
    final scheduler = _scheduler;
    final session = _session;
    if (scheduler == null || session == null) return;
    _scrollToBottom();
    _startPowerSampling();
    _lastPlan = null;
    _generationWatchdog?.cancel();
    _generationWatchdog = Timer(const Duration(seconds: 60), () {
      if (!_generating || !mounted) return;
      _scheduler?.cancel();
      final last = _messages.isEmpty ? null : _messages.last;
      if (last != null && last.role == 'assistant' && last.streaming) {
        setState(() {
          last.streaming = false;
          last.cancelled = true;
          if (last.text.trim().isEmpty) last.text = '生成超时，已停止。';
          _generating = false;
        });
        unawaited(_saveSession());
      }
    });
    await _saveSession();

    final turns = <ChatTurn>[
      ChatTurn(
        'system',
        (session.systemPrompt?.trim().isNotEmpty ?? false)
            ? session.systemPrompt!.trim()
            : _systemPrompt,
      ),
      ..._messages
          .where((m) => m.text.trim().isNotEmpty || m.imagePaths.isNotEmpty)
          .map((m) => ChatTurn(m.role, m.text, imagePaths: m.imagePaths)),
    ];
    final pendingStateSave = _stateSaveFuture;
    if (pendingStateSave != null) await pendingStateSave;
    await _loadStateIfNeeded();
    try {
      await scheduler.generate(
        ChatRequest(
          messages: turns,
          params: GenerationParams(
            maxTokens: session.maxTokens ?? _maxTokens,
            temperature: session.temperature ?? 0.7,
            topP: session.topP ?? 0.95,
            topK: session.topK ?? 40,
            repeatPenalty: session.repeatPenalty ?? 1.1,
          ),
          enableThinking: _thinking,
        ),
      );
    } catch (error) {
      setState(() => _generating = false);
      _showError('Failed to start generation: $error');
    }
  }

  Future<void> _stop() async {
    await _scheduler?.cancel();
  }

  Future<void> _copyMessage(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制'),
        backgroundColor: AppColors.primaryDeep,
      ),
    );
  }

  Widget _messageFooter(ChatMessage message) {
    final session = _session;
    final node = message.nodeId == null
        ? null
        : session?.nodeById(message.nodeId!);
    if (session == null || node == null || message.streaming) {
      return const SizedBox.shrink();
    }
    final siblings = session.siblingsOf(node);
    final index = siblings.indexWhere((item) => item.id == node.id);
    final isUser = message.role == 'user';
    final actions = <Widget>[
      if (!isUser)
        _footerAction(
          icon: Icons.refresh_rounded,
          tooltip: '重新生成',
          onPressed: _generating ? null : () => _regenerateMessage(node),
        ),
      _footerAction(
        icon: Icons.content_copy_rounded,
        tooltip: '复制',
        onPressed: () => _copyMessage(
          isUser ? node.text : ThinkingContent.parse(node.text).answer,
        ),
      ),
      if (isUser)
        _footerAction(
          icon: Icons.edit_outlined,
          tooltip: '编辑',
          onPressed: _generating ? null : () => _editMessage(node),
        ),
      if (siblings.length > 1) ...[
        _footerAction(
          icon: Icons.chevron_left_rounded,
          tooltip: '上一个分支',
          onPressed: index > 0 ? () => _moveBranch(node, -1) : null,
        ),
        _footerAction(
          icon: Icons.chevron_right_rounded,
          tooltip: '下一个分支',
          onPressed: index >= 0 && index < siblings.length - 1
              ? () => _moveBranch(node, 1)
              : null,
        ),
        _footerAction(
          icon: Icons.account_tree_outlined,
          tooltip: '选择分支',
          onPressed: _generating ? null : () => _switchBranch(node),
        ),
      ],
    ];
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 1, bottom: 3),
        child: Row(mainAxisSize: MainAxisSize.min, children: actions),
      ),
    );
  }

  Widget _footerAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      icon: Icon(icon, size: 16, color: AppColors.muted),
    );
  }

  Future<void> _moveBranch(StoredMessage node, int delta) async {
    final session = _session;
    if (session == null || _generating) return;
    final siblings = session.siblingsOf(node);
    final index = siblings.indexWhere((item) => item.id == node.id);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= siblings.length) return;
    await _saveSession();
    final leaf = session.latestLeaf(siblings[target].id);
    if (leaf == null) return;
    await _scheduler?.clearState();
    _stateLoadedForCurrent = false;
    setState(() {
      _setPathTo(leaf);
      _lastPlan = null;
    });
    await _saveSession();
    unawaited(_preloadStateCache());
  }

  Future<void> _showMessageActions(ChatMessage message) async {
    final session = _session;
    final node = session?.nodeById(message.nodeId);
    if (session == null || node == null || _generating) return;
    final siblings = session.siblingsOf(node);
    final index = siblings.indexWhere((m) => m.id == node.id) + 1;

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _surface,
      useSafeArea: true,
      barrierColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
              child: Row(
                children: [
                  const Text('消息操作', style: AppText.title),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded, color: AppColors.primary),
              title: const Text('复制文本'),
              onTap: () => Navigator.pop(sheetContext, 'copy'),
            ),
            if (node.role == 'user')
              ListTile(
                leading: const Icon(
                  Icons.edit_rounded,
                  color: AppColors.primary,
                ),
                title: const Text('编辑并新建分支'),
                subtitle: const Text('原分支保留，新分支从这里继续'),
                onTap: () => Navigator.pop(sheetContext, 'edit'),
              ),
            if (node.role == 'assistant')
              ListTile(
                leading: const Icon(
                  Icons.refresh_rounded,
                  color: AppColors.primary,
                ),
                title: const Text('重新生成'),
                subtitle: const Text('在同一个提问下生成新的回答分支'),
                onTap: () => Navigator.pop(sheetContext, 'regenerate'),
              ),
            if (siblings.length > 1)
              ListTile(
                leading: const Icon(
                  Icons.account_tree_rounded,
                  color: AppColors.primary,
                ),
                title: Text('切换分支（$index/${siblings.length}）'),
                onTap: () => Navigator.pop(sheetContext, 'branch'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'copy':
        await _copyMessage(
          node.role == 'user'
              ? node.text
              : ThinkingContent.parse(node.text).answer,
        );
        break;
      case 'edit':
        await _editMessage(node);
        break;
      case 'regenerate':
        await _regenerateMessage(node);
        break;
      case 'branch':
        await _switchBranch(node);
        break;
    }
  }

  Future<void> _editMessage(StoredMessage node) async {
    if (_generating) return;
    final controller = TextEditingController(text: node.text);
    final images = List<String>.of(node.imagePaths);
    var picking = false;

    final result = await showModalBottomSheet<_EditMessageResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Text(
                      '编辑消息',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close_rounded, color: _muted),
                    ),
                  ],
                ),
                TextField(
                  controller: controller,
                  autofocus: true,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    hintText: '输入新的内容',
                    alignLabelWithHint: true,
                  ),
                ),
                if (images.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < images.length; i++)
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            GestureDetector(
                              onTap: () => _openImagePreview(images[i]),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(9),
                                child: Image.file(
                                  File(images[i]),
                                  width: 72,
                                  height: 72,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                            Positioned(
                              right: -5,
                              top: -5,
                              child: GestureDetector(
                                onTap: () =>
                                    setSheetState(() => images.removeAt(i)),
                                child: Container(
                                  decoration: const BoxDecoration(
                                    color: Colors.black87,
                                    shape: BoxShape.circle,
                                  ),
                                  padding: const EdgeInsets.all(2),
                                  child: const Icon(
                                    Icons.close_rounded,
                                    size: 13,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: picking || images.length >= 4
                      ? null
                      : () async {
                          setSheetState(() => picking = true);
                          final paths = await _pickImagesFromGallery();
                          if (!sheetContext.mounted) return;
                          setSheetState(() {
                            for (final path in paths) {
                              if (images.length >= 4) break;
                              if (!images.contains(path)) images.add(path);
                            }
                            picking = false;
                          });
                        },
                  icon: picking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(
                          Icons.add_photo_alternate_outlined,
                          size: 18,
                        ),
                  label: Text(
                    images.length >= 4 ? '最多 4 张图片' : '添加图片',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          final text = controller.text.trim();
                          if (text.isEmpty && images.isEmpty) return;
                          Navigator.pop(
                            sheetContext,
                            _EditMessageResult(
                              text: text,
                              images: List<String>.of(images),
                            ),
                          );
                        },
                        child: const Text('生成'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    controller.dispose();
    if (!mounted || result == null || _generating) return;
    if (result.text.isEmpty && result.images.isEmpty) return;
    final user = _newNode(
      role: 'user',
      text: result.text,
      parentId: node.parentId,
      imagePaths: result.images,
    );
    final assistant = _newNode(role: 'assistant', text: '', parentId: user.id);
    setState(() {
      _setPathTo(assistant.id, streamLast: true);
      _generating = true;
      _lastPlan = null;
    });
    await _startGeneration();
  }

  Future<void> _regenerateMessage(StoredMessage node) async {
    if (_generating) return;
    final assistant = _newNode(
      role: 'assistant',
      text: '',
      parentId: node.parentId,
    );
    setState(() {
      _setPathTo(assistant.id, streamLast: true);
      _generating = true;
      _lastPlan = null;
    });
    await _startGeneration();
  }

  Future<void> _switchBranch(StoredMessage node) async {
    final session = _session;
    if (session == null || _generating) return;
    final siblings = session.siblingsOf(node);
    final choice = await showModalBottomSheet<StoredMessage>(
      context: context,
      backgroundColor: _surface,
      useSafeArea: true,
      barrierColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
              child: Row(
                children: [
                  const Text('切换分支', style: AppText.title),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
            for (final sibling in siblings)
              ListTile(
                title: Text(
                  sibling.text.trim().isEmpty ? '（空消息）' : sibling.text.trim(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(sibling.id == node.id ? '当前分支' : '切换到此分支'),
                trailing: sibling.id == node.id
                    ? const Icon(Icons.check_rounded, color: AppColors.primary)
                    : null,
                onTap: () => Navigator.pop(sheetContext, sibling),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || choice == null || choice.id == node.id) return;
    final leaf = session.latestLeaf(choice.id);
    if (leaf == null) return;
    await _scheduler?.clearState();
    _stateLoadedForCurrent = false;
    setState(() {
      _setPathTo(leaf);
      _lastPlan = null;
    });
    await _saveSession();
    unawaited(_preloadStateCache());
  }

  void _startPowerSampling() {
    _powerTimer?.cancel();
    _powerReadings.clear();
    _firstTokenAt = null;
    _powerTimer = Timer.periodic(const Duration(milliseconds: 250), (_) async {
      if (!mounted || !_generating) return;
      final snapshot = await PowerSnapshot.read(_channel);
      if (snapshot != null && mounted && _generating) {
        _powerReadings.add(PowerReading(DateTime.now(), snapshot));
      }
    });
  }

  void _attachPowerStats(ChatMessage message) {
    final store = _sessionStore;
    if (store == null || !store.powerStatsEnabled) return;
    final first = _firstTokenAt;
    if (first == null) return;
    final readings = _powerReadings.where((r) => r.at.isAfter(first)).toList();
    if (readings.isEmpty) return;
    if (!readings.first.snapshot.supported) {
      message.powerLabel = 'power n/a';
      return;
    }

    final avgV =
        readings.fold<double>(0, (sum, r) => sum + r.snapshot.voltageV) /
        readings.length;
    final avgA =
        readings.fold<double>(0, (sum, r) => sum + r.snapshot.currentA) /
        readings.length;
    final charging = avgA > 0;
    final watts = avgV * avgA.abs();
    final tokens = int.tryParse(message.stats['tokens'] ?? '') ?? 0;
    final seconds = DateTime.now().difference(first).inMilliseconds / 1000.0;
    final idle = _idleWatts;
    final delta = idle == null
        ? null
        : (watts - idle).clamp(0.0, double.infinity);
    final energy = _energySuffix(
      watts: delta ?? watts,
      seconds: seconds,
      readings: readings,
    );

    if (charging) {
      if (delta != null && tokens > 0 && seconds > 0) {
        final joulesPerToken = delta * seconds / tokens;
        message.powerLabel =
            'Δ${delta.toStringAsFixed(1)} W · ${joulesPerToken.toStringAsFixed(2)} J/tok$energy (chg)';
      } else {
        message.powerLabel =
            'net ${watts.toStringAsFixed(1)} W · ${avgA.abs().toStringAsFixed(2)} A$energy (chg)';
      }
      return;
    }

    if (tokens > 0 && seconds > 0) {
      final joulesPerToken = watts * seconds / tokens;
      message.powerLabel =
          '${watts.toStringAsFixed(1)} W · ${joulesPerToken.toStringAsFixed(2)} J/tok$energy';
    } else {
      message.powerLabel = '${watts.toStringAsFixed(1)} W$energy';
    }
  }

  String _energySuffix({
    required double watts,
    required double seconds,
    required List<PowerReading> readings,
  }) {
    final store = _sessionStore;
    if (store == null || !store.energyEstimateEnabled) return '';
    final wh = watts * seconds / 3600.0;
    if (store.energyAsPercent) {
      final capacity = readings.isEmpty
          ? null
          : readings.last.snapshot.batteryCapacityWh;
      if (capacity != null && capacity > 0) {
        return ' · ≈${(wh / capacity * 100).toStringAsFixed(3)}% 电池';
      }
    }
    return ' · ≈${wh.toStringAsFixed(3)} Wh';
  }

  Future<void> _captureIdleBaselineAndPrompt() async {
    await Future<void>.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    final snapshot = await PowerSnapshot.read(_channel);
    if (snapshot != null && snapshot.supported && mounted) {
      setState(() => _idleWatts = snapshot.voltageV * snapshot.currentA.abs());
    }
    await _consumeLaunchPrompt();
  }

  Future<void> _consumeLaunchPrompt() async {
    if (!_loaded || _generating) return;
    try {
      final prompt = await _channel.invokeMethod<String>('getLaunchPrompt');
      if (prompt == null || prompt.trim().isEmpty || !mounted) return;
      _input.text = prompt;
      await _send();
    } catch (_) {
      // optional development hook only
    }
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  Future<void> _clearChat() async {
    if (_generating) return;
    final session = _session;
    if (session == null) return;
    await _invalidateSessionState(session);
    session.messages.clear();
    session.activeLeafId = null;
    setState(() => _messages.clear());
    await _saveSession();
  }

  Future<void> _openSystemPromptEditor() async {
    final session = _session;
    final store = _sessionStore;
    if (session == null || store == null || _generating) return;

    final hasOverride = session.systemPrompt?.trim().isNotEmpty ?? false;
    final controller = TextEditingController(
      text: hasOverride ? session.systemPrompt! : _systemPrompt,
    );
    var applyGlobal = false;

    final result = await showDialog<_PromptEditResult>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: _surface,
          title: const Text('系统提示词'),
          content: SizedBox(
            width: MediaQuery.sizeOf(dialogContext).width * 0.82,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    minLines: 5,
                    maxLines: 9,
                    decoration: const InputDecoration(
                      hintText: '留空使用全局提示词',
                      alignLabelWithHint: true,
                    ),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: applyGlobal,
                    onChanged: (value) =>
                        setDialogState(() => applyGlobal = value ?? false),
                    title: const Text('应用到全局'),
                    subtitle: const Text(
                      '只影响新会话；已有会话保持当前提示词，不会被修改。',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => setDialogState(() {
                controller.text = _systemPrompt;
                applyGlobal = false;
              }),
              child: const Text('恢复默认'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(
                dialogContext,
                _PromptEditResult(
                  text: controller.text,
                  applyGlobal: applyGlobal,
                ),
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (!mounted || result == null) return;

    final value = result.text.trim();
    if (result.applyGlobal) {
      final newGlobal = value.isEmpty || value == _systemPrompt ? null : value;
      await store.setGlobalSystemPrompt(newGlobal);
      _globalSystemPrompt = (newGlobal == null) ? _systemPrompt : newGlobal;
      if (mounted) setState(() => _lastPlan = null);
      return;
    }

    final old = hasOverride ? session.systemPrompt!.trim() : _systemPrompt;
    session.systemPrompt = value.isEmpty ? null : value;
    final next = value.isEmpty ? _systemPrompt : value;
    if (next != old) {
      await _invalidateSessionState(session);
    }
    await _saveSession();
    if (mounted) setState(() => _lastPlan = null);
  }

  Future<void> _openSessionSettings() async {
    final store = _sessionStore;
    final session = _session;
    if (store == null || session == null) return;
    final value = await showModalBottomSheet<SessionSettingsValue>(
      context: context,
      backgroundColor: _surface,
      useSafeArea: true,
      barrierColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SessionSettingsSheet(
        session: session,
        defaultSystemPrompt: _systemPrompt,
        defaultMaxTokens: _maxTokens,
      ),
    );
    if (value == null) return;

    String effective(String? prompt) =>
        (prompt == null || prompt.trim().isEmpty)
        ? _systemPrompt
        : prompt.trim();
    final promptChanged =
        effective(session.systemPrompt) != effective(value.systemPrompt);
    if (promptChanged) {
      await _invalidateSessionState(session);
    }

    session.systemPrompt = value.systemPrompt.isEmpty
        ? null
        : value.systemPrompt;
    session.temperature = value.temperature;
    session.topP = value.topP;
    session.topK = value.topK;
    session.repeatPenalty = value.repeatPenalty;
    session.maxTokens = value.maxTokens;
    session.rememberSettings = value.remember;
    await store.save(session);
    if (mounted) setState(() => _lastPlan = null);
  }

  Future<void> _invalidateSessionState(ChatSession session) async {
    final path = session.statePath;
    if (path != null) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
        final meta = File('$path.meta');
        if (await meta.exists()) await meta.delete();
      } catch (_) {}
    }
    session.statePath = null;
    session.stateBytes = 0;
    session.stateTokens = 0;
    session.stateModelPath = null;
    session.stateMmprojPath = null;
    session.stateCtx = 0;
    session.stateUpdatedAt = null;
    if (_session?.id == session.id) {
      _stateLoadedForCurrent = false;
      await _scheduler?.clearState();
    }
    await _sessionStore?.save(session);
  }

  // ignore: unused_element
  Future<void> _openSettings() async {
    var backend = _backend;
    var threads = _threads;
    var contextSize = _contextSize;
    var memoryBudget = _memoryBudgetMb;
    var maxTokens = _maxTokens;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _surface,
      useSafeArea: true,
      barrierColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 20,
                  right: 20,
                  top: 20,
                  bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '推理设置',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: const Icon(Icons.close_rounded, color: _muted),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '切换后端、内存预算或上下文后需要重新加载模型。',
                      style: TextStyle(color: _muted, fontSize: 12.5),
                    ),
                    const SizedBox(height: 20),
                    if (_info != null) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _surfaceHigh,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _line),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '模型 ${(_info!.modelBytes / (1024 * 1024)).round()} MB · '
                              'KV ${(_info!.kvBytes / (1024 * 1024)).round()} MB · '
                              'ctx ${_info!.nCtx}（推荐 ${_info!.recommendedCtx}）',
                              style: const TextStyle(
                                fontSize: 11,
                                color: _text,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '可用内存 ${(_info!.availRamBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} / '
                              '${(_info!.totalRamBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB · '
                              '预算 ${(_info!.budgetBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB · '
                              'RSS ${(_info!.rssBytes / (1024 * 1024)).round()} MB',
                              style: const TextStyle(
                                fontSize: 11,
                                color: _muted,
                              ),
                            ),
                            Text(
                              '已用上下文 ${_lastPlan?.promptTokens ?? 0} / ${_info!.nCtx}'
                              '（精确 tokenizer）',
                              style: const TextStyle(
                                fontSize: 11,
                                color: _muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                    ],
                    const _SheetLabel('后端'),
                    _ChipWrap<int>(
                      values: const [0, 1],
                      selected: backend == ComputeBackend.vulkan ? 0 : 1,
                      label: (value) => value == 0 ? 'Vulkan GPU' : '仅 CPU',
                      onSelected: (value) => setSheetState(
                        () => backend = value == 0
                            ? ComputeBackend.vulkan
                            : ComputeBackend.cpu,
                      ),
                    ),
                    const SizedBox(height: 18),
                    const _SheetLabel('CPU 线程'),
                    _ChipWrap<int>(
                      values: const [2, 4, 6, 8],
                      selected: threads,
                      label: (value) => '$value',
                      onSelected: (value) =>
                          setSheetState(() => threads = value),
                    ),
                    const SizedBox(height: 18),
                    const _SheetLabel('上下文大小'),
                    _ChipWrap<int>(
                      values: const [0, 4096, 8192, 16384, 32768],
                      selected: contextSize,
                      label: (value) => value == 0 ? '自动' : '$value',
                      onSelected: (value) =>
                          setSheetState(() => contextSize = value),
                    ),
                    const SizedBox(height: 18),
                    const _SheetLabel('内存预算'),
                    _ChipWrap<int>(
                      values: const [0, 2048, 4096, 6144, 8192],
                      selected: memoryBudget,
                      label: (value) => value == 0 ? '自动' : '${value}M',
                      onSelected: (value) =>
                          setSheetState(() => memoryBudget = value),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        const _SheetLabel('最大输出 tokens'),
                        const Spacer(),
                        Text(
                          '$maxTokens',
                          style: const TextStyle(
                            color: _accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: maxTokens.toDouble(),
                      min: 64,
                      max: 512,
                      divisions: 7,
                      activeColor: _accent,
                      inactiveColor: _line,
                      onChanged: (value) => setSheetState(
                        () => maxTokens = (value / 64).round() * 64,
                      ),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: () async {
                          final requiresReload =
                              backend != _backend ||
                              threads != _threads ||
                              contextSize != _contextSize ||
                              memoryBudget != _memoryBudgetMb;
                          setState(() {
                            _backend = backend;
                            _threads = threads;
                            _contextSize = contextSize;
                            _memoryBudgetMb = memoryBudget;
                            _maxTokens = maxTokens;
                          });
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                          if (requiresReload && _modelPath != null) {
                            _loadModel();
                          }
                        },
                        child: const Text(
                          '应用',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        toolbarHeight: 70,
        titleSpacing: 20,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'EDGE AI',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
                color: AppColors.ink,
              ),
            ),
            SizedBox(height: 2),
            Text(
              '端侧离线推理 · llama.cpp',
              style: TextStyle(fontSize: 11, color: AppColors.muted),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '会话',
            onPressed: _generating ? null : _openSessions,
            icon: const Icon(Icons.forum_outlined, color: AppColors.inkSoft),
          ),
          IconButton(
            tooltip: '系统提示词',
            onPressed: _generating ? null : _openSystemPromptEditor,
            icon: const Icon(Icons.notes_rounded, color: AppColors.inkSoft),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_booting) {
      return const _BootView();
    }
    if (_fatalError != null) {
      return _ErrorView(
        title: 'Engine error',
        message: _fatalError!,
        onRetry: () async {
          setState(() {
            _fatalError = null;
            _booting = true;
          });
          await _bootstrap();
        },
      );
    }
    if (_modelPath == null) {
      return _MissingModelView(
        modelDir: _modelDir,
        onOpenModels: _pageController.onOpenModels,
        onRescan: () async {
          setState(() => _booting = true);
          await _resolveModel();
          if (_modelPath != null) unawaited(_loadModel());
        },
      );
    }
    if (_loading) {
      return Column(
        children: [
          Expanded(
            child: _LoadingView(
              backend: _backend,
              fileName: _modelPath!.split(Platform.pathSeparator).last,
              modelBytes: _modelBytes,
            ),
          ),
          _Composer(
            controller: _input,
            generating: false,
            sendEnabled: false,
            pickingImage: _pickingImage,
            pendingImages: _pendingImagePaths,
            onAttach: _pickImage,
            onRemoveImage: (index) => setState(() {
              _pendingImagePaths.removeAt(index);
              _pendingImagePath = _pendingImagePaths.isEmpty
                  ? null
                  : _pendingImagePaths.first;
            }),
            onSend: _send,
            onStop: _stop,
          ),
        ],
      );
    }
    if (!_loaded) {
      return _ErrorView(
        title: '模型加载失败',
        message: _loadError ?? 'Unknown error. Check logcat for details.',
        onRetry: _loadModel,
        extraAction: _backend == ComputeBackend.vulkan
            ? TextButton(
                onPressed: () {
                  setState(() => _backend = ComputeBackend.cpu);
                  _loadModel();
                },
                child: const Text('用 CPU 重试'),
              )
            : null,
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 14, 4),
          child: Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _openModels,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _modelName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.bodyStrong.copyWith(fontSize: 13),
                      ),
                      const SizedBox(height: 1),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${(_info?.backend ?? '').toLowerCase().contains('vulkan') ? 'Vulkan' : 'CPU'}'
                            ' · ${int.tryParse(_modelParams['ctx'] ?? '') ?? _contextSize} ctx',
                            style: AppText.small.copyWith(
                              fontSize: 10,
                              color: AppColors.faint,
                            ),
                          ),
                          const SizedBox(width: 2),
                          const Icon(
                            Icons.unfold_more_rounded,
                            size: 13,
                            color: AppColors.faint,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                selected: _thinking,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                selectedColor: AppColors.primaryWash,
                backgroundColor: AppColors.surface,
                side: BorderSide(
                  color: _thinking ? AppColors.primary : AppColors.line,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 2),
                avatar: Icon(
                  Icons.psychology_alt_outlined,
                  size: 15,
                  color: _thinking ? AppColors.primary : AppColors.muted,
                ),
                label: Text(
                  '思考',
                  style: TextStyle(
                    fontSize: 11,
                    color: _thinking
                        ? AppColors.primaryStrong
                        : AppColors.muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                tooltip: '启用思考模式，仅对支持 enable_thinking 的模型生效',
                onSelected: _setThinking,
              ),
            ],
          ),
        ),
        Expanded(
          child: _messages.isEmpty
              ? _WelcomeView(
                  onSuggestion: (text) {
                    _input.text = text;
                    _send();
                  },
                )
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final message = _messages[index];
                    if (message.role == 'assistant' &&
                        !message.streaming &&
                        message.text.trim().isEmpty &&
                        message.stats.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return _MessageBubble(
                      message: message,
                      onAction: () => _showMessageActions(message),
                      onImageTap: _openImagePreview,
                      footer: _messageFooter(message),
                    );
                  },
                ),
        ),
        _Composer(
          controller: _input,
          generating: _generating,
          pickingImage: _pickingImage,
          pendingImages: _pendingImagePaths,
          onAttach: _pickImage,
          onRemoveImage: (index) => setState(() {
            _pendingImagePaths.removeAt(index);
            _pendingImagePath = _pendingImagePaths.isEmpty
                ? null
                : _pendingImagePaths.first;
          }),
          onSend: _send,
          onStop: _stop,
        ),
      ],
    );
  }
}

class _BootView extends StatelessWidget {
  const _BootView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: _accent),
          ),
          SizedBox(height: 18),
          Text('Starting inference engine...', style: TextStyle(color: _muted)),
        ],
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView({
    required this.backend,
    required this.fileName,
    required this.modelBytes,
  });

  final ComputeBackend backend;
  final String fileName;
  final int modelBytes;

  @override
  Widget build(BuildContext context) {
    final size = modelBytes > 0
        ? '${(modelBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB'
        : '';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    _accent.withValues(alpha: 0.20),
                    AppColors.primary.withValues(alpha: 0.10),
                  ],
                ),
                border: Border.all(color: _accent.withValues(alpha: 0.22)),
              ),
              child: const Padding(
                padding: EdgeInsets.all(26),
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: _accent,
                ),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              backend == ComputeBackend.vulkan ? '正在预热 Vulkan' : '正在加载模型',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            const Text(
              'Mapping model weights and creating the inference context.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted, height: 1.45),
            ),
            const SizedBox(height: 22),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _line),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.description_outlined,
                    size: 15,
                    color: _muted,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      '$fileName  $size',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: _muted),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'First launch takes a few seconds. Weights stay resident afterwards.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: AppColors.faint),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.title,
    required this.message,
    required this.onRetry,
    this.extraAction,
  });

  final String title;
  final String message;
  final Future<void> Function() onRetry;
  final Widget? extraAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, color: _danger, size: 42),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _muted,
                height: 1.45,
                fontSize: 12.5,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              onPressed: onRetry,
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
            ?extraAction,
          ],
        ),
      ),
    );
  }
}

class _MissingModelView extends StatelessWidget {
  const _MissingModelView({
    required this.modelDir,
    required this.onRescan,
    this.onOpenModels,
  });

  final String modelDir;
  final Future<void> Function() onRescan;
  final VoidCallback? onOpenModels;

  @override
  Widget build(BuildContext context) {
    final command = 'adb push Qwen3-1.7B-Q6_K.gguf \\\n  $modelDir/';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 12),
          const Icon(Icons.folder_off_outlined, color: _accent, size: 40),
          const SizedBox(height: 18),
          const Text(
            '还没有可用模型',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '去「模型」页从 ModelScope 或 HuggingFace 镜像下载 GGUF；'
            '也可以把模型文件放进下面的目录，再回来扫描。',
            style: TextStyle(color: _muted, height: 1.55),
          ),
          const SizedBox(height: 22),
          if (onOpenModels != null) ...[
            SizedBox(
              width: double.infinity,
              child: AppPrimaryButton(label: '打开模型页', onPressed: onOpenModels),
            ),
            const SizedBox(height: 10),
          ],
          SizedBox(
            width: double.infinity,
            child: AppSoftButton(label: '重新扫描本地目录', onPressed: onRescan),
          ),
          const SizedBox(height: 22),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _line),
            ),
            child: SelectableText(
              command,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
                color: _accentSoft,
                height: 1.5,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '模型目录\n$modelDir',
            style: const TextStyle(
              color: AppColors.muted,
              fontSize: 11.5,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _WelcomeView extends StatelessWidget {
  const _WelcomeView({required this.onSuggestion});

  final void Function(String) onSuggestion;

  @override
  Widget build(BuildContext context) {
    const suggestions = <String>[
      '用一句话解释什么是 Vulkan',
      '写一首关于手机运行大模型的俳句',
      '9.11 和 9.9 哪个大？',
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 32, 22, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppBadge(label: '100% 本地运行', icon: Icons.lock_outline_rounded),
          const SizedBox(height: 18),
          const Text(
            '你的模型。\n你的手机。\n无需云端。',
            style: TextStyle(
              fontSize: 32,
              height: 1.18,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
              color: AppColors.ink,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'llama.cpp 在设备上完成推理，支持 CPU / Vulkan、多模态图片和长上下文。'
            '文本、图片和缓存都不会离开这台设备。',
            style: TextStyle(
              color: AppColors.muted,
              height: 1.55,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 26),
          const Text(
            '试着问',
            style: TextStyle(
              fontSize: 9.5,
              color: AppColors.faint,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          ...suggestions.map(
            (text) => SurfaceCard(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              onTap: () => onSuggestion(text),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      text,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.ink,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.arrow_outward_rounded,
                    size: 15,
                    color: AppColors.faint,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageText extends StatelessWidget {
  const _MessageText({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    if (isUser) {
      return SelectableText(
        message.text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14.5,
          height: 1.42,
        ),
      );
    }
    if (message.streaming) {
      final parsed = ThinkingContent.parse(message.text);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (parsed.hasThinking)
            _ThinkingPanel(text: parsed.thinking, streaming: true),
          if (parsed.answer.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: parsed.hasThinking ? 8 : 0),
              child: SelectableText(
                '${parsed.answer}▍',
                style: const TextStyle(
                  color: _text,
                  fontSize: 14.5,
                  height: 1.42,
                ),
              ),
            )
          else if (!parsed.hasThinking)
            const SelectableText(
              '▍',
              style: TextStyle(color: _text, fontSize: 14.5, height: 1.42),
            ),
        ],
      );
    }
    final parsed = ThinkingContent.parse(message.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (parsed.hasThinking)
          _ThinkingPanel(text: parsed.thinking, streaming: false),
        if (parsed.answer.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: parsed.hasThinking ? 10 : 0),
            child: MarkdownBody(
              data: parsed.answer,
              selectable: true,
              fitContent: true,
              styleSheet: _markdownStyle(),
              sizedImageBuilder: (config) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '[图片] ${config.alt ?? config.uri.toString()}',
                  style: const TextStyle(color: _muted, fontSize: 12.5),
                ),
              ),
              onTapLink: (text, href, title) {
                if (href == null || href.isEmpty) return;
                Clipboard.setData(ClipboardData(text: href));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('链接已复制：$href'),
                    backgroundColor: AppColors.primaryDeep,
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _GeneratingIndicator extends StatefulWidget {
  const _GeneratingIndicator();

  @override
  State<_GeneratingIndicator> createState() => _GeneratingIndicatorState();
}

class _GeneratingIndicatorState extends State<_GeneratingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('正在生成', style: TextStyle(color: _muted, fontSize: 12)),
            const SizedBox(width: 8),
            for (var i = 0; i < 3; i++)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Opacity(
                  opacity:
                      0.25 +
                      0.75 *
                          (1 -
                              ((_controller.value + i * 0.22) % 1 - 0.5).abs() *
                                  2),
                  child: const SizedBox(
                    width: 5,
                    height: 5,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: _accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ThinkingPanel extends StatefulWidget {
  const _ThinkingPanel({required this.text, required this.streaming});

  final String text;
  final bool streaming;

  @override
  State<_ThinkingPanel> createState() => _ThinkingPanelState();
}

class _ThinkingPanelState extends State<_ThinkingPanel> {
  late bool _expanded;
  bool _userToggled = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.streaming;
  }

  @override
  void didUpdateWidget(covariant _ThinkingPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.streaming && !oldWidget.streaming) {
      _expanded = true;
    } else if (oldWidget.streaming && !widget.streaming && !_userToggled) {
      _expanded = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.streaming ? '思考中' : '已思考';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() {
            _userToggled = true;
            _expanded = !_expanded;
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: widget.streaming
                        ? AppColors.primaryStrong
                        : AppColors.muted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${widget.text.length} 字',
                  style: const TextStyle(fontSize: 10, color: AppColors.faint),
                ),
                const Spacer(),
                Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 19,
                  color: AppColors.muted,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(top: 7, left: 2, right: 2),
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: AppColors.primary.withValues(alpha: 0.32),
                    width: 2,
                  ),
                ),
              ),
              padding: const EdgeInsets.only(left: 11),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: SingleChildScrollView(
                  child: SelectableText(
                    widget.text,
                    style: const TextStyle(
                      fontSize: 13.5,
                      height: 1.65,
                      color: AppColors.inkSoft,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

MarkdownStyleSheet _markdownStyle() {
  const body = TextStyle(color: _text, fontSize: 14.5, height: 1.5);
  return MarkdownStyleSheet(
    p: body,
    h1: body.copyWith(fontSize: 21, fontWeight: FontWeight.w700, height: 1.25),
    h2: body.copyWith(fontSize: 18, fontWeight: FontWeight.w700, height: 1.28),
    h3: body.copyWith(fontSize: 16, fontWeight: FontWeight.w700, height: 1.3),
    h4: body.copyWith(fontSize: 14.5, fontWeight: FontWeight.w700),
    h5: body.copyWith(fontSize: 13.5, fontWeight: FontWeight.w700),
    h6: body.copyWith(
      fontSize: 12.5,
      fontWeight: FontWeight.w700,
      color: _muted,
    ),
    strong: body.copyWith(fontWeight: FontWeight.w700),
    em: body.copyWith(fontStyle: FontStyle.italic),
    del: body.copyWith(decoration: TextDecoration.lineThrough),
    a: body.copyWith(color: _accent, decoration: TextDecoration.underline),
    code: const TextStyle(
      color: AppColors.primaryDeep,
      backgroundColor: AppColors.primaryWash,
      fontFamily: 'monospace',
      fontSize: 13,
      height: 1.45,
    ),
    codeblockDecoration: BoxDecoration(
      color: AppColors.surfaceTint,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      border: Border.all(color: AppColors.line),
    ),
    codeblockPadding: const EdgeInsets.all(11),
    blockquote: body.copyWith(color: AppColors.muted),
    blockquoteDecoration: const BoxDecoration(
      color: AppColors.primaryWash,
      border: Border(left: BorderSide(color: AppColors.primary, width: 3)),
    ),
    blockquotePadding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
    listBullet: body,
    listIndent: 18,
    tableHead: body.copyWith(fontWeight: FontWeight.w700),
    tableBody: body,
    tableBorder: TableBorder.all(color: AppColors.line),
    tableCellsPadding: const EdgeInsets.all(6),
    horizontalRuleDecoration: const BoxDecoration(
      border: Border(top: BorderSide(color: AppColors.line)),
    ),
  );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    this.onAction,
    this.onImageTap,
    this.footer,
  });

  final ChatMessage message;
  final VoidCallback? onAction;
  final ValueChanged<String>? onImageTap;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final width = MediaQuery.sizeOf(context).width;
    final maxWidth = width * 0.82;

    return Column(
      crossAxisAlignment: isUser
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: GestureDetector(
            onLongPress: onAction,
            child: Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.fromLTRB(16, 13, 16, 12),
              decoration: BoxDecoration(
                color: isUser ? _accent : _surface,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
                border: isUser ? null : Border.all(color: _line),
                boxShadow: isUser ? null : AppShadows.card,
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Padding(
                    padding: EdgeInsets.zero,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!isUser &&
                            message.streaming &&
                            message.text.trim().isEmpty)
                          const _GeneratingIndicator(),
                        if (message.imagePaths.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final path in message.imagePaths)
                                  GestureDetector(
                                    onTap: () => onImageTap?.call(path),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(10),
                                      child: Image.file(
                                        File(path),
                                        width: message.imagePaths.length == 1
                                            ? 220
                                            : 104,
                                        height: message.imagePaths.length == 1
                                            ? 180
                                            : 104,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        if (message.text.trim().isNotEmpty)
                          _MessageText(message: message),
                        if (!message.streaming &&
                            message.stats.isNotEmpty &&
                            !isUser)
                          Padding(
                            padding: const EdgeInsets.only(top: 9),
                            child: Text(
                              _statsLine(
                                message.stats,
                                message.cancelled,
                                message.powerLabel,
                              ),
                              style: const TextStyle(
                                fontSize: 10,
                                color: AppColors.muted,
                                letterSpacing: 0.1,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        ?footer,
      ],
    );
  }

  String _statsLine(Map<String, String> stats, bool cancelled, String? power) {
    final backend = (stats['backend'] ?? '').toLowerCase().contains('vulkan')
        ? 'Vulkan'
        : 'CPU';
    final tokS = stats['tok_s'] ?? '0';
    final tokens = stats['tokens'] ?? '0';
    final prefillMs = double.tryParse(stats['prefill_ms'] ?? '') ?? 0;
    final prefill = prefillMs >= 1000
        ? '${(prefillMs / 1000).toStringAsFixed(2)}s prefill'
        : '${prefillMs.toStringAsFixed(0)}ms prefill';
    final suffix = cancelled ? ' · stopped' : '';
    final dropped = int.tryParse(stats['dropped'] ?? '') ?? 0;
    final droppedPart = dropped > 0 ? ' · trimmed $dropped' : '';
    final powerPart = power == null ? '' : '\n$power';
    return '$backend · $tokS tok/s · $tokens tok · $prefill$droppedPart$suffix$powerPart';
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.generating,
    this.sendEnabled = true,
    this.pickingImage = false,
    required this.pendingImages,
    required this.onAttach,
    required this.onRemoveImage,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool generating;
  final bool sendEnabled;
  final bool pickingImage;
  final List<String> pendingImages;
  final Future<void> Function() onAttach;
  final void Function(int index) onRemoveImage;
  final Future<void> Function() onSend;
  final Future<void> Function() onStop;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _bg,
        border: Border(top: BorderSide(color: _line)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pendingImages.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SizedBox(
                    height: 62,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: pendingImages.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        return Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.file(
                                File(pendingImages[index]),
                                width: 58,
                                height: 58,
                                fit: BoxFit.cover,
                              ),
                            ),
                            Positioned(
                              right: 0,
                              top: 0,
                              child: GestureDetector(
                                onTap: () => onRemoveImage(index),
                                child: Container(
                                  decoration: const BoxDecoration(
                                    color: Color(0xCC000000),
                                    shape: BoxShape.circle,
                                  ),
                                  padding: const EdgeInsets.all(2),
                                  child: const Icon(
                                    Icons.close_rounded,
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    onPressed: generating || pickingImage ? null : onAttach,
                    icon: pickingImage
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _muted,
                            ),
                          )
                        : const Icon(Icons.image_outlined),
                    color: _muted,
                    tooltip: '添加图片',
                  ),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: _surface,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: _line),
                      ),
                      child: TextField(
                        controller: controller,
                        enabled: true,
                        minLines: 1,
                        maxLines: 4,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        style: const TextStyle(fontSize: 14.5, height: 1.4),
                        decoration: const InputDecoration(
                          hintText: '输入消息…',
                          hintStyle: TextStyle(
                            color: AppColors.faint,
                            fontSize: 14,
                          ),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 15,
                            vertical: 13,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: generating
                        ? FilledButton(
                            onPressed: onStop,
                            style: FilledButton.styleFrom(
                              padding: EdgeInsets.zero,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              backgroundColor: _surfaceHigh,
                            ),
                            child: const Icon(
                              Icons.stop_rounded,
                              color: _danger,
                              size: 22,
                            ),
                          )
                        : FilledButton(
                            onPressed: sendEnabled ? onSend : null,
                            style: FilledButton.styleFrom(
                              padding: EdgeInsets.zero,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              backgroundColor: sendEnabled
                                  ? _accent
                                  : _surfaceHigh,
                            ),
                            child: Icon(
                              Icons.arrow_upward_rounded,
                              color: sendEnabled ? Colors.white : _muted,
                              size: 22,
                            ),
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetLabel extends StatelessWidget {
  const _SheetLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 9.5,
        letterSpacing: 1.3,
        color: AppColors.muted,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _ChipWrap<T> extends StatelessWidget {
  const _ChipWrap({
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelected,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: values
          .map(
            (value) => ChoiceChip(
              label: Text(label(value), style: const TextStyle(fontSize: 12)),
              selected: value == selected,
              onSelected: (_) => onSelected(value),
              selectedColor: _accent.withValues(alpha: 0.16),
              backgroundColor: _surfaceHigh,
              side: BorderSide(
                color: value == selected
                    ? _accent.withValues(alpha: 0.5)
                    : _line,
              ),
              labelStyle: TextStyle(
                color: value == selected ? _accentSoft : _muted,
                fontWeight: value == selected
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
              showCheckmark: false,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9),
              ),
            ),
          )
          .toList(),
    );
  }
}
