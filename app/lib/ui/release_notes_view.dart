import 'dart:ui' as ui;
import 'package:flutter/material.dart';

sealed class _NotesBlock {
  const _NotesBlock();
}

class _NotesHeadingBlock extends _NotesBlock {
  const _NotesHeadingBlock(this.level, this.text);

  final int level;
  final String text;
}

class _NotesBulletBlock extends _NotesBlock {
  const _NotesBulletBlock({
    required this.text,
    this.indent = 0,
    this.marker,
  });

  final String text;
  final int indent;
  final String? marker;
}

class _NotesParagraphBlock extends _NotesBlock {
  const _NotesParagraphBlock(this.text);

  final String text;
}

class _NotesQuoteBlock extends _NotesBlock {
  const _NotesQuoteBlock(this.text);

  final String text;
}

class _NotesCodeBlock extends _NotesBlock {
  const _NotesCodeBlock(this.code);

  final String code;
}

class _NotesRuleBlock extends _NotesBlock {
  const _NotesRuleBlock();
}

/// Renders Markdown release notes cleanly inside an alert well while caching
/// parsed blocks across rebuilds so layout/theme ticks never re-parse Markdown.
class ReleaseNotesView extends StatefulWidget {
  const ReleaseNotesView({
    required this.body,
    required this.hasNotes,
    required this.ink,
    required this.muted,
    required this.dark,
    super.key,
  });

  final String body;
  final bool hasNotes;
  final Color ink;
  final Color muted;
  final bool dark;

  @override
  State<ReleaseNotesView> createState() => _ReleaseNotesViewState();
}

class _ReleaseNotesViewState extends State<ReleaseNotesView> {
  static final _headingRe = RegExp(r'^\s*(#{1,6})\s+(.+?)\s*#*\s*$');
  static final _unorderedRe = RegExp(r'^(\s*)[-*+•]\s+(.+)$');
  static final _orderedRe = RegExp(r'^(\s*)(\d+)[.)]\s+(.+)$');
  static final _quoteRe = RegExp(r'^\s*>\s?(.*)$');
  static final _ruleRe = RegExp(r'^\s*([-*_])(?:\s*\1){2,}\s*$');
  static final _fenceRe = RegExp(r'^\s*(`{3,}|~{3,})');

  List<_NotesBlock> _blocks = const [];

  @override
  void initState() {
    super.initState();
    _blocks = widget.hasNotes ? _parseBlocks(widget.body) : const [];
  }

