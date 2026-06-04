# Manual Full Feature Smoke

## 목적

`scripts/manual-full-feature-smoke.ps1`는 로컬 또는 개발 서버 runtime에서 PetNose MVP의 주요 사용자 흐름을 사람이 한 번에 확인하기 위한 PowerShell 7 smoke script다.

검증 범위는 회원가입, 로그인, 내 정보, 프로필/프로필 이미지, 비밀번호 변경, 선택적 비밀번호 재설정, 강아지 등록, 내 강아지 조회, 분양글 생성, 공개 목록/상세 privacy, 좋아요, 선택적 Firebase chat, 인도 시점 비문 확인, 입양 완료, 내가 입양한 강아지 목록, 파일 서빙, Qdrant/MySQL reconciliation이다.

이 script는 backend Java runtime code, Python Embed runtime code, Flutter code, Flyway migration, API behavior를 변경하지 않는다.

## 사전 준비

- PowerShell 7 (`pwsh`)
- 로컬 또는 개발 서버 PetNose runtime
- Spring Boot health: `http://localhost/actuator/health`
- Python Embed health: `http://localhost:8000/health`
- Qdrant health: `http://localhost:6333/healthz`
- 기본 real-model collection: `dog_nose_embeddings_real_v2`
- 등록용 nose image `1.jpg`부터 `5.jpg` 또는 `1.png`부터 `5.png`
- 인도 확인용 nose image `6.jpg` 또는 `6.png`
- 파일은 repository 밖의 로컬 디렉터리에 두는 것을 권장한다.

real-model Docker runtime에서는 `infra/docker/.env`를 실제 값으로 준비하고, 모델 checkpoint는 repository 밖 경로에 mount한다. SMTP와 Firebase는 optional이다.

## 기본 실행

```powershell
pwsh ./scripts/manual-full-feature-smoke.ps1 `
  -NoseImageDir "C:\Users\jaesung\Desktop\dog_nose\ddubi" `
  -PasswordResetMode skip `
  -FirebaseMode auto `
  -RunReconciliation `
  -WriteEvidence
```

기본값:

- `BaseUrl`: `http://localhost/api`
- `RootUrl`: `http://localhost`
- `QdrantUrl`: `http://localhost:6333`
- `PythonEmbedUrl`: `http://localhost:8000`
- `RegisterNoseImageCount`: `5`
- `HandoverImageIndex`: `6`
- `OutputDir`: `docs/ops-evidence/manual-full-feature-smoke-local`
- `SummaryPath`: `docs/ops-evidence/manual-full-feature-smoke-local/summary.json`

`manual-full-feature-smoke-local/` 디렉터리는 gitignore 대상이다.

## ddubi 예시

`-NoseImageDir "C:\Users\jaesung\Desktop\dog_nose\ddubi"` 아래에 다음 파일을 둔다.

| 용도 | 파일 |
|---|---|
| dog registration | `1.jpg` - `5.jpg` |
| handover verification | `6.jpg` |

확장자는 `jpg`, `jpeg`, `png`를 지원한다. `-NoseImageExtension auto`가 기본값이며, 각 index에 대해 존재하는 파일을 찾는다.

## Firebase disabled 테스트

Firebase 설정 없이 Spring 인증 이후 chat API가 `503`과 `FIREBASE_DISABLED`를 반환하면 disabled runtime 검증은 PASS다.

```powershell
pwsh ./scripts/manual-full-feature-smoke.ps1 `
  -NoseImageDir "C:\Users\jaesung\Desktop\dog_nose\ddubi" `
  -FirebaseMode disabled
```

`-FirebaseMode auto`는 먼저 Firebase custom token endpoint를 호출한다. `FIREBASE_DISABLED`이면 disabled PASS로 처리하고, 정상 custom token이 반환되면 enabled flow를 계속 진행한다.

## Firebase enabled 테스트

enabled mode는 아래 환경이 준비된 runtime에서만 사용한다.

- `FIREBASE_ENABLED=true`
- `FIREBASE_PROJECT_ID`
- `FIREBASE_CREDENTIALS_HOST_PATH` 또는 Firebase compose override
- service account JSON은 repository 밖에 보관
- 필요 시 `infra/docker/compose.firebase.yaml` 포함

```powershell
pwsh ./scripts/manual-full-feature-smoke.ps1 `
  -NoseImageDir "C:\Users\jaesung\Desktop\dog_nose\ddubi" `
  -FirebaseMode enabled `
  -FcmToken "<local-test-fcm-token>"
