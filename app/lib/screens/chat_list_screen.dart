import 'package:flutter/material.dart';
import 'AppColor.dart';
import 'chat_store.dart';
import 'chat_room_screen.dart';
import 'AppData.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  List<Map<String, dynamic>> chatList = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    loadChatRooms();
  }

  Future<void> loadChatRooms() async {
    final token = AppUser.accessToken;

    if (token.isEmpty) {
      setState(() {
        isLoading = false;
      });
      return;
    }

    try {
      final rooms = await ChatStore.fetchChatRooms(token: token);

      final Map<dynamic, Map<String, dynamic>> uniqueRooms = {};

      for (final room in rooms) {
        final postId = room['post_id'];

        if (postId == null) continue;

        if (!uniqueRooms.containsKey(postId)) {
          uniqueRooms[postId] = room;
        }
      }

      setState(() {
        chatList = uniqueRooms.values.toList();
        isLoading = false;
      });
    } catch (e) {
      setState(() {
        isLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('채팅방 목록을 불러오지 못했습니다: $e')),
      );
    }
  }

  String formatTime(dynamic value) {
    if (value == null) return '';

    try {
      final dateTime = DateTime.parse(value.toString()).toLocal();
      return '${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: isLoading
            ? const Center(child: CircularProgressIndicator())
            : chatList.isEmpty
            ? const Center(
          child: Text(
            '아직 채팅방이 없습니다.',
            style: TextStyle(color: AppColors.text),
          ),
        )
            : ListView.separated(
          itemCount: chatList.length,
          separatorBuilder: (context, index) => Padding(
            padding: const EdgeInsets.only(left: 92),
            child: Divider(
              height: 1,
              thickness: 1,
              color: AppColors.border.withOpacity(0.6),
            ),
          ),
          itemBuilder: (context, index) {
            final chat = chatList[index];

            final roomId = chat['room_id'] ?? '';
            final postTitle = chat['post_title'] ?? '채팅방';
            final otherUserName =
                chat['other_user_display_name'] ?? '상대방';
            final message =
                chat['last_message_preview'] ?? '아직 메시지가 없습니다.';
            final time = formatTime(chat['last_message_at']);
            final count = chat['unread_count'] ?? 0;

            return InkWell(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatRoomScreen(
                      roomId: roomId,
                      name: otherUserName,
                      breed: postTitle,
                    ),
                  ),
                ).then((_) {
                  loadChatRooms();
                });
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: AppColors.border,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Icon(
                        Icons.pets,
                        color: AppColors.text,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                otherUserName,
                                style: const TextStyle(
                                  color: AppColors.darkBrown,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.light
                                        .withOpacity(0.3),
                                    borderRadius:
                                    BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    postTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: AppColors.text,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                time,
                                style: TextStyle(
                                  fontSize: 11,
                                  color:
                                  AppColors.text.withOpacity(0.55),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  message,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color:
                                    AppColors.text.withOpacity(0.8),
                                    fontWeight: count > 0
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (count > 0)
                                Container(
                                  width: 22,
                                  height: 22,
                                  alignment: Alignment.center,
                                  decoration: const BoxDecoration(
                                    color: AppColors.darkBrown,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Text(
                                    '$count',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}