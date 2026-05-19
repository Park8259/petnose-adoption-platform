# Storage and Vector Boundary

> 문서 성격: 보조 참고 문서(Task Reference)
>
> Qdrant, Python Embed, file storage, `dog_images.file_path` 경계 판단에서 읽는다.
> active canonical 문서와 충돌하면 active canonical 문서가 우선한다.
> API contract와 privacy rule은 `docs/PETNOSE_MVP_API_CONTRACT.md`를 우선한다.

## 역할 분리

| Layer | Role | Stored Data |
|---|---|---|
| MySQL | Source of truth | `users`, `dogs`, dog image metadata, verification history, adoption posts |
| Qdrant | Vector search index | dog nose embedding vector와 minimal search payload |
| File storage | Binary object storage | uploaded nose/profile image |

핵심 규칙:

- MySQL이 source of truth다.
- Qdrant는 account, dog lifecycle, adoption post, verification history의 authority가 아니다.
- Qdrant는 dog nose vector search index로만 사용한다.
- MySQL은 embedding vector 또는 image BLOB를 저장하지 않는다.
- file binary는 file storage에 저장하고, MySQL은 `dog_images.file_path`에 upload-root-relative path만 저장한다.

## MySQL Table Scope

active MVP table set은 정확히 아래 5개다.

1. `users`
2. `dogs`
3. `dog_images`
4. `verification_logs`
5. `adoption_posts`

`publisher_profiles`, `shelter_profiles`, `seller_profiles`, `auth_logs`, `reports`, `refresh_tokens`, `handover_verifications`는 active MVP table이 아니다.

## Qdrant Collection Contract

Real model target:

- collection: `dog_nose_embeddings_real_v1`
- vector size: `2048`
- distance: `Cosine`
- point id: `dogs.id`

Qdrant point id는 MySQL column으로 저장하지 않는다. API response에서는 아래처럼 계산한다.

- normal dog registration: `qdrant_point_id = dog_id`
- duplicate suspected dog registration: `qdrant_point_id = null`
- adoption post creation: no Qdrant point is created or updated

## Image Storage Policy

- uploaded image bytes는 MySQL 밖에 저장한다.
- `dog_images.file_path`는 upload root 아래 상대 경로를 저장한다.
- public file URL은 `/files/{relative_path}` 형태를 사용한다.
- API display용 authoritative image URL은 MySQL `dog_images.file_path`에서 계산한다.
- dog registration `nose_image`는 `dog_images.image_type=NOSE` row로 저장된다.
- adoption post creation은 nose image/vector upload endpoint가 아니다. 단, required `profile_image`는 분양글 대표 이미지로 저장하고 새 `dog_images.image_type=PROFILE` row를 만든다.
- Qdrant payload에 internal search metadata가 있더라도 public/user-facing response에 Qdrant payload details를 노출하지 않는다.

## Verification Modeling Policy

`verification_logs`는 dog-centered 비문 검증 결과 이력의 source of truth다.

`dogs.status`는 lifecycle/service state만 유지한다. `POST /api/dogs/register`의 `DUPLICATE_SUSPECTED`는 dog status와 verification log result에 남으며 Qdrant upsert는 생략된다.

detailed verification data는 `verification_logs`에 속한다.

- result
- similarity score
- duplicate candidate dog id
- model
- dimension
- failure reason

API response field `verification_status`와 `embedding_status`는 latest `verification_logs.result`에서 계산한다.

## Qdrant Payload Contract

Qdrant payload는 vector search를 보조하는 최소 metadata로 제한한다. payload는 public response contract가 아니다.

```json
{
  "dog_id": "uuid-string",
  "user_id": 101,
  "nose_image_path": "dogs/{uuid}/nose/{yyyyMMdd_HHmmss}_{filename}.jpg",
  "registered_at": "2026-05-08T00:00:00Z",
  "is_active": true,
  "breed": "optional"
}
```

Qdrant payload에 personal contact information, credential, image byte, base64 image data, long description을 저장하지 않는다.

handover verification response는 `nose_image_url`, 다른 dog의 `dog_id`, Qdrant payload details, `author_user_id`를 노출하지 않는다.
