# 운영 메모

> 문서 성격: 보조 참고 문서(Task Reference)
>
> local/dev 운영, compose, health check, GHCR/CD 절차를 확인할 때 읽는다.
> active canonical 문서와 충돌하면 active canonical 문서가 우선한다.

---

## 환경 구분

- `local dev`: 개인 PC 개발/디버깅 (`compose.dev`)
- `shared dev`: 팀 공용 서버 검증 (`cd-dev.yaml`)
- `prod`: 발표/시연용 수동 배포 (`cd-prod.yaml`)

---

## 로컬 실행

> **사전 조건:** Docker Desktop, Docker Compose v2  
> 백엔드를 직접 빌드/테스트하려면 **Java 21** 필요 (`java -version` 확인).

> **env/secrets 전략 전체**: [ENV_STRATEGY.md](ENV_STRATEGY.md) 참고.
> `.env.example`의 `[SECRET]` 항목(`MYSQL_PASSWORD`, `MYSQL_ROOT_PASSWORD`, `SPRING_DATASOURCE_PASSWORD`)은  
> 반드시 실제 값으로 교체하고 `MYSQL_PASSWORD`와 `SPRING_DATASOURCE_PASSWORD`는 동일하게 유지하세요.

### 비밀번호 재설정 이메일 설정

기본 runtime은 비밀번호 재설정 token을 response에 노출하지 않고 이메일 발송도 비활성화한다.
운영에서 reset link 이메일 발송을 사용하려면 `AUTH_PASSWORD_RESET_EMAIL_ENABLED=true`와 SMTP 환경변수를 함께 설정한다.

```dotenv
AUTH_PASSWORD_RESET_EXPOSE_TOKEN_IN_RESPONSE=false
AUTH_PASSWORD_RESET_EMAIL_ENABLED=false
AUTH_PASSWORD_RESET_URL_TEMPLATE=http://localhost:3000/password-reset?token={token}
AUTH_PASSWORD_RESET_MAIL_FROM=no-reply@petnose.local
AUTH_PASSWORD_RESET_MAIL_SUBJECT=[PetNose] 비밀번호 재설정 안내

MAIL_HOST=
MAIL_PORT=587
MAIL_USERNAME=
MAIL_PASSWORD=
MAIL_SMTP_AUTH=true
MAIL_SMTP_STARTTLS_ENABLE=true
MAIL_SMTP_CONNECTION_TIMEOUT_MS=5000
MAIL_SMTP_TIMEOUT_MS=3000
MAIL_SMTP_WRITE_TIMEOUT_MS=5000
MANAGEMENT_HEALTH_MAIL_ENABLED=false
```

주의:

- 운영에서는 `AUTH_PASSWORD_RESET_EXPOSE_TOKEN_IN_RESPONSE=false`를 유지한다.
- `MAIL_PASSWORD` 실제 값은 repository에 절대 커밋하지 않고 서버/CI 환경변수 또는 secret store로만 주입한다.
- 비밀번호 재설정 이메일은 optional 기능이므로 `MANAGEMENT_HEALTH_MAIL_ENABLED=false`가 기본값이다. SMTP 연결 상태를 서비스 health에 포함해야 하는 런타임에서만 true로 설정한다.
- `AUTH_PASSWORD_RESET_EMAIL_ENABLED`는 reset link 발송 여부이고, `MANAGEMENT_HEALTH_MAIL_ENABLED`는 Actuator mail health 포함 여부다. 두 값은 별도 정책으로 관리한다.
- SMTP username/password, service account, reset token 값은 로그, PR 본문, evidence에 남기지 않는다.
- reset token은 로그인 비밀번호가 아니라 `POST /api/auth/password-reset/confirm`에서 새 비밀번호 설정에만 사용하는 1회성 secret이다.

### MySQL 포트 충돌 해결

로컬에 MySQL이 3306으로 실행 중이면 컨테이너 포트 충돌이 발생합니다.  
`infra/docker/.env`에서 `MYSQL_PORT=3307`로 변경하면 해결됩니다:

