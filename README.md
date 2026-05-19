# PetNose Adoption Platform

Dev branch deployment rehearsal marker
강아지 비문(코 지문) 인식 기반 유기견 입양 플랫폼 — 졸업작품 monorepo.

---

## 프로젝트 개요

강아지 코 사진을 찍으면 비문 임베딩을 통해 동일 개체를 식별하고, 유기견과 보호자를 연결하는 입양 플랫폼입니다.  
Flutter 앱 → Spring Boot API → Python 임베딩 서비스 → Qdrant 벡터 검색의 파이프라인으로 동작합니다.

## 환경 의미 구분

- `local dev`: 개인 PC에서 `compose.dev`로 기능 개발/디버깅
- `shared dev`: 팀 공용 dev 서버 배포 검증 (`develop` 기준, self-hosted runner)
- `prod`: 발표/시연용 수동 배포 경로 (`workflow_dispatch`, 보수적 운영)

## 목표

- 비문 기반 개체 식별로 유기견 재회율 향상
- 졸업작품 수준의 완성도 있는 서비스 시연

## 시스템 구성 요소

| 서비스         | 역할                           | 포트        |
| -------------- | ------------------------------ | ----------- |
| `nginx`        | 리버스 프록시                  | 80          |
| `spring-api`   | 비즈니스 로직, 인증, DB 연동   | 8080 (내부) |
| `python-embed` | 비문 이미지 → 임베딩 벡터 변환 | 8000 (내부) |
| `mysql`        | 사용자/강아지/입양 데이터 저장 | 3306 (내부) |
| `qdrant`       | 벡터 유사도 검색               | 6333 (내부) |

전체 구조는 [docs/reference/ARCHITECTURE.md](docs/reference/ARCHITECTURE.md)를 참고하세요.

---

## 빠른 시작 (로컬 개발)

**사전 조건:** Docker Desktop, Docker Compose v2  
백엔드를 로컬에서 직접 빌드/테스트하려면 **Java 21** (`JAVA_HOME` 설정 필요).

```bash
# 1. 환경변수 파일 준비
cp infra/docker/.env.example infra/docker/.env
# .env 파일을 열어 필요한 값 수정

# 2. 서비스 기동
bash infra/scripts/dev-up.sh

# 3. 상태 확인
bash infra/scripts/healthcheck.sh

# 4. 서비스 종료
bash infra/scripts/dev-down.sh
```

앱 접속: `http://localhost` (Nginx → Spring API)

### 실제 모델 모드 기준

기본 dev/CI compose 경로는 빠른 연결 검증을 위해 `mock-v1` / 128차원 값을 사용할 수 있습니다. 이 값은 실제 MVP 검증을 대체하지 않습니다.

실제 모델 E2E 또는 팀 공유 전 MVP 검증은 `infra/docker/compose.real-model.yaml`을 함께 사용하고 아래 값을 기준으로 합니다.

| 항목 | 필수 값 |
|---|---|
| `EMBED_MODEL` | `dog-nose-identification2` |
| `EMBED_VECTOR_DIM` | `2048` |
| `QDRANT_COLLECTION` | `dog_nose_embeddings_real_v1` |
| `QDRANT_VECTOR_DIM` | `2048` |

`compose.real-model.yaml`은 sample env의 mock 기본값이 실제 모델 실행에 섞이지 않도록 위 런타임 값을 강제합니다. mock smoke와 real-model E2E는 같은 Qdrant collection/volume을 섞어 쓰지 않는 것이 안전합니다.

실제 Docker runtime에서 MVP 핵심 흐름을 끝까지 검증하려면 실제 dog nose image를 준비한 뒤 아래 스크립트를 실행합니다. `-HandoverNoseImagePath`를 넘기면 등록 비문 사진과 인도 시점 비문 사진을 분리해 비교할 수 있고, 생략하면 `-NoseImagePath`를 그대로 사용합니다.

```powershell
pwsh ./scripts/verify-real-model-mvp-flow.ps1 -StartCompose -ResetRuntime -NoseImagePath "C:\path\to\nose.jpg"
```

```powershell
pwsh ./scripts/verify-real-model-mvp-flow.ps1 `
  -StartCompose `
  -ResetRuntime `
  -NoseImagePath "C:\Dev\sample\nose_test1.jpg" `
  -HandoverNoseImagePath "C:\Dev\sample\nose_test2.jpg" `
  -ProfileImagePath "C:\Dev\sample\nose_test1.jpg"
