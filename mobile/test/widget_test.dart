import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protores/main.dart';

void main() {
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
