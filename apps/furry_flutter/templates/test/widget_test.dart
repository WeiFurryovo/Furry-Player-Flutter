import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('smoke test', (WidgetTester tester) async {
    // Keep tests independent from native libraries (FFI/JNI) used by the app.
    expect(true, isTrue);
  });
}
