import 'package:flutter_test/flutter_test.dart';

import 'package:edge_ai/session/thinking_content.dart';

void main() {
  test('splits deepseek style think block', () {
    final parsed = ThinkingContent.parse('<think>思考：先分析问题。</think>\n\n最终答案。');
    expect(parsed.open, isFalse);
    expect(parsed.thinking, '思考：先分析问题。');
    expect(parsed.answer, '最终答案。');
  });

  test('splits qwen style think block', () {
    final parsed = ThinkingContent.parse(
      '<thinking>先检查约束</thinking>\n\n答案在这里。',
    );
    expect(parsed.thinking, '先检查约束');
    expect(parsed.answer, '答案在这里。');
  });

  test('splits piped thinking block', () {
    final parsed = ThinkingContent.parse('<|thinking|>内部推理</|thinking|>回答');
    expect(parsed.thinking, '内部推理');
    expect(parsed.answer, '回答');
  });

  test('keeps unfinished thinking block open while streaming', () {
    final parsed = ThinkingContent.parse('<think>还在想');
    expect(parsed.open, isTrue);
    expect(parsed.thinking, '还在想');
    expect(parsed.answer, isEmpty);
  });

  test('accepts square and reasoning tags', () {
    final parsed = ThinkingContent.parse(
      '[THINK]第一步[/THINK]\n<reasoning>第二步</reasoning>\n结果',
    );
    expect(parsed.thinking, contains('第一步'));
    expect(parsed.thinking, contains('第二步'));
    expect(parsed.answer, '结果');
  });

  test('accepts gemma channel thought blocks', () {
    final parsed = ThinkingContent.parse(
      '<|channel>thought Thinking Process:\n'
      '1. Analyze the request.\n'
      '<|channel|>9.9 大。',
    );
    expect(parsed.thinking, contains('Thinking Process'));
    expect(parsed.thinking, contains('Analyze the request'));
    expect(parsed.answer, '9.9 大。');
  });

  test('plain assistant output is unchanged', () {
    final parsed = ThinkingContent.parse('普通回答，不包含思考标签。');
    expect(parsed.hasThinking, isFalse);
    expect(parsed.answer, '普通回答，不包含思考标签。');
  });

  test('trims leading blank lines when thinking is enabled but unused', () {
    final parsed = ThinkingContent.parse('\n\n普通回答');
    expect(parsed.hasThinking, isFalse);
    expect(parsed.answer, '普通回答');
  });
}
