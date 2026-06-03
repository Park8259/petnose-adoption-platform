# Qdrant MySQL Reference Reconciliation Runbook

> 문서 성격: 보조 참고 문서(Task Reference)
>
> dog nose v2에서 MySQL `dog_nose_references`와 Qdrant active points의 정합성을 점검하고, drift가 발견되었을 때 안전한 복구 판단을 내릴 때 사용한다.
> active canonical 문서와 충돌하면 active canonical 문서가 우선한다.

## 목적

이 runbook은 MySQL `dog_nose_references`와 Qdrant active points 사이의 정합성을 점검하는 절차를 정의한다.

핵심 원칙:

- MySQL은 source of truth다.
- Qdrant는 dog nose vector search index다.
- Qdrant point id는 UUID이며 `dogs.id`가 아니다.
- Qdrant point id와 reference metadata는 MySQL `dog_nose_references`가 추적한다.
- Qdrant vector 자체는 MySQL에 저장하지 않는다.

## Dog Nose V2 정상 상태

정상 dog registration 1건 기준으로 아래 상태가 모두 맞아야 한다.

| 위치 | 정상 상태 |
|---|---|
| `dog_images` | `image_type=NOSE` row 5개 |
| `dog_nose_references` | active row 6개: `REFERENCE` 5개, `CENTROID` 1개 |
| Qdrant active points | active point 6개 |
| Qdrant payload | `is_active=true`, `dog_id=dogs.id`, `embedding_kind=REFERENCE` 또는 `CENTROID`, `dimension=2048`, `preprocess_version` 존재 |
| `verification_logs` | latest dog registration result가 `PASSED` |
| `dogs` | `status=REGISTERED` |

## 가능한 Drift 유형

| 유형 | 증상 | 가능한 원인 | 처리 원칙 |
|---|---|---|---|
| `orphan_in_qdrant` | Qdrant에는 active point가 있지만 MySQL `dog_nose_references.qdrant_point_id`에는 없다. | Qdrant upsert 성공 후 DB 저장 실패, DB reset, 수동 DB 삭제. | MySQL source of truth에 없는 point다. dry-run evidence를 확인한 뒤 Qdrant delete를 수행할 수 있다. |
| `missing_in_qdrant` | MySQL `dog_nose_references`에는 active reference가 있지만 Qdrant에는 point가 없다. | Qdrant collection reset, Qdrant point 수동 삭제, volume 손상. | 자동 복구하지 않는다. MySQL에는 vector가 없으므로 해당 dog를 재등록하거나, 관리자가 기존 reference를 inactive 처리한 뒤 재등록해야 한다. |
| `payload_mismatch` | Qdrant point id는 MySQL에 있으나 payload의 `dog_id`, `embedding_kind`, `dimension`, `preprocess_version` 등이 MySQL과 다르다. | 수동 payload 수정, 잘못된 collection migration, 과거 데이터 import 실수. | payload patch보다 point 삭제 후 재등록/재생성을 권장한다. 운영자가 임의 수정하면 evidence chain이 깨질 수 있다. |
| `collection_contract_mismatch` | Qdrant collection dimension 또는 distance가 config와 다르다. | collection을 잘못 생성했거나 mock/real-model 설정이 섞임. | collection 재생성 또는 별도 collection migration이 필요하다. 기존 point와 model dimension이 불일치하면 search/upsert가 실패할 수 있다. |

## 복구 원칙

- 기본 작업은 dry-run이다.
- delete는 명시적 flag를 사용할 때만 수행한다.
- `missing_in_qdrant`는 자동 복구하지 않는다.
- vector는 MySQL에 저장하지 않으므로 missing point를 script가 재생성할 수 없다.
- `payload_mismatch`는 자동 patch하지 않는다.
- orphan delete 전에는 evidence JSON을 저장한다.
- production 또는 shared dev에서 delete를 수행하려면 담당자 승인 또는 PR/issue evidence를 남긴다.
- raw vector, DB password, JWT, service account 경로, 전체 Qdrant payload를 evidence에 남기지 않는다.

