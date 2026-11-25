import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:panel/models/entry.dart';
import 'package:panel/theme.dart';
import 'package:panel/widgets/common.dart';

void main() {
  Widget wrap(Widget child, {bool dark = false}) => MaterialApp(
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        home: Scaffold(body: Center(child: child)),
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
