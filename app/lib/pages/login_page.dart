import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../session.dart';
import 'map_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _server = TextEditingController();
  final _name = TextEditingController();
  final _code = TextEditingController();
  final _key = TextEditingController();
  bool _admin = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // wersja web jest serwowana przez sam serwer, więc domyślnie łączymy się z nim
    if (kIsWeb) _server.text = Uri.base.origin;
    SessionController.lastServer().then((s) {
      if (s != null && mounted) _server.text = s;
    });
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = _admin
          ? await SessionController.loginAsAdmin(_server.text, _key.text)
          : await SessionController.joinAsUser(_server.text, _name.text.trim(), _code.text.trim());
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => MapPage(session: s)));
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.travel_explore, size: 64),
                const SizedBox(height: 8),
                Text('GeoFinder', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 24),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Uczestnik'), icon: Icon(Icons.directions_walk)),
                    ButtonSegment(value: true, label: Text('Koordynator'), icon: Icon(Icons.admin_panel_settings)),
                  ],
                  selected: {_admin},
                  onSelectionChanged: (v) => setState(() => _admin = v.first),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _server,
                  decoration: const InputDecoration(labelText: 'Adres serwera', hintText: '192.168.1.10:8000'),
                  keyboardType: TextInputType.url,
                ),
                if (!_admin) ...[
                  TextField(controller: _name, decoration: const InputDecoration(labelText: 'Imię / ksywka')),
                  TextField(
                    controller: _code,
                    decoration: const InputDecoration(labelText: 'Kod dołączenia'),
                    keyboardType: TextInputType.number,
                  ),
                ] else
                  TextField(
                    controller: _key,
                    decoration: const InputDecoration(labelText: 'Klucz administratora'),
                    obscureText: true,
                  ),
                const SizedBox(height: 20),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: _busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_admin ? 'Zaloguj' : 'Dołącz do akcji'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
