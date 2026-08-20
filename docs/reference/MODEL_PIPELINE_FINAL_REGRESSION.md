# Model Pipeline Final Regression

> 문서 성격: release regression gate(Task Reference)
>
> `develop`를 `main`으로 승격하기 전에 모델 파이프라인, production runtime guardrail, 핵심 API 흐름을 한 번에 확인할 때 이 문서를 따른다.

---

## 목적

이 gate는 새 기능을 켜기 위한 문서가 아니라 release 전에 이미 존재하는 검증 도구를 같은 순서와 같은 기준으로 실행하기 위한 최종 회귀 검증 절차다.

대상 범위:

- PyTorch `/embed-batch` production runtime
- profile-first, YOLO, registration timing log default-off
- optional ONNX 코드와 CI smoke는 포함하되 production runtime 활성화 금지
- multi-reference 5장 등록, duplicate detection, handover verification, adoption post/like/adoption completion
- Firebase chat, password reset confirm, Qdrant/MySQL reconciliation은 환경 의존 manual gate로 분리
- immutable production image와 inference runtime policy

선행 조건:

- PR #111 `ops: enforce safe inference runtime deployment policy`가 `develop`에 merge되어 있어야 한다.
- PR #111 merge commit 기준 CI가 PASS여야 한다.
- `docs/reference/INFERENCE_RUNTIME_DEPLOYMENT_POLICY.md`, `scripts/verify-server-release-readiness.ps1`, `scripts/tests/verify-server-release-policy.ps1`, `infra/scripts/tests/test-production-runtime-policy.sh`가 존재해야 한다.

---

## 실행 도구

최종 wrapper:

```powershell
pwsh ./scripts/run-model-pipeline-final-regression.ps1 -Mode PlanOnly
pwsh ./scripts/run-model-pipeline-final-regression.ps1 -Mode Static
```

로컬 real-model runtime:

```powershell
pwsh ./scripts/run-model-pipeline-final-regression.ps1 `
  -Mode LocalRealModel `
  -NoseImageDir "<fixture-dir>" `
  -ProfileImagePath "<profile-image>" `
  -EnvFile "infra/docker/.env" `
  -WriteEvidence
```

서버 API only smoke:

```powershell
pwsh ./scripts/run-model-pipeline-final-regression.ps1 `
  -Mode ApiOnly `
  -RootUrl "http://<server-host>" `
  -BaseUrl "http://<server-host>/api" `
  -NoseImageDir "<fixture-dir>" `
  -PasswordResetMode skip `
  -FirebaseMode enabled `
  -WriteEvidence
```

wrapper는 아래 기존 child script를 subprocess로 호출한다.

- `scripts/verify-server-release-readiness.ps1`
- `scripts/verify-submission-real-model-e2e.ps1`
- `scripts/manual-full-feature-smoke.ps1`
- `scripts/check-qdrant-reference-consistency.ps1`

새 wrapper는 child script의 API 호출 로직을 복사하지 않는다.

---

## Regression Matrix

