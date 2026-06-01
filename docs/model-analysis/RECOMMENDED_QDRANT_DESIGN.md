# Recommended Qdrant Design

작성일: 2026-05-24 KST

## 목표

1. 3-5장 multi-reference 등록을 지원한다.
2. cropped nose input에서 확인된 score 분포를 활용한다.
3. 낮은 similarity가 전처리/촬영 문제인지 추적 가능하게 한다.
4. Qdrant search score를 dog-level decision score로 안정적으로 집계한다.

## 결론

Qdrant에는 centroid만 저장하지 말고, 개별 reference embedding과 centroid embedding을 함께 저장한다.

- 개별 reference는 pose/lighting별 best match를 잡는 데 필요하다.
- centroid는 dog-level 안정성과 빠른 coarse scoring에 유용하다.
- 실험상 positive mean은 `max reference=0.9061`, `centroid=0.8990`, `centroid+max=0.9025`였다.
- centroid만 저장하면 어떤 reference가 match에 기여했는지 설명하기 어렵고, 특정 각도/조명에 강한 reference를 잃는다.

## Collection

권장 collection:

- `dog_nose_embeddings_real_v2`
- vector size: `2048`
- distance: `Cosine`

현재 real v1:

- `dog_nose_embeddings_real_v1`
- size 2048
- distance Cosine
- point당 dog 1개 centroid/single vector처럼 사용 중

v2에서는 dog 1마리당 point 여러 개를 둔다.

## Point 구조

Qdrant point id는 UUID를 사용한다. `dog_id:ref:1` 같은 arbitrary string은 Qdrant point id 제약에 걸릴 수 있으므로 피한다.

### Reference point

```json
{
  "id": "reference_embedding_uuid",
  "vector": [2048 floats],
  "payload": {
    "dog_id": "dog_uuid",
    "owner_user_id": 1,
    "embedding_kind": "reference",
    "reference_index": 1,
    "image_path": "dogs/{dog_id}/nose/{file}.jpg",
    "image_sha256": "...",
    "model": "dog-nose-identification2:s101_224",
    "dimension": 2048,
    "preprocess_version": "rgb_resize224_bicubic_imagenet_l2_v1",
    "capture_quality": {
      "source": "manual_upload",
      "is_cropped_nose": true,
      "quality_score": null
    },
    "is_active": true,
    "created_at": "2026-05-24T00:00:00Z"
  }
}
```

### Centroid point

```json
{
  "id": "centroid_embedding_uuid",
  "vector": [2048 floats],
  "payload": {
    "dog_id": "dog_uuid",
    "owner_user_id": 1,
    "embedding_kind": "centroid",
    "reference_count": 3,
    "reference_embedding_ids": ["uuid1", "uuid2", "uuid3"],
    "model": "dog-nose-identification2:s101_224",
    "dimension": 2048,
    "preprocess_version": "rgb_resize224_bicubic_imagenet_l2_v1",
    "is_active": true,
    "created_at": "2026-05-24T00:00:00Z"
  }
}
```

Centroid vector는 reference vectors의 mean을 계산한 뒤 다시 L2 normalize한다.

## 등록 흐름

1. 사용자가 nose reference 3-5장을 제출한다.
2. 각 이미지를 품질 검사한다.
3. 각 이미지를 close-up nose crop으로 표준화한다.
4. Python embedder가 각 reference embedding을 생성한다.
5. 등록 전 중복 검색은 reference embedding 각각 또는 centroid query로 수행한다.
6. 후보 dog_id별로 score를 집계한다.
7. duplicate/manual/not match 결정을 한다.
8. 등록이 허용되면 reference points와 centroid point를 upsert한다.
9. duplicate/manual이면 upsert하지 않고 pending/review 상태로 둔다.

현재 코드처럼 duplicate suspected 시 Qdrant upsert를 생략하는 정책은 유지한다.

## 검색/집계 방식

Qdrant search는 reference point를 대상으로 먼저 수행한다.

Search filter:

```json
{
  "must": [
    {"key": "is_active", "match": {"value": true}},
    {"key": "embedding_kind", "match": {"value": "reference"}}
  ]
}
```

권장 search parameter:

- `limit`: 50-100
- `score_threshold`: 0.55 또는 0.60
- `with_payload`: true

Dog-level aggregation:

| score | 계산 |
|---|---|
| `single_reference_score` | 가장 오래된/대표 reference 1장과 query cosine |
| `max_reference_score` | 같은 dog_id 후보 reference 중 max |
| `top2_average_score` | 상위 2개 reference score 평균 |
| `centroid_score` | query와 centroid point cosine |
| `final_score` | 초기에는 `max_reference_score` 권장, 보조로 `centroid_score` 기록 |

운영 rule 초안:

- `final_score = max_reference_score`
- tie-break 또는 review 화면에는 `centroid_score`, `top2_average_score`, best reference image를 함께 표시한다.
- 같은 dog의 reference가 여러 장 반환되면 hit_count도 기록한다.

## Threshold 초안

cropped nose 샘플 50마리/250장 실험 기준:

- 동일 dog `max_reference_score` min: `0.7687`
- 다른 dog `max_reference_score` max: `0.5836`

초안:

| decision | final score |
|---|---:|
| AUTO MATCH / DUPLICATE_SUSPECTED | `>= 0.75` |
| MANUAL_REVIEW | `0.60 <= score < 0.75` |
| NOT_MATCH / REGISTER_ALLOWED | `< 0.60` |

Qdrant pre-filter는 final threshold보다 낮아야 한다. `score_threshold=0.60`으로 두면 manual-review 후보를 Spring이 볼 수 있다. 더 넓게 보려면 `0.55`가 안전하다.

현재 단일 allow/deny UX만 있다면 `NOSE_DUPLICATE_THRESHOLD=0.70`은 cropped sample에서 동작한다. 그러나 낮은 similarity 문제를 threshold만 낮춰 해결하는 것은 위험하다. 먼저 crop/detection/quality gate와 multi-reference를 넣어야 한다.

## DB 보조 구조

Qdrant payload만으로 운영 metadata를 모두 관리하지 말고 RDB에도 reference row를 둔다.

권장 table 초안:

```text
dog_nose_references
- id UUID primary key
- dog_id UUID not null
- dog_image_id bigint not null
- qdrant_point_id UUID not null
- reference_index int not null
- embedding_kind enum(reference, centroid)
- model varchar
- dimension int
- preprocess_version varchar
- quality_status enum(accepted, rejected, needs_review)
- quality_score decimal nullable
- is_active boolean
- created_at timestamp
```

Centroid를 별도 row로 저장하거나 `dog_nose_embedding_sets` table을 둬도 된다. 중요한 것은 Qdrant point id와 DB row를 1:1로 추적할 수 있어야 한다는 점이다.

## 전처리/촬영 요구사항

모델은 close-up cropped nose에서 잘 분리된다. 운영 등록 UX는 다음을 강제해야 한다.

- 코가 frame 대부분을 차지해야 한다.
- 코 끝과 양쪽 콧구멍이 잘리지 않아야 한다.
- 초점 흐림이 없어야 한다.
- 강한 반사광/그림자가 없어야 한다.
- 정면 1장, 약한 좌/우 각도 1장씩 최소 3장.
- 가능하면 5장: 정면 2장, 좌/우 각도 각 1장, 다른 조명 1장.

추가 데이터 권장량:

- 초기 calibration: 최소 100마리, dog당 5장, 총 500장.
- 운영 threshold 확정: 최소 300-500마리, dog당 5장, 총 1,500-2,500장.
- 반드시 실제 앱 촬영 조건으로 수집한다. 모델 repo의 cropped training image만으로 production threshold를 확정하면 안 된다.

## 구현 순서

1. Python embedder 앞단에 nose crop/alignment 또는 앱 촬영 crop UX를 추가한다.
2. 등록 API를 3-5장 multipart로 확장한다.
3. Qdrant v2 collection을 만든다.
4. reference point 다건 upsert와 centroid point upsert를 구현한다.
5. search 결과를 dog_id로 group-by하는 Spring aggregation layer를 추가한다.
6. `AUTO_MATCH`, `MANUAL_REVIEW`, `NOT_MATCH` 상태를 응답/DB에 반영한다.
7. 앱 촬영 데이터로 threshold를 재보정한다.
