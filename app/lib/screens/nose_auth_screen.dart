import 'package:flutter/material.dart';
import 'AppColor.dart';
import 'nose_auth_camera_screen.dart';
import 'AppData.dart';

class NoseAuthScreen extends StatefulWidget {
  const NoseAuthScreen({super.key});

  @override
  State<NoseAuthScreen> createState() => _NoseAuthScreenState();
}

class _NoseAuthScreenState extends State<NoseAuthScreen> {

  @override
  Widget build(BuildContext context) {
    final authDogs = AppData.dogPosts
        .where((dog) =>
    dog['isAdopted'] == true &&
        dog['adopterId'] == AppUser.currentUserId &&
        dog['needNoseAuth'] == true &&
        dog['noseAuthDone'] == false)
        .toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          if (authDogs.isEmpty)
            const EmptyAuthView()
          else
            ...authDogs.map((dog) {
              return AdoptedDogAuthCard(
                breed: dog['breed'] ?? '견종 정보 없음',
                gender: dog['gender'] ?? '성별 정보 없음',
                status: '비문 인증이 완료되지 않았습니다',
                onTap: () async {
                  final result = await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const NoseAuthCameraScreen(),
                    ),
                  );

                  if (result == true) {
                    setState(() {
                      dog['noseAuthDone'] = true;
                    });
                  }
                },
              );
            }),
        ],
      ),
    );
  }
}

class AdoptedDogAuthCard extends StatelessWidget {
  final String breed;
  final String gender;
  final String status;
  final VoidCallback onTap;

  const AdoptedDogAuthCard({
    super.key,
    required this.breed,
    required this.gender,
    required this.status,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Container(
              width: 62,
              height: 62,
              decoration: const BoxDecoration(
                color: AppColors.background,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.pets_rounded,
                color: AppColors.text,
                size: 30,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$breed · $gender',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.text,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    status,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Colors.redAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
class EmptyAuthView extends StatelessWidget {
  const EmptyAuthView({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 110),
      child: Column(
        children: [
          Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.border),
            ),
            child: const Icon(
              Icons.verified_rounded,
              size: 46,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 22),
          const Text(
            '비문 인증할 강아지가 없습니다',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '현재 모든 강아지의 비문 인증이 완료되었어요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Colors.brown,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}