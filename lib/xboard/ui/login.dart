import 'dart:async';

import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/ui/pop_scope.dart';
import 'package:fl_clash/providers/providers.dart' as app;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fl_clash/ui/loading.dart';

import '../providers.dart';
import 'common/components.dart';
import 'common/errors.dart';
import 'common/exit_action.dart';
import 'common/gradient.dart';
import 'common/motion.dart';
import 'common/tokens.dart';
import 'common/widgets.dart';
import 'shell.dart' show XcCommerceHost;
import 'shell/navigation.dart' show XcBrandMark;

class XcRootBackScope extends ConsumerStatefulWidget {
  const XcRootBackScope({super.key, required this.child, this.navigatorKey});
  final Widget child;
  final GlobalKey<NavigatorState>? navigatorKey;
  @override
  ConsumerState<XcRootBackScope> createState() => _XcRootBackScopeState();
}

class _XcRootBackScopeState extends ConsumerState<XcRootBackScope> {
  bool _handling = false;
  @override
  Widget build(BuildContext context) => CommonPopScope(
    onPop: (_) async {
      if (_handling) return false;
      _handling = true;
      try {
        final navigator = widget.navigatorKey?.currentState;
        if (navigator != null && await navigator.maybePop()) return false;
        if (mounted) {
          await ref.read(app.systemActionProvider.notifier).handleClose();
        }
        return false;
      } finally {
        _handling = false;
      }
    },
    child: widget.child,
  );
}

