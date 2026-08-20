# AWS g4dn.xlarge Single-Host GPU Deployment Runbook

This runbook deploys the PetNose real-model stack to one AWS g4dn.xlarge host
with the Python Embed service using the NVIDIA T4 GPU.

## Target Architecture

```text
Android/Flutter
  -> Nginx
    -> Spring Boot
      -> MySQL
      -> Qdrant
      -> Python Embed
        -> PyTorch CUDA
        -> NVIDIA T4
```

All services run on one EC2 host through Docker Compose. Nginx is the only public
application entrypoint. Spring Boot, MySQL, Qdrant, and Python Embed stay on the
internal compose network.

## Host Setup

Install and verify the host runtime before deploying PetNose:

```bash
sudo apt-get update
sudo apt-get install -y git curl ca-certificates

curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"
newgrp docker

docker --version
docker compose version
```

Install the NVIDIA driver and NVIDIA Container Toolkit using the current AWS
and NVIDIA documentation for the selected Ubuntu version. Then verify both the
host driver and Docker GPU access:

```bash
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.1.1-base-ubuntu22.04 nvidia-smi
```

## Security Group

Expose only public application traffic:

| Port | Source | Policy |
|---|---|---|
| `80/tcp` | Public | HTTP through Nginx |
| `443/tcp` | Public | HTTPS after certificate setup |
| `22/tcp` | Admin IP only or SSM | Administration |

Do not expose `3306`, `6333`, `8000`, or `8080` publicly. MySQL, Qdrant, Python
Embed, and Spring Boot are internal services.

## Storage

Keep durable data on EBS-backed paths under `/opt/petnose`:

```text
/opt/petnose/infra/docker/.env
/opt/petnose/models/dog_nose_identification2/logs/s101_224/model_final.pth
/opt/petnose/secrets/
/opt/petnose/uploads/
/opt/petnose/backups/
```

Do not use g4dn instance store for MySQL, Qdrant, uploads, model checkpoints, or
secrets. Instance store is not the rollback or stop/start durability boundary.

## Model Artifact

The required checkpoint path is:

```text
/opt/petnose/models/dog_nose_identification2/logs/s101_224/model_final.pth
```

The model directory is mounted read-only into the Python Embed container at:

```text
/models/dog_nose_identification2
```

Do not commit the checkpoint to Git and do not bake it into Docker images.
ONNX files, YOLO weights, Firebase service account JSON, JWT secrets, `.env`,
raw dog images, and raw vectors also stay out of Git and images.

## Profile-first YOLO Demo Artifacts

The profile-first YOLO runtime is a demo-only opt-in path for g4dn validation.
It uses the same dog-nose embedding checkpoint plus external YOLO assets mounted
read-only into the Python Embed container:

```text
/opt/petnose-lab/artifacts/yolo/best.pt
/opt/petnose-lab/vendor/yolov05
```

Container paths are fixed by `compose.prod-profile-first-yolo.yaml`:

```text
/models/yolo/best.pt
/models/yolov05
```

Do not copy YOLO weights or the YOLOv5 repository into Git or Docker images.
Treat the `.pt` checkpoint and legacy YOLOv5 code as trusted server-local demo
artifacts only. Production default remains profile-first off and YOLO off.

## Environment

Create `infra/docker/.env` on the server from `.env.example` and set production
values. Use immutable `main-<sha7>` tags in production:

```dotenv
APP_ENV=prod
SPRING_PROFILES_ACTIVE=prod

SPRING_API_IMAGE=ghcr.io/jaaesung/petnose-spring-api:main-<sha7>
PYTHON_EMBED_GPU_REAL_IMAGE=ghcr.io/jaaesung/petnose-python-embed-gpu-real:main-<sha7>

DOG_NOSE_RUNTIME=torch
DOG_NOSE_EXTRACT_ENABLED=false
PETNOSE_PROFILE_FIRST_ENABLED=false
PETNOSE_REGISTRATION_TIMING_LOG_ENABLED=false

EMBED_MODEL=dog-nose-identification2
EMBED_VECTOR_DIM=2048
EMBED_DEVICE=cuda:0
EMBED_DEVICE_REQUIRED=true
PYTHON_EMBED_INSTALL_REAL_DEPS=1

DOG_NOSE_MODEL_DIR_HOST=/opt/petnose/models/dog_nose_identification2

QDRANT_COLLECTION=dog_nose_embeddings_real_v2
QDRANT_VECTOR_DIM=2048
QDRANT_DISTANCE=Cosine
```

