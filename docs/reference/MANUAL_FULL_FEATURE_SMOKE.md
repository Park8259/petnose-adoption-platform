# Manual Full Feature Smoke

## 목적

`scripts/manual-full-feature-smoke.ps1`는 로컬, 개발 서버, 또는 운영 서버 API에서 PetNose MVP의 주요 사용자 흐름을 사람이 한 번에 확인하기 위한 PowerShell 7 smoke script다.

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

Firebase enabled chat까지 검증하려면 server runtime에는 Firebase service account JSON이 필요하다. Android/Flutter 앱용 `google-services.json`은 클라이언트 설정 파일이며, Spring server의 Firebase Admin 인증에는 사용하지 않는다. 예를 들어 service account는 `C:\Dev\secrets\petnose-firebase-service-account.json`처럼 repository 밖에 둔다.

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
- `ApiTranscriptPath`: `docs/ops-evidence/manual-full-feature-smoke-local/api-transcript.md`
- `ApiTranscriptJsonPath`: `docs/ops-evidence/manual-full-feature-smoke-local/api-transcript.json`
- `ApiTranscriptDetail`: `body`
- `ComposeProjectName`: `petnose`

`manual-full-feature-smoke-local/` 디렉터리는 gitignore 대상이다.

## 운영 서버 API smoke

운영 서버처럼 내부 Qdrant/Python Embed/MySQL에 직접 접근하면 안 되는 대상은 `-ApiOnly`와 `-SkipInternalPreflight`를 사용한다. 이 mode는 외부 HTTP API만 호출하며 다음 검증을 생략한다.

- Python Embed 직접 health check
- Qdrant 직접 health/collection check
- initial DB zero count check
- initial Qdrant active point zero check
- Qdrant/MySQL reconciliation
- dev-only `/api/dev/ping` check

`-ApiOnly`에서는 `-ResetRuntimeData`, `-StartRuntime`, `-StopRuntimeAfter`를 사용할 수 없다. 운영 서버 데이터 삭제나 compose lifecycle 제어 옵션은 절대 사용하지 않는다. `-RunReconciliation`은 기본 skip이며, 명시적으로 `-RunReconciliation:$false`를 넘기는 것을 권장한다.

운영 서버 실행 예시:

```powershell
pwsh -NoProfile -File .\scripts\manual-full-feature-smoke.ps1 `
  -ApiOnly `
  -SkipInternalPreflight `
  -RootUrl "http://15.164.211.50" `
  -BaseUrl "http://15.164.211.50/api" `
  -NoseImageDir "C:\Users\jaesung\Desktop\dog_nose\ddubi" `
  -PasswordResetMode skip `
  -FirebaseMode enabled `
  -FcmToken "manual-smoke-fcm-token" `
  -RunReconciliation:$false `
  -WriteEvidence `
  -WriteApiTranscript `
  -PrintApiTranscript `
  -ApiTranscriptDetail body `
  -AllowAmbiguousHandover
```

`-FirebaseMode enabled`에서는 `/api/firebase/custom-token`이 `FIREBASE_DISABLED`를 반환하면 실패로 처리한다. enabled smoke는 Firebase Admin runtime이 실제로 켜진 서버에서만 PASS해야 한다.

## Dedicated compose project 실행

기존 로컬 `petnose` stack이나 host port `3306`을 건드리지 않고 검증하려면 별도 compose project와 temp env를 사용한다. 예를 들어 temp env에서 `NGINX_PORT=8088`, `SPRING_APP_PORT=18080`, `PYTHON_EMBED_PORT=18000`, `QDRANT_PORT=16333`, `MYSQL_PORT=13306`으로 override한다.

주의: 현재 compose에서 `QDRANT_PORT`는 host port mapping과 Spring 내부 접속 port에 함께 쓰인다. Host에는 `16333`을 열되 Spring 컨테이너가 내부 service `qdrant:6333`으로 붙게 하려면 temp compose override를 하나 더 둔다.

