import 'package:fl_clash/widgets/config_item.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'probe_runtime.dart';

class XcProbeSettingsTile extends StatelessWidget {
  const XcProbeSettingsTile({super.key});

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ConfigToggleItem(
        selector: xcProbeSettingsProvider.select(
          (settings) => settings.enabled,
        ),
        title: (_) => '自动地区故障转移',
        onChanged: (ref, value) =>
            ref.read(xcProbeSettingsProvider.notifier).update(enabled: value),
      ),
      ConfigToggleItem(
        selector: xcProbeSettingsProvider.select(
          (settings) => settings.allowCrossRegion,
        ),
        title: (_) => '允许跨地区故障转移',
        onChanged: (ref, value) => ref
            .read(xcProbeSettingsProvider.notifier)
            .update(allowCrossRegion: value),
      ),
    ],
  );
}