## 제출 전 Smoke 확인 항목

real-model E2E smoke 또는 제출 전 운영 점검에서 아래 항목을 확인한다.

- `dog_nose_references` active count와 Qdrant active point count 일치
- `missing_in_qdrant = []`
- `orphan_in_qdrant = []`
- `payload_mismatches = []`
- collection dimension = `2048`
- collection distance = `Cosine`
- registration normal case 후 dog 1마리당 `REFERENCE` 5개 + `CENTROID` 1개 확인
- duplicate suspected case 후 Qdrant count 증가 없음

## Dry-Run 명령 예시

PowerShell에서 로컬/dev compose runtime이 떠 있는 상태에서 실행한다.

```powershell
pwsh ./scripts/check-qdrant-reference-consistency.ps1 `
  -EnvFile infra/docker/.env `
  -QdrantUrl http://localhost:6333 `
  -Collection dog_nose_embeddings_real_v2 `
  -OutputPath docs/ops-evidence/local-qdrant-reconciliation-dry-run.json
```

drift가 있으면 exit code를 실패로 받고 싶은 제출 전 smoke에서는 `-FailOnDrift`를 추가한다.

```powershell
pwsh ./scripts/check-qdrant-reference-consistency.ps1 `
  -EnvFile infra/docker/.env `
  -QdrantUrl http://localhost:6333 `
  -Collection dog_nose_embeddings_real_v2 `
  -FailOnDrift
```

## Orphan Delete 명령 예시

주의: 이 명령은 Qdrant point를 삭제할 수 있다. production/shared dev에서는 승인과 evidence를 먼저 남긴다.

삭제는 아래 두 flag가 모두 있을 때만 수행된다.

- `-DeleteOrphans`
- `-ConfirmDelete`

```powershell
pwsh ./scripts/check-qdrant-reference-consistency.ps1 `
  -EnvFile infra/docker/.env `
  -QdrantUrl http://localhost:6333 `
  -Collection dog_nose_embeddings_real_v2 `
  -OutputPath docs/ops-evidence/local-qdrant-orphan-delete-evidence.json `
  -DeleteOrphans `
  -ConfirmDelete
```

삭제 후에는 dry-run 명령을 다시 실행해 `orphan_in_qdrant = []`인지 확인한다.

## 결과 JSON 해석

script summary의 핵심 field:

```json
{
  "collection": "dog_nose_embeddings_real_v2",
  "checked_at": "2026-06-03T00:00:00Z",
  "mysql_active_reference_count": 0,
  "qdrant_active_point_count": 0,
  "missing_in_qdrant": [],
  "orphan_in_qdrant": [],
  "payload_mismatches": [],
  "collection_contract": {
    "exists": true,
    "dimension": 2048,
    "distance": "Cosine"
  },
  "consistent": true,
  "deleted_orphans": []
}
```

`consistent=true` 조건:

- collection이 존재한다.
- `missing_in_qdrant`가 비어 있다.
- `orphan_in_qdrant`가 비어 있다.
- `payload_mismatches`가 비어 있다.
- collection dimension이 expected dimension과 같다. 기본값은 `2048`이다.
- collection distance가 expected distance와 같다. 기본값은 `Cosine`이다.

## 운영 판단 메모

- `missing_in_qdrant`는 script로 복구할 수 없다. dog nose vector는 Qdrant에만 있고 MySQL에는 없다.
- `payload_mismatch`는 evidence chain을 보존하기 위해 자동 patch하지 않는다.
- `orphan_in_qdrant`는 MySQL source of truth에 없으므로 삭제 후보가 될 수 있지만, 삭제 전 evidence JSON을 보관한다.
- collection contract가 real-model 기준과 다르면 dog nose v2 smoke를 진행하기 전에 collection 생성 경로와 compose override 조합을 먼저 확인한다.
