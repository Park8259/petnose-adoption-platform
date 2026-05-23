import 'package:flutter_test/flutter_test.dart';

import 'package:petnose_chat_visual_smoke/main.dart';

void main() {
  testWidgets('renders visual smoke harness title', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('PetNose Firebase Chat Visual Smoke'), findsOneWidget);
  });
}
