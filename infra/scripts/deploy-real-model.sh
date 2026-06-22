#!/usr/bin/env bash
# AWS EC2 real-model deploy script (GHCR pull-based).
# - no source build on server
# - uses base + prod + prod-real-model compose files
# - optionally includes the g4dn GPU override only when explicitly requested
# - optionally includes the demo profile-first YOLO override only when explicitly requested
# - optionally includes Firebase only when explicitly requested
# - fail-fast on the Nginx-routed Spring actuator healthcheck
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="${SCRIPT_DIR}/../docker"
ENV_FILE="${PETNOSE_DEPLOY_ENV_FILE:-${DOCKER_DIR}/.env}"
COMPOSE_BASE="${DOCKER_DIR}/compose.yaml"
COMPOSE_PROD="${DOCKER_DIR}/compose.prod.yaml"
COMPOSE_REAL_PROD="${DOCKER_DIR}/compose.prod-real-model.yaml"
COMPOSE_GPU="${DOCKER_DIR}/compose.prod-gpu.yaml"
COMPOSE_PROFILE_FIRST_YOLO="${DOCKER_DIR}/compose.prod-profile-first-yolo.yaml"
COMPOSE_FIREBASE="${DOCKER_DIR}/compose.firebase.yaml"
MODEL_CHECKPOINT_RELATIVE="logs/s101_224/model_final.pth"

SPRING_IMAGE_DEFAULT="ghcr.io/jaaesung/petnose-spring-api:main-latest"
PYTHON_REAL_IMAGE_DEFAULT="ghcr.io/jaaesung/petnose-python-embed-real:main-latest"
PYTHON_GPU_IMAGE_DEFAULT="ghcr.io/jaaesung/petnose-python-embed-gpu-real:main-latest"

INCLUDE_FIREBASE="false"
INCLUDE_GPU="false"
INCLUDE_PROFILE_FIRST_YOLO="false"
VALIDATE_ONLY="${PETNOSE_DEPLOY_VALIDATE_ONLY:-false}"

usage() {
  cat <<'EOF'
Usage: bash infra/scripts/deploy-real-model.sh [--firebase] [--gpu] [--profile-first-yolo] [--validate-only]

Deploy the AWS EC2 production stack with the real dog-nose model override.

Required env file:
  infra/docker/.env

Compose files used by default:
  infra/docker/compose.yaml
  infra/docker/compose.prod.yaml
  infra/docker/compose.prod-real-model.yaml

Firebase is disabled by default. Include infra/docker/compose.firebase.yaml
only by passing --firebase or setting:
  PETNOSE_INCLUDE_FIREBASE=true

GPU is disabled by default. Include infra/docker/compose.prod-gpu.yaml only by
passing --gpu or setting:
  PETNOSE_INCLUDE_GPU=true

Profile-first YOLO demo runtime is disabled by default. Include
infra/docker/compose.prod-profile-first-yolo.yaml only by passing
--profile-first-yolo or setting:
  PETNOSE_INCLUDE_PROFILE_FIRST_YOLO=true

This demo override implies the g4dn GPU override, requires APP_ENV to be
non-prod, mounts external YOLO assets read-only, keeps DOG_NOSE_RUNTIME=torch,
and keeps ONNX disabled.

Validation-only mode checks production env/image/runtime policy and exits before
Docker, NVIDIA, model checkpoint, GHCR login, compose pull/up, or health checks.
It is for CI/unit guardrail tests only and does not replace production readiness checks.

Expected production images:
  SPRING_API_IMAGE=ghcr.io/jaaesung/petnose-spring-api:main-<sha7>
  PYTHON_EMBED_REAL_IMAGE=ghcr.io/jaaesung/petnose-python-embed-real:main-<sha7>
  PYTHON_EMBED_GPU_REAL_IMAGE=ghcr.io/jaaesung/petnose-python-embed-gpu-real:main-<sha7>

Required .env highlights:
  DOG_NOSE_MODEL_DIR_HOST=/opt/petnose/models/dog_nose_identification2

The model checkpoint must exist at:
  $DOG_NOSE_MODEL_DIR_HOST/logs/s101_224/model_final.pth

Examples:
  bash infra/scripts/deploy-real-model.sh
  bash infra/scripts/deploy-real-model.sh --validate-only
  bash infra/scripts/deploy-real-model.sh --gpu
  bash infra/scripts/deploy-real-model.sh --profile-first-yolo
  PETNOSE_INCLUDE_GPU=true bash infra/scripts/deploy-real-model.sh
  PETNOSE_INCLUDE_PROFILE_FIRST_YOLO=true bash infra/scripts/deploy-real-model.sh
  PETNOSE_INCLUDE_FIREBASE=true bash infra/scripts/deploy-real-model.sh
  bash infra/scripts/deploy-real-model.sh --firebase
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --firebase)
      INCLUDE_FIREBASE="true"
      ;;
    --gpu)
      INCLUDE_GPU="true"
      ;;
    --profile-first-yolo)
      INCLUDE_PROFILE_FIRST_YOLO="true"
      INCLUDE_GPU="true"
      ;;
    --validate-only)
      VALIDATE_ONLY="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" > /dev/null 2>&1 || {
    echo "[ERROR] Required command not found: ${cmd}"
    exit 1
  }
}

