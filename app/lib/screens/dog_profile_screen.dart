import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'AppColor.dart';
import 'chat_room_screen.dart';
import 'board_screen.dart';
import 'chat_store.dart';
import 'seller_profile_screen.dart';
import '../services/api_config.dart';
import '../services/post_service.dart';

class DogProfileScreen extends StatefulWidget {
  final Map<String, dynamic> dog;

  const DogProfileScreen({super.key, required this.dog});

  @override
  State<DogProfileScreen> createState() => _DogProfileScreenState();
}

class _DogProfileScreenState extends State<DogProfileScreen> {
  bool isEdit = false;
  bool _isMyPost = false;
  String _accessToken = '';

  final PostService _postService = PostService();

  late TextEditingController breedController;
  late TextEditingController ageController;
  late TextEditingController genderController;
  late TextEditingController priceController;
  late TextEditingController regionController;
  late TextEditingController descriptionController;
  late TextEditingController healthController;

  Map<String, dynamic>? _postDetail;

  @override
  void initState() {
    super.initState();
    breedController = TextEditingController(
      text: widget.dog['breed']?.toString() ?? '',
    );

    ageController = TextEditingController(
      text: widget.dog['age']?.toString() ?? '',
    );

    genderController = TextEditingController(
      text: widget.dog['gender']?.toString() ?? '',
    );

    priceController = TextEditingController(
      text: widget.dog['price']?.toString() ?? '',
    );

    regionController = TextEditingController(
      text: widget.dog['region']?.toString() ?? '',
    );

    descriptionController = TextEditingController(
      text: widget.dog['description']?.toString() ?? '',
    );

    healthController = TextEditingController(
      text: widget.dog['health']?.toString() ?? '',
    );
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _accessToken = prefs.getString('access_token') ?? '';
    await Future.wait([_loadPostDetail(), _checkIsMyPost()]);
  }

  // 내 글 여부: getMyPosts에서 post_id 포함 여부로 판별
  Future<void> _checkIsMyPost() async {
    if (_accessToken.isEmpty) return;
    final myPosts = await _postService.getMyPosts(_accessToken);
    final postId = widget.dog['id'];
    if (!mounted) return;
    setState(() {
      _isMyPost = myPosts.any((p) => p['post_id'] == postId);
    });
  }

  Future<void> _loadPostDetail() async {
    final postId = widget.dog['id'];
    if (postId == null) return;

    final detail = await _postService.getPostDetail(postId);
    if (detail == null || !mounted) return;
    print(detail);

    setState(() {
      _postDetail = detail;
      widget.dog['breed'] = detail['breed'] ?? widget.dog['breed'];
      widget.dog['gender'] = switch (detail['gender']) {
        'MALE' => '수컷',
        'FEMALE' => '암컷',
        _ => widget.dog['gender'],
      };
      widget.dog['region'] =
          detail['dog_region'] ?? widget.dog['region'];
      widget.dog['description'] = detail['content'] ?? widget.dog['description'];
      widget.dog['owner'] =
          detail['author_display_name'] ?? widget.dog['owner'];
      widget.dog['profile_image_url'] =
          detail['profile_image_url'] ?? widget.dog['profile_image_url'];
      widget.dog['isReserved'] = detail['status'] == 'RESERVED';
      widget.dog['isAdopted'] = detail['status'] == 'COMPLETED';
      widget.dog['age'] = detail['age'] ?? widget.dog['age'];
      widget.dog['price'] = detail['price'] ?? widget.dog['price'];
      widget.dog['health'] = detail['health'] ?? widget.dog['health'];

      breedController.text = widget.dog['breed'] ?? '';
      genderController.text = widget.dog['gender'] ?? '';
      regionController.text = widget.dog['region']?.toString() ?? '';
      descriptionController.text = widget.dog['description'] ?? '';
      ageController.text = widget.dog['age']?.toString() ?? '';
      priceController.text = widget.dog['price']?.toString() ?? '';
      healthController.text = widget.dog['health']?.toString() ?? '';
    });
  }

  @override
  void dispose() {
    breedController.dispose();
    ageController.dispose();
    genderController.dispose();
    priceController.dispose();
    regionController.dispose();
    descriptionController.dispose();
    healthController.dispose();
    super.dispose();
  }

  void _saveEdit() {
    setState(() {
      widget.dog['breed'] = breedController.text;
      widget.dog['age'] = ageController.text;
      widget.dog['gender'] = genderController.text;
      widget.dog['price'] = priceController.text;
      widget.dog['health'] = healthController.text;
      widget.dog['region'] = regionController.text;
      widget.dog['description'] = descriptionController.text;
      isEdit = false;
    });
  }

