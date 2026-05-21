# PetNose MVP API 계약

## 문서 범위

이 문서는 simplified DBML v2 canonical model 기준의 active MVP API contract다.

Base URL: `http://<host>/api`

이 문서는 current backend implementation에 맞춘 Flutter MVP flow를 기록한다. Firebase chat/push는 MySQL source of truth를 대체하지 않는 optional communication layer로만 다룬다. expanded profile table, report API, refresh token, non-canonical role concept은 추가하지 않는다.

## Canonical Response Rules

- JSON response field는 `snake_case`를 사용한다.
- 공통 error response는 아래 shape를 사용한다.

```json
{
  "error_code": "VALIDATION_FAILED",
  "message": "입력값 검증에 실패했습니다.",
  "details": {
    "timestamp": "2026-05-13T00:00:00Z"
  }
}
```

- MVP role은 `USER`와 `ADMIN`만 사용한다.
- `users`가 `display_name`, `contact_phone`, `region`, `is_active`를 직접 가진다.
- MySQL은 source of truth다. Qdrant는 nose embedding vector index일 뿐이다.
- `dog_images.file_path`는 upload root 기준 상대 경로를 저장한다.
- `qdrant_point_id`, `verification_status`, `embedding_status`는 API-calculated field이며 DB column이 아니다.
- similarity score는 JSON number로 반환된다. DB persistence는 `DECIMAL(6,5)` 기준이지만, API numeric serialization은 trailing zero 표시를 보장하지 않는다.
- dog/verification/image 계열 resource timestamp는 current implementation에서 Instant-style `Z` timestamp로 노출될 수 있고, adoption post 계열 timestamp는 zone 없는 LocalDateTime-style timestamp로 노출될 수 있다.
- public adoption post list/detail response는 `nose_image_url`을 노출하지 않는다.
- owner-scoped dog registration response는 새로 제출한 dog 자신의 `nose_image_url`을 반환할 수 있다.
- `top_match`는 raw `nose_image_url`을 노출하지 않는다.
- handover verification response는 `nose_image_url`, `top_matched_dog_id`, 다른 dog의 `dog_id`, Qdrant payload details, `author_user_id`를 노출하지 않는다.

## Flutter MVP Flow Readiness

| Step | Endpoint or branch | Current status | Flutter dependency |
| --- | --- | --- | --- |
| 1 | `POST /api/auth/register` | 구현됨 | public signup으로 `USER` 계정을 만든다. |
| 2 | `POST /api/auth/login` | 구현됨 | Bearer access token과 current user payload를 받는다. |
| 3 | `GET /api/users/me` | 구현됨 | profile readiness field를 읽는다. |
| 4 | `PATCH /api/users/me/profile` | 구현됨 | 누락된 `display_name`과 선택적 phone/region을 채운다. |
| 5 | `POST /api/dogs/register` | 구현됨 | dog identity 등록, 비문 embedding, Qdrant duplicate search, Qdrant upsert의 유일한 진입점이다. |
| 6 | `registration_allowed=false` | 구현됨 | duplicate suspected 화면으로 분기하고 post creation을 막는다. Qdrant upsert는 수행하지 않는다. |
| 7 | `registration_allowed=true` | 구현됨 | response `dog_id`를 분양글 작성 form state에 저장한다. Qdrant point id도 같은 `dog_id`다. |
| 8 | `POST /api/adoption-posts` | 구현됨 | 이미 등록된 `dog_id`, title, content, status, required `profile_image`로 `DRAFT` 또는 `OPEN` post를 만든다. |
| 9 | `GET /api/dogs/me` | 구현됨 | current user의 dog 목록과 post 생성 가능 여부를 읽는다. |
| 10 | `GET /api/dogs/{dog_id}` | 구현됨 | owner detail 또는 public dog detail을 렌더링한다. |
| 11 | `GET /api/adoption-posts` | 구현됨 | nose image 없이 public post list를 렌더링한다. |
| 12 | `GET /api/adoption-posts/{post_id}` | 구현됨 | nose image 없이 public post detail을 렌더링한다. |
| 13 | `GET /api/adoption-posts/me` | 구현됨 | current user의 post만 나열한다. |
| 14 | `PATCH /api/adoption-posts/{post_id}/status` | 구현됨 | owner-only post status management를 수행한다. |
| 15 | `POST /api/adoption-posts/{post_id}/handover-verifications` | 구현됨 | `post_id -> adoption_posts.dog_id -> Qdrant point id = dog_id`로 1:1 identity check를 수행한다. |

handover verification endpoint는 MVP trust/safety flow의 일부다. 이 contract 밖의 더 넓은 API 확장은 follow-up scope로 남긴다.

## Auth

### 회원가입

```http
POST /api/auth/register
Content-Type: application/json
```

Request body:

```json
{
  "email": "user@example.com",
  "password": "password123",
  "display_name": "초코 보호자",
  "contact_phone": "01012341234",
  "region": "서울"
}
```

Response `201`:

```json
{
  "user_id": 101,
  "email": "user@example.com",
  "role": "USER",
  "display_name": "초코 보호자",
  "contact_phone": "01012341234",
  "region": "서울",
  "is_active": true
}
```

Contract notes:

- public signup은 항상 `role=USER`를 생성한다.
- public signup으로 `ADMIN`을 생성하지 않는다. request body에 `role`이 포함되어도 current implementation은 무시하고 `USER`를 저장한다.
- `password_hash`는 DB에 저장하지만 API response에는 노출하지 않는다.
- email은 trim 후 lowercase로 normalize한다.
- password는 trim 후 8자 이상이어야 한다.
- `display_name`, `contact_phone`, `region`은 signup에서 필수값이다.
- `contact_phone`은 `^010[0-9]{8}$` 형식이어야 한다. 예: `01012341234`.
- current JSON serialization은 `UserMeResponse` field set을 사용하므로 profile field key를 response에 유지한다.
- adoption post creation은 non-blank `users.display_name`을 요구한다.

Error codes:

- `VALIDATION_FAILED`
- `EMAIL_ALREADY_EXISTS`

### 로그인

```http
POST /api/auth/login
Content-Type: application/json
```

Request body:

```json
{
  "email": "user@example.com",
  "password": "password123"
}
```

Response `200`:

