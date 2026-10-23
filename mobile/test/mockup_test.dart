import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protores/main.dart';

class SchoolApi extends Api {
  SchoolApi(this.role);
  final String role;
  bool registered = false;
  final calls = <String>[];
  @override
  Future<dynamic> call(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? data,
  }) async {
    calls.add('$method $path');
    if (path == '/me') return {'id': 1, 'name': 'Ana', 'role': role};
    if (path == '/status') {
      return {
        'server_time': DateTime.now().toUtc().toIso8601String(),
        'day': {
          'id': 1,
          'date': '2026-10-23',
          'status': 'running',
          'version': 1,
          'turns': [
            {
              'id': 8,
              'group_id': 8,
              'group_name': '8°',
              'teacher_id': 1,
              'status': 'active',
              'duration_seconds': 1800,
              'paused_seconds': 0,
              'scheduled': '2026-10-23T13:00:00Z',
            },
            {
              'id': 9,
              'group_id': 9,
              'group_name': '9°',
              'teacher_id': 2,
              'status': 'pending',
              'duration_seconds': 1800,
              'paused_seconds': 0,
              'scheduled': '2026-10-23T13:30:00Z',
            },
          ],
        },
      };
    }
    if (path == '/students') {
      return [
        {
          'id': 1,
          'name': 'María López',
          'code': 'EST-001',
          'group_id': 8,
          'group_name': '8°',
          'registered_at': registered ? '2026-10-23T13:12:00Z' : null,
        },
      ];
    }
    if (path == '/attendance') {
      registered = true;
      return {'name': 'María López'};
    }
    return [];
  }
}

void main() {
  for (final role in ['admin', 'teacher', 'student']) {
    testWidgets('Navegación del mockup y permisos: $role', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      FlutterSecureStorage.setMockInitialValues({'token': 'test'});
      final api = SchoolApi(role);
      await tester.pumpWidget(MaterialApp(home: Home(api: api)));
      await tester.pumpAndSettle();
      expect(find.text('Horarios de turnos'), findsOneWidget);
      await tester.tap(find.text('Turno actual'));
      await tester.pumpAndSettle();
      expect(find.text('TURNO ACTUAL'), findsOneWidget);
      expect(find.text('Siguiente turno:'), findsOneWidget);
      await tester.tap(find.text('Registro'));
      await tester.pumpAndSettle();
      if (role == 'student') {
        expect(find.text('ESCANEAR'), findsNothing);
        expect(api.calls.contains('GET /students'), isFalse);
      } else {
        expect(find.text('ESCANEAR'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'EST-001');
        await tester.pumpAndSettle();
        await Scrollable.ensureVisible(
          tester.element(find.text('Registrar')),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Registrar'));
        await tester.pumpAndSettle();
        expect(api.registered, isTrue);
        expect(find.text('Registrar'), findsNothing);
      }
      await tester.tap(find.text('Encargado'));
      await tester.pumpAndSettle();
      expect(
        find.text('CAMBIAR TURNO'),
        role == 'admin' ? findsOneWidget : findsNothing,
      );
      if (role != 'student') {
        expect(find.text('100% de asistencia'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
