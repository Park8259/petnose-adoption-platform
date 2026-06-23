import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nosetag_app/screens/dog_register_screen.dart';

void main() {
  test('dummy test', () {
    expect(1, 1);
  });

  testWidgets('dog register screen hides dev user id and debug rows', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: DogRegisterScreen()));

    expect(find.text('개발 user_id'), findsNothing);
    expect(find.text('dog_id'), findsNothing);
    expect(find.text('profile_image_url'), findsNothing);
    expect(find.text('강아지 사진'), findsOneWidget);
    expect(find.text('사진 추가'), findsOneWidget);
    expect(find.text('얼굴·코 확인용 정면 사진'), findsOneWidget);
    expect(find.text('강아지 얼굴과 코가 잘 보이는 정면 사진을 1장 추가해주세요.'), findsOneWidget);
    expect(find.textContaining('다음 단계에서 코 영역을 확인합니다'), findsNothing);
    expect(find.text('비문 촬영하기'), findsOneWidget);
  });
}
