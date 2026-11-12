import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../ui/common/tokens.dart';
import '../ui/common/widgets.dart';
import 'probe_runtime.dart';

class XcProbeSettingsTile extends ConsumerWidget {
  const XcProbeSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(xcProbeSettingsProvider);
    final notifier = ref.read(xcProbeSettingsProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: XcSpace.xxs,
      children: [
        XcToggleRow(
          label: '自动地区故障转移',
          subtitle: '当前线路不可用时，自动换到同地区的可用线路',
          value: settings.enabled,
          onChanged: (value) => notifier.update(enabled: value),
        ),
        XcToggleRow(
          label: '允许跨地区故障转移',
          subtitle: '同地区都不可用时，允许换到其他地区',
          value: settings.allowCrossRegion,
          onChanged: (value) => notifier.update(allowCrossRegion: value),
        ),
      ],
    );
  }
}
