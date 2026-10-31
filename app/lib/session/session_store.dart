import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

class StoredMessage {
  StoredMessage({
    required this.role,
    required this.text,
    this.id = '',
    this.parentId,
    List<String>? imagePaths,
    Map<String, String>? stats,
    DateTime? createdAt,
  }) : imagePaths = imagePaths ?? <String>[],
       stats = stats ?? <String, String>{},
       createdAt = createdAt ?? DateTime.now();

  String id;
  String? parentId;
  final String role;
  String text;
  final List<String> imagePaths;
  Map<String, String> stats;
  final DateTime createdAt;

  String? get imagePath => imagePaths.isEmpty ? null : imagePaths.first;

  Map<String, Object?> toJson() => {
    'id': id,
    'parentId': parentId,
    'role': role,
    'text': text,
    if (imagePaths.isNotEmpty) 'imagePaths': imagePaths,
    if (stats.isNotEmpty) 'stats': stats,
    'createdAt': createdAt.toIso8601String(),
  };

  factory StoredMessage.fromJson(Map<String, dynamic> json) {
    final legacy = json['imagePath'] as String?;
    final paths =
        (json['imagePaths'] as List?)?.cast<String>().toList() ??
        <String>[if (legacy != null && legacy.isNotEmpty) legacy];
    return StoredMessage(
      id: json['id'] as String? ?? '',
      parentId: json['parentId'] as String?,
      role: json['role'] as String? ?? 'user',
      text: json['text'] as String? ?? '',
      imagePaths: paths,
      stats: (json['stats'] as Map?)?.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      ),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    );
  }
}

class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.modelPath,
    List<StoredMessage>? messages,
  }) : messages = messages ?? <StoredMessage>[];

  final String id;
  String title;
  String? modelPath;
  String? systemPrompt;
  double? temperature;
  double? topP;
  double? repeatPenalty;
  int? topK;
  int? maxTokens;
  bool rememberSettings = true;
  String? statePath;
  String? stateModelPath;
  String? stateMmprojPath;
  int stateCtx = 0;
  int stateBytes = 0;
  int stateTokens = 0;
  DateTime? stateUpdatedAt;
  final DateTime createdAt;
  DateTime updatedAt;
  final List<StoredMessage> messages;
  String? activeLeafId;

  Map<String, Object?> toJson() => {
    'version': 2,
    'id': id,
    'title': title,
    'modelPath': modelPath,
    'activeLeafId': activeLeafId,
    'rememberSettings': rememberSettings,
    if (rememberSettings)
      'settings': {
        'systemPrompt': systemPrompt,
        'temperature': temperature,
        'topP': topP,
        'repeatPenalty': repeatPenalty,
        'topK': topK,
        'maxTokens': maxTokens,
      },
    'statePath': statePath,
    'stateModelPath': stateModelPath,
    'stateMmprojPath': stateMmprojPath,
    'stateCtx': stateCtx,
    'stateBytes': stateBytes,
    'stateTokens': stateTokens,
    'stateUpdatedAt': stateUpdatedAt?.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'messages': messages.map((m) => m.toJson()).toList(),
  };

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    final created =
        DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now();
    final updated =
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? created;
    final nodes = (json['messages'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => StoredMessage.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    final session =
        ChatSession(
            id: json['id'] as String? ?? '',
            title: json['title'] as String? ?? 'New chat',
            modelPath: json['modelPath'] as String?,
            createdAt: created,
            updatedAt: updated,
            messages: nodes,
          )
          ..statePath = json['statePath'] as String?
          ..rememberSettings = json['rememberSettings'] as bool? ?? true
          ..systemPrompt =
              (json['settings'] as Map?)?['systemPrompt'] as String?
          ..temperature = ((json['settings'] as Map?)?['temperature'] as num?)
              ?.toDouble()
          ..topP = ((json['settings'] as Map?)?['topP'] as num?)?.toDouble()
          ..repeatPenalty =
              ((json['settings'] as Map?)?['repeatPenalty'] as num?)?.toDouble()
          ..topK = ((json['settings'] as Map?)?['topK'] as num?)?.toInt()
          ..maxTokens = ((json['settings'] as Map?)?['maxTokens'] as num?)
              ?.toInt()
          ..stateModelPath = json['stateModelPath'] as String?
          ..stateMmprojPath = json['stateMmprojPath'] as String?
          ..stateCtx = (json['stateCtx'] as num?)?.toInt() ?? 0
          ..stateBytes = (json['stateBytes'] as num?)?.toInt() ?? 0
          ..stateTokens = (json['stateTokens'] as num?)?.toInt() ?? 0
          ..stateUpdatedAt = DateTime.tryParse(
            json['stateUpdatedAt'] as String? ?? '',
          );

    final isTree = json['version'] == 2 && nodes.every((n) => n.id.isNotEmpty);
    if (!isTree) {
      String? parent;
      final stamp = DateTime.now().microsecondsSinceEpoch;
      for (var i = 0; i < nodes.length; i++) {
        nodes[i]
          ..id = 'legacy-$stamp-$i'
          ..parentId = parent;
        parent = nodes[i].id;
      }
      session.activeLeafId = parent;
    } else {
      session.activeLeafId =
          json['activeLeafId'] as String? ??
          (nodes.isEmpty ? null : nodes.last.id);
    }
    return session;
  }

  StoredMessage? nodeById(String? id) {
    if (id == null) return null;
    for (final node in messages) {
      if (node.id == id) return node;
    }
    return null;
  }

  List<StoredMessage> childrenOf(String? parentId) {
    final children = messages.where((m) => m.parentId == parentId).toList()
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        return byTime != 0 ? byTime : a.id.compareTo(b.id);
      });
    return children;
  }

  List<StoredMessage> pathTo(String? leafId) {
    final path = <StoredMessage>[];
    final seen = <String>{};
    var current = nodeById(leafId);
    while (current != null && seen.add(current.id)) {
      path.add(current);
      current = nodeById(current.parentId);
    }
    return path.reversed.toList();
  }

  List<StoredMessage> get activePath => pathTo(activeLeafId);

  String? latestLeaf(String? startId) {
    var current = nodeById(startId);
    if (current == null) return null;
    final seen = <String>{};
    while (seen.add(current!.id)) {
      final children = childrenOf(current.id);
      if (children.isEmpty) break;
      current = children.last;
    }
    return current.id;
  }

  List<StoredMessage> siblingsOf(StoredMessage node) {
    return childrenOf(node.parentId).where((m) => m.role == node.role).toList();
  }
}

