import 'dart:math' as math;

import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/loading.dart';
import 'package:fl_clash/ui/navigation_dock.dart' show ElasticPress;
import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/surface.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:material_ui/material_ui.dart';

import 'gradient.dart';
import 'motion.dart';
import 'tokens.dart';

enum XcButtonVariant { primary, secondary, ghost, danger }

enum XcButtonSize {
  large(54, 28),
  medium(46, 22),
  small(38, 16);

  const XcButtonSize(this.height, this.padding);

  final double height;
  final double padding;
}

/// The one button of the design system. [buttonKey] lands on the Material
/// button itself, which widget tests and accessibility tooling look up.
class XcButton extends StatelessWidget {
  const XcButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = XcButtonVariant.primary,
    this.size = XcButtonSize.medium,
    this.glyph,
    this.loading = false,
    this.loadingLabel,
    this.expand = false,
    this.buttonKey,
  });

  final String label;
  final VoidCallback? onPressed;
  final XcButtonVariant variant;
  final XcButtonSize size;
  final Glyph? glyph;
  final bool loading;
  final String? loadingLabel;
  final bool expand;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    final enabled = onPressed != null && !loading;
    final (background, foreground) = switch (variant) {
      XcButtonVariant.primary => (Colors.transparent, colors.onAccent),
      XcButtonVariant.secondary => (
        context.raisedSurfaceLevel.next.colorOf(Theme.of(context).colorScheme),
        colors.title,
      ),
      XcButtonVariant.ghost => (Colors.transparent, colors.accent),
      XcButtonVariant.danger => (colors.softOf(XcTone.danger), colors.danger),
    };
    final gradient = variant == XcButtonVariant.primary && enabled;
    final disabledBackground = variant == XcButtonVariant.ghost
        ? Colors.transparent
        : colors.title.withValues(alpha: 0.08);
    final textStyle =
        (size == XcButtonSize.small
                ? AppTextStyle.subheadline
                : AppTextStyle.callout)
            .of(context, emphasized: true);
    final height = gradient ? math.max(size.height, 44.0) : size.height;
    final style = ElasticPress.buttonStyle.merge(
      FilledButton.styleFrom(
        minimumSize: Size(expand ? double.infinity : 0, height),
        visualDensity: VisualDensity.standard,
        tapTargetSize: gradient ? MaterialTapTargetSize.shrinkWrap : null,
        padding: EdgeInsets.symmetric(
          horizontal: variant == XcButtonVariant.ghost
              ? size.padding / 2
              : size.padding,
        ),
        backgroundColor: gradient ? Colors.transparent : background,
        foregroundColor: foreground,
        disabledBackgroundColor: loading && variant == XcButtonVariant.primary
            ? colors.accent.withValues(alpha: 0.72)
            : disabledBackground,
        disabledForegroundColor: loading
            ? foreground
            : colors.title.withValues(alpha: 0.38),
        shadowColor: Colors.transparent,
        elevation: 0,
        textStyle: textStyle,
      ),
    );
    final glyphSize = size == XcButtonSize.small ? 16.0 : 20.0;
    final content = XcSwap(
      value: loading,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: XcSpace.xs,
        children: [
          if (loading)
            CommonCircleLoading(
              size: glyphSize,
              color: foreground,
              semanticLabel: loadingLabel ?? label,
            )
          else if (glyph case final glyph?)
            GlyphIcon(glyph, size: glyphSize, fill: 1),
          Flexible(
            child: Text(
              loading ? loadingLabel ?? label : label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    Widget button = FilledButton(
      key: buttonKey,
      onPressed: enabled ? onPressed : null,
      style: style,
      child: content,
    );
    if (gradient) {
      button = DecoratedBox(
        decoration: XcGradientDecoration(
          gradient: colors.accentGradient,
          shape: AppShape.full,
          shadows: XcShadow.glow(colors.accent, strength: 0.7),
        ),
        child: button,
      );
    }
    return ElasticPress(
      enabled: enabled && !XcMotion.reduced(context),
      maxGrowth: 6,
      child: button,
    );
  }
}

/// A raised surface one level above whatever it sits on.
class XcPanel extends StatelessWidget {
  const XcPanel({
    super.key,
    this.padding = const EdgeInsets.all(XcSpace.lg),
    this.shape = XcRadius.card,
    this.elevated = false,
    this.color,
    this.gradient,
    this.onTap,
    required this.child,
  });

  final EdgeInsetsGeometry padding;
  final RoundedSuperellipseBorder shape;
  final bool elevated;
  final Color? color;
  final Gradient? gradient;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final level = context.raisedSurfaceLevel;
    final colors = XcColors.of(context);
    Widget body = Padding(padding: padding, child: child);
    if (onTap != null) {
      body = Material(
        type: MaterialType.transparency,
        child: InkWell(customBorder: shape, onTap: onTap, child: body),
      );
    }
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: gradient == null
            ? color ?? level.colorOf(Theme.of(context).colorScheme)
            : null,
        gradient: gradient,
        shape: shape,
        shadows: elevated ? XcShadow.card(colors) : null,
      ),
      child: SurfaceScope(level: level, child: body),
    );
  }
}