```yaml
# C:\tmp\petnose-manual-full-smoke\compose.qdrant-internal.yml
services:
  spring-api:
    environment:
      QDRANT_HOST: qdrant
      QDRANT_PORT: "6333"
```

그 다음 아래처럼 실행한다.

```powershell
$SmokeDir = "C:\tmp\petnose-manual-full-smoke"
$TempEnv = Join-Path $SmokeDir ".env"
$ComposeFiles = @(
  "infra/docker/compose.yaml",
  "infra/docker/compose.dev.yaml",
  "infra/docker/compose.real-model.yaml",
  "C:\tmp\petnose-manual-full-smoke\compose.qdrant-internal.yml"
)

pwsh -NoProfile -File .\scripts\manual-full-feature-smoke.ps1 `
  -RootUrl "http://localhost:8088" `
  -BaseUrl "http://localhost:8088/api" `
  -QdrantUrl "http://localhost:16333" `
  -PythonEmbedUrl "http://localhost:18000" `
  -NoseImageDir "C:\Users\jaesung\Desktop\dog_nose\ddubi" `
  -PasswordResetMode skip `
  -FirebaseMode auto `
  -RunReconciliation `
  -WriteEvidence `
  -WriteApiTranscript `
  -PrintApiTranscript `
  -ApiTranscriptDetail body `
  -AllowAmbiguousHandover `
  -ResetRuntimeData `
  -StartRuntime `
  -StopRuntimeAfter `
  -EnvFile $TempEnv `
  -ComposeProjectName "petnose_manual_smoke" `
  -ComposeFile ($ComposeFiles -join ";") `
  -MysqlService "mysql"
```

`manual-full-feature-smoke.ps1`의 `ComposeProjectName` 기본값은 `petnose`다. Dedicated 검증에서는 반드시 `petnose_manual_smoke`처럼 별도 project name을 넘겨 기존 로컬 stack과 볼륨을 분리한다. Script가 실행하는 compose lifecycle, MySQL side-effect check, reconciliation 호출은 모두 `docker compose -p <ComposeProjectName>` 기준으로 동작한다. `check-qdrant-reference-consistency.ps1`는 독립 실행 시 기존처럼 `ComposeProjectName`을 생략할 수 있고, smoke script가 호출할 때는 동일한 project name을 전달한다.

`pwsh -File`로 다른 PowerShell process를 열어 실행할 때는 array parameter가 안전하게 전달되지 않을 수 있다. 그런 경우 위 예시처럼 `-ComposeFile ($ComposeFiles -join ";")` 또는 `-ComposeFile "infra/docker/compose.yaml;infra/docker/compose.dev.yaml;infra/docker/compose.real-model.yaml"`처럼 semicolon-separated string으로 넘긴다.

`-ComposeFile $ComposeFiles`처럼 array를 그대로 넘기면 두 번째 compose 파일 값이 positional parameter로 흘러 `NoseImageExtension` validation 오류가 날 수 있다. `infra/docker/compose.dev.yaml`이 `auto,jpg,jpeg,png` 중 하나가 아니라는 오류가 보이면 compose 파일 목록을 semicolon-separated string으로 전달했는지 먼저 확인한다.

## Clean runtime 검증

`-ResetRuntimeData`는 smoke 시작 전에 `docker compose -p <ComposeProjectName> ... down -v`를 실행한다. `-StartRuntime`은 이어서 `up -d --build`를 실행하고 Spring, Python Embed, Qdrant health가 준비될 때까지 기다린다. `-StopRuntimeAfter`는 성공/실패와 관계없이 끝에서 `down -v`를 실행한다.

Clean run은 smoke fixture를 만들기 전에 아래 값을 확인하고 summary에 기록한다.

- MySQL: `users`, `dogs`, `dog_images`, `dog_nose_references`, `verification_logs`, `adoption_posts`, `adoption_post_likes`
- Qdrant: `is_active=true` point count