  Future<void> _changePostStatus(String status) async {
    final postId = widget.dog['id'];
    if (postId == null) {
      _showSnack('게시글 정보를 찾을 수 없습니다.');
      return;
    }
    if (_accessToken.isEmpty) {
      _showSnack('로그인이 필요합니다.');
      return;
    }

    final result = await _postService.updatePostStatus(
      accessToken: _accessToken,
      postId: postId,
      status: status,
    );

    if (!mounted) return;
    if (result['success'] == true) {
      setState(() {
        widget.dog['isReserved'] = status == 'RESERVED';
        widget.dog['isAdopted'] = status == 'COMPLETED';
      });
      _showSnack('게시글 상태가 변경되었습니다.');
    } else {
      _showSnack(result['message'] ?? '상태 변경 실패');
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _onBottomNavTap(int index) {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => MainScreen(initialIndex: index)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authorDisplayName = widget.dog['owner']?.toString() ?? '';
    final userForCard = {
      'display_name': authorDisplayName,
      'email': _postDetail?['author_email'] ?? '',
      'contact_phone': _postDetail?['author_contact_phone'] ?? '',
      'region': _postDetail?['author_region'] ?? widget.dog['region'] ?? '',
    };

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(
          widget.dog['breed'] ?? '강아지 프로필',
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: AppColors.darkBrown,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          if (_isMyPost)
            IconButton(
              icon: Icon(isEdit ? Icons.check : Icons.edit),
              onPressed: () {
                if (isEdit) {
                  _saveEdit();
                } else {
                  setState(() => isEdit = true);
                }
              },
            ),
        ],
      ),

      body: ListView(
        padding: const EdgeInsets.only(bottom: 90),
        children: [
          DogImageSection(dog: widget.dog),
          const SizedBox(height: 16),
          SellerMiniProfile(
            dog: widget.dog,
            authorDisplayName: authorDisplayName,
            userForCard: userForCard,
          ),
          const SizedBox(height: 22),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DogInfoSection(
                  isEdit: isEdit,
                  breedController: breedController,
                  ageController: ageController,
                  genderController: genderController,
                  priceController: priceController,
                  healthController: healthController,
                  regionController: regionController,
                  descriptionController: descriptionController,
                  dog: widget.dog,
                ),
                const SizedBox(height: 24),
                if (_isMyPost)
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => _changePostStatus('RESERVED'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.darkBrown,
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('예약 중으로 변경'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () => _changePostStatus('COMPLETED'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.grey,
                            foregroundColor: Colors.white,
                          ),
                          child: const Text('입양 완료'),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),

      floatingActionButton: (widget.dog['isAdopted'] == true || _isMyPost)
          ? null
          : FloatingActionButton.extended(
        backgroundColor: AppColors.darkBrown,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.chat_bubble_outline),
        label: const Text('채팅'),
        onPressed: () async {
          final postId = widget.dog['id'];

          try {
            final room = await ChatStore.createOrGetChatRoom(
              token: _accessToken,
              postId: postId,
            );

            if (!mounted) return;

            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatRoomScreen(
                  roomId: room['room_id'],
                  name: widget.dog['owner'] ?? '상대방',
                  breed: widget.dog['breed'] ?? '강아지',
                ),
              ),
            );
          } catch (e) {
            _showSnack('채팅방 생성 실패: $e');
          }
        },
      ),

      bottomNavigationBar: BottomNavigationBar(
        currentIndex: 0,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: AppColors.darkBrown,
        unselectedItemColor: Colors.grey,
        onTap: _onBottomNavTap,
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
// DogImageSection
// -----------------------------------------------------------------------

class DogImageSection extends StatelessWidget {
  final Map<String, dynamic> dog;

  const DogImageSection({super.key, required this.dog});

  @override
  Widget build(BuildContext context) {
    final bool isReserved = dog['isReserved'] == true;
    final bool isAdopted = dog['isAdopted'] == true;

    return Stack(
      children: [
        Container(
          height: 260,
          width: double.infinity,
          color: const Color(0xFFFFEAF2),
          child: dog['profile_image_url'] != null &&
              dog['profile_image_url'].toString().isNotEmpty
              ? Image.network(
            ApiConfig.fileUrl(dog['profile_image_url']),
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Center(
              child: Text(
                dog['breed'] ?? '강아지',
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                  color: AppColors.text,
                ),
              ),
            ),
          )
              : Center(
            child: Text(
              dog['breed'] ?? '강아지',
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                color: AppColors.text,
              ),
            ),
          ),
        ),
        Positioned(
          right: 18,
          bottom: 18,
          child: Container(
            padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: isAdopted ? Colors.grey.shade400 : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isAdopted ? Colors.grey.shade500 : AppColors.border,
              ),
            ),
            child: Text(
              isAdopted ? '입양 완료' : isReserved ? '예약 중' : '예약 가능',
              style: TextStyle(
                color: isAdopted ? Colors.white : AppColors.text,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// -----------------------------------------------------------------------
// SellerMiniProfile
// -----------------------------------------------------------------------

class SellerMiniProfile extends StatelessWidget {
  final Map<String, dynamic> dog;
  final String authorDisplayName;
  final Map<String, dynamic> userForCard;

  const SellerMiniProfile({
    super.key,
    required this.dog,
    required this.authorDisplayName,
    required this.userForCard,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: GestureDetector(
        onTap: () {
          if (authorDisplayName.isEmpty) return;
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            backgroundColor: Colors.transparent,
            builder: (_) {
              return DraggableScrollableSheet(
                initialChildSize: 0.5,
                minChildSize: 0.5,
                maxChildSize: 0.9,
                builder: (context, scrollController) {
                  return Container(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius:
                      BorderRadius.vertical(top: Radius.circular(20)),
                    ),
                    child: ListView(
                      controller: scrollController,
                      children: [
                        SellerProfileCard(
                          authorDisplayName: authorDisplayName,
                          user: userForCard,
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
        child: Row(
          children: [
            const CircleAvatar(
              radius: 18,
              backgroundColor: AppColors.beige,
              child: Icon(Icons.person, color: AppColors.text, size: 20),
            ),
            const SizedBox(width: 10),
            Text(
              authorDisplayName.isNotEmpty ? authorDisplayName : '보호자',
              style: const TextStyle(
                color: AppColors.text,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------
// DogInfoSection, EditField, InfoRow
// -----------------------------------------------------------------------

class DogInfoSection extends StatelessWidget {
  final bool isEdit;
  final Map<String, dynamic> dog;
  final TextEditingController breedController;
  final TextEditingController ageController;
  final TextEditingController genderController;
  final TextEditingController priceController;
  final TextEditingController healthController;
  final TextEditingController regionController;
  final TextEditingController descriptionController;

  const DogInfoSection({
    super.key,
    required this.isEdit,
    required this.dog,
    required this.breedController,
    required this.ageController,
    required this.genderController,
    required this.priceController,
    required this.healthController,
    required this.regionController,
    required this.descriptionController,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 20),
        isEdit
            ? EditField(label: '견종', controller: breedController)
            : InfoRow(label: '견종', value: dog['breed'] ?? '정보 없음'),
        isEdit
            ? EditField(label: '나이', controller: ageController)
            : InfoRow(
          label: '나이',
          value: dog['age']?.toString() ?? '정보 없음',
        ),
        isEdit
            ? EditField(label: '성별', controller: genderController)
            : InfoRow(label: '성별', value: dog['gender'] ?? '정보 없음'),
        isEdit
            ? EditField(label: '가격', controller: priceController)
            : InfoRow(
          label: '가격',
          value: dog['price']?.toString() ?? '정보 없음',
        ),

        isEdit
            ? EditField(label: '건강/접종', controller: healthController)
            : InfoRow(
          label: '건강/접종',
          value: dog['health']?.toString() ?? '정보 없음',
        ),

        isEdit
            ? EditField(label: '지역', controller: regionController)
            : InfoRow(label: '지역', value: dog['region'] ?? '정보 없음'),
        const SizedBox(height: 18),
        const Text(
          '소개',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
            color: AppColors.text,
          ),
        ),
        const SizedBox(height: 8),
        isEdit
            ? TextField(
          controller: descriptionController,
          maxLines: 5,
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white,
            hintText: '소개를 입력하세요',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(color: AppColors.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: const BorderSide(
                  color: AppColors.darkBrown, width: 1.5),
            ),
          ),
        )
            : Text(
          dog['description'] ?? '',
          style: const TextStyle(
            fontSize: 14,
            height: 1.6,
            color: Colors.black87,
          ),
        ),
      ],
    );
  }
}

class EditField extends StatelessWidget {
  final String label;
  final TextEditingController controller;

  const EditField({super.key, required this.label, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: AppColors.text),
          filled: true,
          fillColor: Colors.white,
          contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: AppColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide:
            const BorderSide(color: AppColors.darkBrown, width: 1.5),
          ),
        ),
      ),
    );
  }
}

class InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const InfoRow({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 105,
            child: Text(
              label,
              style: const TextStyle(color: Colors.brown, fontSize: 14),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppColors.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}