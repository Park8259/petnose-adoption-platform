import 'dart:io';

import 'package:flutter/material.dart';
import 'AppColor.dart';
import 'board_screen.dart';

class DogRegisterCompleteScreen extends StatelessWidget {
  final String breed;
  final String gender;
  final String age;
  final String region;
  final String price;
  final String health;
  final String intro;
  final List<String> tags;
  final File? profileImage;
  final double? profileNoseMatchScore;

  const DogRegisterCompleteScreen({
    super.key,
    required this.breed,
    required this.gender,
    required this.age,
    required this.region,
    required this.price,
    required this.health,
    required this.intro,
    required this.tags,
    this.profileImage,
    this.profileNoseMatchScore,
  });

  @override
  Widget build(BuildContext context) {
    final matchPercentText = _matchPercentText(profileNoseMatchScore);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('등록 완료'),
        backgroundColor: AppColors.darkBrown,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 40),

            const CircleAvatar(
              radius: 58,
              backgroundColor: AppColors.beige,
              child: Icon(Icons.check, size: 58, color: Colors.white),
            ),

            const SizedBox(height: 28),

            const Text(
              '강아지 등록 완료!',
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                color: AppColors.text,
              ),
            ),

            const SizedBox(height: 12),

            const Text(
              '강아지 게시글이 성공적으로 등록되었습니다.',
              style: TextStyle(
                fontSize: 15,
                color: Colors.brown,
              ),
            ),

            const SizedBox(height: 32),

            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.darkBrown,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '등록 정보',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 16),

                  if (profileImage != null || matchPercentText != null) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (profileImage != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              profileImage!,
                              width: 64,
                              height: 64,
                              fit: BoxFit.cover,
                            ),
                          ),
                        if (profileImage != null) const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '프로필 사진과 비문 일치율',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                matchPercentText ?? '확인 완료',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 22,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                  ],

                  Text(
                    '$breed · $gender · $age',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 10),

                  Text(
                    '지역: $region',
                    style: const TextStyle(color: Colors.white),
                  ),
                  Text(
                    '가격: $price',
                    style: const TextStyle(color: Colors.white),
                  ),
                  Text(
                    '건강/접종 기록: $health',
                    style: const TextStyle(color: Colors.white),
                  ),

                  const SizedBox(height: 12),

                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      '비문 인증 완료',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const Spacer(),

            SizedBox(
              width: double.infinity,
              height: 58,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.darkBrown,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                onPressed: () {
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const MainScreen(initialIndex: 0),
                    ),
                        (route) => false,
                  );
                },
                child: const Text(
                  '게시글로 이동',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String? _matchPercentText(double? score) {
    if (score == null) return null;
    final percent = score > 1 ? score : score * 100;
    return '${percent.toStringAsFixed(1)}%';
  }
}
