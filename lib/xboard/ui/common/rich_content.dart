import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:material_ui/material_ui.dart';

import 'widgets.dart';

/// A `[{feature, support}]` item of a plan's content (LiquidNext
/// `parseFeatures`).
class XcFeature {
  final String feature;
  final bool support;

  const XcFeature(this.feature, this.support);
}

/// Plan content may be a JSON feature list instead of markdown/HTML.
List<XcFeature>? parseXcFeatures(String? content) {
  final text = (content ?? '').trim();
  if (!text.startsWith('[') && !text.startsWith('{')) return null;
  try {
    final data = jsonDecode(text);
    final list = data is List ? data : (data is Map ? data.values : const []);
    final features = [
      for (final item in list)
        if (item is Map && item.containsKey('feature'))
          XcFeature(
            '${item['feature']}',
            item['support'] == true ||
                item['support'] == 1 ||
                item['support'] == '1',
          ),
    ];
    return features.isEmpty ? null : features;
  } on FormatException {
    return null;
  }
}

enum XcBlockType { heading, paragraph, bullet, quote, code, rule }

/// A piece of inline text: plain, bold, code or a link.
class XcInline {
  final String text;
  final bool bold;
  final bool code;
  final String? url;

  const XcInline(this.text, {this.bold = false, this.code = false, this.url});

  @override
  String toString() =>
      'XcInline($text${bold ? ', bold' : ''}${code ? ', code' : ''}'
      '${url != null ? ', $url' : ''})';
}

class XcBlock {
  final XcBlockType type;
  final List<XcInline> inlines;

  /// Heading level (1–6) or the ordinal of a numbered list item.
  final int level;
  final String? marker;

  const XcBlock(this.type, this.inlines, {this.level = 0, this.marker});

  String get plainText => inlines.map((e) => e.text).join();
}

final _htmlTag = RegExp(r'<[a-zA-Z!/][^>]*>');

/// Admin-authored HTML (notices, knowledge base, plan descriptions) turned
/// into the markdown subset [parseXcBlocks] reads. Scripts and styles go;
/// nothing is executed or loaded.
String xcHtmlToMarkdown(String html) {
  var text = html
      .replaceAll(
        RegExp(r'<(script|style)[^>]*>[\s\S]*?</\1\s*>', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(RegExp(r'\r\n?'), '\n');
  text = text.replaceAllMapped(
    RegExp(
      r'''<a\b[^>]*?href\s*=\s*["']([^"']*)["'][^>]*>([\s\S]*?)</a\s*>''',
      caseSensitive: false,
    ),
    (m) => '[${m[2]!.replaceAll(_htmlTag, '').trim()}](${m[1]})',
  );
  text = text.replaceAllMapped(
    RegExp(
      r'''<img\b[^>]*?src\s*=\s*["']([^"']*)["'][^>]*>''',
      caseSensitive: false,
    ),
    (m) => '[图片](${m[1]})',
  );
  text = text
      .replaceAllMapped(
        RegExp(r'<h([1-6])\b[^>]*>', caseSensitive: false),
        (m) => '\n${'#' * int.parse(m[1]!)} ',
      )
      .replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '\n- ')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<hr\b[^>]*>', caseSensitive: false), '\n---\n')
      .replaceAll(RegExp(r'</?(strong|b)\b[^>]*>', caseSensitive: false), '**')
      .replaceAll(
        RegExp(
          r'</(p|div|h[1-6]|li|ul|ol|tr|table|blockquote|section)\s*>',
          caseSensitive: false,
        ),
        '\n',
      )
      .replaceAll(_htmlTag, '');
  return _decodeEntities(text);
}

String _decodeEntities(String text) {
  return text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (m) => String.fromCharCode(int.parse(m[1]!)),
      )
      .replaceAll('&amp;', '&');
}

final _inlinePattern = RegExp(
  r'!?\[([^\]]*)\]\(([^)\s]+)\)|\*\*(.+?)\*\*|__(.+?)__|`([^`]+)`',
);

final _safeUrl = RegExp(r'^(https?:|mailto:)', caseSensitive: false);

List<XcInline> parseXcInlines(String text) {
  final result = <XcInline>[];
  var index = 0;
  for (final match in _inlinePattern.allMatches(text)) {
    if (match.start > index) {
      result.add(XcInline(text.substring(index, match.start)));
    }
    final whole = match[0]!;
    if (match[2] != null) {
      final isImage = whole.startsWith('!');
      final label = match[1]!.isEmpty
          ? (isImage ? '图片' : match[2]!)
          : match[1]!;
      final url = match[2]!;
      result.add(
        XcInline(
          isImage ? '[$label]' : label,
          url: _safeUrl.hasMatch(url) ? url : null,
        ),
      );
    } else if (match[3] != null || match[4] != null) {
      result.add(XcInline(match[3] ?? match[4]!, bold: true));
    } else if (match[5] != null) {
      result.add(XcInline(match[5]!, code: true));
    }
    index = match.end;
  }
  if (index < text.length) result.add(XcInline(text.substring(index)));
  return result;
}

