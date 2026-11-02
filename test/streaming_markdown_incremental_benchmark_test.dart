import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:open_builder/features/conversation/message_autolink.dart';

Widget plainCodeBuilder(
  BuildContext context,
  String name,
  String code,
  bool closed,
) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF161B22),
      borderRadius: BorderRadius.circular(8),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Text(
        code,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          color: Color(0xFFEC407A),
        ),
      ),
    ),
  );
}

void main() {
  final mdSheet = MarkdownStyleSheet(
    p: const TextStyle(fontSize: 14, height: 1.45),
    pPadding: const EdgeInsets.only(bottom: 6),
    code: const TextStyle(fontFamily: 'monospace', fontSize: 13),
    strong: const TextStyle(fontWeight: FontWeight.w600),
    blockquote: const TextStyle(fontStyle: FontStyle.italic),
    listBullet: const TextStyle(fontSize: 14),
    tableHead: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    tableBody: const TextStyle(fontSize: 13),
  );

  Widget mdHost(String data) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownBody(
              data: data,
              styleSheet: mdSheet,
            ),
          ),
        ),
      );

  Widget gptHost(String data) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GptMarkdown(
              data,
              style: const TextStyle(fontSize: 14, height: 1.45),
              animation: GptMarkdownAnimation.none,
              blockAnimation: GptMarkdownBlockAnimation.none,
              isStreaming: false,
              autolink: false,
            ),
          ),
        ),
      );

  Widget gptPlainCodeHost(String data) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GptMarkdown(
              data,
              style: const TextStyle(fontSize: 14, height: 1.45),
              animation: GptMarkdownAnimation.none,
              blockAnimation: GptMarkdownBlockAnimation.none,
              isStreaming: false,
              autolink: false,
              codeBuilder: plainCodeBuilder,
            ),
          ),
        ),
      );

  String paragraphs(int lines, {int lineLength = 80}) {
    final buf = StringBuffer();
    for (var i = 0; i < lines; i++) {
      if (i > 0 && i % 4 == 0) buf.writeln();
      buf.writeln(List.filled(lineLength, 'x').join());
    }
    return buf.toString();
  }

  String bulletList(int lines) => List.generate(
        lines,
        (i) => '- item $i ${List.filled(50, 'y').join()}',
      ).join('\n');

  String orderedList(int lines) => List.generate(
        lines,
        (i) => '${i + 1}. step $i ${List.filled(50, 'z').join()}',
      ).join('\n');

  String quote(int lines) => List.generate(
        lines,
        (i) => '> quoted $i ${List.filled(50, 'q').join()}',
      ).join('\n');

  String table(int rows) {
    final buf = StringBuffer('| col0 | col1 | col2 | col3 |\n');
    buf.writeln('|---|---|---|---|');
    for (var i = 0; i < rows; i++) {
      buf.writeln('| $i | ${List.filled(15, 'a').join()} | ${List.filled(15, 'b').join()} | ${List.filled(15, 'c').join()} |');
    }
    return buf.toString();
  }

  String codeFence(int lines) {
    final buf = StringBuffer('```dart\n');
    for (var i = 0; i < lines; i++) {
      buf.writeln('final v$i = ${List.filled(20, 'v').join()};');
    }
    buf.writeln('```');
    return buf.toString();
  }

  List<String> prefixes(String doc, int count) {
    final lines = doc.split('\n');
    final step = (lines.length / count).ceil();
    return List.generate(
      count,
      (i) {
        var end = (i + 1) * step;
        if (end > lines.length) end = lines.length;
        return lines.take(end).join('\n');
      },
      growable: false,
    );
  }

  Future<void> measureAppends(
    WidgetTester tester,
    String name,
    String doc,
    Widget Function(String) host,
    int checkpoints, {
    bool printEach = false,
  }) async {
    final ps = prefixes(doc, checkpoints);
    await tester.pumpWidget(host(ps.first));
    await tester.pump();
    final times = <double>[];
    for (var i = 1; i < ps.length; i++) {
      final sw = Stopwatch()..start();
      await tester.pumpWidget(host(ps[i]));
      await tester.pump();
      sw.stop();
      times.add(sw.elapsedMicroseconds / 1000);
    }
    final avg = times.reduce((a, b) => a + b) / times.length;
    final max = times.reduce((a, b) => a > b ? a : b);
    final p95 = times..sort();
    final p95v = p95[(p95.length * 0.95).ceil() - 1];
    debugPrint(
      '$name avg=${avg.toStringAsFixed(2)}ms p95=${p95v.toStringAsFixed(2)}ms max=${max.toStringAsFixed(2)}ms',
    );
    if (printEach) {
      debugPrint(times.map((t) => t.toStringAsFixed(2)).join(', '));
    }
  }

  testWidgets('markdown_body paragraphs incremental', (tester) async {
    await measureAppends(
      tester,
      'markdown_body paragraphs_2KB',
      paragraphs(25),
      mdHost,
      5,
    );
  });

  testWidgets('markdown_body list incremental', (tester) async {
    await measureAppends(
      tester,
      'markdown_body bullets_200',
      bulletList(200),
      mdHost,
      5,
    );
  });

  testWidgets('gpt_markdown paragraphs incremental', (tester) async {
    await measureAppends(
      tester,
      'gpt_markdown paragraphs_2KB',
      paragraphs(25),
      gptHost,
      5,
    );
  });

  testWidgets('gpt_markdown list incremental', (tester) async {
    await measureAppends(
      tester,
      'gpt_markdown bullets_200',
      bulletList(200),
      gptHost,
      5,
    );
  });

  testWidgets('gpt_markdown ordered list incremental', (tester) async {
    await measureAppends(
      tester,
      'gpt_markdown ordered_200',
      orderedList(200),
      gptHost,
      5,
    );
  });

  testWidgets('gpt_markdown quote incremental', (tester) async {
    await measureAppends(
      tester,
      'gpt_markdown quote_100',
      quote(100),
      gptHost,
      5,
    );
  });

  testWidgets('gpt_markdown table incremental', (tester) async {
    await measureAppends(
      tester,
      'gpt_markdown table_50',
      table(50),
      gptHost,
      5,
    );
  });

  testWidgets('gpt_markdown code fence incremental', (tester) async {
    await measureAppends(
      tester,
      'gpt_markdown code_300',
      codeFence(300),
      gptHost,
      5,
    );
  });

  testWidgets('gpt_markdown code fence plain incremental', (tester) async {
    await measureAppends(
      tester,
      'gpt_markdown code_plain_300',
      codeFence(300),
      gptPlainCodeHost,
      5,
    );
  });

  testWidgets('markdown_body paragraphs per line', (tester) async {
    await measureAppends(
      tester,
      'markdown_body paragraphs_25_lines',
      paragraphs(25),
      mdHost,
      25,
    );
  });

  testWidgets('gpt_markdown paragraphs per line', (tester) async {
    await measureAppends(
      tester,
      'gpt_markdown paragraphs_25_lines',
      paragraphs(25),
      gptHost,
      25,
    );
  });

  testWidgets('gpt_markdown paragraphs 16KB per line', (tester) async {
    await measureAppends(
      tester,
      'gpt_markdown paragraphs_16KB_200_lines',
      paragraphs(200),
      gptHost,
      200,
    );
  });

  testWidgets('gpt_markdown bullets per line', (tester) async {
    await measureAppends(
      tester,
      'gpt_markdown bullets_200_lines',
      bulletList(200),
      gptHost,
      200,
    );
  });

  testWidgets('gpt_markdown ordered list per line', (tester) async {
    await measureAppends(
      tester,
      'gpt_markdown ordered_200_lines',
      orderedList(200),
      gptHost,
      200,
    );
  });

  testWidgets('gpt_markdown table per row', (tester) async {
    await measureAppends(
      tester,
      'gpt_markdown table_50_rows',
      table(50),
      gptHost,
      50,
    );
  });

  testWidgets('gpt_markdown quote per line', (tester) async {
    await measureAppends(
      tester,
      'gpt_markdown quote_100_lines',
      quote(100),
      gptHost,
      100,
    );
  });

  testWidgets('gpt_markdown plain code per line', (tester) async {
    await measureAppends(
      tester,
      'gpt_markdown code_plain_300_lines',
      codeFence(300),
      gptPlainCodeHost,
      300,
    );
  });

  test('autolink prefix cost', () {
    final docs = <String, String>{
      '2KB': paragraphs(25),
      '8KB': paragraphs(100),
      '16KB': paragraphs(200),
      'bullets_200': bulletList(200),
      'table_50': table(50),
      'code_300': codeFence(300),
    };
    for (final e in docs.entries) {
      final ps = prefixes(e.value, 5);
      final times = <double>[];
      for (var i = 1; i < ps.length; i++) {
        final sw = Stopwatch()..start();
        autolinkMarkdownLinks(ps[i]);
        sw.stop();
        times.add(sw.elapsedMicroseconds / 1000);
      }
      final avg = times.reduce((a, b) => a + b) / times.length;
      final max = times.reduce((a, b) => a > b ? a : b);
      debugPrint(
        'autolink ${e.key} avg=${avg.toStringAsFixed(2)}ms max=${max.toStringAsFixed(2)}ms',
      );
    }
  });
}
