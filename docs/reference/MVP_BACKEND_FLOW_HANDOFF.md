# MVP 백엔드 흐름 Flutter 인수인계

## 1. 문서 성격

이 문서는 PetNose MVP 백엔드 흐름을 Flutter 팀원과 졸업작품 검토자가 빠르게 이어받을 수 있도록 정리한 인수인계 문서다. 상세 request/response와 error code는 `docs/PETNOSE_MVP_API_CONTRACT.md`가 기준이다.

## 2. 현재 MVP 백엔드 상태 요약

### 구현된 endpoint

- `POST /api/auth/register`
- `POST /api/auth/login`
- `POST /api/auth/password-reset/request`
- `POST /api/auth/password-reset/confirm`
- `GET /api/users/me`
- `PATCH /api/users/me/profile`
- `PATCH /api/users/me/profile-image`
- `PATCH /api/users/me/password`
- `POST /api/dogs/register`
- `GET /api/dogs/me`
- `GET /api/dogs/adopted/me`
- `GET /api/dogs/{dog_id}`
- `POST /api/adoption-posts`
- `GET /api/adoption-posts`
- `GET /api/adoption-posts/{post_id}`
- `GET /api/adoption-posts/me`
- `PUT /api/adoption-posts/{post_id}/like`
- `DELETE /api/adoption-posts/{post_id}/like`
- `GET /api/adoption-posts/liked/me`
- `PATCH /api/adoption-posts/{post_id}/status`
- `POST /api/adoption-posts/{post_id}/handover-verifications`

### 앱 연동 경계

- Flutter는 Spring Boot HTTP API만 호출한다.
- active role은 `USER`, `ADMIN`뿐이다.
- Firebase chat/push는 optional communication layer이며 MySQL source of truth를 대체하지 않는다.
- `POST /api/dogs/register`가 dog identity 등록, 비문 중복 검사, Qdrant upsert의 유일한 active entrypoint다.
- dog nose v2에서는 dog 1개당 Qdrant `REFERENCE` point 5개와 `CENTROID` point 1개를 사용한다.
- API flow의 안정 식별자는 `dog_id`이며, Qdrant point id는 내부 UUID다.
- `post_id`는 게시글 id일 뿐 Qdrant id가 아니다.
- `POST /api/adoption-posts`는 이미 등록된 `dog_id`로 post와 PROFILE 대표 이미지만 생성하며 embed service나 Qdrant를 호출하지 않는다.
- JSON response field는 `snake_case`를 유지한다.

## 3. 전체 사용자 흐름

1. 회원가입: Flutter는 `POST /api/auth/register`로 public signup을 수행한다.
2. 로그인: `POST /api/auth/login`으로 Bearer token을 받는다.
3. 내 정보 조회/수정: `GET /api/users/me`, 필요 시 `PATCH /api/users/me/profile`.
4. 강아지 등록/비문 중복 검사: `POST /api/dogs/register`에 dog 기본 정보와 `nose_images` 정확히 5장을 보낸다.
5. `registration_allowed=false`: 중복 의심 화면으로 분기하고 분양글 생성을 막는다. Qdrant upsert는 이미 생략된 상태다.
6. `registration_allowed=true`: 반환된 `dog_id`를 작성 form state에 저장한다. Qdrant point id는 v2 내부 UUID이며 app flow에서 사용하지 않는다.
7. 분양글 생성: `POST /api/adoption-posts` multipart form에 `dog_id`, `title`, `content`, optional `status`, required `profile_image`를 보낸다.
8. 공개 분양글 목록/상세: public 사용자는 비문 이미지 없이 공개 정보를 본다.
9. 내 분양글 관리: 작성자는 owner endpoint로 post를 관리한다.
10. 인도 시점 비문 확인: `POST /api/adoption-posts/{post_id}/handover-verifications`로 새 촬영 비문과 post의 expected dog를 비교한다.
11. 완료 처리: handover verification은 safety signal이다. 실제 완료는 owner-only status update flow로 처리한다.

## 4. Endpoint Flow Table

