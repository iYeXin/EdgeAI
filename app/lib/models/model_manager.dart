import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'hub.dart';

const MethodChannel _storageChannel = MethodChannel('edge_ai/paths');

class _DownloadPaused implements Exception {
  const _DownloadPaused();
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}

Future<String> _sha256File(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}

class LocalModel {
  const LocalModel({
    required this.path,
    required this.mmprojPath,
    required this.size,
    this.repo,
    this.source,
    this.label,
  });

  final String path;
  final String? mmprojPath;
  final int size;
  final String? repo;
  final HubSource? source;
  final String? label;

  String get name => label ?? path.split(Platform.pathSeparator).last;
  bool get vision => mmprojPath != null;
}

class DownloadJob {
  DownloadJob({
    required this.model,
    required this.file,
    required this.target,
    this.total = 0,
  });

  final HubModel model;
  final HubFile file;
  final String target;
  int total;
  int received = 0;
  bool done = false;
  bool cancelled = false;
  bool paused = false;
  bool pauseRequested = false;
  bool inFlight = false;
  bool retrying = false;
  int retryAttempt = 0;
  String? error;
  double speedBps = 0;
  Duration? eta;
  HubProvider? provider;
  void Function(DownloadJob job)? onProgress;
  final DateTime createdAt = DateTime.now();
  DateTime? _sampleAt;
  int _sampleBytes = 0;
  final StreamController<DownloadJob> _updates =
      StreamController<DownloadJob>.broadcast();

  Stream<DownloadJob> get updates => _updates.stream;
  double get progress => total > 0 ? received / total : 0;
  bool get running =>
      inFlight && !done && !cancelled && !paused && error == null;

  void sampleSpeed() {
    final now = DateTime.now();
    if (_sampleAt == null) {
      _sampleAt = now;
      _sampleBytes = received;
      return;
    }
    final elapsed = now.difference(_sampleAt!).inMilliseconds / 1000.0;
    if (elapsed < 0.4) return;
    final delta = received - _sampleBytes;
    speedBps = delta > 0 ? delta / elapsed : 0;
    final left = total - received;
    eta = speedBps > 0 && left > 0
        ? Duration(seconds: (left / speedBps).ceil())
        : null;
    _sampleAt = now;
    _sampleBytes = received;
  }

  void emit() {
    if (!_updates.isClosed) _updates.add(this);
  }

  void cancel() {
    cancelled = true;
    pauseRequested = false;
    paused = false;
    retrying = false;
  }

  Future<void> dispose() => _updates.close();
}

class ModelManager {
  ModelManager(this.root);

  final Directory root;

  Future<void> ensureReady() async {
    await root.create(recursive: true);
  }

  Future<int> freeBytes() async {
    try {
      final value = await _storageChannel.invokeMethod<num>('getFreeBytes');
      return value?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<List<LocalModel>> scan() async {
    await ensureReady();
    final files = <File>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File && entity.path.toLowerCase().endsWith('.gguf')) {
        files.add(entity);
      }
    }
    final byDir = <String, List<File>>{};
    for (final file in files) {
      final dir = file.parent.path;
      byDir.putIfAbsent(dir, () => []).add(file);
    }
    final result = <LocalModel>[];
    for (final entry in byDir.entries) {
      String? mmproj;
      for (final file in entry.value) {
        final name = file.path.split(Platform.pathSeparator).last.toLowerCase();
        if (name.startsWith('mmproj') || name.contains('mmproj')) {
          mmproj = file.path;
          break;
        }
      }
      for (final file in entry.value) {
        final name = file.path.split(Platform.pathSeparator).last.toLowerCase();
        if (name.startsWith('mmproj') || name.contains('mmproj')) continue;
        result.add(
          LocalModel(
            path: file.path,
            mmprojPath: mmproj,
            size: await file.length(),
          ),
        );
      }
    }
    result.sort((a, b) => b.size.compareTo(a.size));
    return result;
  }

  Future<DownloadJob> download(
    HubProvider provider,
    HubModel model,
    HubFile file, {
    void Function(DownloadJob job)? onProgress,
  }) async {
    await ensureReady();
    final repoDir = Directory(
      '${root.path}/${_safe(model.source.label)}/${_safe(model.id)}',
    );
    await repoDir.create(recursive: true);
    final target =
        '${repoDir.path}/${file.path.replaceAll('/', Platform.pathSeparator)}';
    await File(target).parent.create(recursive: true);
    final job = DownloadJob(
      model: model,
      file: file,
      target: target,
      total: file.size,
    );
    job.provider = provider;
    job.onProgress = onProgress;
    onProgress?.call(job);
    unawaited(_download(job));
    return job;
  }

  void pause(DownloadJob job) {
    if (job.done || job.cancelled) return;
    job.pauseRequested = true;
    job.paused = true;
    job.retrying = false;
    job.speedBps = 0;
    job.eta = null;
    job.onProgress?.call(job);
    job.emit();
  }

  void resume(DownloadJob job) {
    if (job.done || job.cancelled || job.inFlight) return;
    job.paused = false;
    job.pauseRequested = false;
    job.error = null;
    job.retrying = false;
    job.retryAttempt = 0;
    job.onProgress?.call(job);
    job.emit();
    unawaited(_download(job));
  }

