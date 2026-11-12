import 'dart:async';

import 'package:fl_clash/ui/context.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/switch.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fl_clash/ui/loading.dart';
import 'package:url_launcher/url_launcher.dart';

import 'components.dart';
import 'errors.dart';
import 'motion.dart';
import 'tokens.dart';

Future<bool> xcOpenExternal(Uri uri) async {
  if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    return false;
  }
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

void xcMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

Future<bool> xcConfirm(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;

void xcPush(BuildContext context, Widget page) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
}

class XcPage extends StatelessWidget {
  const XcPage({
    super.key,
    required this.title,
    required this.child,
    this.actions,
    this.bottom,
  });
  final String title;
  final Widget child;
  final List<Widget>? actions;

  /// Stays below the content, for an action that must remain in reach.
  final Widget? bottom;
  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    return Scaffold(
      backgroundColor: colors.page,
      appBar: AppBar(
        backgroundColor: colors.page,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        titleSpacing: XcSpace.xs,
        title: Text(title, style: XcType.title(context)),
        actions: actions,
      ),
      bottomNavigationBar: bottom,
      body: SafeArea(
        top: false,
        bottom: bottom == null,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: XcSpace.readingWidth),
            child: child,
          ),
        ),
      ),
    );
  }
}

class XcSection extends StatelessWidget {
  const XcSection({
    super.key,
    this.title,
    this.glyph,
    this.trailing,
    required this.children,
  });
  final String? title;
  final Glyph? glyph;
  final Widget? trailing;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: XcSpace.md),
    child: XcPanel(
      elevated: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: XcSpace.sm,
        children: [
          if (title != null || trailing != null)
            Row(
              spacing: XcSpace.xs,
              children: [
                if (glyph case final glyph?)
                  GlyphIcon(glyph, size: 18, color: XcColors.of(context).muted),
                Expanded(
                  child: Text(title ?? '', style: XcType.headline(context)),
                ),
                ?trailing,
              ],
            ),
          ...children,
        ],
      ),
    ),
  );
}

class XcValue extends StatelessWidget {
  const XcValue(this.label, this.value, {super.key, this.strong = false});
  final String label;
  final Object? value;

  /// Sets the value as the figure a reader looks for, such as a total.
  final bool strong;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 140),
        child: Text(label, style: XcType.secondary(context)),
      ),
      const SizedBox(width: XcSpace.md),
      Expanded(
        child: SelectableText(
          '${value ?? '—'}',
          textAlign: TextAlign.end,
          style: strong ? XcType.metric(context) : XcType.value(context),
        ),
      ),
    ],
  );
}

class XcTaskButton extends StatefulWidget {
  const XcTaskButton({
    super.key,
    required this.label,
    required this.action,
    this.tonal = false,
    this.enabled = true,
    this.variant,
    this.size = XcButtonSize.medium,
    this.glyph,
    this.expand = false,
    this.loadingLabel,
  });
  final String label;
  final String? loadingLabel;
  final Future<void> Function() action;
  final bool tonal;
  final bool enabled;
  final XcButtonVariant? variant;
  final XcButtonSize size;
  final Glyph? glyph;
  final bool expand;
  @override
  State<XcTaskButton> createState() => _XcTaskButtonState();
}

