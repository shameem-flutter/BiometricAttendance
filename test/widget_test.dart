import 'package:flutter_test/flutter_test.dart';
import 'package:odoo_mobile/main.dart';

void main() {
  testWidgets('App smoke test - verifies MaterialApp initializes', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.byType(MyApp), findsOneWidget);
    // Advance timers so SplashScreen transitions without leaving pending timers
    await tester.pump(const Duration(milliseconds: 3500));
    await tester.pumpAndSettle();
  });
}
