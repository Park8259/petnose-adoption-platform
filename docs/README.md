# PetNose 문서 진입점

이 디렉터리는 PetNose 졸업작품 문서의 진입점이다.

모든 작업자는 먼저 `docs/README.md`와 `docs/PROJECT_KNOWLEDGE_INDEX.md`를 읽는다. 그다음 작업 종류에 맞는 active canonical 문서 또는 reference 문서를 따라간다.

## 읽기 계층

1. 항상 필독(Always read first)
   - 모든 작업 시작 전 먼저 읽는 문서다.
2. Active canonical
   - 현재 구현과 판단의 기준이 되는 문서다.
3. Task-specific reference
   - 특정 작업에서 active canonical을 보조하는 참고 문서다.
4. Ops evidence
   - 배포/운영 검증 이력과 증거를 확인하는 문서다.
5. Archive/historical
   - 과거 설계, 초안, 회고 기록이다. active 구현 기준으로 사용하지 않는다.

## 문서 라우팅 표

| 구분 | 문서 | 언제 읽는가 |
|---|---|---|
| 항상 필독 | `PROJECT_KNOWLEDGE_INDEX.md` | 모든 작업 시작 전 |
| API 기준 | `PETNOSE_MVP_API_CONTRACT.md` | API/controller/service/test 작업 |
| 도메인 기준 | `PETNOSE_MVP_FINAL_PROJECT_SPEC.md` | 기능 범위/정책 판단 |
| DB 기준 | `db/petnose_mvp_schema.dbml` | entity/schema 판단 |
| DB 기준 | `db/V20260508__mvp_canonical_schema.sql` | clean canonical SQL 확인 |
| Migration 참고 | `reference/DB_MIGRATION_STRATEGY.md` | Flyway/runtime migration 작업 |
| Vector/Storage 참고 | `reference/STORAGE_AND_VECTOR_BOUNDARY.md` | Qdrant/Python Embed/file storage 경계 판단 |
| Qdrant 정합성 복구 | `reference/QDRANT_RECONCILIATION_RUNBOOK.md` | `dog_nose_references`와 Qdrant active points drift 점검/복구 |
| 모델 분석 근거 | `model-analysis/README.md` | dog nose v2 threshold/Qdrant reference 설계 summary와 재현 경로 확인 |
| Spring-Python 참고 | `reference/SPRING_PYTHON_EMBED_CONTRACT.md` | Spring Boot ↔ Python Embed 연동 작업 |
| 공유 전 점검 | `reference/MVP_SCHEMA_TABLE_COUNT_REVIEW.md` | 과거 table count 기준 충돌 확인 |
| 앱 요청 후속 API 계획 | `reference/APP_REQUESTED_API_PR_PLAN.md` | 앱팀 추가 요청사항의 PR 분할/범위 확인 |
| 앱 요청 API 최종 체크리스트 | `reference/APP_API_FINAL_HANDOFF_CHECKLIST.md` | 앱팀 endpoint/header/field 연결 전 최종 확인 |
| 실제 runtime E2E | `ops-evidence/dog-nose-v2-smoke-plan.md`, `reference/MVP_BACKEND_FLOW_HANDOFF.md` | dog nose v2 real-model Docker flow 검증 |
| 로컬 정리 | `reference/LOCAL_CLEANUP_GUIDE.md` | ignored/generated 파일 수동 정리 |
| 운영 증거 | `ops-evidence/dev-cd-validation-log.md` | 배포/운영 검증 이력 확인 |
| 앱 요청 API 회귀 증거 | `ops-evidence/app-requested-api-regression-log.md` | PR 8 regression/evidence 결과 확인 |
| 최종 제출 real-model E2E 증적 | `ops-evidence/submission-real-model-e2e-log.md` | 최종 real-model E2E 증적 |
| Archive | `archive/**` | 과거 문서 확인용. active 기준으로 사용 금지 |

추가 참고 문서는 `docs/reference/` 아래에 있다. 예를 들어 운영 절차, 환경변수, 백업, 온보딩, 파일 저장 정책은 active canonical을 보조하는 문서로만 사용한다.

## Current Active Snapshot

- develop 제출 기준 MySQL table은 총 8개다.
- Core domain/relationship table은 `users`, `dogs`, `dog_images`, `dog_nose_references`, `verification_logs`, `adoption_posts`, `adoption_post_likes` 7개다.
- Auth support table은 `password_reset_tokens` 1개이며 domain table로 세지 않는다.
- Dog nose v2 registration은 `POST /api/dogs/register`에서 `nose_images` 정확히 5장을 받고 Python `/embed-batch`를 1회 호출한다.
- Active Qdrant collection은 `dog_nose_embeddings_real_v2`, vector dimension은 `2048`, distance는 `Cosine`이다.
- Qdrant point id는 UUID이며 `dogs.id`와 같지 않다. point id와 reference metadata는 MySQL `dog_nose_references`가 추적한다.

## 충돌 규칙

- `docs/archive/**` 문서와 active canonical 문서가 충돌하면 active canonical 문서가 우선한다.
- `docs/reference/**` 문서와 active canonical 문서가 충돌하면 active canonical 문서가 우선한다.
- 코드 구현 상태와 문서가 충돌하면 먼저 감사/검증 프롬프트로 확인한다.
- DBML/SQL/코드/API 동작을 바꾸는 결론은 문서 정리 작업만으로 확정하지 않는다.
- table count가 과거 기준과 current active schema 기준으로 충돌하면 `reference/MVP_SCHEMA_TABLE_COUNT_REVIEW.md`와 `PROJECT_KNOWLEDGE_INDEX.md`를 먼저 확인하고 기능 코드나 migration을 바로 삭제하지 않는다.

## Codex 재사용 지시문

```text
Required docs reading policy:
- Always read docs/README.md and docs/PROJECT_KNOWLEDGE_INDEX.md first.
- Then read task-specific canonical/reference documents.
- Do not use docs/archive/** as active implementation criteria.
- If archive/reference docs conflict with active canonical docs, active canonical docs win.
```
