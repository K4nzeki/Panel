import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:panel/models/entry.dart';
import 'package:panel/services/cover_cache.dart';
import 'package:panel/theme.dart';
import 'package:panel/widgets/common.dart';

void main() {
  // CoverImage watches the connection state, so it needs a ProviderScope.
  Widget wrap(Widget child, {bool dark = false}) => ProviderScope(
        child: MaterialApp(
          theme: dark ? AppTheme.dark() : AppTheme.light(),
          home: Scaffold(body: Center(child: child)),
        ),
      );

  testWidgets('StatusBadge shows the status label in both themes',
      (tester) async {
    for (final dark in [false, true]) {
      await tester.pumpWidget(wrap(const StatusBadge(EntryStatus.finished),
          dark: dark));
      expect(find.text('Finished'), findsOneWidget);
    }
  });

  testWidgets('CoverImage falls back to the title initial', (tester) async {
    await tester.pumpWidget(wrap(const CoverImage(
        url: null, title: 'berserk', width: 60, height: 90)));
    expect(find.text('B'), findsOneWidget);
  });

  testWidgets('CoverImage keeps the initial when a cover is refused, and '
      'reports it so the title looks its cover up again', (tester) async {
    CoverCache.resetForTest();
    addTearDown(CoverCache.resetForTest);
    final reported = <String>[];
    CoverCache.onBroken = reported.add;
    CoverCache.client = MockClient((_) async => http.Response('', 404));
    const url = 'https://site.test/covers/missing.jpg';

    await tester.pumpWidget(wrap(const CoverImage(
        url: url, title: 'omniscient reader', width: 60, height: 90)));
    // Let the (fake) download finish outside the test's fake clock.
    await tester.runAsync(() async {
      try {
        await CoverCache.bytes(url);
      } catch (_) {}
    });
    await tester.pump();

    expect(find.text('O'), findsOneWidget);
    expect(CoverCache.isBroken(url), isTrue);
    expect(reported, [url]);
  });

  testWidgets('EmptyState renders its action', (tester) async {
    await tester.pumpWidget(wrap(EmptyState(
      icon: Icons.inbox,
      title: 'Nothing here',
      message: 'Add something',
      action: FilledButton(onPressed: () {}, child: const Text('Add')),
    )));
    expect(find.text('Nothing here'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
  });
}
