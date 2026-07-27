import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_config.dart';

class UserService {
  /// 내 정보 조회
  /// GET /api/users/me
  Future<Map<String, dynamic>?> getMe(String accessToken) async {
    try {
      if (accessToken.isEmpty) return null;
      final response = await http.get(
        Uri.parse(ApiConfig.api('/users/me')),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  /// 6-3. 내가 좋아요한 게시글 목록
  /// GET /api/adoption-posts/liked/me
  Future<List<dynamic>> getLikedPosts(String accessToken) async {
    try {
      if (accessToken.isEmpty) return [];
      final response = await http.get(
        Uri.parse(ApiConfig.api('/adoption-posts/liked/me?page=0&size=20')),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['items'] ?? [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// 4-3. 내가 입양한 강아지 목록
  /// GET /api/dogs/adopted/me
  Future<List<dynamic>> getAdoptedDogs(String accessToken) async {
    try {
      if (accessToken.isEmpty) return [];
      final response = await http.get(
        Uri.parse(ApiConfig.api('/dogs/adopted/me?page=0&size=20')),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['items'] ?? [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }
}