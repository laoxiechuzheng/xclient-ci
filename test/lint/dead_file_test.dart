import 'dart:io';

import 'package:test/test.dart';

const _entryPoints = ['lib/main.dart'];

/// Types, and the top level names a file publishes alongside them — the
/// `final appPath = AppPath()` singleton pattern is how most of `lib/common`
/// is actually consumed.
final _declaration = RegExp(
  r'^(?:abstract |sealed |final |base |mixin )*'
  r'(?:(?:class|enum|mixin)\s+([A-Za-z]\w*)'
  r'|(?:final|const)\s+(?:[\w<>,\s\[\]?]+\s+)?([a-z]\w*)\s*=)',
  multiLine: true,
);

final _functionDeclaration = RegExp(
  r'^(?:external\s+)?[A-Za-z]\w*(?:<[^;\n=]+>)?\??\s+'
  r'([a-z]\w*)\s*(?:<[^;\n=]+>)?\s*\(',
  multiLine: true,
);

Set<String> _publishedNames(String source) => {
  for (final match in _declaration.allMatches(source))
    match.group(1) ?? match.group(2)!,
  for (final match in _functionDeclaration.allMatches(source)) match.group(1)!,
};

bool _hasConsumer(
  String path,
  Set<String> names,
  Map<String, String> consumers,
  Set<String> barrels,
) {
  return consumers.entries.any((entry) {
    if (entry.key == path || barrels.contains(entry.key)) return false;
    return names.any((name) => RegExp('\\b$name\\b').hasMatch(entry.value));
  });
}

Iterable<File> _dartFiles({required bool includeGenerated}) sync* {
  for (final root in ['lib', 'test', 'tool', 'plugins']) {
    final directory = Directory(root);
    if (!directory.existsSync()) {
      fail('$root no longer exists; update this test.');
    }
    for (final entity in directory.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll('\\', '/');
      final generated =
          path.endsWith('.g.dart') ||
          path.endsWith('.freezed.dart') ||
          path.contains('/generated/');
      if (generated && !includeGenerated) continue;
      yield entity;
    }
  }
}

bool _isBarrel(String source) {
  final lines = source
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('//'));
  return lines.isNotEmpty &&
      lines.every(
        (line) => line.startsWith('export ') || line.startsWith('import '),
      );
}

void main() {
  test('top-level functions count as consumed declarations', () {
    const source = '''
const defaultType = 16;
class Message {}
Message decodeMessage(List<int> bytes) => Message();
Future<List<int>> encodeQuery<T>(T name) async => [];
''';
    expect(_publishedNames(source), {
      'defaultType',
      'Message',
      'decodeMessage',
      'encodeQuery',
    });
    expect(
      _hasConsumer('lib/codec.dart', _publishedNames(source), {
        'lib/codec.dart': source,
        'lib/client.dart': 'final message = decodeMessage(bytes);',
      }, {}),
      isTrue,
    );
  });

  test('an unused function or only a barrel export is still dead', () {
    const source = 'void encodeQuery() {}';
    expect(
      _hasConsumer(
        'lib/codec.dart',
        _publishedNames(source),
        {
          'lib/codec.dart': source,
          'lib/net.dart': "export 'codec.dart'; // encodeQuery",
          'lib/client.dart': "final name = 'encodeQueryExtra';",
        },
        {'lib/net.dart'},
      ),
      isFalse,
    );
  });

  test('every file under lib declares something used outside itself', () {
    // Generated code counts as a consumer but never as a declarer: a riverpod
    // notifier is reached through the provider its annotation generates.
    final consumers = {
      for (final file in _dartFiles(includeGenerated: true))
        file.path.replaceAll('\\', '/'): file.readAsStringSync(),
    };
    final sources = {
      for (final file in _dartFiles(includeGenerated: false))
        file.path.replaceAll('\\', '/'):
            consumers[file.path.replaceAll('\\', '/')]!,
    };
    final barrels = {
      for (final MapEntry(key: path, value: source) in sources.entries)
        if (_isBarrel(source)) path,
    };

    final orphans = <String>[];

    for (final MapEntry(key: path, value: source) in sources.entries) {
      if (!path.startsWith('lib/')) continue;
      if (barrels.contains(path) || _entryPoints.contains(path)) continue;
      if (path.startsWith('lib/l10n/')) continue;

      // Extensions and typedefs are reached through the types they attach to,
      // never by name, so a file that publishes only those cannot be measured
      // this way.
      final names = _publishedNames(source);
      if (names.isEmpty) continue;

      final used = _hasConsumer(path, names, consumers, barrels);

      if (!used) {
        orphans.add(
          '$path — publishes ${names.join(', ')}, none of which is referenced '
          'anywhere else. A barrel export keeps it compiling; it is still dead.',
        );
      }
    }

    expect(orphans, isEmpty, reason: orphans.join('\n'));
  });
}