```json
{
  "access_token": "jwt-access-token",
  "token_type": "Bearer",
  "expires_in": 3600,
  "user": {
    "user_id": 101,
    "email": "user@example.com",
    "role": "USER",
    "display_name": "초코 보호자",
    "contact_phone": "01012341234",
    "region": "서울",
    "is_active": true
  }
}
```

Contract notes:

- email은 signup과 동일하게 trim 후 lowercase로 normalize한다.
- `expires_in`은 current default configuration 기준 `3600`초다.
- response `user`는 `UserMeResponse`와 같은 shape다.
- inactive user는 token을 발급하지 않고 HTTP `403`과 `USER_INACTIVE`를 반환한다.

Error codes:

- `VALIDATION_FAILED`
- `INVALID_CREDENTIALS`
- `USER_INACTIVE`

## Users

### 내 정보 조회

```http
GET /api/users/me
Authorization: Bearer <JWT>
```

Response `200`:

```json
{
  "user_id": 101,
  "email": "user@example.com",
  "role": "USER",
  "display_name": "초코 보호자",
  "contact_phone": "01012341234",
  "region": "서울",
  "is_active": true
}
```

Flutter-required fields:

- `user_id`
- `email`
- `role`
- `display_name`
- `contact_phone`
- `region`
- `is_active`

`display_name`, `contact_phone`, `region`은 `null`일 수 있지만 field name 자체는 response contract에 포함된다. `created_at`은 current `GET /api/users/me` response에 포함하지 않는다.

Contract notes:

- Bearer JWT authorization이 필요하다.
- `password_hash`는 API response에 노출하지 않는다.
- valid token의 subject가 inactive user로 resolve되면 HTTP `403`과 `USER_INACTIVE`를 반환한다.
- token subject가 existing user로 resolve되지 않으면 `USER_NOT_FOUND`를 반환한다.

Error codes:

- `UNAUTHORIZED`
- `USER_NOT_FOUND`
- `USER_INACTIVE`

### 작성자 표시 정보 수정

```http
PATCH /api/users/me/profile
Authorization: Bearer <JWT>
Content-Type: application/json
```

Request body:

```json
{
  "display_name": "초코보호자",
  "contact_phone": "01012345678",
  "region": "대구시 달서구"
}
```

Response `200`:

```json
{
  "user_id": 101,
  "display_name": "초코보호자",
  "contact_phone": "01012345678",
  "region": "대구시 달서구"
}
```

Contract notes:

- Bearer JWT authorization이 필요하다.
- 이 endpoint는 `display_name`, `contact_phone`, `region`만 수정한다.
- `email`, `role`, `is_active`, `password_hash`는 이 endpoint로 변경하지 않는다.
- `password_hash`는 API response에 노출하지 않는다.
- `display_name`, `contact_phone`, `region` 중 하나 이상은 있어야 한다.
- 생략한 field는 현재 값을 유지한다.
- 명시적 `null`은 해당 profile field를 비운다.
- `display_name`은 optional이다. 생략하면 현재 값을 유지하고, 명시적 `null`은 값을 비운다. non-null 값은 trim 후 저장하며, 2자 이상 10자 이하만 허용한다. 값 안의 whitespace, space, tab, newline, control character는 허용하지 않는다. 허용 문자는 한글 완성형 음절, English letters, digits뿐이며 special character와 emoji는 거부한다.
- `contact_phone`은 optional이다. 생략하면 현재 값을 유지하고, 명시적 `null`은 값을 비운다. non-null 값은 trim 후 저장하며, 정확히 11자리 숫자만 허용한다. hyphen, space, plus sign, parenthesis, 기타 symbol은 거부한다.
- `region`은 optional이다. 생략하면 현재 값을 유지하고, 명시적 `null`은 값을 비운다. non-null 값은 trim 후 저장하며, blank는 거부하고 최대 100자까지 허용한다. 이 branch의 backend는 district enum/list를 강제하지 않으며, Flutter selection UI가 `"대구시 달서구"` 같은 값을 제한한다.
- adoption post creation에는 non-blank `display_name`이 필요하다.

Error codes:

- `UNAUTHORIZED`
- `USER_NOT_FOUND`
- `USER_INACTIVE`
- `VALIDATION_FAILED`

## Dog Registration

### Nose Image로 Dog 등록

```http
POST /api/dogs/register
Content-Type: multipart/form-data
Authorization: Bearer <JWT>
```

Authentication policy:

- 이 endpoint는 dog identity 등록과 비문 중복 검사의 유일한 active MVP 진입점이다.
- `Authorization: Bearer <JWT>`가 필요하다.
- `owner_user_id`는 JWT principal로 resolve된 current active user에서만 결정한다.
- `user_id`는 active API contract 입력값이 아니다.
- client가 multipart form-data에 `user_id`를 보내더라도 무시되며 JWT ownership을 override할 수 없다.
- missing, malformed, invalid, or expired JWT는 `UNAUTHORIZED`를 반환한다.
- token subject가 existing user로 resolve되지 않으면 current `AuthService` convention에 따라 `USER_NOT_FOUND`를 반환한다.
- inactive current user는 HTTP `403`과 `USER_INACTIVE`를 반환한다.

Form fields:

- `name`: string, required, non-blank
- `breed`: string, required, non-blank
- `gender`: required, `MALE`, `FEMALE`, or `UNKNOWN`
- `birth_date`: `YYYY-MM-DD`, optional
- `description`: string, optional
- `nose_image`: file, required

Response `201`, normal registration:

```json
{
  "dog_id": "uuid",
  "registration_allowed": true,
  "status": "REGISTERED",
  "verification_status": "VERIFIED",
  "embedding_status": "COMPLETED",
  "qdrant_point_id": "uuid",
  "model": "dog-nose-identification2:s101_224",
  "dimension": 2048,
  "max_similarity_score": 0.41,
  "nose_image_url": "/files/dogs/{uuid}/nose/20260508_010203_nose.jpg",
  "profile_image_url": null,
  "top_match": null,
  "message": "중복 의심 개체가 없어 등록이 완료되었습니다."
}
```

Normal registration fields:

- `dog_id`
- `registration_allowed`
- `status`
- `verification_status`
- `embedding_status`
- `profile_image_url` (`null`)
- `top_match`
- `message`

App integration notes:

