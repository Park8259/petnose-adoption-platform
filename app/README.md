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

- 현재 `app/`은 구현 전 스캐폴드 단계입니다(실코드 없음).
- 기능 개발 시작 전 API 계약 문서(`docs/PETNOSE_MVP_API_CONTRACT.md`)를 기준으로 화면/요청 스펙을 확정합니다.
- dev 전용 API(`/api/dev/*`)는 앱 기능 계약에 포함하지 않습니다.

---

> 추후 빌드 방법, 환경 분기, 상태관리 패턴 등 상세 내용을 이 문서에 추가할 예정입니다.
