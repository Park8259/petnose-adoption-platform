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

assert_file_contains() {
  local path="$1"
  local expected="$2"
  if ! grep -Fq "${expected}" "${path}"; then
    fail "Expected ${path} to contain: ${expected}"
  fi
}

expect_yolo_runtime_build_config() {
  local dockerfile="${REPO_ROOT}/python-embed/Dockerfile"
  local gpu_dockerfile="${REPO_ROOT}/python-embed/Dockerfile.gpu"
  local requirements="${REPO_ROOT}/python-embed/requirements-yolo.txt"
  local publish_workflow="${REPO_ROOT}/.github/workflows/publish-images.yaml"
  local ci_workflow="${REPO_ROOT}/.github/workflows/ci.yaml"

  [ -f "${requirements}" ] || fail "Missing python-embed/requirements-yolo.txt"

  assert_file_contains "${dockerfile}" "ARG INSTALL_YOLO_RUNTIME_DEPS=0"
  assert_file_contains "${dockerfile}" "COPY requirements-yolo.txt ."
  assert_file_contains "${dockerfile}" "pip install --no-cache-dir -r requirements-yolo.txt"
  assert_file_contains "${gpu_dockerfile}" "ARG INSTALL_YOLO_RUNTIME_DEPS=0"
  assert_file_contains "${gpu_dockerfile}" "COPY requirements-yolo.txt ."
  assert_file_contains "${gpu_dockerfile}" "pip install --no-cache-dir -r requirements-yolo.txt"

  assert_file_contains "${requirements}" "opencv-python-headless=="
  assert_file_contains "${requirements}" "pandas=="
  assert_file_contains "${requirements}" "scipy=="
  assert_file_contains "${requirements}" "matplotlib=="
  assert_file_contains "${requirements}" "seaborn=="
  assert_file_contains "${requirements}" "PyYAML=="
  assert_file_contains "${requirements}" "requests=="
  assert_file_contains "${requirements}" "tqdm=="
  assert_file_contains "${requirements}" "psutil=="

  assert_file_contains "${publish_workflow}" "INSTALL_YOLO_RUNTIME_DEPS=1"
  assert_file_contains "${ci_workflow}" "YOLO_RUNTIME_IMPORTS_OK"

  echo "[PASS] yolo runtime build config"
}