```

이 스크립트는 회원가입, 로그인, 비문 등록/중복 의심, 분양글 생성, public privacy, handover verification, owner-only 완료 처리, `/files` 접근, Qdrant point 존재 여부를 확인합니다. `ResetRuntime`은 PetNose compose project의 로컬 DB/Qdrant 볼륨을 초기화하므로 필요한 경우에만 사용하세요.

### DB schema 기준

팀원 공유 기준 canonical table은 `users`, `dogs`, `dog_images`, `verification_logs`, `adoption_posts` 5개입니다. `POST /api/dogs/register`가 dog identity 등록, 비문 중복 검사, Qdrant upsert의 유일한 진입점이고, `POST /api/adoption-posts`는 이미 등록된 `dog_id`와 required `profile_image`로 게시글과 대표 이미지만 생성합니다.

---

## 디렉토리 구조

```
petnose-adoption-platform/
├── app/                   # Flutter 앱
├── backend/               # Spring Boot API
├── python-embed/          # Python 비문 임베딩 서비스
├── infra/
│   ├── docker/            # compose.yaml, .env.example
│   ├── nginx/             # nginx.conf, conf.d/
│   ├── scripts/           # 운영 스크립트
│   └── aws/               # EC2 배포 가이드
├── docs/                  # 설계 문서
│   ├── db/                # active DB 기준(DBML/canonical SQL)
│   ├── reference/         # active canonical 보조 문서
│   └── archive/           # historical reference (active 기준 아님)
└── .github/               # CI/CD, PR/Issue 템플릿
```

---

## 문서 위치

| 문서 | 설명 |
|---|---|
| [docs/README.md](docs/README.md) | 문서 라우팅 진입점 |
| [docs/PROJECT_KNOWLEDGE_INDEX.md](docs/PROJECT_KNOWLEDGE_INDEX.md) | active 기준 요약 및 충돌 규칙 |
| [docs/PETNOSE_MVP_FINAL_PROJECT_SPEC.md](docs/PETNOSE_MVP_FINAL_PROJECT_SPEC.md) | active 최종 스펙 |
| [docs/PETNOSE_MVP_API_CONTRACT.md](docs/PETNOSE_MVP_API_CONTRACT.md) | active Flutter ↔ Spring API 계약 |
| [docs/db/petnose_mvp_schema.dbml](docs/db/petnose_mvp_schema.dbml) | active DB 기준(DBML) |
| [docs/db/V20260508__mvp_canonical_schema.sql](docs/db/V20260508__mvp_canonical_schema.sql) | active DB 기준(canonical SQL) |
| [docs/reference/ARCHITECTURE.md](docs/reference/ARCHITECTURE.md) | 시스템 구조 및 서비스 책임 |
| [docs/reference/ENV_STRATEGY.md](docs/reference/ENV_STRATEGY.md) | 환경변수 및 Secrets 전략 |
| [docs/reference/STORAGE_AND_VECTOR_BOUNDARY.md](docs/reference/STORAGE_AND_VECTOR_BOUNDARY.md) | MySQL / Qdrant / file storage 경계 |
| [docs/reference/SPRING_PYTHON_EMBED_CONTRACT.md](docs/reference/SPRING_PYTHON_EMBED_CONTRACT.md) | Spring ↔ Python 계약 |
| [docs/reference/FILE_STORAGE_AND_URL_POLICY.md](docs/reference/FILE_STORAGE_AND_URL_POLICY.md) | 업로드 파일 저장/URL 정책 |
| [docs/reference/TEAM_ONBOARDING.md](docs/reference/TEAM_ONBOARDING.md) | 팀원 최초 실행 가이드 |
| [docs/reference/OPS_NOTES.md](docs/reference/OPS_NOTES.md) | 운영 메모 |
| [docs/reference/BACKUP_PLAN.md](docs/reference/BACKUP_PLAN.md) | 백업/복구 절차 |
| [docs/reference/LOCAL_CLEANUP_GUIDE.md](docs/reference/LOCAL_CLEANUP_GUIDE.md) | ignored/generated 파일 수동 정리 가이드 |
| [docs/reference/MVP_SCHEMA_TABLE_COUNT_REVIEW.md](docs/reference/MVP_SCHEMA_TABLE_COUNT_REVIEW.md) | schema table count 통합 기록 |
| [docs/ops-evidence/backup-restore-drill-log.md](docs/ops-evidence/backup-restore-drill-log.md) | 백업/복구 드릴 증적 로그 |
| [infra/aws/ec2-setup.md](infra/aws/ec2-setup.md) | EC2 배포 준비 |

---

## 저장소 clone 및 시작

```bash
git clone https://github.com/jaaesung/petnose-adoption-platform.git
cd petnose-adoption-platform
cp infra/docker/.env.example infra/docker/.env
# .env 열어서 [SECRET] 항목(비밀번호)을 수정하세요
# MySQL 포트 충돌 시 MYSQL_PORT=3307 로 변경
# env/secrets 전략: docs/reference/ENV_STRATEGY.md 참고
bash infra/scripts/dev-up.sh
```

---

## GitHub Actions CI / CD

| 워크플로              | 트리거                                                   | 역할                                                        |
| --------------------- | -------------------------------------------------------- | ----------------------------------------------------------- |
| `ci.yaml`             | push(develop/main) + PR                                  | backend-test, python-smoke, integration-smoke, docker-build |
| `publish-images.yaml` | push(develop/main)                                       | GHCR 이미지 빌드 및 publish                                 |
| `cd-dev.yaml`         | `publish-images.yaml` 성공 + develop, 또는 수동 dispatch | dev 서버 배포 (GHCR pull path)                              |
| `cd-prod.yaml`        | workflow_dispatch(main 기준)                             | prod 서버 수동 배포 (GHCR pull path)                        |

Shared dev deploy chain (deterministic target):

1. `develop` push
2. `publish-images.yaml` 성공
3. `cd-dev.yaml` 실행 (`workflow_run` 또는 수동 dispatch)
4. `cd-dev` guardrails 통과
   - tag format + GHCR manifest 존재 확인
   - `/opt/petnose` 핵심 배포 파일 해시 정합성 확인
5. `deploy.sh` 실행 (`pull` → `up --no-build` → healthcheck)

`ci.yaml`의 `integration-smoke`는 Docker Compose(dev)를 실제로 띄워 아래를 검증합니다:

- Spring 기동 + `GET /actuator/health`
- Flyway 마이그레이션 적용(`flyway_schema_history` 확인)
- Spring → Python 연결(`/api/dev/embed-ping`)
- Spring → Python `/embed` 호출(`/api/dev/embed-sample`)
- Qdrant 컬렉션 초기화 경로(`GET /collections/dog_nose_embeddings`)

`integration-smoke`가 아직 보장하지 않는 것:

- Flutter ↔ backend E2E
- 인증/인가/도메인 API 정합성
- 실제 AI 모델 추론 품질
- 실제 서버 배포 경로(CD/self-hosted runner/서버 런타임)

Dev CD one-run validation (recommended):

1. Confirm `publish-images.yaml` pushed both images for the same develop tag.
2. In GitHub Actions, run `cd-dev.yaml` with `workflow_dispatch` and set `image_tag` (`develop-latest` or `develop-<sha7>`).
3. `cd-dev.yaml` should run on self-hosted labels (`self-hosted`, `Linux`, `X64`, `petnose-dev`) and execute local preflight in `/opt/petnose`:
   - required files (`infra/scripts/deploy.sh`, `infra/docker/.env`, compose files)
   - Docker/Compose availability and compose config validation
   - deterministic image tag resolution (`workflow_dispatch` input or `workflow_run.head_sha`)
   - strict tag guardrail (`develop-latest` or `develop-<sha7>`) + GHCR manifest existence check
   - server deploy file hash match check against workflow repository files
4. Deployment uses one-run env override (`SPRING_API_IMAGE`, `PYTHON_EMBED_IMAGE`) and does not rewrite server `.env` image keys.
5. Deployment succeeds only when local `infra/scripts/deploy.sh` completes and post-deploy healthcheck (`http://localhost/actuator/health`) passes.
6. If it fails, use workflow logs + [docs/reference/OPS_NOTES.md](docs/reference/OPS_NOTES.md) dev CD checklist to resolve.

