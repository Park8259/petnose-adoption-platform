import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:nosetag_app/screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const enableFirebase = bool.fromEnvironment(
    'ENABLE_FIREBASE',
    defaultValue: false,
  );

  if (enableFirebase) {
    try {
      await Firebase.initializeApp();
    } catch (error, stackTrace) {
      debugPrint('Firebase initialization skipped/failed: $error');
      debugPrint('$stackTrace');
    }
  }

  runApp(const NoseTagApp());
}

class NoseTagApp extends StatelessWidget {
  const NoseTagApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NoseTag',
      theme: ThemeData(
        fontFamily: 'Pretendard',
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFC6A77D)),
        scaffoldBackgroundColor: const Color(0xFFFFFBF6),
      ),
      home: const LoginScreen(),
    );
  }
}
