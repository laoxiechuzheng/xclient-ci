import 'package:animations/animations.dart';
import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// Fades and lifts [child] in once, [index] steps after its siblings. One
/// controller covers the delay as well, so no timer outlives the widget.
class XcEntrance extends StatefulWidget {
  const XcEntrance({
    super.key,
    this.index = 0,
    this.offset = 14,
    required this.child,
  });

  final int index;
  final double offset;
  final Widget child;

  @override
  State<XcEntrance> createState() => _XcEntranceState();
}

class _XcEntranceState extends State<XcEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: XcMotion.emphasized + XcMotion.stagger * _steps,
  );
  late final Animation<double> _progress = CurvedAnimation(
    parent: _controller,
    curve: Interval(
      _controller.duration!.inMicroseconds == 0
          ? 0
          : (XcMotion.stagger * _steps).inMicroseconds /
                _controller.duration!.inMicroseconds,
      1,
      curve: XcMotion.emphasizedCurve,
    ),
  );

  int get _steps => widget.index.clamp(0, 8);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller.isAnimating || _controller.isCompleted) return;
    if (XcMotion.reduced(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _progress,
    builder: (context, child) => Opacity(
      opacity: _progress.value,
      child: Transform.translate(
        offset: Offset(0, widget.offset * (1 - _progress.value)),
        child: child,
      ),
    ),
    child: widget.child,
  );
}

/// Counts from the last shown [value] to the new one.
class XcAnimatedNumber extends StatelessWidget {
  const XcAnimatedNumber({
    super.key,
    required this.value,
    required this.format,
    this.style,
    this.from = 0,
  });

  final double value;
  final double from;
  final String Function(double value) format;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: from, end: value),
    duration: XcMotion.of(context, XcMotion.tween),
    curve: XcMotion.emphasizedCurve,
    builder: (context, shown, _) => Text(
      format(shown),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: style,
    ),
  );
}

/// The shell's page change: the old page fades out before the new one rises,
/// so two layouts never overlap.
class XcPageSwitcher extends StatelessWidget {
  const XcPageSwitcher({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => PageTransitionSwitcher(
    duration: XcMotion.of(context, XcMotion.emphasized),
    layoutBuilder: (entries) => Stack(fit: StackFit.expand, children: entries),
    transitionBuilder: (child, primary, secondary) => FadeThroughTransition(
      animation: primary,
      secondaryAnimation: secondary,
      fillColor: Colors.transparent,
      child: child,
    ),
    child: child,
  );
}

/// Cross-fades text or a small widget whenever its [value] key changes.
class XcSwap extends StatelessWidget {
  const XcSwap({
    super.key,
    required this.value,
    this.alignment = Alignment.center,
    required this.child,
  });

  final Object? value;
  final AlignmentGeometry alignment;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: XcMotion.of(context, XcMotion.standard),
    switchInCurve: const Interval(0.35, 1, curve: XcMotion.standardCurve),
    switchOutCurve: const Interval(0.65, 1, curve: XcMotion.exitCurve),
    layoutBuilder: (current, previous) =>
        Stack(alignment: alignment, children: [...previous, ?current]),
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.18),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    ),
    child: KeyedSubtree(key: ValueKey(value), child: child),
  );
}
