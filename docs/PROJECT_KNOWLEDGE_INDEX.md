# PetNose 프로젝트 지식 인덱스

## 문서 성격

이 문서는 모든 작업 전 필독해야 하는 always-read router 문서다.

이 문서는 다음을 빠르게 판단하기 위해 존재한다.

- active canonical 요약
- 현재 구현 상태 요약
- task-specific 문서 라우팅
- removed scope 정리
- archive/reference 문서를 active 구현 기준으로 오해하지 않기 위한 경계

항상 `docs/README.md`를 먼저 읽고, 이어서 이 문서를 읽는다. 이후 작업 종류에 맞는 canonical/reference 문서를 읽는다.

## Always-Read Policy

모든 작업은 아래 두 문서에서 시작한다.

1. `docs/README.md`
2. `docs/PROJECT_KNOWLEDGE_INDEX.md`

`docs/archive/**`는 과거 문서 확인용이다. active 구현 기준으로 사용하지 않는다.

## Active Canonical Documents

현재 PetNose MVP 기준 문서는 아래 경로를 유지한다.

- `docs/PETNOSE_MVP_FINAL_PROJECT_SPEC.md`
- `docs/PETNOSE_MVP_API_CONTRACT.md`
- `docs/db/petnose_mvp_schema.dbml`
- `docs/db/V20260508__mvp_canonical_schema.sql`
- `docs/PROJECT_KNOWLEDGE_INDEX.md`

## Pre-Share Schema Count Note

schema count 불일치는 해결되었다. pre-adoption nose verification ticket은 `verification_logs`로 통합되었고 dog nose v2 reference metadata는 `dog_nose_references`가 추적한다. current MVP app table은 6개다. 상세 refactor 기록은 `docs/reference/MVP_SCHEMA_TABLE_COUNT_REVIEW.md`를 확인한다.

## Task-Specific Routing

| 작업 종류 | 먼저 읽을 문서 |
|---|---|
| API/controller/service/test 작업 | `docs/PETNOSE_MVP_API_CONTRACT.md` |
| product/domain scope 판단 | `docs/PETNOSE_MVP_FINAL_PROJECT_SPEC.md` |
| DB/entity/schema 판단 | `docs/db/petnose_mvp_schema.dbml`, `docs/db/V20260508__mvp_canonical_schema.sql` |
| Firebase chat/push 판단 | `docs/firebase/chat-firestore-schema.md`, `docs/reference/FIREBASE_CHAT_OPERATIONS.md`, `docs/reference/FIREBASE_CHAT_STABILIZATION_PLAN.md` |
| Flyway/runtime migration 작업 | `docs/reference/DB_MIGRATION_STRATEGY.md` |
| Qdrant/Python Embed/file storage 경계 판단 | `docs/reference/STORAGE_AND_VECTOR_BOUNDARY.md`, `docs/reference/SPRING_PYTHON_EMBED_CONTRACT.md` |
| ops/deploy evidence 확인 | `docs/ops-evidence/dev-cd-validation-log.md` |

추가 운영/온보딩/환경 참고 문서는 `docs/reference/` 아래에 있다. reference 문서와 active canonical 문서가 충돌하면 active canonical 문서가 우선한다.

## Current Canonical Summary

현재 PetNose MVP canonical baseline은 simplified DBML v2다.

- 활성 role은 `USER` / `ADMIN`만 사용한다.
- `SHELTER` / `ADOPTER`는 active role이 아니다.
- `publisher_profiles`, `shelter_profiles`, `seller_profiles`, `auth_logs`, `reports`, `refresh_tokens`는 active MVP에 없다.
- 활성 domain table은 아래 6개다.
  - `users`
  - `dogs`
  - `dog_images`
  - `dog_nose_references`
  - `verification_logs`
  - `adoption_posts`
- `users`가 `display_name`, `contact_phone`, `region`, `is_active`를 직접 가진다.
- MySQL이 source of truth다.
- Qdrant는 dog nose vector index일 뿐이다.
- Firebase chat/push는 optional communication layer로 구현될 수 있으며 MySQL 대체물이 아니다.
- Firebase chat/push는 canonical 6-table MySQL schema를 변경하지 않는다.
- `dog_images.file_path`는 upload root 기준 상대 경로만 저장한다.
- API 응답 필드 `qdrant_point_id`, `verification_status`, `embedding_status`는 계산 필드이며 DB column이 아니다.
- Dog nose v2 real Qdrant collection은 `dog_nose_embeddings_real_v2`이며 vector dimension은 `2048`, distance는 `Cosine`이다.
- Qdrant point id는 UUID이고 `dogs.id`와 같지 않다. dog id와 point metadata는 Qdrant payload 및 MySQL `dog_nose_references`로 추적한다.
- 정상 등록은 `REFERENCE` 3~5개와 `CENTROID` 1개를 Qdrant에 저장한다.
- `qdrant_point_id` response field는 dog nose v2에서 `null`이다.
- 모든 JSON response field는 `snake_case`를 유지한다.
- 공통 error response shape는 아래 형태를 유지한다.

```json
{
  "error_code": "...",
  "message": "...",
  "details": ...
}
```

## Current Implemented API Flow

현재 dog nose v2 branch 기준 Flutter MVP/API 흐름은 아래 endpoint를 구현된 기준으로 다룬다.

