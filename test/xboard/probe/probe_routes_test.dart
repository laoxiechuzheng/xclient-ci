import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/xboard/probe/probe_routes.dart';
import 'package:fl_clash/xboard/probe/probe_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

Group _group(String name, List<String> children, {String? now}) => Group(
  name: name,
  type: GroupType.Selector,
  now: now,
  all: [for (final child in children) Proxy(name: child, type: 'ss')],
);

void main() {
  test(
    'nested main-group selections expose all reachable nodes and a valid switch path',
    () {
      final routes = ProbeRoutes(
        groups: [
          _group('Main', ['Japan', 'America']),
          _group('Japan', ['JP-1', 'JP-2']),
          _group('America', ['US-1']),
        ],
        selected: {'Main': 'Japan', 'Japan': 'JP-1', 'America': 'US-1'},
        targets: {
          for (final name in ['JP-1', 'JP-2', 'US-1'])
            name: ProbeTarget(
              name: name,
              identity: name,
              url: 'https://test.example',
            ),
        },
      );
      final main = routes.selections().firstWhere(
        (selection) => selection.group == 'Main',
      );
      expect(main.target.name, 'JP-1');
      expect(main.candidates.map((target) => target.name), [
        'JP-1',
        'JP-2',
        'US-1',
      ]);
      expect(routes.pathTo('Main', 'JP-2'), [
        (group: 'Main', name: 'Japan'),
        (group: 'Japan', name: 'JP-2'),
      ]);
      expect(routes.pathTo('Japan', 'US-1'), isNull);
    },
  );

  test('group cycles terminate and a direct node remains selectable', () {
    final routes = ProbeRoutes(
      groups: [
        _group('A', ['B', 'JP-1']),
        _group('B', ['A']),
      ],
      selected: {'A': 'B', 'B': 'A'},
      targets: {
        'JP-1': const ProbeTarget(
          name: 'JP-1',
          identity: 'a',
          url: 'https://test.example',
        ),
      },
    );
    expect(routes.selections(), isEmpty);
    expect(routes.pathTo('A', 'JP-1'), [(group: 'A', name: 'JP-1')]);
    expect(routes.pathTo('A', 'US-1'), isNull);
  });

  test(
    'an automatic group follows the core current node and rejects unsupported load-balancing hops',
    () {
      const target = ProbeTarget(
        name: 'JP-1',
        identity: 'a',
        url: 'https://test.example',
      );
      final routes = ProbeRoutes(
        groups: [
          const Group(
            name: 'Auto',
            type: GroupType.URLTest,
            now: 'JP-1',
            all: [Proxy(name: 'JP-1', type: 'ss')],
          ),
          const Group(
            name: 'Balanced',
            type: GroupType.LoadBalance,
            all: [Proxy(name: 'JP-1', type: 'ss')],
          ),
        ],
        selected: {'Auto': 'JP-2'},
        targets: {'JP-1': target},
      );
      expect(routes.selections().single.target, target);
      expect(routes.pathTo('Balanced', 'JP-1'), isNull);
    },
  );
}
