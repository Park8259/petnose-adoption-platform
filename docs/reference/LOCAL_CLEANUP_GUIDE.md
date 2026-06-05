# Local Cleanup Guide

이 문서는 팀원 공유 전 로컬에 쌓인 ignored/generated 파일을 수동으로 정리할 때만 사용한다. tracked 소스, migration, compose service, 실제 모델 파일은 삭제하지 않는다.

## 원칙

- 먼저 `git status --short --ignored`로 대상이 ignored/generated인지 확인한다.
- `git clean -xfd` 같은 전체 삭제 명령은 사용하지 않는다.
- 아래 명령은 예시이며, 실행 전 경로를 직접 확인한다.
- `infra/docker/.env.backup.*`는 secret이 들어 있을 수 있으므로 git에 올리거나 공유하지 않는다.

## 정리 대상

| 경로 | 성격 | 주의 |
|---|---|---|
| `backend/build/**` | Gradle build output | 재생성 가능 |
| `backend/.gradle/**` | Gradle local cache | 재생성 가능 |
| `backend/bin/**` | IDE/컴파일 산출물 가능성 | 직접 확인 후 삭제 |
| `python-embed/**/__pycache__/**` | Python bytecode cache | 재생성 가능 |
| `backups/e2e-temp/**` | E2E 임시 백업/검증 산출물 | 필요한 증적이 없는지 확인 |
| `infra/docker/.env.backup.*` | 로컬 env 백업 | secret 가능성 높음, 공유 금지 |

## PowerShell 예시

먼저 목록을 확인한다.

```powershell
Get-ChildItem -Force backend\build, backend\.gradle, backend\bin -ErrorAction SilentlyContinue
Get-ChildItem -Recurse -Directory -Filter __pycache__ python-embed -ErrorAction SilentlyContinue
Get-ChildItem -Force backups\e2e-temp -ErrorAction SilentlyContinue
Get-ChildItem -Force infra\docker -Filter ".env.backup.*" -ErrorAction SilentlyContinue
```

확인 후 필요한 항목만 개별 삭제한다.

```powershell
Remove-Item -LiteralPath backend\build -Recurse -Force
Remove-Item -LiteralPath backend\.gradle -Recurse -Force
Remove-Item -LiteralPath backend\bin -Recurse -Force
Get-ChildItem -Recurse -Directory -Filter __pycache__ python-embed | Remove-Item -Recurse -Force
Remove-Item -LiteralPath backups\e2e-temp -Recurse -Force
Get-ChildItem -Force infra\docker -Filter ".env.backup.*" | Remove-Item -Force
```

## Bash 예시

먼저 목록을 확인한다.

```bash
find backend/build backend/.gradle backend/bin -maxdepth 2 -print 2>/dev/null
find python-embed -type d -name __pycache__ -print 2>/dev/null
find backups/e2e-temp -maxdepth 2 -print 2>/dev/null
find infra/docker -maxdepth 1 -type f -name ".env.backup.*" -print 2>/dev/null
```

확인 후 필요한 항목만 개별 삭제한다.

```bash
rm -rf backend/build
rm -rf backend/.gradle
rm -rf backend/bin
find python-embed -type d -name __pycache__ -prune -exec rm -rf {} +
rm -rf backups/e2e-temp
find infra/docker -maxdepth 1 -type f -name ".env.backup.*" -delete
```

## 정리 후 확인

```bash
git status --short --ignored
cd backend && gradle test --no-daemon --stacktrace
cd backend && gradle bootJar --no-daemon
docker compose --env-file infra/docker/.env -f infra/docker/compose.yaml -f infra/docker/compose.dev.yaml config --quiet
```

real-model E2E를 다시 검증할 때는 `infra/docker/compose.real-model.yaml`을 함께 포함하고, `dog-nose-identification2`, 2048차원, `dog_nose_embeddings_real_v2` 기준을 사용한다.