require_file() {
  local path="$1"
  if [ ! -f "${path}" ]; then
    echo "[ERROR] Missing required file: ${path}"
    exit 1
  fi
}

strip_optional_quotes() {
  local value="$1"
  value="${value%$'\r'}"

  if [ "${#value}" -ge 2 ]; then
    if [ "${value:0:1}" = '"' ] && [ "${value: -1}" = '"' ]; then
      value="${value:1:${#value}-2}"
    elif [ "${value:0:1}" = "'" ] && [ "${value: -1}" = "'" ]; then
      value="${value:1:${#value}-2}"
    fi
  fi

  printf '%s' "${value}"
}

read_env_var() {
  local key="$1"
  local line
  line="$(grep -m1 "^${key}=" "${ENV_FILE}" || true)"
  if [ -z "${line}" ]; then
    return 0
  fi

  strip_optional_quotes "${line#*=}"
}

read_config_var() {
  local key="$1"
  local shell_value
  shell_value="$(printenv "${key}" || true)"
  if [ -n "${shell_value}" ]; then
    strip_optional_quotes "${shell_value}"
    return 0
  fi

  read_env_var "${key}"
}

is_true() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [ "${value}" = "true" ] || [ "${value}" = "1" ] || [ "${value}" = "yes" ]
}

is_false() {
  local value
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [ "${value}" = "false" ] || [ "${value}" = "0" ] || [ "${value}" = "no" ]
}

