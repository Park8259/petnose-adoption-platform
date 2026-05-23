# app — Flutter 앱

> 이 문서는 초안입니다. 개발이 진행되면 상세화할 예정입니다.

---

## 역할

사용자가 직접 사용하는 모바일 앱입니다.  
Spring Boot API 서버와 HTTP 통신하며, 강아지 등록, 비문 인증, 입양 게시판 조회 기능을 제공합니다.

API 계약은 [docs/PETNOSE_MVP_API_CONTRACT.md](../docs/PETNOSE_MVP_API_CONTRACT.md)를 참고하세요.

---

## 개발 환경

- Flutter 3.x 이상
- Dart 3.x 이상

```bash
# 의존성 설치
flutter pub get

# 앱 실행 (에뮬레이터 또는 실기기 연결 필요)
flutter run
```

---

## 주의사항

- API base URL은 환경별로 분리하여 관리합니다. 하드코딩하지 않습니다.
- 로컬 개발 시 백엔드는 `http://localhost` (Nginx 포트)로 접속합니다.
- `POST /api/dogs/register`의 `nose_image`와 `POST /api/adoption-posts`의 required `profile_image` 업로드는 `multipart/form-data`를 사용합니다.

---

## 팀 최소 운영 규칙

- 현재 `app/`은 production 앱 구현 전 단계이며 Firebase chat 수동 visual smoke harness만 포함합니다.
- 기능 개발 시작 전 API 계약 문서(`docs/PETNOSE_MVP_API_CONTRACT.md`)를 기준으로 화면/요청 스펙을 확정합니다.
- dev 전용 API(`/api/dev/*`)는 앱 기능 계약에 포함하지 않습니다.

---

## Firebase Chat Visual Smoke

Firebase 채팅 backend/API가 준비된 뒤, 에뮬레이터 또는 실기기에서 Flutter 클라이언트의 Firebase custom token 로그인과 Firestore realtime listener를 눈으로 확인하기 위한 수동 검증 화면입니다. Production 채팅 UI가 아니며, 메시지 write는 반드시 Spring Boot API를 통해서만 수행합니다.

### Prerequisites

- Backend가 Firebase enabled 모드로 실행 중이어야 합니다.
- Firestore database가 생성되어 있어야 합니다.
- `docs/firebase/firestore.rules`가 Firebase 프로젝트에 배포되어 있어야 합니다.
- Flutter Firebase client config가 로컬에 준비되어 있어야 합니다.
  - 권장: `flutterfire configure`
  - Android: `app/android/app/google-services.json`
  - iOS: `app/ios/Runner/GoogleService-Info.plist`
- 위 Firebase client config 파일은 이 PR에서 실제 값으로 생성하지 않습니다.
- Firebase service account JSON, Spring JWT, Firebase custom token, FCM token, `.env`는 커밋하지 않습니다.
- 현재 저장소의 `app/`에는 최소 Flutter source만 있습니다. Flutter CLI가 있는 환경에서 platform folder가 없다면 `app/`에서 `flutter create --platforms=android,ios .`를 먼저 실행한 뒤 Firebase client config를 로컬로 추가하세요.

### Backend Fixture

Firebase chat smoke fixture는 backend helper scripts를 사용합니다.

```powershell
.\scripts\prepare-firebase-chat-smoke-fixture.ps1
.\scripts\verify-firebase-chat-smoke.ps1
```

`prepare-firebase-chat-smoke-fixture.ps1`는 author/inquirer 사용자와 post fixture를 만들고, 로컬 임시 env 파일에 검증용 값을 출력합니다. 토큰 값은 문서나 evidence에 붙여넣지 마세요.

### Run

```bash
cd app
flutter pub get
flutter run
```

API base URL은 실행 대상에 맞게 입력합니다.

- Android emulator: `http://10.0.2.2:8080`
- iOS simulator: `http://localhost:8080`
- Real device: PC LAN IP 또는 서버 URL, 예: `http://192.168.x.x:8080`
- 실기기에서 PC backend에 접속하려면 방화벽에서 8080 포트를 허용하거나 nginx 80 포트 등 접근 가능한 URL을 사용하세요.

### Manual Visual Test Steps

1. Backend를 Firebase enabled 모드로 실행합니다.
2. `scripts/prepare-firebase-chat-smoke-fixture.ps1`로 author/inquirer fixture를 준비합니다.
3. 앱을 실행하고 API base URL, inquirer Spring Bearer token, `post_id`를 입력합니다.
4. `Get Firebase Custom Token`을 눌러 Firebase Auth sign-in이 되고 `firebase_uid`가 표시되는지 확인합니다.
5. `Create / Get Chat Room`을 눌러 Spring API로 room을 만들고 Firestore listener가 시작되는지 확인합니다.
6. `Send Message`를 눌러 Spring API로 메시지를 보냅니다.
7. 메시지가 Firestore listener를 통해 `Realtime Messages` 영역에 나타나는지 확인합니다.
8. 가능하면 다른 device/session에서 author token으로 로그인해 같은 room을 listen하고 realtime update를 확인합니다.
9. `Mark Read`를 눌러 Spring API read marking 결과를 확인합니다.
10. `Refresh Room List`를 눌러 room id, post status, message preview, unread count를 확인합니다.
11. FCM platform 설정이 끝난 device에서는 `Register FCM Token`을 눌러 Spring API 등록 결과를 확인합니다. 화면은 token 전체 값을 표시하지 않습니다.

### Known Limitations

- 이 화면은 Firebase chat 수동 시각 검증용 harness이며 production UI가 아닙니다.
- Flutter는 Firestore realtime read만 수행하고, chat room 생성/메시지 전송/read marking/FCM token 등록은 Spring Boot API를 호출합니다.
- Real device push delivery는 device token, platform-specific Firebase 설정, OS notification permission을 포함한 별도 실기기 검증이 필요합니다.
- Flutter listener 검증은 backend smoke와 별개로 수행해야 합니다.

---

> 추후 빌드 방법, 환경 분기, 상태관리 패턴 등 상세 내용을 이 문서에 추가할 예정입니다.
