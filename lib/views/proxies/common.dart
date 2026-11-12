import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:flutter/widgets.dart';

const proxyGridSpacing = 8.0;

double get listHeaderHeight {
  final measure = globalState.measure;
  return 20 +
      measure.textHeight(AppTextStyle.callout) +
      2 +
      measure.textHeight(AppTextStyle.caption1) +
      2;
}

double getItemHeight(ProxyCardType proxyCardType) {
  final measure = globalState.measure;
  final baseHeight =
      16 +
      measure.textHeight(AppTextStyle.subheadline) * 2 +
      measure.textHeight(AppTextStyle.footnote) +
      8 +
      4;
  return switch (proxyCardType) {
    ProxyCardType.loose =>
      baseHeight + measure.textHeight(AppTextStyle.caption2) + 6,
    ProxyCardType.standard => baseHeight,
    ProxyCardType.compact =>
      baseHeight - measure.textHeight(AppTextStyle.subheadline),
  };
}

double getRowExtent(ProxyCardType proxyCardType) =>
    getItemHeight(proxyCardType) + proxyGridSpacing;

/// Lets the page around a [ProxiesView] draw its proxies its own way.
class ProxiesViewOverride extends InheritedWidget {
  const ProxiesViewOverride({
    super.key,
    required this.groupBody,
    required this.card,
    required this.selectedOffset,
    required super.child,
  });

  final Widget Function(
    Group group,
    ScrollController controller,
    int columns,
    ProxyCardType cardType,
  )
  groupBody;

  final Widget Function(
    String groupName,
    GroupType groupType,
    Proxy proxy,
    String? testUrl,
    ProxyCardType cardType,
  )
  card;

  final double? Function(Group group, String? selectedProxyName, int columns)
  selectedOffset;

  static ProxiesViewOverride? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ProxiesViewOverride>();

  @override
  bool updateShouldNotify(ProxiesViewOverride oldWidget) => false;
}

class GroupOffsets {
  const GroupOffsets(this.groups, this.offsets);

  static const empty = GroupOffsets(<Group>[], <double>[]);

  final List<Group> groups;
  final List<double> offsets;

  bool get isEmpty => offsets.isEmpty;

  double offsetOf(String groupName) {
    final index = groups.indexWhere((group) => group.name == groupName);
    if (index < 0 || index >= offsets.length) {
      return 0;
    }
    return offsets[index];
  }
}

double? selectedRowOffset({
  required List<Proxy> proxies,
  required String? selectedProxyName,
  required int columns,
  required double rowExtent,
}) {
  final index = proxies.indexWhere((proxy) => proxy.name == selectedProxyName);
  if (index < 0) {
    return null;
  }
  return (index ~/ columns) * rowExtent;
}

void animateScrollTo(ScrollController controller, double offset) {
  if (!controller.hasClients) {
    return;
  }
  final position = controller.position;
  controller.animateTo(
    offset.clamp(position.minScrollExtent, position.maxScrollExtent),
    duration: const Duration(milliseconds: 300),
    curve: Curves.easeOutCubic,
  );
}