validate_production_runtime_policy() {
  local failures=0
  local app_env
  local dog_nose_runtime
  local dog_nose_extract_enabled
  local profile_first_enabled
  local timing_log_enabled
  local embed_model
  local embed_vector_dim
  local embed_device
  local embed_device_required
  local install_real_deps
  local dog_nose_onnx_path
  local dog_nose_detector_weights
  local dog_nose_detector_backend
  local dog_nose_detector_device
  local dog_nose_yolov5_repo

  app_env="$(read_config_var APP_ENV)"
  dog_nose_runtime="$(read_config_var DOG_NOSE_RUNTIME)"
  dog_nose_extract_enabled="$(read_config_var DOG_NOSE_EXTRACT_ENABLED)"
  profile_first_enabled="$(read_config_var PETNOSE_PROFILE_FIRST_ENABLED)"
  timing_log_enabled="$(read_config_var PETNOSE_REGISTRATION_TIMING_LOG_ENABLED)"
  embed_model="$(read_config_var EMBED_MODEL)"
  embed_vector_dim="$(read_config_var EMBED_VECTOR_DIM)"
  embed_device="$(read_config_var EMBED_DEVICE)"
  embed_device_required="$(read_config_var EMBED_DEVICE_REQUIRED)"
  install_real_deps="$(read_config_var PYTHON_EMBED_INSTALL_REAL_DEPS)"
  dog_nose_onnx_path="$(read_config_var DOG_NOSE_ONNX_PATH)"
  dog_nose_detector_weights="$(read_config_var DOG_NOSE_DETECTOR_WEIGHTS)"
  dog_nose_detector_backend="$(read_config_var DOG_NOSE_DETECTOR_BACKEND)"
  dog_nose_detector_device="$(read_config_var DOG_NOSE_DETECTOR_DEVICE)"
  dog_nose_yolov5_repo="$(read_config_var DOG_NOSE_YOLOV5_REPO)"

  echo "[INFO] Production inference runtime policy validation..."

  if [ "${dog_nose_runtime}" != "torch" ]; then
    echo "[ERROR] DOG_NOSE_RUNTIME must be torch for current production release."
    failures=1
  fi

  if [ "${INCLUDE_PROFILE_FIRST_YOLO}" = "true" ]; then
    if [ "${app_env:-prod}" = "prod" ]; then
      echo "[ERROR] Profile-first YOLO demo runtime requires APP_ENV to be non-prod."
      failures=1
    fi

    if ! is_true "${dog_nose_extract_enabled}"; then
      echo "[ERROR] DOG_NOSE_EXTRACT_ENABLED must be true for profile-first YOLO demo runtime."
      failures=1
    fi

    if ! is_true "${profile_first_enabled}"; then
      echo "[ERROR] PETNOSE_PROFILE_FIRST_ENABLED must be true for profile-first YOLO demo runtime."
      failures=1
    fi

    if [ "${dog_nose_detector_backend}" != "yolov5_legacy" ]; then
      echo "[ERROR] DOG_NOSE_DETECTOR_BACKEND must be yolov5_legacy for profile-first YOLO demo runtime."
      failures=1
    fi

    if [ "${dog_nose_detector_weights}" != "/models/yolo/best.pt" ]; then
      echo "[ERROR] DOG_NOSE_DETECTOR_WEIGHTS must be /models/yolo/best.pt for profile-first YOLO demo runtime."
      failures=1
    fi

    if [ "${dog_nose_yolov5_repo}" != "/models/yolov05" ]; then
      echo "[ERROR] DOG_NOSE_YOLOV5_REPO must be /models/yolov05 for profile-first YOLO demo runtime."
      failures=1
    fi

    if [ "${dog_nose_detector_device}" != "cuda:0" ]; then
      echo "[ERROR] DOG_NOSE_DETECTOR_DEVICE must be cuda:0 for profile-first YOLO demo runtime."
      failures=1
    fi
  else
    if ! is_false "${dog_nose_extract_enabled}"; then
      echo "[ERROR] DOG_NOSE_EXTRACT_ENABLED must be false for current production release."
      failures=1
    fi

    if ! is_false "${profile_first_enabled}"; then
      echo "[ERROR] PETNOSE_PROFILE_FIRST_ENABLED must be false for current production release."
      failures=1
    fi
  fi

  if ! is_false "${timing_log_enabled}"; then
    echo "[ERROR] PETNOSE_REGISTRATION_TIMING_LOG_ENABLED must be false for current production release."
    failures=1
  fi

  if [ "${embed_model}" != "dog-nose-identification2" ]; then
    echo "[ERROR] EMBED_MODEL must be dog-nose-identification2 for current production release."
    failures=1
  fi

  if [ "${embed_vector_dim}" != "2048" ]; then
    echo "[ERROR] EMBED_VECTOR_DIM must be 2048 for current production release."
    failures=1
  fi

  if ! is_true "${install_real_deps}"; then
    echo "[ERROR] PYTHON_EMBED_INSTALL_REAL_DEPS must be true or 1 for current production release."
    failures=1
  fi

  if [ -n "${dog_nose_onnx_path}" ]; then
    echo "[ERROR] DOG_NOSE_ONNX_PATH must be empty for current production release."
    failures=1
  fi

  if [ "${INCLUDE_PROFILE_FIRST_YOLO}" != "true" ] && [ -n "${dog_nose_detector_weights}" ]; then
    echo "[ERROR] DOG_NOSE_DETECTOR_WEIGHTS must be empty for current production release."
    failures=1
  fi

  if [ "${app_env:-prod}" = "prod" ]; then
    if [[ ! "${SPRING_IMAGE_EFFECTIVE}" =~ ^ghcr\.io/jaaesung/petnose-spring-api:main-[0-9a-f]{7}$ ]]; then
      echo "[ERROR] SPRING_API_IMAGE must be ghcr.io/jaaesung/petnose-spring-api:main-<sha7>."
      failures=1
    fi
  elif [[ ! "${SPRING_IMAGE_EFFECTIVE}" =~ ^ghcr\.io/jaaesung/petnose-spring-api:develop-(latest|[0-9a-f]{7})$ ]]; then
    echo "[ERROR] Non-prod SPRING_API_IMAGE must use develop-latest or develop-<sha7>."
    failures=1
  fi

  if [ "${INCLUDE_GPU}" = "true" ]; then
    if [ "${app_env:-prod}" = "prod" ]; then
      if [[ ! "${PYTHON_GPU_IMAGE_EFFECTIVE}" =~ ^ghcr\.io/jaaesung/petnose-python-embed-gpu-real:main-[0-9a-f]{7}$ ]]; then
        echo "[ERROR] PYTHON_EMBED_GPU_REAL_IMAGE must be ghcr.io/jaaesung/petnose-python-embed-gpu-real:main-<sha7>."
        failures=1
      fi
    elif [[ ! "${PYTHON_GPU_IMAGE_EFFECTIVE}" =~ ^ghcr\.io/jaaesung/petnose-python-embed-gpu-real:develop-(latest|[0-9a-f]{7})$ ]]; then
      echo "[ERROR] Non-prod PYTHON_EMBED_GPU_REAL_IMAGE must use develop-latest or develop-<sha7>."
      failures=1
    fi

    if [ "${embed_device}" != "cuda:0" ]; then
      echo "[ERROR] EMBED_DEVICE must be cuda:0 for GPU production deployment."
      failures=1
    fi

    if ! is_true "${embed_device_required}"; then
      echo "[ERROR] EMBED_DEVICE_REQUIRED must be true for GPU production deployment."
      failures=1
    fi
  else
    if [ "${app_env:-prod}" = "prod" ]; then
      if [[ ! "${PYTHON_REAL_IMAGE_EFFECTIVE}" =~ ^ghcr\.io/jaaesung/petnose-python-embed-real:main-[0-9a-f]{7}$ ]]; then
        echo "[ERROR] PYTHON_EMBED_REAL_IMAGE must be ghcr.io/jaaesung/petnose-python-embed-real:main-<sha7>."
        failures=1
      fi
    elif [[ ! "${PYTHON_REAL_IMAGE_EFFECTIVE}" =~ ^ghcr\.io/jaaesung/petnose-python-embed-real:develop-(latest|[0-9a-f]{7})$ ]]; then
      echo "[ERROR] Non-prod PYTHON_EMBED_REAL_IMAGE must use develop-latest or develop-<sha7>."
      failures=1
    fi
  fi

  if [ "${failures}" -ne 0 ]; then
    echo "[FAIL] inference runtime policy"
    return 1
  fi

  if [ "${INCLUDE_PROFILE_FIRST_YOLO}" = "true" ]; then
    echo "[OK] inference runtime policy: demo-only profile-first YOLO; torch CUDA; ONNX disabled"
  elif [ "${INCLUDE_GPU}" = "true" ]; then
    echo "[OK] inference runtime policy: torch CUDA; ONNX/YOLO/profile-first/timing disabled"
  else
    echo "[OK] inference runtime policy: torch; ONNX/YOLO/profile-first/timing disabled"
  fi
}

