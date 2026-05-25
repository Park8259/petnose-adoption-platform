# Dog Nose v2 Smoke Plan

## 목적

Dog nose v2 multi-reference registration과 expected-dog handover reference-set 비교가 runtime 설정과 active API contract 기준으로 검증 가능한지 확인한다.

이 문서는 실행 계획과 기대 evidence를 정리한다. 실제 secret, `.env`, Firebase service account JSON, JWT, 모델 weight 파일은 기록하지 않는다.

## 전제

- PR #62가 `next/dog-nose-v2`에 merge되어 있어야 한다.
- 개발/검증 데이터는 reset 가능하다고 가정한다.
- 기존 Qdrant v1 backfill은 수행하지 않는다.
- v2 smoke는 `dog_nose_embeddings_real_v2` clean start를 기준으로 한다.
- 실제 운영 데이터가 있는 환경에서는 아래 reset 절차를 실행하면 안 된다.
- 사용자는 close-up cropped dog nose image 3~5장을 준비한다. Backend는 crop/detection/alignment를 수행하지 않는다.

## Runtime 기준값

| 항목 | 값 |
|---|---|
| Qdrant collection | `dog_nose_embeddings_real_v2` |
| Vector dimension | `2048` |
| Distance | `Cosine` |
| Python model | `dog-nose-identification2` |
| Model dir | `/models/dog_nose_identification2` |
| Registration embed endpoint | `/embed-batch` |
| Handover embed endpoint | `/embed` |
| Qdrant candidate search threshold | `0.55` |
| Duplicate threshold | `0.75` |
| Review lower bound | `0.60` |
| Reference count | min `3`, max `5` |
| Reference consistency threshold | `0.60` |
| Handover match threshold | `0.75` |
| Handover ambiguous threshold | `0.60` |
| Max batch images | `5` |
| Max batch total bytes | `83886080` |
| Max upload file size | `20MB` |
| Max upload request size | `80MB` |
| Python embed response timeout | `30000ms` |

## Clean Reset / No-Backfill Note

기존 dog/Qdrant v1 데이터는 실험용 dev data로 보고 v2 전환 시 clean reset할 수 있다. Production-like 전환에서는 v1 -> v2 backfill 또는 재등록 전략이 필요하지만, 이번 MVP v2 branch에서는 backfill을 수행하지 않는다.

Dev reset 후보:

- MySQL `petnose` DB 또는 Docker volume
- Qdrant `dog_nose_embeddings_real_v1` / `dog_nose_embeddings_real_v2` collection
- `uploads/dogs`
- 필요 시 Firebase dev chat data

실제 운영 데이터가 있는 환경에서는 이 reset을 실행하지 않는다.

## 실행 준비

`infra/docker/.env.example`을 참고해 repository 밖 또는 local-only `.env`를 준비한다. Secret, service account JSON path, 모델 weight 파일은 git에 추가하지 않는다.

`infra/docker/.env.example`의 active 기본값은 dev/CI mock compose가 바로 뜨도록 `mock-v1`, `dog_nose_embeddings`, 128차원을 유지한다. Dog nose v2 real-model runtime 값은 `compose.real-model.yaml`이 강제하므로 실제 v2 smoke에서는 반드시 아래처럼 real-model override를 함께 포함한다.

```bash
docker compose --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.dev.yaml \
  -f infra/docker/compose.real-model.yaml \
  up -d --build
```

Config만 검증할 때는 secret 값을 문서에 쓰지 않고 아래 형태를 사용한다.

```bash
docker compose --env-file infra/docker/.env.example \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.dev.yaml \
  -f infra/docker/compose.real-model.yaml \
  config
```

## Health / Infra Checks

1. Spring health가 `UP`인지 확인한다.
2. Python Embed health를 확인하고 model/dimension이 real model 기준인지 확인한다.
3. Qdrant `dog_nose_embeddings_real_v2` collection이 생성되어 있는지 확인한다.
4. Qdrant collection vector size가 `2048`, distance가 `Cosine`인지 확인한다.
5. Spring dev qdrant config endpoint가 있다면 collection, dimension, score threshold가 v2 값인지 확인한다.

Expected:

- Python model contains `dog-nose-identification2`.
- Qdrant collection is `dog_nose_embeddings_real_v2`.
- Qdrant vector params are `size=2048`, `distance=Cosine`.

## API Smoke Flow

### 1. 회원가입 / 로그인

- `POST /api/auth/register`
- `POST /api/auth/login`
- JWT는 local shell variable에만 보관하고 문서/commit에 남기지 않는다.

Expected:

- 회원가입 `201` 또는 이미 존재하는 테스트 계정이면 명확한 expected error.
- 로그인 `200`, access token 발급.

