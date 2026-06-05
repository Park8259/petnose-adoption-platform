# Main Release Server Deployment Checklist

> 문서 성격: 보조 참고 문서(Task Reference)
>
> `main` release 이미지를 운영 서버에 배포하기 전에 `/opt/petnose` 기준 파일 배치,
> production `.env`, compose 조합, secret 금지 목록, 최종 readiness check를 확인할 때 읽는다.
> active canonical 문서와 충돌하면 active canonical 문서가 우선한다.

---

## Scope

이 문서는 `main` branch release를 서버에서 pull-based로 배포하기 위한 운영 체크리스트다.

- 서버 기준 경로: `/opt/petnose`
- 배포 방식: GHCR image pull + Docker Compose
- Spring profile: `prod`
- Python Embed: dog-nose-identification2 real-model image
- Qdrant collection: `dog_nose_embeddings_real_v2`
- Firebase chat/push: optional layer, production Firebase ON 기준 포함

이 문서는 backend/Python/Flutter runtime behavior, Flyway migration, API contract를 변경하지 않는다.

---

## Required Stabilization Gate

`main` release/server deployment 작업 전에 아래 항목이 `develop`에 반영되어 있어야 한다.

| 항목 | 확인 기준 |
|---|---|
| Canonical docs/schema 정리 | `docs/PROJECT_KNOWLEDGE_INDEX.md`, `docs/PETNOSE_MVP_API_CONTRACT.md`, `docs/db/*` |
| storage rollback cleanup | `docs/reference/STORAGE_AND_VECTOR_BOUNDARY.md`, `docs/reference/OPS_NOTES.md` |
| Qdrant/MySQL reconciliation runbook/script | `docs/reference/QDRANT_RECONCILIATION_RUNBOOK.md`, `scripts/check-qdrant-reference-consistency.ps1` |
| model-analysis raw artifact cleanup | `.gitignore`, `docs/model-analysis/README.md` |
| real-model E2E evidence | `docs/ops-evidence/submission-real-model-e2e-summary.json` |
| CI/CD dog nose v2 release path | `.github/workflows/publish-images.yaml`, `.github/workflows/cd-prod.yaml`, `infra/scripts/deploy-real-model.sh` |
| async password reset email | `docs/reference/OPS_NOTES.md`, `infra/docker/.env.example`, `infra/docker/compose.yaml` |
| manual full feature smoke script | `scripts/manual-full-feature-smoke.ps1`, `docs/reference/MANUAL_FULL_FEATURE_SMOKE.md` |
| API transcript mode | `docs/reference/MANUAL_FULL_FEATURE_SMOKE.md` |
| Firebase enabled chat smoke | `docs/ops-evidence/firebase-chat-release-readiness.md`, `docs/ops-evidence/firebase-chat-smoke-log.md` |

---

## Server Directory Structure

운영 서버에는 아래 구조를 기준으로 파일을 배치한다.

```text
/opt/petnose/
  infra/
    docker/
    nginx/
    scripts/
  models/
    dog_nose_identification2/
      logs/
        s101_224/
          model_final.pth
  secrets/
    firebase-service-account.json
  uploads/
  logs/
  infra/docker/.env
```

권장 권한:

- `/opt/petnose/secrets/firebase-service-account.json`: server operator와 deploy/runtime 계정만 읽기 가능
- `/opt/petnose/infra/docker/.env`: server operator와 deploy/runtime 계정만 읽기 가능
- `/opt/petnose/models/dog_nose_identification2`: deploy/runtime 계정 read-only
- `/opt/petnose/uploads`: Docker volume 또는 runtime upload path로 관리
- `/opt/petnose/logs`: 운영 로그 보관 위치

---

## Files To Upload To Server

서버에 직접 올리지만 GitHub에 올리지 않는 파일:

| 서버 파일 | 위치 | 비고 |
|---|---|---|
| Firebase Admin SDK service account JSON | `/opt/petnose/secrets/firebase-service-account.json` | Firebase Admin SDK server-only credential |
| dog nose model checkpoint | `/opt/petnose/models/dog_nose_identification2/logs/s101_224/model_final.pth` | real-model runtime 필수 |
| production `.env` | `/opt/petnose/infra/docker/.env` | secret 포함 가능, repository commit 금지 |
| optional SMTP credential | `.env` 또는 server secret store | password reset email을 켤 때만 필요 |

GitHub에서 서버로 배치해야 하는 non-secret 운영 파일:

