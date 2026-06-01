# PetNose MVP 최종 프로젝트 명세

## Canonical Baseline

이 문서는 simplified DBML v2 기준의 active PetNose MVP canonical model을 정의한다.

active domain table은 아래 6개다.

1. `users`
2. `dogs`
3. `dog_images`
4. `dog_nose_references`
5. `verification_logs`
6. `adoption_posts`

MySQL은 account, dog, image metadata, verification history, adoption post data의 source of truth다. Qdrant는 vector search index일 뿐이다. image binary는 파일로 저장하고, MySQL에는 `dog_images.file_path`에 상대 경로만 저장한다.

Dog nose v2의 active Qdrant collection은 `dog_nose_embeddings_real_v2`다. Vector dimension은 `2048`, distance는 `Cosine`이다. Qdrant point id는 UUID이며 더 이상 `dogs.id` 단일 point를 사용하지 않는다. `dog_id`는 Qdrant payload와 MySQL `dog_nose_references`로 추적한다.

## MVP v2에서 제외된 범위

과거 separate profile, auth history, report, token, image quality/crop, reservation, payment, contract, report/admin dashboard, non-canonical role extension 영역은 current canonical MVP v2 schema 또는 API surface에 포함하지 않는다.

Firebase chat/push may be provided as an optional communication layer. It is not part of the core MySQL domain schema and does not replace MySQL source of truth. Firebase remains outside the core dog-registration trust pipeline.

## Users

`users`는 account identity와 author display information을 직접 저장한다.

Columns:

- `id`
- `email`
- `password_hash`
- `role`
- `display_name`
- `contact_phone`
- `region`
- `is_active`
- `created_at`

허용 role은 `USER`와 `ADMIN`뿐이다.

`display_name`, `contact_phone`, `region`은 DB/entity level에서 migration/import flexibility를 위해 nullable로 둘 수 있다. 다만 public signup API인 `POST /api/auth/register`는 `email`, `password`, `display_name`, `contact_phone`, `region`을 모두 required로 요구한다. `contact_phone`은 `^010[0-9]{8}$` 형식, 예를 들어 `01012341234`처럼 하이픈 없는 11자리여야 한다. Nose verification 단계는 author display information을 다시 받지 않지만, adoption post를 생성하기 전에는 service가 `users.display_name` 존재 여부를 검증해야 한다.

`PATCH /api/users/me/profile`로 `display_name`을 설정할 때는 더 엄격한 작성자 표시명 정책을 적용한다. 값은 trim 후 저장하며 2자 이상 10자 이하, 한글 완성형 음절/English letters/digits만 허용하고 whitespace, special character, emoji는 허용하지 않는다. `contact_phone`은 optional이지만 profile update로 설정하는 경우 hyphen 없는 11자리 mobile phone number여야 한다. `region`은 optional이고 Flutter UI 선택값을 저장하는 필드다. backend는 profile update에서 trim, blank rejection, max-length validation을 적용하되 district enum/list를 강제하지 않는다.

## Dogs

`dogs`는 기본 강아지 정보와 lifecycle/service status를 저장한다.

Columns:

- `id`
- `owner_user_id`
- `name`
- `breed`
- `gender`
- `birth_date`
- `description`
- `status`
- `created_at`
- `updated_at`

`dogs.status`는 dog lifecycle/service status다.

- `PENDING`
- `REGISTERED`
- `DUPLICATE_SUSPECTED`
- `REVIEW_REQUIRED`
- `REJECTED`
- `ADOPTED`
- `INACTIVE`

`DUPLICATE_SUSPECTED`와 `REVIEW_REQUIRED`는 adoption post creation을 막는 호환 상태로 `dogs.status`에 남긴다. Active dog nose v2 normal registration decision은 `REVIEW_REQUIRED`를 반환하지 않지만, 기존 데이터와 enum 호환성을 유지한다. similarity, duplicate candidate, model, dimension, score breakdown 같은 detailed verification information은 `verification_logs`에 속한다.

