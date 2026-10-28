import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;

import '../models.dart';
import 'tile_store.dart';

/// Kafelki z serwera GeoFinder (który sam je przechowuje), zapisywane też
/// w pamięci telefonu – mapa działa, nawet gdy nie ma połączenia z serwerem.
class TileCache {
  static const minZoom = 12, maxZoom = 18;

  static Uri url(String base, int z, int x, int y) => Uri.parse('$base/tiles/$z/$x/$y.png');

  /// Najpierw pamięć telefonu, potem serwer.
  static Future<Uint8List?> get(String base, int z, int x, int y) async {
    final local = await TileStore.read(z, x, y);
    if (local != null) return local;
    return _download(base, z, x, y);
  }

  static Future<Uint8List?> _download(String base, int z, int x, int y) async {
    try {
      final r = await http.get(url(base, z, x, y)).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return null;
      await TileStore.write(z, x, y, r.bodyBytes);
      return r.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  /// Wszystkie kafelki obszaru akcji w zakresie przybliżeń do pracy offline.
  static List<(int, int, int)> tilesFor(Area a) {
    int tx(double lon, int z) => ((lon + 180) / 360 * (1 << z)).floor();
    int ty(double lat, int z) {
      final r = lat * math.pi / 180;
      return ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * (1 << z)).floor();
    }

    return [
      for (var z = minZoom; z <= maxZoom; z++)
        for (var x = tx(a.west, z); x <= tx(a.east, z); x++)
          for (var y = ty(a.north, z); y <= ty(a.south, z); y++) (z, x, y),
    ];
  }

  /// Ściąga brakujące kafelki do telefonu. [onProgress] dostaje (zrobione, wszystkie).
  static Future<int> prefetch(String base, Area a, void Function(int, int) onProgress,
      {bool Function()? cancelled}) async {
    final tiles = tilesFor(a);
    var done = 0, failed = 0;
    // 4 pobrania równolegle
    final queue = tiles.iterator;
    Future<void> worker() async {
      while (!(cancelled?.call() ?? false)) {
        if (!queue.moveNext()) return;
        final t = queue.current;
        if (!await TileStore.exists(t.$1, t.$2, t.$3) && await _download(base, t.$1, t.$2, t.$3) == null) {
          failed++;
        }
        onProgress(++done, tiles.length);
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    return failed;
  }
}

class CachedTileProvider extends TileProvider {
  final String base;
  CachedTileProvider(this.base);

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    if (!TileStore.supported) return NetworkImage(TileCache.url(base, coordinates.z, coordinates.x, coordinates.y).toString());
    return _TileImage(base, coordinates.z, coordinates.x, coordinates.y);
  }
}

class _TileImage extends ImageProvider<_TileImage> {
  final String base;
  final int z, x, y;
  const _TileImage(this.base, this.z, this.x, this.y);

  @override
  Future<_TileImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_TileImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await TileCache.get(base, z, x, y);
    if (bytes == null) throw StateError('Brak kafelka $z/$x/$y offline');
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is _TileImage && other.base == base && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(base, z, x, y);
}