require_file "${ENV_FILE}"
require_file "${COMPOSE_BASE}"
require_file "${COMPOSE_PROD}"
require_file "${COMPOSE_REAL_PROD}"

if is_true "$(read_config_var PETNOSE_INCLUDE_FIREBASE)"; then
  INCLUDE_FIREBASE="true"
fi

if is_true "$(read_config_var PETNOSE_INCLUDE_GPU)"; then
  INCLUDE_GPU="true"
fi

if is_true "$(read_config_var PETNOSE_INCLUDE_PROFILE_FIRST_YOLO)"; then
  INCLUDE_PROFILE_FIRST_YOLO="true"
  INCLUDE_GPU="true"
fi

COMPOSE_FILES=(
  -f "${COMPOSE_BASE}"
  -f "${COMPOSE_PROD}"
  -f "${COMPOSE_REAL_PROD}"
)

if [ "${INCLUDE_GPU}" = "true" ]; then
  require_file "${COMPOSE_GPU}"
  COMPOSE_FILES+=(-f "${COMPOSE_GPU}")
fi

if [ "${INCLUDE_PROFILE_FIRST_YOLO}" = "true" ]; then
  require_file "${COMPOSE_PROFILE_FIRST_YOLO}"
  COMPOSE_FILES+=(-f "${COMPOSE_PROFILE_FIRST_YOLO}")
fi