class SessionStore {
  SessionStore._(this.root);

  final Directory root;
  final List<ChatSession> sessions = <ChatSession>[];
  String? activeId;
  bool stateCacheEnabled = false;
  int stateCacheMaxBytes = 4 * 1024 * 1024 * 1024;
  bool stateCacheConfigured = false;
  bool powerStatsEnabled = true;
  bool energyEstimateEnabled = true;
  bool energyAsPercent = false;
  bool thinkingEnabled = false;
  Future<void> _writeQueue = Future<void>.value();

  Directory get _sessionDir => Directory('${root.path}/sessions');
  Directory get _mediaDir => Directory('${root.path}/media');
  File get _indexFile => File('${root.path}/sessions.json');

  static Future<SessionStore> open(MethodChannel channel) async {
    final base = await channel.invokeMethod<String>('getExternalFilesDir');
    if (base == null) throw StateError('no external files dir');
    final store = SessionStore._(Directory(base));
    await store.load();
    return store;
  }

  Future<void> load() async {
    await _sessionDir.create(recursive: true);
    await _mediaDir.create(recursive: true);
    sessions.clear();
    if (await _indexFile.exists()) {
      try {
        final data = jsonDecode(await _indexFile.readAsString());
        activeId = (data as Map)['activeId'] as String?;
        stateCacheEnabled = (data)['stateCacheEnabled'] as bool? ?? false;
        stateCacheMaxBytes =
            ((data)['stateCacheMaxBytes'] as num?)?.toInt() ??
            4 * 1024 * 1024 * 1024;
        stateCacheConfigured = (data)['stateCacheConfigured'] as bool? ?? false;
        powerStatsEnabled = (data)['powerStatsEnabled'] as bool? ?? true;
        energyEstimateEnabled =
            (data)['energyEstimateEnabled'] as bool? ?? true;
        energyAsPercent = (data)['energyAsPercent'] as bool? ?? false;
        thinkingEnabled = (data)['thinkingEnabled'] as bool? ?? false;
      } catch (_) {}
    }
    final files = await _sessionDir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    for (final file in files) {
      try {
        final json = jsonDecode(await file.readAsString());
        final session = ChatSession.fromJson(
          Map<String, dynamic>.from(json as Map),
        );
        if (session.id.isNotEmpty) sessions.add(session);
      } catch (_) {
        // Ignore a corrupt session file; keep the rest usable.
      }
    }
    sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (sessions.isNotEmpty &&
        (activeId == null || !sessions.any((s) => s.id == activeId))) {
      activeId = sessions.first.id;
    }
  }

  ChatSession create({String? modelPath}) {
    final now = DateTime.now();
    final id =
        '${now.millisecondsSinceEpoch.toString()}-${Random().nextInt(1 << 20)}';
    final session = ChatSession(
      id: id,
      title: 'New chat',
      modelPath: modelPath,
      createdAt: now,
      updatedAt: now,
    );
    sessions.insert(0, session);
    activeId = id;
    return session;
  }

