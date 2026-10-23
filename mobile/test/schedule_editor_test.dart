import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protores/schedule_editor.dart';

void main() {
  final groups = [
    {'id': 1, 'name': '6°', 'active': true},
    {'id': 2, 'name': '7°', 'active': true},
  ];
  final turns = [
    {
      'id': 10,
      'group_id': 1,
      'group_name': '6°',
      'scheduled': '2026-10-23T12:00:00Z',
      'duration_seconds': 1800,
      'status': 'pending',
    },
    {
      'id': 11,
      'group_id': 2,
      'group_name': '7°',
      'scheduled': '2026-10-23T12:30:00Z',
      'duration_seconds': 1800,
      'status': 'pending',
    },
  ];
  testWidgets(
    'Precarga, detecta cruces y guarda horas y duraciones individuales',
    (tester) async {
      List<Map<String, dynamic>>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ScheduleEditor(
                      date: '2026-10-23',
                      groups: groups,
                      turns: turns,
                      onSave: (value) async {
                        saved = value;
                      },
                    ),
                  ),
                ),
                child: const Text('Editar'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Editar'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('turn-10-start')))
            .controller!
            .text,
        '07:00',
      );
      final minutes = find.byKey(const ValueKey('turn-10-minutes'));
      final secondStart = find.byKey(const ValueKey('turn-11-start'));
      await tester.enterText(minutes, '45');
      await tester.scrollUntilVisible(
        find.text('Guardar horarios'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guardar horarios'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(
        find.text('Ordena los horarios sin cruces y dentro del mismo día.'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        secondStart,
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.enterText(secondStart, '08:00');
      await tester.scrollUntilVisible(
        find.text('Guardar horarios'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guardar horarios'));
      await tester.pumpAndSettle();
      expect(saved, [
        {'id': 10, 'group_id': 1, 'start': '07:00', 'minutes': 45},
        {'id': 11, 'group_id': 2, 'start': '08:00', 'minutes': 30},
      ]);
      expect(find.text('Editar'), findsOneWidget);
    },
  );
  testWidgets(
    'Conserva el turno activo y mantiene el editor abierto ante conflicto',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ScheduleEditor(
            date: '2026-10-23',
            groups: groups,
            turns: [
              {...turns.first, 'status': 'active'},
              turns.last,
            ],
            onSave: (_) async {
              throw Exception('La jornada cambió. Vuelve a abrir el editor');
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextFormField>(find.byType(TextFormField).first).enabled,
        isFalse,
      );
      await tester.scrollUntilVisible(
        find.text('Guardar horarios'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guardar horarios'));
      await tester.pumpAndSettle();
      expect(find.textContaining('La jornada cambió'), findsOneWidget);
      expect(find.text('Horarios por grupo'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
