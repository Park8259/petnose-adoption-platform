# App Team Production Handoff

> 문서 성격: 보조 참고 문서(Task Reference)
>
> 앱팀이 production API/Firebase chat 연결을 시작할 때 전달할 항목과 전달하면 안 되는 server-only secret을 구분한다.
> active canonical 문서와 충돌하면 active canonical 문서가 우선한다.

---

## Provide Only These Items

앱팀에는 아래 항목만 제공한다.

| 항목 | 값 또는 위치 |
|---|---|
| API base URL | `API_BASE_URL=https://<api-domain>/api` |
| Android Firebase config | `app/android/app/google-services.json`에 배치할 client config |
| Firebase Project ID | `petnose-c6ec5` |
| Android package | `com.example.petnose_app` |

`google-services.json`은 Android client configuration이다. Spring server의 Firebase Admin 인증에는 사용하지 않는다.

---

## Do Not Provide

앱팀에게 아래 항목은 전달하지 않는다.

- `firebase-service-account.json`
- server `.env`
- DB secret
- JWT secret
- SMTP secret
- GHCR token
- dog nose model file
- Firebase private key
- raw dog image fixtures
- raw Qdrant vectors or payloads

---

## Auth And Firebase Login Flow

1. 앱은 Spring login API로 Spring JWT를 받는다.
2. 앱은 Spring JWT로 Firebase custom token API를 호출한다.
3. 앱은 응답의 `firebase_custom_token`을 Firebase Auth에 전달한다.

```http
POST /api/firebase/custom-token
Authorization: Bearer <spring-jwt>
```

Response shape:

```json
{
  "firebase_uid": "user_1",
  "firebase_custom_token": "<firebase-custom-token>"
}
```

Flutter flow:

```text
Spring login -> /api/firebase/custom-token -> FirebaseAuth.signInWithCustomToken
```

`firebase_custom_token`은 secret이다. 앱 로그, screenshot, crash report, PR 본문에 남기지 않는다.

---

## FCM Token Registration

앱은 Firebase Messaging token을 발급받은 뒤 Spring API로 저장한다.

```text
FirebaseMessaging.getToken -> PUT /api/users/me/fcm-token
```

```http
PUT /api/users/me/fcm-token
Authorization: Bearer <spring-jwt>
Content-Type: application/json
```

```json
{
  "fcm_token": "<fcm-token>",
  "platform": "ANDROID"
}
```

Allowed `platform` values:

- `ANDROID`
- `IOS`
- `WEB`

Response shape:

```json
{
  "registered": true
}
```

앱은 `user_devices` Firestore collection에 직접 쓰지 않는다.

---

## Firestore Listener

채팅 realtime listener는 아래 path를 사용한다.

```text
chat_rooms/{room_id}/messages
```

Room document path:

```text
chat_rooms/{room_id}
```

Spring API의 room 생성 응답에 `firebase_room_path`가 포함된다.

```http
POST /api/chat/rooms
Authorization: Bearer <spring-jwt>
Content-Type: application/json
```

```json
{
  "post_id": 123
}
```

Response shape:

```json
{
  "room_id": "post_123_user_45",
  "post_id": 123,
  "firebase_room_path": "chat_rooms/post_123_user_45",
  "author_user_id": 10,
  "inquirer_user_id": 45,
  "status": "ACTIVE"
}
```

The app may read room/message documents where the signed-in Firebase user is a participant. The app must not create, update, or delete Firestore chat room/message documents directly.

---

## Chat API Writes

Message write goes through Spring Boot.

```http
POST /api/chat/rooms/{room_id}/messages
Authorization: Bearer <spring-jwt>
Content-Type: application/json
```

```json
{
  "text": "hello",
  "client_message_id": "client-generated-id"
}
```

Mark read also goes through Spring Boot.

```http
PATCH /api/chat/rooms/{room_id}/read
Authorization: Bearer <spring-jwt>
```

Spring Boot remains authoritative for:

- room creation
- message sending
- FCM token registration
- read marking
- post-status-based chat permission decisions

Firestore is a realtime UI snapshot layer only. MySQL remains source of truth.

---

## Firebase Disabled Response

If a runtime does not include Firebase, authenticated Firebase/chat APIs return `FIREBASE_DISABLED`.
Production handoff assumes Firebase is enabled, so this response is a deployment/configuration issue in production.

```json
{
  "error_code": "FIREBASE_DISABLED",
  "message": "Firebase 연동이 비활성화되어 있습니다.",
  "details": {
    "timestamp": "2026-05-13T00:00:00Z"
  }
}
```

---

## App Team Smoke Checklist

- [ ] `google-services.json` is installed under the Android app path.
- [ ] Spring login returns JWT.
- [ ] `POST /api/firebase/custom-token` returns `firebase_custom_token`.
- [ ] `FirebaseAuth.signInWithCustomToken` succeeds.
- [ ] `FirebaseMessaging.getToken` returns a token.
- [ ] `PUT /api/users/me/fcm-token` returns `registered=true`.
- [ ] `POST /api/chat/rooms` returns `firebase_room_path`.
- [ ] Firestore listener starts on `chat_rooms/{room_id}/messages`.
- [ ] Message send uses Spring API, not direct Firestore write.
- [ ] Client direct write to Firestore is not attempted.
