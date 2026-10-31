import 'dart:async';

import 'package:flutter/material.dart';

import '../engine/edge_ai.dart';
import 'chat_page_controller.dart';
import 'core/app_theme.dart';
import 'widgets/app_components.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final ChatPageController controller;

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

  Future<void> _apply() async {
    widget.controller.applySettings(
      InferenceSettings(
        backend: _backend,
        threads: _threads,
        contextSize: _context,
        memoryBudgetMb: _memory,
        maxTokens: _maxTokens,
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
        return Scaffold(
          backgroundColor: AppColors.background,
          appBar: AppBar(
            toolbarHeight: 68,
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
                          'ctx ${widget.controller.info!.nCtx}',
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
                        for (final value in const [0, 4096, 8192, 16384, 32768])
                          ChoiceChip(
                            label: Text(value == 0 ? '自动' : '$value'),
                            selected: _context == value,
                            showCheckmark: false,
                            selectedColor: AppColors.primaryWash,
                            backgroundColor: AppColors.surfaceTint,
                            onSelected: (_) => _mark(() => _context = value),
                          ),
                      ],
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
                            onSelected: (_) => _mark(() => _memory = value),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        const Text('最大输出', style: AppText.small),
                        const Spacer(),
                        Text(
                          '$_maxTokens tok',
                          style: AppText.smallStrong.copyWith(
                            color: AppColors.primaryStrong,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _maxTokens.toDouble(),
                      min: 64,
                      max: 1024,
                      divisions: 15,
                      onChanged: (v) =>
                          _mark(() => _maxTokens = (v / 64).round() * 64),
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