Canonical deployment path:

1. `publish-images.yaml` 로 GHCR 이미지 생성
2. 서버에서 `infra/scripts/deploy.sh` 실행
3. `deploy.sh`가 `docker compose pull` → `up -d --no-build` 실행
4. post-deploy healthcheck(`http://localhost/actuator/health`, nginx 경유) 실패 시 즉시 실패 처리

GHCR 이미지:

- `ghcr.io/jaaesung/petnose-spring-api:<branch>-latest`
- `ghcr.io/jaaesung/petnose-python-embed:<branch>-latest`

결과 확인: `https://github.com/jaaesung/petnose-adoption-platform/actions`  
태그 전략 및 운영 상세: [docs/reference/OPS_NOTES.md](docs/reference/OPS_NOTES.md)

---

## 팀 작업 규칙

- **브랜치 전략:** `main` (배포) / `develop` (통합) / `feature/*`, `fix/*`, `infra/*`, `docs/*` (작업)
- **PR:** `.github/pull_request_template.md` 형식을 따른다.
- **커밋 메시지:** `feat:`, `fix:`, `docs:`, `infra:`, `chore:` 등 prefix를 붙인다.
- **`.env` 파일은 절대 커밋하지 않는다.** `.env.example`만 관리한다.
- **서비스별 포트/환경변수명은 `compose.yaml`과 문서를 기준으로 통일한다.**
- 각 서비스 디렉토리의 README를 참고해 로컬 실행 방법을 확인한다.

## Branch Protection 권장 (GitHub 설정)

GitHub 저장소 Settings → Branches → Add rule (`main`) 에서 아래를 권장한다:

- `main` 직접 push 금지 (require PR)
- PR merge 전 CI 통과 필수 (`Spring Boot 테스트`, `Python smoke`, `Integration smoke`, `Docker 이미지 빌드`)
- 최소 1인 리뷰 승인 필요
