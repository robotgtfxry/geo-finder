import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models.dart';
import '../session.dart';

Future<bool> confirm(BuildContext context, String text) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Tak')),
        ],
      ),
    ) ??
    false;

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

String _time(double t) {
  final d = DateTime.fromMillisecondsSinceEpoch((t * 1000).round());
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(d.hour)}:${two(d.minute)}';
}

// ------------------------------------------------------------------ zgłoszenie

Future<void> showReportDialog(BuildContext context, SessionController s, LatLng at) async {
  final text = TextEditingController();
  var category = s.categories.keys.isNotEmpty ? s.categories.keys.first : 'other';
  final cell = s.settings.cellOf(at.latitude, at.longitude);
  final send = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(cell != null ? 'Zgłoszenie – kwadrat $cell' : 'Zgłoszenie (poza siatką)'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final e in s.categories.entries)
              ChoiceChip(
                avatar: Icon(categoryIcons[e.key], size: 18),
                label: Text(e.value),
                selected: category == e.key,
                onSelected: (_) => setState(() => category = e.key),
              ),
          ]),
          TextField(
            controller: text,
            autofocus: true,
            maxLength: 500,
            maxLines: 3,
            minLines: 1,
            decoration: const InputDecoration(labelText: 'Opis (co, jak wygląda, kierunek…)'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Wyślij do wszystkich')),
        ],
      ),
    ),
  );
  if (send != true) return;
  try {
    final r = await s.sendReport(at, category, text.text);
    if (context.mounted) _snack(context, 'Wysłano: ${r.message}');
  } catch (e) {
    if (context.mounted) _snack(context, 'Nie wysłano zgłoszenia: $e');
  }
}

Future<void> showReportDetails(BuildContext context, SessionController s, Report r) => showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(categoryIcons[r.category], color: categoryColors[r.category]),
        title: Text(r.message),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (r.text.isNotEmpty) Text(r.text),
          const SizedBox(height: 8),
          Text('${r.userName}, ${_time(r.t)}', style: Theme.of(ctx).textTheme.bodySmall),
          Text('${r.lat.toStringAsFixed(6)}, ${r.lon.toStringAsFixed(6)}', style: Theme.of(ctx).textTheme.bodySmall),
        ]),
        actions: [
          if (s.isAdmin)
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                if (await confirm(context, 'Usunąć zgłoszenie?')) s.deleteReport(r.id);
              },
              child: const Text('Usuń'),
            ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );

Future<void> showReportsSheet(BuildContext context, SessionController s, {required void Function(Report) onSelect}) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        builder: (ctx, scroll) => ListenableBuilder(
          listenable: s,
          builder: (ctx, _) {
            final list = s.reports.reversed.toList();
            if (list.isEmpty) return const Center(child: Text('Brak zgłoszeń'));
            return ListView.builder(
              controller: scroll,
              itemCount: list.length,
              itemBuilder: (ctx, i) {
                final r = list[i];
                return ListTile(
                  leading: Icon(categoryIcons[r.category], color: categoryColors[r.category]),
                  title: Text(r.message),
                  subtitle: Text([if (r.text.isNotEmpty) r.text, '${r.userName}, ${_time(r.t)}'].join('\n')),
                  isThreeLine: r.text.isNotEmpty,
                  onTap: () {
                    Navigator.pop(ctx);
                    onSelect(r);
                  },
                  trailing: s.isAdmin
                      ? IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            if (await confirm(ctx, 'Usunąć zgłoszenie?')) s.deleteReport(r.id);
                          },
                        )
                      : null,
                );
              },
            );
          },
        ),
      ),
    );

// ------------------------------------------------------------------ kalibracja

