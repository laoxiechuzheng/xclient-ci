import 'dart:async';

import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/ui/switch.dart';
import 'package:fl_clash/ui/surface.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fl_clash/ui/loading.dart';
import 'package:url_launcher/url_launcher.dart';

import 'errors.dart';

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
  });
  final String title;
  final Widget child;
  final List<Widget>? actions;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: SurfaceLevel.page.colorOf(Theme.of(context).colorScheme),
    appBar: AppBar(
      title: Text(title, style: AppTextStyle.pageTitle.of(context)),
      actions: actions,
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: child,
        ),
      ),
    ),
  );
}

class XcSection extends StatelessWidget {
  const XcSection({super.key, this.title, required this.children});
  final String? title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    shape: AppShape.xl.copyWith(side: BorderSide.none),
    color: SurfaceLevel.card.colorOf(Theme.of(context).colorScheme),
    elevation: 0,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          if (title != null)
            Text(title!, style: AppTextStyle.headline.of(context)),
          ...children,
        ],
      ),
    ),
  );
}

class XcValue extends StatelessWidget {
  const XcValue(this.label, this.value, {super.key});
  final String label;
  final Object? value;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Text(
          label,
          style: AppTextStyle.body
              .of(context)
              .copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ),
      const SizedBox(width: 16),
      Expanded(
        child: SelectableText(
          '${value ?? '—'}',
          textAlign: TextAlign.end,
          style: AppTextStyle.body.of(context),
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
  });
  final String label;
  final Future<void> Function() action;
  final bool tonal;
  final bool enabled;
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
  Widget build(BuildContext context) {
    final label = _busy
        ? Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 10,
            children: [
              const CommonCircleLoading(size: 16, semanticLabel: '处理中'),
              Text(widget.label),
            ],
          )
        : Text(widget.label);
    return widget.tonal
        ? FilledButton.tonal(
            onPressed: widget.enabled && !_busy ? _run : null,
            child: label,
          )
        : FilledButton(
            onPressed: widget.enabled && !_busy ? _run : null,
            child: label,
          );
  }
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
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: 16,
              children: [
                Text(xcErrorText(snapshot.error!)),
                FilledButton.tonal(
                  onPressed: _refresh,
                  child: const Text('重试'),
                ),
              ],
            ),
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
              Padding(
                padding: const EdgeInsets.all(40),
                child: Center(child: Text(widget.emptyText)),
              ),
              Center(
                child: TextButton(onPressed: _refresh, child: const Text('刷新')),
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

Widget xcList(List<Widget> children) => ListView(
  padding: const EdgeInsets.all(20),
  physics: const AlwaysScrollableScrollPhysics(),
  children: children,
);

class XcMenuRow extends StatelessWidget {
  const XcMenuRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.onTap,
  });
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    trailing: const GlyphIcon(AppGlyphs.chevronForward),
    onTap: onTap,
  );
}

class XcToggleTile extends StatefulWidget {
  const XcToggleTile({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });
  final String label;
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
  Widget build(BuildContext context) => ListTile(
    title: Text(widget.label),
    trailing: CommonSwitch(
      value: widget.value,
      semanticLabel: widget.label,
      onChanged: _busy ? null : _change,
    ),
  );
}