  @override
  void didUpdateWidget(covariant ReleaseNotesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.body != widget.body ||
        oldWidget.hasNotes != widget.hasNotes) {
      _blocks = widget.hasNotes ? _parseBlocks(widget.body) : const [];
    }
  }

  static List<_NotesBlock> _parseBlocks(String raw) {
    final lines = raw
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final blocks = <_NotesBlock>[];
    final paragraph = <String>[];
    final quote = <String>[];

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      blocks.add(_NotesParagraphBlock(paragraph.join('\n')));
      paragraph.clear();
    }

    void flushQuote() {
      if (quote.isEmpty) return;
      blocks.add(_NotesQuoteBlock(quote.join('\n')));
      quote.clear();
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      final fence = _fenceRe.firstMatch(line);
      if (fence != null) {
        flushParagraph();
        flushQuote();
        final marker = fence.group(1)!;
        final fenceChar = marker[0];
        final fenceLen = marker.length;
        final codeLines = <String>[];
        while (++i < lines.length) {
          final close = _fenceRe.firstMatch(lines[i]);
          if (close != null) {
            final closeMarker = close.group(1)!;
            if (closeMarker[0] == fenceChar && closeMarker.length >= fenceLen) {
              break;
            }
          }
          codeLines.add(lines[i]);
        }
        blocks.add(_NotesCodeBlock(codeLines.join('\n')));
        continue;
      }

      if (line.trim().isEmpty) {
        flushParagraph();
        flushQuote();
        continue;
      }

      if (_ruleRe.hasMatch(line)) {
        flushParagraph();
        flushQuote();
        blocks.add(const _NotesRuleBlock());
        continue;
      }

      final heading = _headingRe.firstMatch(line);
      if (heading != null) {
        flushParagraph();
        flushQuote();
        blocks.add(
          _NotesHeadingBlock(heading.group(1)!.length, heading.group(2)!.trim()),
        );
        continue;
      }

      final unordered = _unorderedRe.firstMatch(line);
      if (unordered != null) {
        flushParagraph();
        flushQuote();
        final indent = (unordered.group(1)!.length ~/ 2).clamp(0, 2);
        blocks.add(
          _NotesBulletBlock(text: unordered.group(2)!.trim(), indent: indent),
        );
        continue;
      }

      final ordered = _orderedRe.firstMatch(line);
      if (ordered != null) {
        flushParagraph();
        flushQuote();
        final indent = (ordered.group(1)!.length ~/ 2).clamp(0, 2);
        blocks.add(
          _NotesBulletBlock(
            text: ordered.group(3)!.trim(),
            indent: indent,
            marker: '${ordered.group(2)!}.',
          ),
        );
        continue;
      }

      final quoteMatch = _quoteRe.firstMatch(line);
      if (quoteMatch != null) {
        flushParagraph();
        quote.add(quoteMatch.group(1)!);
        continue;
      }

      flushQuote();
      paragraph.add(line);
    }

    flushParagraph();
    flushQuote();
    return blocks;
  }

  static bool _isEscapable(String ch) => r'\`*_{}[]()#+-.!~<>'.contains(ch);

  static TextSpan _parseInline(
    String text, {
    required TextStyle baseStyle,
    required TextStyle boldStyle,
    required TextStyle codeStyle,
    required TextStyle strikeStyle,
  }) {
    final spans = <InlineSpan>[];
    final buffer = StringBuffer();

    void flushText() {
      if (buffer.isEmpty) return;
      spans.add(TextSpan(text: buffer.toString()));
      buffer.clear();
    }

    var i = 0;
    while (i < text.length) {
      final ch = text[i];

      if (ch == r'\' && i + 1 < text.length && _isEscapable(text[i + 1])) {
        buffer.write(text[i + 1]);
        i += 2;
        continue;
      }

      if (ch == '`') {
        final end = text.indexOf('`', i + 1);
        if (end > i + 1) {
          flushText();
          spans.add(
            TextSpan(text: text.substring(i + 1, end), style: codeStyle),
          );
          i = end + 1;
          continue;
        }
      }

      if ((ch == '*' || ch == '_') &&
          i + 1 < text.length &&
          text[i + 1] == ch) {
        final delim = '$ch$ch';
        final end = text.indexOf(delim, i + 2);
        if (end > i + 2) {
          flushText();
          spans.add(
            _parseInline(
              text.substring(i + 2, end),
              baseStyle: boldStyle,
              boldStyle: boldStyle,
              codeStyle: codeStyle.copyWith(fontWeight: FontWeight.w600),
              strikeStyle: strikeStyle,
            ),
          );
          i = end + 2;
          continue;
        }
      }

      if (ch == '~' && i + 1 < text.length && text[i + 1] == '~') {
        final end = text.indexOf('~~', i + 2);
        if (end > i + 2) {
          flushText();
          spans.add(
            TextSpan(text: text.substring(i + 2, end), style: strikeStyle),
          );
          i = end + 2;
          continue;
        }
      }

      if (ch == '*' && i + 1 < text.length && text[i + 1] != ' ') {
        final end = text.indexOf('*', i + 1);
        if (end > i + 1 && text[end - 1] != ' ') {
          flushText();
          spans.add(
            TextSpan(
              text: text.substring(i + 1, end),
              style: baseStyle.copyWith(fontStyle: FontStyle.italic),
            ),
          );
          i = end + 1;
          continue;
        }
      }

      if (ch == '[') {
        final closeBracket = text.indexOf(']', i + 1);
        if (closeBracket > i + 1 &&
            closeBracket + 1 < text.length &&
            text[closeBracket + 1] == '(') {
          final closeParen = text.indexOf(')', closeBracket + 2);
          if (closeParen > closeBracket + 2) {
            flushText();
            spans.add(
              _parseInline(
                text.substring(i + 1, closeBracket),
                baseStyle: baseStyle,
                boldStyle: boldStyle,
                codeStyle: codeStyle,
                strikeStyle: strikeStyle,
              ),
            );
            i = closeParen + 1;
            continue;
          }
        }
      }

      buffer.write(ch);
      i++;
    }

    flushText();
    if (spans.isEmpty) return TextSpan(text: '', style: baseStyle);
    if (spans.length == 1 && spans.single is TextSpan) {
      final only = spans.single as TextSpan;
      if (only.style == null && only.children == null) {
        return TextSpan(text: only.text, style: baseStyle);
      }
    }
    return TextSpan(style: baseStyle, children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final bodyColor = widget.hasNotes
        ? widget.ink.withValues(alpha: widget.dark ? .88 : .86)
        : widget.muted;
    final bodyStyle = TextStyle(
      fontSize: 13.5,
      fontWeight: FontWeight.w400,
      height: 1.55,
      color: bodyColor,
    );
    if (!widget.hasNotes || _blocks.isEmpty) {
      return Text(widget.body, textAlign: TextAlign.start, style: bodyStyle);
    }

    final codeStyle = bodyStyle.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      color: widget.ink.withValues(alpha: widget.dark ? .96 : .94),
      fontFeatures: const [ui.FontFeature.tabularFigures()],
    );
    final strikeStyle = bodyStyle.copyWith(
      decoration: TextDecoration.lineThrough,
      color: widget.muted,
    );
    final bulletColor = widget.ink.withValues(alpha: widget.dark ? .52 : .44);

    TextSpan spanFor(String text, {TextStyle? style}) => _parseInline(
      text,
      baseStyle: style ?? bodyStyle,
      boldStyle: (style ?? bodyStyle).copyWith(
        fontWeight: FontWeight.w600,
        color: widget.ink,
      ),
      codeStyle: codeStyle,
      strikeStyle: strikeStyle,
    );

    final children = <Widget>[];
    for (var i = 0; i < _blocks.length; i++) {
      final block = _blocks[i];
      final previous = i > 0 ? _blocks[i - 1] : null;
      if (previous != null) {
        final double gap;
        if (block is _NotesHeadingBlock) {
          gap = 14;
        } else if (previous is _NotesHeadingBlock) {
          gap = 6;
        } else if (block is _NotesBulletBlock &&
            previous is _NotesBulletBlock) {
          gap = 5;
        } else {
          gap = 8;
        }
        children.add(SizedBox(height: gap));
      }

      switch (block) {
        case _NotesHeadingBlock(:final level, :final text):
          final headingStyle = TextStyle(
            fontSize: level <= 2 ? 14.5 : 14,
            fontWeight: FontWeight.w600,
            height: 1.35,
            letterSpacing: -0.15,
            color: widget.ink.withValues(alpha: widget.dark ? .96 : .94),
          );
          children.add(
            Text.rich(
              spanFor(text, style: headingStyle),
              textAlign: TextAlign.start,
            ),
          );
        case _NotesBulletBlock(:final text, :final indent, :final marker):
          final markerText = marker ?? (indent == 0 ? '•' : '◦');
          final markerStyle = bodyStyle.copyWith(
            color: bulletColor,
            fontWeight: marker == null ? FontWeight.w700 : FontWeight.w500,
            fontFeatures: marker == null
                ? null
                : const [ui.FontFeature.tabularFigures()],
          );
          children.add(
            Padding(
              padding: EdgeInsets.only(left: indent * 14.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(right: marker == null ? 7 : 6),
                    child: Text(markerText, style: markerStyle),
                  ),
                  Expanded(
                    child: Text.rich(
                      spanFor(text),
                      textAlign: TextAlign.start,
                    ),
                  ),
                ],
              ),
            ),
          );
        case _NotesParagraphBlock(:final text):
          children.add(
            Text.rich(spanFor(text), textAlign: TextAlign.start),
          );
        case _NotesQuoteBlock(:final text):
          children.add(
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: widget.ink.withValues(alpha: widget.dark ? .24 : .18),
                    width: 2,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Text.rich(
                  spanFor(text, style: bodyStyle.copyWith(color: widget.muted)),
                  textAlign: TextAlign.start,
                ),
              ),
            ),
          );
        case _NotesCodeBlock(:final code):
          children.add(
            DecoratedBox(
              decoration: ShapeDecoration(
                color: widget.dark
                    ? const Color(0x16FFFFFF)
                    : const Color(0x0D000000),
                shape: const RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.all(Radius.circular(10)),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Text(
                  code,
                  style: bodyStyle.copyWith(
                    fontSize: 12.5,
                    height: 1.45,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          );
        case _NotesRuleBlock():
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Divider(
                height: 0.5,
                thickness: 0.5,
                color: widget.ink.withValues(alpha: widget.dark ? .16 : .10),
              ),
            ),
          );
      }
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
