import 'package:fl_clash/ui/color.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/surface.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:material_color_utilities/material_color_utilities.dart'
    show Hct;
import 'package:material_ui/material_ui.dart';

/// XClient's design tokens. `lib/xboard/ui/DESIGN-SYSTEM.md` is the reference;
/// every brand derives its palette from the theme's primary color alone.
abstract final class XcSpace {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double huge = 48;

  static const double minTouch = 48;
  static const double formWidth = 420;
  static const double contentWidth = 1120;

  static double gutterOf(double width) => width >= XcBreakpoint.desktop
      ? xxl
      : width < 380
      ? md
      : lg;
}

abstract final class XcBreakpoint {
  static const double desktop = 840;
  static const double wide = 1100;
}

abstract final class XcRadius {
  static const RoundedSuperellipseBorder control = AppShape.md;
  static const RoundedSuperellipseBorder tile = AppShape.lg;
  static const RoundedSuperellipseBorder card = AppShape.xl;
  static const RoundedSuperellipseBorder hero = AppShape.xxl;
  static const RoundedSuperellipseBorder pill = AppShape.full;
}

abstract final class XcMotion {
  static const quick = Duration(milliseconds: 160);
  static const standard = Duration(milliseconds: 280);
  static const emphasized = Duration(milliseconds: 460);
  static const tween = Duration(milliseconds: 900);
  static const celebrate = Duration(milliseconds: 1200);
  static const orbit = Duration(milliseconds: 1400);
  static const stagger = Duration(milliseconds: 70);

  static const Curve standardCurve = Curves.easeOutCubic;
  static const Curve emphasizedCurve = Cubic(0.2, 0, 0, 1);
  static const Curve exitCurve = Curves.easeInCubic;
  static const Curve settleCurve = Cubic(0.34, 1.36, 0.64, 1);

  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  static Duration of(BuildContext context, Duration duration) =>
      reduced(context) ? Duration.zero : duration;
}

enum XcTone { neutral, accent, success, warning, danger }

@immutable
class XcColors {
  const XcColors._({
    required this.dark,
    required this.page,
    required this.card,
    required this.block,
    required this.inset,
    required this.float,
    required this.title,
    required this.muted,
    required this.hairline,
    required this.accent,
    required this.onAccent,
    required this.accentLight,
    required this.accentDeep,
    required this.accentSoft,
    required this.success,
    required this.warning,
    required this.danger,
  });

  factory XcColors.of(BuildContext context) =>
      XcColors.from(Theme.of(context).colorScheme);

  factory XcColors.from(ColorScheme scheme) =>
      _cache[scheme] ??= _derive(scheme);

  static final _cache = Expando<XcColors>();

  static XcColors _derive(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    final card = SurfaceLevel.card.colorOf(scheme);
    final accent = scheme.primary;
    final hct = Hct.fromInt(accent.toARGB32());
    Color shade(double hueShift, double toneShift) => Color(
      Hct.from(
        (hct.hue + hueShift) % 360,
        hct.chroma,
        (hct.tone + toneShift).clamp(18, 82),
      ).toInt(),
    );
    return XcColors._(
      dark: dark,
      page: SurfaceLevel.page.colorOf(scheme),
      card: card,
      block: SurfaceLevel.block.colorOf(scheme),
      inset: SurfaceLevel.inset.colorOf(scheme),
      float: SurfaceLevel.floatingOf(scheme).colorOf(scheme),
      title: scheme.onSurface,
      muted: scheme.onSurfaceVariant,
      hairline: scheme.onSurface.withValues(alpha: dark ? 0.12 : 0.08),
      accent: accent,
      onAccent: scheme.onPrimary,
      accentLight: shade(-12, dark ? 10 : 12),
      accentDeep: shade(16, dark ? -14 : -12),
      accentSoft: Color.alphaBlend(
        accent.withValues(alpha: dark ? 0.2 : 0.1),
        card,
      ),
      success: scheme.success,
      warning: scheme.warning,
      danger: scheme.error,
    );
  }

  final bool dark;
  final Color page;
  final Color card;
  final Color block;
  final Color inset;
  final Color float;
  final Color title;
  final Color muted;
  final Color hairline;
  final Color accent;
  final Color onAccent;
  final Color accentLight;
  final Color accentDeep;
  final Color accentSoft;
  final Color success;
  final Color warning;
  final Color danger;