/// Markdown (or HTML, converted first) as blocks: headings, paragraphs,
/// list items, quotes, code and rules. Enough for notices, articles and
/// plan descriptions; tables and nested lists flatten to text.
List<XcBlock> parseXcBlocks(String? source) {
  var text = (source ?? '').replaceAll(RegExp(r'\r\n?'), '\n');
  if (_htmlTag.hasMatch(text)) text = xcHtmlToMarkdown(text);
  final blocks = <XcBlock>[];
  final paragraph = <String>[];
  void flush() {
    if (paragraph.isEmpty) return;
    blocks.add(
      XcBlock(XcBlockType.paragraph, parseXcInlines(paragraph.join('\n'))),
    );
    paragraph.clear();
  }

  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i];
    final line = raw.trim();
    if (line.startsWith('```')) {
      flush();
      final code = <String>[];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith('```')) {
        code.add(lines[i]);
        i++;
      }
      blocks.add(
        XcBlock(XcBlockType.code, [XcInline(code.join('\n'), code: true)]),
      );
      continue;
    }
    if (line.isEmpty) {
      flush();
      continue;
    }
    if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(line)) {
      flush();
      blocks.add(const XcBlock(XcBlockType.rule, []));
      continue;
    }
    final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
    if (heading != null) {
      flush();
      blocks.add(
        XcBlock(
          XcBlockType.heading,
          parseXcInlines(heading[2]!.replaceAll(RegExp(r'\s#+$'), '')),
          level: heading[1]!.length,
        ),
      );
      continue;
    }
    final bullet = RegExp(r'^([-*+]|\d+[.)])\s+(.*)$').firstMatch(line);
    if (bullet != null) {
      flush();
      final marker = bullet[1]!;
      blocks.add(
        XcBlock(
          XcBlockType.bullet,
          parseXcInlines(bullet[2]!),
          marker: RegExp(r'^\d').hasMatch(marker) ? marker : '•',
        ),
      );
      continue;
    }
    if (line.startsWith('>')) {
      flush();
      blocks.add(
        XcBlock(
          XcBlockType.quote,
          parseXcInlines(line.replaceFirst(RegExp(r'^>\s?'), '')),
        ),
      );
      continue;
    }
    paragraph.add(line);
  }
  flush();
  return blocks;
}

/// Renders panel content (markdown, HTML or a plan feature list) as text.
/// Links open in the system browser after a tap; nothing is fetched.
class XcRichContent extends StatefulWidget {
  final String? content;
  final TextStyle? style;

  const XcRichContent({super.key, required this.content, this.style});

  @override
  State<XcRichContent> createState() => _XcRichContentState();
}

class _XcRichContentState extends State<XcRichContent> {
  final _recognizers = <TapGestureRecognizer>[];

  void _clearRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clearRecognizers();
    super.dispose();
  }

  List<InlineSpan> _spans(List<XcInline> inlines, TextStyle base) {
    final colorScheme = Theme.of(context).colorScheme;
    return [
      for (final inline in inlines)
        if (inline.url case final url?)
          TextSpan(
            text: inline.text,
            style: base.copyWith(
              color: colorScheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: colorScheme.primary,
            ),
            recognizer:
                (TapGestureRecognizer()
                      ..onTap = () => xcOpenExternal(Uri.parse(url)))
                    .also(_recognizers.add),
          )
        else
          TextSpan(
            text: inline.text,
            style: inline.bold
                ? AppTextStyle.body.of(context, emphasized: true)
                : inline.code
                ? base.copyWith(
                    fontFamily: 'JetBrainsMono',
                    backgroundColor: colorScheme.surfaceContainerHighest,
                  )
                : base,
          ),
    ];
  }

  Widget _features(List<XcFeature> features, TextStyle base) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        for (final item in features)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              GlyphIcon(
                item.support ? AppGlyphs.check : AppGlyphs.close,
                size: 20,
                color: item.support ? colorScheme.primary : colorScheme.outline,
              ),
              Expanded(
                child: Text(
                  item.feature,
                  style: item.support
                      ? base
                      : base.copyWith(
                          color: colorScheme.outline,
                          decoration: TextDecoration.lineThrough,
                        ),
                ),
              ),
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    _clearRecognizers();
    final theme = Theme.of(context);
    final base = widget.style ?? AppTextStyle.body.of(context);
    final features = parseXcFeatures(widget.content);
    if (features != null) return _features(features, base);
    final blocks = parseXcBlocks(widget.content);
    if (blocks.isEmpty) return const SizedBox.shrink();
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        for (final block in blocks)
          switch (block.type) {
            XcBlockType.heading => Text.rich(
              TextSpan(
                children: _spans(
                  block.inlines,
                  (block.level <= 2
                          ? AppTextStyle.title2
                          : AppTextStyle.headline)
                      .of(context),
                ),
              ),
            ),
            XcBlockType.paragraph => Text.rich(
              TextSpan(children: _spans(block.inlines, base)),
            ),
            XcBlockType.bullet => Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Text(block.marker ?? '•', style: base),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: _spans(block.inlines, base)),
                  ),
                ),
              ],
            ),
            XcBlockType.quote => DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: colorScheme.outlineVariant, width: 3),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text.rich(
                  TextSpan(
                    children: _spans(
                      block.inlines,
                      base.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
              ),
            ),
            XcBlockType.code => DecoratedBox(
              decoration: ShapeDecoration(
                color: colorScheme.surfaceContainerHighest,
                shape: AppShape.sm,
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: SelectableText(
                  block.plainText,
                  style: base.copyWith(fontFamily: 'JetBrainsMono'),
                ),
              ),
            ),
            XcBlockType.rule => const Divider(height: 8),
          },
      ],
    );
  }
}

extension _Also<T> on T {
  T also(void Function(T value) action) {
    action(this);
    return this;
  }
}
