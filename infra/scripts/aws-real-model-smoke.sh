#!/usr/bin/env bash
# Server-side smoke check for AWS EC2 real-model deployments.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCKER_DIR="${SCRIPT_DIR}/../docker"
ENV_FILE="${DOCKER_DIR}/.env"
COMPOSE_BASE="${DOCKER_DIR}/compose.yaml"
COMPOSE_PROD="${DOCKER_DIR}/compose.prod.yaml"
COMPOSE_REAL="${DOCKER_DIR}/compose.real-model.yaml"
COMPOSE_FIREBASE="${DOCKER_DIR}/compose.firebase.yaml"

EXPECTED_MODEL_KEYWORD="dog-nose-identification2"
EXPECTED_VECTOR_DIM="2048"
EXPECTED_QDRANT_COLLECTION="dog_nose_embeddings_real_v1"
INCLUDE_FIREBASE="false"

usage() {
  cat <<'EOF'
Usage: bash infra/scripts/aws-real-model-smoke.sh [--firebase]

Run a concise server-side smoke check after AWS real-model deployment.

Required env file:
  infra/docker/.env

Compose files used by default:
  infra/docker/compose.yaml
  infra/docker/compose.prod.yaml
  infra/docker/compose.real-model.yaml

Firebase is disabled by default. Include infra/docker/compose.firebase.yaml
only by passing --firebase or setting:
  PETNOSE_INCLUDE_FIREBASE=true

Expected production images:
  SPRING_API_IMAGE=ghcr.io/jaaesung/petnose-spring-api:main-<sha7>
  PYTHON_EMBED_IMAGE=ghcr.io/jaaesung/petnose-python-embed-real:main-<sha7>

Expected model checkpoint:
  /opt/petnose/models/dog_nose_identification2/logs/s101_224/model_final.pth

Checks:
  http://localhost/actuator/health through Nginx
  python-embed /health from inside the compose network
  Qdrant collection dog_nose_embeddings_real_v1 from inside the compose network

Examples:
  bash infra/scripts/aws-real-model-smoke.sh
  PETNOSE_INCLUDE_FIREBASE=true bash infra/scripts/aws-real-model-smoke.sh
  bash infra/scripts/aws-real-model-smoke.sh --firebase
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --firebase)
      INCLUDE_FIREBASE="true"
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

require_cmd docker
require_cmd curl

if ! docker compose version > /dev/null 2>&1; then
  echo "[ERROR] docker compose plugin is not available."
  exit 1
fi

require_file "${ENV_FILE}"
require_file "${COMPOSE_BASE}"
require_file "${COMPOSE_PROD}"
require_file "${COMPOSE_REAL}"

if is_true "$(read_config_var PETNOSE_INCLUDE_FIREBASE)"; then
  INCLUDE_FIREBASE="true"
fi