if [ "${INCLUDE_FIREBASE}" = "true" ]; then
  require_file "${COMPOSE_FIREBASE}"
  COMPOSE_FILES+=(-f "${COMPOSE_FIREBASE}")
fi

compose_real_prod() {
  docker compose \
    --env-file "${ENV_FILE}" \
    "${COMPOSE_FILES[@]}" \
    "$@"
}

SPRING_IMAGE_EFFECTIVE="$(read_config_var SPRING_API_IMAGE)"
PYTHON_REAL_IMAGE_EFFECTIVE="$(read_config_var PYTHON_EMBED_REAL_IMAGE)"
PYTHON_GPU_IMAGE_EFFECTIVE="$(read_config_var PYTHON_EMBED_GPU_REAL_IMAGE)"
PYTHON_LEGACY_IMAGE_EFFECTIVE="$(read_config_var PYTHON_EMBED_IMAGE)"
DOG_NOSE_MODEL_DIR_HOST_EFFECTIVE="$(read_config_var DOG_NOSE_MODEL_DIR_HOST)"
EMBED_DEVICE_EFFECTIVE="$(read_config_var EMBED_DEVICE)"
EMBED_DEVICE_REQUIRED_EFFECTIVE="$(read_config_var EMBED_DEVICE_REQUIRED)"
DOG_NOSE_DETECTOR_WEIGHTS_HOST_EFFECTIVE="$(read_config_var DOG_NOSE_DETECTOR_WEIGHTS_HOST)"
DOG_NOSE_YOLOV5_REPO_HOST_EFFECTIVE="$(read_config_var DOG_NOSE_YOLOV5_REPO_HOST)"
GHCR_USER="$(read_config_var GHCR_USERNAME)"
GHCR_TOKEN_VALUE="$(read_config_var GHCR_TOKEN)"

SPRING_IMAGE_EFFECTIVE="${SPRING_IMAGE_EFFECTIVE:-${SPRING_IMAGE_DEFAULT}}"
PYTHON_REAL_IMAGE_EFFECTIVE="${PYTHON_REAL_IMAGE_EFFECTIVE:-${PYTHON_LEGACY_IMAGE_EFFECTIVE}}"
PYTHON_REAL_IMAGE_EFFECTIVE="${PYTHON_REAL_IMAGE_EFFECTIVE:-${PYTHON_REAL_IMAGE_DEFAULT}}"
PYTHON_GPU_IMAGE_EFFECTIVE="${PYTHON_GPU_IMAGE_EFFECTIVE:-${PYTHON_GPU_IMAGE_DEFAULT}}"

export SPRING_API_IMAGE="${SPRING_IMAGE_EFFECTIVE}"
export PYTHON_EMBED_REAL_IMAGE="${PYTHON_REAL_IMAGE_EFFECTIVE}"
export PYTHON_EMBED_GPU_REAL_IMAGE="${PYTHON_GPU_IMAGE_EFFECTIVE}"
if [ "${INCLUDE_GPU}" = "true" ]; then
  export EMBED_DEVICE="cuda:0"
  export EMBED_DEVICE_REQUIRED="true"
  EMBED_DEVICE_EFFECTIVE="cuda:0"
  EMBED_DEVICE_REQUIRED_EFFECTIVE="true"
fi
if [ "${INCLUDE_PROFILE_FIRST_YOLO}" = "true" ]; then
  export PETNOSE_PROFILE_FIRST_ENABLED="true"
  export DOG_NOSE_EXTRACT_ENABLED="true"
  export DOG_NOSE_DETECTOR_BACKEND="yolov5_legacy"
  export DOG_NOSE_DETECTOR_WEIGHTS="/models/yolo/best.pt"
  export DOG_NOSE_YOLOV5_REPO="/models/yolov05"
  export DOG_NOSE_DETECTOR_DEVICE="cuda:0"
fi

echo "[INFO] Deploy image targets"
echo "  SPRING_API_IMAGE=${SPRING_IMAGE_EFFECTIVE}"
if [ "${INCLUDE_GPU}" = "true" ]; then
  echo "  PYTHON_EMBED_GPU_REAL_IMAGE=${PYTHON_GPU_IMAGE_EFFECTIVE}"
else
  echo "  PYTHON_EMBED_REAL_IMAGE=${PYTHON_REAL_IMAGE_EFFECTIVE}"