/// A glyph on a tinted circle: the mark of a callout, a metric or a state.
class XcGlyphWell extends StatelessWidget {
  const XcGlyphWell({
    super.key,
    required this.glyph,
    this.tone = XcTone.accent,
    this.size = 40,
  });

  final Glyph glyph;
  final XcTone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colors.softOf(tone),
        shape: AppShape.circle,
      ),
      child: SizedBox.square(
        dimension: size,
        child: Center(
          child: GlyphIcon(
            glyph,
            size: size * 0.5,
            color: colors.vividOf(tone),
            fill: tone == XcTone.neutral ? 0 : 1,
          ),
        ),
      ),
    );
  }
}

/// A small status pill: a dot and a word.
class XcBadge extends StatelessWidget {
  const XcBadge({
    super.key,
    required this.label,
    this.tone = XcTone.neutral,
    this.glyph,
  });

  final String label;
  final XcTone tone;
  final Glyph? glyph;

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    final color = colors.toneOf(tone);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colors.softOf(tone),
        shape: AppShape.full,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            if (glyph case final glyph?)
              GlyphIcon(glyph, size: 14, color: color, fill: 1)
            else
              DecoratedBox(
                decoration: ShapeDecoration(
                  color: color,
                  shape: AppShape.circle,
                ),
                child: const SizedBox.square(dimension: 6),
              ),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyle.caption1
                    .of(context, emphasized: true)
                    .copyWith(
                      color: tone == XcTone.neutral ? colors.muted : color,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One figure with its label, as the home and account summaries show them.
class XcMetric extends StatelessWidget {
  const XcMetric({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.glyph,
    this.tone = XcTone.neutral,
    this.valueWidget,
  });

  final String label;
  final String value;
  final String? caption;
  final Glyph? glyph;
  final XcTone tone;
  final Widget? valueWidget;

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    return Semantics(
      container: true,
      label: '$label $value${caption == null ? '' : '，$caption'}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Row(
            spacing: 6,
            children: [
              if (glyph case final glyph?)
                GlyphIcon(glyph, size: 15, color: colors.muted),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: XcType.caption(context),
                ),
              ),
            ],
          ),
          valueWidget ??
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: XcType.value(context).copyWith(
                  color: tone == XcTone.neutral ? null : colors.toneOf(tone),
                ),
              ),
          if (caption case final caption?)
            Text(
              caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: XcType.caption(context),
            ),
        ],
      ),
    );
  }
}

/// A linear meter that eases to [value] between 0 and 1.
class XcMeter extends StatelessWidget {
  const XcMeter({
    super.key,
    required this.value,
    this.tone = XcTone.accent,
    this.height = 8,
  });