- Flutter adoption-post creation uses the returned `dog_id` when `registration_allowed=true`.
- Dog registration does not accept or store `profile_image`; dog profile image is uploaded later through `POST /api/adoption-posts` and stored as `dog_images.image_type=PROFILE`.
- Clients should use `dog_id`, `registration_allowed`, `status`, `verification_status`, `embedding_status`, `top_match`, and `message` for the active registration UI flow.
- Current response also includes diagnostic fields such as `qdrant_point_id`, `model`, `dimension`, `max_similarity_score`, and owner-scoped `nose_image_url`; app screens should not require these for normal flow rendering.

Response `200`, duplicate suspected:

```json
{
  "dog_id": "new-dog-id",
  "registration_allowed": false,
  "status": "DUPLICATE_SUSPECTED",
  "verification_status": "DUPLICATE_SUSPECTED",
  "embedding_status": "SKIPPED_DUPLICATE",
  "qdrant_point_id": null,
  "model": "dog-nose-identification2:s101_224",
  "dimension": 2048,
  "max_similarity_score": 0.99782,
  "nose_image_url": "/files/dogs/new-dog-id/nose/...",
  "profile_image_url": null,
  "top_match": {
    "dog_id": "existing-dog-id",
    "similarity_score": 0.99782,
    "breed": "말티즈"
  },
  "message": "기존 등록견과 동일 개체로 의심되어 등록이 제한됩니다."
}
```

Duplicate suspected contract:

- `registration_allowed`는 `false`다.
- `status`는 `DUPLICATE_SUSPECTED`다.
- `verification_status`는 `DUPLICATE_SUSPECTED`다.
- `embedding_status`는 `SKIPPED_DUPLICATE`다.
- `qdrant_point_id`는 `null`이다.
- `max_similarity_score`는 반환된 match 중 가장 높은 score다.
- `top_match`는 `dog_id`, `similarity_score`, `breed`만 포함한다.
- `top_match`는 `nose_image_url`을 포함하지 않는다.
- top-level `nose_image_url`은 owner-scoped registration response에서 새로 제출한 dog image이며 public exposure가 아니다.
- `message`는 Flutter duplicate suspected screen copy로 사용할 수 있다.
- `breed`와 `gender`는 DB-level flexibility와 별개로 dog registration API request에서는 required다.
- `UNKNOWN`은 client가 명시적으로 제출할 수 있는 gender 값이며 DB default로 자동 적용되는 값이 아니다.

Duplicate threshold policy:

- dog registration duplicate detection uses Qdrant cosine search score.
- current MVP duplicate threshold is `0.70`.
- duplicate if Qdrant score `>= 0.70`.
- not duplicate if Qdrant score `< 0.70`.
- Qdrant candidate search threshold default is `0.70`.
- Spring duplicate decision threshold default is `0.70`.
- threshold values are runtime configuration, not DB fields.
- Qdrant threshold and Spring threshold must stay aligned because Qdrant filters candidates before Spring makes the final duplicate decision.
- duplicate suspected response remains HTTP `200` with `registration_allowed=false`.
- normal registration response remains HTTP `201` with `registration_allowed=true`.
- `top_match` privacy is unchanged and does not expose raw `nose_image_url`.
- handover verification is a separate stateless flow, but current MVP aligns the same/different threshold to the same Qdrant cosine score `0.70` standard for simplicity.
- In normal registration, `max_similarity_score=0.0` can mean no Qdrant candidate was returned above `score_threshold=0.70`; it is not necessarily a literal model similarity score of zero.

Calculation policy:

- `qdrant_point_id`는 normal registration에서 `dog_id`, duplicate suspected registration에서 `null`로 계산한다.
- `verification_status`는 latest verification result에서 계산한다.
- `embedding_status`는 latest verification result에서 계산한다.
- similarity, duplicate candidate, model, dimension, failure metadata는 verification history에 저장한다.
- embedding vector는 Qdrant에만 저장한다.

Error codes:

- `UNAUTHORIZED`: missing, malformed, invalid, or expired JWT
- `USER_NOT_FOUND`: JWT subject가 existing user로 resolve되지 않음
- `USER_INACTIVE`: JWT subject가 inactive user로 resolve됨
- `NAME_REQUIRED`: `name`이 missing 또는 blank
- `BREED_REQUIRED`: `breed`가 missing 또는 blank
- `NOSE_IMAGE_REQUIRED`: `nose_image` field가 없거나 비어 있음
- `VALIDATION_FAILED`: malformed request field 또는 invalid `gender`
- `INVALID_BIRTH_DATE`: `birth_date`가 `YYYY-MM-DD` 형식이 아님
- `INVALID_NOSE_IMAGE`: nose image를 처리할 수 없음
- `EMBED_SERVICE_UNAVAILABLE`: embedding service에 접근할 수 없거나 사용할 수 없음
- `EMPTY_EMBEDDING`: embedding service가 vector를 반환하지 않음
- `EMBEDDING_DIMENSION_MISMATCH`: embedding dimension이 configured Qdrant vector dimension과 맞지 않음
- `QDRANT_SEARCH_FAILED`: Qdrant vector search 실패
- `QDRANT_UPSERT_FAILED`: Qdrant vector upsert 실패

## Dog Query

### 내 강아지 목록

```http
GET /api/dogs/me?page=0&size=20
Authorization: Bearer <JWT>
```

Query parameters:

- `page`: optional, zero-based page number, 기본값은 `0`.
- `size`: optional page size, 기본값은 `20`, 최대 `100`.

Response `200`:

```json
{
  "items": [
    {
      "dog_id": "uuid",
      "name": "초코",
      "breed": "말티즈",
      "gender": "MALE",
      "birth_date": "2023-01-01",
      "status": "REGISTERED",
      "verification_status": "VERIFIED",
      "embedding_status": "COMPLETED",
      "profile_image_url": "/files/dogs/{dog_id}/profile/profile.jpg",
      "has_active_post": false,
      "active_post_id": null,
      "can_create_post": true,
      "created_at": "2026-05-13T10:00:00Z"
    }
  ],
  "page": 0,
  "size": 20,
  "total_count": 1
}
```

Contract notes:

