import 'package:flutter/material.dart';

import '../session/session_store.dart';
import 'core/app_theme.dart';
import 'widgets/app_components.dart';

class GlobalSettingsSheet extends StatefulWidget {
  const GlobalSettingsSheet({
    super.key,
    required this.store,
    required this.onOpenInference,
    required this.onOpenModels,
  });

  final SessionStore store;
  final VoidCallback onOpenInference;
  final VoidCallback onOpenModels;

  @override
  State<GlobalSettingsSheet> createState() => _GlobalSettingsSheetState();
}

class _GlobalSettingsSheetState extends State<GlobalSettingsSheet> {
  late bool _enabled = widget.store.stateCacheEnabled;
  late int _maxBytes = widget.store.stateCacheMaxBytes;
  int _cacheBytes = 0;
  bool _clearing = false;
  late bool _powerStats = widget.store.powerStatsEnabled;
  late bool _energyEstimate = widget.store.energyEstimateEnabled;
  late bool _energyPercent = widget.store.energyAsPercent;

  static const _choices = <int>[
    512 * 1024 * 1024,
    1024 * 1024 * 1024,
    2 * 1024 * 1024 * 1024,
    4 * 1024 * 1024 * 1024,
    8 * 1024 * 1024 * 1024,
    16 * 1024 * 1024 * 1024,
    20 * 1024 * 1024 * 1024,
  ];

  @override
  void initState() {
    super.initState();
    _refreshSize();
  }

  Future<void> _refreshSize() async {
    final bytes = await widget.store.stateCacheBytes();
    if (mounted) setState(() => _cacheBytes = bytes);
  }

  Future<void> _savePolicy() async {
    await widget.store.setStateCachePolicy(
      enabled: _enabled,
      maxBytes: _maxBytes,
    );
    await widget.store.evictStateCache(_maxBytes);
    await _refreshSize();
  }