fi
echo "[INFO] Firebase compose included: ${INCLUDE_FIREBASE}"
echo "[INFO] GPU compose included: ${INCLUDE_GPU}"
echo "[INFO] Profile-first YOLO demo compose included: ${INCLUDE_PROFILE_FIRST_YOLO}"

validate_production_runtime_policy

if is_true "${VALIDATE_ONLY}"; then
  echo "[INFO] Validation-only mode complete. Docker pull/up and health checks were not run."
  exit 0
fi

require_cmd docker
require_cmd curl

if ! docker compose version > /dev/null 2>&1; then
  echo "[ERROR] docker compose plugin is not available."
  exit 1
fi

if [ "${INCLUDE_GPU}" = "true" ]; then
  require_cmd nvidia-smi
  echo "[INFO] NVIDIA driver preflight..."
  if ! nvidia-smi > /dev/null 2>&1; then
    echo "[ERROR] nvidia-smi failed. Install and verify the NVIDIA driver before GPU deploy."
    exit 1
  fi

  echo "[INFO] Docker GPU access preflight..."
  if ! docker run --rm --gpus all nvidia/cuda:12.1.1-base-ubuntu22.04 nvidia-smi > /dev/null 2>&1; then
    echo "[ERROR] Docker cannot access NVIDIA GPUs. Install or repair NVIDIA Container Toolkit."
    exit 1
  fi
fi

if [ -z "${DOG_NOSE_MODEL_DIR_HOST_EFFECTIVE}" ]; then
  echo "[ERROR] DOG_NOSE_MODEL_DIR_HOST must be set for AWS real-model deployment."
  echo "        Example: DOG_NOSE_MODEL_DIR_HOST=/opt/petnose/models/dog_nose_identification2"
  exit 1
fi

if [ ! -d "${DOG_NOSE_MODEL_DIR_HOST_EFFECTIVE}" ]; then
  echo "[ERROR] DOG_NOSE_MODEL_DIR_HOST does not exist or is not a directory:"
  echo "        ${DOG_NOSE_MODEL_DIR_HOST_EFFECTIVE}"
  exit 1
fi

MODEL_ROOT="${DOG_NOSE_MODEL_DIR_HOST_EFFECTIVE%/}"
MODEL_CHECKPOINT_PATH="${MODEL_ROOT}/${MODEL_CHECKPOINT_RELATIVE}"
if [ ! -f "${MODEL_CHECKPOINT_PATH}" ]; then
  echo "[ERROR] Expected real-model checkpoint was not found:"
  echo "        ${MODEL_CHECKPOINT_PATH}"
  echo "        Upload model files to DOG_NOSE_MODEL_DIR_HOST before deploying."
  exit 1
fi

if [ "${INCLUDE_PROFILE_FIRST_YOLO}" = "true" ]; then
  if [ -z "${DOG_NOSE_DETECTOR_WEIGHTS_HOST_EFFECTIVE}" ]; then
    echo "[ERROR] DOG_NOSE_DETECTOR_WEIGHTS_HOST must be set for profile-first YOLO demo runtime."
    echo "        Example: DOG_NOSE_DETECTOR_WEIGHTS_HOST=/opt/petnose-lab/artifacts/yolo/best.pt"
    exit 1
  fi

  if [ ! -f "${DOG_NOSE_DETECTOR_WEIGHTS_HOST_EFFECTIVE}" ]; then
    echo "[ERROR] DOG_NOSE_DETECTOR_WEIGHTS_HOST does not exist or is not a file:"
    echo "        ${DOG_NOSE_DETECTOR_WEIGHTS_HOST_EFFECTIVE}"
    exit 1
  fi

  if [ -z "${DOG_NOSE_YOLOV5_REPO_HOST_EFFECTIVE}" ]; then
    echo "[ERROR] DOG_NOSE_YOLOV5_REPO_HOST must be set for profile-first YOLO demo runtime."
    echo "        Example: DOG_NOSE_YOLOV5_REPO_HOST=/opt/petnose-lab/vendor/yolov05"
    exit 1
  fi

  if [ ! -d "${DOG_NOSE_YOLOV5_REPO_HOST_EFFECTIVE}" ] || [ ! -f "${DOG_NOSE_YOLOV5_REPO_HOST_EFFECTIVE%/}/hubconf.py" ]; then
    echo "[ERROR] DOG_NOSE_YOLOV5_REPO_HOST must be a YOLOv5 repo directory containing hubconf.py:"
    echo "        ${DOG_NOSE_YOLOV5_REPO_HOST_EFFECTIVE}"
    exit 1
  fi
