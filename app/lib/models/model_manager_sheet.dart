import 'dart:async';

import 'package:flutter/material.dart';

import 'hub.dart';
import 'model_manager.dart';
import '../ui/core/app_theme.dart';

const _surface = AppColors.surface;
const _surfaceHigh = AppColors.surfaceTint;
const _accent = AppColors.primary;
const _muted = AppColors.muted;
const _text = AppColors.ink;
const _line = AppColors.line;
const _danger = AppColors.red;

class ModelManagerSheet extends StatefulWidget {
  const ModelManagerSheet({
    super.key,
    required this.manager,
    this.currentPath,
    this.pageMode = false,
    this.onSelected,
  });

  final ModelManager manager;
  final String? currentPath;
  final bool pageMode;
  final ValueChanged<LocalModel>? onSelected;

  @override
  State<ModelManagerSheet> createState() => _ModelManagerSheetState();
}

class _ModelManagerSheetState extends State<ModelManagerSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final TextEditingController _search = TextEditingController();
  final Map<String, DownloadJob> _jobs = <String, DownloadJob>{};
  final List<DownloadJob> _activeJobs = <DownloadJob>[];

  List<LocalModel> _local = <LocalModel>[];
  List<HubModel> _results = <HubModel>[];
  List<HubFile> _files = <HubFile>[];
  HubModel? _selectedModel;
  HubSource _source = HubSource.modelScope;
  bool _loading = false;
  bool _searching = false;
  bool _downloading = false;
  bool _finishingBatch = false;
  String? _error;
  String? _tagFilter;
  String? _modelScopeToken;
  String? _hfToken;
  HubProvider get _provider => _source == HubSource.modelScope
      ? ModelScopeProvider(token: _modelScopeToken)
      : HuggingFaceProvider(mirror: true, token: _hfToken);

  @override
  void initState() {
    super.initState();
    _refreshLocal();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    for (final job in _jobs.values) {
      job.dispose();
    }
    super.dispose();
  }

  Future<void> _refreshLocal() async {
    setState(() => _loading = true);
    try {
      final local = await widget.manager.scan();
      if (mounted) setState(() => _local = local);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runSearch() async {
    final query = _search.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _error = null;
      _results = <HubModel>[];
      _files = <HubFile>[];
      _selectedModel = null;
      _tagFilter = null;
    });
    try {
      final results = await _provider.search(query);
      if (mounted) setState(() => _results = results);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _openModel(HubModel model) async {
    setState(() {
      _selectedModel = model;
      _searching = true;
      _files = <HubFile>[];
      _error = null;
    });
    try {
      final files = await _provider.files(model);
      files.sort((a, b) => b.size.compareTo(a.size));
      if (mounted) setState(() => _files = files);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _download(HubModel model, HubFile main) async {
    final mmproj = _files.where((f) => f.isMmproj).toList();
    final prefix = main.splitPrefix;
    final shards = prefix == null
        ? <HubFile>[main]
        : _files.where((f) => f.splitPrefix == prefix).toList();
    final queue = <HubFile>[];
    for (final file in [...shards, ...mmproj.take(1)]) {
      if (!queue.any((f) => f.path == file.path)) queue.add(file);
    }
    final totalBytes = queue.fold<int>(0, (sum, f) => sum + f.size);
    final free = await widget.manager.freeBytes();
    if (free > 0 && free < totalBytes + 512 * 1024 * 1024) {
      setState(() {
        _error = '磁盘不足：需要 ${_size(totalBytes)}，可用 ${_size(free)}';
      });
      return;
    }
    _activeJobs.clear();
    _finishingBatch = false;
    setState(() {
      _error = null;
      _downloading = true;
    });

    final batch = <DownloadJob>[];
    try {
      for (final file in queue) {
        final job = await widget.manager.download(
          _provider,
          model,
          file,
          onProgress: (job) => _onJobProgress(job, batch, main),
        );
        batch.add(job);
        _activeJobs.add(job);
        _jobs[job.target] = job;
      }
      if (mounted) {
        setState(() {
          _downloading = _activeJobs.any((job) => job.running);
        });
      }
      _maybeFinishBatch(batch, main);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  void _onJobProgress(DownloadJob job, List<DownloadJob> batch, HubFile main) {
    if (!mounted) return;
    setState(() {
      _jobs[job.target] = job;
      _downloading = _activeJobs.any((item) => item.running);
      if (job.error != null) _error = job.error;
    });
    _maybeFinishBatch(batch, main);
  }

  void _maybeFinishBatch(List<DownloadJob> batch, HubFile main) {
    if (_finishingBatch || batch.isEmpty || batch.any((job) => !job.done)) {
      return;
    }
    _finishingBatch = true;
    unawaited(_finishBatch(batch, main));
  }

  Future<void> _finishBatch(List<DownloadJob> batch, HubFile main) async {
    await _refreshLocal();
    if (!mounted) {
      _finishingBatch = false;
      return;
    }
    final local = _local.where((m) => m.path.endsWith(main.name)).firstOrNull;
    if (local != null) {
      if (widget.pageMode) {
        widget.onSelected?.call(local);
      } else {
        Navigator.pop(context, local);
      }
    } else {
      setState(() => _error = '下载完成，但未在本地索引中找到模型');
    }
    _activeJobs.clear();
    setState(() => _downloading = false);
    _finishingBatch = false;
  }

  Future<void> _openDownloadManager() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black26,
      isScrollControlled: true,
      builder: (_) => _DownloadManagerSheet(
        manager: widget.manager,
        jobs: _jobs.values.toList(),
        onChanged: () {
          if (mounted) setState(() {});
        },
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _editToken() async {
    final isScope = _source == HubSource.modelScope;
    final controller = TextEditingController(
      text: (isScope ? _modelScopeToken : _hfToken) ?? '',
    );
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _surface,
        title: Text(isScope ? 'ModelScope Token' : 'HuggingFace Token'),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: true,
          decoration: const InputDecoration(hintText: '可选，用于私有/受限仓库'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || value == null) return;
    setState(() {
      final token = value.trim();
      if (isScope) {
        _modelScopeToken = token.isEmpty ? null : token;
      } else {
        _hfToken = token.isEmpty ? null : token;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: widget.pageMode
            ? double.infinity
            : MediaQuery.sizeOf(context).height * 0.82,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 10, 6),
              child: Row(
                children: [
                  const Text(
                    '模型',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '下载管理',
                    onPressed: _openDownloadManager,
                    icon: Badge.count(
                      count: _jobs.values
                          .where((job) => job.running || job.paused)
                          .length,
                      isLabelVisible: _jobs.values.any(
                        (job) => job.running || job.paused,
                      ),
                      backgroundColor: _accent,
                      child: const Icon(
                        Icons.download_for_offline_outlined,
                        color: _muted,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Hub Token',
                    onPressed: _editToken,
                    icon: Icon(
                      (_source == HubSource.modelScope
                                  ? _modelScopeToken
                                  : _hfToken) !=
                              null
                          ? Icons.key_rounded
                          : Icons.key_outlined,
                      color: _muted,
                    ),
                  ),
                  if (!widget.pageMode)
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded, color: _muted),
                    ),
                ],
              ),
            ),
            TabBar(
              controller: _tabs,
              labelColor: _accent,
              unselectedLabelColor: _muted,
              indicatorColor: _accent,
              tabs: const [
                Tab(text: '本地模型'),
                Tab(text: '下载模型'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [_buildLocal(), _buildHub()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLocal() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }
    if (_local.isEmpty) {
      return const Center(
        child: Text('还没有本地模型，去“下载模型”添加', style: TextStyle(color: _muted)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: _local.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final model = _local[index];
        final selected = model.path == widget.currentPath;
        return Container(
          decoration: BoxDecoration(
            color: selected ? _surfaceHigh : _surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? _accent : _line),
          ),
          child: ListTile(
            title: Text(
              model.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? _accent : _text,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              '${_size(model.size)}${model.vision ? ' · 视觉' : ''}',
              style: const TextStyle(color: _muted, fontSize: 11),
            ),
            trailing: IconButton(
              onPressed: model.path == widget.currentPath
                  ? null
                  : () async {
                      await widget.manager.delete(model);
                      await _refreshLocal();
                    },
              icon: const Icon(
                Icons.delete_outline_rounded,
                color: _muted,
                size: 20,
              ),
            ),
            onTap: () {
              if (widget.pageMode) {
                widget.onSelected?.call(model);
              } else {
                Navigator.pop(context, model);
              }
            },
          ),
        );
      },
    );
  }

  Widget _buildHub() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
          child: Row(
            children: [
              SegmentedButton<HubSource>(
                segments: const [
                  ButtonSegment(value: HubSource.modelScope, label: Text('魔搭')),
                  ButtonSegment(
                    value: HubSource.huggingFace,
                    label: Text('HF 镜像'),
                  ),
                ],
                selected: {_source},
                onSelectionChanged: (value) => setState(() {
                  _source = value.first;
                  _results = <HubModel>[];
                  _files = <HubFile>[];
                  _selectedModel = null;
                }),
                style: const ButtonStyle(
                  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _search,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _runSearch(),
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: '搜索 GGUF 模型',
                    hintStyle: const TextStyle(color: _muted, fontSize: 12),
                    isDense: true,
                    filled: true,
                    fillColor: _surface,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _line),
                    ),
                    suffixIcon: IconButton(
                      onPressed: _runSearch,
                      icon: const Icon(Icons.search_rounded, size: 19),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Text(
              _error!,
              style: const TextStyle(color: AppColors.red, fontSize: 11),
            ),
          ),
        Expanded(
          child: _searching
              ? const Center(child: CircularProgressIndicator(color: _accent))
              : _selectedModel != null
              ? _buildFiles()
              : _buildResults(),
        ),
      ],
    );
  }

  Widget _buildResults() {
    if (_results.isEmpty) {
      return const Center(
        child: Text(
          '输入关键词，从魔搭 / HuggingFace 搜索 GGUF',
          style: TextStyle(color: _muted),
        ),
      );
    }
    final tags = <String>{};
    for (final model in _results) {
      for (final tag in model.tags) {
        if (tag.trim().isNotEmpty && !tag.startsWith('region:')) {
          tags.add(tag.trim());
        }
      }
    }
    final shownTags = tags.take(12).toList();
    final filtered = _tagFilter == null
        ? _results
        : _results
              .where(
                (m) => m.tags.any(
                  (t) => t.toLowerCase() == _tagFilter!.toLowerCase(),
                ),
              )
              .toList();
    return Column(
      children: [
        if (shownTags.isNotEmpty)
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final tag in shownTags)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(tag, style: const TextStyle(fontSize: 10.5)),
                      selected: _tagFilter?.toLowerCase() == tag.toLowerCase(),
                      showCheckmark: false,
                      selectedColor: _accent.withValues(alpha: 0.14),
                      backgroundColor: _surface,
                      side: BorderSide(
                        color: _tagFilter?.toLowerCase() == tag.toLowerCase()
                            ? _accent
                            : _line,
                      ),
                      onSelected: (_) => setState(
                        () => _tagFilter = _tagFilter == tag ? null : tag,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    '没有匹配「$_tagFilter」的结果',
                    style: const TextStyle(color: _muted, fontSize: 12),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final model = filtered[index];
                    return InkWell(
                      onTap: () => _openModel(model),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                        decoration: BoxDecoration(
                          color: _surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _line),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    model.id,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: _text,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const Icon(
                                  Icons.chevron_right_rounded,
                                  color: _muted,
                                  size: 18,
                                ),
                              ],
                            ),
                            if (model.description.trim().isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(
                                  model.description.replaceAll(
                                    RegExp(r'\s+'),
                                    ' ',
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: _muted,
                                    fontSize: 10.5,
                                    height: 1.35,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 5),
                            Wrap(
                              spacing: 10,
                              runSpacing: 3,
                              children: [
                                Text(
                                  '↓ ${_count(model.downloads)}',
                                  style: const TextStyle(
                                    color: _muted,
                                    fontSize: 10,
                                  ),
                                ),
                                Text(
                                  '♥ ${_count(model.likes)}',
                                  style: const TextStyle(
                                    color: _muted,
                                    fontSize: 10,
                                  ),
                                ),
                                if (model.updatedLabel != null)
                                  Text(
                                    model.updatedLabel!,
                                    style: const TextStyle(
                                      color: _muted,
                                      fontSize: 10,
                                    ),
                                  ),
                                if (model.fileSize > 0)
                                  Text(
                                    '仓库 ${_size(model.fileSize)}',
                                    style: const TextStyle(
                                      color: _muted,
                                      fontSize: 10,
                                    ),
                                  ),
                              ],
                            ),
                            if (model.tags.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Wrap(
                                  spacing: 5,
                                  runSpacing: 4,
                                  children: [
                                    for (final tag in model.tags.take(8))
                                      GestureDetector(
                                        onTap: () =>
                                            setState(() => _tagFilter = tag),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: _surfaceHigh,
                                            borderRadius: BorderRadius.circular(
                                              5,
                                            ),
                                          ),
                                          child: Text(
                                            tag,
                                            style: const TextStyle(
                                              color: _muted,
                                              fontSize: 9.5,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildFiles() {
    final gguf = _files.where((f) => f.isGguf).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
          child: Row(
            children: [
              IconButton(
                onPressed: () => setState(() {
                  _selectedModel = null;
                  _files = <HubFile>[];
                }),
                icon: const Icon(
                  Icons.arrow_back_rounded,
                  color: _muted,
                  size: 19,
                ),
              ),
              Expanded(
                child: Text(
                  _selectedModel!.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _text, fontSize: 12),
                ),
              ),
              if (_downloading)
                IconButton(
                  tooltip: '取消下载',
                  onPressed: () {
                    for (final job in _activeJobs) {
                      unawaited(widget.manager.cancel(job));
                    }
                  },
                  icon: const Icon(
                    Icons.stop_circle_outlined,
                    color: _danger,
                    size: 20,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: gguf.isEmpty
              ? const Center(
                  child: Text('该仓库没有 GGUF 文件', style: TextStyle(color: _muted)),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  itemCount: gguf.length,
                  separatorBuilder: (_, _) =>
                      const Divider(color: _line, height: 1),
                  itemBuilder: (context, index) {
                    final file = gguf[index];
                    final job = _jobs.values
                        .where((j) => j.file.path == file.path)
                        .firstOrNull;
                    return ListTile(
                      dense: true,
                      title: Text(
                        file.path,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _text, fontSize: 11),
                      ),
                      subtitle: job == null
                          ? Text(
                              file.size > 0 ? _size(file.size) : '文件大小未知',
                              style: const TextStyle(
                                color: _muted,
                                fontSize: 10,
                              ),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                LinearProgressIndicator(
                                  value: job.progress == 0
                                      ? null
                                      : job.progress,
                                  color: _accent,
                                  backgroundColor: _line,
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  job.done
                                      ? '已下载 · ${_size(job.received)}'
                                      : '${_size(job.received)} / '
                                            '${job.total > 0 ? _size(job.total) : '未知'}'
                                            '${job.speedBps > 0 ? ' · ${_size(job.speedBps.round())}/s' : ''}'
                                            '${job.eta != null ? ' · 剩余 ${_duration(job.eta!)}' : ''}',
                                  style: const TextStyle(
                                    color: _muted,
                                    fontSize: 9.5,
                                  ),
                                ),
                              ],
                            ),
                      trailing: job != null && !job.done && job.error == null
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _accent,
                              ),
                            )
                          : const Icon(
                              Icons.download_rounded,
                              color: _accent,
                              size: 20,
                            ),
                      onTap: (_searching || _downloading)
                          ? null
                          : () => _download(_selectedModel!, file),
                    );
                  },
                ),
        ),
      ],
    );
  }

  static String _size(int bytes) {
    if (bytes <= 0) return '未知大小';
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).round()} MB';
    return '${(bytes / 1024).round()} KB';
  }

  static String _count(int value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
    return '$value';
  }

  static String _duration(Duration value) {
    if (value.inHours > 0) {
      return '${value.inHours}h${value.inMinutes % 60}m';
    }
    if (value.inMinutes > 0) {
      return '${value.inMinutes}m${value.inSeconds % 60}s';
    }
    return '${value.inSeconds}s';
  }
}

class _DownloadManagerSheet extends StatefulWidget {
  const _DownloadManagerSheet({
    required this.manager,
    required this.jobs,
    required this.onChanged,
  });

  final ModelManager manager;
  final List<DownloadJob> jobs;
  final VoidCallback onChanged;

  @override
  State<_DownloadManagerSheet> createState() => _DownloadManagerSheetState();
}

class _DownloadManagerSheetState extends State<_DownloadManagerSheet> {
  late final List<DownloadJob> _jobs = List<DownloadJob>.of(widget.jobs);
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final jobs = _jobs.toList()
      ..sort((a, b) {
        int rank(DownloadJob job) {
          if (job.running) return 0;
          if (job.paused) return 1;
          if (job.error != null) return 2;
          if (job.done) return 3;
          return 4;
        }

        return rank(a).compareTo(rank(b));
      });
    final active = jobs.where((job) => job.running || job.paused).length;
    return Container(
      height: MediaQuery.sizeOf(context).height * 0.72,
      decoration: const BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
              child: Row(
                children: [
                  const Text(
                    '下载管理',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 8),
                  if (active > 0)
                    Text(
                      '$active 个进行中',
                      style: const TextStyle(color: _muted, fontSize: 11),
                    ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: _muted),
                  ),
                ],
              ),
            ),
            Expanded(
              child: jobs.isEmpty
                  ? const Center(
                      child: Text(
                        '暂无下载任务',
                        style: TextStyle(color: _muted, fontSize: 12),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
                      itemCount: jobs.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, index) => _jobCard(jobs[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _jobCard(DownloadJob job) {
    final total = job.total > 0 ? job.total : job.file.size;
    final progress = total > 0 ? (job.received / total).clamp(0.0, 1.0) : 0.0;
    final status = job.done
        ? '已完成'
        : job.cancelled
        ? '已取消'
        : job.paused
        ? '已暂停'
        : job.error != null
        ? '下载失败'
        : '下载中';

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      decoration: BoxDecoration(
        color: _surfaceHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  job.model.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _text,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                status,
                style: TextStyle(
                  color: job.error != null
                      ? _danger
                      : job.done
                      ? _accent
                      : _muted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            job.file.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _muted, fontSize: 10),
          ),
          const SizedBox(height: 7),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: job.done ? 1 : progress,
              minHeight: 5,
              color: job.cancelled ? _muted : _accent,
              backgroundColor: _line,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: Text(
                  job.error != null && !job.done
                      ? job.error!
                      : '${_downloadSize(job.received)} / '
                            '${_downloadSize(total)}'
                            '${job.running && job.speedBps > 0 ? ' · ${_downloadSize(job.speedBps.round())}/s' : ''}'
                            '${job.running && job.eta != null ? ' · 剩余 ${_downloadTime(job.eta!)}' : ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: job.error != null && !job.done ? _danger : _muted,
                    fontSize: 9.5,
                  ),
                ),
              ),
              if (job.running) ...[
                _action(
                  icon: Icons.pause_rounded,
                  tooltip: '暂停',
                  onTap: () {
                    widget.manager.pause(job);
                    widget.onChanged();
                    setState(() {});
                  },
                ),
                _action(
                  icon: Icons.close_rounded,
                  tooltip: '取消',
                  color: _danger,
                  onTap: () async {
                    await widget.manager.cancel(job);
                    widget.onChanged();
                    if (mounted) setState(() {});
                  },
                ),
              ] else if (job.paused) ...[
                _action(
                  icon: Icons.play_arrow_rounded,
                  tooltip: '继续',
                  onTap: () {
                    widget.manager.resume(job);
                    widget.onChanged();
                    setState(() {});
                  },
                ),
                _action(
                  icon: Icons.close_rounded,
                  tooltip: '取消',
                  color: _danger,
                  onTap: () async {
                    await widget.manager.cancel(job);
                    widget.onChanged();
                    if (mounted) setState(() {});
                  },
                ),
              ] else if (job.error != null && !job.cancelled) ...[
                _action(
                  icon: Icons.refresh_rounded,
                  tooltip: '重试',
                  onTap: () {
                    widget.manager.resume(job);
                    widget.onChanged();
                    setState(() {});
                  },
                ),
                _action(
                  icon: Icons.close_rounded,
                  tooltip: '取消',
                  color: _danger,
                  onTap: () async {
                    await widget.manager.cancel(job);
                    widget.onChanged();
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color color = _muted,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      padding: const EdgeInsets.all(5),
      icon: Icon(icon, color: color, size: 18),
    );
  }
}

String _downloadSize(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).round()} MB';
  }
  return '${(bytes / 1024).round()} KB';
}

String _downloadTime(Duration value) {
  if (value.inHours > 0) return '${value.inHours}h${value.inMinutes % 60}m';
  if (value.inMinutes > 0) return '${value.inMinutes}m${value.inSeconds % 60}s';
  return '${value.inSeconds}s';
}