- `POST /api/auth/register`
- `POST /api/auth/login`
- `GET /api/users/me`
- `PATCH /api/users/me/profile`
- `POST /api/dogs/register`
- `GET /api/dogs/me`
- `GET /api/dogs/{dog_id}`
- `POST /api/adoption-posts`
- `GET /api/adoption-posts`
- `GET /api/adoption-posts/{post_id}`
- `GET /api/adoption-posts/me`
- `PATCH /api/adoption-posts/{post_id}/status`
- `POST /api/adoption-posts/{post_id}/handover-verifications`

Optional Firebase chat/push communication endpoints are implemented behind Firebase runtime enablement:

- `POST /api/firebase/custom-token`
- `PUT /api/users/me/fcm-token`
- `POST /api/chat/rooms`
- `GET /api/chat/rooms`
- `POST /api/chat/rooms/{room_id}/messages`
- `PATCH /api/chat/rooms/{room_id}/read`

These endpoints do not change the canonical MySQL domain schema. Firebase disabled mode returns `FIREBASE_DISABLED` after Spring authentication succeeds. This index does not claim Flutter chat UI implementation is complete.

상세 request/response, error code, visibility rule은 `docs/PETNOSE_MVP_API_CONTRACT.md`가 기준이다.

Dog registration과 adoption post creation ownership은 JWT-principal-only다.

- request `user_id`는 active API contract input이 아니다.
- 신규 Flutter 분양글 작성 flow는 `POST /api/dogs/register`에서 dog 기본 정보와 `nose_images` 3~5장을 등록하고 duplicate/review/pass decision을 검사한다.
- dog registration embedding은 Python `/embed-batch` 1회 호출을 사용한다.
- client가 close-up cropped nose image를 제공한다고 가정하며 backend는 crop/detection/alignment를 수행하지 않는다.
- `POST /api/dogs/register` 성공 시 반환된 `dog_id`가 `POST /api/adoption-posts` request의 기준이다.
- `POST /api/adoption-posts`는 multipart request로 required `profile_image`를 받고 `dog_images.image_type=PROFILE` row를 저장한다.
- adoption post creation은 JWT principal과 `dog.owner_user_id`를 함께 검증한다.
- adoption post creation은 embed service 호출이나 Qdrant upsert를 수행하지 않는다.

Dog Query API는 current dog nose v2 branch에 구현되어 있다.

- dog list는 `nose_image_url`을 노출하지 않는다.
- owner dog detail은 owner 자신의 dog `nose_image_url`을 노출할 수 있다.
- public dog detail은 `nose_image_url`을 노출하지 않는다.
- public dog detail은 현재 `OPEN` 또는 `RESERVED` adoption post가 있는 dog로 제한된다.
- adoption post public detail은 구현상 `OPEN`, `RESERVED`, `COMPLETED` post를 지원할 수 있다. 이것은 Dog Query public detail eligibility와 별도다.

## Handover Trust/Safety Flow

인도 시점 비문 확인(Handover-Time Dog Nose Verification)은 current MVP trust/safety flow에 포함되어 있다.

- `POST /api/adoption-posts/{post_id}/handover-verifications`는 stateless API로 구현되어 있다.
- 새로 촬영한 `nose_image`를 `adoption_posts.dog_id`에 연결된 expected dog reference set과 비교한다.
- handover embedding은 Python `/embed` 단건 호출을 사용한다.
- Qdrant point id는 `post_id`나 `dog_id`가 아니라 UUID다.
- handover lookup path는 `post_id -> adoption_posts.dog_id -> dog_nose_references/Qdrant expected REFERENCE/CENTROID set`이다.
- default decision thresholds는 `MATCHED >= 0.75`, `AMBIGUOUS 0.60 이상 0.75 미만`, `NOT_MATCHED < 0.60`이다.
- Spring Boot가 Python Embed와 Qdrant 호출을 오케스트레이션한다.
- Flutter는 Python Embed, Qdrant, MySQL을 직접 호출하지 않는다.
- 이 흐름은 DB table을 추가하지 않는다.
- handover image를 저장하지 않는다.
- 현재 MVP에서는 `verification_logs` history를 만들지 않는다.
- `adoption_posts.status` 또는 `dogs.status`를 변경하지 않는다.
- 자동으로 adoption completion을 수행하지 않는다.
- response에 `nose_image_url`, 다른 강아지의 `dog_id`, Qdrant payload details, `author_user_id`를 노출하지 않는다.

## Removed Scope

아래 항목은 current MVP active scope가 아니다.

- Firebase replacement of MySQL domain data는 제외한다. Firebase chat/push는 optional communication layer로만 허용한다.
- reports/admin dashboard는 제외한다.
- reservation/payment/contract는 제외한다.
- `SHELTER`, `ADOPTER` 같은 non-canonical role은 제외한다.
- `publisher_profiles`, `shelter_profiles`, `seller_profiles` 같은 old separate profile table은 제외한다.
- 별도 `handover_verifications` table은 추가하지 않는다.

## 충돌 판단 규칙

- active canonical 문서가 reference 문서보다 우선한다.
- active canonical 문서가 archive 문서보다 우선한다.
- 코드 구현 상태와 문서가 충돌하면 구현을 임의로 바꾸지 말고 먼저 감사/검증 작업으로 확인한다.
- `docs/archive/**`는 historical context로만 읽고 active implementation criteria로 쓰지 않는다.
