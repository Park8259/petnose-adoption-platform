#!/usr/bin/env bash
# AWS EC2 real-model deploy script (GHCR pull-based).
# - no source build on server
# - uses base + prod + prod-real-model compose files
# - optionally includes Firebase only when explicitly requested
# - fail-fast on the Nginx-routed Spring actuator healthcheck
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="${SCRIPT_DIR}/../docker"
ENV_FILE="${PETNOSE_DEPLOY_ENV_FILE:-${DOCKER_DIR}/.env}"
COMPOSE_BASE="${DOCKER_DIR}/compose.yaml"
COMPOSE_PROD="${DOCKER_DIR}/compose.prod.yaml"
COMPOSE_REAL_PROD="${DOCKER_DIR}/compose.prod-real-model.yaml"
COMPOSE_FIREBASE="${DOCKER_DIR}/compose.firebase.yaml"
MODEL_CHECKPOINT_RELATIVE="logs/s101_224/model_final.pth"

SPRING_IMAGE_DEFAULT="ghcr.io/jaaesung/petnose-spring-api:main-latest"
PYTHON_REAL_IMAGE_DEFAULT="ghcr.io/jaaesung/petnose-python-embed-real:main-latest"

INCLUDE_FIREBASE="false"
VALIDATE_ONLY="${PETNOSE_DEPLOY_VALIDATE_ONLY:-false}"

usage() {
  cat <<'EOF'
Usage: bash infra/scripts/deploy-real-model.sh [--firebase] [--validate-only]

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

Validation-only mode checks production env/image/runtime policy and exits before
Docker, model checkpoint, GHCR login, compose pull/up, or health checks. It is for
CI/unit guardrail tests only and does not replace production readiness checks.

Expected production images:
  SPRING_API_IMAGE=ghcr.io/jaaesung/petnose-spring-api:main-<sha7>
  PYTHON_EMBED_REAL_IMAGE=ghcr.io/jaaesung/petnose-python-embed-real:main-<sha7>

Required .env highlights:
  DOG_NOSE_MODEL_DIR_HOST=/opt/petnose/models/dog_nose_identification2

The model checkpoint must exist at:
  $DOG_NOSE_MODEL_DIR_HOST/logs/s101_224/model_final.pth

Examples:
  bash infra/scripts/deploy-real-model.sh
  bash infra/scripts/deploy-real-model.sh --validate-only
  PETNOSE_INCLUDE_FIREBASE=true bash infra/scripts/deploy-real-model.sh
  bash infra/scripts/deploy-real-model.sh --firebase
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --firebase)
      INCLUDE_FIREBASE="true"
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
  local dog_nose_runtime
  local dog_nose_extract_enabled
  local profile_first_enabled
  local timing_log_enabled
  local embed_model
  local embed_vector_dim
  local install_real_deps
  local dog_nose_onnx_path
  local dog_nose_detector_weights

  dog_nose_runtime="$(read_config_var DOG_NOSE_RUNTIME)"
  dog_nose_extract_enabled="$(read_config_var DOG_NOSE_EXTRACT_ENABLED)"
  profile_first_enabled="$(read_config_var PETNOSE_PROFILE_FIRST_ENABLED)"
  timing_log_enabled="$(read_config_var PETNOSE_REGISTRATION_TIMING_LOG_ENABLED)"
  embed_model="$(read_config_var EMBED_MODEL)"
  embed_vector_dim="$(read_config_var EMBED_VECTOR_DIM)"
  install_real_deps="$(read_config_var PYTHON_EMBED_INSTALL_REAL_DEPS)"
  dog_nose_onnx_path="$(read_config_var DOG_NOSE_ONNX_PATH)"
  dog_nose_detector_weights="$(read_config_var DOG_NOSE_DETECTOR_WEIGHTS)"

  echo "[INFO] Production inference runtime policy validation..."

  if [ "${dog_nose_runtime}" != "torch" ]; then
    echo "[ERROR] DOG_NOSE_RUNTIME must be torch for current production release."
    failures=1
  fi

  if ! is_false "${dog_nose_extract_enabled}"; then
    echo "[ERROR] DOG_NOSE_EXTRACT_ENABLED must be false for current production release."
    failures=1
  fi

  if ! is_false "${profile_first_enabled}"; then
    echo "[ERROR] PETNOSE_PROFILE_FIRST_ENABLED must be false for current production release."
    failures=1
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

  if [ -n "${dog_nose_detector_weights}" ]; then
    echo "[ERROR] DOG_NOSE_DETECTOR_WEIGHTS must be empty for current production release."
    failures=1
  fi

  if [[ ! "${SPRING_IMAGE_EFFECTIVE}" =~ ^ghcr\.io/jaaesung/petnose-spring-api:main-[0-9a-f]{7}$ ]]; then
    echo "[ERROR] SPRING_API_IMAGE must be ghcr.io/jaaesung/petnose-spring-api:main-<sha7>."
    failures=1
  fi

  if [[ ! "${PYTHON_REAL_IMAGE_EFFECTIVE}" =~ ^ghcr\.io/jaaesung/petnose-python-embed-real:main-[0-9a-f]{7}$ ]]; then
    echo "[ERROR] PYTHON_EMBED_REAL_IMAGE must be ghcr.io/jaaesung/petnose-python-embed-real:main-<sha7>."
    failures=1
  fi

  if [ "${failures}" -ne 0 ]; then
    echo "[FAIL] inference runtime policy"
    return 1
  fi

  echo "[OK] inference runtime policy: torch; ONNX/YOLO/profile-first/timing disabled"
}