  final double value;
  final XcTone tone;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.clamp(0, 1)),
      duration: XcMotion.of(context, XcMotion.tween),
      curve: XcMotion.emphasizedCurve,
      builder: (context, shown, _) => SizedBox(
        height: height,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: colors.inset,
            shape: AppShape.full,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: shown <= 0
                ? const SizedBox.shrink()
                : FractionallySizedBox(
                    widthFactor: math.max(shown, 0.02),
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        gradient: tone == XcTone.accent
                            ? LinearGradient(
                                colors: [colors.accentLight, colors.accent],
                              )
                            : null,
                        color: tone == XcTone.accent
                            ? null
                            : colors.vividOf(tone),
                        shape: AppShape.full,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

/// A ring that sweeps to [value] between 0 and 1 around [child].
class XcRing extends StatelessWidget {
  const XcRing({
    super.key,
    required this.value,
    this.size = 132,
    this.stroke = 12,
    this.tone = XcTone.accent,
    this.child,
  });

  final double value;
  final double size;
  final double stroke;
  final XcTone tone;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    final (start, end) = tone == XcTone.accent
        ? (colors.accentLight, colors.accentDeep)
        : (colors.vividOf(tone), colors.vividOf(tone));
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: value.clamp(0, 1)),
      duration: XcMotion.of(context, XcMotion.tween),
      curve: XcMotion.emphasizedCurve,
      builder: (context, shown, child) => CustomPaint(
        painter: _RingPainter(
          value: shown,
          stroke: stroke,
          track: colors.inset,
          start: start,
          end: end,
        ),
        child: child,
      ),
      child: SizedBox.square(
        dimension: size,
        child: Center(child: child),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.value,
    required this.stroke,
    required this.track,
    required this.start,
    required this.end,
  });

  final double value;
  final double stroke;
  final Color track;
  final Color start;
  final Color end;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: (size.shortestSide - stroke) / 2,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint);
    if (value <= 0) return;
    final sweep = math.pi * 2 * value;
    paint.shader = SweepGradient(
      startAngle: 0,
      endAngle: math.max(sweep, 0.01),
      colors: [start, end],
      transform: const GradientRotation(-math.pi / 2),
    ).createShader(rect);
    canvas.drawArc(rect, -math.pi / 2, sweep, false, paint);
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      value != oldDelegate.value ||
      stroke != oldDelegate.stroke ||
      track != oldDelegate.track ||
      start != oldDelegate.start ||
      end != oldDelegate.end;
}

/// A message that tells what happened and what to do next.
class XcCallout extends StatelessWidget {
  const XcCallout({
    super.key,
    required this.title,
    this.message,
    this.glyph = AppGlyphs.info,
    this.tone = XcTone.accent,
    this.actions = const [],
    this.onDismiss,
    this.dismissTooltip = '关闭',
    this.onTap,
    this.filled = false,
    this.children = const [],
  });

  final String title;
  final String? message;
  final Glyph glyph;
  final XcTone tone;
  final List<Widget> actions;
  final VoidCallback? onDismiss;
  final String dismissTooltip;
  final VoidCallback? onTap;

  /// Washes the whole callout in its tone, kept for blocking problems.
  final bool filled;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    return XcPanel(
      color: filled ? colors.washOf(tone) : null,
      padding: const EdgeInsets.fromLTRB(
        XcSpace.md,
        XcSpace.md,
        XcSpace.xs,
        XcSpace.md,
      ),
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          XcGlyphWell(glyph: glyph, tone: tone, size: 36),
          const SizedBox(width: XcSpace.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2, right: XcSpace.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Text(title, style: XcType.headline(context)),
                  if (message case final message?)
                    Text(message, style: XcType.secondary(context)),
                  ...children,
                  if (actions.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: XcSpace.xs),
                      child: Wrap(
                        spacing: XcSpace.xs,
                        runSpacing: XcSpace.xs,
                        children: actions,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (onDismiss != null)
            IconButton(
              tooltip: dismissTooltip,
              visualDensity: VisualDensity.standard,
              onPressed: onDismiss,
              icon: GlyphIcon(AppGlyphs.close, size: 18, color: colors.muted),
            )
          else if (onTap != null)
            Padding(
              padding: const EdgeInsets.only(top: 8, right: 8),
              child: GlyphIcon(
                AppGlyphs.chevronForward,
                size: 18,
                color: colors.muted,
              ),
            ),
        ],
      ),
    );
  }
}

/// A full-area state: empty, failed, or blocked, always with a way forward.
class XcStateView extends StatelessWidget {
  const XcStateView({
    super.key,
    required this.title,
    this.message,
    this.glyph = AppGlyphs.info,
    this.tone = XcTone.neutral,
    this.action,
    this.secondary,
    this.children = const [],
  });

