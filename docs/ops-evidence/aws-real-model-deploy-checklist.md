# AWS Real-Model Deploy Checklist

Use this checklist for the latest `main` real-model AWS deployment path.

## Branch And Source

- [ ] Deployment branch is based on latest `origin/main`.
- [ ] Deployment branch is not based on `origin/develop`.
- [ ] No merge, rebase, or cherry-pick from `develop` was used.

## AWS Instance

- [ ] EC2 instance created.
- [ ] Elastic IP associated.
- [ ] Security group checked.
- [ ] `22/tcp` allows only my IP.
- [ ] `80/tcp` is public.
- [ ] `443/tcp` is public only after HTTPS is configured.
- [ ] `3306`, `6333`, `8080`, and `8000` are not public.

## Server Setup

- [ ] Docker installed.
- [ ] Docker Compose v2 available.
- [ ] Repository cloned to `/opt/petnose`.
- [ ] `infra/docker/.env` created on the server.
- [ ] Secrets are present only in server environment or `infra/docker/.env`.
- [ ] `/opt/petnose/secrets` exists for optional service-account files.
- [ ] `/opt/petnose/backups/mysql` exists.
- [ ] `/opt/petnose/backups/uploads` exists.

## Real Model

- [ ] Model files uploaded to `/opt/petnose/models/dog_nose_identification2`.
- [ ] Checkpoint path exists:
      `/opt/petnose/models/dog_nose_identification2/logs/s101_224/model_final.pth`.
- [ ] `DOG_NOSE_MODEL_DIR_HOST=/opt/petnose/models/dog_nose_identification2`.
- [ ] `PYTHON_EMBED_IMAGE` uses `petnose-python-embed-real`.
- [ ] `QDRANT_COLLECTION=dog_nose_embeddings_real_v1`.
- [ ] `QDRANT_VECTOR_DIM=2048`.

## Deployment Validation

- [ ] GHCR pull works.
- [ ] `bash infra/scripts/deploy-real-model.sh` passed.
- [ ] `bash infra/scripts/aws-real-model-smoke.sh` passed.
- [ ] `pwsh ./scripts/verify-real-model-mvp-flow.ps1` passed from local machine.
- [ ] Flutter app connected to AWS base URL.
- [ ] Image URLs under `/files/...` resolve against the same AWS base URL.

## Firebase

- [ ] Firebase not enabled yet.
- [ ] Or Firebase enabled later separately after core MVP smoke passed.
- [ ] Firebase service account JSON is stored outside committed source, for example
      `/opt/petnose/secrets/firebase-service-account.json`.

## Repository Hygiene

- [ ] No `.env` file committed.
- [ ] No model files committed.
- [ ] No Firebase service account JSON committed.
- [ ] No GHCR tokens or other secrets committed.
