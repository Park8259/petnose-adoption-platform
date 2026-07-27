import 'package:flutter/material.dart';
import 'AppColor.dart';
import 'dog_profile_screen.dart';
import '../services/post_service.dart';
import '../services/api_config.dart';

class SellerProfileCard extends StatefulWidget {
  final String authorDisplayName;

  final Map<String, dynamic> user;

  const SellerProfileCard({
    super.key,
    required this.authorDisplayName,
    required this.user,
  });

  @override
  State<SellerProfileCard> createState() => _SellerProfileCardState();
}

class _SellerProfileCardState extends State<SellerProfileCard> {
  final PostService _postService = PostService();
  List<Map<String, dynamic>> _posts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPosts();
  }

  Future<void> _loadPosts() async {
    final posts = await _postService.getPostsByAuthor(widget.authorDisplayName);
    if (!mounted) return;
    setState(() {
      _posts = posts.cast<Map<String, dynamic>>();  // 여기 추가
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // API 응답 필드명에 맞게 접근
    final displayName =
        widget.user['display_name'] ?? widget.authorDisplayName;
    final email = widget.user['email'] ?? '';
    final phone = widget.user['contact_phone'] ?? '';
    final region = widget.user['region'] ?? '';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 프로필 헤더 ──────────────────────────────────────
          Row(
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(30),
                ),
                child: const Icon(
                  Icons.person,
                  color: AppColors.darkBrown,
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  displayName,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.text,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 20),
          Container(height: 1, color: AppColors.border),
          const SizedBox(height: 16),

          // ── 유저 정보 ────────────────────────────────────────
          if (email.isNotEmpty) ...[
            _infoRow(Icons.email, email),
            const SizedBox(height: 10),
          ],
          if (phone.isNotEmpty) ...[
            _infoRow(Icons.phone, phone),
            const SizedBox(height: 10),
          ],
          if (region.isNotEmpty) ...[
            _infoRow(Icons.location_on, region),
            const SizedBox(height: 20),
          ],

          // ── 올린 게시물 ──────────────────────────────────────
          const Text(
            '올린 게시물',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 12),

          if (_isLoading)
            const Center(child: CircularProgressIndicator())
          else if (_posts.isEmpty)
            Container(
              width: double.infinity,
              height: 120,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Center(
                child: Text(
                  '올린 게시물이 없습니다',
                  style: TextStyle(fontSize: 16, color: AppColors.text),
                ),
              ),
            )
          else
            Column(
              children: _posts.map((post) {
                // API 응답 → 카드용 포맷
                final dog = {
                  'id': post['post_id'],
                  'breed': post['breed'] ?? '',
                  'gender': switch (post['gender']) {
                    'MALE' => '수컷',
                    'FEMALE' => '암컷',
                    _ => '미상',
                  },
                  'age': post['birth_date'] ?? '',
                  'region': post['author_region'] ?? '',
                  'owner': post['author_display_name'] ?? '',
                  'profile_image_url': post['profile_image_url'],
                  'tags': [],
                  'description': post['content'] ?? '',
                  'isAdopted': post['status'] == 'COMPLETED',
                  'isReserved': post['status'] == 'RESERVED',
                  'needNoseAuth': false,
                  'noseAuthDone': post['verification_status'] == 'VERIFIED',
                  'userId': null,
                };

                return GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => DogProfileScreen(dog: dog),
                      ),
                    );
                  },
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            color: AppColors.border,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: post['profile_image_url'] != null &&
                              post['profile_image_url'].toString().isNotEmpty
                              ? Image.network(
                            ApiConfig.fileUrl(post['profile_image_url']),
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(
                              Icons.pets,
                              color: AppColors.darkBrown,
                            ),
                          )
                              : const Icon(Icons.pets,
                              color: AppColors.darkBrown),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                post['breed'] ?? '',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.text,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${post['birth_date'] ?? ''} · ${post['author_region'] ?? ''}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.darkBrown),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13, color: AppColors.text),
          ),
        ),
      ],
    );
  }
}