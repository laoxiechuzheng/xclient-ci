import 'dart:io';
import 'dart:typed_data';

/// A minimal RGBA8 PNG encoder, enough for placeholder brand icons without a
/// new image dependency.
Uint8List encodePng(int width, int height, Uint8List rgba) {
  if (rgba.length != width * height * 4) {
    throw ArgumentError('expected ${width * height * 4} bytes of RGBA');
  }
  final raw = BytesBuilder(copy: false);
  for (var y = 0; y < height; y++) {
    raw.addByte(0);
    raw.add(Uint8List.sublistView(rgba, y * width * 4, (y + 1) * width * 4));
  }
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6)
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);
  final out = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(_chunk('IHDR', header.buffer.asUint8List()))
    ..add(_chunk('IDAT', ZLibCodec(level: 9).encode(raw.toBytes())))
    ..add(_chunk('IEND', Uint8List(0)));
  return out.toBytes();
}

Uint8List _chunk(String type, List<int> data) {
  final typeBytes = type.codeUnits;
  final crcInput = Uint8List(typeBytes.length + data.length)
    ..setAll(0, typeBytes)
    ..setAll(typeBytes.length, data);
  final chunk = ByteData(12 + data.length)..setUint32(0, data.length);
  final bytes = chunk.buffer.asUint8List()
    ..setAll(4, typeBytes)
    ..setAll(8, data);
  chunk.setUint32(8 + data.length, _crc32(crcInput));
  return bytes;
}

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xFF] ^ (crc >> 8);
  }
  return crc ^ 0xFFFFFFFF;
}

enum IconShape { square, rounded, circle }

/// Draws the placeholder brand mark: a filled [shape] in [background] with a
/// white "X", sampled 4x per axis for smooth edges.
Uint8List renderPlaceholderIcon(
  int size, {
  required int background,
  IconShape shape = IconShape.rounded,
  double margin = 0,
}) {
  const samples = 4;
  final rgba = Uint8List(size * size * 4);
  final bgR = (background >> 16) & 0xFF;
  final bgG = (background >> 8) & 0xFF;
  final bgB = background & 0xFF;
  final inset = size * margin;
  final extent = size - inset * 2;
  final radius = extent * 0.22;
  final stroke = extent * 0.11;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      var cover = 0;
      var mark = 0;
      for (var sy = 0; sy < samples; sy++) {
        for (var sx = 0; sx < samples; sx++) {
          final px = x + (sx + 0.5) / samples - inset;
          final py = y + (sy + 0.5) / samples - inset;
          if (!_inside(px, py, extent, radius, shape)) continue;
          cover++;
          // Normalised to 0..1 inside the shape.
          final u = px / extent;
          final v = py / extent;
          final inBox = u > 0.28 && u < 0.72 && v > 0.28 && v < 0.72;
          final onDiagonal =
              (u - v).abs() * extent < stroke * 0.71 ||
              (u + v - 1).abs() * extent < stroke * 0.71;
          if (inBox && onDiagonal) mark++;
        }
      }
      const total = samples * samples;
      final i = (y * size + x) * 4;
      final alpha = cover / total;
      final white = cover == 0 ? 0.0 : mark / cover;
      rgba[i] = (bgR + (255 - bgR) * white).round();
      rgba[i + 1] = (bgG + (255 - bgG) * white).round();
      rgba[i + 2] = (bgB + (255 - bgB) * white).round();
      rgba[i + 3] = (alpha * 255).round();
    }
  }
  return encodePng(size, size, rgba);
}

bool _inside(double x, double y, double extent, double radius, IconShape s) {
  if (x < 0 || y < 0 || x > extent || y > extent) return false;
  switch (s) {
    case IconShape.square:
      return true;
    case IconShape.circle:
      final c = extent / 2;
      return (x - c) * (x - c) + (y - c) * (y - c) <= c * c;
    case IconShape.rounded:
      final cx = x < radius
          ? radius
          : x > extent - radius
          ? extent - radius
          : x;
      final cy = y < radius
          ? radius
          : y > extent - radius
          ? extent - radius
          : y;
      return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius;
  }
}
