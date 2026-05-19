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
| Spring-Python 참고 | `reference/SPRING_PYTHON_EMBED_CONTRACT.md` | Spring Boot ↔ Python Embed 연동 작업 |
| 공유 전 점검 | `reference/MVP_SCHEMA_TABLE_COUNT_REVIEW.md` | 5-table vs 6-table 기준 충돌 확인 |
| 로컬 정리 | `reference/LOCAL_CLEANUP_GUIDE.md` | ignored/generated 파일 수동 정리 |
| 운영 증거 | `ops-evidence/dev-cd-validation-log.md` | 배포/운영 검증 이력 확인 |
| Archive | `archive/**` | 과거 문서 확인용. active 기준으로 사용 금지 |

추가 참고 문서는 `docs/reference/` 아래에 있다. 예를 들어 운영 절차, 환경변수, 백업, 온보딩, 파일 저장 정책은 active canonical을 보조하는 문서로만 사용한다.

## 충돌 규칙

- `docs/archive/**` 문서와 active canonical 문서가 충돌하면 active canonical 문서가 우선한다.
- `docs/reference/**` 문서와 active canonical 문서가 충돌하면 active canonical 문서가 우선한다.
- 코드 구현 상태와 문서가 충돌하면 먼저 감사/검증 프롬프트로 확인한다.
- DBML/SQL/코드/API 동작을 바꾸는 결론은 문서 정리 작업만으로 확정하지 않는다.
- table count가 5-table 기준과 6-table 구현 기준으로 충돌하면 `reference/MVP_SCHEMA_TABLE_COUNT_REVIEW.md`를 먼저 확인하고 기능 코드나 migration을 바로 삭제하지 않는다.

## Codex 재사용 지시문

```text
Required docs reading policy:
- Always read docs/README.md and docs/PROJECT_KNOWLEDGE_INDEX.md first.
- Then read task-specific canonical/reference documents.
- Do not use docs/archive/** as active implementation criteria.
- If archive/reference docs conflict with active canonical docs, active canonical docs win.
```
