// import 'package:flutter/material.dart';
// import 'package:flutter/rendering.dart';
// import 'package:flutter_test/flutter_test.dart';

// void main() {
//   group('AppTheme Golden Tests', () {
//     testWidgets('AppButton renders correctly', (tester) async {
//       final previousDisableShadows = debugDisableShadows;
//       debugDisableShadows = true;
//       tester.view.devicePixelRatio = 1.0;
//       tester.view.physicalSize = const Size(800, 600);
//       addTearDown(() {
//         debugDisableShadows = previousDisableShadows;
//         tester.view.resetDevicePixelRatio();
//         tester.view.resetPhysicalSize();
//       });

//       await tester.pumpWidget(
//         MaterialApp(
//           theme: ThemeData.dark(useMaterial3: false),
//           home: Scaffold(
//             body: Center(
//               child: ElevatedButton(
//                 style: ElevatedButton.styleFrom(
//                   elevation: 0,
//                   shadowColor: Colors.transparent,
//                 ),
//                 onPressed: () {},
//                 child: const Text('TEST BUTTON'),
//               ),
//             ),
//           ),
//         ),
//       );
//       await expectLater(
//         find.byType(ElevatedButton),
//         matchesGoldenFile('goldens/app_button.png'),
//       );
//     });
//   });
// }