require_file "${ENV_FILE}"
require_file "${COMPOSE_BASE}"
require_file "${COMPOSE_PROD}"
require_file "${COMPOSE_REAL_PROD}"

if is_true "$(read_config_var PETNOSE_INCLUDE_FIREBASE)"; then
  INCLUDE_FIREBASE="true"
fi

COMPOSE_FILES=(
  -f "${COMPOSE_BASE}"
  -f "${COMPOSE_PROD}"
  -f "${COMPOSE_REAL_PROD}"
)

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
PYTHON_LEGACY_IMAGE_EFFECTIVE="$(read_config_var PYTHON_EMBED_IMAGE)"
DOG_NOSE_MODEL_DIR_HOST_EFFECTIVE="$(read_config_var DOG_NOSE_MODEL_DIR_HOST)"
EMBED_DEVICE_EFFECTIVE="$(read_config_var EMBED_DEVICE)"
GHCR_USER="$(read_config_var GHCR_USERNAME)"
GHCR_TOKEN_VALUE="$(read_config_var GHCR_TOKEN)"

SPRING_IMAGE_EFFECTIVE="${SPRING_IMAGE_EFFECTIVE:-${SPRING_IMAGE_DEFAULT}}"
PYTHON_REAL_IMAGE_EFFECTIVE="${PYTHON_REAL_IMAGE_EFFECTIVE:-${PYTHON_LEGACY_IMAGE_EFFECTIVE}}"
PYTHON_REAL_IMAGE_EFFECTIVE="${PYTHON_REAL_IMAGE_EFFECTIVE:-${PYTHON_REAL_IMAGE_DEFAULT}}"

export SPRING_API_IMAGE="${SPRING_IMAGE_EFFECTIVE}"
export PYTHON_EMBED_REAL_IMAGE="${PYTHON_REAL_IMAGE_EFFECTIVE}"

echo "[INFO] Deploy image targets"
echo "  SPRING_API_IMAGE=${SPRING_IMAGE_EFFECTIVE}"
echo "  PYTHON_EMBED_REAL_IMAGE=${PYTHON_REAL_IMAGE_EFFECTIVE}"
echo "[INFO] Firebase compose included: ${INCLUDE_FIREBASE}"

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
  local output

  if output="$(compose_real_prod exec -T python-embed env EXPECTED_EMBED_DEVICE="${expected_device}" python -c '
import json
import os
import sys
import urllib.request

expected_device = os.environ.get("EXPECTED_EMBED_DEVICE") or "cpu"

try:
    with urllib.request.urlopen("http://localhost:8000/health", timeout=5) as response:
        body = json.load(response)
except Exception:
    print("[FAIL] Python Embed runtime health: request failed")
    sys.exit(1)

errors = []
if body.get("status") != "ok":
    errors.append("status must be ok")
if body.get("model_loaded") is not True:
    errors.append("model_loaded must be true")
backend = body.get("backend")
if backend != "torch+timm":
    errors.append("backend must be torch+timm")
device = body.get("device")
if device != expected_device:
    errors.append("device must match EMBED_DEVICE")
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
    print("[FAIL] Python Embed runtime health: " + "; ".join(errors))
    sys.exit(1)

print(f"[OK] Python Embed backend={backend} vector_dim={vector_dim} model_loaded=true")
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

echo "[INFO] Deploy success."
compose_real_prod ps
echo "  status: docker compose --env-file ${ENV_FILE} ${COMPOSE_FILES[*]} ps"
echo "  logs:   docker compose --env-file ${ENV_FILE} ${COMPOSE_FILES[*]} logs -f"
