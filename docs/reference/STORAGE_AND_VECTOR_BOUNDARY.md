# Storage and Vector Boundary

> 문서 성격: 보조 참고 문서(Task Reference)
>
> Qdrant, Python Embed, file storage, `dog_images.file_path` 경계 판단에서 읽는다.
> active canonical 문서와 충돌하면 active canonical 문서가 우선한다.
> API contract와 privacy rule은 `docs/PETNOSE_MVP_API_CONTRACT.md`를 우선한다.

## 역할 분리

| Layer | Role | Stored Data |
|---|---|---|
| MySQL | Source of truth | 7 core/relationship tables plus `password_reset_tokens` auth support |
| Qdrant | Vector search index | dog nose v2 `REFERENCE`/`CENTROID` vectors and minimal search payload |
| File storage | Binary object storage | uploaded nose/profile image |

핵심 규칙:

- MySQL이 source of truth다.
- Qdrant는 account, dog lifecycle, adoption post, verification history의 authority가 아니다.
- Qdrant는 dog nose vector search index로만 사용한다.
- MySQL `dog_nose_references`가 Qdrant point id와 point metadata의 source of truth다.
- MySQL은 embedding vector 또는 image BLOB를 저장하지 않는다.
- file binary는 file storage에 저장하고, MySQL은 `dog_images.file_path`에 upload-root-relative path만 저장한다.

## MySQL Table Scope

develop 제출 기준 MySQL table은 총 8개다.

Core domain/relationship table은 아래 7개다.

1. `users`
2. `dogs`
3. `dog_images`
4. `dog_nose_references`
5. `verification_logs`
6. `adoption_posts`
7. `adoption_post_likes`

Auth support table은 `password_reset_tokens` 1개다. 이 table은 domain table이 아니며 reset token 원문 대신 SHA-256 hash만 저장한다.

`publisher_profiles`, `shelter_profiles`, `seller_profiles`, `auth_logs`, `reports`, `refresh_tokens`, `handover_verifications`, `post_adoption_verifications`는 active MVP table이 아니다.

## Qdrant Collection Contract

Real model target:

- collection: `dog_nose_embeddings_real_v2`
- vector size: `2048`
- distance: `Cosine`
- point id: UUID, not `dogs.id`

Qdrant point id는 `dogs.id`와 같지 않다. Dog nose v2의 point id와 reference metadata는 MySQL `dog_nose_references`가 추적한다. API response에서는 아래 기준을 유지한다.

- normal dog registration: `qdrant_point_id = null`
- duplicate suspected dog registration: `qdrant_point_id = null`
- adoption post creation: no Qdrant point is created or updated

정상 등록(`PASSED`)에서만 Qdrant `REFERENCE` point 5개와 `CENTROID` point 1개를 upsert한다. `DUPLICATE_SUSPECTED`와 reference quality failure(`RETAKE_ONE`, `RETAKE_ALL`)는 Qdrant upsert를 수행하지 않는다.

## Qdrant Reconciliation Policy

Qdrant/MySQL drift 점검과 복구 절차는 [QDRANT_RECONCILIATION_RUNBOOK.md](QDRANT_RECONCILIATION_RUNBOOK.md)를 따른다.

운영 기준:

- MySQL `dog_nose_references`가 Qdrant point metadata의 source of truth다.
- Qdrant vector 자체는 MySQL에 저장하지 않는다.
- 따라서 MySQL에는 active `dog_nose_references` row가 있지만 Qdrant point가 사라진 `missing_in_qdrant` 상태는 script가 자동 재생성할 수 없다.
- MySQL source of truth에 없는 `orphan_in_qdrant` point는 dry-run evidence를 확인한 뒤 삭제할 수 있다.
- Qdrant payload mismatch는 자동 patch하지 않는다. evidence chain을 보존하려면 삭제 후 재등록/재생성을 우선 검토한다.

## Image Storage Policy

- uploaded image bytes는 MySQL 밖에 저장한다.
- `dog_images.file_path`는 upload root 아래 상대 경로를 저장한다.
- public file URL은 `/files/{relative_path}` 형태를 사용한다.
- API display용 authoritative image URL은 MySQL `dog_images.file_path`에서 계산한다.
- dog registration `nose_images` 정확히 5장은 `dog_images.image_type=NOSE` row 5개로 저장된다.
- registration 단건 `nose_image` field는 active v2 contract가 아니며 handover verification에서만 사용한다.
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
  "embedding_kind": "REFERENCE",
  "reference_index": 1,
  "model": "dog-nose-identification2:s101_224",
  "dimension": 2048,
  "preprocess_version": "v1",
  "is_active": true
}
```

Qdrant payload에 personal contact information, credential, image byte, base64 image data, long description을 저장하지 않는다.

handover verification response는 `nose_image_url`, 다른 dog의 `dog_id`, Qdrant payload details, `author_user_id`를 노출하지 않는다.