write_safe_env() {
  local path="$1"
  cat > "${path}" <<EOF
APP_ENV=prod
SPRING_PROFILES_ACTIVE=prod
SPRING_API_IMAGE=ghcr.io/jaaesung/petnose-spring-api:main-8edd2dc
PYTHON_EMBED_REAL_IMAGE=ghcr.io/jaaesung/petnose-python-embed-real:main-8edd2dc
PYTHON_EMBED_GPU_REAL_IMAGE=ghcr.io/jaaesung/petnose-python-embed-gpu-real:main-8edd2dc
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
EMBED_DEVICE_REQUIRED=false
PETNOSE_INCLUDE_FIREBASE=false
PETNOSE_INCLUDE_GPU=false
PETNOSE_INCLUDE_PROFILE_FIRST_YOLO=false
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

expect_gpu_pass() {
  local name="gpu-safe-env"
  local env_path="${TEMP_DIR}/${name}.env"
  local output_path="${TEMP_DIR}/${name}.out"

  write_safe_env "${env_path}"
  set_env_value "${env_path}" "EMBED_DEVICE" "cuda:0"
  set_env_value "${env_path}" "EMBED_DEVICE_REQUIRED" "true"
  run_deploy_script "${env_path}" "${output_path}" --gpu --validate-only || {
    cat "${output_path}"
    fail "${name} expected pass"
  }
  assert_contains "${output_path}" "[OK] inference runtime policy"
  assert_contains "${output_path}" "GPU compose included: true"
  assert_not_contains "${output_path}" "${SECRET_MARKER}"
  echo "[PASS] ${name}"
}

expect_gpu_fail() {
  local name="$1"
  local key="$2"
  local value="$3"
  local expected="$4"
  local env_path="${TEMP_DIR}/${name}.env"
  local output_path="${TEMP_DIR}/${name}.out"

  write_safe_env "${env_path}"
  set_env_value "${env_path}" "EMBED_DEVICE" "cuda:0"
  set_env_value "${env_path}" "EMBED_DEVICE_REQUIRED" "true"
  set_env_value "${env_path}" "${key}" "${value}"
  if run_deploy_script "${env_path}" "${output_path}" --gpu --validate-only; then
    cat "${output_path}"
    fail "${name} expected fail"
  fi
  assert_contains "${output_path}" "${expected}"
  assert_not_contains "${output_path}" "${SECRET_MARKER}"
  echo "[PASS] ${name}"
}

write_profile_first_yolo_demo_env() {
  local path="$1"

  write_safe_env "${path}"
  set_env_value "${path}" "APP_ENV" "dev"
  set_env_value "${path}" "SPRING_API_IMAGE" "ghcr.io/jaaesung/petnose-spring-api:develop-8edd2dc"
  set_env_value "${path}" "PYTHON_EMBED_GPU_REAL_IMAGE" "ghcr.io/jaaesung/petnose-python-embed-gpu-real:develop-8edd2dc"
  set_env_value "${path}" "EMBED_DEVICE" "cuda:0"
  set_env_value "${path}" "EMBED_DEVICE_REQUIRED" "true"
  set_env_value "${path}" "DOG_NOSE_DETECTOR_WEIGHTS_HOST" "/opt/petnose-lab/artifacts/yolo/best.pt"
  set_env_value "${path}" "DOG_NOSE_YOLOV5_REPO_HOST" "/opt/petnose-lab/vendor/yolov05"
}

expect_profile_first_yolo_pass() {
  local name="$1"
  local use_env_flag="$2"
  local env_path="${TEMP_DIR}/${name}.env"
  local output_path="${TEMP_DIR}/${name}.out"
  local args=(--validate-only)

  write_profile_first_yolo_demo_env "${env_path}"
  if [ "${use_env_flag}" = "true" ]; then
    set_env_value "${env_path}" "PETNOSE_INCLUDE_PROFILE_FIRST_YOLO" "true"
  else
    args=(--profile-first-yolo --validate-only)
  fi

  run_deploy_script "${env_path}" "${output_path}" "${args[@]}" || {
    cat "${output_path}"
    fail "${name} expected pass"
  }

  assert_contains "${output_path}" "[OK] inference runtime policy: demo-only profile-first YOLO"
  assert_contains "${output_path}" "GPU compose included: true"
  assert_contains "${output_path}" "Profile-first YOLO demo compose included: true"
  assert_not_contains "${output_path}" "${SECRET_MARKER}"
  echo "[PASS] ${name}"
}

expect_profile_first_yolo_fail() {
  local name="$1"
  local key="$2"
  local value="$3"
  local expected="$4"
  local env_path="${TEMP_DIR}/${name}.env"
  local output_path="${TEMP_DIR}/${name}.out"

  write_profile_first_yolo_demo_env "${env_path}"
  set_env_value "${env_path}" "${key}" "${value}"

  if run_deploy_script "${env_path}" "${output_path}" --profile-first-yolo --validate-only; then
    cat "${output_path}"
    fail "${name} expected fail"
  fi

  assert_contains "${output_path}" "${expected}"
  assert_not_contains "${output_path}" "${SECRET_MARKER}"
  echo "[PASS] ${name}"
}

expect_pass "safe-env"
expect_fail "unsafe-runtime" "DOG_NOSE_RUNTIME" "onnxruntime" "DOG_NOSE_RUNTIME must be torch"
expect_fail "mutable-spring-tag" "SPRING_API_IMAGE" "ghcr.io/jaaesung/petnose-spring-api:main-latest" "SPRING_API_IMAGE must be ghcr.io/jaaesung/petnose-spring-api:main-<sha7>"
expect_gpu_pass
expect_gpu_fail "gpu-mutable-image-tag" "PYTHON_EMBED_GPU_REAL_IMAGE" "ghcr.io/jaaesung/petnose-python-embed-gpu-real:main-latest" "PYTHON_EMBED_GPU_REAL_IMAGE must be ghcr.io/jaaesung/petnose-python-embed-gpu-real:main-<sha7>"
expect_profile_first_yolo_pass "profile-first-yolo-flag-safe-env" "false"
expect_profile_first_yolo_pass "profile-first-yolo-env-safe-env" "true"
expect_profile_first_yolo_fail "profile-first-yolo-prod-env-fails" "APP_ENV" "prod" "Profile-first YOLO demo runtime requires APP_ENV to be non-prod"
expect_profile_first_yolo_fail "profile-first-yolo-onnx-path-fails" "DOG_NOSE_ONNX_PATH" "/models/generated.onnx" "DOG_NOSE_ONNX_PATH must be empty"
expect_profile_first_yolo_fail "profile-first-yolo-mutable-spring-fails" "SPRING_API_IMAGE" "ghcr.io/jaaesung/petnose-spring-api:main-latest" "Non-prod SPRING_API_IMAGE must use develop-latest or develop-<sha7>"
expect_validation_failure_before_pull_up
expect_yolo_runtime_build_config

echo "[OK] test-production-runtime-policy completed"