`dogs`는 `qdrant_point_id`를 저장하지 않는다. Dog nose v2에서는 등록된 dog마다 Qdrant `REFERENCE` point 5개와 `CENTROID` point 1개를 UUID point id로 만든다. point id와 reference metadata는 `dog_nose_references`가 추적한다.

`breed`와 `gender`는 DB/entity level에서 operational/import flexibility를 위해 nullable로 둘 수 있다. 다만 current MVP dog registration API인 `POST /api/dogs/register`는 `breed` non-blank와 `gender` 제출을 요구한다. `gender`는 `MALE`, `FEMALE`, `UNKNOWN` 중 하나이며, `UNKNOWN`은 client가 명시적으로 제출하는 값이고 DB default로 자동 적용되는 값이 아니다.

## Dog Images

`dog_images`는 image metadata와 relative file path만 저장한다.

허용 `image_type` 값:

- `NOSE`
- `PROFILE`

Columns:

- `id`
- `dog_id`
- `image_type`
- `file_path`
- `mime_type`
- `file_size`
- `sha256`
- `uploaded_at`

Image file은 MySQL BLOB column에 저장하지 않는다.

service가 생성하는 `dog_images` row는 정상적으로 `mime_type`, `file_size`, `sha256` metadata를 포함해야 한다. 이 metadata column들은 migration/import flexibility를 위해 DB level에서는 nullable로 남길 수 있다.

비문 이미지는 `POST /api/dogs/register` 단계에서 `dog_images.image_type=NOSE` row로 저장한다. Dog nose v2 registration은 `nose_images` 정확히 5장을 required로 받으며, 사용자가 close-up cropped nose image를 제공한다고 가정한다. Backend는 crop/detection/alignment를 수행하지 않는다. 등록 전 5장 reference set에 대해 pairwise quality diagnostics를 수행하며, 5장 기준 10개 pairwise comparison만 계산한다. `POST /api/adoption-posts`는 이미 등록된 `dog_id`만 참조하고, 분양글 대표 이미지인 `profile_image`만 `dog_images.image_type=PROFILE` row로 저장한다.

## Dog Nose References

`dog_nose_references`는 MySQL에서 Qdrant point id와 dog nose reference metadata를 추적한다.

Columns:

- `id`
- `dog_id`
- `dog_image_id`
- `qdrant_point_id`
- `embedding_kind`
- `reference_index`
- `model`
- `dimension`
- `preprocess_version`
- `quality_status`
- `quality_score`
- `is_active`
- `created_at`

허용 `embedding_kind` 값:

- `REFERENCE`
- `CENTROID`

허용 `quality_status` 값:

- `ACCEPTED`
- `REJECTED`
- `NEEDS_REVIEW`

정상 등록(`PASSED`)에서만 `REFERENCE` 5개와 `CENTROID` 1개가 Qdrant에 upsert되고 `dog_nose_references` row 6개가 생성된다. `DUPLICATE_SUSPECTED` decision은 file/DB/log evidence를 남길 수 있지만 active Qdrant point와 `dog_nose_references`를 만들지 않는다. `REVIEW_REQUIRED`는 호환 상태로 유지하지만 active dog nose v2 normal registration decision에서는 반환하지 않는다.

## Verification Logs

`verification_logs`는 current dog registration verification history의 source of truth다. Schema와 enum은 `purpose=HANDOVER_COMPARE`를 허용하지만, current MVP handover verification API는 stateless safety check이며 `verification_logs` row를 생성하지 않는다.

Columns:

- `id`
- `dog_id`
- `dog_image_id`
- `requested_by_user_id`
- `submitted_image_path`
- `submitted_image_mime_type`
- `submitted_image_file_size`
- `submitted_image_sha256`
- `result`
- `purpose`
- `similarity_score`
- `score_breakdown_json`
- `candidate_dog_id`
- `model`
- `dimension`
- `failure_reason`
- `created_at`