class _XcTaskButtonState extends State<XcTaskButton> {
  bool _busy = false;
  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.action();
    } catch (error) {
      if (mounted) xcMessage(context, xcErrorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => XcButton(
    label: widget.label,
    loadingLabel: widget.loadingLabel,
    loading: _busy,
    glyph: widget.glyph,
    size: widget.size,
    expand: widget.expand,
    variant:
        widget.variant ??
        (widget.tonal ? XcButtonVariant.secondary : XcButtonVariant.primary),
    onPressed: widget.enabled ? _run : null,
  );
}

class XcLoad<T> extends StatefulWidget {
  const XcLoad({
    super.key,
    required this.load,
    required this.builder,
    this.emptyText = '暂无记录',
  });
  final Future<T> Function() load;
  final Widget Function(
    BuildContext context,
    T data,
    Future<void> Function() refresh,
  )
  builder;
  final String emptyText;
  @override
  State<XcLoad<T>> createState() => _XcLoadState<T>();
}

class _XcLoadState<T> extends State<XcLoad<T>> {
  late Future<T> _future;
  @override
  void initState() {
    super.initState();
    _future = Future<T>.sync(widget.load);
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final future = Future<T>.sync(widget.load);
    setState(() {
      _future = future;
    });
    try {
      await future;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
    future: _future,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(
          child: CommonCircleLoading.page(semanticLabel: '正在加载'),
        );
      }
      if (snapshot.hasError) {
        return XcStateView(
          tone: XcTone.danger,
          glyph: AppGlyphs.wifiOff,
          title: '内容没有加载出来',
          message: xcErrorText(snapshot.error!),
          action: XcButton(
            label: '重试',
            variant: XcButtonVariant.secondary,
            glyph: AppGlyphs.refresh,
            onPressed: _refresh,
          ),
        );
      }
      final data = snapshot.data;
      if (data == null) {
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              XcStateView(
                glyph: AppGlyphs.layers,
                title: widget.emptyText,
                message: '下拉或点击刷新，获取最新内容',
                action: XcButton(
                  label: '刷新',
                  variant: XcButtonVariant.secondary,
                  onPressed: _refresh,
                ),
              ),
            ],
          ),
        );
      }
      return RefreshIndicator(
        onRefresh: _refresh,
        child: widget.builder(context, data, _refresh),
      );
    },
  );
}

Widget xcList(List<Widget> children) => _XcList(children: children);

/// A page's scrolling column: gutters by width, clear of anything floating
/// over its foot, each block rising in after the one above it.
class _XcList extends StatelessWidget {
  const _XcList({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final gutter = XcSpace.gutterOf(MediaQuery.sizeOf(context).width);
    return ListView(
      padding: EdgeInsets.fromLTRB(
        gutter,
        XcSpace.xs,
        gutter,
        XcSpace.xl + context.bottomInset,
      ),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        for (final (index, child) in children.indexed)
          XcEntrance(index: index, child: child),
      ],
    );
  }
}

class XcMenuRow extends StatelessWidget {
  const XcMenuRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.onTap,
    this.glyph,
    this.tone = XcTone.accent,
    this.trailing,
  });
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Glyph? glyph;
  final XcTone tone;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: InkWell(
      customBorder: XcRadius.tile,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: XcSpace.minTouch + 4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: XcSpace.xs),
          child: Row(
            spacing: XcSpace.sm,
            children: [
              if (glyph case final glyph?)
                XcGlyphWell(glyph: glyph, tone: tone, size: 36),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(title, style: XcType.body(context)),
                    if (subtitle case final subtitle?)
                      Text(subtitle, style: XcType.caption(context)),
                  ],
                ),
              ),
              ?trailing,
              GlyphIcon(
                AppGlyphs.chevronForward,
                size: 18,
                color: XcColors.of(context).muted,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class XcToggleTile extends StatefulWidget {
  const XcToggleTile({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });
  final String label;
  final String? subtitle;
  final bool value;
  final Future<void> Function(bool value) onChanged;
  @override
  State<XcToggleTile> createState() => _XcToggleTileState();
}

class _XcToggleTileState extends State<XcToggleTile> {
  bool _busy = false;
  Future<void> _change(bool value) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onChanged(value);
    } catch (error) {
      if (mounted) xcMessage(context, xcErrorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => XcToggleRow(
    label: widget.label,
    subtitle: widget.subtitle,
    value: widget.value,
    onChanged: _busy ? null : _change,
  );
}

/// A labelled switch laid out like an [XcMenuRow].
class XcToggleRow extends StatelessWidget {
  const XcToggleRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: XcSpace.minTouch + 4),
    child: Row(
      spacing: XcSpace.sm,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Text(label, style: XcType.body(context)),
              if (subtitle case final subtitle?)
                Text(subtitle, style: XcType.caption(context)),
            ],
          ),
        ),
        CommonSwitch(value: value, semanticLabel: label, onChanged: onChanged),
      ],
    ),
  );
}