fi

if [ -n "${GHCR_USER}" ] && [ -n "${GHCR_TOKEN_VALUE}" ]; then
  echo "[INFO] GHCR login attempt..."
  printf '%s' "${GHCR_TOKEN_VALUE}" | docker login ghcr.io -u "${GHCR_USER}" --password-stdin
elif [ -n "${GHCR_USER}" ] || [ -n "${GHCR_TOKEN_VALUE}" ]; then
  echo "[ERROR] Partial GHCR credentials. Set both GHCR_USERNAME and GHCR_TOKEN."
  exit 1
else
  echo "[WARN] GHCR_USERNAME/GHCR_TOKEN not set. Assuming existing docker login or public package visibility."
fi

echo "[INFO] Compose config validation..."
compose_real_prod config > /dev/null

echo "[INFO] Pull images..."
compose_real_prod pull

echo "[INFO] Compose up (--no-build)..."
compose_real_prod up -d --no-build

check_http_with_retry() {
  local label="$1"
  local url="$2"
  local attempts="${3:-25}"
  local sleep_sec="${4:-3}"

  local i
  for i in $(seq 1 "${attempts}"); do
    if curl -sf --max-time 5 "${url}" > /dev/null 2>&1; then
      echo "[OK]   ${label} -> ${url}"
      return 0
    fi
    echo "[WAIT] ${label} (${i}/${attempts})"
    sleep "${sleep_sec}"
  done

  echo "[FAIL] ${label} -> ${url}"
  return 1
}

check_python_embed_runtime_health() {
  local expected_device="${EMBED_DEVICE_EFFECTIVE:-cpu}"
  local expected_device_required="${EMBED_DEVICE_REQUIRED_EFFECTIVE:-false}"
  local output

  if output="$(compose_real_prod exec -T python-embed env EXPECTED_EMBED_DEVICE="${expected_device}" EXPECTED_EMBED_DEVICE_REQUIRED="${expected_device_required}" python -c '
import json
import os
import sys
import urllib.request

expected_device = os.environ.get("EXPECTED_EMBED_DEVICE") or "cpu"
expected_device_required = (os.environ.get("EXPECTED_EMBED_DEVICE_REQUIRED") or "false").lower() in {"1", "true", "yes"}

try:
    with urllib.request.urlopen("http://localhost:8000/health/ready", timeout=5) as response:
        body = json.load(response)
except Exception:
    print("[FAIL] Python Embed readiness: request failed")
    sys.exit(1)

errors = []
if body.get("status") not in {"ok", "ready"}:
    errors.append("status must be ready")
if body.get("model_loaded") is not True:
    errors.append("model_loaded must be true")
backend = body.get("backend")
if backend != "torch+timm":
    errors.append("backend must be torch+timm")
device = body.get("device")
if expected_device.startswith("cuda"):
    if not str(device).startswith("cuda"):
        errors.append("device must be cuda for GPU deploy")
elif device != expected_device:
    errors.append("device must match EMBED_DEVICE")
if bool(body.get("device_required")) != expected_device_required:
    errors.append("device_required must match EMBED_DEVICE_REQUIRED")
if body.get("device_required_satisfied") is not True:
    errors.append("device_required_satisfied must be true")
if body.get("model_path_exists") is not True:
    errors.append("model_path_exists must be true")
try:
    vector_dim = int(body.get("vector_dim"))
except Exception:
    vector_dim = None
if vector_dim != 2048:
    errors.append("vector_dim must be 2048")
model = str(body.get("model", ""))
if not model.startswith("dog-nose-identification2"):
    errors.append("model must start with dog-nose-identification2")

if errors:
    print("[FAIL] Python Embed readiness: " + "; ".join(errors))
    sys.exit(1)

print(f"[OK] Python Embed readiness backend={backend} device={device} vector_dim={vector_dim} model_loaded=true")
' 2>&1)"; then
    printf '%s\n' "${output}"
    return 0
  fi

  printf '%s\n' "${output}"
  return 1
}

