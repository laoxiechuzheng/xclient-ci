import 'dart:math' as math;

import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/navigation_dock.dart' show ElasticPress;
import 'package:fl_clash/ui/shape.dart';
import 'package:material_ui/material_ui.dart';

import '../common/tokens.dart';

enum XcLinkState {
  off,
  connecting,
  on,
  disconnecting,
  blocked;

  bool get busy => this == connecting || this == disconnecting;
}

/// The home screen's connect control. Only the transitions animate: the orbit
/// runs while a change is pending, the ring closes and one ripple spreads when
/// the connection comes up, and every steady state is still.
class XcConnectionOrb extends StatefulWidget {
  const XcConnectionOrb({
    super.key,
    required this.state,
    required this.onPressed,
    required this.semanticLabel,
    this.size = 184,
  });

  final XcLinkState state;
  final VoidCallback? onPressed;
  final String semanticLabel;
  final double size;

  @override
  State<XcConnectionOrb> createState() => _XcConnectionOrbState();
}

class _XcConnectionOrbState extends State<XcConnectionOrb>
    with TickerProviderStateMixin {
  late final AnimationController _active = AnimationController(
    vsync: this,
    duration: XcMotion.emphasized,
    value: _activeTarget,
  );
  late final AnimationController _orbit = AnimationController(
    vsync: this,
    duration: XcMotion.orbit,
  );
  late final AnimationController _burst = AnimationController(
    vsync: this,
    duration: XcMotion.celebrate,
    value: 1,
  );
  late final Listenable _motion = Listenable.merge([_active, _orbit, _burst]);

  double get _activeTarget => widget.state == XcLinkState.on ? 1 : 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncOrbit();
  }

  @override
  void didUpdateWidget(XcConnectionOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state == widget.state) return;
    final reduced = XcMotion.reduced(context);
    if (reduced) {
      _active.value = _activeTarget;
    } else {
      _active.animateTo(
        _activeTarget,
        duration: widget.state == XcLinkState.on
            ? XcMotion.tween
            : XcMotion.standard,
        curve: XcMotion.emphasizedCurve,
      );
    }
    if (widget.state == XcLinkState.on &&
        oldWidget.state != XcLinkState.on &&
        !reduced) {
      _burst.forward(from: 0);
    }
    _syncOrbit();
  }

  void _syncOrbit() {
    if (widget.state.busy && !XcMotion.reduced(context)) {
      if (!_orbit.isAnimating) _orbit.repeat();
    } else if (_orbit.isAnimating || _orbit.value != 0) {
      _orbit
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _active.dispose();
    _orbit.dispose();
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    final enabled = widget.onPressed != null && !widget.state.busy;
    final blocked = widget.state == XcLinkState.blocked;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      excludeSemantics: true,
      onTap: enabled ? widget.onPressed : null,
      child: ElasticPress(
        enabled: enabled && !XcMotion.reduced(context),
        maxGrowth: 8,
        child: SizedBox.square(
          dimension: widget.size,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: AppShape.circle,
              splashFactory: NoSplash.splashFactory,
              highlightColor: Colors.transparent,
              hoverColor: Colors.transparent,
              mouseCursor: enabled
                  ? SystemMouseCursors.click
                  : SystemMouseCursors.basic,
              onTap: enabled ? widget.onPressed : null,
              child: AnimatedBuilder(
                animation: _motion,
                builder: (context, child) => CustomPaint(
                  painter: _OrbPainter(
                    colors: colors,
                    active: _active.value,
                    orbit: widget.state.busy ? _orbit.value : null,
                    burst: _burst.value,
                    blocked: blocked,
                    glyph: !blocked,
                  ),
                  child: child,
                ),
                child: blocked
                    ? Center(
                        child: GlyphIcon(
                          AppGlyphs.lock,
                          size: widget.size * 0.2,
                          color: colors.warning,
                        ),
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  const _OrbPainter({
    required this.colors,
    required this.active,
    required this.orbit,
    required this.burst,
    required this.blocked,
    required this.glyph,
  });

  final XcColors colors;
  final double active;
  final double? orbit;
  final double burst;
  final bool blocked;
  final bool glyph;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final disc = radius * 0.6;
    final ring = radius * 0.8;
    final stroke = math.max(4.0, radius * 0.055);
    final accent = colors.accent;

    if (active > 0) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              accent.withValues(alpha: (colors.dark ? 0.34 : 0.22) * active),
              accent.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }

    if (burst < 1) {
      for (final delay in const [0.0, 0.22]) {
        final t = ((burst - delay) / (1 - delay)).clamp(0.0, 1.0);
        if (t <= 0 || t >= 1) continue;
        final eased = Curves.easeOutCubic.transform(t);
        canvas.drawCircle(
          center,
          disc + (radius - disc) * eased,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2 * (1 - t) + 0.5
            ..color = accent.withValues(alpha: 0.5 * (1 - t)),
        );
      }
    }

    final ringRect = Rect.fromCircle(center: center, radius: ring);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = blocked
          ? colors.warning.withValues(alpha: 0.22)
          : Color.lerp(colors.inset, accent.withValues(alpha: 0.18), active)!;
    canvas.drawCircle(center, ring, track);

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    if (orbit case final turn?) {
      final start = turn * math.pi * 2 - math.pi / 2;
      const sweep = math.pi * 0.62;
      arc.shader = SweepGradient(
        startAngle: 0,
        endAngle: sweep,
        colors: [accent.withValues(alpha: 0), accent],
        transform: GradientRotation(start),
      ).createShader(ringRect);
      canvas.drawArc(ringRect, start, sweep, false, arc);
    } else if (active > 0) {
      arc.shader = SweepGradient(
        colors: [
          colors.accentLight,
          accent,
          colors.accentDeep,
          colors.accentLight,
        ],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(ringRect);
      canvas.drawArc(ringRect, -math.pi / 2, math.pi * 2 * active, false, arc);
    }

    final discRect = Rect.fromCircle(center: center, radius: disc);
    canvas.drawCircle(
      center.translate(0, disc * 0.08),
      disc,
      Paint()
        ..color = Colors.black.withValues(alpha: colors.dark ? 0.45 : 0.1)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, disc * 0.16),
    );
    canvas.drawCircle(
      center,
      disc,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors.dark
              ? [colors.inset, colors.block]
              : [Colors.white, colors.card],
        ).createShader(discRect),
    );
    if (active > 0) {
      final gradient = colors.accentGradient;
      canvas.drawCircle(
        center,
        disc,
        Paint()
          ..shader = LinearGradient(
            begin: gradient.begin,
            end: gradient.end,
            stops: gradient.stops,
            colors: [
              for (final color in gradient.colors)
                color.withValues(alpha: active),
            ],
          ).createShader(discRect),
      );
      canvas.drawCircle(
        center,
        disc,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.35, -0.55),
            radius: 0.9,
            colors: [
              Colors.white.withValues(alpha: 0.32 * active),
              Colors.white.withValues(alpha: 0),
            ],
          ).createShader(discRect),
      );
    }
    canvas.drawCircle(
      center,
      disc - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white.withValues(
          alpha: colors.dark ? 0.06 + 0.1 * active : 0.6 * (1 - active),
        ),
    );

    if (!glyph) return;
    final idle = orbit != null ? accent : colors.muted;
    final glyphColor = Color.lerp(idle, colors.onAccent, active)!;
    final glyphRadius = disc * 0.34;
    final glyphPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2.5, disc * 0.075)
      ..strokeCap = StrokeCap.round
      ..color = glyphColor;
    final glyphCenter = center.translate(0, disc * 0.04);
    canvas.drawArc(
      Rect.fromCircle(center: glyphCenter, radius: glyphRadius),
      -math.pi / 2 + 0.72,
      math.pi * 2 - 1.44,
      false,
      glyphPaint,
    );
    canvas.drawLine(
      glyphCenter.translate(0, -glyphRadius * 1.22),
      glyphCenter.translate(0, -glyphRadius * 0.28),
      glyphPaint,
    );
  }

  @override
  bool shouldRepaint(_OrbPainter oldDelegate) =>
      active != oldDelegate.active ||
      orbit != oldDelegate.orbit ||
      burst != oldDelegate.burst ||
      blocked != oldDelegate.blocked ||
      glyph != oldDelegate.glyph ||
      !identical(colors, oldDelegate.colors);
}
