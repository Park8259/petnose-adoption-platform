# app - Flutter 앱

> 이 문서는 production Flutter 앱 구현 전 단계의 최소 안내입니다.

---

## 역할

`app/`은 사용자가 직접 사용하는 PetNose production Flutter 앱 구현을 위한 공간입니다.
Spring Boot API 서버와 HTTP 통신하며, 강아지 등록, 비문 인증, 입양 게시판 조회 등 실제 사용자 기능이 이곳에서 구현됩니다.

API 계약은 [docs/PETNOSE_MVP_API_CONTRACT.md](../docs/PETNOSE_MVP_API_CONTRACT.md)를 참고하세요.

---

## 개발 환경

- Flutter 3.x 이상
- Dart 3.x 이상

```bash
flutter pub get
flutter run
```

---

## 주의사항

- API base URL은 환경별로 분리하여 관리합니다. 하드코딩하지 않습니다.
- 로컬 개발 시 백엔드는 `http://localhost` 또는 로컬 nginx/API 포트로 접속합니다.
- `POST /api/dogs/register`는 `nose_images` multipart field로 비문 기준 사진을 정확히 5장 업로드합니다. Registration 단건 `nose_image`는 active contract가 아닙니다.
- Handover verification은 registration과 다르게 `POST /api/adoption-posts/{post_id}/handover-verifications`에 단건 `nose_image`를 업로드합니다.
- `POST /api/adoption-posts`의 required `profile_image` 업로드는 `multipart/form-data`를 사용합니다.
- 현재 `app/`은 production Flutter 구현 전 단계이므로, registration UI 구현 시 backend v2 contract에 맞춰 5장 업로드 flow로 구현해야 합니다.
- dev 전용 API(`/api/dev/*`)는 production 앱 기능 계약에 포함하지 않습니다.

---

## Firebase Chat Visual Smoke

Firebase chat 수동 시각 검증용 Flutter harness는 production 앱 구현과 분리되어 있습니다.

```text
tools/flutter-chat-visual-smoke/
```

이 harness는 testing/tooling 용도이며 production UI가 아닙니다. Firebase custom token 로그인, Spring API 기반 채팅방 생성/메시지 전송/read marking, Firestore realtime listener 확인은 위 tool README를 따르세요.

---

## 팀 최소 운영 규칙

- `app/`에는 production 앱 구현만 둡니다.
- 수동 검증 도구, fixture, smoke harness는 `tools/` 또는 `scripts/` 아래에 둡니다.
- Firebase service account JSON, Spring JWT, Firebase custom token, FCM token, `.env`는 커밋하지 않습니다.

---

> 추후 빌드 방법, 환경 분기, 상태관리 패턴 등 상세 내용을 이 문서에 추가할 예정입니다.
