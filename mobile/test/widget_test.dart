import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protores/main.dart';

void main() {
  testWidgets('Editar usuario precarga y valida los datos antes de guardar', (
    tester,
  ) async {
    Map<String, String>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showDialog<Map<String, String>>(
                  context: context,
                  builder: (_) => const UserEditDialog(
                    name: 'Docente inicial',
                    username: 'docente-1',
                  ),
                );
              },
              child: const Text('Abrir editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir editor'));
    await tester.pumpAndSettle();
    expect(find.text('Docente inicial'), findsOneWidget);
    expect(find.text('docente-1'), findsOneWidget);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), ' ');
    await tester.enterText(fields.at(1), 'ab');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(find.text('Escribe el nombre'), findsOneWidget);
    expect(result, isNull);
    await tester.enterText(fields.at(0), ' Docente corregido ');
    await tester.enterText(fields.at(1), ' DOCENTE-NUEVO ');
    await tester.tap(find.text('Guardar'));
    await tester.pumpAndSettle();
    expect(result, {'name': 'Docente corregido', 'username': 'docente-nuevo'});
  });

  testWidgets(
    'Una sesión nueva pide acceso y no ofrece controles administrativos',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(const ProtoresApp());
      await tester.pumpAndSettle();
      expect(find.text('Protores'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Ingresar'), findsOneWidget);
      expect(find.text('Administrar'), findsNothing);
      expect(
        find.text('Finalizar atención y llamar al siguiente'),
        findsNothing,
      );
      expect(find.byType(TextField), findsNWidgets(2));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
