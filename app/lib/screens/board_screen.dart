import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'AppColor.dart';
import 'notification_screen.dart';
import 'dog_register_screen.dart';
import 'dog_profile_screen.dart';
import 'nose_auth_screen.dart';
import 'nose_check_screen.dart';
import 'chat_list_screen.dart';
import 'my_page_screen.dart';
import '../services/post_service.dart';
import '../services/user_service.dart';
import '../services/api_config.dart';

class MainScreen extends StatefulWidget {
  final int initialIndex;
  const MainScreen({super.key, this.initialIndex = 0});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  late int _selectedIndex;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex;
  }

  void _onTap(int index) => setState(() => _selectedIndex = index);

  List<Widget> get _pages => [
    const BoardPage(),
    const NoseAuthScreen(),
    const NoseCheckScreen(),
    const ChatListScreen(),
    const MyPageScreen(),
  ];

  final List<String> _titles = ['NoseTag', '비문 인증', '비문 확인', '채팅', '마이페이지'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(
          _titles[_selectedIndex],
          style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: AppColors.darkBrown,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_none, color: Colors.white),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NotificationScreen()),
            ),
          ),
        ],
      ),
      body: IndexedStack(index: _selectedIndex, children: _pages),
      floatingActionButton: _selectedIndex == 0
          ? FloatingActionButton.extended(
        backgroundColor: AppColors.darkBrown,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('강아지 등록'),
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const DogRegisterScreen()),
          );
          setState(() {});
        },
      )
          : null,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: _onTap,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: AppColors.darkBrown,
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.article), label: '게시글'),
          BottomNavigationBarItem(icon: Icon(Icons.pets), label: '비문 인증'),
          BottomNavigationBarItem(icon: Icon(Icons.remove_red_eye), label: '비문 확인'),
          BottomNavigationBarItem(icon: Icon(Icons.chat_bubble), label: '채팅'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: '마이페이지'),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------
// BoardPage
// -----------------------------------------------------------------------

class BoardPage extends StatefulWidget {
  const BoardPage({super.key});

  @override
  State<BoardPage> createState() => _BoardPageState();
}

class _BoardPageState extends State<BoardPage> {
  String searchText = '';
  bool _isLoading = false;

  List<Map<String, dynamic>> _posts = [];
  final Set<int> _myPostIds = {};

  // 좋아요 상태 — 서버 기준으로 초기화, 토글 시 서버 반영
  final Map<int, bool> _liked = {};

  String _displayName = '';
  String _accessToken = '';

  final PostService _postService = PostService();
  final UserService _userService = UserService();

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<String> _getToken() async {
    if (_accessToken.isNotEmpty) return _accessToken;
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString('access_token') ?? '';
    return _accessToken;
  }

  Future<void> _loadAll() async {
    setState(() => _isLoading = true);
    await Future.wait([_loadPosts(), _loadMe()]);
    setState(() => _isLoading = false);
  }

  Future<void> _loadMe() async {
    final token = await _getToken();
    final me = await _userService.getMe(token);
    if (me == null || !mounted) return;

    final myPosts = await _postService.getMyPosts(token);
    if (!mounted) return;

    setState(() {
      _displayName = me['display_name'] ?? '';
      _myPostIds
        ..clear()
        ..addAll(myPosts.map<int>((p) => p['post_id'] as int));
    });
  }

  Future<void> _loadPosts() async {
    final results = await Future.wait([
      _postService.getPosts(status: 'OPEN'),
      _postService.getPosts(status: 'RESERVED'),
      _postService.getPosts(status: 'COMPLETED'),
    ]);

    if (!mounted) return;

    final allPosts = results
        .expand((list) => list)
        .map((p) => _mapPost(p as Map<String, dynamic>))
        .toList();

    setState(() {
      _posts = allPosts;
      // 서버에서 내려온 liked 필드로 초기화
      for (final p in _posts) {
        final id = p['id'] as int?;
        if (id != null) _liked[id] = p['liked'] == true;
      }
    });
  }

  Map<String, dynamic> _mapPost(Map<String, dynamic> post) {
    return {
      'id': post['post_id'],
      'breed': post['breed'] ?? '',
      'gender': switch (post['gender']) {
        'MALE'   => '수컷',
        'FEMALE' => '암컷',
        _        => '미상',
      },
      'age': post['birth_date'] ?? '',
      'region': post['author_region'] ?? '',
      'price': '',
      'owner': post['author_display_name'] ?? '',
      'profile_image_url': post['profile_image_url'],
      'tags': [],
      'description': post['content'] ?? '',
      'isReserved': post['status'] == 'RESERVED',
      'needNoseAuth': false,
      'noseAuthDone': post['verification_status'] == 'VERIFIED',
      'isAdopted': post['status'] == 'COMPLETED',
      'liked': post['liked'] ?? false,
    };
  }

