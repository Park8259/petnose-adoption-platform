# Similarity Experiment

작성일: 2026-05-24 KST

## 실행 환경

- Model root: `<local_model_repo>`
- Dataset: `<model_dataset_dir>`
- Checkpoint: `logs\s101_224\model_final.pth`
- Model: `dog-nose-identification2:s101_224`
- Vector dimension: 2048
- Device: CPU
- Runtime: Docker image `petnose-python-embed:latest`
- Script: `docs/model-analysis/run_similarity_experiment.py`

샘플 선택:

- `dir_train`의 dog_id 폴더를 숫자순으로 정렬했다.
- 5장 이상 있는 dog_id 중 첫 50개를 선택했다.
- 각 dog_id당 정렬된 이미지 5장을 사용했다.
- multi-reference 실험은 앞 3장을 등록 reference, 뒤 2장을 validation query로 사용했다.
- 선택 dog_id: `1771`-`1821` 범위의 50개 dog_id. `1819`는 5장 조건을 만족하지 않아 건너뛰었다.

생성 산출물:

- `pairwise_scores.csv`: 31,175 rows, generated raw CSV artifact
- `multi_reference_scores.csv`: 5,000 rows, generated raw CSV artifact
- `experiment_summary.json`: 실험 summary, repository에 유지하는 primary tracked summary

Raw CSV는 active repository에 tracked file로 유지하지 않는다. 필요하면 `docs/model-analysis/README.md`의 artifact policy와 `run_similarity_experiment.py`로 local artifact directory에 재생성한다.

## 실험 A: 동일 이미지 재입력

같은 파일 embedding을 자기 자신과 cosine 비교했다.

| count | mean | min | max | std |
|---:|---:|---:|---:|---:|
| 50 | 1.000000 | 0.9999997 | 1.0000003 | 0.0000001 |

결론: embedding normalize와 cosine 계산 자체는 정상이다. 같은 파일 재입력은 기대대로 거의 1.0이다.

## 실험 B: 동일 dog 다른 이미지

각 dog_id의 5장 이미지 내 모든 pair를 비교했다.

| count | mean | min | max | std | p05 | p50 | p95 |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 500 | 0.8676 | 0.7119 | 0.9836 | 0.0620 | 0.7698 | 0.8650 | 0.9635 |

결론: cropped nose 데이터에서는 같은 dog의 다른 이미지도 대부분 0.8 이상이다. 최저값도 0.7119라 현재 0.70 threshold는 이 샘플에서는 통과한다.

## 실험 C: 다른 dog 비교

선택한 50개 dog_id 간 서로 다른 dog image pair를 모두 비교했다.

| count | mean | min | max | std | p95 | p99 |
|---:|---:|---:|---:|---:|---:|---:|
| 30,625 | 0.1494 | -0.1891 | 0.5893 | 0.1121 | 0.3398 | 0.4213 |

결론: cropped nose 샘플에서는 다른 dog 점수가 같은 dog와 명확히 분리된다. 이 표본에서 observed negative max는 0.5893이다.

## 실험 D: 3-reference 등록 방식

각 dog_id에서 registration reference 3장, validation query 2장을 사용했다. 각 validation query를 모든 target dog의 3-reference set과 비교했다.

Positive = query dog_id와 target dog_id가 같음. Negative = 다름.

### Positive same dog

| method | count | mean | min | std | p05 | p50 | p95 |
|---|---:|---:|---:|---:|---:|---:|---:|
| single reference | 100 | 0.8407 | 0.7348 | 0.0507 | 0.7624 | 0.8337 | 0.9275 |
| centroid | 100 | 0.8990 | 0.7913 | 0.0432 | 0.8159 | 0.9023 | 0.9622 |
| max reference | 100 | 0.9061 | 0.7687 | 0.0574 | 0.7975 | 0.9260 | 0.9689 |
| top2 average | 100 | 0.8780 | 0.7569 | 0.0481 | 0.7922 | 0.8767 | 0.9466 |
| centroid + max average | 100 | 0.9025 | 0.7855 | 0.0485 | 0.8086 | 0.9176 | 0.9594 |

### Negative different dogs

