import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nosetag_app/services/dog_service.dart';

void main() {
  test(
    'register keeps nose images separate from optional face check image',
    () {
      expect(DogService.profileImageField, 'profile_image');
      expect(DogService.profileNosePreviewImageField, 'profile_image');
      expect(DogService.faceCheckImageField, 'face_check_image');
      expect(DogService.noseImagesField, 'nose_image');
      expect(DogService.faceCheckImageField, isNot(DogService.noseImagesField));
      expect(
        DogService.faceCheckImageField,
        isNot(DogService.profileNosePreviewImageField),
      );
    },
  );

  test(
    'register multipart contains profile, face check, and five nose files',
    () async {
      final dir = await Directory.systemTemp.createTemp('dog_service_request_');
      http.MultipartRequest? request;
      try {
        File image(String name) =>
            File('${dir.path}${Platform.pathSeparator}$name')
              ..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]);

        final profileImage = image('profile.jpg');
        final faceCheckImage = image('face_check.jpg');
        final noseImages = List.generate(
          5,
          (index) => image('nose_$index.jpg'),
        );

        request = await DogService().buildRegisterDogRequest(
          accessToken: 'ignored-when-auth-header-disabled',
          name: '테스트 강아지',
          breed: '말티즈',
          gender: 'FEMALE',
          age: '3',
          price: '250000',
          dogRegion: '서울',
          health: 'healthy',
          description: 'friendly',
          profileImage: profileImage,
          faceCheckImage: faceCheckImage,
          noseImages: noseImages,
        );

        final fileFields = request.files.map((file) => file.field).toList();

        expect(request.fields['user_id'], '1');
        expect(request.headers.containsKey('Authorization'), isFalse);
        expect(
          fileFields.where((field) => field == DogService.profileImageField),
          hasLength(1),
        );
        expect(
          fileFields.where((field) => field == DogService.faceCheckImageField),
          hasLength(1),
        );
        expect(
          fileFields.where((field) => field == DogService.noseImagesField),
          hasLength(5),
        );
      } finally {
        await request?.finalize().drain<void>();
        await _deleteTempDir(dir);
      }
    },
  );

  test(
    'register multipart keeps filename extension and content type aligned',
    () async {
      final dir = await Directory.systemTemp.createTemp('dog_service_mime_');
      http.MultipartRequest? request;
      try {
        File image(String name, List<int> bytes) =>
            File('${dir.path}${Platform.pathSeparator}$name')
              ..writeAsBytesSync(bytes);

        final jpegBytes = [0xFF, 0xD8, 0xFF, 0xD9];
        final pngBytes = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00];

        final profileImage = image('scaled_35.png', pngBytes);
        final faceCheckImage = image('face_check_wrong_ext.jpg', pngBytes);
        final noseImages = [
          image('nose_1.jpg', jpegBytes),
          image('nose_2.jpeg', jpegBytes),
          image('nose_3.png', pngBytes),
          image('nose_4_wrong_ext.jpg', pngBytes),
          image('nose_5.jpg', jpegBytes),
        ];

        request = await DogService().buildRegisterDogRequest(
          accessToken: 'ignored-when-auth-header-disabled',
          name: '테스트 강아지',
          breed: '말티즈',
          gender: 'FEMALE',
          age: '3',
          price: '250000',
          dogRegion: '서울',
          health: 'healthy',
          description: 'friendly',
          profileImage: profileImage,
          faceCheckImage: faceCheckImage,
          noseImages: noseImages,
        );

        final profile = request.files.singleWhere(
          (file) => file.field == DogService.profileImageField,
        );
        final face = request.files.singleWhere(
          (file) => file.field == DogService.faceCheckImageField,
        );
        final noses = request.files
            .where((file) => file.field == DogService.noseImagesField)
            .toList();

        expect(profile.filename, 'scaled_35.png');
        expect(profile.contentType.toString(), 'image/png');
        expect(face.filename, 'face_check_wrong_ext.png');
        expect(face.contentType.toString(), 'image/png');
        expect(noses, hasLength(5));
        expect(noses[0].filename, 'nose_1.jpg');
        expect(noses[0].contentType.toString(), 'image/jpeg');
        expect(noses[1].filename, 'nose_2.jpg');
        expect(noses[1].contentType.toString(), 'image/jpeg');
        expect(noses[2].filename, 'nose_3.png');
        expect(noses[2].contentType.toString(), 'image/png');
        expect(noses[3].filename, 'nose_4_wrong_ext.png');
        expect(noses[3].contentType.toString(), 'image/png');
      } finally {
        await request?.finalize().drain<void>();
        await _deleteTempDir(dir);
      }
    },
  );

  test('register face image required error maps to friendly message', () {
    final message = DogService.registrationFailureMessage({
      'error_code': 'FACE_CHECK_IMAGE_REQUIRED',
      'message': 'server message',
      'details': {'failure_reason': 'FACE_CHECK_IMAGE_ABSENT'},
    });

    expect(message, '얼굴·코 확인용 정면 사진이 필요합니다.');
  });

  test('register mismatch error message includes profile centroid percent', () {
    final message = DogService.registrationFailureMessage({
      'error_code': 'PROFILE_CENTROID_MISMATCH',
      'message': '얼굴·코 확인 사진과 비문 5장이 같은 강아지로 확인되지 않았습니다.',
      'details': {'similarity_score': 0.5234, 'threshold': 0.65},
    });

    expect(message, contains('일치도 52.3%'));
    expect(message, contains('기준 65.0%'));
  });

  test('register face embed failure message includes failure reason', () {
    final message = DogService.registrationFailureMessage({
      'error_code': 'PROFILE_FACE_EMBED_FAILED',
      'message': '얼굴·코 확인용 정면 사진에서 코 영역 임베딩을 만들지 못했습니다.',
      'details': {'failure_reason': 'DETECTOR_UNAVAILABLE'},
    });

    expect(message, contains('DETECTOR_UNAVAILABLE'));
  });
}

Future<void> _deleteTempDir(Directory dir) async {
  for (var attempt = 0; attempt < 10; attempt += 1) {
    try {
      await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 9) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}
