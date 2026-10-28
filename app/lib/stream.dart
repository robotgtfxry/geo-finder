import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'session.dart';

// Obraz z kamery idzie bezpośrednio z telefonu do koordynatora (WebRTC).
// W sieci lokalnej nie potrzeba internetu; serwer tylko przekazuje
// wiadomości zestawiające połączenie (oferta, odpowiedź, kandydaci ICE).

const _rtcConfig = {
  'iceServers': [
    // przydaje się, gdy serwer jest w internecie; w sieci lokalnej zbędny
    {'urls': 'stun:stun.l.google.com:19302'},
  ],
  'sdpSemantics': 'unified-plan',
};

RTCIceCandidate _candidate(Map<String, dynamic> m) =>
    RTCIceCandidate(m['candidate'] as String?, m['sdpMid'] as String?, m['sdpMLineIndex'] as int?);

/// Połączenie z jednym rozmówcą + kandydaci ICE, którzy przyszli za wcześnie.
class _Peer {
  final RTCPeerConnection pc;
  final List<RTCIceCandidate> early = [];
  bool remoteSet = false;
  _Peer(this.pc);

  Future<void> addCandidate(RTCIceCandidate c) async {
    if (remoteSet) {
      await pc.addCandidate(c);
    } else {
      early.add(c);
    }
  }

  Future<void> setRemote(RTCSessionDescription d) async {
    await pc.setRemoteDescription(d);
    remoteSet = true;
    for (final c in early) {
      await pc.addCandidate(c);
    }
    early.clear();
  }
}

/// Uczestnik: nadaje obraz z kamery każdemu koordynatorowi, który chce oglądać.
class Broadcaster {
  final SessionController s;
  final renderer = RTCVideoRenderer();
  MediaStream? _stream;
  final Map<String, _Peer> _viewers = {};
  StreamSubscription? _sub;
  String? _announcedCid;
  bool micOn = true;

  void Function()? onChanged;
  int get viewers => _viewers.length;

  Broadcaster(this.s);

  Future<void> start() async {
    await renderer.initialize();
    _stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {
        'facingMode': 'environment', // tylna kamera – pokazujemy teren, nie siebie
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
        'frameRate': {'ideal': 20},
      },
    });
    renderer.srcObject = _stream;
    _sub = s.rtcMessages.listen((m) => _onRtc(m.$1, m.$2));
    s.addListener(_reannounce);
    _reannounce();
  }

  /// Po zerwaniu i odnowieniu połączenia z serwerem trzeba na nowo ogłosić transmisję.
  void _reannounce() {
    if (s.online && s.myCid != null && s.myCid != _announcedCid) {
      if (s.sendWs({'type': 'live', 'live': true})) _announcedCid = s.myCid;
    }
  }

  Future<void> _onRtc(String from, Map<String, dynamic> d) async {
    switch (d['kind']) {
      case 'watch':
        await _viewers.remove(from)?.pc.close();
        final pc = await createPeerConnection(_rtcConfig);
        final peer = _Peer(pc);
        _viewers[from] = peer;
        for (final t in _stream!.getTracks()) {
          await pc.addTrack(t, _stream!);
        }
        pc.onIceCandidate = (c) => s.sendRtc(from, {'kind': 'ice', ...c.toMap()});
        pc.onConnectionState = (st) {
          if (st == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
              st == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
            _viewers.remove(from)?.pc.close();
            onChanged?.call();
          }
        };
        final offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        s.sendRtc(from, {'kind': 'offer', 'sdp': offer.sdp, 'type': offer.type});
        onChanged?.call();
      case 'answer':
        await _viewers[from]?.setRemote(RTCSessionDescription(d['sdp'] as String?, d['type'] as String?));
      case 'ice':
        await _viewers[from]?.addCandidate(_candidate(d));
      case 'bye':
        await _viewers.remove(from)?.pc.close();
        onChanged?.call();
    }
  }

  Future<void> switchCamera() async {
    final v = _stream?.getVideoTracks();
    if (v != null && v.isNotEmpty) await Helper.switchCamera(v.first);
  }

  void toggleMic() {
    micOn = !micOn;
    for (final t in _stream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      t.enabled = micOn;
    }
    onChanged?.call();
  }

  Future<void> stop() async {
    s.removeListener(_reannounce);
    await _sub?.cancel();
    s.setLive(false);
    for (final e in _viewers.entries) {
      s.sendRtc(e.key, {'kind': 'bye'});
      await e.value.pc.close();
    }
    _viewers.clear();
    for (final t in _stream?.getTracks() ?? const <MediaStreamTrack>[]) {
      await t.stop();
    }
    await _stream?.dispose();
    renderer.srcObject = null;
    await renderer.dispose();
  }
}

enum ViewState { connecting, live, ended }

/// Koordynator: ogląda obraz jednego uczestnika.
class Viewer {
  final SessionController s;
  final String cid; // połączenie nadającego uczestnika
  final renderer = RTCVideoRenderer();
  _Peer? _peer;
  StreamSubscription? _sub;
  ViewState state = ViewState.connecting;
  void Function()? onChanged;

  Viewer(this.s, this.cid);

  Future<void> start() async {
    await renderer.initialize();
    _sub = s.rtcMessages.where((m) => m.$1 == cid).listen((m) => _onRtc(m.$2));
    s.sendRtc(cid, {'kind': 'watch'});
  }

  void _set(ViewState v) {
    state = v;
    onChanged?.call();
  }

  Future<void> _onRtc(Map<String, dynamic> d) async {
    switch (d['kind']) {
      case 'offer':
        await _peer?.pc.close();
        final pc = await createPeerConnection(_rtcConfig);
        final peer = _Peer(pc);
        _peer = peer;
        pc.onTrack = (e) {
          if (e.streams.isNotEmpty) {
            renderer.srcObject = e.streams.first;
            _set(ViewState.live);
          }
        };
        pc.onIceCandidate = (c) => s.sendRtc(cid, {'kind': 'ice', ...c.toMap()});
        pc.onConnectionState = (st) {
          if (st == RTCPeerConnectionState.RTCPeerConnectionStateFailed) _set(ViewState.ended);
        };
        await peer.setRemote(RTCSessionDescription(d['sdp'] as String?, d['type'] as String?));
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        s.sendRtc(cid, {'kind': 'answer', 'sdp': answer.sdp, 'type': answer.type});
      case 'ice':
        await _peer?.addCandidate(_candidate(d));
      case 'bye':
        _set(ViewState.ended);
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    s.sendRtc(cid, {'kind': 'bye'});
    await _peer?.pc.close();
    renderer.srcObject = null;
    await renderer.dispose();
  }
}
