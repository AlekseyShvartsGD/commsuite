import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:commsuite/widgets/user_avatar.dart';

void main() {
  testWidgets('UserAvatar renders initials', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SizedBox(child: UserAvatar(name: 'Jane Doe', seed: 'jane'))),
    );

    expect(find.text('JD'), findsOneWidget);
  });
}