  Future<void> _saveDisplayPolicy() async {
    await widget.store.setPowerDisplayPolicy(
      enabled: _powerStats,
      energy: _powerStats && _energyEstimate,
      energyPercent: _energyPercent,
    );
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('清理缓存？'),
        content: const Text('会删除所有会话的 KV state，下一次发送需要重新 prefill。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _clearing = true);
    await widget.store.clearStateCache();
    await _refreshSize();
    if (mounted) setState(() => _clearing = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('缓存已清理'),
          backgroundColor: AppColors.primaryDeep,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.78,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 10, 4),
              child: Row(
                children: [
                  const Text(
                    '设置',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: AppColors.ink,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const AppSectionHeader(title: '存储与缓存', overline: 'GLOBAL'),
                    const SizedBox(height: 8),
                    SurfaceCard(
                      padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _enabled,
                            title: const Text(
                              'KV 状态缓存',
                              style: AppText.bodyStrong,
                            ),
                            subtitle: const Text(
                              '长对话/多图生成后保存 KV state，重启或切回会话时跳过 prefill。磁盘不足时自动跳过。',
                              style: AppText.small,
                            ),
                            onChanged: (value) {
                              setState(() => _enabled = value);
                              _savePolicy();
                            },
                          ),
                          const Divider(height: 18, color: AppColors.line),
                          Row(
                            children: [
                              const Text('当前占用', style: AppText.small),
                              const SizedBox(width: 6),
                              Text(
                                _format(_cacheBytes),
                                style: AppText.smallStrong.copyWith(
                                  color: AppColors.primaryStrong,
                                ),
                              ),
                              const Spacer(),
                              TextButton(
                                onPressed: _clearing || _cacheBytes == 0
                                    ? null
                                    : _clear,
                                child: Text(_clearing ? '清理中…' : '清理缓存'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text('缓存上限', style: AppText.small),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 7,
                            runSpacing: 7,
                            children: [
                              for (final value in _choices)
                                ChoiceChip(
                                  label: Text(
                                    _format(value),
                                    style: const TextStyle(fontSize: 11.5),
                                  ),
                                  selected: _maxBytes == value,
                                  showCheckmark: false,
                                  selectedColor: AppColors.primaryWash,
                                  backgroundColor: AppColors.surfaceTint,
                                  side: BorderSide(
                                    color: _maxBytes == value
                                        ? AppColors.primary
                                        : AppColors.line,
                                  ),
                                  labelStyle: TextStyle(
                                    color: _maxBytes == value
                                        ? AppColors.primaryStrong
                                        : AppColors.muted,
                                    fontWeight: _maxBytes == value
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                  onSelected: (_) {
                                    setState(() => _maxBytes = value);
                                    _savePolicy();
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            '状态缓存按会话保存，超预算时优先淘汰最久未使用的会话。'
                            '默认在磁盘充足时开启，上限可到 20 GB。',
                            style: AppText.small,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    const AppSectionHeader(title: '推理统计', overline: 'DISPLAY'),
                    const SizedBox(height: 8),
                    SurfaceCard(
                      padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                      child: Column(
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _powerStats,
                            title: const Text(
                              '显示功耗统计',
                              style: AppText.bodyStrong,
                            ),
                            subtitle: const Text(
                              '生成结束后显示实时功率和每 token 能耗（J/tok）。',
                              style: AppText.small,
                            ),
                            onChanged: (value) {
                              setState(() {
                                _powerStats = value;
                                if (!value) _energyEstimate = false;
                              });
                              _saveDisplayPolicy();
                            },
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: _energyEstimate,
                            title: const Text(
                              '显示耗电量估算',
                              style: AppText.bodyStrong,
                            ),
                            subtitle: const Text(
                              '按生成期间功率积分估算本次生成的 Wh；仅为电池采样估算。',
                              style: AppText.small,
                            ),
                            onChanged: _powerStats
                                ? (value) {
                                    setState(() => _energyEstimate = value);
                                    _saveDisplayPolicy();
                                  }
                                : null,
                          ),
                          if (_powerStats && _energyEstimate) ...[
                            const Divider(height: 18, color: AppColors.line),
                            const Text('耗电量单位', style: AppText.small),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              children: [
                                ChoiceChip(
                                  label: const Text('Wh'),
                                  selected: !_energyPercent,
                                  showCheckmark: false,
                                  selectedColor: AppColors.primaryWash,
                                  backgroundColor: AppColors.surfaceTint,
                                  side: BorderSide(
                                    color: !_energyPercent
                                        ? AppColors.primary
                                        : AppColors.line,
                                  ),
                                  onSelected: (_) {
                                    setState(() => _energyPercent = false);
                                    _saveDisplayPolicy();
                                  },
                                ),
                                ChoiceChip(
                                  label: const Text('电池 %'),
                                  selected: _energyPercent,
                                  showCheckmark: false,
                                  selectedColor: AppColors.primaryWash,
                                  backgroundColor: AppColors.surfaceTint,
                                  side: BorderSide(
                                    color: _energyPercent
                                        ? AppColors.primary
                                        : AppColors.line,
                                  ),
                                  onSelected: (_) {
                                    setState(() => _energyPercent = true);
                                    _saveDisplayPolicy();
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '“电池 %”按整块电池容量折算；设备不暴露容量时自动回退为 Wh。',
                              style: AppText.small,
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    AppSoftButton(
                      label: '推理与后端设置',
                      onPressed: () {
                        Navigator.pop(context);
                        widget.onOpenInference();
                      },
                    ),
                    const SizedBox(height: 8),
                    AppSoftButton(
                      label: '模型管理',
                      onPressed: () {
                        Navigator.pop(context);
                        widget.onOpenModels();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _format(int bytes) {
    if (bytes <= 0) return '0 MB';
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(bytes / (1024 * 1024)).round()} MB';
  }
}
