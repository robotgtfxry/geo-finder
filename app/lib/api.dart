import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => message;
}

class Api {
  final String base;
  final String token;
  Api(this.base, this.token);

  static String normalize(String url) {
    var u = url.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'http://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  static Future<Map<String, dynamic>> join(String base, String name, String code) async {
    final r = await http
        .post(Uri.parse('$base/api/join'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'name': name, 'code': code}))
        .timeout(const Duration(seconds: 10));
    return _decode(r) as Map<String, dynamic>;
  }

  Map<String, String> get _headers =>
      {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};

  Future<dynamic> get(String path) => _send(http.get(Uri.parse('$base$path'), headers: _headers));
  Future<dynamic> post(String path, [Object? body]) =>
      _send(http.post(Uri.parse('$base$path'), headers: _headers, body: jsonEncode(body ?? {})));
  Future<dynamic> put(String path, Object body) =>
      _send(http.put(Uri.parse('$base$path'), headers: _headers, body: jsonEncode(body)));
  Future<dynamic> delete(String path) => _send(http.delete(Uri.parse('$base$path'), headers: _headers));

  Future<dynamic> _send(Future<http.Response> req) async =>
      _decode(await req.timeout(const Duration(seconds: 15)));

  static dynamic _decode(http.Response r) {
    final body = utf8.decode(r.bodyBytes);
    if (r.statusCode >= 200 && r.statusCode < 300) return body.isEmpty ? null : jsonDecode(body);
    var msg = 'Błąd serwera (${r.statusCode})';
    try {
      final detail = jsonDecode(body)['detail'];
      msg = detail is String ? detail : jsonEncode(detail);
    } catch (_) {}
    throw ApiException(r.statusCode, msg);
  }

  WebSocketChannel webSocket() {
    final wsBase = base.replaceFirst(RegExp(r'^http'), 'ws');
    return WebSocketChannel.connect(Uri.parse('$wsBase/ws?token=${Uri.encodeComponent(token)}'));
  }
}