class XcAuthGate extends ConsumerStatefulWidget {
  const XcAuthGate({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<XcAuthGate> createState() => _XcAuthGateState();
}

class _XcAuthGateState extends ConsumerState<XcAuthGate> {
  final _navigator = GlobalKey<NavigatorState>();
  @override
  Widget build(BuildContext context) {
    final brand = ref.watch(xcBrandConfigProvider);
    return XcRootBackScope(
      navigatorKey: _navigator,
      child: ref
          .watch(xcSessionProvider)
          .when(
            loading: () => XcLaunchView(
              key: XcLaunchView.handoff,
              displayName: brand.displayName,
            ),
            error: (error, stack) => Scaffold(
              body: SafeArea(
                child: XcStateView(
                  tone: XcTone.danger,
                  glyph: AppGlyphs.error,
                  title: '客户端初始化失败，请重试',
                  message: '可能是网络暂时不可用，重试通常即可恢复。',
                  action: XcButton(
                    label: '重试',
                    glyph: AppGlyphs.refresh,
                    onPressed: () => ref.invalidate(xcRuntimeProvider),
                  ),
                ),
              ),
            ),
            data: (session) {
              if (session.isLoggedIn) {
                return XcCommerceHost(
                  child: Navigator(
                    key: _navigator,
                    onGenerateRoute: (_) =>
                        MaterialPageRoute<void>(builder: (_) => widget.child),
                  ),
                );
              }
              return XcLoginPage(
                displayName: brand.displayName,
                panelWebUrl: Uri.tryParse(brand.panelWebUrl),
                message: session.message,
                footer: ref.watch(xcManagedAndroidProvider)
                    ? const XcExitAction()
                    : null,
                onLogin: (email, password) =>
                    ref.read(xcActionsProvider).login(email, password),
              );
            },
          ),
    );
  }
}

class XcLoginPage extends StatefulWidget {
  const XcLoginPage({
    super.key,
    required this.displayName,
    required this.onLogin,
    this.panelWebUrl,
    this.message,
    this.footer,
  });
  final String displayName;
  final Uri? panelWebUrl;
  final String? message;
  final Widget? footer;
  final Future<void> Function(String email, String password) onLogin;
  @override
  State<XcLoginPage> createState() => _XcLoginPageState();
}

class _XcLoginPageState extends State<XcLoginPage> {
  final _form = GlobalKey<XcFormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onLogin(_email.text.trim(), _password.text);
      if (mounted) _password.clear();
    } catch (error) {
      if (mounted) setState(() => _error = xcLoginErrorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String fragment) async {
    final base = widget.panelWebUrl;
    if (base == null ||
        !await xcOpenExternal(base.replace(fragment: fragment))) {
      if (mounted) xcMessage(context, '暂时无法打开站点，请稍后重试');
    }
  }

  Widget _formCard(BuildContext context) {
    final colors = XcColors.of(context);
    final notice = _error ?? widget.message;
    return XcPanel(
      elevated: true,
      shape: XcRadius.hero,
      padding: const EdgeInsets.all(XcSpace.xl),
      child: XcFieldTheme(
        child: XcForm(
          key: _form,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const Key('xc-login-email'),
                  controller: _email,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: '邮箱',
                    prefixIcon: GlyphIcon(AppGlyphs.account, size: 20),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  autofillHints: const [AutofillHints.username],
                  validator: validateLoginEmail,
                ),
                const SizedBox(height: XcSpace.sm),
                TextFormField(
                  key: const Key('xc-login-password'),
                  controller: _password,
                  enabled: !_busy,
                  decoration: InputDecoration(
                    labelText: '密码',
                    prefixIcon: const GlyphIcon(AppGlyphs.lock, size: 20),
                    suffixIcon: IconButton(
                      tooltip: _obscure ? '显示密码' : '隐藏密码',
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: GlyphIcon(
                        _obscure ? AppGlyphs.eye : AppGlyphs.eyeOff,
                        size: 20,
                      ),
                    ),
                  ),
                  obscureText: _obscure,
                  autocorrect: false,
                  autofillHints: const [AutofillHints.password],
                  validator: validateLoginPassword,
                  onFieldSubmitted: (_) => _submit(),
                ),
                AnimatedSize(
                  duration: XcMotion.of(context, XcMotion.standard),
                  curve: XcMotion.emphasizedCurve,
                  alignment: Alignment.topCenter,
                  child: notice == null
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.only(top: XcSpace.md),
                          child: _LoginNotice(
                            message: notice,
                            tone: _error == null
                                ? XcTone.warning
                                : XcTone.danger,
                          ),
                        ),
                ),
                const SizedBox(height: XcSpace.lg),
                XcButton(
                  buttonKey: const Key('xc-login-submit'),
                  label: '登录',
                  loadingLabel: '正在登录',
                  size: XcButtonSize.large,
                  expand: true,
                  loading: _busy,
                  onPressed: _submit,
                ),
                AnimatedSize(
                  duration: XcMotion.of(context, XcMotion.standard),
                  curve: XcMotion.emphasizedCurve,
                  child: _busy
                      ? Padding(
                          padding: const EdgeInsets.only(top: XcSpace.sm),
                          child: Text(
                            '正在安全验证账号，请稍候…',
                            textAlign: TextAlign.center,
                            style: XcType.caption(context),
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
                const SizedBox(height: XcSpace.md),
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('还没有账号？', style: XcType.secondary(context)),
                          _LinkButton(
                            label: '注册账号',
                            onPressed: widget.panelWebUrl == null
                                ? null
                                : () => _open('/register'),
                          ),
                        ],
                      ),
                    ),
                    _LinkButton(
                      label: '忘记密码',
                      color: colors.muted,
                      onPressed: widget.panelWebUrl == null
                          ? null
                          : () => _open('/forgot-password'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
    displayName: widget.displayName,
    builder: (context, wide, gutter) {
      final form = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!wide) ...[
            XcEntrance(
              child: Row(
                spacing: XcSpace.sm,
                children: [
                  XcBrandMark(title: widget.displayName, size: 44),
                  Expanded(
                    child: Text(
                      widget.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: XcType.headline(context),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: XcSpace.xxl),
          ],
          XcEntrance(
            index: 1,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: XcSpace.xs,
              children: [
                Text(
                  '欢迎回来',
                  style: AppTextStyle.largeTitle
                      .of(context, emphasized: true)
                      .copyWith(color: XcColors.of(context).title),
                ),
                Text('登录后一键连接，节点会自动加密同步。', style: XcType.secondary(context)),
              ],
            ),
          ),
          const SizedBox(height: XcSpace.xl),
          XcEntrance(index: 2, child: _formCard(context)),
          const SizedBox(height: XcSpace.lg),
          const XcEntrance(index: 3, child: _TrustLine()),
          if (widget.footer case final footer?) ...[
            const SizedBox(height: XcSpace.md),
            Center(child: footer),
          ],
        ],
      );
      return SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: gutter, vertical: XcSpace.xl),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: XcSpace.formWidth + 20),
            child: form,
          ),
        ),
      );
    },
  );
}

/// The sign-in backdrop around [builder]'s column: a brand panel beside it
/// from 900 dp, the aurora alone below that.
class _AuthScaffold extends StatefulWidget {
  const _AuthScaffold({
    required this.displayName,
    required this.builder,
    this.showcase = true,
  });
  final String displayName;
  final Widget Function(BuildContext context, bool wide, double gutter) builder;
  final bool showcase;
  @override
  State<_AuthScaffold> createState() => _AuthScaffoldState();
}