```dotenv
MYSQL_PORT=3307
```

### Linux / macOS (bash)

```bash
# 1. 환경변수 파일 준비 (최초 1회)
cp infra/docker/.env.example infra/docker/.env

# 2. 서비스 기동 (--build 포함)
bash infra/scripts/dev-up.sh

# 3. 상태 확인
bash infra/scripts/healthcheck.sh

# 4. 서비스 종료
bash infra/scripts/dev-down.sh
```

### Windows (PowerShell)

```powershell
# 1. 환경변수 파일 준비 (최초 1회)
Copy-Item infra\docker\.env.example infra\docker\.env

# 2. 서비스 기동
.\infra\scripts\dev-up.ps1

# 3. 서비스 종료
.\infra\scripts\dev-down.ps1
```

---

## 직접 compose 명령

```bash
# 기동
docker compose \
  --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.dev.yaml \
  up -d --build

# 종료
docker compose \
  --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.dev.yaml \
  down
```

---

## 로그 확인

```bash
# 전체 로그 (최근 100줄)
docker compose \
  --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.dev.yaml \
  logs --tail=100

# 특정 서비스 로그 (실시간)
docker compose ... logs -f spring-api
docker compose ... logs -f python-embed
docker compose ... logs -f nginx
docker compose ... logs -f mysql
```

---

## Health Check 확인 위치

| 서비스 | 주소 | 비고 |
|---|---|---|
| Nginx | `http://localhost/` | 공개 진입점 |
| Spring Boot | `http://localhost/actuator/health` | nginx 경유 |
| Spring Boot (직접) | `http://localhost:8080/actuator/health` | dev 포트 오픈 시 |
| Dev Ping | `http://localhost:8080/api/dev/ping` | 연결 확인용 |
| Python Embed | `http://localhost:8000/health` | dev 포트 오픈 시 |
| Qdrant | `http://localhost:6333/healthz` | dev 포트 오픈 시 |
| 업로드 이미지 | `http://localhost/files/dogs/{uuid}/nose/{filename}` | nginx 직접 서빙 |

> **파일 URL 정책 전체**: [FILE_STORAGE_AND_URL_POLICY.md](FILE_STORAGE_AND_URL_POLICY.md)

---

## Qdrant/MySQL 정합성 점검

dog nose v2 real-model smoke 이후에는 MySQL `dog_nose_references`와 Qdrant active points가 일치하는지 확인합니다.

```powershell
pwsh ./scripts/check-qdrant-reference-consistency.ps1 `
  -EnvFile infra/docker/.env `
  -QdrantUrl http://localhost:6333 `
  -Collection dog_nose_embeddings_real_v2 `
  -OutputPath docs/ops-evidence/local-qdrant-reconciliation-dry-run.json `
  -FailOnDrift
```

drift가 발견되면 [QDRANT_RECONCILIATION_RUNBOOK.md](QDRANT_RECONCILIATION_RUNBOOK.md)를 먼저 확인합니다.

주의:

- 기본 실행은 dry-run이며 Qdrant point를 삭제하지 않습니다.
- orphan delete는 명시적 승인/evidence를 남긴 뒤 `-DeleteOrphans`와 `-ConfirmDelete`를 모두 사용할 때만 허용합니다.
- `missing_in_qdrant` 자동 복구와 Qdrant payload 자동 patch는 금지합니다.

---

## 장애 시 1차 확인 포인트

```bash
# 모든 컨테이너 상태 확인
docker compose --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.dev.yaml \
  ps