| method | count | mean | max | std | p95 | p99 |
|---|---:|---:|---:|---:|---:|---:|
| single reference | 4,900 | 0.1503 | 0.5538 | 0.1118 | 0.3407 | 0.4225 |
| centroid | 4,900 | 0.1556 | 0.5777 | 0.1151 | 0.3508 | 0.4302 |
| max reference | 4,900 | 0.1687 | 0.5836 | 0.1117 | 0.3594 | 0.4407 |
| top2 average | 4,900 | 0.1586 | 0.5631 | 0.1112 | 0.3477 | 0.4276 |
| centroid + max average | 4,900 | 0.1622 | 0.5802 | 0.1133 | 0.3546 | 0.4326 |

## Multi-reference 효과

3-reference 방식은 single reference보다 확실히 도움이 된다.

- Positive mean: single `0.8407` -> centroid `0.8990`, max `0.9061`.
- Positive min: single `0.7348`, centroid `0.7913`, max `0.7687`.
- Negative max는 multi-reference에서도 `0.58` 근처에 머물렀다.

운영 관점에서는 centroid만 저장하는 것보다 개별 reference embedding을 함께 저장하는 편이 낫다.

- `max reference`가 positive 평균에서 가장 높았다.
- `centroid`는 positive 최저값이 가장 높아 안정성이 좋았다.
- 개별 reference가 있어야 각도/조명별 best match를 잡고, 어떤 reference가 맞았는지 설명할 수 있다.
- centroid만 저장하면 pose/lighting 다양성을 평균내면서 일부 query의 best evidence를 잃는다.

## Query Expansion / Re-ranking

현재 PetNose 구현에는 query expansion 또는 re-ranking 단계가 없다. Qdrant가 반환한 point score 중 max를 바로 Spring threshold와 비교한다.

생성된 multi-reference raw artifact의 행은 각 query를 모든 target dog의 3-reference set과 비교했기 때문에, "reference point search 후 dog_id로 group-by re-ranking"을 오프라인으로 재현한 형태다. 별도의 query vector expansion은 실행하지 않았다. v2 설계에서는 Qdrant reference search 결과를 dog_id로 묶고 `max_reference_score`, `top2_average_score`, `centroid_score`로 re-ranking하는 방식을 권장한다.

## Threshold 초안

이 실험은 cropped nose 샘플 기준이다. 실제 운영 threshold는 앱 촬영 데이터로 재보정해야 한다.

3-reference 이상을 전제로 한 초안:

| decision | dog-level score |
|---|---:|
| AUTO MATCH / DUPLICATE_SUSPECTED | `>= 0.75` |
| MANUAL_REVIEW | `0.60 <= score < 0.75` |
| NOT_MATCH / REGISTER_ALLOWED | `< 0.60` |

Dog-level score는 우선 `max_reference_score`를 사용하고, `centroid_score`를 함께 기록한다. 동일 dog positive의 observed min이 `0.7687`, 다른 dog negative의 observed max가 `0.5836`이므로 0.60-0.75 band는 cropped sample에서 margin이 있다.

중요: 현재 Spring/Qdrant 구조에서 Qdrant `score_threshold`가 0.70이면 `0.60~0.70` manual-review 후보가 Spring에 도달하지 않는다. manual-review band를 운영하려면 Qdrant pre-filter를 `0.55` 또는 `0.60` 수준으로 낮추고, 최종 결정은 Spring policy에서 해야 한다.

## 해석

cropped nose 샘플에서는 모델이 같은 dog와 다른 dog를 강하게 분리했다. 따라서 운영에서 동일 비문 score가 낮다면 가장 먼저 확인할 것은 모델 checkpoint가 아니라 입력 이미지다.

확인 우선순위:

1. 업로드 이미지가 close-up nose crop인지 확인한다.
2. full face/muzzle 이미지를 그대로 넣고 있지 않은지 확인한다.
3. blur, glare, 어두움, 비스듬한 각도, 콧구멍 과다 노출, 코 끝 잘림을 품질 gate로 막는다.
4. 3-5장 reference를 등록해 max/centroid score를 같이 사용한다.
5. threshold를 낮추기 전에 Qdrant pre-filter와 Spring final threshold를 분리한다.
