import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onedrop/screens/file_explorer_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> _pump(
    WidgetTester tester, {
    required FileExplorerMode mode,
    bool allowMultiple = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FileExplorerScreen(
          mode: mode,
          allowMultiple: allowMultiple,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('file picker shows Send and hides New folder', (tester) async {
    await _pump(
      tester,
      mode: FileExplorerMode.pickFile,
      allowMultiple: true,
    );
    expect(find.byIcon(Icons.create_new_folder_outlined), findsNothing);
    expect(find.text('Send'), findsOneWidget);
    expect(find.text('Choose a file'), findsNothing);
    expect(find.text('Save here'), findsNothing);
  });

  testWidgets('folder picker keeps New folder and Save here', (tester) async {
    await _pump(tester, mode: FileExplorerMode.pickFolder);
    expect(find.byIcon(Icons.create_new_folder_outlined), findsOneWidget);
    expect(find.text('Save here'), findsOneWidget);
    expect(find.text('Send'), findsNothing);
  });
}
