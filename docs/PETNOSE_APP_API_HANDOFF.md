# PetNose App API Handoff

이 문서는 새 앱 MVP flow에서 Flutter가 호출해야 하는 API 순서만 정리한다. 상세 error code와 전체 response shape는 `docs/PETNOSE_MVP_API_CONTRACT.md`를 기준으로 한다.

## Canonical App Flow

1. 회원가입: `POST /api/auth/register`
2. 로그인: `POST /api/auth/login`
3. 분양할 강아지 정보와 비문 촬영
4. 강아지 등록/비문 중복 검사: `POST /api/dogs/register`
5. `registration_allowed=false`이면 작성 차단
6. `registration_allowed=true`이면 반환된 `dog_id`를 작성 form state에 저장
7. 분양글 작성 화면에서 title/content/status 입력
8. 분양글 생성: `POST /api/adoption-posts`
9. 공개 분양글 생성 완료
10. 인도 시점 비문 확인: `POST /api/adoption-posts/{post_id}/handover-verifications`
11. `matched=true`이면 완료 버튼 활성화
12. 완료 처리: `PATCH /api/adoption-posts/{post_id}/status` with `COMPLETED`

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
- `nose_image`: required

App-facing response fields:

```json
{
  "dog_id": "uuid",
  "registration_allowed": true,
  "status": "REGISTERED",
  "verification_status": "VERIFIED",
  "embedding_status": "COMPLETED",
  "qdrant_point_id": "uuid",
  "message": "중복 의심 개체가 없어 등록이 완료되었습니다."
}
```

Duplicate suspected:

```json
{
  "dog_id": "uuid",
  "registration_allowed": false,
  "status": "DUPLICATE_SUSPECTED",
  "qdrant_point_id": null,
  "message": "기존 등록견과 동일 개체로 의심되어 등록이 제한됩니다."
}
```

Notes:

- 이 단계가 dog identity 등록, embedding 생성, Qdrant duplicate search, Qdrant upsert의 유일한 active entrypoint다.
- 정상 등록이면 Qdrant point id는 `dog_id`다.
- duplicate suspected이면 Qdrant upsert를 하지 않는다.

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

인도 시점 확인은 `post_id -> adoption_posts.dog_id -> Qdrant point id = dog_id` 순서로 expected dog vector를 찾는다. `post_id`는 게시글 식별자일 뿐 Qdrant id가 아니다.

## Auth Phone Format

`contact_phone`은 하이픈 없이 `01012341234` 형식으로 보낸다.
