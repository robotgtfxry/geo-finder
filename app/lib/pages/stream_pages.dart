import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models.dart';
import '../session.dart';
import '../stream.dart';

/// Uczestnik: podgląd własnej kamery w trakcie nadawania.
class BroadcastPage extends StatefulWidget {
  final SessionController session;
  const BroadcastPage({super.key, required this.session});

  @override
  State<BroadcastPage> createState() => _BroadcastPageState();
}

class _BroadcastPageState extends State<BroadcastPage> {
  late final Broadcaster _b = Broadcaster(widget.session);
  String? _error;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _b.onChanged = () {
      if (mounted) setState(() {});
    };
    _b.start().then((_) {
      if (mounted) setState(() => _started = true);
    }).catchError((e) {
      if (mounted) setState(() => _error = 'Nie udało się włączyć kamery: $e');
    });
  }

  @override
  void dispose() {
    _b.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final online = widget.session.online;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(children: [
          Positioned.fill(
            child: _error != null
                ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center))
                : RTCVideoView(_b.renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: online ? Colors.red.shade700 : Colors.grey.shade800,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(children: [
                const Icon(Icons.fiber_manual_record, color: Colors.white, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    !online
                        ? 'Brak połączenia – koordynator nie widzi obrazu'
                        : !_started
                            ? 'Włączam kamerę…'
                            : _b.viewers == 0
                                ? 'NA ŻYWO · czekam, aż koordynator otworzy podgląd'
                                : 'NA ŻYWO · ogląda: ${_b.viewers}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ]),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _round(Icons.cameraswitch, 'Przełącz kamerę', Colors.white24, _b.switchCamera),
              _round(Icons.call_end, 'Zakończ', Colors.red, () => Navigator.pop(context), big: true),
              _round(_b.micOn ? Icons.mic : Icons.mic_off, _b.micOn ? 'Wycisz' : 'Włącz mikrofon',
                  _b.micOn ? Colors.white24 : Colors.orange, _b.toggleMic),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _round(IconData icon, String tip, Color bg, VoidCallback onTap, {bool big = false}) => Tooltip(
        message: tip,
        child: RawMaterialButton(
          onPressed: onTap,
          shape: const CircleBorder(),
          fillColor: bg,
          constraints: BoxConstraints.tightFor(width: big ? 76 : 58, height: big ? 76 : 58),
          child: Icon(icon, color: Colors.white, size: big ? 36 : 26),
        ),
      );
}

/// Koordynator: obraz na żywo od jednego uczestnika.
class ViewerPage extends StatefulWidget {
  final SessionController session;
  final AppUser user;
  const ViewerPage({super.key, required this.session, required this.user});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  Viewer? _v;

  SessionController get s => widget.session;

  @override
  void initState() {
    super.initState();
    s.addListener(_onSession);
    _connect();
  }

  void _connect() {
    final cid = s.live[widget.user.id];
    if (cid == null || _v?.cid == cid) return;
    _v?.stop();
    final v = Viewer(s, cid);
    v.onChanged = () {
      if (mounted) setState(() {});
    };
    _v = v;
    v.start();
  }

  void _onSession() {
    if (!mounted) return;
    _connect(); // uczestnik mógł wznowić transmisję po zerwaniu sieci
    setState(() {});
  }

  @override
  void dispose() {
    s.removeListener(_onSession);
    _v?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    final isLive = s.isLive(widget.user.id);
    final u = s.users[widget.user.id] ?? widget.user;
    final cell = u.lat == null ? null : s.settings.cellOf(u.lat!, u.lon!);
    final String? status = !isLive
        ? 'Transmisja zakończona'
        : v == null || v.state == ViewState.connecting
            ? 'Łączę z kamerą…'
            : v.state == ViewState.ended
                ? 'Połączenie przerwane'
                : null;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${u.name}${cell != null ? ' · kwadrat $cell' : ''}'),
        actions: [
          if (!isLive)
            TextButton.icon(
              icon: const Icon(Icons.videocam, color: Colors.white),
              label: const Text('Poproś ponownie', style: TextStyle(color: Colors.white)),
              onPressed: () => s.requestStream(u.id),
            ),
        ],
      ),
      body: Stack(children: [
        if (v != null) Positioned.fill(child: RTCVideoView(v.renderer)),
        if (status != null)
          Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (isLive && v?.state != ViewState.ended) const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 12),
              Text(status, style: const TextStyle(color: Colors.white, fontSize: 16)),
            ]),
          ),
        if (status == null)
          Positioned(
            top: 12,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              color: Colors.red,
              child: const Text('NA ŻYWO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),
      ]),
    );
  }
}