Future<void> showCalibrationDialog(BuildContext context, SessionController s) async {
  final ref = s.settings.calib;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Kalibracja GPS'),
      content: Text(ref != null
          ? 'Stań dokładnie w punkcie kalibracyjnym (czarny celownik na mapie) i nie ruszaj się przez 30 sekund. '
              'Telefon trzymaj poziomo, z dala od samochodu i budynków.'
          : 'Koordynator nie ustawił punktu kalibracyjnego – sprawdzę tylko jakość sygnału GPS. '
              'Stój w miejscu przez 30 sekund.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Anuluj')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start')),
      ],
    ),
  );
  if (go != true || !context.mounted) return;

  final future = s.calibrate();
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => ListenableBuilder(
      listenable: s,
      builder: (ctx, _) {
        final run = s.calibration;
        return AlertDialog(
          title: const Text('Kalibruję…'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(value: run?.progress ?? 1),
            const SizedBox(height: 12),
            Text('Odczyty: ${run?.samples.length ?? 0}'
                '${s.myFix != null ? ' · dokładność ±${s.myFix!.acc.round()} m' : ''}'),
          ]),
        );
      },
    ),
  );
  final result = await future;
  if (!context.mounted) return;
  Navigator.of(context, rootNavigator: true).pop();
  await showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(result.ok ? Icons.check_circle : Icons.error, color: result.ok ? Colors.green : Colors.red),
      title: Text(result.ok ? 'Skalibrowano' : 'Kalibracja nieudana'),
      content: Text(result.message),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
    ),
  );
}

// ------------------------------------------------------------------ siatka (admin)

Future<void> showGridDialog(BuildContext context, SessionController s) async {
  final st = s.settings;
  final name = TextEditingController(text: st.name);
  final cols = TextEditingController(text: '${st.cols}');
  final rows = TextEditingController(text: '${st.rows}');
  final size = TextEditingController();
  final radius = TextEditingController(text: '${st.defaultRadius.round()}');
  final maxAcc = TextEditingController(text: '${st.maxAccuracy.round()}');
  Map<String, dynamic>? fittedArea;

  Widget numField(TextEditingController c, String label, {String? suffix}) => TextField(
        controller: c,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label, suffixText: suffix),
      );

  final save = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
      final a = st.area;
      final c = int.tryParse(cols.text) ?? st.cols, r = int.tryParse(rows.text) ?? st.rows;
      return AlertDialog(
        title: const Text('Siatka i parametry'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Nazwa akcji')),
            const SizedBox(height: 8),
            if (a == null)
              const Text('Najpierw zaznacz obszar na mapie (przycisk „Obszar”).', style: TextStyle(color: Colors.red))
            else
              Text('Obszar ${a.widthM.round()} × ${a.heightM.round()} m'
                  ' → kwadrat ≈ ${(a.widthM / c).round()} × ${(a.heightM / r).round()} m'),
            Row(children: [
              Expanded(child: numField(cols, 'Kolumny (A, B, C…)')),
              const SizedBox(width: 12),
              Expanded(child: numField(rows, 'Wiersze (1, 2, 3…)')),
            ]),
            Row(children: [
              Expanded(child: numField(size, 'albo bok kwadratu', suffix: 'm')),
              TextButton(
                onPressed: a == null
                    ? null
                    : () {
                        final m = double.tryParse(size.text);
                        if (m == null || m < 5) return;
                        final nc = (a.widthM / m).ceil(), nr = (a.heightM / m).ceil();
                        if (nc > 200 || nr > 200) return _snack(ctx, 'Za dużo kwadratów – zwiększ bok');
                        // rozszerzamy obszar na wschód i południe, żeby kwadraty miały dokładnie zadany bok
                        fittedArea = {
                          'north': a.north,
                          'west': a.west,
                          'east': a.west + nc * m / mPerDegLon(a.midLat),
                          'south': a.north - nr * m / mPerDegLat,
                        };
                        setState(() {
                          cols.text = '$nc';
                          rows.text = '$nr';
                        });
                      },
                child: const Text('Dopasuj'),
              ),
            ]),
            const Divider(height: 24),
            numField(radius, 'Domyślny promień nowych uczestników', suffix: 'm'),
            numField(maxAcc, 'Odrzucaj pozycje GPS gorsze niż', suffix: 'm'),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Zapisz')),
        ],
      );
    }),
  );
  if (save != true) return;
  try {
    await s.updateSettings({
      'name': name.text.trim().isEmpty ? st.name : name.text.trim(),
      'cols': int.tryParse(cols.text) ?? st.cols,
      'rows': int.tryParse(rows.text) ?? st.rows,
      'default_radius': double.tryParse(radius.text) ?? st.defaultRadius,
      'max_accuracy': double.tryParse(maxAcc.text) ?? st.maxAccuracy,
      if (fittedArea != null) 'area': fittedArea,
    });
  } catch (e) {
    if (context.mounted) _snack(context, 'Nie zapisano: $e');
  }
}

