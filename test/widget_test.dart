import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:community_safe/main.dart';

void main() {
  testWidgets(
    'Login rejects an invalid email and empty password',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: AuthScreen(),
        ),
      );

      await tester.enterText(
        find.byType(TextFormField).first,
        'invalid-email',
      );

      final loginButton =
          find.widgetWithText(FilledButton, 'Log in');

      await tester.ensureVisible(loginButton);
      await tester.tap(loginButton);
      await tester.pumpAndSettle();

      expect(
        find.text('Please enter a valid email address.'),
        findsOneWidget,
      );
      expect(
        find.text('Please enter a password.'),
        findsOneWidget,
      );
    },
  );
}