- Bearer JWT authorization이 필요하다.
- current user가 소유한 dog만 반환한다.
- `nose_image_url`은 list response에 노출하지 않는다.
- `verification_status`와 `embedding_status`는 latest `verification_logs.result`에서 계산한다.
- latest verification result가 없으면 `verification_status=PENDING`, `embedding_status=PENDING`이다.
- `PASSED`는 `VERIFIED` / `COMPLETED`로 계산한다.
- `DUPLICATE_SUSPECTED`는 `DUPLICATE_SUSPECTED` / `SKIPPED_DUPLICATE`로 계산한다.
- `EMBED_FAILED`, `QDRANT_SEARCH_FAILED`, `QDRANT_UPSERT_FAILED`는 failure 상태로 계산한다.
- `has_active_post`는 `DRAFT`, `OPEN`, `RESERVED` 상태의 active post가 있으면 `true`다.
- `can_create_post`는 아래 조건을 모두 만족할 때만 `true`다.
  - `dogs.status == REGISTERED`
  - latest verification result가 `PASSED`
  - active post가 없음

Error codes:

- `UNAUTHORIZED`
- `USER_NOT_FOUND`
- `USER_INACTIVE`
- `INVALID_PAGE_REQUEST`

### 강아지 상세

```http
GET /api/dogs/{dog_id}
Authorization: Bearer <JWT> optional
```

Current behavior:

- Authorization header가 없으면 public dog detail flow로 처리한다.
- Authorization header가 있으면 current `AuthService`로 JWT를 검증한다.
- invalid Authorization header 또는 invalid/expired token은 `UNAUTHORIZED`를 반환한다.
- token subject가 existing user로 resolve되지 않으면 `USER_NOT_FOUND`를 반환한다.
- token subject가 inactive user로 resolve되면 `USER_INACTIVE`를 반환한다.
- authenticated current user가 dog owner이면 owner detail을 반환한다.
- owner detail은 해당 owner의 dog `nose_image_url`을 노출할 수 있다.
- requester가 owner가 아니거나 Authorization header가 없으면 public detail을 반환할 수 있다.
- public detail은 해당 dog에 `OPEN` 또는 `RESERVED` adoption post가 있을 때만 반환한다.
- public dog detail은 `nose_image_url`을 노출하지 않는다.
- current implementation은 `COMPLETED`만 있는 dog를 Dog Query public detail 대상으로 보지 않는다.
- `GET /api/adoption-posts/{post_id}`는 `OPEN`, `RESERVED`, `COMPLETED` post detail을 public으로 반환할 수 있다. 이것은 Dog Query public detail eligibility와 별도다.
- public detail이 가능한 `OPEN`/`RESERVED` post가 없고 requester가 owner가 아니면 `DOG_NOT_ACCESSIBLE`을 반환한다.
- dog가 없으면 `DOG_NOT_FOUND`를 반환한다.

Owner response `200`:

```json
{
  "dog_id": "uuid",
  "name": "초코",
  "breed": "말티즈",
  "gender": "MALE",
  "birth_date": "2023-01-01",
  "description": "사람을 좋아합니다.",
  "status": "REGISTERED",
  "verification_status": "VERIFIED",
  "embedding_status": "COMPLETED",
  "nose_image_url": "/files/dogs/{dog_id}/nose/nose.jpg",
  "profile_image_url": "/files/dogs/{dog_id}/profile/profile.jpg",
  "has_active_post": false,
  "active_post_id": null,
  "can_create_post": true,
  "created_at": "2026-05-13T10:00:00Z",
  "updated_at": "2026-05-13T10:00:00Z"
}
```

Public response `200`:

```json
{
  "dog_id": "uuid",
  "name": "초코",
  "breed": "말티즈",
  "gender": "MALE",
  "birth_date": "2023-01-01",
  "description": "사람을 좋아합니다.",
  "status": "REGISTERED",
  "verification_status": "VERIFIED",
  "embedding_status": "COMPLETED",
  "profile_image_url": "/files/dogs/{dog_id}/profile/profile.jpg",
  "has_active_post": true,
  "active_post_id": 501,
  "can_create_post": false,
  "created_at": "2026-05-13T10:00:00Z",
  "updated_at": "2026-05-13T10:00:00Z"
}
```

Privacy rules:

- owner detail은 owner 자신의 dog `nose_image_url`을 노출할 수 있다.
- public detail은 `nose_image_url`을 노출하지 않는다.
- dog list는 `nose_image_url`을 노출하지 않는다.
- response field는 `snake_case`를 유지한다.

Error codes:

- `DOG_NOT_FOUND`
- `DOG_NOT_ACCESSIBLE`
- `UNAUTHORIZED`
- `USER_NOT_FOUND`
- `USER_INACTIVE`

## Adoption Posts

### Adoption Post 생성

```http
POST /api/adoption-posts
Authorization: Bearer <JWT>
Content-Type: multipart/form-data
```

Form fields:

- `dog_id`: string, required. `POST /api/dogs/register`에서 정상 등록된 dog id다.
- `title`: string, required, non-blank, max 200 after trim.
- `content`: string, required, non-blank.
- `status`: optional, `DRAFT` or `OPEN`; default `DRAFT`.
- `profile_image`: file, required. 분양글 대표 이미지이며 `dog_images.image_type=PROFILE` row로 저장된다.

Response `201`:

```json
{
  "post_id": 501,
  "dog_id": "uuid",
  "title": "말티즈 가족을 찾습니다",
  "content": "상세 내용...",
  "status": "OPEN",
  "published_at": "2026-05-13T10:00:00",
  "created_at": "2026-05-13T10:00:00"
}
```

Contract notes:

- JWT principal이 필요하다.
- `dog_id`는 존재해야 한다.
- `dog.owner_user_id`는 JWT principal user id와 일치해야 한다.
- `dog.status`는 `REGISTERED`여야 한다.
- 해당 dog의 latest `verification_logs.result`는 `PASSED`여야 한다.
- 같은 dog에 `DRAFT`, `OPEN`, `RESERVED` active post가 이미 있으면 생성할 수 없다.
- post 생성 전 `users.display_name`은 non-blank여야 한다.
- `title`은 required, non-blank이며 trim 후 최대 200자다.
- `content`는 required, non-blank이며 trim 후 저장된다.
- 분양글 생성은 새 `dogs` row 또는 새 NOSE `dog_images` row를 만들지 않는다.
- 분양글 생성은 `profile_image`를 저장하고 `dog_images.image_type=PROFILE` row를 만든다.
- 분양글 생성은 embed service를 호출하지 않고 Qdrant upsert도 수행하지 않는다.
- `DUPLICATE_SUSPECTED` 또는 failed registration dog는 대상이 될 수 없다.
- create는 `DRAFT` 또는 `OPEN`을 받는다. `status`를 생략하면 기본값은 `DRAFT`다.
- create-time service errors include `USER_PROFILE_REQUIRED`, `PROFILE_IMAGE_REQUIRED`, `DOG_NOT_FOUND`, `DOG_OWNER_MISMATCH`, `DOG_NOT_REGISTERED`, `DOG_NOT_VERIFIED`, `DOG_ALREADY_HAS_ACTIVE_POST`, `INVALID_POST_STATUS`, and `VALIDATION_FAILED`.

