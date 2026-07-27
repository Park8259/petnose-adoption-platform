import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nosetag_app/services/api_config.dart';
import 'package:nosetag_app/services/post_service.dart';

void main() {
  test(
    'create post request uses dev user id and no auth header by default',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'post_service_request_',
      );
      try {
        final image = File('${dir.path}${Platform.pathSeparator}profile.png')
          ..writeAsBytesSync([
            0x89,
            0x50,
            0x4E,
            0x47,
            0x0D,
            0x0A,
            0x1A,
            0x0A,
            0x00,
          ]);

        final request = await PostService().buildCreatePostRequest(
          accessToken: 'stale-token-is-ignored-when-auth-header-disabled',
          dogId: 'dog-1',
          title: '테스트 분양글',
          content: '비문 인증 후 작성합니다.',
          profileImage: image,
        );

        expect(ApiConfig.enableAuthHeader, isFalse);
        expect(request.headers.containsKey('Authorization'), isFalse);
        expect(request.fields['user_id'], ApiConfig.devUserId.toString());
        expect(request.fields['dog_id'], 'dog-1');
        expect(request.fields['status'], 'OPEN');

        final profile = request.files.single;
        expect(profile.field, 'profile_image');
        expect(profile.filename, 'profile.png');
        expect(profile.contentType.toString(), 'image/png');
      } finally {
        await _deleteTempDir(dir);
      }
    },
  );
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