```

1. **MySQL 연결 실패 (spring-api 미기동)** — `.env`의 `SPRING_DATASOURCE_URL`, `MYSQL_PASSWORD` 확인
2. **Flyway 마이그레이션 실패** — `spring-api` 로그에서 `FlywayException` 확인
   - `Validate failed` → 이미 적용된 마이그레이션 파일이 변경됨. 파일 내용 복구 필요
   - `Migration checksum mismatch` → 동일 원인. 체크섬 불일치
   - 기존 DB에 테이블이 있고 `flyway_schema_history` 가 없는 경우 → `IF NOT EXISTS` 덕분에 자동 처리됨
3. **502 Bad Gateway (Nginx)** — `spring-api` 컨테이너 상태 및 로그 확인
4. **임베딩 실패** — `python-embed` 컨테이너 로그 확인, `EMBED_MODEL=mock-v1` 여부 확인
5. **Qdrant 연결 실패** — `qdrant` 컨테이너 상태, `http://localhost:6333/healthz` 응답 확인
6. **spring-api 기동 지연** — `start_period: 60s`이므로 최대 75초까지 대기

---

## 컨테이너/볼륨 주의사항

- 데이터 볼륨 (`mysql_data`, `qdrant_storage`, `uploads_data`)은 `docker compose down`으로 삭제되지 않습니다.
- 완전 초기화: `docker compose ... down -v` (데이터 영구 삭제 주의)
- Compose 프로젝트명은 `infra/docker/compose.yaml`의 `name: petnose`로 고정합니다.
- 따라서 볼륨 이름은 `petnose_mysql_data`, `petnose_qdrant_storage`, `petnose_uploads_data` 형태로 생성됩니다.
- `backup.sh`/`restore.sh`는 이 실제 마운트를 `docker compose ... exec`로 사용하므로, 볼륨명을 수동으로 입력할 필요가 없습니다.

---

## 백업/복구 드릴 메모 (dev)

- 백업 실행: `bash infra/scripts/backup.sh`
- MySQL 산출물: `backups/mysql/backup_<YYYYMMDD_HHMMSS>.sql.gz`
- uploads 산출물: `backups/uploads/uploads_<YYYYMMDD_HHMMSS>.tar.gz`
- uploads 복구는 두 모드가 있습니다.
- 기본 모드: 기존 파일 유지 + 동일 경로 파일 덮어쓰기
- 스냅샷 재현 모드: `--wipe-first` 옵션으로 기존 파일 삭제 후 복구

```bash
bash infra/scripts/restore.sh mysql backups/mysql/backup_<YYYYMMDD_HHMMSS>.sql.gz
bash infra/scripts/restore.sh uploads backups/uploads/uploads_<YYYYMMDD_HHMMSS>.tar.gz --wipe-first
```

상세 실검증 절차는 [BACKUP_PLAN.md](BACKUP_PLAN.md)의 `로컬/dev Drill (1회 실검증)` 섹션을 따릅니다.
드릴 결과 기록 템플릿: [backup-restore-drill-log.md](../ops-evidence/backup-restore-drill-log.md)

---

## Python embed mock 모드

`.env`에 `EMBED_MODEL=mock-v1`이 설정되어 있으면 실제 모델 없이도 동작합니다.  
mock 모드에서는 이미지 SHA-256 해시 기반으로 재현 가능한 더미 벡터(128차원)를 반환합니다.  
실제 모델 적용 시 `python-embed/app/main.py`의 `_load_model()` 함수를 구현하세요.

GitHub Actions `ci.yaml`의 compose smoke는 이 mock/dev 경로만 검증합니다. CI에서는
`QDRANT_COLLECTION=dog_nose_embeddings_ci_mock`, `QDRANT_VECTOR_DIM=128`을 명시해
실제 v2 runtime(`dog_nose_embeddings_real_v2`, 2048차원)과 혼동하지 않습니다.
실제 dog-nose-identification2 checkpoint가 필요한 E2E 검증은
`scripts/verify-submission-real-model-e2e.ps1`와 제출 evidence 문서에서 다룹니다.

---

## Dev 전용 엔드포인트 (`/api/dev/*`)

`DevController`는 `@Profile("dev")`로 격리되어 있습니다.

