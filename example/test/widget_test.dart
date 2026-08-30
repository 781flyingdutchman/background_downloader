import 'package:background_downloader_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('MyApp renders background_downloader UI components', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp());

    // Verify app bar title
    expect(find.text('background_downloader example'), findsOneWidget);

    // Verify main sections
    expect(find.text('Transfer Settings'), findsOneWidget);
    expect(find.text('Main Transfer Demo'), findsOneWidget);
    expect(find.text('Additional Transfer Workflows'), findsOneWidget);

    // Verify buttons
    expect(find.text('Start (getOrStart)'), findsOneWidget);
    expect(find.text('start'), findsOneWidget);
  });
}
