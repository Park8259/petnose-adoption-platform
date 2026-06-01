# Dog Nose v2 Reference Quality Diagnostics Smoke

## Summary

PR #67에서 추가된 dog nose reference quality diagnostics를 real-model compose 환경에서 검증했다.

- 실행 일시: 2026-06-01 15:17:39 KST
- Base branch: `next/dog-nose-v2`
- 작업 branch: `feature/nose-quality-diagnostics-smoke`
- Smoke 대상 commit: `dcaab9e` (`Merge pull request #67 from jaaesung/feature/nose-reference-quality-diagnostics`)
- Compose project: `petnose_v2_quality_smoke_20260601-151739`
- Raw evidence dir: `C:\tmp\petnose-quality-diagnostics-smoke\20260601-151739`
- Final verdict: PASS

이번 smoke는 evidence 문서화 범위이며 backend business logic, Python `/embed-batch`, Qdrant client, handover flow, DB migration, Flutter app은 수정하지 않았다.

## PR #67 Merge Check

`origin/next/dog-nose-v2` 최신 fetch 후 아래 commit이 포함되어 있음을 확인했다.

```text
dcaab9e Merge pull request #67 from jaaesung/feature/nose-reference-quality-diagnostics
7f8372a feat(nose): add reference quality diagnostics
```

## Runtime

Real-model compose 조합:

```text
infra/docker/compose.yaml
infra/docker/compose.dev.yaml
infra/docker/compose.real-model.yaml
```

기존 local compose stack과 host port가 충돌해 smoke 전용 temp env에서 host port만 변경했다. Qdrant는 host `26333`으로 노출했지만, temp-only `compose.local-ports.yaml`로 Spring 내부 `QDRANT_PORT`는 `6333`을 유지했다.

| 항목 | 확인값 |
|---|---|
| Spring health | `UP` |
| Python model | `dog-nose-identification2:s101_224` |
| Python backend | `torch+timm` |
| Python vector dim | `2048` |
| Model loaded | `true` |
| Model path exists | `true` |
| Python load error | `null` |
| Qdrant collection | `dog_nose_embeddings_real_v2` |
| Qdrant vector size | `2048` |
| Qdrant distance | `Cosine` |
| Initial Qdrant point count | `0` |
| Initial DB rows | `users=0`, `dogs=0`, `dog_images=0`, `dog_nose_references=0`, `verification_logs=0`, `adoption_posts=0` |

## Active Quality Policy

| Policy | Value |
|---|---|
| Registration input | exactly `5` `nose_images` |
| Reference consistency threshold | `0.55` |
| Outlier improvement threshold | `0.04` |
| Quality warning enabled | `true` |
| Verdicts | `ACCEPTED`, `WARN_ACCEPTED`, `RETAKE_ONE`, `RETAKE_ALL` |
| Duplicate threshold | `0.65` |
| Review lower bound | `0.65` |
| Handover match threshold | `0.65` |
| Handover ambiguous threshold | `0.65` |
| Qdrant search pre-filter | `0.55` |
| Final score policy | `max(max_reference_score, centroid_score)` |

5장 reference set은 10개 unique pair를 계산한다. Pairwise diagnostics는 O(n^2)이지만 registration 입력이 5장으로 고정되어 고정 비용이다. `weakest_image_index`는 "나쁜 사진" 판정이 아니라 다른 reference 이미지들과의 일관성이 가장 낮은 이미지 위치를 뜻한다.

## Case Results

| Case | Staged input | Direct verdict | API result | Score highlights | Side effect |
|---|---|---|---|---|---|
| ACCEPTED | `ddubi/1.png`-`5.png` | `ACCEPTED` | HTTP `201`, `REGISTERED` | avg `0.839318`, best subset `0.867222`, improvement `0.027904`, weakest `3` | expected create: dog `+1`, images `+5`, references `+6`, Qdrant `+6`, uploads `+5` |
| WARN_ACCEPTED | `milk/1.png`-`5.png` | `WARN_ACCEPTED` | HTTP `201`, `REGISTERED` | avg `0.775610`, best subset `0.816541`, improvement `0.040931`, weakest `1` | expected create: dog `+1`, images `+5`, references `+6`, Qdrant `+6`, uploads `+5` |
| RETAKE_ONE | `kakao2/1.jpg`-`5.jpg` | `RETAKE_ONE` | HTTP `400`, `NOSE_REFERENCE_INCONSISTENT` | avg `0.544522`, best subset `0.560918`, improvement `0.016396`, weakest `4`, best subset `[1,2,3,5]` | no file/DB/Qdrant side effect |
| RETAKE_ALL | `kakao2/1.jpg`-`4.jpg` + `milk/1.png` | `RETAKE_ALL` | HTTP `400`, `NOSE_REFERENCE_INCONSISTENT` | avg `0.330399`, best subset `0.520050`, improvement `0.189651`, weakest `5`, best subset `[1,2,3,4]` | no file/DB/Qdrant side effect |