Production GPU deploys must not use `main-latest`, `develop-latest`, or
`develop-<sha7>`. Develop validation may use `develop-latest` or
`develop-<sha7>` on the dev server only.

### Demo-only profile-first YOLO env

For a develop/g4dn demo runtime only, keep `APP_ENV` non-prod and opt in:

```dotenv
APP_ENV=dev
SPRING_PROFILES_ACTIVE=prod

SPRING_API_IMAGE=ghcr.io/jaaesung/petnose-spring-api:develop-<sha7>
PYTHON_EMBED_GPU_REAL_IMAGE=ghcr.io/jaaesung/petnose-python-embed-gpu-real:develop-<sha7>

PETNOSE_INCLUDE_GPU=true
PETNOSE_INCLUDE_PROFILE_FIRST_YOLO=true

DOG_NOSE_RUNTIME=torch
DOG_NOSE_EXTRACT_ENABLED=true
PETNOSE_PROFILE_FIRST_ENABLED=true
PETNOSE_REGISTRATION_TIMING_LOG_ENABLED=false

EMBED_DEVICE=cuda:0
EMBED_DEVICE_REQUIRED=true
DOG_NOSE_DETECTOR_WEIGHTS_HOST=/opt/petnose-lab/artifacts/yolo/best.pt
DOG_NOSE_YOLOV5_REPO_HOST=/opt/petnose-lab/vendor/yolov05

QDRANT_COLLECTION=dog_nose_embeddings_real_v2
QDRANT_VECTOR_DIM=2048
QDRANT_DISTANCE=Cosine
```

The deploy script maps these host paths to `/models/yolo/best.pt` and
`/models/yolov05`, sets `DOG_NOSE_DETECTOR_DEVICE=cuda:0`, and keeps
`DOG_NOSE_RUNTIME=torch`. ONNX Runtime is not enabled in this demo path.

For clean `-RequireNormalRegistration` demo evidence, do not delete or reset an
existing Qdrant collection. Point this demo runtime at a temporary collection
instead, for example:

```bash
QDRANT_COLLECTION="dog_nose_embeddings_profile_first_demo_$(date -u +%Y%m%d%H%M%S)"
```

Keep `QDRANT_VECTOR_DIM=2048` and `QDRANT_DISTANCE=Cosine`. This lets the clean
profile-first registration and duplicate-block path be verified without
resetting MySQL, Qdrant volumes, or the active real-model collection.

## Deploy

The GPU path uses these compose files in order:

```text
infra/docker/compose.yaml
infra/docker/compose.prod.yaml
infra/docker/compose.prod-real-model.yaml
infra/docker/compose.prod-gpu.yaml
```

The profile-first YOLO demo path adds one final override:

```text
infra/docker/compose.prod-profile-first-yolo.yaml
```

Validate the compose output:

```bash
docker compose --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.prod.yaml \
  -f infra/docker/compose.prod-real-model.yaml \
  -f infra/docker/compose.prod-gpu.yaml \
  config
```

Deploy:

```bash
bash infra/scripts/deploy-real-model.sh --gpu
```

The script fails before success output if NVIDIA preflight, production runtime
policy, compose config, image pull, container startup, Spring health, Python
readiness, or CUDA runtime checks fail.

For the demo-only profile-first YOLO runtime:

```bash
bash infra/scripts/deploy-real-model.sh --profile-first-yolo
```

This implies the GPU override, requires non-prod `APP_ENV`, verifies the
external YOLO host paths before deploy, and performs a Python container check
that the legacy YOLOv5 detector is loaded on CUDA. It also requires
`QDRANT_COLLECTION` to be set so the profile-first demo can intentionally use
either the normal real-model collection or a temporary clean collection.

## Readiness Checks

After deployment:

```bash
curl -fsS http://localhost/actuator/health

docker compose --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.prod.yaml \
  -f infra/docker/compose.prod-real-model.yaml \
  -f infra/docker/compose.prod-gpu.yaml \
  exec -T python-embed python - <<'PY'
import json
import urllib.request

with urllib.request.urlopen("http://localhost:8000/health/ready", timeout=5) as response:
    body = json.load(response)

assert body["status"] in {"ok", "ready"}, body
assert body["model_loaded"] is True, body
assert body["backend"] == "torch+timm", body
assert body["vector_dim"] == 2048, body
assert str(body["model"]).startswith("dog-nose-identification2"), body
assert str(body["device"]).startswith("cuda"), body
assert body["device_required"] is True, body
assert body["device_required_satisfied"] is True, body
assert body["model_path_exists"] is True, body
print(body)
PY
```

