import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

const mPerDegLat = 111320.0;

/// Dwa kolejne punkty tej samej osoby łączymy w ślad, jeśli dzieli je
/// najwyżej tyle sekund i metrów. Dalej = przerwa (np. zgubiony sygnał).
const gapSeconds = 120.0;
const gapMeters = 60.0;

double mPerDegLon(double lat) => mPerDegLat * math.cos(lat * math.pi / 180);

double distanceM(double lat1, double lon1, double lat2, double lon2) {
  final dy = (lat2 - lat1) * mPerDegLat;
  final dx = (lon2 - lon1) * mPerDegLon((lat1 + lat2) / 2);
  return math.sqrt(dx * dx + dy * dy);
}

/// 0 -> A, 25 -> Z, 26 -> AA
String colLabel(int i) {
  var s = '';
  var n = i + 1;
  while (n > 0) {
    final r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

Color parseColor(String hex) =>
    Color(int.parse(hex.replaceFirst('#', ''), radix: 16) | 0xFF000000);

String colorToHex(Color c) =>
    '#${(c.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

double _d(dynamic v) => (v as num).toDouble();
double? _dn(dynamic v) => v == null ? null : (v as num).toDouble();

class Area {
  final double north, south, east, west;
  const Area({required this.north, required this.south, required this.east, required this.west});

  factory Area.fromJson(Map<String, dynamic> j) =>
      Area(north: _d(j['north']), south: _d(j['south']), east: _d(j['east']), west: _d(j['west']));

  Map<String, dynamic> toJson() => {'north': north, 'south': south, 'east': east, 'west': west};

  double get midLat => (north + south) / 2;
  double get widthM => (east - west) * mPerDegLon(midLat);
  double get heightM => (north - south) * mPerDegLat;
  LatLng get center => LatLng(midLat, (east + west) / 2);
  bool contains(double lat, double lon) => lat >= south && lat <= north && lon >= west && lon <= east;
}

class Settings {
  final String name;
  final Area? area;
  final int rows, cols;
  final LatLng? calib;
  final double defaultRadius, maxAccuracy;

  const Settings({
    this.name = 'GeoFinder',
    this.area,
    this.rows = 10,
    this.cols = 10,
    this.calib,
    this.defaultRadius = 10,
    this.maxAccuracy = 25,
  });

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        name: j['name'] as String? ?? 'GeoFinder',
        area: j['area'] == null ? null : Area.fromJson(j['area']),
        rows: j['rows'] as int,
        cols: j['cols'] as int,
        calib: j['calib'] == null ? null : LatLng(_d(j['calib']['lat']), _d(j['calib']['lon'])),
        defaultRadius: _d(j['default_radius']),
        maxAccuracy: _d(j['max_accuracy']),
      );

  /// Etykieta kwadratu (np. "B4") albo null, gdy punkt jest poza siatką.
  String? cellOf(double lat, double lon) {
    final a = area;
    if (a == null || !a.contains(lat, lon)) return null;
    final col = math.min(((lon - a.west) / (a.east - a.west) * cols).floor(), cols - 1);
    final row = math.min(((a.north - lat) / (a.north - a.south) * rows).floor(), rows - 1);
    return '${colLabel(col)}${row + 1}';
  }
}

class AppUser {
  final int id;
  final String name;
  final double radius;
  final Color color;
  final Map<String, dynamic>? calib;
  final double? lat, lon, acc, lastSeen;

  const AppUser({
    required this.id,
    required this.name,
    required this.radius,
    required this.color,
    this.calib,
    this.lat,
    this.lon,
    this.acc,
    this.lastSeen,
  });

  factory AppUser.fromJson(Map<String, dynamic> j) => AppUser(
        id: j['id'] as int,
        name: j['name'] as String,
        radius: _d(j['radius']),
        color: parseColor(j['color'] as String),
        calib: j['calib'] as Map<String, dynamic>?,
        lat: _dn(j['lat']),
        lon: _dn(j['lon']),
        acc: _dn(j['acc']),
        lastSeen: _dn(j['last_seen']),
      );

  AppUser withPosition(double lat, double lon, double acc, double lastSeen) => AppUser(
      id: id, name: name, radius: radius, color: color, calib: calib,
      lat: lat, lon: lon, acc: acc, lastSeen: lastSeen);

  /// Brak sygnału od ponad 2 minut.
  bool get stale => lastSeen == null || nowSeconds() - lastSeen! > 120;
}

class Report {
  final int id, user;
  final String userName, category, categoryLabel, text, message;
  final String? cell;
  final double lat, lon, t;

  const Report({
    required this.id,
    required this.user,
    required this.userName,
    required this.category,
    required this.categoryLabel,
    required this.text,
    required this.message,
    required this.cell,
    required this.lat,
    required this.lon,
    required this.t,
  });

  factory Report.fromJson(Map<String, dynamic> j) => Report(
        id: j['id'] as int,
        user: j['user'] as int,
        userName: j['user_name'] as String,
        category: j['category'] as String,
        categoryLabel: j['category_label'] as String,
        text: j['text'] as String,
        message: j['message'] as String,
        cell: j['cell'] as String?,
        lat: _d(j['lat']),
        lon: _d(j['lon']),
        t: _d(j['t']),
      );
}

/// Punkt śladu: serwer wysyła go jako [id, user, lat, lon, radius, t].
class TrackPoint {
  final int id, user;
  final double lat, lon, r, t;
  const TrackPoint(this.id, this.user, this.lat, this.lon, this.r, this.t);

  factory TrackPoint.fromList(List<dynamic> l) =>
      TrackPoint(l[0] as int, l[1] as int, _d(l[2]), _d(l[3]), _d(l[4]), _d(l[5]));

  /// Czy z punktu [prev] da się poprowadzić ślad do tego punktu.
  bool continues(TrackPoint prev) =>
      prev.user == user &&
      prev.r == r &&
      t - prev.t <= gapSeconds &&
      distanceM(prev.lat, prev.lon, lat, lon) <= gapMeters;
}

/// Pociągnięcie „mazakiem” – ciągły fragment śladu jednej osoby.
class Stroke {
  final int user;
  final double radius;
  final List<LatLng> points;
  Stroke(this.user, this.radius, this.points);
}

double nowSeconds() => DateTime.now().millisecondsSinceEpoch / 1000;

String ago(double? t) {
  if (t == null) return 'nigdy';
  final s = nowSeconds() - t;
  if (s < 60) return '${s.round()} s temu';
  if (s < 3600) return '${(s / 60).round()} min temu';
  return '${(s / 3600).round()} h temu';
}

const categoryIcons = <String, IconData>{
  'trace': Icons.pets,
  'item': Icons.backpack,
  'person': Icons.person_pin,
  'danger': Icons.warning,
  'other': Icons.flag,
};

const categoryColors = <String, Color>{
  'trace': Colors.brown,
  'item': Colors.blue,
  'person': Colors.red,
  'danger': Colors.orange,
  'other': Colors.purple,
};
