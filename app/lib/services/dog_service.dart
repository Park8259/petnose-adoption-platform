import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:nosetag_app/models/profile_nose_preview_response.dart';

import 'api_config.dart';

class DogService {
  static const String profileImageField = 'profile_image';
  static const String profileNosePreviewImageField = profileImageField;
  static const String profileNosePreviewPath = '/dogs/profile-nose-preview';
  static const String faceCheckImageField = 'face_check_image';
  static const String noseImagesField = 'nose_image';

  Future<ProfileNosePreviewResponse> checkProfileNosePreview({
    required File profileImage,
  }) async {
    try {
      final uri = Uri.parse(ApiConfig.api(profileNosePreviewPath));
      final request = http.MultipartRequest('POST', uri);

      request.headers['Accept'] = 'application/json';
      request.files.add(
        await _multipartImageFile(
          profileNosePreviewImageField,
          profileImage,
          fallbackBaseName: 'profile_preview',
        ),
      );

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 30),
      );
      final response = await http.Response.fromStream(streamedResponse);
      final data = _decodeResponseBody(response);
      final isSuccess = response.statusCode >= 200 && response.statusCode < 300;

      if (isSuccess) {
        return ProfileNosePreviewResponse.fromJson(
          data,
          httpStatusCode: response.statusCode,
        );
      }

