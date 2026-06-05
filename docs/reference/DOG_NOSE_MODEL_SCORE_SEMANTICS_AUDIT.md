# Dog Nose Model Score Semantics Audit

## 문서 성격

- local model repo + PetNose Spring/Qdrant scoring pipeline 감사
- 구현 변경 없음
- threshold 변경 없음
- 다음 threshold 변경 여부 판단을 위한 자료

## 검토 대상

- PetNose repository path: `C:\Dev\_petnose_fix`
- model repository path: `C:\Dev\dog_nose_identification2`
- private host detail, raw checkpoint host path, raw local dataset image path, 민감한 값은 기록하지 않는다.

PetNose에서 검토한 문서:

- `docs/README.md`
- `docs/PROJECT_KNOWLEDGE_INDEX.md`
- `docs/PETNOSE_MVP_API_CONTRACT.md`
- `docs/PETNOSE_MVP_FINAL_PROJECT_SPEC.md`
- `docs/reference/MVP_BACKEND_FLOW_HANDOFF.md`
- `docs/reference/STORAGE_AND_VECTOR_BOUNDARY.md`
- `docs/reference/SPRING_PYTHON_EMBED_CONTRACT.md`
- `docs/ops-evidence/mvp-real-model-e2e-smoke-log.md`

PetNose에서 검토한 코드/설정:

- `backend/src/main/java/com/petnose/api/client/EmbedClient.java`
- `backend/src/main/java/com/petnose/api/service/DogRegistrationService.java`
- `backend/src/main/java/com/petnose/api/client/QdrantDogVectorClient.java`
- `backend/src/main/java/com/petnose/api/service/NoseVerificationPolicy.java`
- `backend/src/main/java/com/petnose/api/config/QdrantInitializer.java`
- `backend/src/main/resources/application.yml`
- `infra/docker/compose.yaml`
- `infra/docker/.env.example`
- `infra/docker/compose.real-model.yaml`
- `python-embed/app/main.py`
- `python-embed/app/embedding/dog_nose_identification2_embedder.py`

model repository에서 검토한 대상:

- `dog_nose_inference_colab.ipynb`
- `logs/fusion_submit/submit.csv`
- local paper PDF text에서 score/metric 관련 부분
- `logs/*` artifact inventory. binary checkpoint와 `.npy` feature content는 감사 대상 inventory로만 확인했고 문서에 private host path를 남기지 않는다.

실행한 주요 명령:

- required git setup: `git status`, `git fetch origin`, `git checkout develop`, `git pull --ff-only origin develop`, `git branch --show-current`, `git status`, `git checkout -b chore/dog-nose-model-score-semantics-audit`
- required docs/code read: `Get-Content ... -Encoding UTF8`
- PetNose score/config search: `rg "QDRANT_SEARCH_SCORE_THRESHOLD|NOSE_DUPLICATE_THRESHOLD|search-score-threshold|duplicate-threshold|score_threshold|duplicateThreshold|maxScore|score >=|score <=" ...`
- model repo existence check: `Test-Path <model repo>`
- model repo semantic search: `rg "cosine|similarity|distance|threshold|score|embedding|normalize|l2|pair|verification|s101_224|model_final|infer|eval" <model repo>`
- model repo threshold search: `rg "threshold" <model repo>` and exact `0.7`/`0.70` search, excluding binary/image artifacts
- model repo file inventory: `Get-ChildItem <model repo> -Recurse -File`
- notebook cell inspection through JSON parsing
- local paper PDF text extraction for metric/threshold terms
- optional runtime checks because the stack was already running: Python Embed `/health`, sanitized Python Embed `/embed` response shape, Spring `/api/dev/qdrant-config`, Qdrant collection config

## 핵심 결론

- Python Embed가 Spring에 반환하는 값은 `status`, `vector`, `dimension`, `model`이다.
- Python Embed는 Spring에 scalar similarity, distance, duplicate score, verification classification result를 직접 반환하지 않는다.
- 현재 dog registration duplicate score는 Python model output scalar가 아니라 Qdrant search result의 `score`에서 온다.
- 현재 production score는 Qdrant collection `Cosine` distance 설정에서 나온 Qdrant search score다.
- 현재 Spring 정책은 `maxScore >= duplicateThreshold`일 때 duplicate로 판정한다.
- 따라서 current PetNose runtime architecture에서 "0.7 이하"는 맞지 않는다. 현 구조에서 target threshold를 `0.70`으로 쓰려면 "Qdrant score 0.70 이상이면 duplicate"로 해석해야 한다.

