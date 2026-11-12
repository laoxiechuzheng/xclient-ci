import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../providers.dart';
import 'tokens.dart';

class XcExitAction extends ConsumerStatefulWidget {
  const XcExitAction({super.key});

  @override
  ConsumerState<XcExitAction> createState() => _XcExitActionState();
}

class _XcExitActionState extends ConsumerState<XcExitAction> {
  bool _pending = false;

  Future<void> _exit() async {
    if (_pending || ref.read(xcClosingProvider)) return;
    setState(() => _pending = true);
    try {
      await ref.read(systemActionProvider.notifier).handleExit();
    } on Object {
      // The exit coordinator owns stop failure feedback and retry state.
    } finally {
      if (mounted) setState(() => _pending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(xcManagedAndroidProvider)) return const SizedBox.shrink();
    final closing = ref.watch(xcClosingProvider) || _pending;
    final running = ref.watch(isStartProvider);
    final colors = XcColors.of(context);
    return TextButton.icon(
      key: const Key('xc-client-exit'),
      onPressed: closing ? null : _exit,
      style: TextButton.styleFrom(
        foregroundColor: colors.danger,
        disabledForegroundColor: colors.muted,
        minimumSize: const Size(0, XcSpace.minTouch),
        padding: const EdgeInsets.symmetric(horizontal: XcSpace.md),
        textStyle: XcType.label(context),
      ),
      icon: GlyphIcon(closing ? AppGlyphs.sync : AppGlyphs.vpn, size: 20),
      label: Text(
        closing
            ? '正在退出…'
            : running
            ? '断开并退出'
            : '退出客户端',
      ),
    );
  }
}
