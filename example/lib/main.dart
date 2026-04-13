import 'package:flutter/gestures.dart' as gestures;
import 'package:flutter/material.dart';

import 'demos/getting_started_demo.dart';

void main() {
  // Enable gesture arena diagnostics for debugging recognizer conflicts
  gestures.debugPrintGestureArenaDiagnostics =
      false; // set to true only when debugging
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Canvas Studio Pro',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      debugShowCheckedModeBanner: false,
      home: const GettingStartedDemoPage(),
    );
  }
}