// ------------------------------------------------------------------ uczestnicy (admin)

const _palette = [
  '#e6194b', '#3cb44b', '#4363d8', '#f58231', '#911eb4', '#42d4f4', '#f032e6',
  '#9a6324', '#800000', '#808000', '#000075', '#469990', '#bfef45', '#dcbeff',
];

Future<void> showUsersSheet(BuildContext context, SessionController s, {required void Function(AppUser) onSelect}) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, scroll) => _UsersList(s: s, scroll: scroll, onSelect: onSelect),
      ),
    );

class _UsersList extends StatefulWidget {
  final SessionController s;
  final ScrollController scroll;
  final void Function(AppUser) onSelect;
  const _UsersList({required this.s, required this.scroll, required this.onSelect});

  @override
  State<_UsersList> createState() => _UsersListState();
}

class _UsersListState extends State<_UsersList> {
  final _radius = <int, TextEditingController>{};

  @override
  void dispose() {
    for (final c in _radius.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickColor(AppUser u) async {
    final hex = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(title: Text('Kolor: ${u.name}'), children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final h in _palette)
              InkWell(
                onTap: () => Navigator.pop(ctx, h),
                child: CircleAvatar(backgroundColor: parseColor(h), radius: 18),
              ),
          ]),
        ),
      ]),
    );
    if (hex != null) widget.s.updateUser(u.id, {'color': hex});
  }

  Future<void> _saveRadius(AppUser u, String text) async {
    final r = double.tryParse(text.replaceAll(',', '.'));
    if (r == null || r <= 0 || r > 500) return _snack(context, 'Promień musi być w zakresie 1–500 m');
    try {
      await widget.s.updateUser(u.id, {'radius': r});
      if (mounted) _snack(context, '${u.name}: promień ${r.round()} m');
    } catch (e) {
      if (mounted) _snack(context, 'Błąd: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final users = s.users.values.toList();
        if (users.isEmpty) {
          return Center(child: Text('Nikt jeszcze nie dołączył.\nKod: ${s.joinCode ?? '—'}', textAlign: TextAlign.center));
        }
        return ListView(
          controller: widget.scroll,
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const ListTile(
              dense: true,
              title: Text('Promień = szerokość „mazaka”, którym osoba zamalowuje przeszukany teren.'),
            ),
            for (final u in users)
              ListTile(
                leading: InkWell(
                  onTap: () => _pickColor(u),
                  child: CircleAvatar(backgroundColor: u.color, child: Icon(u.stale ? Icons.signal_wifi_off : Icons.person, color: Colors.white)),
                ),
                title: Text(u.name),
                subtitle: Text(
                  'Widziany ${ago(u.lastSeen)}${u.acc != null ? ', GPS ±${u.acc!.round()} m' : ''}\n'
                  '${u.calib != null ? 'Kalibracja ${ago((u.calib!['t'] as num).toDouble())}, rozrzut ±${(u.calib!['spread'] as num).toStringAsFixed(1)} m' : 'Bez kalibracji'}',
                ),
                isThreeLine: true,
                onTap: u.lat == null
                    ? null
                    : () {
                        Navigator.pop(context);
                        widget.onSelect(u);
                      },
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                    width: 64,
                    child: TextField(
                      controller: _radius.putIfAbsent(u.id, () => TextEditingController(text: '${u.radius.round()}')),
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.end,
                      decoration: const InputDecoration(suffixText: 'm', isDense: true),
                      onSubmitted: (v) => _saveRadius(u, v),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Usuń z akcji',
                    icon: const Icon(Icons.person_remove_outlined),
                    onPressed: () async {
                      if (await confirm(context, 'Usunąć ${u.name}? Przeszukany przez nią/niego teren zostaje na mapie.')) {
                        s.deleteUser(u.id);
                      }
                    },
                  ),
                ]),
              ),
          ],
        );
      },
    );
  }
}
