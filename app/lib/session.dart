import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'api.dart';
import 'coverage.dart';
import 'models.dart';
import 'notifications.dart';

/// Pozycja po korekcie kalibracyjnej.
class Fix {
  final double lat, lon, acc, t;
  const Fix(this.lat, this.lon, this.acc, this.t);
  LatLng get latLng => LatLng(lat, lon);
}

class CalibrationRun {
  static const duration = Duration(seconds: 30);
  final DateTime started = DateTime.now();
  final List<Fix> samples = [];
  double get progress =>
      math.min(1.0, DateTime.now().difference(started).inMilliseconds / duration.inMilliseconds);
}

class CalibrationResult {
  final bool ok;
  final String message;
  const CalibrationResult(this.ok, this.message);
}

class SessionController extends ChangeNotifier {
  final Api api;
  final String role; // 'user' albo 'admin'
  int? myId;

  Settings settings = const Settings();
  Map<String, String> categories = const {};
  final Map<int, AppUser> users = {};
  final List<Report> reports = [];
  final List<TrackPoint> points = [];
  int _lastPointId = 0;
  String? joinCode;
  Coverage? coverage;

  bool online = false;
  bool tracking = false;
  String? locationError;
  Fix? myFix;
  double _calDLat = 0, _calDLon = 0;
  double? calibratedAt;
  CalibrationRun? calibration;

  /// Ustawione, gdy admin usunął tego uczestnika – UI wylogowuje.
  bool kicked = false;

  final _incoming = StreamController<Report>.broadcast();
  Stream<Report> get incomingReports => _incoming.stream;

  final List<Map<String, dynamic>> _pending = []; // punkty czekające na wysłanie
  Fix? _lastRecorded;
  double _lastPosSent = 0;
  StreamSubscription<Position>? _posSub;
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  Timer? _flushTimer, _reconnectTimer, _tickTimer;
  bool _disposed = false;
  int _strokesVersion = -1;
  List<Stroke> _strokes = const [];
  int _version = 0;

  SessionController(this.api, this.role, {this.myId});

  bool get isAdmin => role == 'admin';
  AppUser? get me => myId == null ? null : users[myId];
  bool get calibrated => calibratedAt != null;

  // ------------------------------------------------------------ logowanie

  static const _kServer = 'server', _kToken = 'token', _kRole = 'role', _kUserId = 'user_id';
  static const _kCal = 'calibration';

  static Future<SessionController?> restore() async {
    final p = await SharedPreferences.getInstance();
    final server = p.getString(_kServer), token = p.getString(_kToken), role = p.getString(_kRole);
    if (server == null || token == null || role == null) return null;
    return SessionController(Api(server, token), role, myId: p.getInt(_kUserId));
  }

  static Future<String?> lastServer() async =>
      (await SharedPreferences.getInstance()).getString(_kServer);

  static Future<SessionController> joinAsUser(String server, String name, String code) async {
    final base = Api.normalize(server);
    final r = await Api.join(base, name, code);
    final id = r['user']['id'] as int;
    await _save(base, r['token'] as String, 'user', id);
    return SessionController(Api(base, r['token'] as String), 'user', myId: id);
  }

  static Future<SessionController> loginAsAdmin(String server, String key) async {
    final base = Api.normalize(server);
    final api = Api(base, key.trim());
    final st = await api.get('/api/state');
    if (st['role'] != 'admin') throw ApiException(403, 'To nie jest klucz administratora');
    await _save(base, key.trim(), 'admin', null);
    return SessionController(api, 'admin');
  }