| Endpoint | Auth | Content type | 주요 request field | 주요 response field | 주요 error code | Flutter 목적 |
|---|---|---|---|---|---|---|
| `POST /api/auth/register` | 불필요 | `application/json` | `email`, `password`, `display_name`, `contact_phone`, `region` | `user_id`, `email`, `role`, profile fields | `VALIDATION_FAILED`, `EMAIL_ALREADY_EXISTS` | 회원가입 |
| `POST /api/auth/login` | 불필요 | `application/json` | `email`, `password` | `access_token`, `token_type`, `expires_in`, `user` | `VALIDATION_FAILED`, `INVALID_CREDENTIALS`, `USER_INACTIVE` | 로그인 |
| `GET /api/users/me` | 필요 | 없음 | Bearer token | current user/profile fields | `UNAUTHORIZED`, `USER_NOT_FOUND`, `USER_INACTIVE` | profile readiness |
| `PATCH /api/users/me/profile` | 필요 | `application/json` | optional-present profile fields | updated profile fields | `VALIDATION_FAILED` 등 | 작성자 정보 보완 |
| `POST /api/dogs/register` | 필요 | `multipart/form-data` | `name`, `breed`, `gender`, optional `birth_date`, `description`, required `nose_images` exactly 5 | `dog_id`, `registration_allowed`, `status`, `verification_status`, `embedding_status`, `qdrant_point_id`, `reference_count`, `score_breakdown`, `top_match`, `message` | `NOSE_IMAGES_REQUIRED`, `NOSE_IMAGES_COUNT_INVALID`, `NOSE_REFERENCE_INCONSISTENT`, `INVALID_NOSE_IMAGE`, embed/Qdrant errors | dog identity 등록/중복 검사 |
| `GET /api/dogs/me` | 필요 | 없음 | `page`, `size` | dog list, `can_create_post`, active post metadata | `INVALID_PAGE_REQUEST` | 내 강아지 목록 |
| `GET /api/dogs/{dog_id}` | 선택 | 없음 | path `dog_id` | owner/public dog detail | `DOG_NOT_FOUND`, `DOG_NOT_ACCESSIBLE` | 강아지 상세 |
| `POST /api/adoption-posts` | 필요 | `multipart/form-data` | `dog_id`, `title`, `content`, optional `status`, required `profile_image` | `post_id`, `dog_id`, `title`, `content`, `status`, timestamps | `PROFILE_IMAGE_REQUIRED`, `DOG_NOT_FOUND`, `DOG_OWNER_MISMATCH`, `DOG_NOT_REGISTERED`, `DOG_NOT_VERIFIED`, `DOG_ALREADY_HAS_ACTIVE_POST` | 분양글 생성 및 대표 이미지 저장 |
| `GET /api/adoption-posts` | 불필요 | 없음 | optional `status`, `page`, `size` | public post list | `INVALID_POST_STATUS`, `INVALID_PAGE_REQUEST` | 공개 피드 |
| `GET /api/adoption-posts/{post_id}` | 불필요 | 없음 | path `post_id` | public post detail | `POST_NOT_FOUND`, `POST_NOT_PUBLIC` | 공개 상세 |
| `GET /api/adoption-posts/me` | 필요 | 없음 | optional owner `status`, `page`, `size` | owner post list | auth/page/status errors | 내 분양글 관리 |
| `PATCH /api/adoption-posts/{post_id}/status` | 필요 | `application/json` | path `post_id`, body `status`, `COMPLETED`일 때 `adopter_user_id` | updated post status, `adopter_user_id`, `adopted_at` | `INVALID_STATUS_TRANSITION`, `ADOPTER_REQUIRED`, `DOG_ALREADY_HAS_ACTIVE_POST` 등 | 상태 변경 |
| `POST /api/adoption-posts/{post_id}/handover-verifications` | 필요 | `multipart/form-data` | path `post_id`, required `nose_image` | `post_id`, `expected_dog_id`, `matched`, `decision`, `similarity_score`, `message` | handover verification errors | 인도 시점 비문 확인 |

## 5. Flutter State Decisions