class _AuthScaffoldState extends State<_AuthScaffold> {
  bool? _wide;
  bool _settled = false;
  @override
  Widget build(BuildContext context) => XcStandardDensity(
    child: Scaffold(
      backgroundColor: XcColors.of(context).page,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          _settled |= _wide != null && _wide != wide;
          _wide = wide;
          final content = SafeArea(
            child: Center(
              child: widget.builder(
                context,
                wide,
                XcSpace.gutterOf(constraints.maxWidth),
              ),
            ),
          );
          return XcEntranceSettled(
            settled: _settled,
            child: wide
                ? Row(
                    children: [
                      Expanded(
                        flex: 5,
                        child: _BrandPanel(
                          displayName: widget.displayName,
                          showcase: widget.showcase,
                        ),
                      ),
                      Expanded(
                        flex: 6,
                        child: Stack(
                          children: [
                            const Positioned.fill(child: _Aurora(subtle: true)),
                            content,
                          ],
                        ),
                      ),
                    ],
                  )
                : Stack(
                    children: [
                      const Positioned.fill(child: _Aurora()),
                      content,
                    ],
                  ),
          );
        },
      ),
    ),
  );
}

/// Shown while the client starts and checks the session, on the sign-in
/// backdrop, so the form arrives without the background changing.
class XcLaunchView extends StatefulWidget {
  const XcLaunchView({super.key, required this.displayName});
  final String displayName;

  /// Startup and the session check each show a launch view; one key keeps a
  /// single state, with its clock and motion, across the handover.
  static final handoff = GlobalKey(debugLabel: 'xc-launch');

  static const slowAfter = Duration(seconds: 4);

  @override
  State<XcLaunchView> createState() => _XcLaunchViewState();
}

class _XcLaunchViewState extends State<XcLaunchView> {
  Timer? _slowTimer;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _slowTimer = Timer(XcLaunchView.slowAfter, () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
    displayName: widget.displayName,
    showcase: false,
    builder: (context, wide, gutter) {
      final colors = XcColors.of(context);
      final status = _slow ? '网络较慢，仍在尝试…' : '正在准备安全连接…';
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!wide) ...[
              XcEntrance(
                child: XcBrandMark(title: widget.displayName, size: 64),
              ),
              const SizedBox(height: XcSpace.lg),
              XcEntrance(
                child: Text(
                  widget.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: XcType.headline(context),
                ),
              ),
              const SizedBox(height: XcSpace.xxl),
            ],
            XcEntrance(
              index: 1,
              child: Semantics(
                liveRegion: true,
                label: status,
                excludeSemantics: true,
                child: XcSwap(
                  value: _slow,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    spacing: XcSpace.xs,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: XcSpace.sm,
                        children: [
                          CommonCircleLoading(size: 18, color: colors.accent),
                          Flexible(
                            child: Text(
                              status,
                              style: XcType.secondary(context),
                            ),
                          ),
                        ],
                      ),
                      if (_slow)
                        Text(
                          '无需操作，准备好后会自动继续。',
                          textAlign: TextAlign.center,
                          style: XcType.caption(context),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _LoginNotice extends StatelessWidget {
  const _LoginNotice({required this.message, required this.tone});
  final String message;
  final XcTone tone;
  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: colors.softOf(tone),
          shape: XcRadius.control,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: GlyphIcon(
                  tone == XcTone.danger ? AppGlyphs.error : AppGlyphs.info,
                  size: 18,
                  color: colors.toneOf(tone),
                  fill: 1,
                ),
              ),
              Expanded(child: Text(message, style: XcType.body(context))),
            ],
          ),
        ),
      ),
    );
  }
}

class _LinkButton extends StatelessWidget {
  const _LinkButton({required this.label, required this.onPressed, this.color});
  final String label;
  final VoidCallback? onPressed;
  final Color? color;
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: color ?? XcColors.of(context).accent,
      minimumSize: const Size(48, 44),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      textStyle: AppTextStyle.subheadline.of(context, emphasized: true),
    ),
    child: Text(label),
  );
}

