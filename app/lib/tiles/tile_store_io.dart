import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class TileStore {
  static const bool supported = true;
  static Future<Directory>? _dir;

  static Future<File> _file(int z, int x, int y) async {
    final dir = await (_dir ??= getApplicationSupportDirectory().then((d) => Directory('${d.path}/tiles')));
    return File('${dir.path}/$z/$x/$y.png');
  }

  static Future<Uint8List?> read(int z, int x, int y) async {
    final f = await _file(z, x, y);
    return await f.exists() ? f.readAsBytes() : null;
  }

  static Future<bool> exists(int z, int x, int y) async => (await _file(z, x, y)).exists();

  static Future<void> write(int z, int x, int y, Uint8List bytes) async {
    final f = await _file(z, x, y);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: false);
  }
}
