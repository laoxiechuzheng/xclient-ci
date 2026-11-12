import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';

/// Paints [gradient] through [fill] one stop interval per pass, because the
/// Android emulator's software GPU shades 2×2 pixel quads that straddle an
/// interior stop with the wrong interval. Later passes fade in with
/// [BlendMode.srcATop] inside a layer, so pixels and edges match one fill.
void paintXcGradient(
  Canvas canvas,
  Gradient gradient,
  Rect rect,
  void Function(Paint paint) fill, {
  double opacity = 1,
  double bleed = 0,
  TextDirection? textDirection,
}) {
  Paint paintOf(Gradient gradient) =>
      Paint()
        ..shader = gradient.createShader(rect, textDirection: textDirection);
  final passes = _intervals(gradient);
  if (passes.length == 1 && opacity >= 1) {
    fill(paintOf(gradient));
    return;
  }
  final area = rect.inflate(bleed + 1);
  canvas.saveLayer(
    area,
    Paint()..color = Colors.black.withValues(alpha: opacity),
  );
  fill(paintOf(passes.first));
  for (final pass in passes.skip(1)) {
    canvas.drawRect(area, paintOf(pass)..blendMode = BlendMode.srcATop);
  }
  canvas.restore();
}

List<Gradient> _intervals(Gradient gradient) {
  final colors = gradient.colors;
  if (colors.length < 3) return [gradient];
  assert(colors.every((color) => color.a == 1));
  final stops =
      gradient.stops ??
      [for (var i = 0; i < colors.length; i++) i / (colors.length - 1)];
  return [
    for (var i = 0; i + 1 < colors.length; i++)
      _between(
        gradient,
        stops[i],
        stops[i + 1],
        i == 0
            ? [colors[0], colors[1]]
            : [colors[i + 1].withValues(alpha: 0), colors[i + 1]],
      ),
  ];
}

Gradient _between(
  Gradient gradient,
  double from,
  double to,
  List<Color> colors,
) => switch (gradient) {
  LinearGradient(
    :final begin,
    :final end,
    :final transform,
    tileMode: TileMode.clamp,
  ) =>
    LinearGradient(
      begin: AlignmentGeometry.lerp(begin, end, from)!,
      end: AlignmentGeometry.lerp(begin, end, to)!,
      colors: colors,
      transform: transform,
    ),
  SweepGradient(
    :final center,
    :final startAngle,
    :final endAngle,
    :final transform,
    tileMode: TileMode.clamp,
  ) =>
    SweepGradient(
      center: center,
      startAngle: lerpDouble(startAngle, endAngle, from)!,
      endAngle: lerpDouble(startAngle, endAngle, to)!,
      colors: colors,
      transform: transform,
    ),
  _ => throw UnsupportedError('Interior stops on $gradient'),
};

/// [ShapeDecoration] whose gradient is painted with [paintXcGradient].
class XcGradientDecoration extends ShapeDecoration {
  const XcGradientDecoration({
    required Gradient super.gradient,
    required super.shape,
    super.shadows,
  });

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _XcGradientPainter(this, onChanged);
}

class _XcGradientPainter extends BoxPainter {
  _XcGradientPainter(this.decoration, super.onChanged);

  final XcGradientDecoration decoration;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = offset & configuration.size!;
    final direction = configuration.textDirection;
    final shape = decoration.shape;
    void fill(Rect area, Paint paint) => shape.preferPaintInterior
        ? shape.paintInterior(canvas, area, paint, textDirection: direction)
        : canvas.drawPath(
            shape.getOuterPath(area, textDirection: direction),
            paint,
          );
    for (final shadow in decoration.shadows ?? const <BoxShadow>[]) {
      fill(
        rect.shift(shadow.offset).inflate(shadow.spreadRadius),
        shadow.toPaint(),
      );
    }
    paintXcGradient(
      canvas,
      decoration.gradient!,
      rect,
      (paint) => fill(rect, paint),
      textDirection: direction,
    );
    shape.paint(canvas, rect, textDirection: direction);
  }
}
