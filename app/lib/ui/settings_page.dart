import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/edge_ai.dart';
import 'chat_page_controller.dart';
import 'core/app_theme.dart';
import 'widgets/app_components.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller, this.onBack});

  final ChatPageController controller;
  final VoidCallback? onBack;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late ComputeBackend _backend;
  late int _threads;
  late int _context;
  late int _memory;
  late int _maxTokens;
  late bool _thinking;
  int _cacheBytes = 0;
  bool _cacheRequested = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _applyFromController();
    widget.controller.addListener(_onController);
    _refreshCache();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    super.dispose();
  }

  void _applyFromController() {
    final s = widget.controller.settings;
    _backend = s.backend;
    _threads = s.threads;
    _context = s.contextSize;
    _memory = s.memoryBudgetMb;
    _maxTokens = s.maxTokens;
    _thinking = s.thinking;
  }

  void _onController() {
    if (!mounted) return;
    if (!_dirty) setState(_applyFromController);
    if (!_cacheRequested && widget.controller.store != null) {
      unawaited(_refreshCache());
    }
  }

  Future<void> _refreshCache() async {
    final store = widget.controller.store;
    if (store == null) return;
    _cacheRequested = true;
    final bytes = await store.stateCacheBytes();
    if (mounted) setState(() => _cacheBytes = bytes);
  }

  void _mark(VoidCallback fn) {
    setState(() {
      _dirty = true;
      fn();
    });
  }

  BorderSide _chipSide(bool selected) =>
      BorderSide(color: selected ? AppColors.primary : AppColors.line);

  Future<int?> _askNumber({
    required String title,
    required int initial,
    required int min,
    required int max,
    required String suffix,
  }) async {
    final controller = TextEditingController(text: '$initial');
    final value = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            suffixText: suffix,
            helperText: '范围 $min–$max',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final parsed = int.tryParse(controller.text);
              if (parsed == null) return;
              Navigator.pop(dialogContext, parsed.clamp(min, max));
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  Future<void> _customContext() async {
    final limit = (widget.controller.info?.nCtxTrain ?? 0) > 0
        ? widget.controller.info!.nCtxTrain
        : 1048576;
    final value = await _askNumber(
      title: '自定义上下文',
      initial: _context > 0 ? _context : 32768,
      min: 64,
      max: limit,
      suffix: 'tokens',
    );
    if (value != null) _mark(() => _context = value);
  }

  Future<void> _customMaxTokens() async {
    final limit = (widget.controller.info?.nCtxTrain ?? 0) > 0
        ? widget.controller.info!.nCtxTrain
        : 131072;
    final value = await _askNumber(
      title: '自定义最大输出',
      initial: _maxTokens,
      min: 64,
      max: limit,
      suffix: 'tokens',
    );
    if (value != null) _mark(() => _maxTokens = value);
  }

  Future<void> _apply() async {
    widget.controller.applySettings(
      InferenceSettings(
        backend: _backend,
        threads: _threads,
        contextSize: _context,
        memoryBudgetMb: _memory,
        maxTokens: _maxTokens.clamp(
          64,
          (widget.controller.info?.nCtxTrain ?? 0) > 0
              ? widget.controller.info!.nCtxTrain
              : 131072,
        ),
        thinking: _thinking,
      ),
    );
    setState(() => _dirty = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('设置已应用'),
        backgroundColor: AppColors.primaryDeep,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.controller.store;
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final modelCtxLimit = widget.controller.info?.nCtxTrain ?? 0;
        final maxOutputLimit = modelCtxLimit > 0 ? modelCtxLimit : 131072;
        final contextValues = <int>{0, 4096, 8192, 16384, 32768};
        if (_context > 0) contextValues.add(_context);
        if (modelCtxLimit > 0) contextValues.add(modelCtxLimit);
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            toolbarHeight: 68,
            leading: widget.onBack == null
                ? null
                : IconButton(
                    tooltip: '返回聊天',
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
            title: const Text('设置', style: AppText.title),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
            children: [
              const AppSectionHeader(title: '推理', overline: 'ENGINE'),
              const SizedBox(height: 8),
              SurfaceCard(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.controller.info != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          '模型 ${(widget.controller.info!.modelBytes / (1024 * 1024)).round()} MB · '
                          'KV ${(widget.controller.info!.kvBytes / (1024 * 1024)).round()} MB · '
                          'ctx ${widget.controller.info!.nCtx} / 模型上限 ${widget.controller.info!.nCtxTrain}',
                          style: AppText.small,
                        ),
                      ),
                    const Text('后端', style: AppText.small),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('Vulkan GPU'),
                          selected: _backend == ComputeBackend.vulkan,
                          showCheckmark: false,
                          selectedColor: AppColors.primaryWash,
                          backgroundColor: AppColors.surfaceTint,
                          side: BorderSide(
                            color: _backend == ComputeBackend.vulkan
                                ? AppColors.primary
                                : AppColors.line,
                          ),
                          onSelected: (_) =>
                              _mark(() => _backend = ComputeBackend.vulkan),
                        ),
                        ChoiceChip(
                          label: const Text('仅 CPU'),
                          selected: _backend == ComputeBackend.cpu,
                          showCheckmark: false,
                          selectedColor: AppColors.primaryWash,
                          backgroundColor: AppColors.surfaceTint,
                          side: BorderSide(
                            color: _backend == ComputeBackend.cpu
                                ? AppColors.primary
                                : AppColors.line,
                          ),
                          onSelected: (_) =>
                              _mark(() => _backend = ComputeBackend.cpu),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text('CPU 线程', style: AppText.small),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final value in const [2, 4, 6, 8])
                          ChoiceChip(
                            label: Text('$value'),
                            selected: _threads == value,
                            showCheckmark: false,
                            selectedColor: AppColors.primaryWash,
                            backgroundColor: AppColors.surfaceTint,
                            side: _chipSide(_threads == value),
                            onSelected: (_) => _mark(() => _threads = value),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text('上下文', style: AppText.small),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final value in contextValues)
                          ChoiceChip(
                            label: Text(
                              value == 0
                                  ? '自动'
                                  : value == modelCtxLimit
                                  ? '模型上限 $value'
                                  : '$value',
                            ),
                            selected: _context == value,
                            showCheckmark: false,
                            selectedColor: AppColors.primaryWash,
                            backgroundColor: AppColors.surfaceTint,
                            side: _chipSide(_context == value),
                            onSelected: (_) => _mark(() => _context = value),
                          ),
                        ActionChip(
                          avatar: const Icon(Icons.edit_outlined, size: 15),
                          label: const Text('自定义'),
                          onPressed: _customContext,
                        ),
                      ],
                    ),
                    if (modelCtxLimit > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '模型训练上下文上限 $modelCtxLimit tokens',
                          style: AppText.small,
                        ),
                      ),
                    const SizedBox(height: 16),
                    const Text('内存预算', style: AppText.small),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final value in const [0, 2048, 4096, 6144, 8192])
                          ChoiceChip(
                            label: Text(value == 0 ? '自动' : '${value}M'),
                            selected: _memory == value,
                            showCheckmark: false,
                            selectedColor: AppColors.primaryWash,
                            backgroundColor: AppColors.surfaceTint,
                            side: _chipSide(_memory == value),
                            onSelected: (_) => _mark(() => _memory = value),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Text('最大输出', style: AppText.small),
                        const Spacer(),
                        TextButton(
                          onPressed: _customMaxTokens,
                          child: const Text('自定义'),
                        ),
                        Text(
                          '$_maxTokens tok',
                          style: AppText.smallStrong.copyWith(
                            color: AppColors.primaryStrong,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _maxTokens.clamp(64, maxOutputLimit).toDouble(),
                      min: 64,
                      max: maxOutputLimit.toDouble(),
                      divisions: null,
                      onChanged: (v) =>
                          _mark(() => _maxTokens = (v / 64).round() * 64),
                    ),
                    Text(
                      '可设置到模型上下文上限 $maxOutputLimit tokens；实际可用长度还受 prompt 占用影响。',
                      style: AppText.small,
                    ),
                    const SizedBox(height: 8),
                    AppPrimaryButton(label: '应用并重载', onPressed: _apply),
                    const SizedBox(height: 6),
                    const Text(
                      '后端、线程、上下文或内存预算变化会重新加载模型。',
                      style: AppText.small,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              const AppSectionHeader(title: '图像输入', overline: 'MULTIMODAL'),
              const SizedBox(height: 8),
              SurfaceCard(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                child: store == null
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('存储初始化中…', style: AppText.small),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: store.imageCompressionEnabled,
                            title: const Text(
                              '自动压缩图像',
                              style: AppText.bodyStrong,
                            ),
                            subtitle: const Text(
                              '选择图片时按宽度缩放并重新编码，减少视觉 token 与嵌入耗时。',
                              style: AppText.small,
                            ),
                            onChanged: (value) async {
                              await store.setImageInputPolicy(
                                enabled: value,
                                maxWidth: store.imageMaxWidth,
                              );
                              if (mounted) setState(() {});
                            },
                          ),
                          if (store.imageCompressionEnabled) ...[
                            const SizedBox(height: 4),
                            const Text('最大宽度', style: AppText.small),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final value in const [
                                  768,
                                  1024,
                                  1280,
                                  1600,
                                ])
                                  ChoiceChip(
                                    label: Text('$value px'),
                                    selected: store.imageMaxWidth == value,
                                    showCheckmark: false,
                                    selectedColor: AppColors.primaryWash,
                                    side: BorderSide(
                                      color: store.imageMaxWidth == value
                                          ? AppColors.primary
                                          : AppColors.line,
                                    ),
                                    onSelected: (_) async {
                                      await store.setImageInputPolicy(
                                        enabled: true,
                                        maxWidth: value,
                                      );
                                      if (mounted) setState(() {});
                                    },
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '该设置影响新选择的图片；关闭压缩后按原图交由 native 处理。',
                              style: AppText.small,
                            ),
                          ],
                        ],
                      ),
              ),
              const SizedBox(height: 18),
              const AppSectionHeader(title: '缓存', overline: 'STORAGE'),
              const SizedBox(height: 8),
              SurfaceCard(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (store != null)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: store.stateCacheEnabled,
                        title: const Text('KV 状态缓存', style: AppText.bodyStrong),
                        subtitle: const Text(
                          '长对话/多图保存 KV state，重启后按前缀复用。',
                          style: AppText.small,
                        ),
                        onChanged: (value) async {
                          await store.setStateCachePolicy(
                            enabled: value,
                            maxBytes: store.stateCacheMaxBytes,
                          );
                          if (!mounted) return;
                          setState(() {});
                          _refreshCache();
                        },
                      ),
                    if (store != null) ...[
                      Row(
                        children: [
                          Text(
                            '当前占用 ${_formatBytes(_cacheBytes)}',
                            style: AppText.small,
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () async {
                              await store.clearStateCache();
                              await _refreshCache();
                            },
                            child: const Text('清理缓存'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text('缓存上限', style: AppText.small),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final value in const [
                            512,
                            1024,
                            2048,
                            4096,
                            8192,
                            16384,
                            20480,
                          ])
                            ChoiceChip(
                              label: Text(_formatBytes(value * 1024 * 1024)),
                              selected:
                                  store.stateCacheMaxBytes ==
                                  value * 1024 * 1024,
                              showCheckmark: false,
                              selectedColor: AppColors.primaryWash,
                              backgroundColor: AppColors.surfaceTint,
                              side: _chipSide(
                                store.stateCacheMaxBytes == value * 1024 * 1024,
                              ),
                              onSelected: (_) async {
                                await store.setStateCachePolicy(
                                  enabled: store.stateCacheEnabled,
                                  maxBytes: value * 1024 * 1024,
                                );
                                await store.evictStateCache(
                                  value * 1024 * 1024,
                                );
                                if (mounted) setState(() {});
                                await _refreshCache();
                              },
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),
              const AppSectionHeader(title: '显示', overline: 'DISPLAY'),
              const SizedBox(height: 8),
              SurfaceCard(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                child: store == null
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('存储初始化中…', style: AppText.small),
                      )
                    : Column(
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: store.powerStatsEnabled,
                            title: const Text(
                              '显示功耗统计',
                              style: AppText.bodyStrong,
                            ),
                            subtitle: const Text(
                              '功率和 J/token。',
                              style: AppText.small,
                            ),
                            onChanged: (value) async {
                              await store.setPowerDisplayPolicy(
                                enabled: value,
                                energy: value && store.energyEstimateEnabled,
                                energyPercent: store.energyAsPercent,
                              );
                              if (mounted) setState(() {});
                            },
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: store.energyEstimateEnabled,
                            title: const Text(
                              '显示耗电量估算',
                              style: AppText.bodyStrong,
                            ),
                            subtitle: const Text(
                              'Wh 或电池容量百分比。',
                              style: AppText.small,
                            ),
                            onChanged: store.powerStatsEnabled
                                ? (value) async {
                                    await store.setPowerDisplayPolicy(
                                      enabled: store.powerStatsEnabled,
                                      energy: value,
                                      energyPercent: store.energyAsPercent,
                                    );
                                    if (mounted) setState(() {});
                                  }
                                : null,
                          ),
                          if (store.powerStatsEnabled &&
                              store.energyEstimateEnabled)
                            Row(
                              children: [
                                const Text('单位', style: AppText.small),
                                const SizedBox(width: 10),
                                ChoiceChip(
                                  label: const Text('Wh'),
                                  selected: !store.energyAsPercent,
                                  showCheckmark: false,
                                  side: _chipSide(!store.energyAsPercent),
                                  onSelected: (_) async {
                                    await store.setPowerDisplayPolicy(
                                      enabled: true,
                                      energy: true,
                                      energyPercent: false,
                                    );
                                    if (mounted) setState(() {});
                                  },
                                ),
                                const SizedBox(width: 8),
                                ChoiceChip(
                                  label: const Text('电池 %'),
                                  selected: store.energyAsPercent,
                                  showCheckmark: false,
                                  side: _chipSide(store.energyAsPercent),
                                  onSelected: (_) async {
                                    await store.setPowerDisplayPolicy(
                                      enabled: true,
                                      energy: true,
                                      energyPercent: true,
                                    );
                                    if (mounted) setState(() {});
                                  },
                                ),
                              ],
                            ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).round()} MB';
  }
}
