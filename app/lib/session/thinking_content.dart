/// Splits raw assistant output into thinking and final answer sections.
///
/// Models are inconsistent: Qwen/DeepSeek style `...`, `<thinking>`,
/// `<|thinking|>` and `[THINK]` all appear in the wild. The raw message text is
/// never modified when persisted; this parser is only a view over it.
class ThinkingContent {
  const ThinkingContent({
    required this.thinking,
    required this.answer,
    required this.open,
  });

  final String thinking;
  final String answer;

  /// True when a thinking block has started but its closing tag has not arrived
  /// yet. This is normal while tokens are still streaming.
  final bool open;

  bool get hasThinking => thinking.trim().isNotEmpty;

  static final RegExp _openTag = RegExp(
    r'<(think|thinking|reasoning|analysis|thought)\s*>'
    r'|<\|(thinking|reasoning|analysis|think)\|>'
    r'|\[(think|thinking|reasoning|analysis)\]',
    caseSensitive: false,
  );

  static ThinkingContent parse(String raw) {
    if (raw.isEmpty) {
      return const ThinkingContent(thinking: '', answer: '', open: false);
    }

    final thinking = StringBuffer();
    final answer = StringBuffer();
    var cursor = 0;
    var open = false;

    while (cursor < raw.length) {
      final match = _openTag.firstMatch(raw.substring(cursor));
      if (match == null) {
        answer.write(raw.substring(cursor));
        break;
      }

      final start = cursor + match.start;
      answer.write(raw.substring(cursor, start));

      final kind = match.group(1) != null
          ? 0
          : match.group(2) != null
          ? 1
          : 2;
      final tag = (match.group(1) ?? match.group(2) ?? match.group(3) ?? '')
          .toLowerCase();
      final contentStart = cursor + match.end;
      final close = _closeTag(
        tag,
        kind,
      ).firstMatch(raw.substring(contentStart));

      if (close == null) {
        thinking.write(raw.substring(contentStart));
        open = true;
        break;
      }

      final part = raw.substring(contentStart, contentStart + close.start);
      if (part.trim().isNotEmpty) {
        if (thinking.isNotEmpty) thinking.write('\n\n');
        thinking.write(part.trim());
      }
      cursor = contentStart + close.end;
    }

    if (!open && thinking.isEmpty) {
      return ThinkingContent(
        thinking: '',
        answer: answer.toString().trim(),
        open: false,
      );
    }

    return ThinkingContent(
      thinking: thinking.toString().trim(),
      answer: answer.toString().trim(),
      open: open,
    );
  }

  static RegExp _closeTag(String tag, int kind) {
    final escaped = RegExp.escape(tag);
    return switch (kind) {
      0 => RegExp('</\\s*$escaped\\s*>', caseSensitive: false),
      1 => RegExp(
        '<\\|/\\s*$escaped\\s*\\|>|</\\|\\s*$escaped\\s*\\|>',
        caseSensitive: false,
      ),
      _ => RegExp('\\[\\s*/\\s*$escaped\\s*\\]', caseSensitive: false),
    };
  }
}
