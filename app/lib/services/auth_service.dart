import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_config.dart';

class AuthService {
  Future<Map<String, dynamic>> requestPasswordReset({
    required String email,
  }) async {
    try {
      final response = await http.post(
        Uri.parse(ApiConfig.api('/auth/password-reset/request')),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        body: jsonEncode({
          'email': email.trim(),
        }),
      );

      final data = response.bodyBytes.isNotEmpty
          ? jsonDecode(utf8.decode(response.bodyBytes))
          : {};

      if (response.statusCode == 200) {
        return {'success': true, 'data': data};
      }

      return {
        'success': false,
        'message': data['message'] ?? '비밀번호 찾기 요청 실패',
      };
    } catch (e) {
      return {'success': false, 'message': '네트워크 에러가 발생했습니다: $e'};
    }
  }

  Future<Map<String, dynamic>> register({
    required String email,
    required String password,
    required String name,
    required String phone,
    required String region,
    File? profileImage,
  }) async {
    try {
      final formattedPhone = phone.replaceAll(RegExp(r'[^0-9]'), '').trim();

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(ApiConfig.api('/auth/register')),
      );

      // 텍스트 필드
      request.fields['email']         = email.trim();
      request.fields['password']      = password;
      request.fields['display_name']  = name.trim();
      request.fields['contact_phone'] = formattedPhone;
      request.fields['region']        = region.trim();

      // 프로필 이미지 (optional)
      if (profileImage != null) {
        final ext = profileImage.path.split('.').last.toLowerCase();
        final mimeType = ext == 'png' ? 'image/png' : 'image/jpeg';
        request.files.add(
          await http.MultipartFile.fromPath(
            'profile_image',
            profileImage.path,
            contentType: MediaType.parse(mimeType),
          ),
        );
      }

      final streamed = await request.send().timeout(const Duration(seconds: 30));
      final response = await http.Response.fromStream(streamed);
      final data = jsonDecode(utf8.decode(response.bodyBytes));

      if (response.statusCode == 201 || response.statusCode == 200) {
        return {'success': true, 'data': data};
      } else {
        return {
          'success': false,
          'message': data['message'] ?? '회원가입 실패',
        };
      }
    } catch (e) {
      return {'success': false, 'message': '네트워크 에러가 발생했습니다: $e'};
    }
  }

  Future<Map<String, dynamic>> getMyProfile(String token) async {
    try {
      final response = await http.get(
        Uri.parse(ApiConfig.api('/users/me')),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 200) {
        return {'success': true, 'data': jsonDecode(response.body)};
      } else {
        return {'success': false, 'message': '프로필 로드 실패'};
      }
    } catch (e) {
      return {'success': false, 'message': '네트워크 오류: $e'};
    }
  }

  Future<Map<String, dynamic>> getMyAdoptionPosts(String token) async {
    try {
      final response = await http.get(
        Uri.parse(ApiConfig.api('/adoption-posts/me')),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 200) {
        return {'success': true, 'data': jsonDecode(response.body)};
      } else {
        return {'success': false, 'message': '게시글 목록 로드 실패'};
      }
    } catch (e) {
      return {'success': false, 'message': '네트워크 오류: $e'};
    }
  }

  // ──────────────────────────────────────────
  // 4-2. 내가 등록한 강아지 목록
  // GET /api/dogs/me
  // ──────────────────────────────────────────
  Future<Map<String, dynamic>> getMyDogs(String token) async {
    try {
      final response = await http.get(
        Uri.parse(ApiConfig.api('/dogs/me')),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
      );

      if (response.statusCode == 200) {
        return {'success': true, 'data': jsonDecode(response.body)};
      } else {
        return {'success': false, 'message': '강아지 목록 로드 실패'};
      }
    } catch (e) {
      return {'success': false, 'message': '네트워크 오류: $e'};
    }
  }

  Future<String> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('access_token') ?? '';
  }
}