      return ProfileNosePreviewResponse.fromJson(
        data,
        success: false,
        httpStatusCode: response.statusCode,
      );
    } on _UnsupportedImageTypeException catch (e) {
      return ProfileNosePreviewResponse.failure(
        message: e.toString(),
        errorCode: 'INVALID_IMAGE_TYPE',
      );
    } on TimeoutException {
      return ProfileNosePreviewResponse.failure(message: '서버 응답 시간이 초과되었습니다.');
    } catch (e) {
      return ProfileNosePreviewResponse.failure(message: '서버에 연결할 수 없습니다: $e');
    }
  }

  Future<ProfileNosePreviewResponse> previewProfileNose(File image) {
    return checkProfileNosePreview(profileImage: image);
  }

  Future<Map<String, dynamic>> registerDog({
    required String accessToken,
    required String name,
    required String breed,
    required String gender,
    required String age,
    required String price,
    required String dogRegion,
    required String health,
    required String description,
    required List<File> noseImages,
    File? profileImage,
    required File faceCheckImage,
  }) async {
    try {
      final request = await buildRegisterDogRequest(
        accessToken: accessToken,
        name: name,
        breed: breed,
        gender: gender,
        age: age,
        price: price,
        dogRegion: dogRegion,
        health: health,
        description: description,
        noseImages: noseImages,
        profileImage: profileImage,
        faceCheckImage: faceCheckImage,
      );

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      final Map<String, dynamic> data = response.body.isNotEmpty
          ? jsonDecode(utf8.decode(response.bodyBytes))
          : {};

      if (response.statusCode == 200 || response.statusCode == 201) {
        return {'success': true, 'data': data};
      } else {
        return {
          'success': false,
          'message': registrationFailureMessage(data),
          'error_code': data['error_code'],
          'details': data['details'],
          'status_code': response.statusCode,
        };
      }
    } on _UnsupportedImageTypeException catch (e) {
      return {
        'success': false,
        'message': e.toString(),
        'error_code': 'INVALID_IMAGE_TYPE',
      };
    } catch (e) {
      return {'success': false, 'message': e.toString()};
    }
  }

  Future<http.MultipartRequest> buildRegisterDogRequest({
    required String accessToken,
    required String name,
    required String breed,
    required String gender,
    required String age,
    required String price,
    required String dogRegion,
    required String health,
    required String description,
    required List<File> noseImages,
    File? profileImage,
    required File faceCheckImage,
  }) async {
    final uri = Uri.parse(ApiConfig.api('/dogs/register'));
    final request = http.MultipartRequest('POST', uri);

    if (ApiConfig.enableAuthHeader && accessToken.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $accessToken';
    }
    request.headers['Accept'] = 'application/json';

    request.fields['user_id'] = ApiConfig.devUserId.toString();
    request.fields['name'] = name;
    request.fields['breed'] = breed;
    request.fields['gender'] = gender;
    request.fields['age'] = age;
    request.fields['price'] = price;
    request.fields['dog_region'] = dogRegion;
    request.fields['health'] = health;
    request.fields['description'] = description;

    if (profileImage != null) {
      request.files.add(
        await _multipartImageFile(
          profileImageField,
          profileImage,
          fallbackBaseName: 'profile',
        ),
      );
    }

    request.files.add(
      await _multipartImageFile(
        faceCheckImageField,
        faceCheckImage,
        fallbackBaseName: 'face_check',
      ),
    );

    for (var index = 0; index < noseImages.length; index += 1) {
      final image = noseImages[index];
      request.files.add(
        await _multipartImageFile(
          noseImagesField,
          image,
          fallbackBaseName: 'nose_${index + 1}',
        ),
      );
    }

    debugPrint(
      '[DogService] register multipart '
      'profile_image_present=${profileImage != null} '
      'face_check_image_present=true '
      'nose_count=${noseImages.length} '
      'files=${request.files.map((file) => '${file.field}:${file.filename}:${file.contentType}').join(',')}',
    );

    return request;
  }

  static String registrationFailureMessage(Map<String, dynamic> data) {
    final errorCode = data['error_code']?.toString();
    final baseMessage = data['message']?.toString() ?? '강아지 등록 실패';
    final details = data['details'];
    final failureReason = _detailString(details, 'failure_reason');

    if (errorCode == 'FACE_CHECK_IMAGE_REQUIRED') {
      return '얼굴·코 확인용 정면 사진이 필요합니다.';
    }

    if (errorCode == 'PROFILE_CENTROID_MISMATCH') {
      const friendlyMessage = '얼굴 정면 사진과 비문 사진이 충분히 일치하지 않습니다.';
      final scorePercent = _detailPercent(
        details,
        percentKey: 'similarity_percent',
        scoreKey: 'similarity_score',
      );
      final thresholdPercent = _detailPercent(
        details,
        percentKey: 'threshold_percent',
        scoreKey: 'threshold',
      );
      if (scorePercent != null && thresholdPercent != null) {
        return '$friendlyMessage\n일치도 $scorePercent% / 기준 $thresholdPercent%';
      }
      return friendlyMessage;
    }

    if (errorCode == 'PROFILE_FACE_EMBED_FAILED' &&
        failureReason != null &&
        failureReason.isNotEmpty) {
      return '$baseMessage\n사유: $failureReason';
    }

    return baseMessage;
  }

  Future<http.MultipartFile> _multipartImageFile(
    String fieldName,
    File image, {
    required String fallbackBaseName,
  }) async {
    final meta = await _imageUploadMeta(image, fallbackBaseName);
    return http.MultipartFile.fromBytes(
      fieldName,
      await image.readAsBytes(),
      filename: meta.filename,
      contentType: meta.contentType,
    );
  }

  Map<String, dynamic> _decodeResponseBody(http.Response response) {
    if (response.bodyBytes.isEmpty) return {};
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map<String, dynamic>) return decoded;
    return {'message': decoded.toString()};
  }

  static String? _detailString(Object? details, String key) {
    if (details is Map && details[key] != null) {
      return details[key].toString();
    }
    return null;
  }

  static String? _detailPercent(
    Object? details, {
    required String percentKey,
    required String scoreKey,
  }) {
    if (details is! Map) return null;
    final percent = details[percentKey];
    if (percent != null) return percent.toString();

    final score = details[scoreKey];
    if (score is num) return (score * 100).toStringAsFixed(1);
    return null;
  }

  Future<_ImageUploadMeta> _imageUploadMeta(
    File image,
    String fallbackBaseName,
  ) async {
    final detectedMimeType = await _detectImageMimeType(image);
    if (detectedMimeType == null) {
      throw _UnsupportedImageTypeException();
    }
    final extension = _extensionForMimeType(detectedMimeType);
    final baseName = _safeBaseName(image.path, fallbackBaseName);
    return _ImageUploadMeta(
      filename: '$baseName.$extension',
      contentType: MediaType.parse(detectedMimeType),
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
    throw _UnsupportedImageTypeException();
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

class _ImageUploadMeta {
  final String filename;
  final MediaType contentType;

  const _ImageUploadMeta({required this.filename, required this.contentType});
}

class _UnsupportedImageTypeException implements Exception {
  const _UnsupportedImageTypeException();

  @override
  String toString() {
    return '지원하지 않는 이미지 형식입니다. JPG, PNG, WEBP 이미지를 선택해주세요.';
  }
}