  final String title;
  final String? message;
  final Glyph glyph;
  final XcTone tone;
  final Widget? action;
  final Widget? secondary;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: XcSpace.formWidth),
      child: Padding(
        padding: const EdgeInsets.all(XcSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            XcGlyphWell(glyph: glyph, tone: tone, size: 72),
            const SizedBox(height: XcSpace.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: XcType.title(context),
            ),
            if (message case final message?) ...[
              const SizedBox(height: XcSpace.xs),
              Text(
                message,
                textAlign: TextAlign.center,
                style: XcType.secondary(context),
              ),
            ],
            ...children,
            if (action != null) ...[
              const SizedBox(height: XcSpace.xl),
              action!,
            ],
            if (secondary != null) ...[
              const SizedBox(height: XcSpace.xs),
              secondary!,
            ],
          ],
        ),
      ),
    ),
  );
}

class XcSectionHeader extends StatelessWidget {
  const XcSectionHeader({super.key, required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, XcSpace.xs, 0, XcSpace.xs),
    child: Row(
      children: [
        Expanded(child: Text(title, style: XcType.headline(context))),
        ?action,
      ],
    ),
  );
}

/// The foot of a page whose main action must stay in reach.
class XcBottomActionBar extends StatelessWidget {
  const XcBottomActionBar({super.key, required this.children, this.summary});

  final List<Widget> children;
  final Widget? summary;

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: colors.float,
        shape: AppShape.top(AppCorner.xxl),
        shadows: XcShadow.float(colors),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            XcSpace.lg,
            XcSpace.md,
            XcSpace.lg,
            XcSpace.md,
          ),
          child: Row(
            spacing: XcSpace.sm,
            children: [
              if (summary != null) Expanded(child: summary!),
              for (final child in children)
                summary == null ? Expanded(child: child) : child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Places a banner callout in the page gutter, centred on wide windows.
class XcBannerSlot extends StatelessWidget {
  const XcBannerSlot({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final gutter = XcSpace.gutterOf(MediaQuery.sizeOf(context).width);
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, 6, gutter, 6),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: XcSpace.contentWidth),
          child: child,
        ),
      ),
    );
  }
}

/// Filled fields for forms on a card: the fill is one level above the card,
/// and only focus draws a stroke, as `.agents/surfaces.md` sets inputs.
class XcFieldTheme extends StatelessWidget {
  const XcFieldTheme({super.key, required this.child, this.floating = false});

  final Widget child;

  /// Keeps the label above a filled field, for forms with several fields.
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = XcColors.of(context);
    final shape = AppShape.input.copyWith(borderRadius: AppRadius.md);
    final none = shape.copyWith(borderSide: BorderSide.none);
    return XcStandardDensity(
      child: InputDecorationTheme(
        data: InputDecorationTheme.of(context).copyWith(
          filled: true,
          fillColor: context.raisedSurfaceLevel.colorOf(scheme),
          hoverColor: Colors.transparent,
          floatingLabelBehavior: floating
              ? FloatingLabelBehavior.auto
              : FloatingLabelBehavior.never,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: XcSpace.md,
            vertical: 18,
          ),
          prefixIconColor: colors.muted,
          suffixIconColor: colors.muted,
          border: none,
          enabledBorder: none,
          disabledBorder: none,
          errorBorder: none,
          focusedBorder: shape.copyWith(
            borderSide: BorderSide(color: scheme.primary, width: 2),
          ),
          focusedErrorBorder: shape.copyWith(
            borderSide: BorderSide(color: scheme.error, width: 2),
          ),
        ),
        child: child,
      ),
    );
  }
}

/// Errors appear on the first [XcFormState.validate], then follow each edit.
class XcForm extends StatefulWidget {
  const XcForm({super.key, required this.child});

  final Widget child;

  @override
  State<XcForm> createState() => XcFormState();
}

class XcFormState extends State<XcForm> {
  final _form = GlobalKey<FormState>();
  bool _submitted = false;

  bool validate() {
    if (!_submitted) setState(() => _submitted = true);
    return _form.currentState!.validate();
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    autovalidateMode: _submitted
        ? AutovalidateMode.onUserInteraction
        : AutovalidateMode.disabled,
    child: widget.child,
  );
}

/// Windows and macOS default Material to compact density, 8 dp shorter than
/// the sizes in DESIGN-SYSTEM.md; brand pages pin the standard one instead.
class XcStandardDensity extends StatelessWidget {
  const XcStandardDensity({super.key, required this.child});

  final Widget child;

  static final _themes = Expando<ThemeData>();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: _themes[theme] ??= theme.copyWith(
        visualDensity: VisualDensity.standard,
      ),
      child: child,
    );
  }
}
