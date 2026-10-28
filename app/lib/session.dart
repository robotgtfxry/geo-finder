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
import 'tiles/cached_tiles.dart';
import 'tiles/tile_store.dart';

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
  // nadpisywane przez serwer; te są na wypadek pierwszego uruchomienia bez sieci
  Map<String, String> categories = const {
    'trace': 'Ślad', 'item': 'Przedmiot', 'person': 'Osoba', 'danger': 'Zagrożenie', 'other': 'Inne',
  };
  final Map<int, AppUser> users = {};
  final List<Report> reports = [];
  final List<TrackPoint> points = [];
  int _lastPointId = 0;
  String? joinCode;
  Coverage? coverage;

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

  // ---- kamera na żywo
  /// Id tego połączenia WebSocket nadane przez serwer.
  String? myCid;

  /// Kto teraz nadaje obraz: id uczestnika -> cid jego połączenia.
  final Map<int, String> live = {};
  final _rtc = StreamController<(String from, Map<String, dynamic> data)>.broadcast();
  Stream<(String, Map<String, dynamic>)> get rtcMessages => _rtc.stream;

  /// Uczestnik: koordynator prosi o kamerę (wartość = cid koordynatora).
  final _streamRequests = StreamController<String>.broadcast();
  Stream<String> get streamRequests => _streamRequests.stream;

  /// Koordynator: zdarzenia „uczestnik włączył kamerę, o którą prosiłem”
  /// (id uczestnika) i „odmówił” (ujemne id).
  final _streamAnswers = StreamController<int>.broadcast();
  Stream<int> get streamAnswers => _streamAnswers.stream;
  final Set<int> _requested = {};

  // Kolejka offline: punkty śladu i zgłoszenia czekające na wysłanie.
  // Zapisywana w telefonie, więc przetrwa też restart aplikacji.
  final List<Map<String, dynamic>> _pending = [];
  final List<Map<String, dynamic>> _pendingReports = [];
  bool _pendingDirty = false;
  Set<int>? _knownReports;

  /// Od kiedy nie ma połączenia (null = jest połączenie).
  DateTime? offlineSince;
  DateTime _lastMessage = DateTime.now();

  /// Pobieranie mapy offline: do telefonu (uczestnik) albo na serwer (admin).
  int tilesDone = 0, tilesTotal = 0;
  bool tilesRunning = false;

  Fix? _lastRecorded;
  double _lastPosSent = 0;
  StreamSubscription<Position>? _posSub;
  WebSocketChannel? _ws;
  StreamSubscription? _wsSub;
  Timer? _flushTimer, _reconnectTimer, _tickTimer, _pingTimer;
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
  static const _kCal = 'calibration', _kPending = 'pending', _kState = 'state_cache';
  static const _kTracking = 'tracking', _kTilesArea = 'tiles_area';

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
    for (final k in [_kCal, _kPending, _kState, _kTracking, _kTilesArea]) {
      await p.remove(k);
    }
    if (userId == null) {
      await p.remove(_kUserId);
    } else {
      await p.setInt(_kUserId, userId);
    }
  }

  Future<void> logout() async {
    _pending.clear();
    _pendingReports.clear();
    _pendingDirty = false;
    final p = await SharedPreferences.getInstance();
    for (final k in [_kToken, _kRole, _kUserId, _kCal, _kPending, _kState, _kTracking, _kTilesArea]) {
      await p.remove(k);
    }
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
    final pending = p.getString(_kPending);
    if (pending != null) {
      final j = jsonDecode(pending);
      _pending.addAll((j['points'] as List).cast<Map<String, dynamic>>());
      _pendingReports.addAll((j['reports'] as List).cast<Map<String, dynamic>>());
    }
    tracking = p.getBool(_kTracking) ?? false;
    // ostatni znany stan – żeby siatka i zgłoszenia były widoczne także bez sieci
    final cached = p.getString(_kState);
    if (cached != null) {
      try {
        _applyState(jsonDecode(cached) as Map<String, dynamic>);
      } catch (_) {}
    }
    await Notifier.init();
    try {
      await loadState();
    } on ApiException catch (e) {
      if (e.status == 401) kicked = true; // konto usunięte albo zły klucz
      _notify();
      if (kicked) return;
    } catch (_) {
      // serwer niedostępny – aplikacja działa dalej, dane czekają w kolejce
    }
    _connectWs();
    _flushTimer = Timer.periodic(const Duration(seconds: 5), (_) => _flush());
    _tickTimer = Timer.periodic(const Duration(seconds: 15), (_) => _notify()); // odświeża „x min temu”
    _pingTimer = Timer.periodic(const Duration(seconds: 4), (_) => _ping());
    if (!isAdmin) await _startLocation();
  }

  Future<void> loadState() async {
    final st = await api.get('/api/state') as Map<String, dynamic>;
    _applyState(st);
    if (!isAdmin && me == null) kicked = true;
    SharedPreferences.getInstance().then((p) => p.setString(_kState, jsonEncode(st)));
    await _fetchPoints();
    _setOnline(true);
    _notify();
    _prefetchTilesToPhone();
  }

  void _applyState(Map<String, dynamic> st) {
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
    // zgłoszenia, które przyszły, gdy nie mieliśmy sieci – pokazujemy je po powrocie
    final known = _knownReports;
    if (known != null) {
      for (final r in reports) {
        if (!known.contains(r.id) && r.user != myId) {
          _incoming.add(r);
          Notifier.show(r);
        }
      }
    }
    _knownReports = reports.map((r) => r.id).toSet();
    if (coverage == null || _gridChanged(old, settings)) _rebuildCoverage();
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
      onError: (_) => _wsClosed(ch),
      onDone: () => _wsClosed(ch),
      cancelOnError: true,
    );
    ch.ready.then((_) async {
      _lastMessage = DateTime.now();
      try {
        await loadState(); // dociągamy to, co przegapiliśmy podczas przerwy
        _flush(); // i od razu wysyłamy zaległy ślad
      } catch (_) {}
    }, onError: (_) {});
  }

  void _wsClosed(WebSocketChannel ch) {
    if (ch != _ws) return; // stare połączenie, już zastąpione
    _ws = null;
    _wsSub?.cancel();
    _setOnline(false);
    _reconnectTimer?.cancel();
    if (!_disposed) _reconnectTimer = Timer(const Duration(seconds: 3), _connectWs);
  }

  /// Serwer odpowiada „pong” na każdy „ping”. Cisza dłużej niż 10 s oznacza,
  /// że sieć padła, nawet jeśli system jeszcze nie zamknął połączenia.
  void _ping() {
    final ch = _ws;
    if (ch == null) return;
    try {
      ch.sink.add('ping');
    } catch (_) {}
    if (DateTime.now().difference(_lastMessage) > const Duration(seconds: 10)) {
      ch.sink.close();
      _wsClosed(ch);
    }
  }

  bool get online => offlineSince == null && _connectedOnce;
  bool _connectedOnce = false;

  /// Jeszcze nie udało się połączyć od uruchomienia aplikacji.
  bool get connecting => !_connectedOnce && offlineSince == null;

  void _setOnline(bool on) {
    if (on) {
      _connectedOnce = true;
      offlineSince = null;
    } else {
      offlineSince ??= DateTime.now();
    }
    _notify();
  }

  void _onMessage(Map<String, dynamic> m) {
    _lastMessage = DateTime.now();
    switch (m['type']) {
      case 'pong':
        if (!online && _connectedOnce) _setOnline(true);
        return;
      case 'hello':
        myCid = m['cid'] as String;
        live
          ..clear()
          ..addAll((m['live'] as Map).map((k, v) => MapEntry(int.parse(k as String), v as String)));
      case 'live':
        {
          final id = m['id'] as int, cid = m['cid'] as String?;
          if (cid == null) {
            live.remove(id);
          } else {
            live[id] = cid;
            if (_requested.remove(id)) _streamAnswers.add(id);
          }
        }
      case 'rtc':
        _rtc.add((m['from'] as String, (m['data'] as Map).cast<String, dynamic>()));
        return;
      case 'stream_request':
        _streamRequests.add(m['from'] as String);
        return;
      case 'stream_declined':
        {
          final id = m['id'] as int;
          if (_requested.remove(id)) _streamAnswers.add(-id);
        }
      case 'tiles':
        if (isAdmin) {
          // postęp pobierania map na serwer
          tilesDone = m['done'] as int;
          tilesTotal = m['total'] as int;
          tilesRunning = m['running'] as bool;
        }
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
          _knownReports?.add(r.id);
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
        _pending.add({
          'lat': fix.lat, 'lon': fix.lon, 'acc': fix.acc, 't': fix.t,
          'r': me?.radius ?? settings.defaultRadius, // promień ustawiony przez koordynatora
        });
        if (_pending.length > 30000) _pending.removeAt(0); // ok. 10+ godzin chodzenia bez sieci
        _pendingDirty = true;
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
  int _flushTick = 0;

  /// Wysyła kolejkę: najpierw zaległe zgłoszenia, potem ślad (partiami).
  /// Bez sieci nic nie traci – dane zostają w telefonie do następnej próby.
  Future<void> _flush() async {
    if (++_flushTick % 3 == 0) _persistPending();
    if (_flushing || offlineSince != null || (_pending.isEmpty && _pendingReports.isEmpty)) return;
    _flushing = true;
    try {
      while (_pendingReports.isNotEmpty) {
        await api.post('/api/reports', _pendingReports.first);
        _pendingReports.removeAt(0);
        _pendingDirty = true;
      }
      while (_pending.isNotEmpty) {
        final batch = List.of(_pending.take(500));
        await api.post('/api/points', {'points': batch});
        _pending.removeRange(0, batch.length);
        _pendingDirty = true;
        _lastPosSent = nowSeconds();
        _version++;
        _notify();
      }
    } catch (_) {
      _setOnline(false); // sieć padła w trakcie – pasek „brak połączenia” od razu
    } finally {
      _flushing = false;
      _persistPending();
      _notify();
    }
  }

  Future<void> _persistPending() async {
    if (!_pendingDirty) return;
    _pendingDirty = false;
    final p = await SharedPreferences.getInstance();
    await p.setString(_kPending, jsonEncode({'points': _pending, 'reports': _pendingReports}));
  }

  int get pendingCount => _pending.length;
  int get pendingReportsCount => _pendingReports.length;

  void setTracking(bool on) {
    tracking = on;
    _lastRecorded = null;
    SharedPreferences.getInstance().then((p) => p.setBool(_kTracking, on));
    if (!on) _flush();
    _notify();
  }

  // ------------------------------------------------------------ mapy offline

  /// Uczestnik: po połączeniu ściągamy do telefonu mapę całego obszaru akcji
  /// (raz na dany obszar), żeby działała w terenie bez zasięgu.
  Future<void> _prefetchTilesToPhone() async {
    final a = settings.area;
    if (isAdmin || a == null || tilesRunning || !TileStore.supported) return;
    final key = jsonEncode(a.toJson());
    final p = await SharedPreferences.getInstance();
    if (p.getString(_kTilesArea) == key) return;
    if (TileCache.tilesFor(a).length > 8000) return; // za duży obszar na telefon
    tilesRunning = true;
    _notify();
    final failed = await TileCache.prefetch(api.base, a, (done, total) {
      tilesDone = done;
      tilesTotal = total;
      if (done % 20 == 0 || done == total) _notify();
    }, cancelled: () => _disposed);
    tilesRunning = false;
    if (failed == 0 && !_disposed) await p.setString(_kTilesArea, key);
    _notify();
  }

  /// Admin: serwer pobiera z internetu mapę obszaru i trzyma ją u siebie.
  Future<void> prefetchTilesOnServer() async {
    final r = await api.post('/api/tiles/prefetch');
    tilesTotal = r['total'] as int;
    tilesDone = r['done'] as int;
    tilesRunning = true;
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

  /// Wysyła zgłoszenie. Bez sieci zwraca null – zgłoszenie czeka w kolejce
  /// (z oryginalnym czasem) i pójdzie samo, gdy wróci połączenie.
  Future<Report?> sendReport(LatLng at, String category, String text) async {
    final body = {'lat': at.latitude, 'lon': at.longitude, 'category': category, 'text': text, 't': nowSeconds()};
    if (offlineSince == null) {
      try {
        return Report.fromJson(await api.post('/api/reports', body));
      } on ApiException {
        rethrow; // serwer odpowiedział błędem – to nie problem z siecią
      } catch (_) {
        _setOnline(false);
      }
    }
    _pendingReports.add(body);
    _pendingDirty = true;
    await _persistPending();
    _notify();
    return null;
  }

  // ------------------------------------------------------------ kamera na żywo

  /// Wysyła wiadomość przez WebSocket. Zwraca false, gdy nie ma połączenia.
  bool sendWs(Map<String, dynamic> msg) {
    final ch = _ws;
    if (ch == null || !online) return false;
    ch.sink.add(jsonEncode(msg));
    return true;
  }

  void sendRtc(String to, Map<String, dynamic> data) => sendWs({'type': 'rtc', 'to': to, 'data': data});
  void setLive(bool on) => sendWs({'type': 'live', 'live': on});
  void declineStream(String adminCid) => sendWs({'type': 'stream_declined', 'to': adminCid});

  /// Koordynator prosi uczestnika o włączenie kamery.
  bool requestStream(int userId) {
    _requested.add(userId);
    return sendWs({'type': 'stream_request', 'user': userId});
  }

  bool isLive(int userId) => live.containsKey(userId);

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
      all.add(TrackPoint(-1, myId ?? -1, p['lat'], p['lon'], (p['r'] as num?)?.toDouble() ?? r, p['t']));
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
    _persistPending();
    _posSub?.cancel();
    _wsSub?.cancel();
    _ws?.sink.close();
    _pingTimer?.cancel();
    _flushTimer?.cancel();
    _reconnectTimer?.cancel();
    _tickTimer?.cancel();
    _incoming.close();
    _rtc.close();
    _streamRequests.close();
    _streamAnswers.close();
    super.dispose();
  }
}