Verify CUDA from inside the container:

```bash
nvidia-smi

docker compose --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.prod.yaml \
  -f infra/docker/compose.prod-real-model.yaml \
  -f infra/docker/compose.prod-gpu.yaml \
  exec -T python-embed python - <<'PY'
import torch

assert torch.version.cuda is not None
assert torch.cuda.is_available()
print(torch.version.cuda)
print(torch.cuda.get_device_name(0))
PY
```

## Smoke Procedure

Use sanitized test data outside the repository. Do not store raw images or raw
vectors in Git evidence.

1. Confirm `GET /actuator/health` is healthy through Nginx.
2. Confirm `GET /health/ready` inside `python-embed` reports CUDA, `torch+timm`,
   `model_loaded=true`, and `vector_dim=2048`.
3. Register a dog with exactly five close-up cropped `nose_images`.
4. Repeat registration with the same dog images and confirm duplicate handling.
5. Create an adoption post for the registered dog.
6. Run handover verification with a new `nose_image`.
7. Check that MySQL, Qdrant, and uploaded files remain internally reachable only.

## Profile-first YOLO Demo Smoke

Run through an SSH tunnel or on an admin machine that can reach Nginx. Use
fixtures stored outside the repository.

```powershell
pwsh -NoProfile -File .\scripts\profile-first-yolo-demo-smoke.ps1 `
  -RootUrl "http://localhost:18080" `
  -BaseUrl "http://localhost:18080/api" `
  -ProfileImagePath "<profile-image>" `
  -NoseImageDir "<matching-five-nose-images>" `
  -MismatchNoseImageDir "<other-dog-five-nose-images>" `
  -RequireNormalRegistration `
  -WriteEvidence `
  -OutputDir "C:\tmp\petnose-profile-first-yolo-demo-smoke"
```

The script verifies:

- `POST /api/dogs/profile-draft`
- `POST /api/dogs/{dog_id}/nose-verification`
- profile preview extraction through YOLO
- profile mismatch leaves the dog `PENDING`, stores no public owner
  `nose_image_url`, and blocks post creation
- profile match pass can register the PENDING dog and then create a post
- duplicate suspected dog blocks post creation
- backward-compatible `POST /api/dogs/register` still works

Use `-RequireNormalRegistration` only with a clean Qdrant collection or unique
fixture set. If the same nose images already exist, the correct result is
`DUPLICATE_SUSPECTED`; rerun with a fresh collection/fixtures to prove the
normal Qdrant upsert path.

Never delete an existing Qdrant collection, run `docker compose down -v`, or
reset MySQL/Qdrant volumes just to get clean smoke evidence. Use a temporary
collection name such as
`dog_nose_embeddings_profile_first_demo_20260622104732`, redeploy with
`bash infra/scripts/deploy-real-model.sh --profile-first-yolo`, then run the
same smoke command. The temporary collection proves the clean registration path
while leaving existing runtime data intact.

## Stop/Start Durability Check

After a stop/start or reboot:

```bash
nvidia-smi
test -f /opt/petnose/models/dog_nose_identification2/logs/s101_224/model_final.pth
docker compose --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.prod.yaml \
  -f infra/docker/compose.prod-real-model.yaml \
  -f infra/docker/compose.prod-gpu.yaml \
  up -d --no-build
curl -fsS http://localhost/actuator/health
```

Confirm existing MySQL data, Qdrant storage, uploads, model checkpoint, and
secrets are still present on EBS-backed paths.

## Rollback

Rollback does not delete persistent data.

1. Remove `infra/docker/compose.prod-gpu.yaml` from the compose invocation, or
   set `PETNOSE_INCLUDE_GPU=false`.
2. Pin `PYTHON_EMBED_REAL_IMAGE` to the previous known-good CPU real-model
   `main-<sha7>` tag.
3. Set `EMBED_DEVICE=cpu` and `EMBED_DEVICE_REQUIRED=false`.
4. Keep `DOG_NOSE_RUNTIME=torch`, `DOG_NOSE_EXTRACT_ENABLED=false`, and
   `PETNOSE_PROFILE_FIRST_ENABLED=false`.
5. Run `docker compose config`, `pull`, and `up -d --no-build` with the CPU
   real-model compose combination.
6. Verify Spring actuator health and Python `/health/ready`.

Do not delete MySQL, Qdrant, uploads, model, or secrets volumes during rollback.
