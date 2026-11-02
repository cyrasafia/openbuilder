import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/features/conversation/conversation_screen.dart';

void main() {
  test('closeUnmatchedFence appends a matching closing fence', () {
    const src = '```dart\ncode\n';
    final result = closeUnmatchedFence(src);
    expect(result, '```dart\ncode\n```\n');
  });

  test('closeUnmatchedFence leaves a closed fence unchanged', () {
    const src = '~~~\ncode\n~~~\n';
    expect(closeUnmatchedFence(src), src);
  });

  test('closeUnmatchedFence rejects a backtick fence with backticks in info',
      () {
    const src = '``` foo `bar`\ncode\n';
    expect(closeUnmatchedFence(src), src);
  });

  test('closeUnmatchedFence ignores a fence indented by four spaces', () {
    const src = '    ```dart\ncode\n';
    expect(closeUnmatchedFence(src), src);
  });

  test('buildMarkdownSource hides the unfinished first line', () {
    expect(buildMarkdownSource('**bold', false), '');
  });

  test('buildMarkdownSource renders only the completed line prefix', () {
    const raw = 'first line\nsecond **incomplete';
    final result = buildMarkdownSource(raw, false);
    expect(result, contains('first line'));
    expect(result, isNot(contains('second **incomplete')));
  });

  test('buildMarkdownSource returns the full source after settle', () {
    const raw = 'first line\nsecond line';
    expect(buildMarkdownSource(raw, true), raw);
  });
}
