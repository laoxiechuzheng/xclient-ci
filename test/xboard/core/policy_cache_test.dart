import 'dart:io';

import 'package:fl_clash/xboard/core/sync/policy_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'policy cache serializes overlapping runtime writes and following reads',
    () async {
      final folder = await Directory.systemTemp.createTemp('xc-policy-cache-');
      addTearDown(() => folder.delete(recursive: true));
      final first = FilePolicyCache('${folder.path}/policy.json');
      final next = FilePolicyCache('${folder.path}/policy.json');
      final writes = [
        for (var i = 0; i < 12; i++)
          (i.isEven ? first : next).write('document-$i'),
      ];
      final read = next.read();
      await Future.wait(writes);
      expect(await read, 'document-11');
      expect(await first.read(), 'document-11');
      expect(await folder.list().length, 1);
    },
  );
}
