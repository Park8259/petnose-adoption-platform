# 시스템 아키텍처

> 문서 성격: 보조 참고 문서(Task Reference)
>
> runtime architecture, service responsibility, Spring Boot/Python Embed/Qdrant/MySQL/Nginx 경계를 볼 때 읽는다.
> active canonical 문서와 충돌하면 active canonical 문서가 우선한다.

## 문서 목적

이 문서는 PetNose 플랫폼의 런타임 구조, 서비스 간 책임 분리, 주요 요청 흐름을 기술합니다.  
구현 세부사항보다는 전체 설계 방향을 공유하는 것이 목적입니다.

---

## 런타임 구조

```
[Flutter App]
      │  HTTP
      ▼
  [Nginx :80]          ← 단일 진입점, 리버스 프록시
      │
      ▼
[Spring Boot :8080]    ← 메인 오케스트레이터
   │         │
   │         └──── HTTP ──── [Python Embed :8000]
   │                               │
   │                         비문 임베딩 변환
   │                               │
   │                         ┌─────▼──────┐
   │                         │   Qdrant   │  벡터 유사도 검색
   │                         │  :6333     │
   │                         └────────────┘
   │
   └──── JDBC ──── [MySQL :3306]   ← 관계형 데이터 저장소
```

외부에 노출되는 포트는 Nginx의 80(또는 443)뿐입니다.  
Spring Boot, Python, MySQL, Qdrant는 Docker 내부 네트워크에서만 통신합니다.

---

## 서비스별 책임

### Spring Boot (`spring-api`)

- **메인 오케스트레이터.** 모든 비즈니스 로직을 여기서 처리합니다.
- 사용자 인증/인가 (JWT)
- 분양 전 비문 검증, 호환 강아지 등록, 입양 게시글 관리, 인도 시점 비문 확인
- MySQL 읽기/쓰기
- Python 임베딩 서비스 호출 및 Qdrant 벡터 저장/검색 호출
- 이미지 업로드 처리 (`uploads/` 볼륨)

### Python Embed (`python-embed`)

- **임베딩 전용 서비스.** 비즈니스 로직은 없습니다.
- 입력: 비문 이미지 (multipart 또는 바이트)
- 출력: 고정 차원 임베딩 벡터 (JSON)
- Spring Boot로부터만 호출됩니다. Flutter에서 직접 접근하지 않습니다.

### Qdrant

- **벡터 검색 전용.** Spring Boot가 직접 HTTP API로 호출합니다.
- 비문 임베딩 저장 및 top-K 유사도 검색
- 데이터 원본(Source of Truth)은 MySQL이며, Qdrant는 검색 인덱스 역할입니다.
- 자세한 내용은 [STORAGE_AND_VECTOR_BOUNDARY.md](STORAGE_AND_VECTOR_BOUNDARY.md)를 참고하세요.

### MySQL

- **관계형 데이터의 Source of Truth.**
- `users`, `dogs`, `dog_images`, `dog_nose_references`, `verification_logs`, `adoption_posts`, `adoption_post_likes` domain/relationship data와 `password_reset_tokens` auth support data를 보관합니다.

### Nginx

- 클라이언트 요청을 `spring-api`로 프록시합니다.
- `client_max_body_size` 설정으로 이미지 업로드 크기를 제한합니다.
- **정적 파일 직접 서빙**: `GET /files/{path}` → `uploads_data` 볼륨에서 직접 읽어 반환합니다.  
  Spring Boot를 경유하지 않으므로 파일 조회 성능이 향상됩니다.
- 향후 HTTPS 설정 시 이 레이어에서 SSL을 종료합니다.
- 파일 저장 경로·URL 규칙 전체: [FILE_STORAGE_AND_URL_POLICY.md](FILE_STORAGE_AND_URL_POLICY.md)

---

## 주요 흐름

### Dog 등록/비문 중복 검사와 분양글 생성

```
Flutter → POST /api/dogs/register (dog 정보 + nose_images 5장)
  → Spring Boot: NOSE 이미지 5장 저장 (uploads 볼륨, 상대경로 DB 기록)
  → Spring Boot → Python Embed: POST /embed-batch (이미지 바이트 5장)
  ← Python Embed: { "items": [...], "count": 5, "dimension": 2048 }
  → Spring Boot → Qdrant: duplicate search
  → Spring Boot → MySQL: INSERT/UPDATE dogs, dog_images(NOSE), verification_logs(DOG_REGISTRATION)
  → Spring Boot → Qdrant: PASSED일 때 REFERENCE 5개 + CENTROID 1개를 UUID point id로 upsert
  → Spring Boot → MySQL: INSERT dog_nose_references
  ← Spring Boot → Flutter: { "dog_id": "...", "registration_allowed": true, "qdrant_point_id": null, ... }
Flutter → POST /api/adoption-posts (dog_id, title, content, status, profile_image)
  → Spring Boot: profile_image 저장 (uploads 볼륨, 상대경로 DB 기록)
  → Spring Boot → MySQL: validate registered dog + latest PASSED verification; INSERT INTO dog_images(PROFILE), adoption_posts
  ← Spring Boot → Flutter: { "post_id": 501, "dog_id": "...", ... }
```

저장 경로 규칙 및 URL 형식: [FILE_STORAGE_AND_URL_POLICY.md](FILE_STORAGE_AND_URL_POLICY.md)

### 인도 시점 비문 확인

```
Flutter → POST /api/adoption-posts/{post_id}/handover-verifications (이미지 포함)
  → Spring Boot → Python Embed: POST /embed 단건 임베딩 변환
  → Spring Boot: post_id로 adoption_posts.dog_id 조회
  → Spring Boot → Qdrant: dog_nose_references/Qdrant expected REFERENCE/CENTROID set 검색
  → Spring Boot: expected dog와 비교
  ← Spring Boot → Flutter: { "matched": true, "decision": "MATCHED", ... }
```

현재 구현은 handover image를 저장하지 않고, `verification_logs` row를 생성하지 않으며, `adoption_posts.status` 또는 `dogs.status`를 변경하지 않습니다. Qdrant point id는 UUID이며 `post_id` 또는 `dog_id`가 아닙니다.

---

## 운영 원칙

- Spring Boot가 Python과 Qdrant를 호출하는 유일한 주체입니다. Flutter는 Spring Boot만 바라봅니다.
- MySQL과 Qdrant 동기화 실패 처리 방식은 [STORAGE_AND_VECTOR_BOUNDARY.md](STORAGE_AND_VECTOR_BOUNDARY.md)를 따릅니다.
- 모든 서비스는 Docker Compose 내부 네트워크로 격리됩니다.
- 환경별 설정은 `compose.dev.yaml` / `compose.prod.yaml`로 오버라이드합니다.
