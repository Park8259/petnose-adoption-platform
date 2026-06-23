import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'AppColor.dart';
import 'nose_check_camera_screen.dart';
import '../services/api_config.dart';

class NoseCheckScreen extends StatefulWidget {
  const NoseCheckScreen({super.key});

  @override
  State<NoseCheckScreen> createState() => _NoseCheckScreenState();
}

class _NoseCheckScreenState extends State<NoseCheckScreen> {
  bool _isLoading = true;
  List<dynamic> _likedPosts = [];

  @override
  void initState() {
    super.initState();
    _loadLikedPosts();
  }

  Future<String> _getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('access_token') ?? '';
  }

  Future<void> _loadLikedPosts() async {
    setState(() => _isLoading = true);
    try {
      final token = await _getToken();
      final response = await http.get(
        Uri.parse(ApiConfig.api('/adoption-posts/liked/me?page=0&size=50')),
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() => _likedPosts = data['items'] ?? []);
      }
    } catch (e) {
      debugPrint('좋아요 목록 로드 오류: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        onRefresh: _loadLikedPosts,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const Text(
              '비문을 확인할 강아지를 선택해주세요',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppColors.text,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '관심 표시한 강아지 목록입니다.',
              style: TextStyle(fontSize: 13, color: Colors.brown),
            ),
            const SizedBox(height: 18),
            if (_likedPosts.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 80),
                child: Center(
                  child: Text(
                    '관심 표시한 강아지가 없습니다.',
                    style: TextStyle(
                      color: AppColors.text,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              )
            else
              ..._likedPosts.map((post) {
                final postId = post['post_id'] as int;
                return FavoriteDogCard(
                  postId: postId,
                  breed: post['breed'] ?? '견종 정보 없음',
                  gender: switch (post['gender']) {
                    'MALE'   => '수컷',
                    'FEMALE' => '암컷',
                    _        => '미상',
                  },
                  age: post['birth_date'] ?? '',
                  region: post['author_region'] ?? '',
                  profileImageUrl: post['profile_image_url'],
                  verificationStatus: post['verification_status'] ?? '',
                );
              }),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────
// FavoriteDogCard
// ─────────────────────────────────────────
class FavoriteDogCard extends StatelessWidget {
  final int postId;
  final String breed;
  final String gender;
  final String age;
  final String region;
  final String? profileImageUrl;
  final String verificationStatus;

  const FavoriteDogCard({
    super.key,
    required this.postId,
    required this.breed,
    required this.gender,
    required this.age,
    required this.region,
    this.profileImageUrl,
    required this.verificationStatus,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => NoseCheckCameraScreen(postId: postId),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            // 썸네일
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppColors.background,
                shape: BoxShape.circle,
              ),
              clipBehavior: Clip.antiAlias,
              child: profileImageUrl != null && profileImageUrl!.isNotEmpty
                  ? Image.network(
                ApiConfig.fileUrl(profileImageUrl!),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                const Icon(Icons.pets_rounded, color: AppColors.text, size: 34),
              )
                  : const Icon(Icons.pets_rounded, color: AppColors.text, size: 34),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$breed · $gender · $age · $region',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppColors.text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (verificationStatus == 'VERIFIED')
                    Row(
                      children: const [
                        Icon(Icons.verified, size: 14, color: Colors.green),
                        SizedBox(width: 4),
                        Text('비문 인증 완료',
                            style: TextStyle(fontSize: 12, color: Colors.green)),
                      ],
                    ),
                  const SizedBox(height: 6),
                  const Text(
                    '선택하면 비문 촬영으로 이동합니다',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}