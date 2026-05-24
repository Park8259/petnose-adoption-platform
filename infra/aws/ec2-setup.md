# AWS EC2 Real-Model Deployment Runbook

This runbook deploys the latest stable `main` PetNose runtime to a single AWS
EC2 instance with the real dog-nose embedding model.

## Target Architecture

- Single EC2 first, operated with Docker Compose.
- Nginx is the only public application entrypoint.
- Spring API, Python Embed, Qdrant, and MySQL stay on the internal compose network.
- MySQL remains the source of truth for domain state.
- Qdrant remains only the dog nose vector search index.
- Production deployment is GHCR pull-based; do not build source on the server.

## AWS Sizing

| Item | Recommendation |
|---|---|
| Instance | Minimum `t3.medium`; recommended `t3.large` for real-model deployment |
| OS | Ubuntu 22.04 LTS |
| Disk | EBS gp3 50GB+ recommended |
| IP | Elastic IP recommended |

## Security Group

Inbound rules:

| Port | Source | Purpose |
|---|---|---|
| `22/tcp` | My IP only | SSH |
| `80/tcp` | `0.0.0.0/0`, `::/0` | HTTP through Nginx |
| `443/tcp` | `0.0.0.0/0`, `::/0` | HTTPS after certificate setup |

Do not expose `3306`, `6333`, `8080`, or `8000` publicly. Those ports are for
MySQL, Qdrant, Spring, and Python Embed internal traffic only.

## Ubuntu Setup

```bash
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y git curl ca-certificates

curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
newgrp docker

docker --version
docker compose version
curl --version
```

## Server Directory Layout

Use `/opt/petnose` as the repository root and keep runtime-only data under it:

```text
/opt/petnose
/opt/petnose/models/dog_nose_identification2
/opt/petnose/secrets
/opt/petnose/backups/mysql
/opt/petnose/backups/uploads
```

## Repository Placement

```bash
sudo git clone https://github.com/jaaesung/petnose-adoption-platform.git /opt/petnose
sudo chown -R "$USER":"$USER" /opt/petnose
cd /opt/petnose
git fetch origin --prune
git switch main
git pull --ff-only origin main
```

Create runtime-only directories after the repository exists:

```bash
mkdir -p \
  /opt/petnose/models/dog_nose_identification2 \
  /opt/petnose/secrets \
  /opt/petnose/backups/mysql \
  /opt/petnose/backups/uploads
```

## Model Placement

Required model root:

```text
/opt/petnose/models/dog_nose_identification2
```

Required checkpoint example:

```text
/opt/petnose/models/dog_nose_identification2/logs/s101_224/model_final.pth
```

Model files must never be committed to git. The real-model compose override
mounts the model directory read-only into the Python Embed container at:

```text
/models/dog_nose_identification2
```

Before deployment, verify the checkpoint exists:

```bash
test -f /opt/petnose/models/dog_nose_identification2/logs/s101_224/model_final.pth
```

## Environment Setup

```bash
cd /opt/petnose
cp infra/docker/.env.example infra/docker/.env
nano infra/docker/.env
```

Set strong secret values for MySQL and any private registry credentials. Do not
commit `infra/docker/.env`.

Required real-model production values:

```dotenv
APP_ENV=prod
SPRING_PROFILES_ACTIVE=prod

DOG_NOSE_MODEL_DIR_HOST=/opt/petnose/models/dog_nose_identification2
EMBED_MODEL=dog-nose-identification2
EMBED_VECTOR_DIM=2048
PYTHON_EMBED_INSTALL_REAL_DEPS=1

QDRANT_COLLECTION=dog_nose_embeddings_real_v1
QDRANT_VECTOR_DIM=2048

SPRING_API_IMAGE=ghcr.io/jaaesung/petnose-spring-api:main-<sha7>
PYTHON_EMBED_IMAGE=ghcr.io/jaaesung/petnose-python-embed-real:main-<sha7>
```

Use immutable `main-<sha7>` tags for production instead of `main-latest` when
possible. If GHCR packages are private, set both `GHCR_USERNAME` and
`GHCR_TOKEN` in the server environment or in `infra/docker/.env`. Never print or
commit token values.

## Deployment

The real-model path uses:

- `infra/docker/compose.yaml`
- `infra/docker/compose.prod.yaml`
- `infra/docker/compose.real-model.yaml`

Run:

```bash
cd /opt/petnose
bash infra/scripts/deploy-real-model.sh
bash infra/scripts/aws-real-model-smoke.sh
```

`deploy-real-model.sh` validates compose config, pulls GHCR images, runs
`docker compose up -d --no-build`, and checks
`http://localhost/actuator/health` through Nginx.

## Local PC E2E Test

From a local development PC with real nose/profile images:

```powershell
pwsh ./scripts/verify-real-model-mvp-flow.ps1 `
  -BaseUrl "http://<elastic-ip-or-domain>" `
  -NoseImagePath "<local nose image path>" `
  -ProfileImagePath "<local profile image path>" `
  -ExpectedVectorDimension 2048 `
  -ExpectedModelKeyword "dog-nose-identification2" `
  -DbCheckMode skip
```

`-DbCheckMode skip` is recommended for remote AWS smoke unless the local machine
also has private access to the server database container.

## Flutter App Base URL

For AWS deployment, the app should use the AWS server base URL:

```text
http://<elastic-ip-or-domain>
https://<domain>
```

Do not use `10.0.2.2` for an AWS server. `10.0.2.2` is only for an Android
emulator connecting to a backend running on the developer's local PC.

Image URLs returned as `/files/...` should be joined with the same server base
URL, for example `http://<elastic-ip-or-domain>/files/...`.

## Firebase Optional

Firebase chat/push is optional. Enable it only after the core MVP real-model
deployment and smoke checks pass.

The Firebase service account JSON must live outside committed source, for
example:

```text
/opt/petnose/secrets/firebase-service-account.json
```

Set Firebase values in `infra/docker/.env` without committing them:

```dotenv
FIREBASE_ENABLED=true
FIREBASE_PROJECT_ID=<firebase-project-id>
FIREBASE_CREDENTIALS_HOST_PATH=/opt/petnose/secrets/firebase-service-account.json
```

Then explicitly include the Firebase compose override:

```bash
PETNOSE_INCLUDE_FIREBASE=true bash infra/scripts/deploy-real-model.sh
PETNOSE_INCLUDE_FIREBASE=true bash infra/scripts/aws-real-model-smoke.sh
```

Equivalent flag form:

```bash
bash infra/scripts/deploy-real-model.sh --firebase
bash infra/scripts/aws-real-model-smoke.sh --firebase
```

Do not commit Firebase service account JSON. Do not print Firebase secrets.
Firebase must not replace MySQL domain state.

## HTTPS

Start with HTTP for the first smoke:

```text
http://<elastic-ip-or-domain>
```

After the HTTP deployment is healthy, attach a domain and add HTTPS with
Certbot or an equivalent certificate process. If 443 is not already configured,
the production Nginx compose/nginx configuration needs a `443:443` port mapping
and an HTTPS server block before opening `443/tcp` in the security group.

## Backups

Minimum backup targets:

- MySQL dump.
- Uploads volume/files.
- `infra/docker/.env`.
- Firebase service account JSON, if Firebase is used.
- Model files under `/opt/petnose/models/dog_nose_identification2`.

The existing `infra/scripts/backup.sh` is oriented around the dev compose file
combination. For production, either adapt it carefully to the prod compose stack
or add a future dedicated prod backup script that writes to:

```text
/opt/petnose/backups/mysql
/opt/petnose/backups/uploads
```

Keep backup archives and secrets out of git.
