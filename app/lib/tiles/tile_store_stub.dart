import 'dart:typed_data';

class TileStore {
  static const bool supported = false;
  static Future<Uint8List?> read(int z, int x, int y) async => null;
  static Future<bool> exists(int z, int x, int y) async => false;
  static Future<void> write(int z, int x, int y, Uint8List bytes) async {}
}