| 환경 | `SPRING_PROFILES_ACTIVE` | `/api/dev/*` 활성화 |
|------|--------------------------|---------------------|
| dev (로컬/개발 서버) | `dev` | ✅ 활성화 |
| test (CI `gradle test`) | `test` | ❌ 비활성화 |
| prod | `prod` | ❌ 비활성화 |

`compose.dev.yaml`에서 `SPRING_PROFILES_ACTIVE: dev`를 명시합니다.  
`compose.prod.yaml`에서 `SPRING_PROFILES_ACTIVE: prod`가 설정되어 있어 prod 배포 시 자동 격리됩니다.

---

## GHCR 이미지 Publish

`develop` 또는 `main` 브랜치에 push 되면 `.github/workflows/publish-images.yaml` 이 자동 실행되어  
세 이미지를 빌드하고 GitHub Container Registry(GHCR)에 push합니다.

| 이미지 | GHCR 경로 |
|--------|-----------|
| Spring Boot API | `ghcr.io/jaaesung/petnose-spring-api` |
| Python Embed | `ghcr.io/jaaesung/petnose-python-embed` |
| Python Embed Real | `ghcr.io/jaaesung/petnose-python-embed-real` |

**태그 전략**

| 태그 | 예시 | 설명 |
|------|------|------|
| `<branch>-latest` | `develop-latest` | 해당 브랜치 최신 이미지 |
| `<branch>-<sha>` | `develop-a1b2c3d` | 특정 커밋 고정 이미지 (7자리 SHA) |

workflow summary에는 image digest, provenance/SBOM/attestation 적용 여부가 기록됩니다.
`actions/attest@v4`는 GHCR registry attestation을 push하되, 개인 계정 repository 안전성을 위해 GitHub artifact storage record는 생성하지 않습니다. Organization repository에서 storage record까지 사용하려면 `artifact-metadata: write` 권한과 `create-storage-record: true` 정책을 별도로 검토합니다.
`petnose-python-embed-real` 이미지는 real-model dependency만 포함하며 model checkpoint는 image에 포함하지 않습니다.
checkpoint는 서버의 `DOG_NOSE_MODEL_DIR_HOST` 경로를 read-only mount합니다.

**이미지 pull 예시**

```bash
# develop 최신 이미지
docker pull ghcr.io/jaaesung/petnose-spring-api:develop-latest

# 특정 커밋 고정 이미지
docker pull ghcr.io/jaaesung/petnose-spring-api:develop-a1b2c3d
```

> **주의**: GHCR 패키지가 처음 push 되면 기본적으로 **private**으로 생성됩니다.  
> 팀원 모두 접근이 필요하면 GitHub → Packages → visibility 를 public으로 변경하거나  
> 팀원 계정에 패키지 접근 권한을 부여하세요.

---

## Canonical 배포 경로 (단일화)

배포는 아래 경로만 사용합니다:

1. GitHub Actions `publish-images.yaml`에서 GHCR 이미지 publish
2. mock/prod path는 서버에서 `infra/scripts/deploy.sh` 실행
3. dog nose v2 real-model path는 서버에서 `infra/scripts/deploy-real-model.sh` 실행
4. deploy script 내부에서:
   - `docker compose pull`
   - `docker compose up -d --no-build`
   - post-deploy healthcheck (`/actuator/health` via nginx, canonical)
5. healthcheck 실패 시 즉시 non-zero 종료 (fail-fast)

즉, **서버에서 `git pull` 후 소스 빌드하는 방식은 사용하지 않습니다.**

---

## Dev CD 실검증 체크리스트

`cd-dev.yaml`은 두 방식으로 실행됩니다.
- 자동: `publish-images.yaml` 성공 + `develop` 브랜치
- 수동: `workflow_dispatch` (원하는 `image_tag` 지정 가능)
- 태그 형식: `develop-latest` 또는 `develop-<sha7>`만 허용
- 자동 deploy는 `develop-<sha7>` immutable tag와 `real_model=true` 기준으로 실행됩니다.
- `real_model=true`에서는 `PYTHON_EMBED_REAL_IMAGE`를 real image repo로 pinning하고 `deploy-real-model.sh`를 실행합니다.
- `real_model=false`에서는 `PYTHON_EMBED_IMAGE`를 mock/prod image repo로 pinning하고 `deploy.sh`를 실행합니다.
- workflow는 `.env` 전체를 출력하지 않고 key existence, model path, compose config만 확인합니다.