check_python_embed_cuda_runtime() {
  local output

  if [ "${INCLUDE_GPU}" != "true" ]; then
    return 0
  fi

  if output="$(compose_real_prod exec -T python-embed python -c '
import sys
import torch

errors = []
if torch.version.cuda is None:
    errors.append("torch.version.cuda must not be None")
if not torch.cuda.is_available():
    errors.append("torch.cuda.is_available() must be true")
device_name = None
if not errors:
    device_name = torch.cuda.get_device_name(0)
    if not device_name:
        errors.append("torch.cuda.get_device_name(0) must be non-empty")

if errors:
    print("[FAIL] Python Embed CUDA runtime: " + "; ".join(errors))
    sys.exit(1)

print(f"[OK] Python Embed CUDA runtime cuda={torch.version.cuda} device={device_name}")
' 2>&1)"; then
    printf '%s\n' "${output}"
    return 0
  fi

  printf '%s\n' "${output}"
  return 1
}

check_python_embed_profile_first_yolo_runtime() {
  local output

  if [ "${INCLUDE_PROFILE_FIRST_YOLO}" != "true" ]; then
    return 0
  fi

  if output="$(compose_real_prod exec -T python-embed python -c '
from app.nose_extraction import DogNoseExtractor

extractor = DogNoseExtractor.from_env()
errors = []
if not extractor.config.enabled:
    errors.append("DOG_NOSE_EXTRACT_ENABLED must be true")
if extractor.config.detector_backend != "yolov5_legacy":
    errors.append("detector backend must be yolov5_legacy")
if extractor.config.weights_path != "/models/yolo/best.pt":
    errors.append("detector weights path must be /models/yolo/best.pt")
if extractor.config.yolov5_repo_path != "/models/yolov05":
    errors.append("YOLOv5 repo path must be /models/yolov05")
if extractor.config.detector_device != "cuda:0":
    errors.append("detector device must be cuda:0")
if extractor.detector is None:
    errors.append("YOLO detector must be loaded")
elif not str(extractor.detector_device).startswith("cuda"):
    errors.append("YOLO detector must resolve to CUDA")

if errors:
    print("[FAIL] Python Embed profile-first YOLO runtime: " + "; ".join(errors))
    raise SystemExit(1)

print(f"[OK] Python Embed profile-first YOLO runtime detector={extractor.detector_name} device={extractor.detector_device}")
' 2>&1)"; then
    printf '%s\n' "${output}"
    return 0
  fi

  printf '%s\n' "${output}"
  return 1
}

print_failure_context() {
  echo "[INFO] docker compose ps"
  compose_real_prod ps || true

  echo "[INFO] Recent service logs"
  compose_real_prod logs --tail=200 spring-api python-embed nginx qdrant mysql || true
}

HEALTHCHECK_LABEL="spring-actuator-via-nginx"
HEALTHCHECK_URL="http://localhost/actuator/health"
HEALTHCHECK_ATTEMPTS="${DEPLOY_HEALTHCHECK_ATTEMPTS:-25}"
HEALTHCHECK_SLEEP_SEC="${DEPLOY_HEALTHCHECK_SLEEP_SEC:-3}"

echo "[INFO] Post-deploy healthcheck..."
echo "  target: ${HEALTHCHECK_URL} (${HEALTHCHECK_LABEL})"
if ! check_http_with_retry "${HEALTHCHECK_LABEL}" "${HEALTHCHECK_URL}" "${HEALTHCHECK_ATTEMPTS}" "${HEALTHCHECK_SLEEP_SEC}"; then
  print_failure_context
  exit 1
fi

echo "[INFO] Python Embed runtime healthcheck..."
if ! check_python_embed_runtime_health; then
  print_failure_context
  exit 1
fi

if [ "${INCLUDE_GPU}" = "true" ]; then
  echo "[INFO] Python Embed CUDA runtime check..."
  if ! check_python_embed_cuda_runtime; then
    print_failure_context
    exit 1
  fi
fi

if [ "${INCLUDE_PROFILE_FIRST_YOLO}" = "true" ]; then
  echo "[INFO] Python Embed profile-first YOLO runtime check..."
  if ! check_python_embed_profile_first_yolo_runtime; then
    print_failure_context
    exit 1
  fi
fi

echo "[INFO] Deploy success."
compose_real_prod ps
echo "  status: docker compose --env-file ${ENV_FILE} ${COMPOSE_FILES[*]} ps"
echo "  logs:   docker compose --env-file ${ENV_FILE} ${COMPOSE_FILES[*]} logs -f"