### 공개 분양글 목록(Public Adoption Post List)

```http
GET /api/adoption-posts?status=OPEN&page=0&size=20
```

Query parameters:

- `status`: optional, 기본값은 `OPEN`; 지원 값은 `OPEN`, `RESERVED`, `COMPLETED`.
- `page`: optional, zero-based page number, 기본값은 `0`.
- `size`: optional page size, 기본값은 `20`, 최대 `100`.

Public feed status display mapping:

- `OPEN` = 분양가능
- `RESERVED` = 예약중
- `COMPLETED` = 분양완료

Response `200`:

```json
{
  "items": [
    {
      "post_id": 501,
      "dog_id": "uuid",
      "title": "말티즈 가족을 찾습니다",
      "status": "OPEN",
      "dog_name": "초코",
      "breed": "말티즈",
      "gender": "MALE",
      "birth_date": "2024-01-01",
      "profile_image_url": "/files/dogs/{uuid}/profile/profile.jpg",
      "verification_status": "VERIFIED",
      "author_display_name": "초코 보호자",
      "author_region": "서울",
      "published_at": "2026-05-13T10:00:00",
      "created_at": "2026-05-13T10:00:00"
    }
  ],
  "page": 0,
  "size": 20,
  "total_count": 1
}
```

Contract notes:

- public list `status` 기본값은 `OPEN`이다.
- public list는 `OPEN`, `RESERVED`, `COMPLETED`를 받는다.
- `DRAFT`와 `CLOSED`는 public list status로 유효하지 않다.
- `verification_status`는 Flutter display를 위해 포함한다.
- `profile_image_url`은 노출할 수 있다.
- `nose_image_url`은 노출하지 않는다.
- invalid `status`는 `INVALID_POST_STATUS`를 반환한다.
- invalid `page` 또는 `size`는 `INVALID_PAGE_REQUEST`를 반환한다.

### 공개 분양글 상세(Public Adoption Post Detail)

```http
GET /api/adoption-posts/{post_id}
```

Response `200`:

```json
{
  "post_id": 501,
  "dog_id": "uuid",
  "title": "말티즈 가족을 찾습니다",
  "content": "상세 내용...",
  "status": "OPEN",
  "dog_name": "초코",
  "breed": "말티즈",
  "gender": "MALE",
  "birth_date": "2024-01-01",
  "description": "사람을 좋아합니다.",
  "profile_image_url": "/files/dogs/{uuid}/profile/profile.jpg",
  "verification_status": "VERIFIED",
  "author_display_name": "초코 보호자",
  "author_contact_phone": "01012341234",
  "author_region": "서울",
  "published_at": "2026-05-13T10:00:00",
  "created_at": "2026-05-13T10:00:00",
  "updated_at": "2026-05-13T10:00:00"
}
```

Contract notes:

- detail은 `OPEN`, `RESERVED`, `COMPLETED` post에 대해서만 public이다.
- `verification_status`는 Flutter display를 위해 포함한다.
- `profile_image_url`은 노출할 수 있다.
- `nose_image_url`은 노출하지 않는다.
- missing post는 `POST_NOT_FOUND`를 반환한다.
- non-public post는 `POST_NOT_PUBLIC`을 반환한다.

### Current User의 Adoption Posts 목록

```http
GET /api/adoption-posts/me?status=OPEN&page=0&size=20
Authorization: Bearer <JWT>
```

Query parameters:

- `status`: optional; 지원 값은 `DRAFT`, `OPEN`, `RESERVED`, `COMPLETED`, `CLOSED`.
- `page`: optional, zero-based page number, 기본값은 `0`.
- `size`: optional page size, 기본값은 `20`, 최대 `100`.

Response `200`:

```json
{
  "items": [
    {
      "post_id": 501,
      "dog_id": "uuid",
      "title": "말티즈 가족을 찾습니다",
      "status": "OPEN",
      "dog_name": "초코",
      "breed": "말티즈",
      "gender": "MALE",
      "birth_date": "2024-01-01",
      "profile_image_url": "/files/dogs/{uuid}/profile/profile.jpg",
      "verification_status": "VERIFIED",
      "published_at": "2026-05-13T10:00:00",
      "closed_at": null,
      "created_at": "2026-05-13T10:00:00",
      "updated_at": "2026-05-13T10:00:00"
    }
  ],
  "page": 0,
  "size": 20,
  "total_count": 1
}
```

Contract notes:

- Bearer JWT authorization이 필요하다.
- response는 current user가 소유한 post만 반환한다.
- `status`를 생략하면 current user가 소유한 모든 status를 반환한다.
- `nose_image_url`은 노출하지 않는다.
- invalid `status`는 `INVALID_POST_STATUS`를 반환한다.
- invalid `page` 또는 `size`는 `INVALID_PAGE_REQUEST`를 반환한다.
- missing, malformed, invalid, or expired JWT는 `UNAUTHORIZED`를 반환한다.

### Adoption Post Status 수정

```http
PATCH /api/adoption-posts/{post_id}/status
Authorization: Bearer <JWT>
Content-Type: application/json
```

Request body:

```json
{
  "status": "RESERVED"
}
```

Response `200`:

```json
{
  "post_id": 501,
  "dog_id": "uuid",
  "title": "말티즈 가족을 찾습니다",
  "content": "상세 내용...",
  "status": "RESERVED",
  "published_at": "2026-05-13T10:00:00",
  "closed_at": null,
  "created_at": "2026-05-13T10:00:00",
  "updated_at": "2026-05-13T10:05:00"
}
```

Allowed transitions:

- `DRAFT` -> `OPEN`
- `DRAFT` -> `CLOSED`
- `OPEN` -> `RESERVED`
- `OPEN` -> `COMPLETED`
- `OPEN` -> `CLOSED`
- `RESERVED` -> `OPEN`
- `RESERVED` -> `COMPLETED`
- `RESERVED` -> `CLOSED`

Contract notes:

- Bearer JWT authorization이 필요하다.
- post owner만 status를 수정할 수 있다.
- `COMPLETED`와 `CLOSED`는 terminal state다.
- `COMPLETED`는 `dogs.status`를 `ADOPTED`로 설정한다.
- `CLOSED`는 `dogs.status`를 `ADOPTED`로 설정하지 않는다.
- same-status PATCH는 no-op으로 구현되어 현재 post status response를 반환한다.
- `DRAFT` -> `OPEN`은 post creation과 같은 publish eligibility를 검증한다.
- missing post는 `POST_NOT_FOUND`를 반환한다.
- non-owner update는 `POST_OWNER_MISMATCH`를 반환한다.
- invalid `status`는 `INVALID_POST_STATUS`를 반환한다.
- invalid transition은 `INVALID_STATUS_TRANSITION`을 반환한다.
- missing, malformed, invalid, or expired JWT는 `UNAUTHORIZED`를 반환한다.

### 인도 시점 비문 확인(Handover-Time Dog Nose Verification)

```http
POST /api/adoption-posts/{post_id}/handover-verifications
Authorization: Bearer <JWT>
Content-Type: multipart/form-data
```

Form-data:

- `nose_image`: file, required

Purpose:

- stateless handover-time identity verification이다.
- 새로 촬영한 dog nose image가 `adoption_posts.dog_id`에 연결된 dog와 일치하는지 확인한다.
- persistent record를 만들거나 수정하지 않는다.
- handover image를 저장하지 않는다.
- dog를 생성하지 않는다.
- `dog_images` row를 생성하지 않는다.
- current MVP implementation에서는 `verification_logs` row를 생성하지 않는다.
- `adoption_posts.status` 또는 `dogs.status`를 변경하지 않는다.
- 자동으로 adoption completion을 수행하지 않는다.
- adoption completion은 기존 owner-only status update action으로 남는다.

Authorization:

- Bearer JWT authorization이 필요하다.
- current user는 active 상태여야 한다.
- missing, malformed, invalid, or expired JWT는 `UNAUTHORIZED`를 반환한다.
- token이 deleted 또는 missing user로 resolve되면 `USER_NOT_FOUND`를 반환한다.
- inactive current user는 HTTP `403`과 `USER_INACTIVE`를 반환한다.
- current MVP에는 reservation/applicant table이 없으므로 이 endpoint는 owner-only가 아니다. handover verification을 위한 authenticated user-facing safety check다.
- `ADOPTER` role 또는 reservation ownership rule을 도입하지 않는다.

Post status policy:

- Allowed statuses: `OPEN`, `RESERVED`.
- Rejected statuses: `DRAFT`, `COMPLETED`, `CLOSED`.
- rejected status는 HTTP `400`과 `POST_NOT_VERIFIABLE`을 반환한다.

Expected dog policy:

- `expected_dog_id`는 `adoption_posts.dog_id`다.
- `post_id`는 `adoption_posts.id`다.
- `expected_dog_id`는 `dogs.id`와 같고 Qdrant point id와도 같다.
- expected dog가 존재하지 않으면 `DOG_NOT_FOUND`를 반환한다.
- expected dog는 `REGISTERED`여야 한다.
- expected dog가 `REGISTERED`가 아니면 `DOG_NOT_VERIFIED`를 반환한다.

Default MVP `200` decision values:

- `MATCHED`
- `NOT_MATCHED`
- `NO_MATCH_CANDIDATE`

`AMBIGUOUS` enum value는 response compatibility를 위해 남아 있지만 direct expected-dog MVP runtime에서는 기본적으로 반환하지 않는다.

Response `200`, matched:

```json
{
  "post_id": 501,
  "expected_dog_id": "dog-uuid",
  "matched": true,
  "decision": "MATCHED",
  "similarity_score": 0.80631,
  "threshold": 0.70,
  "ambiguous_threshold": 0.70,
  "top_match_is_expected": true,
  "model": "dog-nose-identification2:s101_224",
  "dimension": 2048,
  "message": "분양글에 등록된 강아지와 일치합니다."
}
```

Response `200`, not matched:

```json
{
  "post_id": 501,
  "expected_dog_id": "dog-uuid",
  "matched": false,
  "decision": "NOT_MATCHED",
  "similarity_score": 0.69999,
  "threshold": 0.70,
  "ambiguous_threshold": 0.70,
  "top_match_is_expected": true,
  "model": "dog-nose-identification2:s101_224",
  "dimension": 2048,
  "message": "분양글에 등록된 강아지와 일치하지 않습니다. 거래 전 확인이 필요합니다."
}
```

Response `200`, no match candidate:

```json
{
  "post_id": 501,
  "expected_dog_id": "dog-uuid",
  "matched": false,
  "decision": "NO_MATCH_CANDIDATE",
  "similarity_score": null,
  "threshold": 0.70,
  "ambiguous_threshold": 0.70,
  "top_match_is_expected": false,
  "model": "dog-nose-identification2:s101_224",
  "dimension": 2048,
  "message": "일치 후보를 찾지 못했습니다. 비문 이미지를 다시 촬영해주세요."
}
```

Decision algorithm:

- `expected_dog_id = adoption_posts.dog_id`
- Qdrant point id는 `expected_dog_id`와 같은 `dog_id`다. `post_id`를 Qdrant id로 사용하지 않는다.
- Lookup path는 `post_id -> adoption_posts.dog_id -> Qdrant point id = dog_id`다.
- Python Embed는 handover image에서 `vector`, `dimension`, `model`만 반환한다.
- Qdrant가 cosine similarity `score`를 생성하고 Spring이 threshold policy를 적용한다.
- Spring은 handover image embedding vector로 Qdrant search를 수행하되, query filter를 `is_active=true`와 `dog_id=expected_dog_id`로 제한한다.
- 이 direct expected-dog query에는 `score_threshold`를 보내지 않는다. expected dog point가 존재하지만 `0.70` 미만인 경우에도 Spring이 score를 받아 `NOT_MATCHED`로 판단해야 하기 때문이다.
- default MVP handover policy uses Qdrant cosine score `0.70` as the same-dog threshold.
- `matched`가 canonical yes/no result이고 `decision`은 reason code다.