필수 선행 조건 (UNVERIFIED, 수동 설정 필요):
1. GitHub self-hosted runner가 dev 서버에서 online/idle 상태이고 라벨이 `self-hosted`, `Linux`, `X64`, `petnose-dev`와 일치
2. dev 서버에 `/opt/petnose` 배치 및 `infra/scripts/deploy.sh`, `infra/scripts/deploy-real-model.sh` 실행 가능 상태
3. 서버 `.env`에 배포/DB 환경변수 설정 (`SPRING_API_IMAGE`, `PYTHON_EMBED_IMAGE`, `PYTHON_EMBED_REAL_IMAGE` 포함)
4. real-model 배포 시 `DOG_NOSE_MODEL_DIR_HOST`와 required checkpoint가 서버에 존재
5. GHCR 패키지가 private이면 서버에서 pull 가능한 인증(`GHCR_USERNAME`, `GHCR_TOKEN`)
6. (수동 검증) runner 서비스 계정이 Docker 명령 실행 가능한 권한 보유 (`docker compose` 실행 가능)

실패 시 확인 우선순위:
1. self-hosted runner 라벨 불일치 또는 offline
2. `/opt/petnose` preflight 실패 (파일 누락, `.env` 누락, compose config 오류)
3. real-model path 누락 (`DOG_NOSE_MODEL_DIR_HOST`, checkpoint, `compose.prod-real-model.yaml`)
4. GHCR pull 실패 (권한/태그 오타)
5. deploy script의 post-deploy healthcheck 실패 (`/actuator/health` via nginx)

---

## Shared Dev 배포 흐름

1. `develop` push
2. `publish-images.yaml`이 GHCR 이미지 publish
3. `cd-dev.yaml` 실행 (자동: workflow_run / 수동: workflow_dispatch)
4. `cd-dev` guardrail 확인
   - tag 형식 검증 (`develop-latest` 또는 `develop-<sha7>`)
   - real-model deploy files, model mount, compose config
   - optional Qdrant/MySQL reconciliation (`pwsh`가 있을 때)
5. `deploy-real-model.sh` 실행 (`pull` → `up --no-build` → `actuator/health`)

---

## 실패 모드별 1차 진단 루틴

| 실패 모드 | 1차 확인 명령 | 통과 기준 |
|---|---|---|
| runner 미수신/대기 | GitHub Actions run 상태 확인 | self-hosted `petnose-dev` 라벨 잡 수신 |
| tag 검증 실패 | workflow 로그의 `Resolve image tag` 확인 | `develop-latest` 또는 `develop-<sha7>` |
| real-model preflight 실패 | `Runner Smoke` 또는 `cd-dev` preflight 로그 확인 | `compose.prod-real-model.yaml`, `DOG_NOSE_MODEL_DIR_HOST`, checkpoint 존재 |
| GHCR pull 실패 | deploy script 로그 확인 | spring/python-real image pull 성공 |
| deploy 후 health 실패 | `docker compose ... ps` / `docker compose ... logs --tail=200 spring-api nginx python-embed` | `http://localhost/actuator/health` 성공 |

---

## GitHub Branch Protection 권장

Settings → Branches → Add rule (대상: `main`):

- `main` 직접 push 금지 — PR을 통해서만 merge
- Status check 필수: `CI / Backend tests` + `CI / Python tests` + `CI / Docs and script sanity` + `CI / Compose mock smoke` + `CI / Docker build`
- 최소 1인 리뷰 승인 후 merge

> 현재는 설정되어 있지 않으므로 저장소 관리자가 GitHub UI에서 직접 설정해야 합니다.
