import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../screens/chat_store.dart';

class FirebaseChatService {
  static Future<void> setupFirebaseChat(String token) async {
    if (token.isEmpty) return;

    final result = await ChatStore.getFirebaseCustomToken(token: token);

    final customToken = result['firebase_custom_token'];

    if (customToken == null || customToken.toString().isEmpty) {
      throw Exception('Firebase custom token이 없습니다.');
    }

    await FirebaseAuth.instance.signInWithCustomToken(
      customToken.toString(),
    );

    final fcmToken = await FirebaseMessaging.instance.getToken();

    if (fcmToken != null && fcmToken.isNotEmpty) {
      await ChatStore.registerFcmToken(
        token: token,
        fcmToken: fcmToken,
        platform: 'ANDROID',
      );
    }
  }
}