Expected dog candidate가 반환되지 않는 경우:

- `decision = NO_MATCH_CANDIDATE`
- `matched = false`
- `similarity_score = null`
- `top_match_is_expected = false`

Expected dog candidate가 반환되고 `candidate.dog_id == expected_dog_id`이며 `score >= 0.70`인 경우:

- `decision = MATCHED`
- `matched = true`
- `similarity_score = score`
- `top_match_is_expected = true`

Expected dog candidate가 반환되고 `candidate.dog_id == expected_dog_id`이며 `score < 0.70`인 경우:

- `decision = NOT_MATCHED`
- `matched = false`
- `similarity_score = score`
- `top_match_is_expected = true`

Defensive case에서 filtered query가 `candidate.dog_id != expected_dog_id`를 반환하는 경우:

- `decision = NOT_MATCHED`
- `matched = false`
- `similarity_score = score`
- `top_match_is_expected = false`
- 다른 dog id 또는 Qdrant payload details는 response에 노출하지 않는다.

`AMBIGUOUS`는 legacy/custom compatibility enum으로 남아 있지만 default MVP direct expected-dog handover runtime에서는 기대하지 않는다.

Privacy rules:

- public/user-facing response는 `nose_image_url`을 노출하지 않는다.
- handover verification response는 `top_matched_dog_id`를 노출하지 않는다.
- handover verification response는 다른 dog의 `dog_id`를 노출하지 않는다.
- handover verification response는 Qdrant payload details를 노출하지 않는다.
- handover verification response는 `author_user_id`를 노출하지 않는다.
- `expected_dog_id`는 adoption post workflow가 이미 dog를 참조하므로 노출할 수 있다.
- current response에는 diagnostic field인 `similarity_score`, `threshold`, `ambiguous_threshold`, `model`, `dimension`, `top_match_is_expected`가 포함된다. Flutter 화면 분기와 사용자 안내는 `matched`, `decision`, `message`를 우선 사용하고 model/dimension 같은 내부 진단값에 의존하지 않는다.

Config defaults:

- `match_threshold = 0.70`
- `ambiguous_threshold = 0.70`
- `top_k = 5`
- 이 값들은 runtime configuration이며 DB field가 아니다. Direct expected-dog Qdrant query itself uses `limit=1`.

Failure behavior:

- missing 또는 empty `nose_image`는 common error response와 `NOSE_IMAGE_REQUIRED`를 반환한다.
- invalid handover image bytes 또는 embed upstream rejection은 common error response와 `INVALID_NOSE_IMAGE`를 반환한다.
- unavailable embed service는 common error response와 `EMBED_SERVICE_UNAVAILABLE`을 반환한다.
- empty embedding output은 common error response와 `EMPTY_EMBEDDING`을 반환한다.
- embedding dimension mismatch는 common error response와 `EMBEDDING_DIMENSION_MISMATCH`를 반환한다.
- Qdrant search failure는 common error response와 `QDRANT_SEARCH_FAILED`를 반환한다.

### Adoption Post Error Codes

- `POST_NOT_FOUND`: adoption post가 존재하지 않는다.
- `POST_NOT_PUBLIC`: adoption post는 존재하지만 public visible 상태가 아니다.
- `POST_NOT_VERIFIABLE`: adoption post는 존재하지만 current status에서 handover verification을 수행할 수 없다.
- `POST_OWNER_MISMATCH`: current user가 post owner가 아니다.
- `DOG_NOT_FOUND`: adoption post가 참조하는 dog가 존재하지 않는다.
- `DOG_OWNER_MISMATCH`: current user가 dog owner가 아니다.
- `DOG_NOT_REGISTERED`: dog status가 `REGISTERED`가 아니어서 adoption post를 만들 수 없다.
- `DOG_NOT_VERIFIED`: dog의 latest verification log가 `PASSED`가 아니다.
- `DOG_ALREADY_HAS_ACTIVE_POST`: 같은 dog에 `DRAFT`, `OPEN`, `RESERVED` active post가 이미 존재한다.
- `USER_PROFILE_REQUIRED`: adoption post 생성 또는 publish 전에 non-blank `users.display_name`이 필요하다.
- `PROFILE_IMAGE_REQUIRED`: adoption post 생성 multipart request에 `profile_image`가 없거나 비어 있다.
- `INVALID_POST_STATUS`: 지원하지 않거나 malformed status value다.
- `INVALID_STATUS_TRANSITION`: 요청한 status transition이 허용되지 않는다.
- `INVALID_PAGE_REQUEST`: page 또는 size parameter가 supported range 밖이다.
- `NOSE_IMAGE_REQUIRED`: handover nose image multipart field가 없거나 비어 있다.
- `INVALID_NOSE_IMAGE`: handover nose image를 처리할 수 없다.
- `EMBED_SERVICE_UNAVAILABLE`: embedding service에 접근할 수 없거나 사용할 수 없다.
- `EMPTY_EMBEDDING`: embedding service가 vector를 반환하지 않았다.
- `EMBEDDING_DIMENSION_MISMATCH`: embedding dimension이 configured Qdrant vector dimension과 맞지 않는다.
- `QDRANT_SEARCH_FAILED`: Qdrant vector search가 실패했다.
- `UNAUTHORIZED`: JWT authorization이 missing, malformed, invalid, or expired 상태다.
- `USER_NOT_FOUND`: JWT subject가 existing user로 매핑되지 않는다.
- `USER_INACTIVE`: JWT subject가 inactive user로 매핑된다.

### Local Verification Examples

`<JWT>`, `<dog_id>`, `<post_id>`를 local test value로 바꿔 사용한다.

