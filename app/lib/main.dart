import 'package:flutter/material.dart';

import 'pages/login_page.dart';
import 'pages/map_page.dart';
import 'session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GeoFinderApp());
}

class GeoFinderApp extends StatelessWidget {
  const GeoFinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GeoFinder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true, brightness: Brightness.dark),
      home: const StartGate(),
    );
  }
}

/// Przywraca zapisaną sesję albo pokazuje ekran logowania.
class StartGate extends StatefulWidget {
  const StartGate({super.key});

  @override
  State<StartGate> createState() => _StartGateState();
}

class _StartGateState extends State<StartGate> {
  @override
  void initState() {
    super.initState();
    SessionController.restore().then((s) {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => s == null ? const LoginPage() : MapPage(session: s),
      ));
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Center(child: CircularProgressIndicator()));
}
