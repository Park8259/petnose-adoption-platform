class ProfileNosePreviewResponse {
  final bool success;
  final int? httpStatusCode;
  final bool extracted;
  final double? confidence;
  final int? cropWidth;
  final int? cropHeight;
  final String? failureReason;
  final String? qualityPurpose;
  final bool? qualityPassed;
  final double? noseAreaRatio;
  final double? noseWidthRatio;
  final double? noseHeightRatio;
  final double? edgeMarginRatio;
  final double? centerX;
  final double? centerY;
  final String? qualityFailureReason;
  final String? message;
  final String? errorCode;

  const ProfileNosePreviewResponse({
    required this.success,
    this.httpStatusCode,
    required this.extracted,
    this.confidence,
    this.cropWidth,
    this.cropHeight,
    this.failureReason,
    this.qualityPurpose,
    this.qualityPassed,
    this.noseAreaRatio,
    this.noseWidthRatio,
    this.noseHeightRatio,
    this.edgeMarginRatio,
    this.centerX,
    this.centerY,
    this.qualityFailureReason,
    this.message,
    this.errorCode,
  });

  factory ProfileNosePreviewResponse.fromJson(
    Map<String, dynamic> json, {
    bool success = true,
    int? httpStatusCode,
  }) {
    final preview = _previewMap(json);
    final quality = _mapOrNull(preview['quality']);
    return ProfileNosePreviewResponse(
      success: success,
      httpStatusCode: httpStatusCode,
      extracted: preview['extracted'] == true,
      confidence: _asDouble(preview['confidence']),
      cropWidth: _asInt(preview['crop_width'] ?? preview['cropWidth']),
      cropHeight: _asInt(preview['crop_height'] ?? preview['cropHeight']),
      failureReason: _asString(
        preview['failure_reason'] ?? preview['failureReason'],
      ),
      qualityPurpose: _asString(quality?['purpose']),
      qualityPassed: _asBool(quality?['passed']),
      noseAreaRatio: _asDouble(quality?['nose_area_ratio']),
      noseWidthRatio: _asDouble(quality?['nose_width_ratio']),
      noseHeightRatio: _asDouble(quality?['nose_height_ratio']),
      edgeMarginRatio: _asDouble(quality?['edge_margin_ratio']),
      centerX: _asDouble(quality?['center_x']),
      centerY: _asDouble(quality?['center_y']),
      qualityFailureReason: _asString(
        quality?['failure_reason'] ?? quality?['failureReason'],
      ),
      message: _asString(json['message'] ?? json['error_message']),
      errorCode: _asString(json['error_code'] ?? json['code']),
    );
  }

  factory ProfileNosePreviewResponse.failure({
    int? httpStatusCode,
    String? message,
    String? errorCode,
  }) {
    return ProfileNosePreviewResponse(
      success: false,
      httpStatusCode: httpStatusCode,
      extracted: false,
      message: message ?? '코 영역 확인 요청에 실패했습니다.',
      errorCode: errorCode,
    );
  }

  bool get isDetectorUnavailable =>
      failureReason == 'DETECTOR_UNAVAILABLE' ||
      failureReason == 'PROFILE_NOSE_PREVIEW_DISABLED' ||
      errorCode == 'DETECTOR_UNAVAILABLE' ||
      errorCode == 'PROFILE_NOSE_PREVIEW_DISABLED';

  String? get effectiveFailureReason => qualityFailureReason ?? failureReason;

  String? get faceCheckFailureMessage =>
      friendlyFaceCheckFailureMessage(effectiveFailureReason);

  static String? friendlyFaceCheckFailureMessage(String? failureReason) {
    switch (failureReason) {
      case 'NOSE_TOO_LARGE_FOR_FACE_CHECK':
        return '코만 너무 크게 나온 사진입니다. 얼굴이 조금 더 보이는 정면 사진을 선택해주세요.';
      case 'NOSE_TOO_SMALL_FOR_FACE_CHECK':
        return '코가 너무 작게 보입니다. 얼굴과 코가 더 잘 보이는 사진을 선택해주세요.';
      case 'NOSE_TOUCHES_IMAGE_EDGE':
        return '코가 사진 가장자리에 너무 가깝습니다. 얼굴 전체가 조금 더 보이게 촬영해주세요.';
      case 'NOSE_OFF_CENTER':
        return '코가 사진 중앙에서 너무 벗어났습니다. 정면 사진을 선택해주세요.';
      case 'MULTIPLE_NOSES_DETECTED':
        return '여러 코 후보가 감지되었습니다. 한 마리만 나온 사진을 선택해주세요.';
      case 'NO_NOSE_DETECTED':
        return '코 영역을 찾지 못했습니다. 얼굴과 코가 함께 보이는 정면 사진을 선택해주세요.';
      case 'LOW_CONFIDENCE':
        return '정면 사진에서 비문 영역을 충분히 확인하지 못했습니다. 더 선명한 정면 사진을 선택해주세요.';
      case 'INVALID_IMAGE':
        return '이미지를 읽지 못했습니다. 다른 사진을 선택해주세요.';
    }
    return null;
  }

  static Map<String, dynamic> _previewMap(Map<String, dynamic> json) {
    final nested = json['profile_nose_preview'] ?? json['profileNosePreview'];
    if (nested is Map<String, dynamic>) return nested;
    if (nested is Map) return Map<String, dynamic>.from(nested);
    return json;
  }
}

Map<String, dynamic>? _mapOrNull(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

String? _asString(dynamic value) {
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

double? _asDouble(dynamic value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

bool? _asBool(dynamic value) {
  if (value is bool) return value;
  if (value == null) return null;
  final text = value.toString().toLowerCase();
  if (text == 'true') return true;
  if (text == 'false') return false;
  return null;
}