단, model repository 자체에는 `0.70`을 official recommended duplicate threshold로 제시한 증거가 없었다. 이 감사는 threshold 방향과 score source를 확인한 것이며, `0.70`이라는 값의 품질/운영 적합성을 dataset-level로 검증한 것은 아니다.

## Current PetNose pipeline

1. Flutter uploads `nose_image` to Spring.
2. Spring stores file and creates pending DB rows.
3. Spring calls Python Embed.
4. Python Embed returns vector/dimension/model.
5. Spring validates dimension.
6. Spring sends vector to Qdrant.
7. Qdrant returns search results with score and payload.
8. Spring selects max score.
9. Spring compares max score with duplicate threshold.
10. Spring marks `REGISTERED` or `DUPLICATE_SUSPECTED`.

관찰된 구현 근거:

- `EmbedClient`는 `/embed` response에서 `vector`, `dimension`, `model`만 읽어 `EmbedResponse`를 만든다.
- `DogRegistrationService`는 `embedResponse.vector()`를 `qdrantDogVectorClient.search(...)`에 넘긴다.
- `QdrantDogVectorClient`는 `/collections/{collection}/points/search`에 `vector`, `limit`, optional `score_threshold`, `with_payload`, `filter`를 보낸다.
- `QdrantDogVectorClient`는 Qdrant response의 각 point에서 `score`를 읽어 `QdrantSearchResult.score()`로 매핑한다.
- `NoseVerificationPolicy`는 Qdrant search result 중 score가 가장 높은 항목을 고르고 `maxScore >= duplicateThreshold`를 duplicate 조건으로 사용한다.

현재 configured defaults:

| 항목 | 현재 default |
|---|---:|
| `qdrant.search-score-threshold` | `0.95` |
| `nose.duplicate-threshold` | `0.95` |
| `QDRANT_SEARCH_SCORE_THRESHOLD` in compose/env examples | `0.95` |
| `NOSE_DUPLICATE_THRESHOLD` in compose/env examples | `0.95` |

두 threshold는 의미가 다르지만 current runtime에서 같은 score domain을 다룬다.

- `QDRANT_SEARCH_SCORE_THRESHOLD`: Qdrant가 Spring에 후보를 반환하기 전에 적용하는 candidate filter다.
- `NOSE_DUPLICATE_THRESHOLD`: Spring이 반환된 후보 중 max score로 duplicate 여부를 결정하는 policy threshold다.

## Model repository findings

검토한 local model repo는 서비스 API가 아니라 Colab inference notebook, paper PDF, dataset/log artifacts 중심이다.

확인된 내용:

- `dog_nose_inference_colab.ipynb`는 `s101_224` 단일 모델 inference를 설명한다.
- notebook은 classifier logits가 아니라 feature embedding으로 1:1 verification distance를 계산한다고 설명한다.
- notebook의 inference code는 feature를 `F.normalize(feature, p=2, dim=1)`로 L2 normalize한다.
- notebook의 `pair_metrics`는 두 값을 계산한다.
  - `cosine_similarity`: cosine similarity이며 값이 높을수록 더 유사한 방향이다.
  - `euclidean_distance`: L2/Euclidean distance이며 값이 낮을수록 더 유사한 방향이다.
- notebook은 classifier logits가 verification에 사용되지 않는다고 명시한다.
- notebook은 threshold calibration을 하지 않는다고 명시한다.
- exact `0.7`/`0.70` threshold-like value는 model repo text/code artifacts에서 발견되지 않았다.
- local paper PDF에서 metric 관련 내용은 Re-ID feature와 Euclidean/cosine metric 언급, competition score 언급 수준이며 PetNose duplicate runtime threshold로 바로 쓸 `0.70` 기준은 확인되지 않았다.
- `logs/fusion_submit/submit.csv`에는 `prediction` numeric column이 있지만 값 범위와 목적이 PetNose Qdrant cosine score와 다르며, PetNose `/embed` response path에 포함되지 않는다.

PetNose Python Embed service 쪽 확인:

- `python-embed/app/main.py`의 `/embed` response는 `status`, `vector`, `dimension`, `model`만 반환한다.
- `python-embed/app/embedding/dog_nose_identification2_embedder.py`는 real model feature를 L2 normalize한 뒤 list vector로 반환한다.
- runtime `/embed` sanitized check 결과도 keys가 `status,vector,dimension,model`뿐이었다. vector count와 dimension은 `2048`, model은 `dog-nose-identification2:s101_224`였다.