  // ── 좋아요 토글 (낙관적 업데이트) ───────────────────────────
  Future<void> _toggleLike(int postId) async {
    final current = _liked[postId] ?? false;

    // 누르는 즉시 UI 반영
    setState(() => _liked[postId] = !current);

    final token = await _getToken();
    final ok = current
        ? await _postService.unlikePost(accessToken: token, postId: postId)
        : await _postService.likePost(accessToken: token, postId: postId);

    // 실패 시 롤백
    if (!ok && mounted) {
      setState(() => _liked[postId] = current);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('좋아요 처리에 실패했습니다.')),
      );
    }
  }

  // ── 게시글 삭제 ──────────────────────────────────────────────
  Future<void> _deletePost(int postId) async {
    final token = await _getToken();
    final result = await _postService.updatePostStatus(
      accessToken: token,
      postId: postId,
      status: 'CLOSED',
    );
    if (result['success'] == true) await _loadPosts();
  }

  // ── 필터·정렬 ────────────────────────────────────────────────
  List<Map<String, dynamic>> get _filteredPosts {
    final result = _posts.where((dog) {
      final text = [
        dog['breed'], dog['gender'], dog['age'],
        dog['region'], dog['description'], dog['owner'],
        ...(dog['tags'] as List),
      ].join(' ').toLowerCase();
      return text.contains(searchText.toLowerCase());
    }).toList();

    result.sort((a, b) {
      final aAdopted = a['isAdopted'] == true;
      final bAdopted = b['isAdopted'] == true;
      if (aAdopted == bAdopted) return 0;
      return aAdopted ? 1 : -1;
    });

    return result;
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _loadAll,
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
        padding: const EdgeInsets.all(18),
        children: [
          WelcomeCard(
            nickname: _displayName.isNotEmpty ? _displayName : '보호자',
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '게시글',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.text,
                ),
              ),
              SizedBox(
                width: 180,
                child: Container(
                  padding: const EdgeInsets.only(bottom: 4),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: AppColors.text, width: 1.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search, color: AppColors.text, size: 20),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          onChanged: (v) => setState(() => searchText = v),
                          decoration: const InputDecoration(
                            hintText: '검색',
                            hintStyle: TextStyle(fontSize: 13, color: Colors.grey),
                            isDense: true,
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ..._filteredPosts.map((dog) {
            final postId = dog['id'] as int?;
            final isMyPost = postId != null && _myPostIds.contains(postId);
            return DogPostCard(
              dog: dog,
              isMyPost: isMyPost,
              isLiked: postId != null ? (_liked[postId] ?? false) : false,
              onLikeToggle: () {
                if (postId != null) _toggleLike(postId);
              },
              onDelete: isMyPost && postId != null
                  ? () => _deletePost(postId)
                  : null,
            );
          }),
          const SizedBox(height: 80),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------
// WelcomeCard
// -----------------------------------------------------------------------

class WelcomeCard extends StatelessWidget {
  final String nickname;
  const WelcomeCard({super.key, required this.nickname});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '오늘도 반가워요',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.brown,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '환영합니다,\n$nickname님',
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: AppColors.text,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.pets_rounded, size: 42, color: AppColors.text),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------
// DogPostCard
// -----------------------------------------------------------------------

class DogPostCard extends StatelessWidget {
  final Map<String, dynamic> dog;
  final bool isMyPost;
  final bool isLiked;
  final VoidCallback onLikeToggle;
  final VoidCallback? onDelete;

  const DogPostCard({
    super.key,
    required this.dog,
    required this.isMyPost,
    required this.isLiked,
    required this.onLikeToggle,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final bool isAdopted = dog['isAdopted'] == true;

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => DogProfileScreen(dog: dog)),
      ),
      child: Card(
        color: isAdopted ? Colors.grey.shade200 : Colors.white,
        margin: const EdgeInsets.only(bottom: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: AppColors.border),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Stack(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 82,
                    height: 82,
                    decoration: BoxDecoration(
                      color: AppColors.background,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: dog['profile_image_url'] != null &&
                        dog['profile_image_url'].toString().isNotEmpty
                        ? Image.network(
                      ApiConfig.fileUrl(dog['profile_image_url']),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.pets, size: 38, color: AppColors.text,
                      ),
                    )
                        : const Icon(Icons.pets, size: 38, color: AppColors.text),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '${dog['breed']}',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: AppColors.text,
                              ),
                            ),
                            if (isAdopted) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.grey.shade400,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Text(
                                  '입양 완료',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${dog['gender']} · ${dog['age']} · ${dog['region']}',
                          style: const TextStyle(fontSize: 12, color: AppColors.text),
                        ),
                        const SizedBox(height: 10),
                        if ((dog['tags'] as List).isNotEmpty)
                          Row(
                            children: (dog['tags'] as List).map((tag) {
                              return Container(
                                margin: const EdgeInsets.only(right: 6),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppColors.background,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: AppColors.border),
                                ),
                                child: Text('#$tag',
                                    style: const TextStyle(
                                        fontSize: 10, color: AppColors.text)),
                              );
                            }).toList(),
                          ),
                        const SizedBox(height: 6),
                        RichText(
                          text: TextSpan(
                            style: const TextStyle(fontFamily: 'Pretendard'),
                            children: [
                              WidgetSpan(
                                alignment: PlaceholderAlignment.middle,
                                child: Icon(Icons.person,
                                    size: 13, color: AppColors.text),
                              ),
                              TextSpan(
                                text: ' ${dog['owner']}',
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Positioned(
                top: -8,
                right: -4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    IconButton(
                      icon: Icon(
                        isLiked ? Icons.favorite : Icons.favorite_border,
                        color: Colors.pink,
                      ),
                      onPressed: onLikeToggle,
                    ),
                    const SizedBox(height: 12),
                    if (isMyPost && onDelete != null)
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert,
                            size: 18, color: Colors.grey),
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: 'delete', child: Text('삭제')),
                        ],
                        onSelected: (value) {
                          if (value == 'delete') {
                            showDialog(
                              context: context,
                              builder: (_) => AlertDialog(
                                title: const Text('게시글 삭제'),
                                content: const Text('정말 삭제하시겠습니까?'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('취소'),
                                  ),
                                  TextButton(
                                    onPressed: () {
                                      Navigator.pop(context);
                                      onDelete!();
                                    },
                                    child: const Text('삭제'),
                                  ),
                                ],
                              ),
                            );
                          }
                        },
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}