```

`FcmToken`을 생략하면 placeholder token을 사용한다. 이 경우 FCM token 저장 API까지 검증하지만 실제 push delivery는 검증하지 않는다.

Evidence에는 Firebase custom token, FCM token, service account path/content를 저장하지 않는다.

## Password reset 테스트

`-PasswordResetMode skip`은 reset flow를 실행하지 않는다.

`-PasswordResetMode dev-exposed`는 local/shared dev 전용이다. runtime에 `AUTH_PASSWORD_RESET_EXPOSE_TOKEN_IN_RESPONSE=true`가 켜져 있어야 하며, script가 `reset_token`을 받아 confirm과 login까지 자동 검증한다. 운영에서는 이 값을 false로 유지한다.

`-PasswordResetMode email`은 request까지 자동 호출한다. 이메일로 받은 reset token을 prompt에 입력하면 confirm과 login까지 검증하고, Enter만 누르면 request-email-sent PASS와 confirm skip으로 기록한다.

모든 mode에서 reset token 원문은 evidence에 저장하지 않는다.

## 결과 해석

주요 PASS 기준:

- dog registration: `registration_allowed=true`, `REGISTERED`, `VERIFIED`, `COMPLETED`, `MULTI_REFERENCE`, `reference_count=5`
- handover: 기본은 `MATCHED`와 `matched=true`
- adoption completion: post `COMPLETED`, `adopter_user_id` 저장, `adopted_at` 존재, dog `ADOPTED`
- reconciliation: `consistent=true`, missing/orphan/payload mismatch count `0`

`-AllowAmbiguousHandover`를 사용하면 handover `AMBIGUOUS`를 warning note와 함께 통과시킬 수 있다. `NOT_MATCHED` 또는 `NO_MATCH_CANDIDATE`는 기본 실패다.

Duplicate suspected가 발생하면 같은 nose fixture가 이미 같은 runtime에 등록되어 있을 가능성이 높다. 반복 실행 전에는 로컬 runtime 데이터를 초기화하거나 다른 fixture를 사용한다.

## Evidence와 redaction

`-WriteEvidence`를 사용하면 아래 파일을 생성한다.

- `docs/ops-evidence/manual-full-feature-smoke-local/summary.json`
- `docs/ops-evidence/manual-full-feature-smoke-local/summary.md`
- reconciliation 실행 시 `docs/ops-evidence/manual-full-feature-smoke-local/reconciliation-summary.json`

저장하는 항목:

- checked time
- base/runtime URL
- health summary
- fixture basename/count/SHA-256 hash
- scenario PASS/SKIP/FAIL
- ID present marker
- sanitized reconciliation counts

저장하지 않는 항목:

- JWT access token
- password/current password/new password
- reset token
- Firebase custom token
- FCM token
- service account path/content
- raw dog image
- raw vector
- full Qdrant payload dump
- `.env` 내용

## 보안 주의

- `.env` 파일을 커밋하지 않는다.
- raw token/password/vector/image를 evidence에 남기지 않는다.
- Firebase service account JSON을 repository 안에 두지 않는다.
- SMTP password와 Firebase credential은 서버/CI secret 또는 로컬 비공개 파일로만 주입한다.
- `manual-full-feature-smoke-local/` 아래 결과물은 로컬 증적이며 커밋 대상이 아니다.

## 주요 파라미터

| 파라미터 | 설명 |
|---|---|
| `BaseUrl` | API base URL. 기본 `http://localhost/api` |
| `RootUrl` | actuator/file serving root. 기본 `http://localhost` |
| `QdrantUrl` | Qdrant URL. 기본 `http://localhost:6333` |
| `PythonEmbedUrl` | Python Embed URL. 기본 `http://localhost:8000` |
| `NoseImageDir` | `1`부터 `6`까지 indexed image가 있는 디렉터리 |
| `PasswordResetMode` | `skip`, `dev-exposed`, `email` |
| `FirebaseMode` | `skip`, `disabled`, `enabled`, `auto` |
| `RunReconciliation` | Qdrant/MySQL 정합성 점검 실행 여부 |
| `WriteEvidence` | sanitized summary JSON/Markdown 저장 |
| `StopOnOptionalFailure` | optional Firebase/DB side-effect 실패도 전체 실패로 처리 |
| `AllowAmbiguousHandover` | handover `AMBIGUOUS`를 warning pass로 허용 |

자세한 사용법은 다음 명령으로 확인한다.

```powershell
pwsh ./scripts/manual-full-feature-smoke.ps1 -Help
```
