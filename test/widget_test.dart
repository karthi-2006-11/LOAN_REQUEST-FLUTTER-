import 'package:flutter_test/flutter_test.dart';
import 'package:loan_request_app/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('App renders splash screen initially', (WidgetTester tester) async {
    await tester.pumpWidget(const LoanRequestApp());
    expect(find.text('LOAN VERSE'), findsOneWidget);

    // Fast-forward past splash timer to dispose cleanly
    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pumpAndSettle();
  });
}
