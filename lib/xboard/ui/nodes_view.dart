import 'package:fl_clash/views/proxies/proxies.dart';
import 'package:material_ui/material_ui.dart';

/// The branded nodes tab: the upstream proxies view in the XClient frame.
class XcNodesView extends StatelessWidget {
  const XcNodesView({super.key});

  @override
  Widget build(BuildContext context) => const ProxiesView(title: '节点');
}
