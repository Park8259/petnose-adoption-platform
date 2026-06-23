import 'package:flutter/material.dart';
import 'AppColor.dart';
import 'package:nosetag_app/services/auth_service.dart';
import 'package:nosetag_app/services/user_service.dart';
import 'package:nosetag_app/services/post_service.dart';
import 'package:nosetag_app/services/api_config.dart';
import 'dog_profile_screen.dart';
import 'board_screen.dart';
import 'change_info_screen.dart';

class MyPageScreen extends StatefulWidget {
  const MyPageScreen({super.key});

  @override
  State<MyPageScreen> createState() => _MyPageScreenState();
}

class _MyPageScreenState extends State<MyPageScreen> {
  bool isLoading = true;

  Map<String, dynamic>? userData;
  List<dynamic> myPosts     = [];
  List<dynamic> likedPosts  = [];
  List<dynamic> adoptedDogs = [];

  final Map<int, bool> _liked = {};

  final _userService = UserService();
  final _postService = PostService();

  @override
  void initState() {
    super.initState();
    _loadAllData();
  }

  Future<String> _getToken() => AuthService().getToken();

  Future<void> _loadAllData() async {
    try {
      final token = await _getToken();

      final results = await Future.wait([
        AuthService().getMyProfile(token),
        AuthService().getMyAdoptionPosts(token),
        _userService.getLikedPosts(token),
        _userService.getAdoptedDogs(token),
      ]);

      if (mounted) {
        setState(() {
          final userResult  = results[0] as Map<String, dynamic>;
          final postsResult = results[1] as Map<String, dynamic>;

          if (userResult['success'] == true) userData = userResult['data'];
          if (postsResult['success'] == true) {
            myPosts = postsResult['data']['items'] ?? [];
          }

          likedPosts  = results[2] as List<dynamic>;
          adoptedDogs = results[3] as List<dynamic>;

          // 좋아요 상태 초기화
          _liked.clear();
          for (final p in likedPosts) {
            final id = p['post_id'] as int?;
            if (id != null) _liked[id] = true;
          }
          // 내가 쓴 게시글의 liked 필드도 반영
          for (final p in myPosts) {
            final id = p['post_id'] as int?;
            if (id != null && !_liked.containsKey(id)) {
              _liked[id] = p['liked'] == true;
            }
          }

          isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("마이페이지 로드 오류: $e");
      if (mounted) setState(() => isLoading = false);
    }
  }

  // ── 좋아요 토글 (낙관적 업데이트) ───────────────────────────
  Future<void> _toggleLike(int postId) async {
    final current = _liked[postId] ?? false;

    // 즉시 UI 반영
    setState(() {
      _liked[postId] = !current;
      if (!current) {
        // 좋아요 추가 → likedPosts에 없으면 myPosts에서 찾아 추가
        if (!likedPosts.any((p) => p['post_id'] == postId)) {
          final fromMyPosts = myPosts.firstWhere(
                (p) => p['post_id'] == postId,
            orElse: () => null,
          );
          if (fromMyPosts != null) likedPosts.add(fromMyPosts);
        }
      } else {
        // 좋아요 취소 → likedPosts에서 제거
        likedPosts.removeWhere((p) => p['post_id'] == postId);
      }
    });

    final token = await _getToken();
    final ok = current
        ? await _postService.unlikePost(accessToken: token, postId: postId)
        : await _postService.likePost(accessToken: token, postId: postId);

    // 실패 시 롤백
    if (!ok && mounted) {
      setState(() {
        _liked[postId] = current;
        if (current) {
          // 롤백: 다시 추가
          if (!likedPosts.any((p) => p['post_id'] == postId)) {
            final fromMyPosts = myPosts.firstWhere(
                  (p) => p['post_id'] == postId,
              orElse: () => null,
            );
            if (fromMyPosts != null) likedPosts.add(fromMyPosts);
          }
        } else {
          likedPosts.removeWhere((p) => p['post_id'] == postId);
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('좋아요 처리에 실패했습니다.')),
      );
    }
  }

  Map<String, dynamic> _mapPost(Map<String, dynamic> post) {
    return {
      'id': post['post_id'],
      'post_id': post['post_id'],
      'title': post['title'] ?? '',
      'name': post['dog_name'] ?? '',
      'breed': post['breed'] ?? '',
      'gender': switch (post['gender']) {
        'MALE'   => '수컷',
        'FEMALE' => '암컷',
        _        => '미상',
      },
      'age': post['birth_date'] ?? '',
      'region': post['author_region'] ?? userData?['region'] ?? '',
      'owner': post['author_display_name'] ?? userData?['display_name'] ?? '',
      'profile_image_url': post['profile_image_url'],
      'tags': <String>[],
      'description': post['title'] ?? '',
      'price': '',
      'isReserved': post['status'] == 'RESERVED',
      'needNoseAuth': false,
      'noseAuthDone': post['verification_status'] == 'VERIFIED',
      'isAdopted': post['status'] == 'COMPLETED' || post['status'] == 'ADOPTED',
      'userId': userData?['user_id'] ?? 0,
    };
  }

  Map<String, dynamic> _mapAdopted(Map<String, dynamic> item) {
    return {
      'id': item['post_id'],
      'post_id': item['post_id'],
      'title': item['post_title'] ?? '',
      'name': item['dog_name'] ?? '',
      'breed': item['breed'] ?? '',
      'gender': switch (item['gender']) {
        'MALE'   => '수컷',
        'FEMALE' => '암컷',
        _        => '미상',
      },
      'age': item['birth_date'] ?? '',
      'region': userData?['region'] ?? '',
      'owner': userData?['display_name'] ?? '',
      'profile_image_url': item['profile_image_url'],
      'tags': <String>[],
      'description': item['post_title'] ?? '',
      'price': '',
      'isReserved': false,
      'needNoseAuth': false,
      'noseAuthDone': item['verification_status'] == 'VERIFIED',
      'isAdopted': true,
      'userId': userData?['user_id'] ?? 0,
    };
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final myPostsMapped    = myPosts.map((p) => _mapPost(p as Map<String, dynamic>)).toList();
    final likedPostsMapped = likedPosts.map((p) => _mapPost(p as Map<String, dynamic>)).toList();
    final adoptedMapped    = adoptedDogs.map((p) => _mapAdopted(p as Map<String, dynamic>)).toList();

    return Scaffold(
      backgroundColor: AppColors.background,
      body: RefreshIndicator(
        onRefresh: _loadAllData,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── 프로필 카드 ──────────────────────────
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  const Icon(Icons.person, size: 70),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              userData?['display_name'] ?? '사용자',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 10),
                            GestureDetector(
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const ChangeInfo()),
                              ),
                              child: const Text(
                                '정보수정',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.darkBrown,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(userData?['email'] ?? '',
                            style: const TextStyle(
                                fontSize: 13, color: Colors.grey)),
                        const SizedBox(height: 3),
                        Text("지역 : ${userData?['region'] ?? '정보 없음'}",
                            style: const TextStyle(
                                fontSize: 13, color: Colors.grey)),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── 좋아요한 게시글 ──────────────────────
            _SectionTitle(title: '좋아요한 게시글', count: likedPostsMapped.length),
            const SizedBox(height: 12),
            likedPostsMapped.isEmpty
                ? const _EmptyBox(message: '좋아요한 강아지가 없습니다')
                : Column(
              children: likedPostsMapped.map((dog) {
                final postId = dog['post_id'] as int?;
                return GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => DogProfileScreen(dog: dog)),
                  ),
                  child: DogPostCard(
                    dog: dog,
                    isLiked: postId != null ? (_liked[postId] ?? true) : true,
                    isMyPost: false,
                    onLikeToggle: () {
                      if (postId != null) _toggleLike(postId);
                    },
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 30),

            // ── 내가 쓴 게시글 ───────────────────────
            _SectionTitle(title: '내가 쓴 게시글', count: myPostsMapped.length),
            const SizedBox(height: 12),
            myPostsMapped.isEmpty
                ? const _EmptyBox(message: '작성한 게시글이 없습니다')
                : Column(
              children: myPostsMapped.map((dog) {
                final postId = dog['post_id'] as int?;
                return GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => DogProfileScreen(dog: dog)),
                  ),
                  child: DogPostCard(
                    dog: dog,
                    isLiked: postId != null ? (_liked[postId] ?? false) : false,
                    isMyPost: true,
                    onLikeToggle: () {
                      if (postId != null) _toggleLike(postId);
                    },
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 30),

            // ── 내가 입양한 강아지 ───────────────────
            _SectionTitle(title: '내가 입양한 강아지', count: adoptedMapped.length),
            const SizedBox(height: 12),
            adoptedMapped.isEmpty
                ? const _EmptyBox(message: '입양한 강아지가 없습니다')
                : Column(
              children: adoptedMapped.map((dog) {
                final postId = dog['post_id'] as int?;
                return DogPostCard(
                  dog: dog,
                  isLiked: postId != null ? (_liked[postId] ?? false) : false,
                  isMyPost: false,
                  onLikeToggle: () {
                    if (postId != null) _toggleLike(postId);
                  },
                );
              }).toList(),
            ),

            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final int count;
  const _SectionTitle({required this.title, required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(width: 8),
        if (count > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.darkBrown,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text('$count',
                style: const TextStyle(fontSize: 12, color: Colors.white)),
          ),
      ],
    );
  }
}

class _EmptyBox extends StatelessWidget {
  final String message;
  const _EmptyBox({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 100,
      decoration: BoxDecoration(
        color: AppColors.border,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: Text(message,
            style: const TextStyle(fontSize: 15, color: AppColors.text)),
      ),
    );
  }
}