허용 `result` 값:

- `PENDING`
- `PASSED`
- `DUPLICATE_SUSPECTED`
- `REVIEW_REQUIRED`
- `EMBED_FAILED`
- `QDRANT_SEARCH_FAILED`
- `QDRANT_UPSERT_FAILED`

Embedding vector 자체는 MySQL에 저장하지 않는다. vector는 Qdrant에만 저장한다.

`similarity_score`는 persistence 기준으로 `DECIMAL(6,5)`를 유지한다. API response에서는 numeric JSON 값으로 노출될 수 있으므로 trailing zero 표시까지 보장하지 않는다.

허용 `purpose` 값:

- `DOG_REGISTRATION`
- `HANDOVER_COMPARE`

`POST /api/dogs/register`가 dog identity를 만들고 비문 중복 검사를 수행하며, `verification_logs`에 `purpose=DOG_REGISTRATION` row를 남긴다. `POST /api/adoption-posts`는 verification ticket을 소비하지 않고, 이미 등록된 dog의 latest verification log가 `PASSED`인지 확인한다.

## Adoption Posts

`adoption_posts`는 adoption listing content와 publishing state를 저장한다.

Columns:

- `id`
- `author_user_id`
- `dog_id`
- `title`
- `content`
- `status`
- `published_at`
- `closed_at`
- `created_at`
- `updated_at`

허용 `status` 값:

- `DRAFT`
- `OPEN`
- `RESERVED`
- `COMPLETED`
- `CLOSED`

Adoption post를 생성하거나 `OPEN`으로 전환하기 전에는 유효한 author `display_name`이 필요하다. 신규 post 생성은 request `dog_id`로 이미 등록된 dog를 참조한다. 이 단계는 새 dog, 새 NOSE image, embedding, Qdrant upsert를 만들지 않는다. 단, 분양글 대표 이미지 `profile_image`는 필수이며 `dog_images.image_type=PROFILE` row로 저장한다. `DUPLICATE_SUSPECTED`, `REVIEW_REQUIRED`, 또는 failed registration dog는 post 작성 대상이 될 수 없다.

current MVP post creation policy에서 `title`은 required/non-blank이며 최대 200자다. `content`도 required/non-blank다.

`POST /api/adoption-posts`는 `multipart/form-data` request로 `dog_id`, `title`, `content`, optional `status`, required `profile_image`를 받는다.

current API timestamp 표현은 resource 계열에 따라 다를 수 있다. dog, dog image, verification log 계열은 Instant-style timestamp를 노출할 수 있고, adoption post 계열은 LocalDateTime-style timestamp를 노출할 수 있다.

## 인도 시점 비문 확인(Handover-Time Dog Nose Verification)

인도 시점 비문 확인은 adoption post publication과 status management 이후의 MVP trust/safety flow에 포함된다.

이 기능은 실제 인도 장소에서 만난 강아지가 adoption post에 등록된 강아지와 같은 개체인지 확인하는 질문에 답한다.

handover verification API는 dog registration과 의도적으로 다르다.

- `POST /api/dogs/register`는 dog identity 등록, duplicate suspicion detection, Qdrant upsert의 유일한 active MVP 진입점이다.
- `POST /api/adoption-posts`는 이미 등록된 dog를 게시글로 노출할 뿐, vector를 다시 만들지 않는다.
- `POST /api/adoption-posts/{post_id}/handover-verifications`는 dog를 등록하지 않는다.
- 이 API는 새로 촬영한 nose image를 기존 adoption post에 연결된 dog와 비교한다.
- expected dog는 `adoption_posts.dog_id`이며, Qdrant point id는 `dog_id`와 같지 않다.
- handover는 uploaded handover image embedding을 expected dog의 active `REFERENCE`/`CENTROID` point set과 비교한다.
- Python Embed 호출은 handover에서 `/embed` 단건 endpoint를 사용한다.
- Spring Boot가 Python Embed와 Qdrant 호출을 오케스트레이션한다. Flutter는 Python Embed, Qdrant, MySQL을 직접 호출하지 않는다.