| regression requirement | existing script/test | coverage | gap | planned action |
|---|---|---|---|---|
| Backend unit/integration tests | `gradle test`, CI `Backend tests` | PASS 필요 | 없음 | Static mode와 CI에서 실행 |
| Python Embed tests | `pytest -q`, CI `Python tests` | PASS 필요 | 없음 | Static mode와 CI에서 실행 |
| Optional ONNX smoke | CI `Optional ONNX runtime smoke` | CI PASS 필요 | 로컬 dependency 없으면 실행 불가 | Static summary에 `CI_REQUIRED` 또는 local PASS 기록 |
| Docker default/ONNX build | CI `Docker build`, `Optional ONNX runtime smoke` | CI PASS 필요 | local Static은 build를 강제하지 않음 | develop-to-main gate에서 CI PASS 필수 |
| Compose mock smoke | CI `Compose mock smoke` | CI PASS 필요 | local Static은 compose config까지만 실행 | CI PASS 필수로 승인 기준화 |
| Production runtime policy | `scripts/verify-server-release-readiness.ps1`, `scripts/tests/verify-server-release-policy.ps1` | PyTorch/default-off/immutable tag 검증 | 없음 | Static mode에서 policy test 호출 |
| Deploy script policy | `infra/scripts/tests/test-production-runtime-policy.sh` | deploy guardrail 검증 | bash 없는 로컬은 CI 필요 | Static/CI에서 실행 |
| Profile-first default-off | backend tests, final runner live probe | 404 `PROFILE_FIRST_DISABLED` 계약 | 기존 smoke에는 live gate가 없음 | ApiOnly/LocalRealModel에서 최소 multipart disabled probe |
| Profile-first YOLO demo opt-in | `scripts/profile-first-yolo-demo-smoke.ps1` | draft, mismatch, pass, duplicate, fallback | g4dn/develop demo runtime과 외부 YOLO fixture 필요 | main release gate가 아니며 별도 demo evidence로 실행 |
| Standard dog registration 5 images | `manual-full-feature-smoke.ps1`, `verify-submission-real-model-e2e.ps1` | 5장 등록, multi-reference | fixture 필요 | child script 재사용 |
| Duplicate detection | `verify-submission-real-model-e2e.ps1`, manual smoke | duplicate suspected 및 Qdrant unchanged | real model runtime 필요 | LocalRealModel manual gate |
| Adoption post create/list/detail | `manual-full-feature-smoke.ps1`, `verify-submission-real-model-e2e.ps1` | create, public list/detail privacy | fixture/runtime 필요 | ApiOnly 또는 LocalRealModel |
| Like/unlike | `manual-full-feature-smoke.ps1` | like/list/unlike/relike | real server 필요 | ApiOnly gate |
| Password reset request/confirm policy | backend tests, manual smoke optional mode | request/confirm 정책 | email token은 자동 run에서 없음 | `PasswordResetMode`로 PASS/SKIP 기록 |
| Firebase custom token/chat | backend tests, manual smoke optional mode | disabled/auto/enabled flow | service account 필요 | `FirebaseMode`로 PASS/SKIP 기록 |
| Handover verification | `manual-full-feature-smoke.ps1`, `verify-submission-real-model-e2e.ps1` | matched decision, no side-effect contract | real model fixture 필요 | child script 재사용 |
| Adoption completion | `manual-full-feature-smoke.ps1`, `verify-submission-real-model-e2e.ps1` | status/adopter/adopted query | real runtime 필요 | child script 재사용 |
| File serving | `manual-full-feature-smoke.ps1`, `verify-submission-real-model-e2e.ps1` | owner/post/nose file URL | runtime upload path 필요 | child script 재사용 |
| MySQL/Qdrant reconciliation | `check-qdrant-reference-consistency.ps1` | dry-run drift detection | ApiOnly에서는 금지 | LocalRealModel/manual gate에서 실행 |
| Sanitized evidence | existing scripts and wrapper summary | tokens/raw images/raw vectors omitted | wrapper summary 필요 | temp evidence `summary.json`, `summary.md`, `steps.csv` |
| No data reset by default | manual and real-model scripts | reset flags explicit only | wrapper가 reset flag를 넘기면 위험 | wrapper 기본값에서 reset/compose lifecycle 미사용 |
| Local benchmark vs AWS E2E separation | `docs/ops-evidence/model-pipeline-analysis/README.md` | scope distinction documented | release gate와 혼동 가능 | 이 문서에서 승인 기준 분리 |

---

## Modes

### PlanOnly

명령이나 child subprocess를 실행하지 않는다.

출력:

- 실행 예정 단계
- 필요한 외부 파일
- 선택 기능과 skip 예정 항목
- evidence 경로
- 데이터 reset 없음

secret, password, token, env 값, 실제 fixture path는 출력하지 않는다.

### Static

실행 항목:

- `git diff --check`
- backend Gradle tests
- Python Embed tests
- production runtime policy test
- deploy script policy test
- PowerShell/shell syntax checks
- compose config using `.env.example`
- forbidden artifact scan
- secret/private-path scan for final regression files
- optional ONNX CI smoke 존재 확인

로컬 ONNX dependency가 없으면 설치하지 않고 `CI_REQUIRED`로 기록한다.

### LocalRealModel

기존 `verify-submission-real-model-e2e.ps1`를 호출한다.

필수:

- 실제 fixture는 repository 밖에서 입력
- 기본값으로 DB/Qdrant reset 금지
- raw image/vector evidence 금지
- Python health는 `status=ok`, `model_loaded=true`, `backend=torch+timm`, `vector_dim=2048`, `model` prefix `dog-nose-identification2`여야 한다.

ONNX Runtime, YOLO detector, profile-first가 production runtime에서 활성화되어 있으면 FAIL이다.

profile-first YOLO demo runtime 검증은 `LocalRealModel` release gate가 아니라
별도 g4dn/develop opt-in smoke다. 실행 시에는 production 기본값을 바꾸지 않고
`scripts/profile-first-yolo-demo-smoke.ps1`로 별도 evidence를 작성한다.

### ApiOnly

기존 `manual-full-feature-smoke.ps1 -ApiOnly`를 호출한다.

금지:

- compose control
- DB reset
- direct Qdrant mutation
- direct Python model export/benchmark

확인:

- public health and auth/profile/password flows
- dog registration 5장
- duplicate detection
- adoption post create/list/detail
- like/unlike
- Firebase optional flow
- handover
- adoption completion
- adopted dog query
- file URL
- profile-first disabled endpoint contract

---

## Runtime Guardrails

현재 production release의 safe defaults:

```dotenv
DOG_NOSE_RUNTIME=torch
DOG_NOSE_EXTRACT_ENABLED=false
PETNOSE_PROFILE_FIRST_ENABLED=false
PETNOSE_REGISTRATION_TIMING_LOG_ENABLED=false
EMBED_MODEL=dog-nose-identification2
EMBED_VECTOR_DIM=2048
```

ApiOnly 또는 LocalRealModel mode는 최소 multipart 요청으로 아래 disabled contract를 확인한다.

- `POST /api/dogs/profile-draft`
- `POST /api/dogs/{random-dog-id}/nose-verification`

기대 결과:

- HTTP `404`
- `error_code=PROFILE_FIRST_DISABLED`

이 확인은 인증, DB, 파일 저장, Python 호출 전에 종료되는 contract를 검증한다. 실제 profile-first 데이터를 만들지 않는다.

---

## Evidence

기본 출력 위치는 repository 밖 temp 경로다.

```text
<system-temp>/petnose-model-pipeline-final-regression/<timestamp>/
  summary.json
  summary.md
  steps.csv
```

`summary.json` schema:

```json
{
  "schema_version": 1,
  "scope": "model-pipeline-final-regression",
  "mode": "ApiOnly",
  "started_at": "...",
  "finished_at": "...",
  "overall_status": "PASS",
  "runtime_policy": {
    "expected_backend": "torch+timm",
    "onnx_enabled": false,
    "yolo_enabled": false,
    "profile_first_enabled": false
  },
  "steps": []
}
```

저장 금지:

- password, JWT, reset token
- Firebase custom token, FCM token, service account
- private email
- raw image, raw vector, full Qdrant payload
- DB credential, `.env` contents
- checkpoint path
- absolute private fixture path

허용:

- fixture count
- file extension
- HTTP status and error code
- redacted dog/post/user id status
- runtime backend and dimension
- duration and aggregate statistics

---

## PASS/FAIL/SKIP Policy

각 항목은 아래 중 하나로 기록한다.

- `PASS`
- `FAIL`
- `SKIP`
- `NOT_RUN`
- `CI_REQUIRED`

`SKIP`, `NOT_RUN`, `CI_REQUIRED`는 반드시 이유를 기록한다.

예:

| item | status | reason |
|---|---|---|
| `password_reset_confirm` | `SKIP` | email token not available in automated run |
| `firebase_chat` | `SKIP` | FirebaseMode=skip |
| `onnx_optional_local` | `CI_REQUIRED` | optional ONNX dependencies not installed locally |

mandatory 항목의 이유 없는 `SKIP` 또는 `NOT_RUN`은 전체 regression FAIL이다.

---

## Benchmark Scope

아래 세 범위는 서로 대체되지 않는다.

- Local benchmark: 모델 또는 로컬 Docker path의 controlled measurement
- AWS end-to-end profiling: 실제 통합 서버의 registration latency profile
- Production release regression: release 승인 전 기능/정책/guardrail 확인

local ONNX benchmark가 빨라도 production ONNX 활성화를 의미하지 않는다. ONNX production enablement는 `INFERENCE_RUNTIME_DEPLOYMENT_POLICY.md`의 별도 gate를 통과해야 한다.

---

## Develop To Main Approval Gate

필수 PASS:

- Backend tests
- Python tests
- Optional ONNX CI smoke
- Docker build
- Compose mock smoke
- Production runtime policy
- Profile-first default-off
- No forbidden artifacts/secrets
- Core dog registration regression
- Duplicate detection
- Handover verification
- File serving

환경에 따라 manual PASS 필요:

- real-model E2E
- Firebase enabled chat
- password reset email confirm
- Qdrant/MySQL reconciliation

다음 중 하나라도 있으면 `develop` to `main` 승인 금지:

- mandatory FAIL
- mandatory unexplained SKIP or NOT_RUN
- ONNX production enabled
- YOLO/profile-first production enabled
- mutable image tag
- tracked model/secret artifact
- DB/Qdrant drift
- Python health backend mismatch
- vector dimension mismatch

---

## Deployment Check

서버 배포 전:

- 이 문서의 Static gate와 CI PASS 확인
- `MAIN_RELEASE_SERVER_DEPLOYMENT_CHECKLIST.md`의 production env/image policy 확인
- 실제 server secret/model artifact는 repository 밖에 둔다.
- Firebase enabled chat과 password reset email confirm은 환경이 준비된 경우 manual PASS를 첨부한다.

서버 배포 후:

- Spring actuator health
- Python Embed health
- ApiOnly smoke
- 필요 시 Qdrant/MySQL reconciliation dry-run

Rollback 기준:

- health mismatch
- vector dimension mismatch
- PyTorch runtime이 아닌 backend
- profile-first/YOLO/ONNX production 활성화
- mandatory core flow failure
- DB/Qdrant drift

Rollback은 immutable image tag와 env policy를 이전 known-good 상태로 되돌리는 방식으로 수행하고, MySQL/Qdrant/uploads volume은 삭제하지 않는다.
