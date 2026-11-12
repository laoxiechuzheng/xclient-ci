import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/surface.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:material_ui/material_ui.dart';

import '../common/tokens.dart';

class XcDestination {
  const XcDestination({required this.glyph, required this.label});

  final Glyph glyph;
  final String label;
}

/// The phone's floating tab bar: a neutral platter slides under the chosen
/// destination, whose glyph fills and takes the accent.
class XcBottomNav extends StatelessWidget {
  const XcBottomNav({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<XcDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const double _height = 64;
  static const double _inset = 6;

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        XcSpace.md,
        XcSpace.xs,
        XcSpace.md,
        bottom > XcSpace.sm ? bottom : XcSpace.sm,
      ),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: colors.float,
              shape: AppShape.full,
              shadows: XcShadow.float(colors),
            ),
            child: SizedBox(
              height: _height,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width =
                      (constraints.maxWidth - _inset * 2) / destinations.length;
                  return Stack(
                    children: [
                      AnimatedPositioned(
                        duration: XcMotion.of(context, XcMotion.emphasized),
                        curve: XcMotion.settleCurve,
                        left: _inset + width * selectedIndex,
                        top: _inset,
                        bottom: _inset,
                        width: width,
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            color: colors.dark ? colors.inset : colors.block,
                            shape: AppShape.full,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(_inset),
                        child: Row(
                          children: [
                            for (final (index, item) in destinations.indexed)
                              Expanded(
                                child: _NavItem(
                                  destination: item,
                                  selected: index == selectedIndex,
                                  vertical: true,
                                  onTap: () => onSelected(index),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The desktop sidebar, window chrome per `.agents/surfaces.md`.
class XcSideNav extends StatelessWidget {
  const XcSideNav({
    super.key,
    required this.title,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.extended,
  });

  final String title;
  final List<XcDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool extended;

  static const double _itemHeight = 48;
  static const double _compactHeight = 64;
  static const double _gap = 4;

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    final itemHeight = extended ? _itemHeight : _compactHeight;
    final pitch = itemHeight + _gap;
    return DecoratedBox(
      decoration: BoxDecoration(color: scheme.chromeSurface),
      child: SafeArea(
        right: false,
        child: SizedBox(
          width: extended ? 248 : 92,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  extended ? XcSpace.lg : XcSpace.md,
                  XcSpace.xl,
                  XcSpace.md,
                  XcSpace.xl,
                ),
                child: Row(
                  mainAxisAlignment: extended
                      ? MainAxisAlignment.start
                      : MainAxisAlignment.center,
                  spacing: XcSpace.sm,
                  children: [
                    XcBrandMark(title: title, size: 40),
                    if (extended)
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: XcType.headline(context),
                            ),
                            Text(
                              '安全 · 稳定 · 极速',
                              style: XcType.caption(context),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: XcSpace.sm),
                child: SizedBox(
                  height: pitch * destinations.length,
                  child: Stack(
                    children: [
                      AnimatedPositioned(
                        duration: XcMotion.of(context, XcMotion.emphasized),
                        curve: XcMotion.settleCurve,
                        left: 0,
                        right: 0,
                        top: pitch * selectedIndex,
                        height: itemHeight,
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            color: colors.dark ? colors.block : colors.card,
                            shape: XcRadius.control,
                            shadows: colors.dark
                                ? null
                                : const [
                                    BoxShadow(
                                      color: Color(0x0F000000),
                                      blurRadius: 6,
                                      offset: Offset(0, 1),
                                    ),
                                  ],
                          ),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              width: 3,
                              height: 18,
                              decoration: ShapeDecoration(
                                color: colors.accent,
                                shape: AppShape.full,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Column(
                        spacing: _gap,
                        children: [
                          for (final (index, item) in destinations.indexed)
                            SizedBox(
                              height: itemHeight,
                              child: _NavItem(
                                destination: item,
                                selected: index == selectedIndex,
                                vertical: !extended,
                                onTap: () => onSelected(index),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A rounded tile with the first letter of the brand on its accent gradient.
class XcBrandMark extends StatelessWidget {
  const XcBrandMark({super.key, required this.title, this.size = 48});

  final String title;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    final letter = title.trim().isEmpty
        ? 'X'
        : String.fromCharCode(title.trim().runes.first).toUpperCase();
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: ShapeDecoration(
          gradient: colors.accentGradient,
          shape: AppShape.all(AppCorner.fit(size) + 2),
          shadows: XcShadow.glow(colors.accent, strength: 0.6),
        ),
        child: SizedBox.square(
          dimension: size,
          child: Center(
            child: Text(
              letter,
              style: AppTextStyle.custom(
                context,
                size: size * 0.46,
                leading: size * 0.56,
                weight: FontWeight.w700,
              ).copyWith(color: colors.onAccent),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.vertical,
    required this.onTap,
  });

  final XcDestination destination;
  final bool selected;
  final bool vertical;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          customBorder: vertical ? AppShape.full : XcRadius.control,
          onTap: onTap,
          child: TweenAnimationBuilder<Color?>(
            tween: ColorTween(end: selected ? colors.accent : colors.muted),
            duration: XcMotion.of(context, XcMotion.standard),
            builder: (context, color, _) {
              final icon = IconTheme(
                data: IconThemeData(color: color, size: vertical ? 24 : 22),
                child: AnimatedGlyph(
                  glyph: destination.glyph,
                  filled: selected,
                ),
              );
              final label = Text(
                destination.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: (vertical ? AppTextStyle.caption1 : AppTextStyle.callout)
                    .of(context, emphasized: selected || vertical)
                    .copyWith(
                      color: vertical || selected ? color : colors.title,
                    ),
              );
              return vertical
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      spacing: 3,
                      children: [icon, label],
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Row(
                        spacing: XcSpace.sm,
                        children: [
                          icon,
                          Expanded(child: label),
                        ],
                      ),
                    );
            },
          ),
        ),
      ),
    );
  }
}
