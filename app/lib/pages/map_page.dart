import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models.dart';
import '../notifications.dart';
import '../session.dart';
import '../tiles/cached_tiles.dart';
import 'dialogs.dart';
import 'login_page.dart';
import 'stream_pages.dart';
import 'users_menu.dart';

enum AdminTool { none, area, calib }

class MapPage extends StatefulWidget {
  final SessionController session;
  const MapPage({super.key, required this.session});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final _map = MapController();
  StreamSubscription<Report>? _reportSub;
  AdminTool _tool = AdminTool.none;
  LatLng? _firstCorner;
  double _zoom = 6;
  bool _mapReady = false, _fitted = false, _follow = false, _leaving = false;

  SessionController get s => widget.session;
  late final _tiles = CachedTileProvider(s.api.base);

  @override
  void initState() {
    super.initState();
    s.addListener(_onSession);
    _reportSub = s.incomingReports.listen(_showReportBanner);
    _streamSubs = [
      s.streamRequests.listen(_onStreamRequest),
      s.streamAnswers.listen(_onStreamAnswer),
    ];
    Notifier.onTap = (id) {
      final r = s.reports.where((r) => r.id == id).firstOrNull;
      if (r != null) _goTo(LatLng(r.lat, r.lon));
    };
    s.start();
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    _reportSub?.cancel();
    for (final sub in _streamSubs) {
      sub.cancel();
    }
    Notifier.onTap = null;
    super.dispose();
  }

  // ------------------------------------------------------------ kamera na żywo

  List<StreamSubscription> _streamSubs = const [];
  bool _broadcasting = false;

  late final _userActions = UserActions(
    showOnMap: (u) => _goTo(LatLng(u.lat!, u.lon!)),
    watch: _watch,
  );

