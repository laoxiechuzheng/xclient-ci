import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';

import 'probe_scheduler.dart';
import 'region_failover.dart';

typedef ProbeRouteHop = ({String group, String name});

class ProbeRoutes {
  ProbeRoutes({
    required List<Group> groups,
    required this.selected,
    required this.targets,
  }) : groups = {for (final group in groups) group.name: group};

  final Map<String, Group> groups;
  final Map<String, String> selected;
  final Map<String, ProbeTarget> targets;

  List<ProbeRouteHop>? pathTo(
    String groupName,
    String nodeName, [
    Set<String> seen = const {},
  ]) {
    if (seen.contains(groupName)) return null;
    final group = groups[groupName];
    if (group == null ||
        (group.type != GroupType.Selector && !group.type.isComputedSelected)) {
      return null;
    }
    for (final proxy in group.all) {
      if (proxy.name == nodeName) return [(group: groupName, name: nodeName)];
      if (groups.containsKey(proxy.name)) {
        final nested = pathTo(proxy.name, nodeName, {...seen, groupName});
        if (nested != null) {
          return [(group: groupName, name: proxy.name), ...nested];
        }
      }
    }
    return null;
  }

  List<FailoverSelection> selections() {
    final results = <FailoverSelection>[];
    for (final root in groups.values) {
      if (root.type != GroupType.Selector && !root.type.isComputedSelected) {
        continue;
      }
      var group = root;
      String? leaf;
      final seen = <String>{};
      while (seen.add(group.name)) {
        final name = group.getCurrentSelectedName(selected[group.name] ?? '');
        final nested = groups[name];
        if (nested == null) {
          leaf = name;
          break;
        }
        group = nested;
      }
      final target = targets[leaf];
      if (target == null) continue;
      final candidates = <ProbeTarget>{};
      final visited = <String>{};
      void collect(Group group) {
        if (!visited.add(group.name) ||
            (group.type != GroupType.Selector &&
                !group.type.isComputedSelected)) {
          return;
        }
        for (final proxy in group.all) {
          final nested = groups[proxy.name];
          if (nested != null) {
            collect(nested);
          } else if (targets[proxy.name] case final candidate?) {
            candidates.add(candidate);
          }
        }
      }

      collect(root);
      results.add(
        FailoverSelection(
          group: root.name,
          target: target,
          candidates: candidates.toList(),
        ),
      );
    }
    return results;
  }
}
