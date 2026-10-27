// Smoke test: the store app builds its root widget and renders the splash
// screen. (The old counter test was a leftover from the project template.)
// runAsync lets the splash's permission/navigation timers run as real async
// work so the test binding doesn't trip over pending FakeAsync timers.

import 'package:flutter_test/flutter_test.dart';

import 'package:maharo_store/app.dart';

void main() {
  testWidgets('MaharoStoreApp renders splash screen', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const MaharoStoreApp());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    });
    expect(find.byType(MaharoStoreApp), findsOneWidget);
    expect(find.text('Maharo Store'), findsWidgets);
  });
}
