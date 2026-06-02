# PetNose App API Handoff

이 문서는 새 앱 MVP flow에서 Flutter가 호출해야 하는 API 순서만 정리한다. 상세 error code와 전체 response shape는 `docs/PETNOSE_MVP_API_CONTRACT.md`를 기준으로 한다.

## Canonical App Flow

1. 회원가입: `POST /api/auth/register`
2. 로그인: `POST /api/auth/login`
3. 분양할 강아지 정보와 비문 기준 사진 5장 촬영
4. 강아지 등록/비문 중복 검사: `POST /api/dogs/register`
5. `registration_allowed=false`이면 작성 차단
6. `registration_allowed=true`이면 반환된 `dog_id`를 작성 form state에 저장
7. 분양글 작성 화면에서 title/content/status 입력
8. 분양글 생성: `POST /api/adoption-posts`
9. 공개 분양글 생성 완료
10. 인도 시점 비문 확인: `POST /api/adoption-posts/{post_id}/handover-verifications`
11. `matched=true`이면 완료 버튼 활성화
12. 완료 처리: `PATCH /api/adoption-posts/{post_id}/status` with `COMPLETED` and `adopter_user_id`

## App-Requested Follow-up Flow

이 섹션은 앱팀 추가 요청사항을 연결할 순서다. 상세 endpoint와 정책은 `PETNOSE_MVP_API_CONTRACT.md`를 기준으로 한다.

1. 회원가입 화면에서 profile image를 함께 보내려면 `POST /api/auth/register`를 `multipart/form-data`로 호출하고 `profile_image` file part를 포함한다. 기존 JSON signup도 계속 지원한다.
2. 회원가입/로그인/`GET /api/users/me`의 user payload에는 nullable `profile_image_url`이 포함될 수 있다. 앱은 이 값을 null-safe로 렌더링한다.
3. 마이페이지 profile image 변경은 `PATCH /api/users/me/profile-image`를 `multipart/form-data`로 호출한다.
4. 기존 `display_name`/`contact_phone`/`region` 변경은 `PATCH /api/users/me/profile`을 계속 사용한다.
5. 마이페이지 비밀번호 변경은 `PATCH /api/users/me/password`를 호출한다. request에는 `current_password`와 `new_password`를 보낸다.
6. 비밀번호 찾기는 비밀번호 조회가 아니라 reset token 기반 요청/확정 흐름으로 연결한다.
7. 비밀번호 재설정 요청 화면은 `POST /api/auth/password-reset/request`를 호출하고 `requested=true`를 받으면 "재설정 안내가 전송되었습니다" 계열의 동일 메시지를 표시한다. 앱은 email 존재 여부를 구분하지 않는다.
8. 실제 email/SMS provider는 아직 연결되지 않았다. shared dev에서는 `AUTH_PASSWORD_RESET_EXPOSE_TOKEN_IN_RESPONSE=true`일 때 active user email에 한해 임시 `reset_token`을 받아 confirm flow를 테스트할 수 있다.
9. 새 비밀번호 설정 화면은 `POST /api/auth/password-reset/confirm`에 `reset_token`과 `new_password`를 보내고 `reset=true`를 받으면 로그인 화면으로 보낸다.
10. 앱은 비밀번호나 `password_hash`를 조회하려고 하지 않는다.
11. 분양글 카드와 상세 화면은 response의 `liked` field를 사용하고, 좋아요 추가 `PUT /api/adoption-posts/{post_id}/like`, 좋아요 취소 `DELETE /api/adoption-posts/{post_id}/like`, 내 좋아요 목록 `GET /api/adoption-posts/liked/me`를 사용한다.
12. 앱은 `users.liked` map을 기대하지 않는다. 서버는 `adoption_post_likes` 관계 테이블 기준으로 좋아요 상태를 계산한다.
13. 분양 완료 버튼을 누를 때 앱은 `adopter_user_id`를 함께 보낸다.
14. 마이페이지 "내가 입양한 강아지" 목록은 `GET /api/dogs/adopted/me`로 조회한다.
15. 입양 후 1주/3개월/6개월 비문 인증, 사후 인증 스케줄/알림, 완료 후 자동 비문 재검증은 이번 follow-up 범위가 아니다.

Storage distinction:

- 사용자 `profile_image`는 `users.profile_image_*` fields와 user profile file storage에 저장한다. 앱은 response의 최신 `profile_image_url`만 사용하고 null-safe 처리한다.
- `PATCH /api/users/me/profile-image`는 이전 이미지 파일을 즉시 삭제하지 않는다. orphan cleanup은 운영 hardening scope다.
- 분양글 대표 `profile_image`는 기존처럼 `dog_images.image_type=PROFILE`로 저장한다.
- `dogs.owner_user_id`는 등록자/작성자 ownership으로 유지하고, 입양자는 `adoption_posts.adopter_user_id`로 추적한다.

