import 'package:flutter/material.dart';

import '../models.dart';
import '../session.dart';
import 'dialogs.dart';

/// Akcje, które menu uczestnika zleca ekranowi mapy.
class UserActions {
  final void Function(AppUser) showOnMap;
  final void Function(AppUser) watch;
  const UserActions({required this.showOnMap, required this.watch});
}

const palette = [
  '#e6194b', '#3cb44b', '#4363d8', '#f58231', '#911eb4', '#42d4f4', '#f032e6',
  '#9a6324', '#800000', '#808000', '#000075', '#469990', '#bfef45', '#ffe119',
];

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

// ------------------------------------------------------------------ lista uczestników

Future<void> showUsersSheet(BuildContext context, SessionController s, UserActions actions) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (ctx, scroll) => ListenableBuilder(
          listenable: s,
          builder: (ctx, _) {
            final users = s.users.values.toList()
              ..sort((a, b) => (s.isLive(b.id) ? 1 : 0).compareTo(s.isLive(a.id) ? 1 : 0));
            if (users.isEmpty) {
              return Center(
                child: Text('Nikt jeszcze nie dołączył.\nKod dołączenia: ${s.joinCode ?? '—'}', textAlign: TextAlign.center),
              );
            }
            return ListView(controller: scroll, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('Uczestnicy (${users.length}) – dotknij, aby edytować',
                    style: Theme.of(ctx).textTheme.titleMedium),
              ),
              for (final u in users)
                ListTile(
                  leading: _Dot(u: u, live: s.isLive(u.id)),
                  title: Text(u.name),
                  subtitle: Text(_statusLine(s, u)),
                  trailing: s.isLive(u.id)
                      ? FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: Colors.red),
                          icon: const Icon(Icons.videocam, size: 18),
                          label: const Text('Oglądaj'),
                          onPressed: () {
                            Navigator.pop(ctx);
                            actions.watch(u);
                          },
                        )
                      : Text('${u.radius.round()} m'),
                  onTap: () => showUserMenu(ctx, s, u.id, actions),
                ),
            ]);
          },
        ),
      ),
    );

String _statusLine(SessionController s, AppUser u) {
  final cell = u.lat == null ? null : s.settings.cellOf(u.lat!, u.lon!);
  return [
    if (s.isLive(u.id)) 'NA ŻYWO',
    u.stale ? 'bez sieci ${ago(u.lastSeen)}' : 'aktywny',
    if (cell != null) 'kwadrat $cell',
    if (u.acc != null && !u.stale) 'GPS ±${u.acc!.round()} m',
  ].join(' · ');
}

class _Dot extends StatelessWidget {
  final AppUser u;
  final bool live;
  final double size;
  const _Dot({required this.u, required this.live, this.size = 40});

  @override
  Widget build(BuildContext context) => Badge(
        isLabelVisible: live,
        backgroundColor: Colors.red,
        label: const Icon(Icons.videocam, size: 10, color: Colors.white),
        child: CircleAvatar(
          radius: size / 2,
          backgroundColor: u.stale ? u.color.withValues(alpha: 0.4) : u.color,
          child: Text(
            u.name.isEmpty ? '?' : u.name.characters.first.toUpperCase(),
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: size * 0.4),
          ),
        ),
      );
}

// ------------------------------------------------------------------ menu jednej osoby

Future<void> showUserMenu(BuildContext context, SessionController s, int userId, UserActions actions) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _UserMenu(s: s, userId: userId, actions: actions),
    );

class _UserMenu extends StatefulWidget {
  final SessionController s;
  final int userId;
  final UserActions actions;
  const _UserMenu({required this.s, required this.userId, required this.actions});

  @override
  State<_UserMenu> createState() => _UserMenuState();
}

class _UserMenuState extends State<_UserMenu> {
  late final TextEditingController _name;
  double? _radius; // w trakcie przesuwania suwaka