  LinearGradient get accentGradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accentLight, accent, accentDeep],
    stops: const [0, 0.55, 1],
  );

  Color toneOf(XcTone tone) => switch (tone) {
    XcTone.neutral => muted,
    XcTone.accent => accent,
    XcTone.success => success,
    XcTone.warning => warning,
    XcTone.danger => danger,
  };

  /// [tone] lifted for strokes and fills, where the text tone reads muddy.
  Color vividOf(XcTone tone) {
    if (tone == XcTone.accent || tone == XcTone.neutral) return toneOf(tone);
    final hct = Hct.fromInt(toneOf(tone).toARGB32());
    return Color(Hct.from(hct.hue, hct.chroma, dark ? 74 : 62).toInt());
  }

  /// A quiet surface in [tone]'s hue for a callout that blocks something.
  Color washOf(XcTone tone) {
    if (tone == XcTone.neutral) return block;
    final hct = Hct.fromInt(toneOf(tone).toARGB32());
    return Color(
      Hct.from(
        hct.hue,
        hct.chroma.clamp(0, dark ? 22 : 16),
        dark ? 18 : 94,
      ).toInt(),
    );
  }

  /// A wash of [tone] over a card, for glyph wells and status chips only.
  Color softOf(XcTone tone) => tone == XcTone.neutral
      ? block
      : Color.alphaBlend(
          toneOf(tone).withValues(alpha: dark ? 0.2 : 0.12),
          card,
        );
}

abstract final class XcShadow {
  static List<BoxShadow> card(XcColors colors) => colors.dark
      ? const []
      : const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 2,
            offset: Offset(0, 1),
          ),
          BoxShadow(
            color: Color(0x0D0B1730),
            blurRadius: 28,
            spreadRadius: -6,
            offset: Offset(0, 12),
          ),
        ];

  static List<BoxShadow> float(XcColors colors) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: colors.dark ? 0.4 : 0.06),
      blurRadius: 2,
      offset: const Offset(0, 1),
    ),
    BoxShadow(
      color: Colors.black.withValues(alpha: colors.dark ? 0.5 : 0.12),
      blurRadius: 32,
      spreadRadius: -4,
      offset: const Offset(0, 14),
    ),
  ];

  static List<BoxShadow> glow(Color color, {double strength = 1}) => [
    BoxShadow(
      color: color.withValues(alpha: 0.34 * strength),
      blurRadius: 36,
      spreadRadius: -6,
      offset: const Offset(0, 14),
    ),
  ];
}

/// Text roles on top of [AppTextStyle]; numbers use tabular figures so a
/// tweening value does not jitter.
abstract final class XcType {
  static const _tabular = [FontFeature.tabularFigures()];

  static TextStyle display(BuildContext context) => AppTextStyle.largeTitle
      .of(context, emphasized: true)
      .copyWith(fontFeatures: _tabular, color: _title(context));

  static TextStyle figure(BuildContext context) => AppTextStyle.title1
      .of(context, emphasized: true)
      .copyWith(fontFeatures: _tabular, color: _title(context));

  static TextStyle metric(BuildContext context) => AppTextStyle.title3
      .of(context, emphasized: true)
      .copyWith(fontFeatures: _tabular, color: _title(context));

  static TextStyle pageTitle(BuildContext context) => AppTextStyle.title1
      .of(context, emphasized: true)
      .copyWith(color: _title(context));

  static TextStyle title(BuildContext context) => AppTextStyle.title3
      .of(context, emphasized: true)
      .copyWith(color: _title(context));

  static TextStyle headline(BuildContext context) =>
      AppTextStyle.headline.of(context).copyWith(color: _title(context));

  static TextStyle body(BuildContext context) =>
      AppTextStyle.callout.of(context).copyWith(color: _title(context));

  static TextStyle secondary(BuildContext context) =>
      AppTextStyle.subheadline.of(context).copyWith(color: _muted(context));

  static TextStyle caption(BuildContext context) =>
      AppTextStyle.footnote.of(context).copyWith(color: _muted(context));

  static TextStyle label(BuildContext context) => AppTextStyle.caption1
      .of(context, emphasized: true)
      .copyWith(color: _muted(context), letterSpacing: 0.2);

  static TextStyle value(BuildContext context) => AppTextStyle.headline
      .of(context)
      .copyWith(fontFeatures: _tabular, color: _title(context));

  static Color _title(BuildContext context) =>
      Theme.of(context).colorScheme.onSurface;

  static Color _muted(BuildContext context) =>
      Theme.of(context).colorScheme.onSurfaceVariant;
}
