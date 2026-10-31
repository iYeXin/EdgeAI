import 'dart:async';
import 'dart:convert';
import 'dart:io';

enum HubSource { huggingFace, modelScope }

extension HubSourceLabel on HubSource {
  String get label => switch (this) {
    HubSource.huggingFace => 'HuggingFace',
    HubSource.modelScope => 'ModelScope',
  };
}

class HubModel {
  HubModel({
    required this.source,
    required this.id,
    this.downloads = 0,
    this.likes = 0,
    this.fileSize = 0,
    this.tags = const <String>[],
    this.description = '',
    this.lastModified,
    this.pipelineTag,
    this.libraryName,
    this.paramCount,
  });

  final HubSource source;
  final String id;
  final int downloads;
  final int likes;
  final int fileSize;
  final List<String> tags;
  final String description;
  final DateTime? lastModified;
  final String? pipelineTag;
  final String? libraryName;
  final String? paramCount;

  String get displayName => id.split('/').last;
  String get owner => id.contains('/') ? id.split('/').first : '';
  String? get updatedLabel {
    final time = lastModified;
    if (time == null) return null;
    final diff = DateTime.now().difference(time);
    if (diff.inDays < 1) return '今天更新';
    if (diff.inDays < 30) return '${diff.inDays} 天前更新';
    if (diff.inDays < 365) return '${(diff.inDays / 30).round()} 个月前更新';
    return '${(diff.inDays / 365).toStringAsFixed(1)} 年前更新';
  }

  bool get looksVision => tags.any(
    (t) =>
        t.toLowerCase().contains('vision') ||
        t.toLowerCase().contains('multimodal'),
  );
  bool get looksGguf =>
      tags.any((t) => t.toLowerCase().contains('gguf')) ||
      id.toLowerCase().contains('gguf');
}

class HubFile {
  const HubFile({
    required this.path,
    required this.size,
    this.isDirectory = false,
    this.sha256,
  });
  final String path;
  final int size;
  final bool isDirectory;
  final String? sha256;

  String get name => path.split('/').last;
  bool get isGguf => path.toLowerCase().endsWith('.gguf');
  bool get isMmproj =>
      name.toLowerCase().startsWith('mmproj') ||
      name.toLowerCase().contains('mmproj');

  String? get splitPrefix {
    final match = RegExp(
      r'^(.*)-\d{5}-of-\d{5}\.gguf$',
      caseSensitive: false,
    ).firstMatch(path);
    return match?.group(1);
  }

  bool get isSplit => splitPrefix != null;
}

class HubException implements Exception {
  const HubException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class HubProvider {
  HubSource get source;
  String get baseUrl;
  String? get token;

  Future<List<HubModel>> search(String query, {int limit = 20});
  Future<List<HubFile>> files(HubModel model);
  Uri downloadUri(HubModel model, HubFile file);
}

class HuggingFaceProvider extends HubProvider {
  HuggingFaceProvider({this.mirror = true, this.token});

  final bool mirror;
  @override
  final String? token;

  @override
  HubSource get source => HubSource.huggingFace;

  @override
  String get baseUrl =>
      mirror ? 'https://hf-mirror.com' : 'https://huggingface.co';

  @override
  Future<List<HubModel>> search(String query, {int limit = 20}) async {
    final uri = Uri.parse(
      '$baseUrl/api/models?search=${Uri.encodeQueryComponent(query)}'
      '&filter=gguf&limit=$limit&sort=downloads&direction=-1',
    );
    final data = await _getJson(uri);
    final list = data is List ? data : const [];
    return list
        .whereType<Map>()
        .map((item) {
          final tags = (item['tags'] as List? ?? const [])
              .map((e) => e.toString())
              .toList();
          return HubModel(
            source: source,
            id: item['id'] as String? ?? item['modelId'] as String? ?? '',
            downloads: (item['downloads'] as num?)?.toInt() ?? 0,
            likes: (item['likes'] as num?)?.toInt() ?? 0,
            tags: tags,
            description: item['description'] as String? ?? '',
            lastModified: DateTime.tryParse(
              item['lastModified'] as String? ??
                  item['last_modified'] as String? ??
                  '',
            ),
            pipelineTag: item['pipeline_tag'] as String?,
            libraryName: item['library_name'] as String?,
            paramCount: item['safetensors'] is Map
                ? '${(item['safetensors'] as Map)['total'] ?? ''}'
                : null,
          );
        })
        .where((m) => m.id.isNotEmpty)
        .toList();
  }

