import 'package:flutter_test/flutter_test.dart';
import 'package:nosetag_app/models/profile_nose_preview_response.dart';
import 'package:nosetag_app/services/dog_service.dart';

void main() {
  test('parses extracted profile nose preview response', () {
    final response = ProfileNosePreviewResponse.fromJson({
      'extracted': true,
      'confidence': 0.95484,
      'crop_width': 224,
      'crop_height': 224,
      'failure_reason': null,
    });

    expect(response.success, isTrue);
    expect(response.extracted, isTrue);
    expect(response.confidence, 0.95484);
    expect(response.cropWidth, 224);
    expect(response.cropHeight, 224);
    expect(response.failureReason, isNull);
  });

  test('parses detector unavailable preview response', () {
    final response = ProfileNosePreviewResponse.fromJson({
      'extracted': false,
      'confidence': null,
      'crop_width': null,
      'crop_height': null,
      'failure_reason': 'DETECTOR_UNAVAILABLE',
    });

    expect(response.success, isTrue);
    expect(response.extracted, isFalse);
    expect(response.isDetectorUnavailable, isTrue);
    expect(response.effectiveFailureReason, 'DETECTOR_UNAVAILABLE');
  });

  test('parses profile preview disabled response', () {
    final response = ProfileNosePreviewResponse.fromJson({
      'extracted': false,
      'confidence': null,
      'crop_width': null,
      'crop_height': null,
      'failure_reason': 'PROFILE_NOSE_PREVIEW_DISABLED',
      'error_code': 'PROFILE_NOSE_PREVIEW_DISABLED',
      'message': '프로필 비문 미리보기 기능이 비활성화되어 있습니다.',
    });

    expect(response.success, isTrue);
    expect(response.extracted, isFalse);
    expect(response.isDetectorUnavailable, isTrue);
    expect(response.message, contains('비활성화'));
  });

  test('parses face check quality response', () {
    final response = ProfileNosePreviewResponse.fromJson({
      'extracted': false,
      'confidence': 0.92,
      'crop_width': null,
      'crop_height': null,
      'failure_reason': 'NOSE_TOO_LARGE_FOR_FACE_CHECK',
      'quality': {
        'purpose': 'face_check',
        'passed': false,
        'nose_area_ratio': 0.48,
        'nose_width_ratio': 0.75,
        'nose_height_ratio': 0.70,
        'edge_margin_ratio': 0.08,
        'center_x': 0.50,
        'center_y': 0.55,
        'failure_reason': 'NOSE_TOO_LARGE_FOR_FACE_CHECK',
      },
    });

    expect(response.extracted, isFalse);
    expect(response.qualityPurpose, 'face_check');
    expect(response.qualityPassed, isFalse);
    expect(response.noseAreaRatio, 0.48);
    expect(response.effectiveFailureReason, 'NOSE_TOO_LARGE_FOR_FACE_CHECK');
  });

  test('maps face check quality failures to friendly messages', () {
    expect(
      ProfileNosePreviewResponse.friendlyFaceCheckFailureMessage(
        'NOSE_TOO_LARGE_FOR_FACE_CHECK',
      ),
      contains('코만 너무 크게'),
    );
    expect(
      ProfileNosePreviewResponse.friendlyFaceCheckFailureMessage(
        'NOSE_TOO_SMALL_FOR_FACE_CHECK',
      ),
      contains('코가 너무 작게'),
    );
    expect(
      ProfileNosePreviewResponse.friendlyFaceCheckFailureMessage(
        'NOSE_TOUCHES_IMAGE_EDGE',
      ),
      contains('가장자리'),
    );
    expect(
      ProfileNosePreviewResponse.friendlyFaceCheckFailureMessage(
        'NOSE_OFF_CENTER',
      ),
      contains('중앙'),
    );
    expect(
      ProfileNosePreviewResponse.friendlyFaceCheckFailureMessage(
        'MULTIPLE_NOSES_DETECTED',
      ),
      contains('여러 코 후보'),
    );
    expect(
      ProfileNosePreviewResponse.friendlyFaceCheckFailureMessage(
        'NO_NOSE_DETECTED',
      ),
      contains('얼굴과 코가 함께'),
    );
    expect(
      ProfileNosePreviewResponse.friendlyFaceCheckFailureMessage(
        'LOW_CONFIDENCE',
      ),
      contains('더 선명한 정면 사진'),
    );
  });

  test('uses non-mutating preview multipart field name', () {
    expect(DogService.profileNosePreviewImageField, 'profile_image');
    expect(DogService.profileNosePreviewPath, '/dogs/profile-nose-preview');
  });
}
