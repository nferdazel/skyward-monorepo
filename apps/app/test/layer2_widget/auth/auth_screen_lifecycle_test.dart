import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skyward/core/theme/app_theme.dart';
import 'package:skyward/features/auth/presentation/cubit/auth_cubit.dart';
import 'package:skyward/features/auth/presentation/views/auth_screen.dart';

void main() {
  testWidgets(
    'AuthScreen disposes owned controllers cleanly when removed from tree',
    (WidgetTester tester) async {
      final authCubit = AuthCubit();
      addTearDown(authCubit.close);

      await tester.pumpWidget(
        BlocProvider<AuthCubit>.value(
          value: authCubit,
          child: MaterialApp(
            theme: AppTheme.darkTheme,
            home: AuthScreen(),
          ),
        ),
      );

      final textFields = find.byType(TextFormField);
      expect(textFields, findsNWidgets(2));

      await tester.enterText(textFields.first, 'chiefpilot');
      await tester.pump();

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
  );
}