MVP handover verification check는 stateless다.

- handover image를 저장하지 않는다.
- dog를 생성하지 않는다.
- `dog_images` row를 생성하지 않는다.
- current MVP implementation에서는 `verification_logs` row를 생성하지 않는다.
- `adoption_posts.status`를 변경하지 않는다.
- `dogs.status`를 변경하지 않는다.
- 자동으로 adoption completion을 수행하지 않는다.
- adoption completion은 별도의 owner-only status update action으로 남는다.

Dog nose v2 handover threshold policy는 expected dog reference set에서 나온 decision score(`final_score`)에 적용한다.

- Qdrant query는 `dog_id=adoption_posts.dog_id`, `is_active=true`, `embedding_kind in (REFERENCE, CENTROID)`인 expected dog reference set만 찾는다.
- `final_score = max(max_reference_score, centroid_score)`이며 `score_breakdown`은 두 점수를 분리 제공한다.
- decision score가 `0.65` 이상이면 같은 dog로 보고 `matched=true`, `MATCHED`를 반환한다.
- decision score가 `0.65` 미만이면 다른 dog로 보고 `matched=false`, `NOT_MATCHED`를 반환한다.
- expected dog candidate가 없으면 `matched=false`, `NO_MATCH_CANDIDATE`를 반환한다.
- `AMBIGUOUS` enum과 response field는 호환성을 위해 유지하지만 active dog nose v2 normal decision에서는 사용하지 않는다.
- handover `MATCHED`는 safety signal이며 adoption post를 자동 완료하지 않는다.

이 기능은 reservation, payment, contract, report/admin, `SHELTER`, `ADOPTER` concept을 추가하지 않는다. Firebase chat/push는 선택적 communication layer일 수 있지만, handover verification이나 dog registration trust pipeline의 일부가 아니다.

## Dog Registration and Adoption Creation Policy

`POST /api/dogs/register`는 신규 분양글 작성 flow의 identity registration endpoint다. 이 단계에서 dog 기본 정보와 `nose_images` 정확히 5장을 받고, Python `/embed-batch` 1회 호출로 reference embedding을 생성한 뒤 Qdrant duplicate search, `verification_logs` 기록, 조건부 Qdrant upsert를 수행한다. Python `/embed-batch` 자체는 내부 endpoint로서 1~5장 batch 입력을 계속 허용하지만, registration API는 5장 입력만 통과시킨다.

`POST /api/adoption-posts`는 `dog_id`와 required `profile_image`를 받아 이미 등록된 dog로 게시글과 대표 이미지만 생성한다. 이 endpoint는 embed service를 호출하지 않고 Qdrant upsert를 수행하지 않는다.

Dog ownership은 JWT principal-only다. `dogs.owner_user_id`는 Bearer JWT로 resolve된 current active user에서 결정하며, public API contract는 request `user_id`를 ownership input으로 받지 않는다.

Dog nose v2 duplicate/pass policy는 Spring score breakdown의 final score 기준이다.

