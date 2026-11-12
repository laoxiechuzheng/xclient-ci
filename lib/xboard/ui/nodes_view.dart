import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/context.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/loading.dart';
import 'package:fl_clash/ui/scroll.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/text.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/views/proxies/card.dart' show selectGroupProxy;
import 'package:fl_clash/views/proxies/common.dart';
import 'package:fl_clash/views/proxies/proxies.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../probe/display_delay.dart';
import '../probe/region_classifier.dart';
import 'common/motion.dart';
import 'common/tokens.dart';

/// The branded nodes tab: the upstream proxies view, with its proxies drawn
/// as plain cards a beginner can read and grouped by region.
class XcNodesView extends StatefulWidget {
  const XcNodesView({super.key});

  @override
  State<XcNodesView> createState() => _XcNodesViewState();
}

class _XcNodesViewState extends State<XcNodesView> {
  final _layout = _XcNodeLayout();

  @override
  Widget build(BuildContext context) => ProxiesViewOverride(
    groupBody: (group, controller, columns, cardType) =>
        _XcNodeGroup(group: group, controller: controller, layout: _layout),
    card: (groupName, groupType, proxy, testUrl, _) => XcNodeCard(
      groupName: groupName,
      groupType: groupType,
      proxy: proxy,
      testUrl: testUrl,
    ),
    selectedOffset: (group, selected, _) => _layout.offsetOf(group, selected),
    child: const ProxiesView(title: '节点'),
  );
}

class _XcNodeSection {
  const _XcNodeSection({
    required this.title,
    required this.proxies,
    this.code,
    this.smart = false,
  });

  final String title;
  final String? code;
  final bool smart;
  final List<Proxy> proxies;

  static List<_XcNodeSection> of(List<Proxy> proxies) {
    final smart = <Proxy>[];
    final regions = <String, List<Proxy>>{};
    final other = <Proxy>[];
    for (final proxy in proxies) {
      if (GroupTypeExtension.getGroupType(proxy.type) != null) {
        smart.add(proxy);
      } else if (classifyRegion(proxy.name) case final code?) {
        regions.putIfAbsent(code, () => []).add(proxy);
      } else {
        other.add(proxy);
      }
    }
    return [
      if (smart.isNotEmpty)
        _XcNodeSection(title: '智能线路', proxies: smart, smart: true),
      for (final MapEntry(key: code, value: list) in regions.entries)
        _XcNodeSection(
          title: regionName(code) ?? code,
          code: code,
          proxies: list,
        ),
      if (other.isNotEmpty) _XcNodeSection(title: '其他线路', proxies: other),
    ];
  }
}

/// The geometry [_XcNodeGroup] last laid out, so the bar's locate button
/// can find the selected card.
class _XcNodeLayout {
  static const top = XcSpace.xxs;
  static const header = 44.0;
  static const gap = XcSpace.sm;
  static const spacing = 10.0;

  int columns = 1;
  double cardExtent = 72;

  static int columnsFor(double width) =>
      width < 600 ? 1 : (width / 380).floor().clamp(2, 4);

  static double extentFor(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return 30 + scaler.scale(22) + scaler.scale(18) < 72
        ? 72
        : 30 + scaler.scale(22) + scaler.scale(18);
  }

  double? offsetOf(Group group, String? selected) {
    final sections = _XcNodeSection.of(group.all);
    final headed = sections.length > 1;
    final row = cardExtent + spacing;
    var offset = top;
    for (final section in sections) {
      if (headed) offset += header;
      final index = section.proxies.indexWhere((p) => p.name == selected);
      if (index >= 0) return offset + (index ~/ columns) * row;
      offset += (section.proxies.length / columns).ceil() * row + gap;
    }
    return null;
  }
}

class _XcNodeGroup extends StatelessWidget {
  const _XcNodeGroup({
    required this.group,
    required this.controller,
    required this.layout,
  });

