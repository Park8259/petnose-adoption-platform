import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'AppColor.dart';
import 'AppData.dart';
import 'chat_store.dart';
import '../services/api_config.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ChatRoomScreen extends StatefulWidget {
  final String roomId;
  final String name;
  final String breed;

  const ChatRoomScreen({
    super.key,
    required this.roomId,
    required this.name,
    required this.breed,
  });

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final TextEditingController _controller = TextEditingController();
  final ImagePicker _picker = ImagePicker();
  String _postStatus = 'OPEN';
  bool _isActionLoading = false;

  @override
  void initState() {
    super.initState();
    _markAsRead();
    _loadRoomState();
  }

  Future<void> _loadRoomState() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('chat_rooms')
          .doc(widget.roomId)
          .get();
      final data = snapshot.data();
      final status = data?['post_status_snapshot'];
      if (status is String && status.isNotEmpty && mounted) {
        setState(() {
          _postStatus = status;
          dogPost['isReserved'] = status == 'RESERVED';
          dogPost['isAdopted'] = status == 'COMPLETED';
        });
      }
    } catch (_) {}
  }

  Future<void> _markAsRead() async {
    final token = AppUser.accessToken;

    if (token.isEmpty) return;

    try {
      await ChatStore.markRoomAsRead(
        token: token,
        roomId: widget.roomId,
      );
    } catch (_) {}
  }

  Map<String, dynamic> get dogPost {
    return AppData.dogPosts.firstWhere(
          (dog) => dog['breed'] == widget.breed,
      orElse: () => {
        'owner': widget.name,
        'breed': widget.breed,
        'age': '',
        'gender': '',
        'region': '',
        'price': '',
        'isReserved': false,
        'isAdopted': false,
        'rating': 0.0,
      },
    );
  }

  Map<String, dynamic> get ownerUser {
    final userId = dogPost['userId'];

    if (userId is int) {
      final user = AppUser.getUserById(userId);
      if (user != null && user.isNotEmpty) return user;
    }

    return {
      'rating': 0.0,
    };
  }

  Future<void> _toggleReservation() async {
    final token = AppUser.accessToken;

    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('로그인이 필요합니다.')),
      );
      return;
    }
    if (_isActionLoading) return;

    setState(() {
      _isActionLoading = true;
    });

    try {
      final result = _postStatus == 'RESERVED'
          ? await ChatStore.cancelReservation(
        token: token,
        roomId: widget.roomId,
      )
          : await ChatStore.reserveRoom(
        token: token,
        roomId: widget.roomId,
      );
      if (!mounted) return;
      _applyPostStatus(result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_postStatus == 'RESERVED' ? '예약되었습니다.' : '예약을 취소했습니다.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('예약 처리 실패: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isActionLoading = false;
        });
      }
    }
  }

  Future<void> _adoptDog() async {
    final token = AppUser.accessToken;

    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('로그인이 필요합니다.')),
      );
      return;
    }
    if (_isActionLoading) return;

    setState(() {
      _isActionLoading = true;
    });

    try {
      final result = await ChatStore.completeAdoption(
        token: token,
        roomId: widget.roomId,
      );
      if (!mounted) return;
      _applyPostStatus(result);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('분양 완료 처리되었습니다.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('분양 완료 실패: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isActionLoading = false;
        });
      }
    }
  }

  void _applyPostStatus(Map<String, dynamic> result) {
    final status = result['status']?.toString();
    if (status == null || status.isEmpty) return;

    setState(() {
      _postStatus = status;
      dogPost['isReserved'] = status == 'RESERVED';
      dogPost['isAdopted'] = status == 'COMPLETED';
      if (status == 'COMPLETED') {
        dogPost['adopterId'] = AppUser.currentUserId;
        dogPost['adoptedAt'] = DateTime.now().toString().split(' ')[0];
        dogPost['needNoseAuth'] = true;
        dogPost['noseAuthDone'] = false;
        dogPost['noseAuth1Done'] = result['verification_step1_completed'] == true;
        dogPost['noseAuth2Done'] = result['verification_step2_completed'] == true;
        dogPost['noseAuth3Done'] = result['verification_step3_completed'] == true;
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    final token = AppUser.accessToken;

    if (text.isEmpty) return;

    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('로그인이 필요합니다.')),
      );
      return;
    }

    try {
      await ChatStore.sendMessage(
        token: token,
        roomId: widget.roomId,
        text: text,
      );

      _controller.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('메시지 전송 실패: $e')),
      );
    }
  }

  String _formatFirestoreTime(dynamic value) {
    try {
      if (value is Timestamp) {
        final dateTime = value.toDate();
        final hour = dateTime.hour > 12 ? dateTime.hour - 12 : dateTime.hour;
        final minute = dateTime.minute.toString().padLeft(2, '0');
        final period = dateTime.hour < 12 ? '오전' : '오후';
        return '$period ${hour == 0 ? 12 : hour}:$minute';
      }
    } catch (_) {}

    return '';
  }

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 1000,
        maxHeight: 1000,
        imageQuality: 85,
      );
      if (!mounted) return;
      if (image != null) {
        final token = AppUser.accessToken;
        if (token.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('로그인이 필요합니다.')),
          );
          return;
        }
        await ChatStore.sendImageMessage(
          token: token,
          roomId: widget.roomId,
          image: File(image.path),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('이미지를 불러오는데 실패했습니다: $e')),
      );
    }
  }

  void _showImagePicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.camera_alt, color: AppColors.text),
                  title: const Text(
                    '카메라로 촬영',
                    style: TextStyle(color: AppColors.text),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _pickImage(ImageSource.camera);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.photo_library, color: AppColors.text),
                  title: const Text(
                    '갤러리에서 선택',
                    style: TextStyle(color: AppColors.text),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _pickImage(ImageSource.gallery);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _bubble(Map<String, dynamic> msg) {
    final bool me = msg['me'] as bool;
    final String? imageUrl = msg['imageUrl'] as String?;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: me ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!me)
            Container(
              width: 30,
              height: 30,
              margin: const EdgeInsets.only(right: 8),
              decoration: const BoxDecoration(
                color: AppColors.text,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.pets, color: AppColors.border, size: 16),
            ),

          Column(
            crossAxisAlignment:
            me ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (!me)
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 3),
                  child: Text(
                    dogPost['owner'] as String,
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppColors.text,
                    ),
                  ),
                ),
              Container(
                constraints: const BoxConstraints(maxWidth: 220),
                padding: imageUrl != null
                    ? const EdgeInsets.all(4)
                    : const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: me ? AppColors.text : AppColors.border,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(me ? 18 : 4),
                    bottomRight: Radius.circular(me ? 4 : 18),
                  ),
                ),
                child: imageUrl != null
                    ? ClipRRect(
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(me ? 16 : 2),
                    bottomRight: Radius.circular(me ? 2 : 16),
                  ),
                  child: Image.network(
                    ApiConfig.fileUrl(imageUrl),
                    width: 180,
                    height: 180,
                    fit: BoxFit.cover,
                    errorBuilder: (_, error, stackTrace) => const SizedBox(
                      width: 180,
                      height: 120,
                      child: Center(
                        child: Icon(Icons.broken_image, color: AppColors.text),
                      ),
                    ),
                  ),
                )
                    : Text(
                  msg['text'] as String,
                  style: TextStyle(
                    fontSize: 13,
                    color: me ? Colors.white : AppColors.darkBrown,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 3, left: 4, right: 4),
                child: Row(
                  children: [
                    if (me)
                      const Icon(
                        Icons.done_all,
                        size: 12,
                        color: AppColors.text,
                      ),
                    const SizedBox(width: 3),
                    Text(
                      msg['time'] as String,
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.text,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isReserved = _postStatus == 'RESERVED' || dogPost['isReserved'] == true;
    final bool isAdopted = _postStatus == 'COMPLETED' || dogPost['isAdopted'] == true;

    return Scaffold(
      backgroundColor: AppColors.darkBrown,

      appBar: AppBar(
        backgroundColor: AppColors.darkBrown,
        elevation: 0,
        centerTitle: false,
        iconTheme: const IconThemeData(color: Colors.white),

        title: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                color: AppColors.text,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.pets, color: AppColors.border, size: 20),
            ),

            const SizedBox(width: 10),

            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  dogPost['owner'] as String,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Row(
                  children: [
                    const Icon(
                      Icons.star_rounded,
                      color: Colors.amber,
                      size: 14,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '${ownerUser['rating']}',
                      style: const TextStyle(
                        color: AppColors.beige,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),

            const Spacer(),

            if (!isAdopted) ...[
              GestureDetector(
                onTap: _isActionLoading ? null : _toggleReservation,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: isReserved
                        ? AppColors.darkBrown
                        : Colors.transparent,
                    border: Border.all(
                      color: AppColors.border,
                      width: 1.6,
                    ),
                  ),
                  child: Text(
                    isReserved ? '예약취소' : '예약하기',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.border,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],

            if (isAdopted)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: AppColors.text,
                ),
                child: const Text(
                  '입양완료',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),

            if (!isAdopted)
              GestureDetector(
                onTap: _isActionLoading ? null : _adoptDog,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.text,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    '분양하기',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),

      body: Column(
        children: [
          // 강아지 정보 카드
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.text,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: AppColors.darkBrown,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.pets,
                      color: AppColors.border,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.name,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${widget.breed} · ${dogPost['age']} · ${dogPost['gender']}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.beige,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${dogPost['region']} · ${dogPost['price']}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.beige,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.darkBrown,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      isAdopted ? '분양완료' : (isReserved ? '예약중' : '분양중'),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppColors.border,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 채팅 영역
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              child: Column(
                children: [
                  // 날짜 구분선
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.border,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '${DateTime.now().year}.${DateTime.now().month.toString().padLeft(2, '0')}.${DateTime.now().day.toString().padLeft(2, '0')}.',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.text,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // 메시지 리스트
                  Expanded(
                    child: StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('chat_rooms')
                          .doc(widget.roomId)
                          .collection('messages')
                          .orderBy('created_at')
                          .snapshots(),
                      builder: (context, snapshot) {
                        if (!snapshot.hasData) {
                          return const Center(child: CircularProgressIndicator());
                        }

                        final docs = snapshot.data!.docs;

                        if (docs.isEmpty) {
                          return const Center(
                            child: Text(
                              '아직 메시지가 없습니다.',
                              style: TextStyle(color: AppColors.text),
                            ),
                          );
                        }

                        return ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          itemCount: docs.length,
                          itemBuilder: (context, index) {
                            final data = docs[index].data() as Map<String, dynamic>;

                            final currentUid = FirebaseAuth.instance.currentUser?.uid;

                            return _bubble({
                              'text': data['text'] ?? '',
                              'imageUrl': data['type'] == 'IMAGE'
                                  ? data['image_url']?.toString()
                                  : null,
                              'me': data['sender_uid'] == currentUid,
                              'time': _formatFirestoreTime(data['created_at']),
                            });
                          },
                        );
                      },
                    ),
                  ),

                  // 입력창
                  Container(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 14),
                    decoration: const BoxDecoration(
                      color: AppColors.background,
                      border: Border(
                        top: BorderSide(color: AppColors.border),
                      ),
                    ),
                    child: Row(
                      children: [
                        // 카메라 버튼
                        GestureDetector(
                          onTap: () => _showImagePicker(context),
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: const BoxDecoration(
                              color: AppColors.light,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.camera_alt,
                              color: AppColors.text,
                              size: 18,
                            ),
                          ),
                        ),

                        const SizedBox(width: 6),

                        // 텍스트 입력
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF5ECD8),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: TextField(
                              controller: _controller,
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.text,
                              ),
                              decoration: const InputDecoration(
                                hintText: '메시지 입력...',
                                hintStyle: TextStyle(color: AppColors.text),
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(width: 6),

                        // 전송 버튼
                        GestureDetector(
                          onTap: _sendMessage,
                          child: Container(
                            width: 36,
                            height: 36,
                            decoration: const BoxDecoration(
                              color: AppColors.text,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.send,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