- Qdrant candidate search pre-filter threshold는 `0.55`다.
- 이 값은 Spring이 후보를 넓게 보기 위한 내부 검색 기준이며 보류 구간이 아니다.
- reference quality pairwise threshold는 `0.55`다.
- reference outlier improvement threshold는 `0.04`다.
- reference quality verdict는 `ACCEPTED`, `WARN_ACCEPTED`, `RETAKE_ONE`, `RETAKE_ALL`이다.
- `final_score = max(max_reference_score, centroid_score)`이며 `score_breakdown`은 두 점수를 분리 제공한다.
- `final_score >= 0.65`이면 `DUPLICATE_SUSPECTED`다.
- `final_score < 0.65`이면 `PASSED`다.
- `REVIEW_REQUIRED` enum/status는 호환성을 위해 유지하지만 active dog nose v2 normal registration decision에서는 사용하지 않는다.
- `WARN_ACCEPTED`는 등록을 막지 않고 `score_breakdown_json.reference_quality`에 warning summary를 저장한다.
- `RETAKE_ONE` 또는 `RETAKE_ALL`은 `NOSE_REFERENCE_INCONSISTENT` HTTP `400`이며 details에 `quality_verdict`, `weakest_image_index`, `best_subset_indexes`, `recommendation`, `pairwise_scores`를 포함하고 file/DB/Qdrant side effect를 만들지 않는다.
- `DUPLICATE_SUSPECTED`는 file/DB/log evidence를 남길 수 있지만 Qdrant upsert를 수행하지 않는다.
- `PASSED`만 Qdrant upsert와 `dog_nose_references` 생성을 수행한다.
- Leave-one-out subset은 진단용으로만 계산한다. best3/best4 자동 선택, outlier reference 제거, quality rejected image 저장 제외는 이번 정책에 포함하지 않는다.

계산되는 response field:

- `qdrant_point_id`
  - dog nose v2 active contract에서는 항상 `null`
- `verification_status`
  - latest `verification_logs.result`에서 계산
  - `REVIEW_REQUIRED`는 호환 값으로 유지하지만 active normal registration decision에서는 반환하지 않음
- `embedding_status`
  - latest `verification_logs.result`에서 계산
  - `REVIEW_REQUIRED`는 호환 값으로 `SKIPPED_REVIEW`

Dog registration만 Qdrant에 dog nose reference vectors를 저장한다. 저장 시 point id는 UUID이고 payload에 `dog_id`, `embedding_kind`, reference metadata를 포함한다. Adoption post creation은 Qdrant를 호출하지 않으며, `profile_image` 저장은 MySQL/file storage metadata에만 영향을 준다. Duplicate suspected/review-required flow는 새 dog에 대한 active Qdrant point를 upsert하지 않아야 한다. `post_id`는 Qdrant id가 아니며, handover verification은 `post_id -> adoption_posts.dog_id -> dog_nose_references/Qdrant expected reference set` 순서로 expected vectors를 찾는다.

## 최종 MVP 사용자 흐름

1. `USER`는 `POST /api/auth/register`로 가입하고 `POST /api/auth/login`으로 Bearer access token을 받는다.
2. Flutter는 `GET /api/users/me`로 profile readiness를 확인하고, 필요하면 `PATCH /api/users/me/profile`로 작성자 표시 정보를 보완한다.
3. 로그인한 `USER`가 Bearer JWT로 인증한 뒤 `POST /api/dogs/register`로 dog 기본 정보와 `nose_images` 정확히 5장을 제출한다.
4. `registration_allowed=false`인 duplicate suspicion 또는 review-required decision은 adoption post creation을 막고 Qdrant upsert를 수행하지 않는다.
5. `registration_allowed=true`이면 Flutter는 반환된 `dog_id`를 분양글 작성 form state에 보관한다.
6. Flutter는 `POST /api/adoption-posts` multipart request에 `dog_id`, `title`, `content`, optional `status`, required `profile_image`를 보낸다.
7. Flutter는 필요하면 `GET /api/dogs/me`와 `GET /api/dogs/{dog_id}`로 owner dog query와 post 생성 가능 여부를 확인할 수 있다.
8. public user는 nose image 노출 없이 adoption post를 볼 수 있다.
9. 인도 시점에는 authenticated user가 새로 촬영한 nose image를 업로드해 post의 expected dog와 stateless verification을 수행할 수 있다.
10. matched handover verification result는 safety signal일 뿐이다.
11. completion은 기존 owner-only post status update flow로 처리한다.