- `infra/docker/compose.yaml`
- `infra/docker/compose.prod.yaml`
- `infra/docker/compose.prod-real-model.yaml`
- `infra/docker/compose.firebase.yaml`
- `infra/nginx/**`
- `infra/scripts/deploy-real-model.sh`
- `scripts/verify-server-release-readiness.ps1`

---

## Never Commit

아래 파일은 절대 GitHub에 올리지 않는다.

- 실제 `infra/docker/.env`
- `.env`, `.env.*` 단, `.env.example` 제외
- `firebase-service-account.json`
- `firebase-service-account*.json`
- `*-firebase-adminsdk-*.json`
- `serviceAccountKey*.json`
- `model_final.pth`
- `*.pt`, `*.pth`, `*.ckpt`, `*.onnx`, `*.h5`, `*.keras`, `*.safetensors`
- raw dog image fixtures
- raw Qdrant vector/payload dumps
- DB/JWT/SMTP/GHCR/Firebase private key 값

문서, PR 본문, screenshot, smoke evidence에도 secret 원문을 넣지 않는다.

---

## Production Env Template

아래 template을 서버의 `/opt/petnose/infra/docker/.env`에 작성한다. 실제 값은 서버에서만 채우고 repository에 커밋하지 않는다.

```dotenv
APP_ENV=prod
SPRING_PROFILES_ACTIVE=prod

SPRING_API_IMAGE=ghcr.io/jaaesung/petnose-spring-api:main-<sha7>
PYTHON_EMBED_REAL_IMAGE=ghcr.io/jaaesung/petnose-python-embed-real:main-<sha7>

MYSQL_DATABASE=petnose
MYSQL_USER=petnose
MYSQL_PASSWORD=<set-strong-secret>
MYSQL_ROOT_PASSWORD=<set-strong-root-secret>
SPRING_DATASOURCE_URL=jdbc:mysql://mysql:3306/petnose?useSSL=false&allowPublicKeyRetrieval=true&characterEncoding=UTF-8
SPRING_DATASOURCE_USERNAME=petnose
SPRING_DATASOURCE_PASSWORD=<same-as-MYSQL_PASSWORD>

AUTH_JWT_SECRET=<set-strong-32byte-or-longer-secret>
AUTH_JWT_ACCESS_TOKEN_TTL_SECONDS=3600

EMBED_MODEL=dog-nose-identification2
EMBED_VECTOR_DIM=2048
PYTHON_EMBED_INSTALL_REAL_DEPS=1
DOG_NOSE_MODEL_DIR_HOST=/opt/petnose/models/dog_nose_identification2

QDRANT_COLLECTION=dog_nose_embeddings_real_v2
QDRANT_VECTOR_DIM=2048
QDRANT_DISTANCE=Cosine

FIREBASE_ENABLED=true
PETNOSE_INCLUDE_FIREBASE=true
FIREBASE_PROJECT_ID=petnose-c6ec5
FIREBASE_CREDENTIALS_HOST_PATH=/opt/petnose/secrets/firebase-service-account.json

AUTH_PASSWORD_RESET_EMAIL_ENABLED=<true-or-false>
AUTH_PASSWORD_RESET_EXPOSE_TOKEN_IN_RESPONSE=false
AUTH_PASSWORD_RESET_URL_TEMPLATE=https://<app-domain>/password-reset?token={token}
AUTH_PASSWORD_RESET_MAIL_FROM=no-reply@<domain>
MAIL_HOST=<smtp-host>
MAIL_PORT=587
MAIL_USERNAME=<smtp-user>
MAIL_PASSWORD=<smtp-password>
MAIL_SMTP_AUTH=true
MAIL_SMTP_STARTTLS_ENABLE=true
MAIL_SMTP_CONNECTION_TIMEOUT_MS=5000
MAIL_SMTP_TIMEOUT_MS=3000
MAIL_SMTP_WRITE_TIMEOUT_MS=5000
MANAGEMENT_HEALTH_MAIL_ENABLED=false

NGINX_PORT=80
UPLOAD_BASE_PATH=/var/uploads
MAX_UPLOAD_SIZE_MB=20
```

Production guardrails:

- `SPRING_API_IMAGE`와 `PYTHON_EMBED_REAL_IMAGE`는 `main-<sha7>` immutable tag로 고정한다.
- `AUTH_PASSWORD_RESET_EXPOSE_TOKEN_IN_RESPONSE=false`를 유지한다.
- `MYSQL_PASSWORD`와 `SPRING_DATASOURCE_PASSWORD`는 같은 값이어야 한다.
- `FIREBASE_CREDENTIALS_HOST_PATH`는 repository 밖의 server-only JSON을 가리켜야 한다.
- SMTP를 사용하지 않으면 `AUTH_PASSWORD_RESET_EMAIL_ENABLED=false`로 두고 SMTP secret을 비워도 된다.

---

## Compose Combination

Production real-model + Firebase ON config 검증:

```bash
docker compose --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.prod.yaml \
  -f infra/docker/compose.prod-real-model.yaml \
  -f infra/docker/compose.firebase.yaml \
  config
```

Image pull:

```bash
docker compose --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.prod.yaml \
  -f infra/docker/compose.prod-real-model.yaml \
  -f infra/docker/compose.firebase.yaml \
  pull
```

Start runtime:

```bash
docker compose --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.prod.yaml \
  -f infra/docker/compose.prod-real-model.yaml \
  -f infra/docker/compose.firebase.yaml \
  up -d
```

실제 운영에서는 `infra/scripts/deploy-real-model.sh --firebase`를 사용하면 동일한 production path를 더 안전하게 실행할 수 있다. 이 script는 config, pull, up, healthcheck를 fail-fast로 수행한다.

---

## Readiness Check Script

서버에서 배포 전 아래를 실행한다.

```powershell
pwsh ./scripts/verify-server-release-readiness.ps1 `
  -EnvFile infra/docker/.env `
  -IncludeFirebase
```

배포 후 healthcheck까지 포함하려면:

```powershell
pwsh ./scripts/verify-server-release-readiness.ps1 `
  -EnvFile infra/docker/.env `
  -IncludeFirebase `
  -HealthCheck `
  -HealthUrl http://localhost/actuator/health
```

Script가 확인하는 항목:

- env file 존재
- required env key 존재
- Firebase enabled일 때 service account JSON path와 JSON 구조
- real-model directory와 `logs/s101_224/model_final.pth`
- Docker daemon, Docker Compose version
- production compose config
- optional healthcheck
- `.env`, service account JSON, model checkpoint가 git tracked 상태가 아닌지
- result summary

---

## Deployment Checklist

Pre-deploy:

- [ ] `develop` stabilization gate PASS
- [ ] `main-<sha7>` image tags published for Spring API and Python Embed Real
- [ ] GHCR package visibility or server docker login ready
- [ ] `/opt/petnose/infra/docker/.env` created with production values
- [ ] `/opt/petnose/secrets/firebase-service-account.json` uploaded
- [ ] `/opt/petnose/models/dog_nose_identification2/logs/s101_224/model_final.pth` uploaded
- [ ] `scripts/verify-server-release-readiness.ps1 -IncludeFirebase` PASS
- [ ] App team received only `docs/reference/APP_TEAM_PRODUCTION_HANDOFF.md` allowed handoff items

Deploy:

- [ ] Run `bash infra/scripts/deploy-real-model.sh --firebase`
- [ ] Confirm `docker compose ps`
- [ ] Confirm `http://localhost/actuator/health`
- [ ] Confirm Python model health through internal or Nginx-routed check if exposed
- [ ] Confirm Qdrant collection `dog_nose_embeddings_real_v2`, dimension `2048`, distance `Cosine`

Post-deploy:

- [ ] Run API smoke suitable for production data policy
- [ ] Run Firebase chat smoke with sanitized evidence
- [ ] Run Qdrant/MySQL reconciliation dry-run after real-model smoke
- [ ] Store evidence without tokens, private keys, raw images, raw vectors, or full Qdrant payloads

---

## Rollback

Firebase rollback:

- Remove `infra/docker/compose.firebase.yaml` from compose invocation, or set `FIREBASE_ENABLED=false`.
- Keep MySQL as source of truth.
- Firestore snapshots can remain ignored or be cleaned under a separate operational policy.

Release rollback:

- Pin `SPRING_API_IMAGE` and `PYTHON_EMBED_REAL_IMAGE` back to the previous known-good `main-<sha7>` tag.
- Re-run compose `config`, `pull`, and `up -d`.
- Re-run healthcheck and sanitized smoke.

Do not delete MySQL/Qdrant/uploads volumes during release rollback unless there is a separate approved data recovery plan.
