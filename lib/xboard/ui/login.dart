import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/ui/pop_scope.dart';
import 'package:fl_clash/providers/providers.dart' as app;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fl_clash/ui/loading.dart';

import '../providers.dart';
import 'common/errors.dart';
import 'common/exit_action.dart';
import 'common/widgets.dart';
import 'shell.dart' show XcCommerceHost;

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
            loading: () => const Scaffold(
              body: Center(
                child: CommonCircleLoading.page(semanticLabel: '正在加载'),
              ),
            ),
            error: (error, stack) => Scaffold(
              body: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 16,
                    children: [
                      const Text('客户端初始化失败，请重试'),
                      FilledButton(
                        onPressed: () => ref.invalidate(xcRuntimeProvider),
                        child: const Text('重试'),
                      ),
                    ],
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
  final _form = GlobalKey<FormState>();
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

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 20,
                children: [
                  Text(
                    widget.displayName,
                    style: AppTextStyle.largeTitle.of(context),
                  ),
                  Text('登录，开启安心连接', style: AppTextStyle.title2.of(context)),
                  Text(
                    '使用您的站点账号登录。节点将自动安全同步。',
                    style: AppTextStyle.body
                        .of(context)
                        .copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  TextFormField(
                    key: const Key('xc-login-email'),
                    controller: _email,
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: '邮箱'),
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    autofillHints: const [AutofillHints.username],
                    validator: validateLoginEmail,
                  ),
                  TextFormField(
                    key: const Key('xc-login-password'),
                    controller: _password,
                    enabled: !_busy,
                    decoration: InputDecoration(
                      labelText: '密码',
                      suffixIcon: TextButton(
                        onPressed: () => setState(() => _obscure = !_obscure),
                        child: Text(_obscure ? '显示' : '隐藏'),
                      ),
                    ),
                    obscureText: _obscure,
                    autocorrect: false,
                    autofillHints: const [AutofillHints.password],
                    validator: validateLoginPassword,
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  if (_error ?? widget.message case final message?)
                    Text(
                      message,
                      style: AppTextStyle.callout
                          .of(context)
                          .copyWith(color: Theme.of(context).colorScheme.error),
                    ),
                  FilledButton(
                    key: const Key('xc-login-submit'),
                    onPressed: _busy ? null : _submit,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: _busy
                          ? const CommonCircleLoading(
                              size: 20,
                              semanticLabel: '正在登录',
                            )
                          : const Text('登录'),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: widget.panelWebUrl == null
                            ? null
                            : () => _open('/register'),
                        child: const Text('注册账号'),
                      ),
                      TextButton(
                        onPressed: widget.panelWebUrl == null
                            ? null
                            : () => _open('/forgot-password'),
                        child: const Text('忘记密码'),
                      ),
                    ],
                  ),
                  ?widget.footer,
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
