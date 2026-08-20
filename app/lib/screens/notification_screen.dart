import 'package:flutter/material.dart';
import 'AppColor.dart';

class NotificationScreen extends StatelessWidget {
  const NotificationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('알림'),
        backgroundColor: AppColors.text,
        foregroundColor: Colors.white,
      ),
      body: const Center(
        child: Text('알림창 화면'),
      ),
    );
  }
}