따라서 model repo는 pairwise comparison metric을 계산할 수 있는 inference evidence를 갖고 있지만, current PetNose runtime으로 scalar score나 official `0.70` verification threshold를 반환하지 않는다.

## Threshold interpretation

| Metric type | More similar means | Duplicate condition |
|---|---|---|
| Qdrant cosine score | higher score | score >= threshold |
| cosine distance | lower distance | distance <= threshold |
| L2 distance | lower distance | distance <= threshold |
| model classifier probability | higher probability | probability >= threshold |

current PetNose runtime에 적용되는 row는 `Qdrant cosine score`다.

이유:

- Qdrant collection config는 `distance=Cosine`이다.
- Spring은 Qdrant response의 `score`를 duplicate score로 저장/반환한다.
- Spring은 model-side distance나 classifier probability를 받지 않는다.
- `NoseVerificationPolicy`는 `score >= threshold` 방향으로 duplicate를 판정한다.

## Qdrant threshold vs Spring threshold

- `QDRANT_SEARCH_SCORE_THRESHOLD` filters candidates before Spring sees them.
- `NOSE_DUPLICATE_THRESHOLD` makes Spring duplicate decision.
- If using Qdrant score and target threshold is `0.70`, both usually need to be aligned to `0.70`.
- If Qdrant remains at `0.95`, Spring cannot evaluate candidates in `0.70~0.95` because Qdrant will not return them.

예시:

| Qdrant score threshold | Spring duplicate threshold | score 0.82 후보 처리 |
|---:|---:|---|
| 0.95 | 0.70 | Qdrant에서 필터링되어 Spring이 보지 못함 |
| 0.70 | 0.70 | Spring이 후보를 받고 duplicate로 판정 |
| 0.70 | 0.95 | Spring이 후보를 받지만 duplicate로 판정하지 않음 |

## Recommendation

Recommendation A를 적용한다.

- current architecture는 Qdrant cosine score를 사용한다.
- duplicate should be `score >= 0.70`, not `score <= 0.70`.
- threshold 변경은 이 audit branch가 아니라 later implementation branch에서 수행한다.
- later implementation branch에서 `QDRANT_SEARCH_SCORE_THRESHOLD`와 `NOSE_DUPLICATE_THRESHOLD`를 함께 `0.70`으로 맞춘다.
- score `0.70` boundary, `0.69999`, `0.70000`, `0.70001`, and Qdrant pre-filter behavior를 테스트한다.

주의:

- model repo에서 official `0.70` threshold는 확인되지 않았다.
- `0.70`이라는 값 자체를 model validation threshold로 주장하려면 known same/different dog image pairs로 별도 calibration/evaluation이 필요하다.
- 그러나 current runtime에서 threshold 방향을 결정하는 문제는 충분히 확인되었다. 현재 구조에서는 `>=` 방향이다.

## Proposed next branch

추천 next branch:

- `fix/dog-duplicate-threshold-070`

추천 task:

- Qdrant search score threshold와 Spring duplicate threshold를 `0.70`으로 align한다.
- duplicate boundary tests를 추가한다.
- Qdrant pre-filter 때문에 `0.70~0.95` 후보가 사라지지 않는지 테스트한다.

대안 task:

- product team이 `0.70` 값 자체의 model 품질 근거를 요구하면 `chore/dog-nose-threshold-calibration`에서 controlled same/different dog pair evaluation을 먼저 수행한다.

## Follow-up threshold branch note

Historical note: this follow-up threshold branch predates the active dog nose v2 binary policy. Current active registration and handover thresholds are documented in `docs/PETNOSE_MVP_API_CONTRACT.md`. This section remains as score-semantics audit history, not as current runtime contract.

## Follow-up handover comparison note

The handover implementation was changed after the model-role / expected-dog comparison audit to compare the uploaded handover image directly against the expected dog linked to the adoption post.

- Handover target id is `adoption_posts.dog_id`. In active dog nose v2, Qdrant point ids are UUIDs tracked through `dog_nose_references` and are not equal to `dogs.id`.
- Handover Qdrant search is filtered to the expected dog only and does not send `score_threshold`, so Spring can distinguish a missing expected candidate from an expected candidate scoring below `0.70`.
- Registration remains a thresholded duplicate gate using Qdrant candidate filtering and Spring duplicate policy.
- Python Embed still only returns embedding vector, dimension, and model.
- Qdrant remains the similarity score source.
- Spring remains the threshold policy layer.