  @override
  Future<List<HubFile>> files(HubModel model) async {
    final uri = Uri.parse('$baseUrl/api/models/${model.id}?blobs=true');
    final data = await _getJson(uri);
    final siblings = (data as Map)['siblings'] as List? ?? const [];
    return siblings
        .whereType<Map>()
        .map((item) {
          final path = item['rfilename'] as String? ?? '';
          return HubFile(
            path: path,
            size:
                (item['size'] as num?)?.toInt() ??
                ((item['lfs'] as Map?)?['size'] as num?)?.toInt() ??
                0,
            sha256: (item['lfs'] as Map?)?['oid'] as String?,
          );
        })
        .where((f) => f.path.isNotEmpty)
        .toList();
  }

  @override
  Uri downloadUri(HubModel model, HubFile file) {
    final path = file.path.split('/').map(Uri.encodeComponent).join('/');
    return Uri.parse('$baseUrl/${model.id}/resolve/main/$path?download=true');
  }

  Future<dynamic> _getJson(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'edge-ai/1.0');
      if (token != null && token!.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HubException(
          'HuggingFace HTTP ${response.statusCode}: ${body.substring(0, body.length.clamp(0, 200))}',
        );
      }
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }
}

class ModelScopeProvider extends HubProvider {
  ModelScopeProvider({this.token});

  @override
  final String? token;

  @override
  HubSource get source => HubSource.modelScope;

  @override
  String get baseUrl => 'https://modelscope.cn';

  @override
  Future<List<HubModel>> search(String query, {int limit = 20}) async {
    final uri = Uri.parse(
      '$baseUrl/openapi/v1/models?PageSize=$limit&PageNumber=1&search=${Uri.encodeQueryComponent(query)}',
    );
    final data = await _getJson(uri);
    final models =
        ((data as Map)['data'] as Map?)?['models'] as List? ?? const [];
    return models
        .whereType<Map>()
        .map((item) {
          return HubModel(
            source: source,
            id: item['id'] as String? ?? '',
            downloads: (item['downloads'] as num?)?.toInt() ?? 0,
            likes: (item['likes'] as num?)?.toInt() ?? 0,
            fileSize: (item['file_size'] as num?)?.toInt() ?? 0,
            tags: (item['tags'] as List? ?? const [])
                .map((e) => e.toString())
                .toList(),
            description: item['description'] as String? ?? '',
            lastModified: DateTime.tryParse(
              item['last_updated'] as String? ??
                  item['lastModified'] as String? ??
                  '',
            ),
            pipelineTag:
                item['tasks'] is List && (item['tasks'] as List).isNotEmpty
                ? (item['tasks'] as List).first.toString()
                : null,
            libraryName: item['library_name'] as String?,
          );
        })
        .where((m) => m.id.isNotEmpty)
        .toList();
  }

  @override
  Future<List<HubFile>> files(HubModel model) async {
    final uri = Uri.parse(
      '$baseUrl/api/v1/models/${model.id}/repo/files?Recursive=true&Revision=master',
    );
    final data = await _getJson(uri);
    final files =
        ((data as Map)['Data'] as Map?)?['Files'] as List? ?? const [];
    return files
        .whereType<Map>()
        .map((item) {
          return HubFile(
            path: item['Path'] as String? ?? '',
            size: (item['Size'] as num?)?.toInt() ?? 0,
            isDirectory: item['Type'] == 'tree',
            sha256: item['Sha256'] as String?,
          );
        })
        .where((f) => f.path.isNotEmpty)
        .toList();
  }

  @override
  Uri downloadUri(HubModel model, HubFile file) {
    final path = file.path.split('/').map(Uri.encodeComponent).join('/');
    return Uri.parse('$baseUrl/models/${model.id}/resolve/master/$path');
  }

  Future<dynamic> _getJson(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, 'edge-ai/1.0');
      if (token != null && token!.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HubException(
          'ModelScope HTTP ${response.statusCode}: ${body.substring(0, body.length.clamp(0, 200))}',
        );
      }
      return jsonDecode(body);
    } finally {
      client.close(force: true);
    }
  }
}