  static Future<void> _save(String server, String token, String role, int? userId) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kServer, server);
    await p.setString(_kToken, token);
    await p.setString(_kRole, role);
    await p.remove(_kCal);
    if (userId == null) {
      await p.remove(_kUserId);
    } else {
      await p.setInt(_kUserId, userId);
    }
  }

  Future<void> logout() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kToken);
    await p.remove(_kRole);
    await p.remove(_kUserId);
    await p.remove(_kCal);
    dispose();
  }

  // ------------------------------------------------------------ start

  Future<void> start() async {
    final p = await SharedPreferences.getInstance();
    final cal = p.getString(_kCal);
    if (cal != null) {
      final j = jsonDecode(cal);
      _calDLat = (j['dlat'] as num).toDouble();
      _calDLon = (j['dlon'] as num).toDouble();
      calibratedAt = (j['t'] as num).toDouble();
    }
    await Notifier.init();
    try {
      await loadState();
    } on ApiException catch (e) {
      if (e.status == 401) kicked = true; // konto usunięte albo zły klucz
      _notify();
      if (kicked) return;
    } catch (_) {
      // serwer niedostępny – stan dociągnie się po połączeniu WebSocketu
    }
    _connectWs();
    _flushTimer = Timer.periodic(const Duration(seconds: 5), (_) => _flush());
    _tickTimer = Timer.periodic(const Duration(seconds: 15), (_) => _notify()); // odświeża „x min temu”
    if (!isAdmin) await _startLocation();
  }

  Future<void> loadState() async {
    final st = await api.get('/api/state') as Map<String, dynamic>;
    final old = settings;
    settings = Settings.fromJson(st['settings']);
    categories = (st['categories'] as Map).cast<String, String>();
    joinCode = st['join_code'] as String?;
    users
      ..clear()
      ..addEntries((st['users'] as List).map((u) {
        final user = AppUser.fromJson(u);
        return MapEntry(user.id, user);
      }));
    reports
      ..clear()
      ..addAll((st['reports'] as List).map((r) => Report.fromJson(r)));
    if (!isAdmin && me == null) kicked = true;
    if (coverage == null || _gridChanged(old, settings)) _rebuildCoverage();
    await _fetchPoints();
    _notify();
  }

  Future<void> _fetchPoints() async {
    final list = await api.get('/api/points?since=$_lastPointId') as List;
    _addPoints(list.map((l) => TrackPoint.fromList(l)));
  }

  void _addPoints(Iterable<TrackPoint> pts) {
    for (final p in pts) {
      if (p.id <= _lastPointId) continue;
      points.add(p);
      _lastPointId = p.id;
      coverage?.add(p);
    }
    _version++;
  }

  bool _gridChanged(Settings a, Settings b) =>
      a.rows != b.rows ||
      a.cols != b.cols ||
      a.area?.north != b.area?.north ||
      a.area?.south != b.area?.south ||
      a.area?.east != b.area?.east ||
      a.area?.west != b.area?.west;

  void _rebuildCoverage() {
    final a = settings.area;
    coverage = a == null ? null : Coverage(a, settings.rows, settings.cols);
    for (final p in points) {
      coverage?.add(p);
    }
    _version++;
  }

  // ------------------------------------------------------------ websocket

  void _connectWs() {
    if (_disposed) return;
    final ch = api.webSocket();
    _ws = ch;
    _wsSub = ch.stream.listen(
      (data) => _onMessage(jsonDecode(data as String) as Map<String, dynamic>),
      onError: (_) => _wsClosed(),
      onDone: _wsClosed,
      cancelOnError: true,
    );
    ch.ready.then((_) async {
      online = true;
      _notify();
      try {
        await loadState(); // dociągamy to, co przegapiliśmy podczas przerwy
      } catch (_) {}
    }, onError: (_) {});
  }

  void _wsClosed() {
    online = false;
    _wsSub?.cancel();
    _notify();
    _reconnectTimer?.cancel();
    if (!_disposed) _reconnectTimer = Timer(const Duration(seconds: 3), _connectWs);
  }

  void _onMessage(Map<String, dynamic> m) {
    switch (m['type']) {
      case 'points':
        _addPoints((m['points'] as List).map((l) => TrackPoint.fromList(l)));
      case 'pos':
        {
          final u = users[m['id']];
          if (u != null) {
            users[u.id] = u.withPosition((m['lat'] as num).toDouble(), (m['lon'] as num).toDouble(),
                (m['acc'] as num).toDouble(), (m['last_seen'] as num).toDouble());
          }
        }
      case 'user':
        {
          final u = AppUser.fromJson(m['user']);
          users[u.id] = u;
        }
      case 'user_deleted':
        users.remove(m['id']);
        if (m['id'] == myId) kicked = true;
      case 'settings':
        {
          final old = settings;
          settings = Settings.fromJson(m['settings']);
          if (_gridChanged(old, settings)) _rebuildCoverage();
        }
      case 'report':
        {
          final r = Report.fromJson(m['report']);
          if (reports.any((x) => x.id == r.id)) break;
          reports.add(r);
          _incoming.add(r);
          if (r.user != myId) Notifier.show(r);
        }
      case 'report_deleted':
        reports.removeWhere((r) => r.id == m['id']);
      case 'reset':
        points.clear();
        _rebuildCoverage();
    }
    _notify();
  }

  // ------------------------------------------------------------ GPS

  Future<void> _startLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        locationError = 'Włącz lokalizację (GPS) w telefonie';
        _notify();
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        locationError = 'Brak zgody na lokalizację';
        _notify();
        return;
      }
      locationError = null;
      _posSub = Geolocator.getPositionStream(locationSettings: _locationSettings()).listen(
        _onPosition,
        onError: (e) {
          locationError = 'Błąd GPS: $e';
          _notify();
        },
      );
    } catch (e) {
      locationError = 'Błąd GPS: $e';
      _notify();
    }
  }

  LocationSettings _locationSettings() {
    if (kIsWeb) {
      return WebSettings(accuracy: LocationAccuracy.best, maximumAge: Duration.zero);
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
          intervalDuration: const Duration(seconds: 1),
          forceLocationManager: true, // czysty GPS, bez mieszania z siecią komórkową
          // usługa pierwszoplanowa: ślad i powiadomienia działają przy wygaszonym ekranie
          foregroundNotificationConfig: const ForegroundNotificationConfig(
            notificationTitle: 'GeoFinder',
            notificationText: 'Akcja w toku – lokalizacja aktywna',
            enableWakeLock: true,
            setOngoing: true,
          ),
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.best,
          activityType: ActivityType.fitness,
          distanceFilter: 0,
          pauseLocationUpdatesAutomatically: false,
          allowBackgroundLocationUpdates: defaultTargetPlatform == TargetPlatform.iOS,
          showBackgroundLocationIndicator: true,
        );
      default:
        return const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0);
    }
  }

  void _onPosition(Position p) {
    final t = p.timestamp.millisecondsSinceEpoch / 1000;
    final raw = Fix(p.latitude, p.longitude, p.accuracy, t);
    calibration?.samples.add(raw);
    final fix = Fix(raw.lat + _calDLat, raw.lon + _calDLon, raw.acc, t);
    myFix = fix;

    if (tracking && fix.acc <= settings.maxAccuracy) {
      final last = _lastRecorded;
      if (last == null ||
          distanceM(last.lat, last.lon, fix.lat, fix.lon) >= 3 ||
          fix.t - last.t >= 30) {
        _lastRecorded = fix;
        _pending.add({'lat': fix.lat, 'lon': fix.lon, 'acc': fix.acc, 't': fix.t});
        if (_pending.length > 5000) _pending.removeAt(0);
        _version++;
      }
    } else if (!tracking && t - _lastPosSent >= 15) {
      _lastPosSent = t;
      api.post('/api/points', {
        'record': false,
        'points': [{'lat': fix.lat, 'lon': fix.lon, 'acc': fix.acc, 't': fix.t}],
      }).catchError((_) => null);
    }
    _notify();
  }

  bool _flushing = false;
  Future<void> _flush() async {
    if (_flushing || _pending.isEmpty) return;
    _flushing = true;
    final batch = List.of(_pending.take(200));
    try {
      await api.post('/api/points', {'points': batch});
      _pending.removeRange(0, batch.length);
      _lastPosSent = nowSeconds();
      _version++;
    } catch (_) {
      // brak zasięgu – spróbujemy przy następnym cyklu, punkty czekają w buforze
    } finally {
      _flushing = false;
    }
  }

  int get pendingCount => _pending.length;

  void setTracking(bool on) {
    tracking = on;
    _lastRecorded = null;
    if (!on) _flush();
    _notify();
  }

  // ------------------------------------------------------------ kalibracja

  /// Zbiera pozycje przez 30 s, stojąc w punkcie kalibracyjnym, i wylicza
  /// stałe przesunięcie tego telefonu względem znanego punktu.
  Future<CalibrationResult> calibrate() async {
    if (_posSub == null) return const CalibrationResult(false, 'GPS nie jest aktywny');
    final run = CalibrationRun();
    calibration = run;
    _notify();
    final ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _notify());
    await Future.delayed(CalibrationRun.duration);
    ticker.cancel();
    calibration = null;
    final result = await _finishCalibration(run.samples.where((s) => s.acc <= 50).toList());
    _notify();
    return result;
  }

  Future<CalibrationResult> _finishCalibration(List<Fix> s) async {
    if (s.length < 10) {
      return CalibrationResult(false,
          'Za mało dobrych odczytów GPS (${s.length}). Wyjdź na otwartą przestrzeń i spróbuj ponownie.');
    }
    // średnia ważona dokładnością (lepsze odczyty liczą się bardziej)
    var sw = 0.0, sLat = 0.0, sLon = 0.0, sAcc = 0.0;
    for (final f in s) {
      final w = 1 / math.max(1, f.acc * f.acc);
      sw += w;
      sLat += f.lat * w;
      sLon += f.lon * w;
      sAcc += f.acc;
    }
    final mLat = sLat / sw, mLon = sLon / sw, meanAcc = sAcc / s.length;
    final spread = math.sqrt(
        s.map((f) => math.pow(distanceM(f.lat, f.lon, mLat, mLon), 2)).reduce((a, b) => a + b) / s.length);

    final ref = settings.calib;
    double dLat = 0, dLon = 0;
    String msg;
    if (ref != null) {
      final off = distanceM(mLat, mLon, ref.latitude, ref.longitude);
      if (off > 150) {
        return CalibrationResult(false,
            'Jesteś ${off.round()} m od punktu kalibracyjnego. Podejdź do niego i spróbuj ponownie.');
      }
      dLat = ref.latitude - mLat;
      dLon = ref.longitude - mLon;
      msg = 'Korekta ${off.toStringAsFixed(1)} m, rozrzut ±${spread.toStringAsFixed(1)} m '
          '(${s.length} odczytów, śr. dokładność ${meanAcc.toStringAsFixed(0)} m).';
    } else {
      msg = 'Brak punktu kalibracyjnego – sprawdzono tylko jakość GPS: rozrzut '
          '±${spread.toStringAsFixed(1)} m, śr. dokładność ${meanAcc.toStringAsFixed(0)} m.';
    }
    _calDLat = dLat;
    _calDLon = dLon;
    calibratedAt = nowSeconds();
    final p = await SharedPreferences.getInstance();
    await p.setString(_kCal, jsonEncode({'dlat': dLat, 'dlon': dLon, 't': calibratedAt}));
    try {
      await api.post('/api/calibration',
          {'dlat': dLat, 'dlon': dLon, 'acc': meanAcc, 'spread': spread, 'samples': s.length});
    } catch (_) {}
    return CalibrationResult(true, msg);
  }

  // ------------------------------------------------------------ zgłoszenia

  Future<Report> sendReport(LatLng at, String category, String text) async {
    final r = await api.post('/api/reports',
        {'lat': at.latitude, 'lon': at.longitude, 'category': category, 'text': text});
    return Report.fromJson(r);
  }

  // ------------------------------------------------------------ admin

  Future<void> updateSettings(Map<String, dynamic> patch) => api.put('/api/settings', patch);
  Future<void> updateUser(int id, Map<String, dynamic> patch) => api.put('/api/users/$id', patch);
  Future<void> deleteUser(int id) => api.delete('/api/users/$id');
  Future<void> deleteReport(int id) => api.delete('/api/reports/$id');
  Future<void> clearCoverage() => api.post('/api/coverage/clear');

  // ------------------------------------------------------------ rysowanie

  /// Ślady wszystkich osób pocięte na ciągłe pociągnięcia (wraz z
  /// własnymi punktami, które jeszcze nie dotarły na serwer).
  List<Stroke> get strokes {
    if (_strokesVersion == _version) return _strokes;
    final all = List.of(points);
    final r = me?.radius ?? settings.defaultRadius;
    for (final p in _pending) {
      all.add(TrackPoint(-1, myId ?? -1, p['lat'], p['lon'], r, p['t']));
    }
    final lastByUser = <int, TrackPoint>{};
    final current = <int, Stroke>{};
    final out = <Stroke>[];
    for (final p in all) {
      final prev = lastByUser[p.user];
      if (prev != null && p.continues(prev)) {
        current[p.user]!.points.add(LatLng(p.lat, p.lon));
      } else {
        final s = Stroke(p.user, p.r, [LatLng(p.lat, p.lon)]);
        current[p.user] = s;
        out.add(s);
      }
      lastByUser[p.user] = p;
    }
    _strokes = out;
    _strokesVersion = _version;
    return out;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _posSub?.cancel();
    _wsSub?.cancel();
    _ws?.sink.close();
    _flushTimer?.cancel();
    _reconnectTimer?.cancel();
    _tickTimer?.cancel();
    _incoming.close();
    super.dispose();
  }
}