  final Group group;
  final ScrollController controller;
  final _XcNodeLayout layout;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final sections = _XcNodeSection.of(group.all);
      final headed = sections.length > 1;
      final columns = _XcNodeLayout.columnsFor(constraints.maxWidth);
      final extent = _XcNodeLayout.extentFor(context);
      layout
        ..columns = columns
        ..cardExtent = extent;
      final gutter = XcSpace.gutterOf(MediaQuery.sizeOf(context).width);
      final starts = <int>[];
      var count = 0;
      for (final section in sections) {
        starts.add(count);
        count += section.proxies.length;
      }
      return CommonScrollBar(
        controller: controller,
        thumbVisibility: true,
        child: CustomScrollView(
          controller: controller,
          slivers: [
            const SliverToBoxAdapter(
              child: SizedBox(height: _XcNodeLayout.top),
            ),
            for (final (number, section) in sections.indexed) ...[
              if (headed)
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: _XcNodeLayout.header,
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: gutter + 4),
                      child: _SectionHeader(section: section),
                    ),
                  ),
                ),
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  gutter,
                  0,
                  gutter,
                  _XcNodeLayout.gap,
                ),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: _XcNodeLayout.spacing,
                    crossAxisSpacing: _XcNodeLayout.spacing,
                    mainAxisExtent: extent,
                  ),
                  itemCount: section.proxies.length,
                  itemBuilder: (context, index) => XcEntrance(
                    index: (starts[number] + index).clamp(0, 6),
                    offset: 8,
                    child: XcNodeCard(
                      groupName: group.name,
                      groupType: group.type,
                      proxy: section.proxies[index],
                      testUrl: group.testUrl,
                    ),
                  ),
                ),
              ),
            ],
            SliverToBoxAdapter(
              child: SizedBox(height: XcSpace.lg + context.bottomInset),
            ),
          ],
        ),
      );
    },
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.section});

  final _XcNodeSection section;

  @override
  Widget build(BuildContext context) => Row(
    spacing: XcSpace.xs,
    children: [
      Text(section.title, style: XcType.headline(context)),
      Text('${section.proxies.length} 个', style: XcType.caption(context)),
    ],
  );
}

/// One proxy as a beginner reads it: where it is, what it is called, how
/// fast it answered last, and whether it is the one in use.
class XcNodeCard extends ConsumerWidget {
  const XcNodeCard({
    super.key,
    required this.groupName,
    required this.groupType,
    required this.proxy,
    this.testUrl,
  });

  final String groupName;
  final GroupType groupType;
  final Proxy proxy;
  final String? testUrl;

