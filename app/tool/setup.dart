// Generuje katalogi platform i dopisuje uprawnienia potrzebne GeoFinderowi.
// Uruchom w katalogu app/:   dart run tool/setup.dart
// Skrypt można odpalać wielokrotnie – niczego nie dubluje.
import 'dart:io';

void main() async {
  final create = await Process.run(
    'flutter',
    ['create', '.', '--project-name', 'geofinder', '--org', 'pl.geofinder',
     '--platforms', 'android,ios,web,windows,macos,linux'],
    runInShell: true,
  );
  stdout.write(create.stdout);
  stderr.write(create.stderr);
  // na Windows bez trybu dewelopera `flutter create` kończy się ostrzeżeniem o
  // symlinkach, ale pliki platform już powstały – łatamy je mimo to
  if (create.exitCode != 0 && !Directory('android').existsSync()) exit(create.exitCode);

  _android();
  _ios();
  _macos();
  stdout.writeln('\nGotowe. Teraz: flutter pub get && flutter run');
}

void _patch(String path, String Function(String) fn) {
  final f = File(path);
  if (!f.existsSync()) {
    stdout.writeln('pomijam (brak pliku): $path');
    return;
  }
  final before = f.readAsStringSync();
  final after = fn(before);
  if (after != before) {
    f.writeAsStringSync(after);
    stdout.writeln('zaktualizowano: $path');
  }
}

void _android() {
  const perms = [
    'android.permission.INTERNET',
    'android.permission.ACCESS_FINE_LOCATION',
    'android.permission.ACCESS_COARSE_LOCATION',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_LOCATION',
    'android.permission.POST_NOTIFICATIONS',
    'android.permission.WAKE_LOCK',
    'android.permission.VIBRATE',
    // kamera na żywo (WebRTC)
    'android.permission.CAMERA',
    'android.permission.RECORD_AUDIO',
    'android.permission.MODIFY_AUDIO_SETTINGS',
    'android.permission.ACCESS_NETWORK_STATE',
    'android.permission.CHANGE_NETWORK_STATE',
  ];
  _patch('android/app/src/main/AndroidManifest.xml', (s) {
    for (final p in perms) {
      if (!s.contains('"$p"')) {
        s = s.replaceFirst('<application', '<uses-permission android:name="$p"/>\n    <application');
      }
    }
    if (!s.contains('usesCleartextTraffic')) {
      // serwer w terenie zwykle działa po http w sieci lokalnej
      s = s.replaceFirst('<application', '<application\n        android:usesCleartextTraffic="true"');
    }
    return s;
  });

  // flutter_local_notifications wymaga desugaringu bibliotek Javy
  _patch('android/app/build.gradle.kts', (s) {
    if (s.contains('isCoreLibraryDesugaringEnabled')) return s;
    s = s.replaceFirst('compileOptions {', 'compileOptions {\n        isCoreLibraryDesugaringEnabled = true');
    return '$s\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n}\n';
  });
  _patch('android/app/build.gradle', (s) {
    if (s.contains('coreLibraryDesugaringEnabled')) return s;
    s = s.replaceFirst('compileOptions {', 'compileOptions {\n        coreLibraryDesugaringEnabled true');
    return "$s\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n";
  });
}

String _plistKeys(String s, Map<String, String> entries) {
  for (final e in entries.entries) {
    if (s.contains('<key>${e.key}</key>')) continue;
    final i = s.lastIndexOf('</dict>');
    s = '${s.substring(0, i)}\t<key>${e.key}</key>\n\t${e.value}\n${s.substring(i)}';
  }
  return s;
}

const _why = '<string>GeoFinder zapisuje przeszukany teren i Twoją pozycję dla koordynatora akcji.</string>';

void _ios() {
  _patch('ios/Runner/Info.plist', (s) => _plistKeys(s, {
        'NSLocationWhenInUseUsageDescription': _why,
        'NSLocationAlwaysAndWhenInUseUsageDescription': _why,
        'NSCameraUsageDescription': _whyCamera,
        'NSMicrophoneUsageDescription': _whyCamera,
        'UIBackgroundModes': '<array>\n\t\t<string>location</string>\n\t</array>',
        'NSAppTransportSecurity': '<dict>\n\t\t<key>NSAllowsArbitraryLoads</key>\n\t\t<true/>\n\t</dict>',
      }));
}

const _whyCamera = '<string>Na prośbę koordynatora możesz przesłać mu obraz z kamery na żywo.</string>';

void _macos() {
  _patch('macos/Runner/Info.plist', (s) => _plistKeys(s, {
        'NSLocationUsageDescription': _why,
        'NSCameraUsageDescription': _whyCamera,
        'NSMicrophoneUsageDescription': _whyCamera,
      }));
  for (final f in ['macos/Runner/DebugProfile.entitlements', 'macos/Runner/Release.entitlements']) {
    _patch(f, (s) => _plistKeys(s, {
          'com.apple.security.network.client': '<true/>',
          'com.apple.security.personal-information.location': '<true/>',
          'com.apple.security.device.camera': '<true/>',
          'com.apple.security.device.audio-input': '<true/>',
        }));
  }
}
