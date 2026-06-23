import 'dart:io';
import 'dart:math' as math;
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'api_config.dart';
import 'package:http_parser/http_parser.dart';

class PostService {
  Future<List<dynamic>> getPosts({
    String status = 'OPEN',
    int page = 0,
    int size = 20,
  }) async {
    try {
      final response = await http.get(
        Uri.parse(
          ApiConfig.api('/adoption-posts?status=$status&page=$page&size=$size'),
        ),
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

  /// 내 분양글 목록
  /// GET /api/adoption-posts/me
  Future<List<dynamic>> getMyPosts(String accessToken) async {
    try {
      if (accessToken.isEmpty) return [];
      final response = await http.get(
        Uri.parse(ApiConfig.api('/adoption-posts/me')),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Accept': 'application/json',
        },
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

  /// 특정 작성자의 게시글 목록
  Future<List<dynamic>> getPostsByAuthor(String authorDisplayName) async {
    try {
      final results = await Future.wait([
        getPosts(status: 'OPEN'),
        getPosts(status: 'RESERVED'),
        getPosts(status: 'COMPLETED'),
      ]);
      return results
          .expand((list) => list)
          .where((p) => p['author_display_name'] == authorDisplayName)
          .toList();
    } catch (e) {
      return [];
    }
  }

  Future<Map<String, dynamic>> createPost({
    required String accessToken,
    required String dogId,
    required String title,
    required String content,
    required File profileImage,
  }) async {
    try {
      final request = await buildCreatePostRequest(
        accessToken: accessToken,
        dogId: dogId,
        title: title,
        content: content,
        profileImage: profileImage,
      );
      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);
      final data = response.bodyBytes.isNotEmpty
          ? jsonDecode(utf8.decode(response.bodyBytes))
          : {};
      if (response.statusCode == 200 || response.statusCode == 201) {
        return {'success': true, 'data': data};
      } else {
        return {
          'success': false,
          'message': data['message'] ?? '분양글 생성 실패',
          'error_code': data['error_code'],
          'status_code': response.statusCode,
        };
      }
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  Future<http.MultipartRequest> buildCreatePostRequest({
    required String accessToken,
    required String dogId,
    required String title,
    required String content,
    required File profileImage,
  }) async {
    final uri = Uri.parse(ApiConfig.api('/adoption-posts'));
    final request = http.MultipartRequest('POST', uri);
    if (ApiConfig.enableAuthHeader && accessToken.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $accessToken';
    }
    request.headers['Accept'] = 'application/json';
    request.fields['user_id'] = ApiConfig.devUserId.toString();
    request.fields['dog_id'] = dogId;
    request.fields['title'] = title;
    request.fields['content'] = content;
    request.fields['status'] = 'OPEN';
    request.files.add(await _multipartImageFile('profile_image', profileImage));
    return request;
  }

  Future<Map<String, dynamic>?> getPostDetail(int postId) async {
    try {
      final response = await http.get(
        Uri.parse(ApiConfig.api('/adoption-posts/$postId')),
        headers: {'Accept': 'application/json'},
      );
      if (response.statusCode == 200) return jsonDecode(response.body);
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<Map<String, dynamic>> updatePostStatus({
    required String accessToken,
    required int postId,
    required String status,
  }) async {
    try {
      final response = await http.patch(
        Uri.parse(ApiConfig.api('/adoption-posts/$postId/status')),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode({'status': status}),
      );
      final data = response.body.isNotEmpty ? jsonDecode(response.body) : {};
      if (response.statusCode == 200) {
        return {'success': true, 'data': data};
      } else {
        return {'success': false, 'message': data['message'] ?? '상태 변경 실패'};
      }
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  // ──────────────────────────────────────────
  // 6-1. 좋아요 추가
  // PUT /api/adoption-posts/{post_id}/like
  // ──────────────────────────────────────────
  Future<bool> likePost({
    required String accessToken,
    required int postId,
  }) async {
    try {
      final response = await http.put(
        Uri.parse(ApiConfig.api('/adoption-posts/$postId/like')),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  // ──────────────────────────────────────────
  // 6-2. 좋아요 취소
  // DELETE /api/adoption-posts/{post_id}/like
  // ──────────────────────────────────────────
  Future<bool> unlikePost({
    required String accessToken,
    required int postId,
  }) async {
    try {
      final response = await http.delete(
        Uri.parse(ApiConfig.api('/adoption-posts/$postId/like')),
        headers: {'Authorization': 'Bearer $accessToken'},
      );
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  Future<http.MultipartFile> _multipartImageFile(
    String fieldName,
    File image,
  ) async {
    final mimeType = await _detectImageMimeType(image);
    if (mimeType == null) {
      throw Exception('지원하지 않는 이미지 형식입니다. JPG, PNG, WEBP 이미지를 선택해주세요.');
    }
    final extension = _extensionForMimeType(mimeType);
    final filename = '${_safeBaseName(image.path, 'profile')}.$extension';
    return http.MultipartFile.fromBytes(
      fieldName,
      await image.readAsBytes(),
      filename: filename,
      contentType: MediaType.parse(mimeType),
    );
  }

  Future<String?> _detectImageMimeType(File image) async {
    final header = await _readHeaderBytes(image, 16);
    if (_startsWith(header, const [0xFF, 0xD8, 0xFF])) {
      return 'image/jpeg';
    }
    if (_startsWith(header, const [
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
    ])) {
      return 'image/png';
    }
    if (header.length >= 12 &&
        _asciiAt(header, 0, 'RIFF') &&
        _asciiAt(header, 8, 'WEBP')) {
      return 'image/webp';
    }
    return _mimeTypeFromExtension(image.path);
  }

  Future<List<int>> _readHeaderBytes(File file, int byteCount) async {
    final length = await file.length();
    if (length <= 0) return const [];

    final randomAccessFile = await file.open();
    try {
      return await randomAccessFile.read(math.min(byteCount, length));
    } finally {
      await randomAccessFile.close();
    }
  }

  static bool _startsWith(List<int> bytes, List<int> prefix) {
    if (bytes.length < prefix.length) return false;
    for (var index = 0; index < prefix.length; index += 1) {
      if (bytes[index] != prefix[index]) return false;
    }
    return true;
  }

  static bool _asciiAt(List<int> bytes, int offset, String text) {
    if (bytes.length < offset + text.length) return false;
    for (var index = 0; index < text.length; index += 1) {
      if (bytes[offset + index] != text.codeUnitAt(index)) return false;
    }
    return true;
  }

  static String? _mimeTypeFromExtension(String path) {
    final extension = _extensionFromPath(path);
    switch (extension) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
    }
    return null;
  }

  static String _extensionForMimeType(String mimeType) {
    switch (mimeType.toLowerCase()) {
      case 'image/jpeg':
      case 'image/jpg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case 'image/webp':
        return 'webp';
    }
    throw Exception('지원하지 않는 이미지 형식입니다. JPG, PNG, WEBP 이미지를 선택해주세요.');
  }

  static String _safeBaseName(String path, String fallbackBaseName) {
    final filename = path.split(RegExp(r'[\\/]')).last;
    final withoutExtension = _stripExtension(filename);
    final sanitized = withoutExtension
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^[_\-.]+|[_\-.]+$'), '');
    if (sanitized.isNotEmpty) return sanitized;
    return fallbackBaseName;
  }

  static String _stripExtension(String filename) {
    final lastDot = filename.lastIndexOf('.');
    if (lastDot <= 0) return filename;
    return filename.substring(0, lastDot);
  }

  static String _extensionFromPath(String path) {
    final filename = path.split(RegExp(r'[\\/]')).last;
    final lastDot = filename.lastIndexOf('.');
    if (lastDot < 0 || lastDot == filename.length - 1) return '';
    return filename.substring(lastDot + 1).toLowerCase();
  }
}