```bash
curl -X POST "http://localhost/api/auth/register" \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com","password":"password123","display_name":"초코 보호자"}'

curl -X POST "http://localhost/api/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com","password":"password123"}'

curl -H "Authorization: Bearer <JWT>" \
  "http://localhost/api/users/me"

curl -X PATCH "http://localhost/api/users/me/profile" \
  -H "Authorization: Bearer <JWT>" \
  -H "Content-Type: application/json" \
  -d '{"display_name":"초코보호자","contact_phone":"01012345678","region":"대구시 달서구"}'

curl -X POST "http://localhost/api/dogs/register" \
  -H "Authorization: Bearer <JWT>" \
  -F "name=초코" \
  -F "breed=말티즈" \
  -F "gender=MALE" \
  -F "nose_image=@/path/to/nose.jpg"

curl -X POST "http://localhost/api/adoption-posts" \
  -H "Authorization: Bearer <JWT>" \
  -F "dog_id=<dog_id>" \
  -F "title=말티즈 가족을 찾습니다" \
  -F "content=상세 내용..." \
  -F "status=OPEN" \
  -F "profile_image=@/path/to/profile.jpg"

curl -H "Authorization: Bearer <JWT>" \
  "http://localhost/api/dogs/me?page=0&size=20"

curl "http://localhost/api/dogs/<dog_id>"

curl -H "Authorization: Bearer <JWT>" \
  "http://localhost/api/dogs/<dog_id>"

curl "http://localhost/api/adoption-posts?status=OPEN&page=0&size=20"
curl "http://localhost/api/adoption-posts?status=RESERVED&page=0&size=20"
curl "http://localhost/api/adoption-posts?status=COMPLETED&page=0&size=20"

curl -H "Authorization: Bearer <JWT>" \
  "http://localhost/api/adoption-posts/me?page=0&size=20"

curl -X PATCH "http://localhost/api/adoption-posts/<post_id>/status" \
  -H "Authorization: Bearer <JWT>" \
  -H "Content-Type: application/json" \
  -d '{"status":"RESERVED"}'

curl -X PATCH "http://localhost/api/adoption-posts/<post_id>/status" \
  -H "Authorization: Bearer <JWT>" \
  -H "Content-Type: application/json" \
  -d '{"status":"COMPLETED"}'

curl -X POST "http://localhost/api/adoption-posts/<post_id>/handover-verifications" \
  -H "Authorization: Bearer <JWT>" \
  -F "nose_image=@/path/to/current-handover-nose.jpg"
```

## Firebase Chat API (Optional)

Firebase chat/push is an optional communication layer. It does not change the canonical 5-table MySQL schema and does not replace MySQL as the source of truth.

All endpoints in this section require a Spring Bearer token. When Firebase is disabled, authenticated requests return `503` with `FIREBASE_DISABLED`.

Firestore documents are realtime snapshots for chat UI/runtime state only. Spring Boot remains authoritative for room creation, message sending, FCM token registration, read marking, and post-status-based chat permission decisions. Flutter may read Firestore through realtime listeners, but must not write chat messages directly to Firestore.

Status policy:

- New rooms are created only for `OPEN` adoption posts.
- Existing room messages are allowed for `OPEN` and `RESERVED` posts.
- `COMPLETED` and `CLOSED` posts are read-only for chat.
- Spring Boot verifies MySQL `adoption_posts.status` before allowing message send.

### Firebase custom token

```http
POST /api/firebase/custom-token
Authorization: Bearer <JWT>
```

Success response:

```json
{
  "firebase_uid": "user_1",
  "firebase_custom_token": "<firebase-custom-token>"
}
```

### FCM token registration

```http
PUT /api/users/me/fcm-token
Authorization: Bearer <JWT>
Content-Type: application/json
```

Request body:

```json
{
  "fcm_token": "<fcm-token>",
  "platform": "WEB"
}
```

Success response:

```json
{
  "registered": true
}
```

`platform` is one of `ANDROID`, `IOS`, or `WEB`.

### Chat room create or return

```http
POST /api/chat/rooms
Authorization: Bearer <JWT>
Content-Type: application/json
```

Request body:

```json
{
  "post_id": 123
}
```

Success response:

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

### Chat room list

```http
GET /api/chat/rooms?page=0&size=20
Authorization: Bearer <JWT>
```

Success response:

```json
{
  "items": [
    {
      "room_id": "post_123_user_45",
      "post_id": 123,
      "post_title": "분양글 제목",
      "post_status": "OPEN",
      "other_user_display_name": "작성자",
      "last_message_preview": "안녕하세요",
      "last_message_at": "2026-05-13T00:00:00Z",
      "unread_count": 0
    }
  ],
  "page": 0,
  "size": 20,
  "total_count": 1
}
```

### Message send

```http
POST /api/chat/rooms/{room_id}/messages
Authorization: Bearer <JWT>
Content-Type: application/json
```

Request body:

```json
{
  "text": "hello",
  "client_message_id": "client-generated-id"
}
```

Success response:

```json
{
  "message_id": "<firestore-message-id>",
  "room_id": "post_123_user_45",
  "sender_uid": "user_45",
  "type": "TEXT",
  "text": "hello",
  "created_at": "2026-05-13T00:00:00Z"
}
```

### Mark room read

```http
PATCH /api/chat/rooms/{room_id}/read
Authorization: Bearer <JWT>
```

Success response:

```json
{
  "room_id": "post_123_user_45",
  "read": true
}
```

Disabled response example for all Firebase chat endpoints after Spring authentication succeeds:

```json
{
  "error_code": "FIREBASE_DISABLED",
  "message": "Firebase 연동이 비활성화되어 있습니다.",
  "details": {
    "timestamp": "2026-05-13T00:00:00Z"
  }
}
```

## JWT Principal Status

Dog registration과 adoption post ownership은 principal-only다. `POST /api/dogs/register`는 dog `owner_user_id`를 JWT principal에서 resolve하고, adoption post creation은 request `dog_id`의 owner와 JWT principal을 비교한다.

이 변경은 duplicate detection pipeline behavior를 `POST /api/dogs/register`에 집중시킨다. 신규 작성 flow에서는 등록된 `dog_id`가 adoption post 생성 권한의 연결 기준이다.

## Removed APIs and Concepts

old separate publisher/profile variant와 report/token extension 영역은 current MVP v2 contract에 포함하지 않는다. 아래 항목을 도입하지 않는다.

- `SHELTER` or `ADOPTER` roles
- `publisher_profiles`
- `shelter_profiles`
- `seller_profiles`
- `auth_logs`
- `reports`
- `refresh_tokens`
- reservation, payment, contract, or admin dashboard APIs

Firebase chat/push is allowed only as the optional communication layer documented above. It must not introduce MySQL chat tables or replace canonical domain authority.
