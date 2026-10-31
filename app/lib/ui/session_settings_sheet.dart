import 'package:flutter/material.dart';

import '../session/session_store.dart';
import 'core/app_theme.dart';
import 'widgets/app_components.dart';

class SessionSettingsValue {
  const SessionSettingsValue({
    required this.systemPrompt,
    required this.temperature,
    required this.topP,
    required this.topK,
    required this.repeatPenalty,
    required this.maxTokens,
    required this.remember,
  });

  final String systemPrompt;
  final double temperature;
  final double topP;
  final int topK;
  final double repeatPenalty;
  final int maxTokens;
  final bool remember;
}

class SessionSettingsSheet extends StatefulWidget {
  const SessionSettingsSheet({
    super.key,
    required this.session,
    required this.defaultSystemPrompt,
    required this.defaultMaxTokens,
  });

  final ChatSession session;
  final String defaultSystemPrompt;
  final int defaultMaxTokens;

  @override
  State<SessionSettingsSheet> createState() => _SessionSettingsSheetState();
}

class _SessionSettingsSheetState extends State<SessionSettingsSheet> {
  late final TextEditingController _prompt = TextEditingController(
    text: widget.session.systemPrompt ?? '',
  );
  late double _temperature = widget.session.temperature ?? 0.7;
  late double _topP = widget.session.topP ?? 0.95;
  late int _topK = widget.session.topK ?? 40;
  late double _repeatPenalty = widget.session.repeatPenalty ?? 1.1;
  late int _maxTokens = widget.session.maxTokens ?? widget.defaultMaxTokens;
  late bool _remember = widget.session.rememberSettings;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.86,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 10, 4),
              child: Row(
                children: [
                  const Text(
                    '会话参数',
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
                    const AppSectionHeader(title: '提示词', overline: 'SESSION'),
                    const SizedBox(height: 8),
                    AppTextField(
                      controller: _prompt,
                      placeholder: '留空使用默认系统提示词',
                      maxLines: 5,
                      minLines: 3,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '修改系统提示词会使该会话的 KV state 缓存失效，下一轮需要重新 prefill。'
                      '模型、上下文和线程仍由全局设置控制，变更会触发模型重载。',
                      style: AppText.small,
                    ),
                    const SizedBox(height: 18),
                    const AppSectionHeader(
                      title: '采样参数',
                      overline: 'GENERATION',
                    ),
                    const SizedBox(height: 8),
                    SurfaceCard(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
                      child: Column(
                        children: [
                          _SliderRow(
                            label: 'Temperature',
                            value: _temperature.toStringAsFixed(2),
                            slider: Slider(
                              value: _temperature,
                              min: 0,
                              max: 1.5,
                              divisions: 30,
                              onChanged: (v) =>
                                  setState(() => _temperature = v),
                            ),
                          ),
                          _SliderRow(
                            label: 'Top P',
                            value: _topP.toStringAsFixed(2),
                            slider: Slider(
                              value: _topP,
                              min: 0.1,
                              max: 1,
                              divisions: 18,
                              onChanged: (v) => setState(() => _topP = v),
                            ),
                          ),
                          _SliderRow(
                            label: 'Top K',
                            value: '$_topK',
                            slider: Slider(
                              value: _topK.toDouble(),
                              min: 1,
                              max: 100,
                              divisions: 99,
                              onChanged: (v) =>
                                  setState(() => _topK = v.round()),
                            ),
                          ),
                          _SliderRow(
                            label: 'Repeat penalty',
                            value: _repeatPenalty.toStringAsFixed(2),
                            slider: Slider(
                              value: _repeatPenalty,
                              min: 1,
                              max: 1.5,
                              divisions: 25,
                              onChanged: (v) =>
                                  setState(() => _repeatPenalty = v),
                            ),
                          ),
                          _SliderRow(
                            label: '最大输出',
                            value: '$_maxTokens tok',
                            slider: Slider(
                              value: _maxTokens.toDouble(),
                              min: 64,
                              max: 1024,
                              divisions: 15,
                              onChanged: (v) => setState(
                                () => _maxTokens = (v / 64).round() * 64,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _remember,
                      title: const Text('记住本会话设置', style: AppText.bodyStrong),
                      subtitle: const Text(
                        '关闭后本次修改只在当前运行期间生效，重启 App 恢复默认。',
                        style: AppText.small,
                      ),
                      onChanged: (v) => setState(() => _remember = v),
                    ),
                    const SizedBox(height: 12),
                    AppPrimaryButton(
                      label: '应用',
                      onPressed: () {
                        Navigator.pop(
                          context,
                          SessionSettingsValue(
                            systemPrompt: _prompt.text.trim(),
                            temperature: _temperature,
                            topP: _topP,
                            topK: _topK,
                            repeatPenalty: _repeatPenalty,
                            maxTokens: _maxTokens,
                            remember: _remember,
                          ),
                        );
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
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.slider,
  });

  final String label;
  final String value;
  final Widget slider;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Text(label, style: AppText.smallStrong),
            const Spacer(),
            Text(
              value,
              style: AppText.smallStrong.copyWith(
                color: AppColors.primaryStrong,
              ),
            ),
          ],
        ),
        SizedBox(height: 32, child: slider),
      ],
    );
  }
}
