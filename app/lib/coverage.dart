import 'dart:math' as math;
import 'dart:typed_data';

import 'models.dart';

/// Raster pokrycia obszaru (piksel ≈ [scale] m), z którego liczymy
/// procent przeszukania każdego kwadratu siatki.
class Coverage {
  final Area area;
  final int rows, cols;
  late final double scale, _mLon;
  late final int w, h;
  late final Uint8List _px;
  late final Int32List _cellOfPixelCol, _cellOfPixelRow, cellFilled, cellTotal;
  int filled = 0;
  final Map<int, TrackPoint> _last = {};

  Coverage(this.area, this.rows, this.cols) {
    _mLon = mPerDegLon(area.midLat);
    scale = math.max(1.0, math.max(area.widthM, area.heightM) / 1000);
    w = math.max(1, (area.widthM / scale).ceil());
    h = math.max(1, (area.heightM / scale).ceil());
    _px = Uint8List(w * h);
    _cellOfPixelCol = Int32List.fromList(List.generate(w, (x) => math.min(x * cols ~/ w, cols - 1)));
    _cellOfPixelRow = Int32List.fromList(List.generate(h, (y) => math.min(y * rows ~/ h, rows - 1)));
    cellFilled = Int32List(rows * cols);
    cellTotal = Int32List(rows * cols);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        cellTotal[_cellOfPixelRow[y] * cols + _cellOfPixelCol[x]]++;
      }
    }
  }

  void add(TrackPoint p) {
    final prev = _last[p.user];
    final from = prev != null && p.continues(prev) ? prev : p;
    _capsule(_x(from.lon), _y(from.lat), _x(p.lon), _y(p.lat), p.r / scale);
    _last[p.user] = p;
  }

  double _x(double lon) => (lon - area.west) * _mLon / scale;
  double _y(double lat) => (area.north - lat) * mPerDegLat / scale;

  /// Zamalowuje wszystkie piksele w odległości [r] od odcinka a–b.
  void _capsule(double ax, double ay, double bx, double by, double r) {
    final x0 = math.max(0, (math.min(ax, bx) - r).floor());
    final x1 = math.min(w - 1, (math.max(ax, bx) + r).ceil());
    final y0 = math.max(0, (math.min(ay, by) - r).floor());
    final y1 = math.min(h - 1, (math.max(ay, by) + r).ceil());
    if (x0 > x1 || y0 > y1) return;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    final r2 = r * r;
    for (var y = y0; y <= y1; y++) {
      final py = y + 0.5;
      for (var x = x0; x <= x1; x++) {
        final i = y * w + x;
        if (_px[i] != 0) continue;
        final px = x + 0.5;
        final t = len2 == 0 ? 0.0 : math.max(0.0, math.min(1.0, ((px - ax) * dx + (py - ay) * dy) / len2));
        final ex = ax + t * dx - px, ey = ay + t * dy - py;
        if (ex * ex + ey * ey <= r2) {
          _px[i] = 1;
          filled++;
          cellFilled[_cellOfPixelRow[y] * cols + _cellOfPixelCol[x]]++;
        }
      }
    }
  }

  double cellPercent(int row, int col) {
    final i = row * cols + col;
    return cellTotal[i] == 0 ? 0 : 100 * cellFilled[i] / cellTotal[i];
  }

  double get totalPercent => 100 * filled / (w * h);
}
