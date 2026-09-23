import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lib/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App launches on the bridge home screen', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('Alexa Device Bridge'), findsOneWidget);
    expect(find.text('Shared Secret'), findsOneWidget);
    expect(find.text('Device Name'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });
}