`RETAKE_ALL`은 KAKAO2 crop-like 4장 subset의 best average가 `0.55` 미만임을 확인하기 위해 `milk/1.png`를 5번째 staging file로 사용했다. 이 복사/재사용 내역은 raw evidence의 `cases/retake_all/source_files.json`에 기록했다.

## Persisted Score Breakdown

성공 case는 API response가 `201 REGISTERED`였고, persisted `verification_logs.score_breakdown_json.reference_quality`를 확인했다.

| Dog ID | Result | Verdict | Weakest | Best subset | Best subset avg | Improvement |
|---|---|---|---|---|---|---|
| `b8a7776f-b92c-4eac-a3a8-fab832145783` | `PASSED` | `ACCEPTED` | `3` | `[1, 2, 4, 5]` | `0.8672223434301537` | `0.02790422846004248` |
| `bc90793a-8182-4ce9-b91f-fcb01cedca6d` | `PASSED` | `WARN_ACCEPTED` | `1` | `[2, 3, 4, 5]` | `0.8165411801157405` | `0.040931407169708` |

각 성공 dog의 Qdrant payload count는 `REFERENCE=5`, `CENTROID=1`이었다.

## Failure Response Details

`RETAKE_ONE`과 `RETAKE_ALL` 실패 response는 모두 다음 필드를 포함했다.

- `error_code=NOSE_REFERENCE_INCONSISTENT`
- `details.quality_verdict`
- `details.average_pairwise_score`
- `details.threshold`
- `details.weakest_image_index`
- `details.best_subset_indexes`
- `details.best_subset_average_score`
- `details.recommendation`
- `details.pairwise_scores`
- `details.per_image_qualities`
- `details.leave_one_out_subsets`

실패 case 전후 count가 동일해 file/DB/Qdrant side effect가 없음을 확인했다.

## Four Image Validation

`nose_images` 4장 요청은 HTTP `400`으로 거부되었다.

```text
error_code=NOSE_IMAGES_COUNT_INVALID
details.expected_count=5
details.actual_count=4
```

이 요청도 file/DB/Qdrant side effect가 없었다.

## Raw Evidence

Raw JSON/CSV/log는 repository에 커밋하지 않고 아래 local-only 경로에 남겼다.

```text
C:\tmp\petnose-quality-diagnostics-smoke\20260601-151739
```

주요 파일:

- `smoke-summary.json`
- `candidate-diagnostics.json`
- `compose-config.final-retry.yaml`
- `spring-health.json`
- `python-health.json`
- `qdrant/collection.json`
- `qdrant/initial-count.json`
- `sql/initial-counts.txt`
- `sql/score-breakdown-reference-quality.txt`
- `cases/*/direct_diagnostic.json`
- `cases/*/pairwise_scores.csv`
- `cases/*/per_image_quality.csv`
- `cases/*/leave_one_out.csv`
- `cases/*/api-registration-response.json`
- `logs/spring-api.log`
- `logs/python-embed.log`
- `logs/qdrant.log`

## Validation Commands

| Command | Result |
|---|---|
| `cd backend && gradle test` | PASS |
| `cd backend && gradle build` | PASS |
| `cd python-embed && pytest` | PASS, 9 passed |
| `git diff --check` | PASS |
| `docker compose --env-file infra/docker/.env.example -f infra/docker/compose.yaml -f infra/docker/compose.dev.yaml config` | PASS |
| `docker compose --env-file infra/docker/.env.example -f infra/docker/compose.yaml -f infra/docker/compose.dev.yaml -f infra/docker/compose.real-model.yaml config` | PASS |
