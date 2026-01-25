import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:furry_flutter_app/main.dart';

void main() {
  testWidgets('app boots', (WidgetTester tester) async {
    await tester.pumpWidget(const FurryApp());
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}

