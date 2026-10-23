import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class ScheduleEditor extends StatefulWidget {
  const ScheduleEditor({
    super.key,
    required this.date,
    required this.groups,
    required this.turns,
    required this.onSave,
  });
  final String date;
  final List<dynamic> groups, turns;
  final Future<void> Function(List<Map<String, dynamic>>) onSave;
  @override
  State<ScheduleEditor> createState() => _ScheduleEditorState();
}

class _TurnDraft {
  _TurnDraft({
    required this.id,
    required this.groupId,
    required String start,
    required String minutes,
    this.locked = false,
  }) : start = TextEditingController(text: start),
       minutes = TextEditingController(text: minutes);
  final int id;
  int? groupId;
  final TextEditingController start, minutes;
  final bool locked;
  void dispose() {
    start.dispose();
    minutes.dispose();
  }
}

class _ScheduleEditorState extends State<ScheduleEditor> {
  final form = GlobalKey<FormState>();
  final rows = <_TurnDraft>[];
  final retired = <_TurnDraft>[];
  bool saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    for (final t in widget.turns) {
      rows.add(
        _TurnDraft(
          id: t['id'] as int,
          groupId: t['group_id'] as int,
          start: DateFormat('HH:mm').format(
            DateTime.parse(
              t['scheduled'],
            ).toUtc().subtract(const Duration(hours: 5)),
          ),
          minutes: '${t['duration_seconds'] ~/ 60}',
          locked: t['status'] != 'pending',
        ),
      );
    }
    if (rows.isEmpty) addRow();
  }

  void addRow() {
    var start = '07:00';
    if (rows.isNotEmpty) {
      final previous = rows.last;
      final parts = previous.start.text.split(':');
      final h = int.tryParse(parts.first),
          m = parts.length == 2 ? int.tryParse(parts.last) : null;
      if (h != null && m != null) {
        final total = h * 60 + m + (int.tryParse(previous.minutes.text) ?? 30);
        start =
            '${(total ~/ 60).toString().padLeft(2, '0')}:${(total % 60).toString().padLeft(2, '0')}';
      }
    }
    rows.add(_TurnDraft(id: 0, groupId: null, start: start, minutes: '30'));
  }

  @override
  void dispose() {
    for (final r in [...rows, ...retired]) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> save() async {
    if (saving || !form.currentState!.validate()) return;
    final used = <int>{};
    int previousEnd = -1;
    for (final row in rows) {
      if (!used.add(row.groupId!)) {
        setState(() => error = 'Cada grupo debe aparecer una sola vez.');
        return;
      }
      final p = row.start.text.split(':');
      final start = int.parse(p[0]) * 60 + int.parse(p[1]);
      final end = start + int.parse(row.minutes.text);
      if (start < previousEnd || end >= 1440) {
        setState(
          () =>
              error = 'Ordena los horarios sin cruces y dentro del mismo día.',
        );
        return;
      }
      previousEnd = end;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.onSave([
        for (final r in rows)
          {
            'id': r.id,
            'group_id': r.groupId,
            'start': r.start.text.trim(),
            'minutes': int.parse(r.minutes.text),
          },
      ]);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final available = <int, String>{
      for (final g in widget.groups.where((g) => g['active'] == true))
        g['id'] as int: g['name'] as String,
      for (final t in widget.turns)
        t['group_id'] as int: t['group_name'] as String,
    };
    return PopScope(
      canPop: !saving,
      child: Scaffold(
        appBar: AppBar(title: const Text('Horarios por grupo')),
        body: Form(
          key: form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                widget.date,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const Text(
                'Hora de Colombia. Puedes cambiar el curso, la hora y la duración de cada turno pendiente. Los turnos atendidos y el activo se conservan.',
              ),
              const SizedBox(height: 16),
              for (var i = 0; i < rows.length; i++)
                Card(
                  key: ObjectKey(rows[i]),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Turno ${i + 1}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            if (rows[i].locked)
                              const Icon(Icons.lock_outline)
                            else ...[
                              IconButton(
                                tooltip: 'Subir turno',
                                onPressed:
                                    saving || i == 0 || rows[i - 1].locked
                                    ? null
                                    : () => setState(() {
                                        final r = rows.removeAt(i);
                                        rows.insert(i - 1, r);
                                      }),
                                icon: const Icon(Icons.arrow_upward),
                              ),
                              IconButton(
                                tooltip: 'Bajar turno',
                                onPressed:
                                    saving ||
                                        i == rows.length - 1 ||
                                        rows[i + 1].locked
                                    ? null
                                    : () => setState(() {
                                        final r = rows.removeAt(i);
                                        rows.insert(i + 1, r);
                                      }),
                                icon: const Icon(Icons.arrow_downward),
                              ),
                              IconButton(
                                tooltip: 'Eliminar turno',
                                onPressed: saving || rows.length == 1
                                    ? null
                                    : () => setState(
                                        () => retired.add(rows.removeAt(i)),
                                      ),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ],
                        ),
                        DropdownButtonFormField<int>(
                          initialValue: rows[i].groupId,
                          decoration: const InputDecoration(labelText: 'Grupo'),
                          items: [
                            for (final g in available.entries)
                              DropdownMenuItem(
                                value: g.key,
                                child: Text(g.value),
                              ),
                          ],
                          onChanged: saving || rows[i].locked
                              ? null
                              : (v) => setState(() => rows[i].groupId = v),
                          validator: (v) =>
                              v == null ? 'Selecciona un grupo' : null,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: ValueKey('turn-${rows[i].id}-start'),
                          controller: rows[i].start,
                          enabled: !saving && !rows[i].locked,
                          decoration: const InputDecoration(
                            labelText: 'Hora de inicio (HH:MM)',
                            hintText: '07:00',
                          ),
                          keyboardType: TextInputType.datetime,
                          validator: (v) =>
                              RegExp(
                                r'^([01]\d|2[0-3]):[0-5]\d$',
                              ).hasMatch(v?.trim() ?? '')
                              ? null
                              : 'Escribe una hora válida, como 07:30',
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          key: ValueKey('turn-${rows[i].id}-minutes'),
                          controller: rows[i].minutes,
                          enabled: !saving && !rows[i].locked,
                          decoration: const InputDecoration(
                            labelText: 'Duración en minutos',
                          ),
                          keyboardType: TextInputType.number,
                          validator: (v) {
                            final n = int.tryParse(v ?? '');
                            return n == null || n < 1 || n > 120
                                ? 'Usa entre 1 y 120 minutos'
                                : null;
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              OutlinedButton.icon(
                onPressed: saving || rows.length >= 100
                    ? null
                    : () => setState(addRow),
                icon: const Icon(Icons.add),
                label: const Text('Añadir grupo'),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              FilledButton.icon(
                onPressed: saving ? null : save,
                icon: const Icon(Icons.save_outlined),
                label: Text(saving ? 'Guardando…' : 'Guardar horarios'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
