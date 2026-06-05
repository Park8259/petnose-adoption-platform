# CI/CD Workflow Overview

> 문서 성격: 보조 참고 문서(Task Reference)
>
> active canonical 문서와 충돌하면 active canonical 문서가 우선한다.

## CI 범위

`.github/workflows/ci.yaml`은 pull request, `develop`/`main` push, 수동 실행에서 빠른 mock/dev validation을 담당한다.

검증 job:

- `backend-test`: Java 21과 Gradle CLI로 Spring Boot test를 실행한다.
- `python-test`: Python 3.11 mock/dev dependency를 설치하고 `pytest -q`를 실행한다.
- `docs-script-check`: evidence JSON, PowerShell script help/syntax, lightweight secret pattern scan을 확인한다.
- `compose-mock-smoke`: `compose.yaml` + `compose.dev.yaml`로 mock stack을 띄우고 Spring/Python/Qdrant/MySQL 연결과 active table/schema sanity를 확인한다.
- `docker-build`: backend image와 python-embed mock image를 build only로 확인한다. PR CI에서는 push하지 않는다.

CI는 secrets 없이 돌아야 한다. GHCR login, Firebase/service account, prod SSH secret, real model checkpoint는 CI job에 필요하지 않다.

## Mock Compose 기준

CI compose smoke는 실제 dog-nose-identification2 checkpoint를 사용하지 않는다.

- `EMBED_MODEL=mock-v1`
- `PYTHON_EMBED_INSTALL_REAL_DEPS=0`
- `QDRANT_COLLECTION=dog_nose_embeddings_ci_mock`
- `QDRANT_VECTOR_DIM=128`

이 기준은 연결, migration, Qdrant initializer, Spring to Python 호출, active table 존재 여부를 빠르게 검증하기 위한 mock/dev runtime이다.

## GHCR Publish

`.github/workflows/publish-images.yaml`은 `develop`/`main` push에서 GHCR image를 publish한다.

publish 대상:

- `ghcr.io/<owner>/petnose-spring-api`
- `ghcr.io/<owner>/petnose-python-embed`
- `ghcr.io/<owner>/petnose-python-embed-real`

tag 전략:

- `develop-latest`, `develop-<sha7>`
- `main-latest`, `main-<sha7>`

publish workflow는 `GITHUB_TOKEN`으로 GHCR에 login하며 `contents: read`, `packages: write`, `attestations: write`, `id-token: write` 권한만 사용한다. Buildx image build에는 `provenance: mode=max`와 `sbom: true`를 적용하고, GitHub image attestation과 image digest summary를 남긴다. `actions/attest@v4`는 GHCR registry attestation을 push하지만, 개인 계정 repository 안전성을 위해 GitHub artifact storage record는 생성하지 않는다. Organization repository에서 storage record까지 사용하려면 `artifact-metadata: write` 권한과 `create-storage-record: true` 정책을 별도로 검토한다.

`petnose-python-embed-real`은 real-model dependencies만 포함한다. dog-nose-identification2 checkpoint, Firebase credential, JWT secret, `.env`, `DOG_NOSE_MODEL_DIR_HOST` 같은 runtime/server-only 값은 image나 build args에 포함하지 않는다. 허용된 real build arg는 `INSTALL_REAL_MODEL_DEPS=1`뿐이다.

## Dev CD

`.github/workflows/cd-dev.yaml`은 self-hosted dev runner(`self-hosted`, `Linux`, `X64`, `petnose-dev`)에서 `/opt/petnose`를 배포 root로 사용한다.

실행 경로:

- 자동: `publish-images.yaml` 성공 + `develop` branch면 `develop-<sha7>` tag로 실행한다.
- 수동: `workflow_dispatch`에서 `image_tag`, `real_model`, `run_reconciliation`, `run_healthcheck`를 입력한다.

real-model dev deploy 기준:

- `real_model=true`가 기본값이다.
- `SPRING_API_IMAGE=ghcr.io/<owner>/petnose-spring-api:<tag>`
- `PYTHON_EMBED_REAL_IMAGE=ghcr.io/<owner>/petnose-python-embed-real:<tag>`
- `infra/scripts/deploy-real-model.sh`를 실행한다.
- `compose.yaml` + `compose.prod.yaml` + `compose.prod-real-model.yaml` config를 검증한다.
- `DOG_NOSE_MODEL_DIR_HOST`와 required checkpoint가 서버에 있어야 한다.

mock/prod image deploy가 필요하면 `real_model=false`로 실행한다. 이때는 `PYTHON_EMBED_IMAGE=ghcr.io/<owner>/petnose-python-embed:<tag>`를 pinning하고 `infra/scripts/deploy.sh`를 실행한다.

## Prod CD

`.github/workflows/cd-prod.yaml`은 production server deploy를 manual-only로 유지한다.

production safety:

- `confirm=yes`일 때만 실행한다.
- `environment: production`을 사용한다.
- `image_tag`는 immutable `main-<sha7>` 형식만 허용한다.
- 기본 deploy path는 `real_model=true`다.
- SSH command는 `.env` 전체를 출력하지 않고 file/key/path existence와 compose config만 확인한다.

real-model prod deploy 기준:

- `SPRING_API_IMAGE=ghcr.io/<owner>/petnose-spring-api:<main-sha7>`
- `PYTHON_EMBED_REAL_IMAGE=ghcr.io/<owner>/petnose-python-embed-real:<main-sha7>`
- `infra/scripts/deploy-real-model.sh`를 실행한다.
- `DOG_NOSE_MODEL_DIR_HOST` host path와 `logs/s101_224/model_final.pth` checkpoint가 있어야 한다.

## Runner Smoke

`.github/workflows/runner-smoke.yaml`은 self-hosted dev runner preflight다.

확인 항목:

- runner user/group/host/disk free
- Docker, Docker Compose, curl
- pwsh availability warning
- `/opt/petnose`
- `infra/docker/.env`
- `compose.yaml`, `compose.prod.yaml`, `compose.prod-real-model.yaml`
- `deploy.sh`, `deploy-real-model.sh`
- `.env` key existence only
- `DOG_NOSE_MODEL_DIR_HOST` path와 required checkpoint
- prod 및 real-model compose config

`.env` 값 전체는 출력하지 않는다.

## Real-Model 검증

현재 dog nose v2 real-model 기준은 다음과 같다.

- collection: `dog_nose_embeddings_real_v2`
- vector dimension: `2048`
- distance: `Cosine`
- point id: UUID
- metadata tracking: MySQL `dog_nose_references`

실제 model checkpoint가 필요한 E2E는 기본 PR CI에서 실행하지 않는다. `scripts/verify-submission-real-model-e2e.ps1`, `docs/ops-evidence/submission-real-model-e2e-log.md`, `docs/ops-evidence/submission-real-model-e2e-summary.json`가 제출 전 real-model 증적 경로다.

## Secrets Policy

- `.env` 파일은 커밋하지 않는다.
- Firebase service account, JWT secret, GHCR token, SSH key는 workflow log에 출력하지 않는다.
- model checkpoint와 raw image는 커밋하지 않고 image에도 bake하지 않는다.
- image tag와 digest는 secret이 아니다.
- build args에는 secret이나 host path를 넣지 않는다.
- Firebase enabled smoke는 이번 workflow 범위가 아니며 optional future workflow로 둔다.
