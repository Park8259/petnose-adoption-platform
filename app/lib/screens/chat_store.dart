import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../services/api_config.dart';

class ChatStore {
  static Future<Map<String, dynamic>> createOrGetChatRoom({
    required String token,
    required int postId,
  }) async {
    final response = await http.post(
      Uri.parse(ApiConfig.api('/chat/rooms')),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'post_id': postId,
      }),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      return jsonDecode(utf8.decode(response.bodyBytes));
    }

    throw Exception('채팅방 생성 실패: ${response.body}');
  }

  static Future<List<Map<String, dynamic>>> fetchChatRooms({
    required String token,
    int page = 0,
    int size = 20,
  }) async {
    final response = await http.get(
      Uri.parse(ApiConfig.api('/chat/rooms?page=$page&size=$size')),
      headers: {
        'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final items = data['items'] as List<dynamic>? ?? [];

      return items.map((e) => Map<String, dynamic>.from(e)).toList();
    }

    throw Exception('채팅방 목록 불러오기 실패: ${response.body}');
  }

  static Future<Map<String, dynamic>> sendMessage({
    required String token,
    required String roomId,
    required String text,
  }) async {
    final response = await http.post(
      Uri.parse(ApiConfig.api('/chat/rooms/$roomId/messages')),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'text': text,
        'client_message_id': DateTime.now().millisecondsSinceEpoch.toString(),
      }),
    );

    if (response.statusCode == 201 || response.statusCode == 200) {
      return jsonDecode(utf8.decode(response.bodyBytes));
    }

    throw Exception('메시지 전송 실패: ${response.body}');
  }

  static Future<Map<String, dynamic>> sendImageMessage({
    required String token,
    required String roomId,
    required File image,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse(ApiConfig.api('/chat/rooms/$roomId/messages/images')),
    );
    request.headers['Authorization'] = 'Bearer $token';
    request.headers['Accept'] = 'application/json';
    request.fields['client_message_id'] =
        DateTime.now().millisecondsSinceEpoch.toString();

    final mimeType = _mimeTypeFromPath(image.path);
    request.files.add(
      await http.MultipartFile.fromPath(
        'image',
        image.path,
        contentType: MediaType.parse(mimeType),
      ),
    );

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode == 201 || response.statusCode == 200) {
      return jsonDecode(utf8.decode(response.bodyBytes));
    }

    throw Exception('이미지 메시지 전송 실패: ${response.body}');
  }

  static Future<Map<String, dynamic>> reserveRoom({
    required String token,
    required String roomId,
  }) async {
    final response = await http.post(
      Uri.parse(ApiConfig.api('/chat/rooms/$roomId/reservation')),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (response.statusCode == 200) {
      return jsonDecode(utf8.decode(response.bodyBytes));
    }

    throw Exception('예약 실패: ${response.body}');
  }

  static Future<Map<String, dynamic>> cancelReservation({
    required String token,
    required String roomId,
  }) async {
    final response = await http.delete(
      Uri.parse(ApiConfig.api('/chat/rooms/$roomId/reservation')),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (response.statusCode == 200) {
      return jsonDecode(utf8.decode(response.bodyBytes));
    }

    throw Exception('예약 취소 실패: ${response.body}');
  }

  static Future<Map<String, dynamic>> completeAdoption({
    required String token,
    required String roomId,
  }) async {
    final response = await http.post(
      Uri.parse(ApiConfig.api('/chat/rooms/$roomId/completion')),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (response.statusCode == 200) {
      return jsonDecode(utf8.decode(response.bodyBytes));
    }

    throw Exception('분양 완료 실패: ${response.body}');
  }

  static Future<void> markRoomAsRead({
    required String token,
    required String roomId,
  }) async {
    final response = await http.patch(
      Uri.parse(ApiConfig.api('/chat/rooms/$roomId/read')),
      headers: {
        'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode != 200) {
      throw Exception('읽음 처리 실패: ${response.body}');
    }
  }
  static Future<Map<String, dynamic>> getFirebaseCustomToken({
    required String token,
  }) async {
    final response = await http.post(
      Uri.parse(ApiConfig.api('/firebase/custom-token')),
      headers: {
        'Authorization': 'Bearer $token',
      },
    );

    if (response.statusCode == 200) {
      return jsonDecode(utf8.decode(response.bodyBytes));
    }

    throw Exception('Firebase 토큰 발급 실패: ${response.body}');
  }

  static Future<void> registerFcmToken({
    required String token,
    required String fcmToken,
    String platform = 'ANDROID',
  }) async {
    final response = await http.put(
      Uri.parse(ApiConfig.api('/users/me/fcm-token')),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({
        'fcm_token': fcmToken,
        'platform': platform,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('FCM 토큰 등록 실패: ${response.body}');
    }
  }

  static String _mimeTypeFromPath(String path) {
    final ext = path.split('.').last.toLowerCase();
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      default:
        return 'image/jpeg';
    }
  }
}
