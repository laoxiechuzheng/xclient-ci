import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/xboard/ui/common/gradient.dart';
import 'package:fl_clash/xboard/ui/common/tokens.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _light = Color(0xFF3BA2FF);
const _accent = Color(0xFF007AFF);
const _deep = Color(0xFF3F4FE0);

const _linear = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [_light, _accent, _deep],
  stops: [0, 0.55, 1],
);

const _sweep = SweepGradient(
  colors: [_light, _accent, _deep, _light],
  transform: GradientRotation(-math.pi / 2),
);

class _CountingCanvas implements Canvas {
  int layers = 0;

  @override
  void saveLayer(Rect? bounds, Paint paint) => layers++;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Painter extends CustomPainter {
  const _Painter(this.draw);

  final void Function(Canvas canvas, Rect rect) draw;

  @override
  void paint(Canvas canvas, Size size) => draw(canvas, Offset.zero & size);

  @override
  bool shouldRepaint(_Painter oldDelegate) => true;
}

Future<Uint8List> _render(WidgetTester tester, Size size, Widget child) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    Center(
      child: RepaintBoundary(
        key: key,
        child: ColoredBox(
          color: const Color(0xFFF4F4F9),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SizedBox.fromSize(size: size, child: child),
          ),
        ),
      ),
    ),
  );
  return (await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.625);
    final data = await image.toByteData();
    image.dispose();
    return data!.buffer.asUint8List();
  }))!;
}

void _expectSame(Uint8List single, Uint8List split, String reason) {
  expect(split.length, single.length, reason: reason);
  var worst = 0;
  var total = 0;
  var off = 0;
  for (var i = 0; i < single.length; i++) {
    final difference = (single[i] - split[i]).abs();
    worst = math.max(worst, difference);
    total += difference;
    if (difference > 2) off++;
  }
  expect(worst, lessThanOrEqualTo(8), reason: '$reason: worst channel');
  expect(off, lessThan(single.length / 10000), reason: '$reason: off by > 2');
  expect(total / single.length, lessThan(0.25), reason: '$reason: mean');
}

void main() {
  testWidgets('a decoration paints the same pixels as one gradient fill', (
    tester,
  ) async {
    debugDisableShadows = false;
    try {
      final shadows = XcShadow.glow(_accent, strength: 0.7);
      for (final (name, shape) in [
        ('full', AppShape.full),
        ('tile', AppShape.all(14)),
        ('circle', AppShape.circle),
        ('rect', AppShape.none),
      ]) {
        const size = Size(323, 54);
        final single = await _render(
          tester,
          size,
          DecoratedBox(
            decoration: ShapeDecoration(
              gradient: _linear,
              shape: shape,
              shadows: shadows,
            ),
          ),
        );
        final split = await _render(
          tester,
          size,
          DecoratedBox(
            decoration: XcGradientDecoration(
              gradient: _linear,
              shape: shape,
              shadows: shadows,
            ),
          ),
        );
        _expectSame(single, split, name);
      }
    } finally {
      debugDisableShadows = true;
    }
  });

  testWidgets('faded fills and sweep strokes match one gradient', (
    tester,
  ) async {
    const size = Size(120, 120);
    const opacity = 0.6;
    final single = await _render(
      tester,
      size,
      CustomPaint(
        painter: _Painter(
          (canvas, rect) => canvas.drawOval(
            rect,
            Paint()
              ..shader = LinearGradient(
                begin: _linear.begin,
                end: _linear.end,
                stops: _linear.stops,
                colors: [
                  for (final color in _linear.colors)
                    color.withValues(alpha: opacity),
                ],
              ).createShader(rect),
          ),
        ),
      ),
    );
    final split = await _render(
      tester,
      size,
      CustomPaint(
        painter: _Painter(
          (canvas, rect) => paintXcGradient(
            canvas,
            _linear,
            rect,
            (paint) => canvas.drawOval(rect, paint),
            opacity: opacity,
          ),
        ),
      ),
    );
    _expectSame(single, split, 'faded disc');

    Paint stroke(Paint paint) => paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round;
    void arc(Canvas canvas, Rect rect, Paint paint) => canvas.drawArc(
      rect.deflate(8),
      -math.pi / 2,
      math.pi * 1.7,
      false,
      stroke(paint),
    );
    final ring = await _render(
      tester,
      size,
      CustomPaint(
        painter: _Painter(
          (canvas, rect) => arc(
            canvas,
            rect,
            Paint()..shader = _sweep.createShader(rect.deflate(8)),
          ),
        ),
      ),
    );
    final splitRing = await _render(
      tester,
      size,
      CustomPaint(
        painter: _Painter(
          (canvas, rect) => paintXcGradient(
            canvas,
            _sweep,
            rect.deflate(8),
            (paint) => arc(canvas, rect, paint),
            bleed: 9,
          ),
        ),
      ),
    );
    _expectSame(ring, splitRing, 'sweep ring');
  });

  test('gradients with one interval are left alone', () {
    final canvas = _CountingCanvas();
    var fills = 0;
    paintXcGradient(
      canvas,
      const LinearGradient(colors: [_light, _deep]),
      const Rect.fromLTWH(0, 0, 10, 10),
      (_) => fills++,
    );
    expect((fills, canvas.layers), (1, 0));
  });
}