각 값은 `0`이어야 한다. 초기 `dogs` 또는 Qdrant active point가 남아 있으면 fixture 중복/오염 가능성이 있으므로 실패한다. Dedicated project에서만 `-ResetRuntimeData`를 사용하는 것을 권장한다.

## API transcript mode

`-PrintApiTranscript`는 각 scenario가 끝날 때 sanitized API transcript를 console에 출력한다. `-WriteApiTranscript`는 아래 파일을 생성한다.

- `docs/ops-evidence/manual-full-feature-smoke-local/api-transcript.md`
- `docs/ops-evidence/manual-full-feature-smoke-local/api-transcript.json`

JSON transcript는 API 호출별 array이며 각 item은 다음 shape를 가진다.

- `index`, `scenario`, `name`, `method`, `url`, `path`
- `auth`: bearer token 사용 여부
- `request`: `content_type`, sanitized `body`/`fields`, multipart `files` (`basename`, `size_bytes`, `sha256`, `content_type`), full mode의 `curl`
- `response`: `status`, sanitized `body`
- `assertions`: `status`, `description`, `expected`, `actual`
- `result`: `PASS`, `SKIP`, `EXPECTED_DISABLED`, `FAIL`

`-ApiTranscriptDetail summary`는 method/path/status/assertion 중심으로 기록한다. `body`는 sanitized request summary와 response body를 포함한다. `full`은 `body`에 sanitized curl-style request 예시를 추가한다. `-MaxTranscriptBodyChars`는 request/response body text를 제한한다.

기본적으로 transcript는 fixture ID 성격의 `user_id`, `dog_id`, `post_id`, `room_id`, `message_id`를 redaction한다. `-ShowFixtureIds`를 켜면 fixture ID는 보이지만 JWT, password/current password/new password, reset token, Firebase custom token, FCM token은 항상 redaction된다. Raw image content, vector, full Qdrant payload는 기록하지 않는다.

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
- `FIREBASE_CREDENTIALS_HOST_PATH`
- `infra/docker/compose.firebase.yaml` compose override
- service account JSON은 repository 밖에 보관
- `AUTH_PASSWORD_RESET_EMAIL_ENABLED=false` 또는 SMTP secret 준비

Dedicated compose project에서 Firebase enabled chat까지 검증하는 예시는 아래와 같다. Host port `3306`이 이미 사용 중이면 temp env에서 `MYSQL_PORT=13306`처럼 다른 port를 지정한다.

```powershell
$SmokeDir = "C:\tmp\petnose-manual-full-smoke"
$TempEnv = Join-Path $SmokeDir ".env"
$ComposeFiles = @(
  "infra/docker/compose.yaml",
  "infra/docker/compose.dev.yaml",
  "infra/docker/compose.real-model.yaml",
  "infra/docker/compose.firebase.yaml",
  "C:\tmp\petnose-manual-full-smoke\compose.qdrant-internal.yml"
)

pwsh -NoProfile -File .\scripts\manual-full-feature-smoke.ps1 `
  -RootUrl "http://localhost:8088" `
  -BaseUrl "http://localhost:8088/api" `
  -QdrantUrl "http://localhost:16333" `
  -PythonEmbedUrl "http://localhost:18000" `
  -NoseImageDir "C:\Users\jaesung\Desktop\dog_nose\ddubi" `
  -PasswordResetMode skip `
  -FirebaseMode enabled `
  -FcmToken "<local-test-fcm-token>" `
  -RunReconciliation `
  -WriteEvidence `
  -WriteApiTranscript `
  -ApiTranscriptDetail body `
  -AllowAmbiguousHandover `
  -ResetRuntimeData `
  -StartRuntime `
  -StopRuntimeAfter `
  -EnvFile $TempEnv `
  -ComposeProjectName "petnose_manual_smoke" `
  -ComposeFile ($ComposeFiles -join ";") `
  -QdrantCollection "dog_nose_embeddings_real_v2" `
  -ExpectedVectorDimension 2048 `
  -ExpectedDistance "Cosine"
```