## Adoption Completion

완료 처리:

- 앱은 `PATCH /api/adoption-posts/{post_id}/status` request에 `status=COMPLETED`와 `adopter_user_id`를 함께 보낸다.
- Firebase chat room 화면에서는 선택한 문의자의 `inquirer_user_id`를 `adopter_user_id`로 전달할 수 있다.
- 서버는 이번 PR에서 chat room participant 여부까지 검증하지 않는다.
- 완료 성공 후 `dogs.status`는 `ADOPTED`가 된다.
- `dogs.owner_user_id`는 작성자/등록자 기준으로 유지된다.
- 내가 입양한 강아지 목록은 `GET /api/dogs/adopted/me`에서 제공한다.
- 입양 후 1주/3개월/6개월 인증은 이번 범위가 아니다.

## My Adopted Dogs

마이페이지 "내가 입양한 강아지" 화면:

- `GET /api/dogs/adopted/me?page=0&size=20`를 호출한다.
- Authorization Bearer token이 필요하다.
- 분양 완료 후 작성자(author)가 아닌 입양자(adopter) 계정으로 조회할 수 있다.
- 서버는 `adoption_posts.status=COMPLETED` 및 `adoption_posts.adopter_user_id=current_user_id` 기준으로 조회한다.
- 앱은 `dogs.owner_user_id` 기준 adopted list를 기대하지 않는다.
- 앱은 response의 `post_id`, `dog_id`, `profile_image_url`, `adopted_at`, `status`를 사용한다.
- response에는 `nose_image_url`, `author_contact_phone`, `author_user_id`, `adopter_user_id`, `embedding_status`가 포함되지 않는다.
- 입양 후 1주/3개월/6개월 비문 인증 UI/API는 이번 범위가 아니다.

## Adoption Post Likes

분양글 목록/상세 화면:

- `GET /api/adoption-posts`와 `GET /api/adoption-posts/{post_id}`는 Authorization header가 없으면 `liked=false`를 반환한다.
- Authorization header가 있으면 서버가 current user 기준 `liked`를 계산한다.
- Authorization header가 invalid/malformed이면 `UNAUTHORIZED`를 반환한다.
- public list/detail은 계속 `nose_image_url`을 노출하지 않는다.

좋아요 액션:

- 추가: `PUT /api/adoption-posts/{post_id}/like`
- 취소: `DELETE /api/adoption-posts/{post_id}/like`
- 둘 다 Authorization이 필요하고 같은 요청을 반복해도 같은 최종 상태를 반환한다.
- 좋아요 추가 대상은 `OPEN`, `RESERVED`, `COMPLETED` public visible post다.
- 좋아요 취소는 post가 존재하면 `DRAFT`/`CLOSED`가 되었더라도 허용한다.

마이페이지 좋아요 목록:

- `GET /api/adoption-posts/liked/me?page=0&size=20`
- `items[].liked`는 항상 `true`이며 `liked_at`은 좋아요한 시각이다.
- 목록은 `OPEN`, `RESERVED`, `COMPLETED` post만 반환하고 `DRAFT`/`CLOSED`는 숨긴다.
- 앱은 이 목록에서도 `nose_image_url`을 기대하지 않는다.

## Firebase Chat Connection Note

`FIREBASE_DISABLED`가 나오면 앱 요청은 Spring 서버에 도달했고 Spring 인증도 통과한 것이다. 이 경우 앱 코드나 API route 누락보다 서버 Firebase runtime 설정을 먼저 확인한다.

앱은 Firestore에 chat room, message, device token을 직접 write하지 않는다. 앱 write flow는 Spring API를 기준으로 한다.

- `POST /api/firebase/custom-token`로 Firebase custom token을 발급받고 Firebase sign-in에 사용한다.
- `POST /api/chat/rooms`로 채팅방을 생성하거나 기존 방을 받는다.
- `POST /api/chat/rooms/{room_id}/messages`로 메시지를 보낸다.
- `PATCH /api/chat/rooms/{room_id}/read`로 읽음 상태를 갱신한다.
- `PUT /api/users/me/fcm-token`로 FCM token을 등록한다.

Firestore realtime listener는 chat room/message read 용도로만 사용한다. 공유 dev 환경에서는 앱팀이 service account JSON을 받지 않는다.

## Dog Registration

```http
POST /api/dogs/register
Authorization: Bearer <JWT>
Content-Type: multipart/form-data
```

Form-data:

- `name`: required
- `breed`: required
- `gender`: required, `MALE`, `FEMALE`, or `UNKNOWN`
- `birth_date`: optional, `YYYY-MM-DD`
- `description`: optional
- `nose_images`: required file[], exactly 5. 같은 multipart field name으로 5개 file part를 보낸다.

App-facing response fields:

```json
{
  "dog_id": "uuid",
  "registration_allowed": true,
  "status": "REGISTERED",
  "verification_status": "VERIFIED",
  "embedding_status": "COMPLETED",
  "qdrant_point_id": null,
  "embedding_mode": "MULTI_REFERENCE",
  "reference_count": 5,
  "score_breakdown": {
    "final_score": 0.41,
    "max_reference_score": 0.43,
    "centroid_score": 0.39,
    "reference_consistency_score": 0.82
  },
  "message": "중복 의심 개체가 없어 등록이 완료되었습니다."
}
```

Duplicate suspected:

```json
{
  "dog_id": "uuid",
  "registration_allowed": false,
  "status": "DUPLICATE_SUSPECTED",
  "verification_status": "DUPLICATE_SUSPECTED",
  "embedding_status": "SKIPPED_DUPLICATE",
  "qdrant_point_id": null,
  "score_breakdown": {
    "final_score": 0.99782,
    "max_reference_score": 0.99812,
    "centroid_score": 0.99687
  },
  "message": "기존 등록견과 동일 개체로 의심되어 등록이 제한됩니다."
}
```

Notes:

- 이 단계가 dog identity 등록, embedding 생성, Qdrant duplicate search, Qdrant upsert의 유일한 active entrypoint다.
- `nose_image` 단건 field는 registration v2 active contract가 아니다. 단건 `nose_image`는 handover verification에서만 사용한다.
- Python Embed `/embed-batch`는 내부 endpoint로 1~5장을 받을 수 있지만, backend dog registration API는 정확히 5장만 허용한다.
- Backend는 등록 전에 5장 reference 간 quality diagnostics를 수행한다. verdict는 `ACCEPTED`, `WARN_ACCEPTED`, `RETAKE_ONE`, `RETAKE_ALL`이다.
- `RETAKE_ONE`/`RETAKE_ALL`은 새로 올린 5장 자체의 reference quality 실패이며 HTTP `400` + `NOSE_REFERENCE_INCONSISTENT`로 반환한다.
- 정상 등록이면 `dog_images=5`, `dog_nose_references=6`, Qdrant points=6이다. Qdrant points는 `REFERENCE` 5개와 `CENTROID` 1개다.
- API response의 `qdrant_point_id`는 dog nose v2에서 `null`이다.
- Duplicate decision은 `final_score = max(max_reference_score, centroid_score)` 기준 binary policy다.
- `final_score >= 0.65`이면 `DUPLICATE_SUSPECTED`, `final_score < 0.65`이면 `REGISTERED`다.
- `REVIEW_REQUIRED`는 active normal duplicate decision에서 사용하지 않는다.
- Qdrant search pre-filter `0.55`는 내부 후보 검색 기준이며 review band가 아니다.
- duplicate suspected이면 reference/Qdrant upsert를 하지 않는다.

## Adoption Post Create

```http
POST /api/adoption-posts
Authorization: Bearer <JWT>
Content-Type: multipart/form-data
```

Form fields:

- `dog_id`: required. `POST /api/dogs/register` 성공 응답의 `dog_id`.
- `title`: required.
- `content`: required.
- `status`: optional, `DRAFT` 또는 `OPEN`. 생략 시 `DRAFT`.
- `profile_image`: required file. 분양글 대표 이미지.

Notes:

- request에 `nose_image`를 보내지 않는다.
- 분양글 생성 시 dog, NOSE dog image, verification log를 새로 만들지 않는다.
- `profile_image`는 `dog_images.image_type=PROFILE`로 저장한다.
- 분양글 생성 시 embed service 호출이나 Qdrant upsert를 수행하지 않는다.
- `dog_id`는 current user 소유의 `REGISTERED` dog여야 한다.
- dog의 latest verification result는 `PASSED`여야 한다.
- 같은 dog에 active post가 이미 있으면 생성할 수 없다.

## Handover Verification

인도 시점 확인은 `post_id -> adoption_posts.dog_id`로 expected dog를 찾고, 해당 dog의 active `REFERENCE`/`CENTROID` Qdrant points와 새 촬영 비문을 비교한다. `post_id`는 게시글 식별자일 뿐 Qdrant id가 아니다.

Form-data:

- `nose_image`: required single file. Handover는 registration과 다르게 5장을 받지 않는다.

Decision notes:

- Handover는 expected dog의 `REFERENCE` 5개와 `CENTROID` 1개를 query image 1장과 비교한다.
- `final_score = max(max_reference_score, centroid_score)`.
- `final_score >= 0.65`이면 `MATCHED`, `final_score < 0.65`이면 `NOT_MATCHED`다.
- `AMBIGUOUS`는 enum compatibility/historical evidence로 남아 있지만 active normal handover decision에서는 사용하지 않는다.
- `NO_MATCH_CANDIDATE`는 후보 없음 예외 상태로 유지한다.

## Auth Phone Format

`contact_phone`은 하이픈 없이 `01012341234` 형식으로 보낸다.