### 2. Dog registration 정상 등록

`POST /api/dogs/register`에 `nose_images` 3장을 multipart로 보낸다.

Expected:

- HTTP `201`
- `registration_allowed=true`
- `status=REGISTERED`
- `verification_status=VERIFIED`
- `embedding_status=COMPLETED`
- `qdrant_point_id=null`
- `embedding_mode=MULTI_REFERENCE`
- `reference_count=3`
- `score_breakdown` 포함
- `nose_image_url`은 첫 reference 대표 URL
- `nose_image_urls`는 전체 reference image URL list
- Qdrant에는 `REFERENCE` 3개와 `CENTROID` 1개 point가 생김
- MySQL `dog_nose_references`에 4개 row가 생김

### 3. Same dog duplicate suspected

같은 dog 또는 매우 가까운 reference set으로 `POST /api/dogs/register`를 다시 호출한다.

Expected:

- HTTP `200`
- `registration_allowed=false`
- `status=DUPLICATE_SUSPECTED`
- `verification_status=DUPLICATE_SUSPECTED`
- `embedding_status=SKIPPED_DUPLICATE`
- `qdrant_point_id=null`
- `score_breakdown` 포함
- 새 Qdrant upsert 없음

### 4. REVIEW_REQUIRED 확인

Mock, fixture, 또는 threshold-controlled local data로 final score가 `0.60` 이상 `0.75` 미만인 registration을 확인한다.

Expected:

- HTTP `200`
- `registration_allowed=false`
- `status=REVIEW_REQUIRED`
- `verification_status=REVIEW_REQUIRED`
- `embedding_status=SKIPPED_REVIEW`
- `qdrant_point_id=null`
- Qdrant upsert 없음

### 5. Reference consistency failure

서로 다른 개체 이미지가 섞인 `nose_images` fixture로 consistency failure를 확인한다.

Expected:

- HTTP `400`
- `error_code=NOSE_REFERENCE_INCONSISTENT`
- file/DB/Qdrant side effect 없음

### 6. Adoption post 생성

정상 등록된 `dog_id`로 `POST /api/adoption-posts`를 호출한다.

Expected:

- HTTP `201`
- post가 `OPEN` 또는 요청 status로 생성됨
- public list/detail에는 `nose_image_url`이 노출되지 않음

### 7. Handover MATCHED

Expected dog와 같은 개체의 handover `nose_image`를 `POST /api/adoption-posts/{post_id}/handover-verifications`에 보낸다.

Expected:

- HTTP `200`
- `matched=true`
- `decision=MATCHED`
- `threshold=0.75`
- `ambiguous_threshold=0.60`
- `score_breakdown` 포함

### 8. Handover AMBIGUOUS

Mock, fixture, 또는 threshold-controlled local data로 decision score가 `0.60` 이상 `0.75` 미만인 handover를 확인한다.

Expected:

- HTTP `200`
- `matched=false`
- `decision=AMBIGUOUS`
- `score_breakdown` 포함

### 9. Handover NOT_MATCHED

Expected dog와 다른 dog의 handover `nose_image`를 제출한다.

Expected:

- HTTP `200`
- `matched=false`
- `decision=NOT_MATCHED`
- score가 `0.60` 미만이거나 expected reference set과 충분히 다름

### 10. Handover NO_MATCH_CANDIDATE

Expected dog reference set이 비어 있거나 Qdrant candidate가 없는 controlled state에서 확인한다.

Expected:

- HTTP `200`
- `matched=false`
- `decision=NO_MATCH_CANDIDATE`
- `similarity_score=null`

## Privacy Checks

아래 응답 필드가 public/user-facing response에 노출되지 않는지 확인한다.

- 다른 dog의 `dog_id`
- Qdrant point id
- Qdrant payload details
- `top_matched_dog_id`
- `author_user_id`
- public adoption post list/detail의 `nose_image_url`
- duplicate `top_match` 내부의 `nose_image_url`

## 실패 시 점검 항목

- `QDRANT_COLLECTION`이 `dog_nose_embeddings_real_v2`인지 확인한다.
- Qdrant vector dimension이 `2048`인지 확인한다.
- 기존 v1 collection 또는 stale Qdrant volume을 보고 있지 않은지 확인한다.
- Python Embed가 `dog-nose-identification2`로 실행 중인지 확인한다.
- 모델 directory mount가 read-only로 연결되어 있는지 확인한다.
- `nose_images` field name과 image count가 3~5 범위인지 확인한다.
- request 전체 크기가 `80MB`를 넘지 않는지 확인한다.
- reference image가 close-up cropped nose image인지 확인한다.
- Firebase 관련 설정을 dog nose smoke failure 원인으로 오해하지 않는다. Firebase는 optional communication layer다.
