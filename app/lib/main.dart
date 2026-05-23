import 'package:flutter/material.dart';

void main() {
  runApp(const PetNoseApp());
}

class PetNoseApp extends StatelessWidget {
  const PetNoseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PetNose',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff287067)),
        useMaterial3: true,
      ),
      home: const PetNosePlaceholderScreen(),
    );
  }
}

class PetNosePlaceholderScreen extends StatelessWidget {
  const PetNosePlaceholderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'PetNose production app scaffold',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