- `POST /api/dogs/register` 정상 등록: `registration_allowed=true`, `qdrant_point_id=null`.
- 정상 등록 side effect는 `dog_images=5`, `dog_nose_references=6`, Qdrant points=6이다. Qdrant points는 `REFERENCE` 5개와 `CENTROID` 1개다.
- Registration 단건 `nose_image` field는 v2 active contract가 아니다. Python Embed `/embed-batch`는 내부 endpoint로 1~5장을 받을 수 있지만, backend dog registration API는 정확히 5장만 허용한다.
- Reference quality diagnostics verdict는 `ACCEPTED`, `WARN_ACCEPTED`, `RETAKE_ONE`, `RETAKE_ALL`이다. `RETAKE_ONE`/`RETAKE_ALL`은 새로 올린 5장 자체의 품질 실패이며 `NOSE_REFERENCE_INCONSISTENT`로 반환된다.
- Duplicate decision은 `final_score = max(max_reference_score, centroid_score)` 기준 binary policy다.
- `final_score >= 0.65`이면 `DUPLICATE_SUSPECTED`, `final_score < 0.65`이면 `REGISTERED`다. `REVIEW_REQUIRED`는 active normal decision에서 사용하지 않는다.
- Qdrant search pre-filter `0.55`는 내부 후보 검색 기준이며 review band가 아니다.
- 중복 의심: `registration_allowed=false`, `status=DUPLICATE_SUSPECTED`, `qdrant_point_id=null`. Flutter는 post creation을 막는다.
- 분양글 생성 버튼은 registered dog만 활성화한다. 최종 검증은 backend가 다시 수행한다.
- `POST /api/adoption-posts`는 dog 또는 nose image upload endpoint가 아니다. 단, 분양글 대표 이미지 `profile_image`는 `dog_images.image_type=PROFILE`로 저장한다.
- public adoption post list/detail은 `nose_image_url`을 노출하지 않는다.
- Handover는 단건 `nose_image`를 사용한다. Registration의 `nose_images` 5장 field로 바꾸지 않는다.
- Handover는 `post_id -> adoption_posts.dog_id` 경로로 expected dog를 찾고, 해당 dog의 active `REFERENCE` 5개와 `CENTROID` 1개를 query image 1장과 비교한다.
- Handover decision은 `final_score = max(max_reference_score, centroid_score)` 기준으로 `final_score >= 0.65`이면 `MATCHED`, `final_score < 0.65`이면 `NOT_MATCHED`다.
- `AMBIGUOUS`는 enum compatibility/historical evidence로 남아 있지만 active normal handover decision에서는 사용하지 않는다. `NO_MATCH_CANDIDATE`는 후보 없음 예외 상태다.
- `matched=true`는 safety signal이다. 완료 처리는 별도 status update가 필요하다.

## 6. Schema/Migration Reminder

- develop 제출 기준 MySQL table은 총 8개다.
- Core domain/relationship table은 `users`, `dogs`, `dog_images`, `dog_nose_references`, `verification_logs`, `adoption_posts`, `adoption_post_likes` 7개다.
- Auth support table은 `password_reset_tokens` 1개이며 domain table로 세지 않는다.
- V3는 historical migration으로 남아 있고, V4가 auxiliary table을 제거한다. V5 이후 migration은 dog nose v2 references, user profile image, password reset, likes, adoption completion adopter fields를 추가한다.
- canonical schema/DBML에는 `nose_verification_attempts`, `post_adoption_verifications`, 별도 handover table이 없어야 한다.

## 7. Real-model MVP E2E Smoke

`scripts/verify-dog-id-centered-flow.ps1`는 빠른 static 문서/스키마, backend test/build, compose config 검증용이다. 실제 Docker runtime에서 회원가입부터 완료 처리까지 end-to-end로 확인할 때는 `docs/ops-evidence/dog-nose-v2-smoke-plan.md`의 active dog nose v2 기준을 따른다.

전제:

- Docker Desktop과 Docker Compose v2가 실행 중이어야 한다.
- 실제 모델 모드는 `infra/docker/compose.yaml`, `infra/docker/compose.dev.yaml`, `infra/docker/compose.real-model.yaml` 조합을 사용한다.
- `infra/docker/.env`가 있으면 compose 실행 시 함께 사용될 수 있다.
- Registration active contract는 비문 기준 사진 5장을 요구한다. Smoke/manual 검증도 같은 dog의 close-up cropped dog nose image 5장을 사용해야 한다. 임의 텍스트 파일은 사용하지 않는다.
- Handover verification은 registration과 다르게 단건 `nose_image`를 사용한다.
- Qdrant collection은 `dog_nose_embeddings_real_v2`, vector dimension은 `2048`, distance는 `Cosine`이다.
- Clean runtime 검증에서 reset 절차는 PetNose compose project의 컨테이너/볼륨을 초기화하므로 로컬 dev 데이터 삭제를 의도할 때만 사용한다.

Dog nose v2 smoke가 검증하는 핵심 flow:

- 회원가입, 로그인, Bearer JWT 기반 `/api/users/me`.
- `/api/dogs/register` 정상 등록과 같은 5장 reference set 중복 등록 차단.
- handover verification은 registration과 다른 단건 `nose_image`를 expected dog와 비교한다.
- 정상 dog의 `/api/adoption-posts` 생성과 duplicate suspected dog의 게시글 생성 차단.
- 공개 분양글 list/detail의 `nose_image_url` 비노출.
- handover verification의 `matched=true` 확인.
- owner-only status update로 `COMPLETED` 전환 후 `POST_NOT_VERIFIABLE` 거부 확인.
- `/files/{relative_path}` 정적 파일 접근 확인.
- Qdrant 직접 point 조회가 가능한 환경에서는 정상 dog의 `REFERENCE`/`CENTROID` points 존재와 duplicate suspected dog point 부재 확인.
- Docker MySQL direct check가 가능한 환경에서는 7개 core/relationship table, `password_reset_tokens` auth support table, 그리고 legacy precheck/post-adoption periodic table 부재를 확인한다.