  ChatSession? byId(String id) {
    for (final session in sessions) {
      if (session.id == id) return session;
    }
    return null;
  }

  Future<void> save(ChatSession session) async {
    session.updatedAt = DateTime.now();
    final file = File('${_sessionDir.path}/${session.id}.json');
    await _atomicWrite(file, jsonEncode(session.toJson()));
    sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await _writeIndex();
  }

  Future<void> setActive(String? id) async {
    activeId = id;
    await _writeIndex();
  }

  Future<void> setStateCachePolicy({
    required bool enabled,
    required int maxBytes,
  }) async {
    stateCacheEnabled = enabled;
    stateCacheMaxBytes = maxBytes;
    stateCacheConfigured = true;
    await _writeIndex();
  }

  Future<void> setPowerDisplayPolicy({
    required bool enabled,
    required bool energy,
    required bool energyPercent,
  }) async {
    powerStatsEnabled = enabled;
    energyEstimateEnabled = energy;
    energyAsPercent = energyPercent;
    await _writeIndex();
  }

  Future<void> setThinkingEnabled(bool enabled) async {
    thinkingEnabled = enabled;
    await _writeIndex();
  }

  Future<int> stateCacheBytes() async {
    if (!await _mediaDir.exists()) return 0;
    var total = 0;
    await for (final entity in _mediaDir.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('state.bin')) {
        total += await entity.length();
      }
    }
    return total;
  }

  Future<void> clearStateCache() async {
    if (await _mediaDir.exists()) {
      await for (final entity in _mediaDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name.startsWith('state.bin')) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    }
    for (final session in sessions) {
      if (session.statePath == null && session.stateBytes == 0) continue;
      session.statePath = null;
      session.stateBytes = 0;
      session.stateTokens = 0;
      session.stateModelPath = null;
      session.stateMmprojPath = null;
      session.stateCtx = 0;
      session.stateUpdatedAt = null;
      await save(session);
    }
  }

  String statePathFor(String sessionId) =>
      '${_mediaDir.path}/$sessionId/state.bin';

  Future<void> delete(String id) async {
    sessions.removeWhere((s) => s.id == id);
    final file = File('${_sessionDir.path}/$id.json');
    if (await file.exists()) await file.delete();
    final media = Directory('${_mediaDir.path}/$id');
    if (await media.exists()) await media.delete(recursive: true);
    if (activeId == id) activeId = sessions.isEmpty ? null : sessions.first.id;
    await _writeIndex();
  }

  Future<void> evictStateCache(int maxBytes) async {
    final entries = sessions
        .where((s) => s.statePath != null && s.stateBytes > 0)
        .toList();
    var total = entries.fold<int>(0, (sum, s) => sum + s.stateBytes);
    if (total <= maxBytes) return;
    entries.sort((a, b) {
      final at = a.stateUpdatedAt ?? a.updatedAt;
      final bt = b.stateUpdatedAt ?? b.updatedAt;
      return at.compareTo(bt);
    });
    for (final session in entries) {
      if (total <= maxBytes) break;
      final path = session.statePath;
      if (path == null) continue;
      final file = File(path);
      if (await file.exists()) await file.delete();
      total -= session.stateBytes;
      session.statePath = null;
      session.stateBytes = 0;
      session.stateTokens = 0;
      session.stateModelPath = null;
      session.stateUpdatedAt = null;
      await save(session);
    }
  }

  Future<String> importImage(String source, String sessionId) async {
    final dir = Directory('${_mediaDir.path}/$sessionId');
    await dir.create(recursive: true);
    final ext = source.contains('.')
        ? source.substring(source.lastIndexOf('.'))
        : '.jpg';
    final target = '${dir.path}/${DateTime.now().microsecondsSinceEpoch}$ext';
    await File(source).copy(target);
    return target;
  }

  Future<void> _writeIndex() async {
    await _atomicWrite(
      _indexFile,
      jsonEncode({
        'version': 1,
        'activeId': activeId,
        'stateCacheEnabled': stateCacheEnabled,
        'stateCacheMaxBytes': stateCacheMaxBytes,
        'stateCacheConfigured': stateCacheConfigured,
        'powerStatsEnabled': powerStatsEnabled,
        'energyEstimateEnabled': energyEstimateEnabled,
        'energyAsPercent': energyAsPercent,
        'thinkingEnabled': thinkingEnabled,
      }),
    );
  }

  Future<void> _atomicWrite(File file, String content) async {
    final previous = _writeQueue;
    final gate = Completer<void>();
    _writeQueue = gate.future;
    await previous;
    try {
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(content, flush: true);
      try {
        await temp.rename(file.path);
      } catch (_) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        await temp.rename(file.path);
      }
    } finally {
      gate.complete();
    }
  }
}