`FcmToken`을 생략하면 placeholder token을 사용한다. 이 경우 FCM token 저장 API까지 검증하지만 실제 push delivery는 검증하지 않는다.

`-FirebaseMode enabled`에서는 Firebase disabled 응답을 성공으로 취급하지 않는다. `/api/firebase/custom-token`이 `FIREBASE_DISABLED`를 반환하면 enabled smoke는 실패해야 한다.

Firestore Console에서 side effect를 확인할 때는 다음 collection path를 보면 된다.

- 채팅방: `chat_rooms/{room_id}`
- 메시지: `chat_rooms/{room_id}/messages/{message_id}`
- FCM 토큰: `user_devices/{firebase_uid}/tokens/{tokenHash}`

기본 transcript는 fixture ID도 redaction한다. Firestore Console 조회를 위해 local-only evidence에 ID가 필요하면 별도 실행에서 `-ShowFixtureIds`와 별도 `-ApiTranscriptPath`/`-ApiTranscriptJsonPath`를 사용한다. `-ShowFixtureIds`를 켜도 Firebase custom token, FCM token, password, reset token은 항상 redaction된다.

Evidence에는 Firebase custom token, FCM token, service account path/content를 저장하지 않는다. Service account JSON과 `.env`는 커밋하지 않는다.

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

`-WriteApiTranscript`를 사용하면 아래 파일을 추가 생성한다.

- `docs/ops-evidence/manual-full-feature-smoke-local/api-transcript.md`
- `docs/ops-evidence/manual-full-feature-smoke-local/api-transcript.json`

저장하는 항목:

- checked time
- base/runtime URL
- health summary
- fixture basename/count/SHA-256 hash
- scenario PASS/SKIP/FAIL
- ID present marker
- 초기 DB row count와 Qdrant active point count. `-ApiOnly`에서는 skip으로 기록
- sanitized API method/path/status/request/response/assertion transcript
- sanitized reconciliation counts. `-ApiOnly`에서는 skip으로 기록

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
- `-ShowFixtureIds`가 없을 때 fixture `user_id`/`dog_id`/`post_id`/`room_id`/`message_id`

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
| `SkipInternalPreflight` | Python Embed/Qdrant 직접 health/collection check 생략 |
| `ApiOnly` | 운영 서버용 API-only mode. 내부 preflight, 초기 zero check, reconciliation, compose control 생략/금지 |
| `RunReconciliation` | Qdrant/MySQL 정합성 점검 실행 여부 |
| `WriteEvidence` | sanitized summary JSON/Markdown 저장 |
| `PrintApiTranscript` | sanitized API transcript를 console에 출력 |
| `WriteApiTranscript` | sanitized API transcript Markdown/JSON 저장 |
| `ApiTranscriptPath` | transcript Markdown 출력 경로 |
| `ApiTranscriptJsonPath` | transcript JSON 출력 경로 |
| `ApiTranscriptDetail` | `summary`, `body`, `full` |
| `MaxTranscriptBodyChars` | transcript body 최대 문자 수 |
| `ShowFixtureIds` | fixture ID redaction 해제. token/password 계열은 항상 redaction |
| `StopOnOptionalFailure` | optional Firebase/DB side-effect 실패도 전체 실패로 처리 |
| `AllowAmbiguousHandover` | handover `AMBIGUOUS`를 warning pass로 허용 |
| `ResetRuntimeData` | 시작 전 dedicated compose project를 `down -v`로 초기화 |
| `StartRuntime` | 시작 전 compose runtime을 `up -d --build`로 실행 |
| `StopRuntimeAfter` | 종료 시 compose runtime을 `down -v`로 정리 |
| `ComposeProjectName` | dedicated compose project의 MySQL/reconciliation 조회에 사용할 project name |

자세한 사용법은 다음 명령으로 확인한다.

```powershell
pwsh ./scripts/manual-full-feature-smoke.ps1 -Help
```