  Future<void> cancel(DownloadJob job) async {
    job.cancel();
    if (!job.inFlight) {
      try {
        final part = File('${job.target}.part');
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
    job.onProgress?.call(job);
    job.emit();
  }

  Future<void> _download(DownloadJob job) async {
    if (job.inFlight || job.done || job.cancelled) return;
    final provider = job.provider;
    if (provider == null) return;
    job.inFlight = true;
    job.error = null;
    job.retrying = false;
    job.retryAttempt = 0;
    final part = File('${job.target}.part');
    final free = await freeBytes();
    if (free > 0 && free < job.file.size + 256 * 1024 * 1024) {
      job.error = '磁盘空间不足：需要 ${_size(job.file.size)}，可用 ${_size(free)}';
      job.inFlight = false;
      job.onProgress?.call(job);
      job.emit();
      return;
    }

    for (var attempt = 0; attempt < 4; attempt++) {
      try {
        await _downloadAttempt(job);
        break;
      } on _DownloadPaused {
        job.paused = true;
        job.pauseRequested = false;
        job.retrying = false;
        break;
      } on _DownloadCancelled {
        job.cancelled = true;
        job.paused = false;
        job.pauseRequested = false;
        job.retrying = false;
        job.error = null;
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
        break;
      } catch (error) {
        if (job.cancelled || job.paused) break;
        if (attempt >= 3 || !_isRetryable(error)) {
          job.error = error.toString();
          break;
        }
        job.retryAttempt = attempt + 1;
        job.retrying = true;
        job.onProgress?.call(job);
        job.emit();
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
        job.retrying = false;
        if (job.cancelled || job.paused) break;
      }
    }

    job.inFlight = false;
    job.retrying = false;
    job.speedBps = 0;
    job.eta = null;
    if (job.cancelled) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
    job.onProgress?.call(job);
    job.emit();
  }

  Future<void> _downloadAttempt(DownloadJob job) async {
    final provider = job.provider!;
    final part = File('${job.target}.part');
    var existing = 0;
    if (await part.exists()) {
      existing = await part.length();
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    RandomAccessFile? raf;
    try {
      final uri = provider.downloadUri(job.model, job.file);
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'edge-ai/1.0');
      if (provider.token != null && provider.token!.isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${provider.token}',
        );
      }
      if (existing > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
      }
      final response = await request.close();
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw HubException('下载失败：HTTP ${response.statusCode}');
      }
      final append = response.statusCode == 206 && existing > 0;
      if (!append) existing = 0;
      final contentLength = response.contentLength;
      job.total = contentLength > 0 ? contentLength + existing : job.file.size;
      job.received = existing;
      raf = await part.open(mode: append ? FileMode.append : FileMode.write);
      await for (final chunk in response) {
        if (job.cancelled) throw const _DownloadCancelled();
        if (job.pauseRequested) throw const _DownloadPaused();
        await raf.writeFrom(chunk);
        job.received += chunk.length;
        job.sampleSpeed();
        job.onProgress?.call(job);
        job.emit();
      }
      await raf.close();
      raf = null;
      if (job.total > 0 && job.received < job.total) {
        throw HubException('下载不完整：${job.received}/${job.total}');
      }
      if (job.file.sha256 != null && job.file.sha256!.isNotEmpty) {
        final partPath = part.path;
        final actual = await Isolate.run(() => _sha256File(partPath));
        if (actual.toLowerCase() != job.file.sha256!.toLowerCase()) {
          await part.delete();
          throw const HubException('SHA256 校验失败，文件已删除');
        }
      }
      final target = File(job.target);
      if (await target.exists()) await target.delete();
      await part.rename(job.target);
      job.done = true;
      job.paused = false;
      job.pauseRequested = false;
      job.onProgress?.call(job);
      job.emit();
      await _writeMeta(job);
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
      client.close(force: true);
    }
  }

  bool _isRetryable(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('connection closed') ||
        text.contains('connection reset') ||
        text.contains('connection aborted') ||
        text.contains('socketexception') ||
        text.contains('timeout') ||
        text.contains('timed out') ||
        text.contains('handshake') ||
        text.contains('http 408') ||
        text.contains('http 429') ||
        text.contains('http 500') ||
        text.contains('http 502') ||
        text.contains('http 503') ||
        text.contains('http 504') ||
        text.contains('下载不完整');
  }

  Future<void> _writeMeta(DownloadJob job) async {
    final meta = File('${File(job.target).parent.path}/.edge_ai_meta.json');
    await meta.writeAsString(
      jsonEncode({
        'source': job.model.source.name,
        'repo': job.model.id,
        'file': job.file.path,
        'downloadedAt': DateTime.now().toIso8601String(),
      }),
    );
  }

  Future<void> delete(LocalModel model) async {
    final file = File(model.path);
    if (await file.exists()) await file.delete();
    if (model.mmprojPath != null) {
      final mm = File(model.mmprojPath!);
      if (await mm.exists()) await mm.delete();
    }
  }

  String _safe(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9._/-]'), '_');

  static String _size(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).round()} MB';
  }
}