  void _watch(AppUser u) => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ViewerPage(session: s, user: u)),
      );

  Future<void> _broadcast() async {
    if (_broadcasting) return;
    _broadcasting = true;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => BroadcastPage(session: s)));
    _broadcasting = false;
  }

  /// Uczestnik: koordynator prosi o obraz z kamery.
  Future<void> _onStreamRequest(String adminCid) async {
    if (!mounted || _broadcasting) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.videocam, size: 40, color: Colors.red),
        title: const Text('Koordynator prosi o obraz z kamery'),
        content: const Text('Włącz kamerę i pokaż, co widzisz. Obraz zobaczy tylko koordynator.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nie teraz')),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.videocam),
            label: const Text('Włącz kamerę'),
          ),
        ],
      ),
    );
    if (ok == true) {
      _broadcast();
    } else {
      s.declineStream(adminCid);
    }
  }

  /// Koordynator: odpowiedź na prośbę o kamerę.
  void _onStreamAnswer(int id) {
    if (!mounted) return;
    final u = s.users[id.abs()];
    if (u == null) return;
    if (id > 0) {
      _watch(u);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${u.name} nie może teraz włączyć kamery')));
    }
  }

  void _onSession() {
    if (s.kicked) {
      _logout(message: 'Zostałeś usunięty z akcji albo sesja wygasła.');
      return;
    }
    if (!_mapReady) return;
    if (!_fitted) _fitInitial();
    final fix = s.myFix;
    if (_follow && fix != null) _map.move(fix.latLng, _map.camera.zoom);
  }

  void _fitInitial() {
    final a = s.settings.area;
    if (a != null) {
      _map.fitCamera(CameraFit.bounds(
        bounds: LatLngBounds(LatLng(a.south, a.west), LatLng(a.north, a.east)),
        padding: const EdgeInsets.all(32),
      ));
      _fitted = true;
    } else if (s.myFix != null) {
      _map.move(s.myFix!.latLng, 17);
      _fitted = true;
    }
  }

  void _goTo(LatLng p) {
    _follow = false;
    _map.move(p, math.max(_map.camera.zoom, 18));
  }

  Future<void> _logout({String? message}) async {
    if (_leaving) return;
    _leaving = true;
    await s.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginPage()));
    if (message != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _showReportBanner(Report r) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentMaterialBanner();
    messenger.showMaterialBanner(MaterialBanner(
      leading: Icon(categoryIcons[r.category] ?? Icons.flag, color: categoryColors[r.category]),
      content: Text('${r.message}${r.text.isNotEmpty ? ': ${r.text}' : ''}\n${r.userName}'),
      actions: [
        TextButton(
          onPressed: () {
            messenger.hideCurrentMaterialBanner();
            _goTo(LatLng(r.lat, r.lon));
          },
          child: const Text('POKAŻ'),
        ),
        TextButton(onPressed: messenger.hideCurrentMaterialBanner, child: const Text('OK')),
      ],
    ));
  }

  // ------------------------------------------------------------ interakcja z mapą

  void _onTap(TapPosition _, LatLng p) {
    switch (_tool) {
      case AdminTool.calib:
        s.updateSettings({'calib': {'lat': p.latitude, 'lon': p.longitude}}).catchError(_error);
        setState(() => _tool = AdminTool.none);
      case AdminTool.area:
        {
          final first = _firstCorner;
          if (first == null) {
            setState(() => _firstCorner = p);
            return;
          }
          s.updateSettings({
            'area': {
              'north': math.max(first.latitude, p.latitude),
              'south': math.min(first.latitude, p.latitude),
              'east': math.max(first.longitude, p.longitude),
              'west': math.min(first.longitude, p.longitude),
            }
          }).catchError(_error);
          setState(() {
            _tool = AdminTool.none;
            _firstCorner = null;
          });
        }
      case AdminTool.none:
        break;
    }
  }

  void _onLongPress(TapPosition _, LatLng p) {
    if (!s.isAdmin) showReportDialog(context, s, p);
  }

  void _error(Object e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Błąd: $e')));
  }

  void _setTool(AdminTool t) => setState(() {
        _tool = _tool == t ? AdminTool.none : t;
        _firstCorner = null;
      });

  // ------------------------------------------------------------ warstwy mapy

  /// Metry na piksel ekranu przy danym przybliżeniu (kafelki 256 px).
  double _metersPerPixel(double lat) => 156543.03392 * math.cos(lat * math.pi / 180) / math.pow(2, _zoom);

  Color _userColor(int id) => s.users[id]?.color ?? Colors.green;

  List<Widget> _layers() {
    final st = s.settings;
    final a = st.area;
    final strokes = s.strokes;
    final fix = s.myFix;
    return [
      // mapa idzie przez serwer GeoFinder i jest zapamiętywana w telefonie –
      // działa w terenie bez internetu (patrz tiles/cached_tiles.dart)
      TileLayer(
        urlTemplate: '${s.api.base}/tiles/{z}/{x}/{y}.png',
        tileProvider: _tiles,
        userAgentPackageName: 'pl.geofinder',
        maxNativeZoom: TileCache.maxZoom,
        maxZoom: 21,
        evictErrorTileStrategy: EvictErrorTileStrategy.dispose, // brakujący kafelek spróbuje ponownie
      ),
      // przeszukany teren – „mazak” o szerokości 2 × promień osoby
      Opacity(
        opacity: 0.45,
        child: PolylineLayer(polylines: [
          for (final k in strokes)
            if (k.points.length > 1)
              Polyline(
                points: k.points,
                strokeWidth: k.radius * 2,
                useStrokeWidthInMeter: true,
                color: _userColor(k.user),
                strokeCap: StrokeCap.round,
                strokeJoin: StrokeJoin.round,
              ),
        ]),
      ),
      Opacity(
        opacity: 0.45,
        child: CircleLayer(circles: [
          for (final k in strokes)
            if (k.points.length == 1)
              CircleMarker(point: k.points.first, radius: k.radius, useRadiusInMeter: true, color: _userColor(k.user)),
        ]),
      ),
      if (a != null) PolylineLayer(polylines: _gridLines(a, st)),
      if (a != null) MarkerLayer(markers: _cellLabels(a, st)),
      if (st.calib != null)
        MarkerLayer(markers: [
          Marker(
            point: st.calib!,
            width: 26,
            height: 26,
            child: const Tooltip(
              message: 'Punkt kalibracyjny',
              child: Icon(Icons.gps_fixed, color: Colors.black, size: 26),
            ),
          ),
        ]),
      if (fix != null && !s.isAdmin)
        CircleLayer(circles: [
          CircleMarker(
            point: fix.latLng,
            radius: fix.acc,
            useRadiusInMeter: true,
            color: Colors.blue.withValues(alpha: 0.12),
          ),
          CircleMarker(
            point: fix.latLng,
            radius: s.me?.radius ?? st.defaultRadius,
            useRadiusInMeter: true,
            color: Colors.transparent,
            borderColor: s.me?.color ?? Colors.blue,
            borderStrokeWidth: 2,
          ),
        ]),
      MarkerLayer(markers: [
        for (final u in s.users.values)
          if (u.lat != null && u.id != s.myId) _userMarker(u),
        if (fix != null && !s.isAdmin)
          Marker(
            point: fix.latLng,
            width: 18,
            height: 18,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.blue,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
                boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black38)],
              ),
            ),
          ),
        for (final r in s.reports) _reportMarker(r),
        if (_firstCorner != null)
          Marker(point: _firstCorner!, width: 20, height: 20, child: const Icon(Icons.add, color: Colors.red)),
      ]),
    ];
  }

  List<Polyline> _gridLines(Area a, Settings st) {
    final dLat = (a.north - a.south) / st.rows, dLon = (a.east - a.west) / st.cols;
    return [
      for (var c = 1; c < st.cols; c++)
        Polyline(points: [LatLng(a.north, a.west + c * dLon), LatLng(a.south, a.west + c * dLon)], color: Colors.black54, strokeWidth: 1),
      for (var r = 1; r < st.rows; r++)
        Polyline(points: [LatLng(a.north - r * dLat, a.west), LatLng(a.north - r * dLat, a.east)], color: Colors.black54, strokeWidth: 1),
      Polyline(
        points: [LatLng(a.north, a.west), LatLng(a.north, a.east), LatLng(a.south, a.east), LatLng(a.south, a.west), LatLng(a.north, a.west)],
        color: Colors.red.shade700,
        strokeWidth: 3,
      ),
    ];
  }

  List<Marker> _cellLabels(Area a, Settings st) {
    final cellPx = a.widthM / st.cols / _metersPerPixel(a.midLat);
    if (cellPx < 44 || st.rows * st.cols > 2500) return const [];
    final cov = s.coverage;
    final dLat = (a.north - a.south) / st.rows, dLon = (a.east - a.west) / st.cols;
    return [
      for (var r = 0; r < st.rows; r++)
        for (var c = 0; c < st.cols; c++)
          Marker(
            point: LatLng(a.north - r * dLat, a.west + c * dLon),
            width: 64,
            height: 18,
            alignment: Alignment.bottomRight,
            child: Container(
              margin: const EdgeInsets.only(left: 2, top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 3),
              alignment: Alignment.centerLeft,
              color: Colors.white70,
              child: Text(
                '${colLabel(c)}${r + 1}${cov != null ? ' ${cov.cellPercent(r, c).round()}%' : ''}',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black87),
                maxLines: 1,
                overflow: TextOverflow.clip,
              ),
            ),
          ),
    ];
  }

  Marker _userMarker(AppUser u) => Marker(
        point: LatLng(u.lat!, u.lon!),
        width: 140,
        height: 20,
        alignment: const Alignment(0.9, 0), // kropka trafia w pozycję, podpis po prawej
        child: GestureDetector(
          // koordynator: dotknięcie kropki otwiera menu tej osoby
          onTap: s.isAdmin ? () => showUserMenu(context, s, u.id, _userActions) : null,
          child: Opacity(
            opacity: u.stale ? 0.45 : 1,
            child: Row(children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: u.color,
                  shape: BoxShape.circle,
                  // czerwona obwódka = nadaje obraz z kamery
                  border: Border.all(color: s.isLive(u.id) ? Colors.red : Colors.white, width: s.isLive(u.id) ? 3 : 2),
                ),
              ),
              const SizedBox(width: 3),
              Flexible(
                child: Container(
                  color: s.isLive(u.id) ? Colors.red : Colors.white70,
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    s.isLive(u.id)
                        ? '● ${u.name}'
                        : u.stale
                            ? '${u.name} (bez sieci ${ago(u.lastSeen)})'
                            : u.name,
                    style: TextStyle(fontSize: 11, color: s.isLive(u.id) ? Colors.white : Colors.black),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ]),
          ),
        ),
      );

  Marker _reportMarker(Report r) => Marker(
        point: LatLng(r.lat, r.lon),
        width: 34,
        height: 34,
        child: GestureDetector(
          onTap: () => showReportDetails(context, s, r),
          child: Container(
            decoration: BoxDecoration(
              color: categoryColors[r.category] ?? Colors.purple,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black45)],
            ),
            child: Icon(categoryIcons[r.category] ?? Icons.flag, color: Colors.white, size: 18),
          ),
        ),
      );

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(s.settings.name, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: 'Zgłoszenia',
              icon: Badge(
                isLabelVisible: s.reports.isNotEmpty,
                label: Text('${s.reports.length}'),
                child: const Icon(Icons.notifications),
              ),
              onPressed: () => showReportsSheet(context, s, onSelect: (r) => _goTo(LatLng(r.lat, r.lon))),
            ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'logout') _logout();
                if (v == 'clear' && await confirm(context, 'Usunąć CAŁE przeszukane pokrycie? Tego nie da się cofnąć.')) {
                  s.clearCoverage().catchError(_error);
                }
              },
              itemBuilder: (_) => [
                if (s.isAdmin) const PopupMenuItem(value: 'clear', child: Text('Wyczyść pokrycie')),
                const PopupMenuItem(value: 'logout', child: Text('Wyloguj')),
              ],
            ),
          ],
        ),
        body: Column(children: [
          _connectionBanner(),
          Expanded(child: _mapStack()),
        ]),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: s.isAdmin ? _adminBar() : _userBar(),
          ),
        ),
      ),
    );
  }

  /// Pasek stanu połączenia – widoczny od razu po utracie sieci.
  Widget _connectionBanner() {
    final waiting = s.pendingCount + s.pendingReportsCount;
    String title;
    String? detail;
    Color color;
    IconData icon;
    if (s.connecting) {
      color = Colors.blueGrey;
      icon = Icons.sync;
      title = 'Łączenie z serwerem…';
      detail = null;
    } else if (!s.online) {
      final since = s.offlineSince!;
      final mins = DateTime.now().difference(since).inMinutes;
      color = Colors.red.shade700;
      icon = Icons.cloud_off;
      title = 'BRAK POŁĄCZENIA${mins > 0 ? ' (od $mins min)' : ''}';
      detail = s.isAdmin
          ? 'Widzisz ostatni znany stan. Odświeży się sam, gdy wróci sieć.'
          : 'Aplikacja działa dalej – szukaj normalnie. Ślad zapisuje się w telefonie'
              '${waiting > 0 ? ' ($waiting do wysłania)' : ''} i wyśle się sam, gdy wróci sieć.';
    } else if (waiting > 0) {
      color = Colors.orange.shade800;
      icon = Icons.cloud_upload;
      title = 'Wysyłam zaległe dane… ($waiting)';
      detail = null;
    } else {
      return const SizedBox.shrink();
    }
    return Material(
      color: color,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                if (detail != null) Text(detail, style: const TextStyle(color: Colors.white, fontSize: 13)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _mapStack() => Stack(children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: const LatLng(52.0, 19.0),
              initialZoom: 6,
              maxZoom: 21,
              onTap: _onTap,
              onLongPress: _onLongPress,
              onMapReady: () {
                _mapReady = true;
                _fitInitial();
              },
              onPositionChanged: (camera, hasGesture) {
                if (hasGesture) _follow = false;
                if ((camera.zoom - _zoom).abs() > 0.05) {
                  // etykiety kwadratów zależą od przybliżenia; odświeżamy po klatce
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _zoom = camera.zoom);
                  });
                }
              },
            ),
            children: _layers(),
          ),
          Positioned(left: 8, right: 8, top: 8, child: s.isAdmin ? _adminStatus() : _userStatus()),
          if (!s.isAdmin)
            Positioned(
              right: 12,
              bottom: 12,
              child: FloatingActionButton.small(
                heroTag: 'me',
                tooltip: 'Moja pozycja',
                backgroundColor: _follow ? Colors.blue : null,
                onPressed: s.myFix == null
                    ? null
                    : () {
                        setState(() => _follow = true);
                        _map.move(s.myFix!.latLng, math.max(_map.camera.zoom, 17));
                      },
                child: const Icon(Icons.my_location),
              ),
            ),
          if (!s.isAdmin)
            Positioned(
              left: 12,
              bottom: 12,
              child: FloatingActionButton.extended(
                heroTag: 'cam',
                backgroundColor: Colors.red.shade700,
                foregroundColor: Colors.white,
                onPressed: s.online ? _broadcast : () => _error('Kamera działa tylko z połączeniem z serwerem'),
                icon: const Icon(Icons.videocam),
                label: const Text('Kamera'),
              ),
            ),
        ]);

  Widget _statusCard(List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: DefaultTextStyle.merge(
            style: const TextStyle(fontSize: 13),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
      );

  Widget _userStatus() {
    final fix = s.myFix;
    final cell = fix == null ? null : s.settings.cellOf(fix.lat, fix.lon);
    return _statusCard([
      if (s.locationError != null)
        Text(s.locationError!, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold))
      else if (fix == null)
        const Text('Czekam na sygnał GPS…')
      else
        Text(
          'GPS ±${fix.acc.round()} m'
          '${fix.acc > s.settings.maxAccuracy ? ' (za słaby – nie zapisuję)' : ''}'
          ' · ${cell != null ? 'kwadrat $cell' : 'poza siatką'}',
          style: TextStyle(color: fix.acc > s.settings.maxAccuracy ? Colors.orange.shade800 : null),
        ),
      Text(
        '${s.tracking ? 'Zapisuję ślad' : 'Ślad wyłączony – naciśnij „Szukam”'}'
        ' · ${s.calibrated ? 'skalibrowano ${ago(s.calibratedAt)}' : 'bez kalibracji'}',
      ),
      if (s.tilesRunning) Text('Pobieram mapę do telefonu: ${s.tilesDone}/${s.tilesTotal}'),
    ]);
  }

  Widget _adminStatus() {
    final cov = s.coverage;
    final active = s.users.values.where((u) => !u.stale).length;
    return _statusCard([
      Text('Kod dołączenia: ${s.joinCode ?? '—'}', style: const TextStyle(fontWeight: FontWeight.bold)),
      Text(
        '${cov != null ? 'Przeszukano ${cov.totalPercent.toStringAsFixed(1)}% obszaru' : 'Zaznacz obszar akcji'}'
        ' · aktywni $active/${s.users.length}',
      ),
      if (s.tilesRunning) Text('Pobieram mapę offline na serwer: ${s.tilesDone}/${s.tilesTotal}'),
      if (_tool == AdminTool.area)
        Text(_firstCorner == null ? 'Kliknij pierwszy róg obszaru' : 'Kliknij przeciwległy róg',
            style: const TextStyle(color: Colors.red)),
      if (_tool == AdminTool.calib)
        const Text('Kliknij miejsce punktu kalibracyjnego', style: TextStyle(color: Colors.red)),
    ]);
  }

  Widget _userBar() => Row(children: [
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: s.tracking ? Colors.grey.shade700 : Colors.green.shade700),
            icon: Icon(s.tracking ? Icons.pause : Icons.play_arrow),
            label: Text(s.tracking ? 'Pauza' : 'Szukam'),
            onPressed: () => s.setTracking(!s.tracking),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.gps_fixed),
            label: const Text('Kalibruj'),
            onPressed: s.calibration == null ? () => showCalibrationDialog(context, s) : null,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            icon: const Icon(Icons.campaign),
            label: const Text('Zgłoś'),
            onPressed: s.myFix == null
                ? () => _error('Brak pozycji GPS – przytrzymaj palec na mapie, aby wskazać miejsce')
                : () => showReportDialog(context, s, s.myFix!.latLng),
          ),
        ),
      ]);

  Widget _adminBar() => Wrap(
        spacing: 8,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        children: [
          FilterChip(
            avatar: const Icon(Icons.crop_square),
            label: const Text('Obszar'),
            selected: _tool == AdminTool.area,
            onSelected: (_) => _setTool(AdminTool.area),
          ),
          FilterChip(
            avatar: const Icon(Icons.gps_fixed),
            label: const Text('Punkt kalibracyjny'),
            selected: _tool == AdminTool.calib,
            onSelected: (_) => _setTool(AdminTool.calib),
          ),
          ActionChip(
            avatar: const Icon(Icons.grid_on),
            label: const Text('Siatka i parametry'),
            onPressed: () => showGridDialog(context, s),
          ),
          ActionChip(
            avatar: const Icon(Icons.group),
            label: Text('Uczestnicy (${s.users.length})'),
            onPressed: () => showUsersSheet(context, s, _userActions),
          ),
          ActionChip(
            avatar: const Icon(Icons.download_for_offline),
            label: const Text('Mapa offline'),
            onPressed: s.tilesRunning
                ? null
                : () => s.prefetchTilesOnServer().then((_) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('Serwer pobiera mapę obszaru. Telefony ściągną ją od niego automatycznie.')));
                      }
                    }).catchError(_error),
          ),
        ],
      );
}