  SessionController get s => widget.s;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: s.users[widget.userId]?.name ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save(Map<String, dynamic> patch, String done) async {
    try {
      await s.updateUser(widget.userId, patch);
      if (mounted) _snack(context, done);
    } catch (e) {
      if (mounted) _snack(context, 'Nie zapisano: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final u = s.users[widget.userId];
        if (u == null) return const SizedBox(height: 120, child: Center(child: Text('Uczestnik usunięty')));
        final isLive = s.isLive(u.id);
        final radius = _radius ?? u.radius.clamp(1, 50).toDouble();
        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                _Dot(u: u, live: isLive, size: 52),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(u.name, style: Theme.of(context).textTheme.titleLarge),
                    Text(_statusLine(s, u)),
                    Text(u.calib != null ? 'Skalibrowany ${ago((u.calib!['t'] as num).toDouble())}' : 'Bez kalibracji GPS',
                        style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
              ]),
              const SizedBox(height: 16),

              // --- akcje
              Row(children: [
                Expanded(
                  child: isLive
                      ? FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: Colors.red, minimumSize: const Size(0, 48)),
                          icon: const Icon(Icons.videocam),
                          label: const Text('Oglądaj na żywo'),
                          onPressed: () {
                            Navigator.pop(context);
                            widget.actions.watch(u);
                          },
                        )
                      : FilledButton.tonalIcon(
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                          icon: const Icon(Icons.videocam_outlined),
                          label: const Text('Poproś o kamerę'),
                          onPressed: u.stale
                              ? null
                              : () {
                                  final sent = s.requestStream(u.id);
                                  _snack(context, sent
                                      ? 'Wysłano prośbę do ${u.name}. Podgląd otworzy się sam, gdy włączy kamerę.'
                                      : 'Brak połączenia z serwerem');
                                },
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                    icon: const Icon(Icons.place),
                    label: const Text('Pokaż na mapie'),
                    onPressed: u.lat == null
                        ? null
                        : () {
                            Navigator.of(context).popUntil((r) => r.isFirst);
                            widget.actions.showOnMap(u);
                          },
                  ),
                ),
              ]),
              const Divider(height: 32),

              // --- nazwa
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _name,
                    maxLength: 40,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(labelText: 'Nazwa'),
                    onSubmitted: (v) => _saveName(u),
                  ),
                ),
                IconButton.filledTonal(icon: const Icon(Icons.check), tooltip: 'Zapisz nazwę', onPressed: () => _saveName(u)),
              ]),

              // --- kolor kropki
              const SizedBox(height: 8),
              Text('Kolor kropki i śladu', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(spacing: 10, runSpacing: 10, children: [
                for (final hex in palette)
                  GestureDetector(
                    onTap: () => _save({'color': hex}, 'Zmieniono kolor'),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: parseColor(hex),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: colorToHex(u.color) == hex ? Theme.of(context).colorScheme.onSurface : Colors.transparent,
                          width: 3,
                        ),
                      ),
                      child: colorToHex(u.color) == hex ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                    ),
                  ),
              ]),

              // --- promień
              const SizedBox(height: 20),
              Text('Promień przeszukiwania („mazak”): ${radius.round()} m  → pas ${(radius * 2).round()} m',
                  style: Theme.of(context).textTheme.labelLarge),
              Slider(
                value: radius,
                min: 1,
                max: 50,
                divisions: 49,
                label: '${radius.round()} m',
                onChanged: (v) => setState(() => _radius = v),
                onChangeEnd: (v) async {
                  await _save({'radius': v.roundToDouble()}, '${u.name}: promień ${v.round()} m');
                  if (mounted) setState(() => _radius = null);
                },
              ),
              const Text('Las gęsty 3–5 m · las rzadki 8–12 m · pole, łąka 15–25 m',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),

              const Divider(height: 32),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                icon: const Icon(Icons.person_remove_outlined),
                label: const Text('Usuń z akcji'),
                onPressed: () async {
                  if (await confirm(context, 'Usunąć ${u.name}? Przeszukany przez tę osobę teren zostaje na mapie.')) {
                    await s.deleteUser(u.id);
                    if (context.mounted) Navigator.pop(context);
                  }
                },
              ),
            ]),
          ),
        );
      },
    );
  }

  void _saveName(AppUser u) {
    final n = _name.text.trim();
    if (n.isEmpty || n == u.name) return;
    _save({'name': n}, 'Zmieniono nazwę na „$n”');
  }
}