COMPOSE_FILES=(
  -f "${COMPOSE_BASE}"
  -f "${COMPOSE_PROD}"
  -f "${COMPOSE_REAL}"
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

echo "[INFO] AWS real-model smoke"
echo "  Firebase compose included: ${INCLUDE_FIREBASE}"

echo "[INFO] docker compose ps"
compose_real_prod ps

echo "[INFO] Nginx -> Spring actuator health"
HEALTH_STATUS="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 http://localhost/actuator/health || true)"
if [ "${HEALTH_STATUS}" != "200" ]; then
  echo "[ERROR] Expected http://localhost/actuator/health to return 200, got ${HEALTH_STATUS}"
  exit 1
fi
echo "[OK]   actuator health returned 200"

echo "[INFO] Python Embed /health inside compose network"
compose_real_prod exec -T \
  -e EXPECTED_MODEL_KEYWORD="${EXPECTED_MODEL_KEYWORD}" \
  -e EXPECTED_VECTOR_DIM="${EXPECTED_VECTOR_DIM}" \
  python-embed python - <<'PY'
import json
import os
import sys
import urllib.request

url = "http://127.0.0.1:8000/health"
expected_keyword = os.environ["EXPECTED_MODEL_KEYWORD"]
expected_dim = int(os.environ["EXPECTED_VECTOR_DIM"])

try:
    with urllib.request.urlopen(url, timeout=10) as response:
        status = response.getcode()
        body = response.read().decode("utf-8")
except Exception as exc:
    print(f"[ERROR] python-embed health request failed: {exc}", file=sys.stderr)
    sys.exit(1)

if status != 200:
    print(f"[ERROR] python-embed /health returned HTTP {status}", file=sys.stderr)
    sys.exit(1)

try:
    data = json.loads(body)
except json.JSONDecodeError as exc:
    print(f"[ERROR] python-embed /health did not return JSON: {exc}", file=sys.stderr)
    sys.exit(1)

model_loaded = data.get("model_loaded")
vector_dim = data.get("vector_dim")
model = str(data.get("model", ""))

if model_loaded is not True:
    print(f"[ERROR] model_loaded must be true, got {model_loaded!r}", file=sys.stderr)
    sys.exit(1)
try:
    actual_dim = int(vector_dim)
except (TypeError, ValueError):
    print(f"[ERROR] vector_dim must be numeric, got {vector_dim!r}", file=sys.stderr)
    sys.exit(1)
if actual_dim != expected_dim:
    print(f"[ERROR] vector_dim must be {expected_dim}, got {vector_dim!r}", file=sys.stderr)
    sys.exit(1)
if expected_keyword not in model:
    print(f"[ERROR] model must contain {expected_keyword!r}, got {model!r}", file=sys.stderr)
    sys.exit(1)

print(f"[OK]   python-embed model={model} vector_dim={vector_dim} model_loaded=true")
PY

echo "[INFO] Qdrant real-model collection inside compose network"
compose_real_prod exec -T \
  -e EXPECTED_QDRANT_COLLECTION="${EXPECTED_QDRANT_COLLECTION}" \
  -e EXPECTED_VECTOR_DIM="${EXPECTED_VECTOR_DIM}" \
  python-embed python - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

collection = os.environ["EXPECTED_QDRANT_COLLECTION"]
expected_dim = int(os.environ["EXPECTED_VECTOR_DIM"])
url = f"http://qdrant:6333/collections/{collection}"

try:
    with urllib.request.urlopen(url, timeout=10) as response:
        status = response.getcode()
        body = response.read().decode("utf-8")
except urllib.error.HTTPError as exc:
    print(f"[ERROR] Qdrant collection {collection!r} request returned HTTP {exc.code}", file=sys.stderr)
    sys.exit(1)
except Exception as exc:
    print(f"[ERROR] Qdrant collection request failed: {exc}", file=sys.stderr)
    sys.exit(1)

if status != 200:
    print(f"[ERROR] Qdrant collection {collection!r} returned HTTP {status}", file=sys.stderr)
    sys.exit(1)

try:
    data = json.loads(body)
except json.JSONDecodeError as exc:
    print(f"[ERROR] Qdrant collection response did not return JSON: {exc}", file=sys.stderr)
    sys.exit(1)

vectors = (
    data.get("result", {})
    .get("config", {})
    .get("params", {})
    .get("vectors")
)

def vector_size(value):
    if isinstance(value, dict):
        if "size" in value:
            return value.get("size")
        for nested in value.values():
            if isinstance(nested, dict) and "size" in nested:
                return nested.get("size")
    return None

size = vector_size(vectors)
if size is None:
    print(f"[WARN] Qdrant collection {collection} exists, but vector size was not returned")
else:
    try:
        actual_size = int(size)
    except (TypeError, ValueError):
        print(f"[ERROR] Qdrant vector size must be numeric, got {size!r}", file=sys.stderr)
        sys.exit(1)
    if actual_size != expected_dim:
        print(f"[ERROR] Qdrant vector size must be {expected_dim}, got {size!r}", file=sys.stderr)
        sys.exit(1)
    print(f"[OK]   Qdrant collection={collection} vector_size={size}")
PY

echo "[OK] AWS real-model smoke passed."
