import 'dart:io';

import 'package:path/path.dart' as p;

import '../src/icons/ico.dart';
import 'src/png.dart';

const _usage = '''
Writes a placeholder icon overlay (a coloured tile with a white "X") in the
layout brand_apply copies onto the tree.

usage: dart tool/xclient/gen_placeholder_icons.dart <overlay-dir> [RRGGBB]

Real brands keep hand-made icons in the same layout in the private brand
repository; this only seeds brands/example and new brands.''';

const _androidDensities = {
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

const _macosSizes = [16, 32, 64, 128, 256, 512, 1024];

const _res = 'android/app/src/main/res';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.length > 2 || arguments.first == '-h') {
    stdout.writeln(_usage);
    exit(arguments.isEmpty ? 64 : 0);
  }
  final out = arguments.first;
  final colorText = arguments.length > 1 ? arguments[1] : '3F6FD8';
  if (!RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(colorText)) {
    stderr.writeln('colour must be RRGGBB, got "$colorText"');
    exit(64);
  }
  final color = int.parse(colorText, radix: 16);
  final written = writePlaceholderOverlay(out, color);
  for (final path in written) {
    stdout.writeln(path);
  }
}

List<String> writePlaceholderOverlay(String out, int color) {
  final written = <String>[];
  void write(String relative, List<int> bytes) {
    final file = File(p.join(out, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    written.add(relative);
  }

  final hex = color.toRadixString(16).padLeft(6, '0').toUpperCase();

  for (final MapEntry(key: density, value: size) in _androidDensities.entries) {
    write(
      '$_res/mipmap-$density/ic_launcher.png',
      renderPlaceholderIcon(size, background: color, margin: 0.04),
    );
    write(
      '$_res/mipmap-$density/ic_launcher_round.png',
      renderPlaceholderIcon(
        size,
        background: color,
        shape: IconShape.circle,
        margin: 0.04,
      ),
    );
  }
  // The adaptive icon (mipmap-anydpi-v26) draws this over the background
  // colour below; the 108dp canvas keeps the mark inside the 66dp safe zone.
  write(
    '$_res/drawable/ic_launcher_foreground.xml',
    '''
<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:pathData="M40,40 L68,68 M68,40 L40,68"
        android:strokeWidth="7"
        android:strokeColor="#FFFFFF"
        android:strokeLineCap="round" />
</vector>
'''
        .codeUnits,
  );
  write(
    '$_res/values/ic_launcher_background.xml',
    '''
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#$hex</color>
</resources>
'''
        .codeUnits,
  );

  write(
    'windows/runner/resources/app_icon.ico',
    buildIco([
      for (final size in icoSizes)
        IcoEntry(
          size: size,
          png: renderPlaceholderIcon(size, background: color, margin: 0.04),
        ),
    ]),
  );

  for (final size in _macosSizes) {
    write(
      'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_$size.png',
      renderPlaceholderIcon(size, background: color, margin: 0.1),
    );
  }

  write(
    'assets/images/icon.png',
    renderPlaceholderIcon(512, background: color),
  );
  return written;
}
