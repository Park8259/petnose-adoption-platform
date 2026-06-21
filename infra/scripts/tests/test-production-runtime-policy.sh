#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DEPLOY_SCRIPT="${REPO_ROOT}/infra/scripts/deploy-real-model.sh"
TEMP_DIR="$(mktemp -d)"
SECRET_MARKER="PETNOSE_TEST_SECRET_MARKER_DO_NOT_PRINT"

cleanup() {
  rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

fail() {
  echo "[FAIL] $*"
  exit 1
}

assert_contains() {
  local path="$1"
  local expected="$2"
  grep -Fq "${expected}" "${path}" || fail "Expected output to contain: ${expected}"
}

assert_not_contains() {
  local path="$1"
  local unexpected="$2"
  if grep -Fq "${unexpected}" "${path}"; then
    fail "Unexpected output contained sensitive text."
  fi
}

write_safe_env() {
  local path="$1"
  cat > "${path}" <<EOF
APP_ENV=prod
SPRING_PROFILES_ACTIVE=prod
SPRING_API_IMAGE=ghcr.io/jaaesung/petnose-spring-api:main-8edd2dc
PYTHON_EMBED_REAL_IMAGE=ghcr.io/jaaesung/petnose-python-embed-real:main-8edd2dc
MYSQL_PASSWORD=${SECRET_MARKER}
MYSQL_ROOT_PASSWORD=${SECRET_MARKER}
SPRING_DATASOURCE_PASSWORD=${SECRET_MARKER}
AUTH_JWT_SECRET=${SECRET_MARKER}
DOG_NOSE_RUNTIME=torch
DOG_NOSE_EXTRACT_ENABLED=false
PETNOSE_PROFILE_FIRST_ENABLED=false
PETNOSE_REGISTRATION_TIMING_LOG_ENABLED=false
EMBED_MODEL=dog-nose-identification2
EMBED_VECTOR_DIM=2048
PYTHON_EMBED_INSTALL_REAL_DEPS=1
DOG_NOSE_ONNX_PATH=
DOG_NOSE_DETECTOR_WEIGHTS=
DOG_NOSE_MODEL_DIR_HOST=/opt/petnose/models/dog_nose_identification2
EMBED_DEVICE=cpu
PETNOSE_INCLUDE_FIREBASE=false
GHCR_USERNAME=
GHCR_TOKEN=
EOF
}

set_env_value() {
  local path="$1"
  local key="$2"
  local value="$3"
  local tmp="${path}.tmp"

  awk -v key="${key}" -v value="${value}" '
    BEGIN { replaced = 0 }
    index($0, key "=") == 1 {
      print key "=" value
      replaced = 1
      next
    }
    { print }
    END {
      if (replaced == 0) {
        print key "=" value
      }
    }
  ' "${path}" > "${tmp}"
  mv "${tmp}" "${path}"
}

run_deploy_script() {
  local env_path="$1"
  local output_path="$2"
  shift 2

  PETNOSE_DEPLOY_ENV_FILE="${env_path}" bash "${DEPLOY_SCRIPT}" "$@" > "${output_path}" 2>&1
}

expect_pass() {
  local name="$1"
  local env_path="${TEMP_DIR}/${name}.env"
  local output_path="${TEMP_DIR}/${name}.out"

  write_safe_env "${env_path}"
  run_deploy_script "${env_path}" "${output_path}" --validate-only || {
    cat "${output_path}"
    fail "${name} expected pass"
  }
  assert_contains "${output_path}" "[OK] inference runtime policy"
  assert_not_contains "${output_path}" "${SECRET_MARKER}"
  echo "[PASS] ${name}"
}

expect_fail() {
  local name="$1"
  local key="$2"
  local value="$3"
  local expected="$4"
  local env_path="${TEMP_DIR}/${name}.env"
  local output_path="${TEMP_DIR}/${name}.out"

  write_safe_env "${env_path}"
  set_env_value "${env_path}" "${key}" "${value}"
  if run_deploy_script "${env_path}" "${output_path}" --validate-only; then
    cat "${output_path}"
    fail "${name} expected fail"
  fi
  assert_contains "${output_path}" "${expected}"
  assert_not_contains "${output_path}" "${SECRET_MARKER}"
  echo "[PASS] ${name}"
}

expect_validation_failure_before_pull_up() {
  local env_path="${TEMP_DIR}/failure-before-pull.env"
  local output_path="${TEMP_DIR}/failure-before-pull.out"
  local stub_dir="${TEMP_DIR}/stubs"
  local docker_log="${TEMP_DIR}/docker.log"

  mkdir -p "${stub_dir}"
  : > "${docker_log}"
  write_safe_env "${env_path}"
  set_env_value "${env_path}" "DOG_NOSE_RUNTIME" "onnxruntime"

  cat > "${stub_dir}/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "${DOCKER_CALL_LOG}"
exit 0
EOF
  cat > "${stub_dir}/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "${CURL_CALL_LOG}"
exit 0
EOF
  chmod +x "${stub_dir}/docker" "${stub_dir}/curl"

  if PATH="${stub_dir}:${PATH}" \
    DOCKER_CALL_LOG="${docker_log}" \
    CURL_CALL_LOG="${TEMP_DIR}/curl.log" \
    PETNOSE_DEPLOY_ENV_FILE="${env_path}" \
    bash "${DEPLOY_SCRIPT}" > "${output_path}" 2>&1; then
    cat "${output_path}"
    fail "unsafe runtime unexpectedly passed"
  fi

  assert_contains "${output_path}" "DOG_NOSE_RUNTIME must be torch"
  if grep -Eq "docker compose .* (pull|up)" "${docker_log}"; then
    cat "${docker_log}"
    fail "docker compose pull/up was called after validation failure"
  fi
  assert_not_contains "${output_path}" "${SECRET_MARKER}"
  echo "[PASS] validation failure stops before pull/up"
}

expect_pass "safe-env"
expect_fail "unsafe-runtime" "DOG_NOSE_RUNTIME" "onnxruntime" "DOG_NOSE_RUNTIME must be torch"
expect_fail "mutable-spring-tag" "SPRING_API_IMAGE" "ghcr.io/jaaesung/petnose-spring-api:main-latest" "SPRING_API_IMAGE must be ghcr.io/jaaesung/petnose-spring-api:main-<sha7>"
expect_validation_failure_before_pull_up

echo "[OK] test-production-runtime-policy completed"