class _TrustLine extends StatelessWidget {
  const _TrustLine();
  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      spacing: 6,
      children: [
        GlyphIcon(AppGlyphs.verified, size: 15, color: colors.success, fill: 1),
        Flexible(
          child: Text(
            '全程加密传输 · 注册和找回密码将在浏览器中打开',
            textAlign: TextAlign.center,
            style: XcType.caption(context),
          ),
        ),
      ],
    );
  }
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel({required this.displayName, required this.showcase});
  final String displayName;
  final bool showcase;
  static const _features = [
    (AppGlyphs.bolt, '一键连接', '登录后点一下，即可开启加密连接'),
    (AppGlyphs.cloudSync, '节点自动同步', '线路加密下发，无需手动导入或配置'),
    (AppGlyphs.dataUsage, '账户一目了然', '流量、到期时间和订单随时查看'),
  ];
  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    const onBrand = Colors.white;
    return DecoratedBox(
      decoration: XcGradientDecoration(
        shape: AppShape.none,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.accentLight, colors.accent, colors.accentDeep],
        ),
      ),
      child: Stack(
        children: [
          const Positioned.fill(child: _Aurora(onBrand: true)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(XcSpace.huge),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    spacing: XcSpace.sm,
                    children: [
                      DecoratedBox(
                        decoration: ShapeDecoration(
                          color: onBrand.withValues(alpha: 0.18),
                          shape: AppShape.all(AppCorner.md - 2),
                        ),
                        child: SizedBox.square(
                          dimension: 44,
                          child: Center(
                            child: Text(
                              displayName.trim().isEmpty
                                  ? 'X'
                                  : String.fromCharCode(
                                      displayName.trim().runes.first,
                                    ).toUpperCase(),
                              style: AppTextStyle.title2
                                  .of(context, emphasized: true)
                                  .copyWith(color: onBrand),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.headline
                              .of(context)
                              .copyWith(color: onBrand),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  if (showcase) ...[
                    XcEntrance(
                      child: Text(
                        '一键连接，\n安心畅游网络',
                        style: AppTextStyle.display
                            .of(context, emphasized: true)
                            .copyWith(color: onBrand, height: 1.2),
                      ),
                    ),
                    const SizedBox(height: XcSpace.xxl),
                    for (final (index, (glyph, title, caption))
                        in _features.indexed)
                      XcEntrance(
                        index: index + 1,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: XcSpace.lg),
                          child: Row(
                            spacing: XcSpace.md,
                            children: [
                              DecoratedBox(
                                decoration: ShapeDecoration(
                                  color: onBrand.withValues(alpha: 0.16),
                                  shape: AppShape.circle,
                                ),
                                child: SizedBox.square(
                                  dimension: 44,
                                  child: Center(
                                    child: GlyphIcon(
                                      glyph,
                                      size: 22,
                                      color: onBrand,
                                      fill: 1,
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  spacing: 2,
                                  children: [
                                    Text(
                                      title,
                                      style: AppTextStyle.headline
                                          .of(context)
                                          .copyWith(color: onBrand),
                                    ),
                                    Text(
                                      caption,
                                      style: AppTextStyle.subheadline
                                          .of(context)
                                          .copyWith(
                                            color: onBrand.withValues(
                                              alpha: 0.82,
                                            ),
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                  const Spacer(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Soft light drawn from the brand color behind the sign-in form.
class _Aurora extends StatelessWidget {
  const _Aurora({this.subtle = false, this.onBrand = false});
  final bool subtle;
  final bool onBrand;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        isComplex: true,
        painter: _AuroraPainter(
          colors: XcColors.of(context),
          strength: subtle ? 0.55 : 1,
          onBrand: onBrand,
        ),
      ),
    ),
  );
}

class _AuroraPainter extends CustomPainter {
  const _AuroraPainter({
    required this.colors,
    required this.strength,
    required this.onBrand,
  });
  final XcColors colors;
  final double strength;
  final bool onBrand;
  @override
  void paint(Canvas canvas, Size size) {
    void glow(Offset center, double radius, Color color, double alpha) {
      final rect = Rect.fromCircle(center: center, radius: radius);
      canvas.drawRect(
        rect.intersect(Offset.zero & size),
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: alpha * strength),
              color.withValues(alpha: 0),
            ],
          ).createShader(rect),
      );
    }

    final side = size.longestSide;
    if (onBrand) {
      glow(
        Offset(size.width * 0.9, size.height * 0.1),
        side * 0.5,
        Colors.white,
        0.18,
      );
      glow(Offset(0, size.height), side * 0.6, colors.accentDeep, 0.5);
      return;
    }
    final lift = colors.dark ? 0.26 : 0.2;
    glow(
      Offset(size.width * 0.1, -size.height * 0.02),
      side * 0.62,
      colors.accentLight,
      lift,
    );
    glow(
      Offset(size.width * 1.02, size.height * 0.16),
      side * 0.5,
      colors.accentDeep,
      lift * 0.7,
    );
    glow(
      Offset(size.width * 0.5, size.height * 1.05),
      side * 0.6,
      colors.accent,
      lift * 0.35,
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter oldDelegate) =>
      !identical(colors, oldDelegate.colors) ||
      strength != oldDelegate.strength ||
      onBrand != oldDelegate.onBrand;
}