  static String? _smartCaption(String type) =>
      switch (GroupTypeExtension.getGroupType(type)) {
        GroupType.URLTest => '自动选择延迟最低的线路',
        GroupType.Fallback => '当前线路故障时自动切换',
        GroupType.LoadBalance => '多条线路分担流量',
        null => null,
        _ => '一组可选线路',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = XcColors.of(context);
    final inUse = ref.watch(
      selectedProxyNameProvider(groupName).select((name) => name == proxy.name),
    );
    final pinned =
        groupType.isComputedSelected &&
        ref.watch(
          proxyNameProvider(groupName).select((name) => name == proxy.name),
        );
    final smart = _smartCaption(proxy.type);
    final code = smart == null ? classifyRegion(proxy.name) : null;
    final caption = smart ?? (code == null ? '其他地区' : regionName(code) ?? code);
    final status = inUse ? '，正在使用' : '';
    return Semantics(
      button: true,
      selected: inUse,
      label: '${proxy.name}，$caption$status',
      child: AnimatedContainer(
        duration: XcMotion.of(context, XcMotion.standard),
        curve: XcMotion.standardCurve,
        decoration: ShapeDecoration(
          color: inUse ? colors.accentSoft : colors.card,
          shape: XcRadius.tile.copyWith(
            side: BorderSide(
              color: inUse ? colors.accent : colors.hairline,
              width: inUse ? 1.5 : 1,
            ),
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: XcRadius.tile,
            onTap: () => selectGroupProxy(
              ref,
              groupName: groupName,
              groupType: groupType,
              proxyName: proxy.name,
            ),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final mark = _RegionMark(code: code, smart: smart != null);
                final badge = _DelayBadge(proxy: proxy, testUrl: testUrl);
                final check = inUse || pinned
                    ? GlyphIcon(
                        pinned ? AppGlyphs.pin : AppGlyphs.checkCircle,
                        size: 20,
                        fill: 1,
                        color: colors.accent,
                      )
                    : null;
                final name = EmojiText(
                  proxy.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.callout
                      .of(context, emphasized: inUse)
                      .copyWith(color: colors.title),
                );
                if (constraints.maxWidth < 240) {
                  return Padding(
                    padding: const EdgeInsets.all(XcSpace.sm),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      spacing: 6,
                      children: [
                        Row(
                          spacing: XcSpace.xs,
                          children: [
                            mark,
                            Expanded(
                              child: Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: badge,
                              ),
                            ),
                            ?check,
                          ],
                        ),
                        name,
                      ],
                    ),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: XcSpace.md,
                    vertical: XcSpace.sm,
                  ),
                  child: Row(
                    spacing: XcSpace.sm,
                    children: [
                      mark,
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          spacing: 2,
                          children: [
                            name,
                            Text(
                              caption,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: XcType.caption(context),
                            ),
                          ],
                        ),
                      ),
                      badge,
                      ?check,
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _RegionMark extends StatelessWidget {
  const _RegionMark({required this.code, required this.smart});

  final String? code;
  final bool smart;

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: smart ? colors.accent : colors.softOf(XcTone.accent),
        shape: XcRadius.control.copyWith(borderRadius: AppRadius.sm),
      ),
      child: SizedBox.square(
        dimension: 36,
        child: Center(
          child: code != null
              ? Text(
                  code!,
                  style: AppTextStyle.footnote
                      .of(context, emphasized: true)
                      .copyWith(color: colors.accent, letterSpacing: 0.4),
                )
              : GlyphIcon(
                  smart ? AppGlyphs.bolt : AppGlyphs.proxies,
                  size: 18,
                  fill: 1,
                  color: smart ? colors.onAccent : colors.accent,
                ),
        ),
      ),
    );
  }
}

/// The last delay this node answered with. No result yet stays neutral: the
/// card never starts a test by itself.
class _DelayBadge extends ConsumerWidget {
  const _DelayBadge({required this.proxy, this.testUrl});

  final Proxy proxy;
  final String? testUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = XcColors.of(context);
    final delay = ref.watch(
      delayProvider(proxyName: proxy.name, testUrl: testUrl),
    );
    final phase = ref.watch(
      delayTestPhaseProvider(proxyName: proxy.name, testUrl: testUrl),
    );
    final shown = displayDelayText(delay);
    final (label, tone) = switch (delay) {
      _ when phase != null => ('检测中', XcTone.neutral),
      _ when shown == null => ('未测速', XcTone.neutral),
      final raw? when raw < 0 => (shown, XcTone.danger),
      final raw? when displayDelay(raw) <= 60 => (shown, XcTone.success),
      _ => (shown, XcTone.warning),
    };
    final color = tone == XcTone.neutral ? colors.muted : colors.toneOf(tone);
    return Tooltip(
      message: '获取最新延迟',
      child: InkWell(
        customBorder: XcRadius.pill,
        onTap: () => ref
            .read(proxiesActionProvider.notifier)
            .proxyDelayTest(proxy, testUrl),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: colors.softOf(tone),
            shape: XcRadius.pill,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: XcSwap(
              value: label,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  if (phase != null)
                    CommonCircleLoading(size: 10, color: color)
                  else
                    DecoratedBox(
                      decoration: ShapeDecoration(
                        color: color,
                        shape: const CircleBorder(),
                      ),
                      child: const SizedBox.square(dimension: 6),
                    ),
                  Text(
                    label,
                    style: AppTextStyle.caption1
                        .of(context, emphasized: true)
                        .copyWith(
                          color: color,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
