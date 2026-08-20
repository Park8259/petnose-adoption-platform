[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:ReadinessScript = Join-Path $script:RepoRoot "scripts\verify-server-release-readiness.ps1"
$script:SecretMarker = "PETNOSE_TEST_SECRET_MARKER_DO_NOT_PRINT"
$script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("petnose-release-policy-" + [System.Guid]::NewGuid().ToString("N"))

function New-SafeEnvMap {
    [ordered]@{
        APP_ENV = "prod"
        SPRING_PROFILES_ACTIVE = "prod"
        SPRING_API_IMAGE = "ghcr.io/jaaesung/petnose-spring-api:main-8edd2dc"
        PYTHON_EMBED_REAL_IMAGE = "ghcr.io/jaaesung/petnose-python-embed-real:main-8edd2dc"
        MYSQL_DATABASE = "petnose"
        MYSQL_USER = "petnose"
        MYSQL_PASSWORD = $script:SecretMarker
        MYSQL_ROOT_PASSWORD = $script:SecretMarker
        SPRING_DATASOURCE_URL = "jdbc:mysql://mysql:3306/petnose?useSSL=false&allowPublicKeyRetrieval=true&characterEncoding=UTF-8"
        SPRING_DATASOURCE_USERNAME = "petnose"
        SPRING_DATASOURCE_PASSWORD = $script:SecretMarker
        AUTH_JWT_SECRET = $script:SecretMarker
        AUTH_JWT_ACCESS_TOKEN_TTL_SECONDS = "3600"
        EMBED_MODEL = "dog-nose-identification2"
        EMBED_VECTOR_DIM = "2048"
        DOG_NOSE_RUNTIME = "torch"
        DOG_NOSE_EXTRACT_ENABLED = "false"
        PETNOSE_PROFILE_FIRST_ENABLED = "false"
        PETNOSE_REGISTRATION_TIMING_LOG_ENABLED = "false"
        PYTHON_EMBED_INSTALL_REAL_DEPS = "1"
        DOG_NOSE_ONNX_PATH = ""
        DOG_NOSE_DETECTOR_WEIGHTS = ""
        DOG_NOSE_MODEL_DIR_HOST = "/opt/petnose/models/dog_nose_identification2"
        QDRANT_COLLECTION = "dog_nose_embeddings_real_v2"
        QDRANT_VECTOR_DIM = "2048"
        QDRANT_DISTANCE = "Cosine"
        FIREBASE_ENABLED = "false"
        PETNOSE_INCLUDE_FIREBASE = "false"
        FIREBASE_PROJECT_ID = "petnose-c6ec5"
        FIREBASE_CREDENTIALS_HOST_PATH = ""
        AUTH_PASSWORD_RESET_EMAIL_ENABLED = "false"
        AUTH_PASSWORD_RESET_EXPOSE_TOKEN_IN_RESPONSE = "false"
        AUTH_PASSWORD_RESET_URL_TEMPLATE = "https://example.com/password-reset?token={token}"
        AUTH_PASSWORD_RESET_MAIL_FROM = "no-reply@example.com"
        MAIL_HOST = ""
        MAIL_PORT = "587"
        MAIL_USERNAME = ""
        MAIL_PASSWORD = $script:SecretMarker
        MAIL_SMTP_AUTH = "true"
        MAIL_SMTP_STARTTLS_ENABLE = "true"
        MAIL_SMTP_CONNECTION_TIMEOUT_MS = "5000"
        MAIL_SMTP_TIMEOUT_MS = "3000"
        MAIL_SMTP_WRITE_TIMEOUT_MS = "5000"
        MANAGEMENT_HEALTH_MAIL_ENABLED = "false"
        NGINX_PORT = "80"
        UPLOAD_BASE_PATH = "/var/uploads"
        MAX_UPLOAD_SIZE_MB = "20"
    }
}

function Write-EnvFile {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$EnvMap)

    $path = Join-Path $script:TempDir ([System.Guid]::NewGuid().ToString("N") + ".env")
    $lines = foreach ($key in $EnvMap.Keys) {
        "$key=$($EnvMap[$key])"
    }
    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
    return $path
}

function Invoke-ReadinessPolicy {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$EnvMap)

    $envPath = Write-EnvFile -EnvMap $EnvMap
    $output = & pwsh -NoProfile -File $script:ReadinessScript -EnvFile $envPath -PolicyOnly 2>&1 |
        ForEach-Object { $_.ToString() }

    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output -join "`n")
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$ShouldPass,
        [scriptblock]$Mutate,
        [string[]]$ExpectedText = @()
    )

    $envMap = New-SafeEnvMap
    if ($null -ne $Mutate) {
        & $Mutate $envMap
    }

    $result = Invoke-ReadinessPolicy -EnvMap $envMap

    if ($ShouldPass) {
        Assert-True -Condition ($result.ExitCode -eq 0) -Message "$Name expected PASS but failed."
    } else {
        Assert-True -Condition ($result.ExitCode -ne 0) -Message "$Name expected FAIL but passed."
    }

    foreach ($text in $ExpectedText) {
        Assert-True -Condition ($result.Output -like "*$text*") -Message "$Name did not include expected sanitized output: $text"
    }

    Assert-True -Condition ($result.Output -notlike "*$script:SecretMarker*") -Message "$Name exposed a secret marker in output."
    Write-Host "[PASS] $Name"
}

New-Item -ItemType Directory -Path $script:TempDir | Out-Null

try {
    Invoke-Case -Name "safe production env" -ShouldPass $true -ExpectedText @(
        "inference runtime policy",
        "immutable image tags"
    )

    Invoke-Case -Name "DOG_NOSE_RUNTIME=onnxruntime fails" -ShouldPass $false -Mutate {
        param($envMap)
        $envMap["DOG_NOSE_RUNTIME"] = "onnxruntime"
    } -ExpectedText @("DOG_NOSE_RUNTIME must be torch")

    Invoke-Case -Name "DOG_NOSE_EXTRACT_ENABLED=true fails" -ShouldPass $false -Mutate {
        param($envMap)
        $envMap["DOG_NOSE_EXTRACT_ENABLED"] = "true"
    } -ExpectedText @("DOG_NOSE_EXTRACT_ENABLED must be false")

    Invoke-Case -Name "PETNOSE_PROFILE_FIRST_ENABLED=true fails" -ShouldPass $false -Mutate {
        param($envMap)
        $envMap["PETNOSE_PROFILE_FIRST_ENABLED"] = "true"
    } -ExpectedText @("PETNOSE_PROFILE_FIRST_ENABLED must be false")

    Invoke-Case -Name "PETNOSE_REGISTRATION_TIMING_LOG_ENABLED=true fails" -ShouldPass $false -Mutate {
        param($envMap)
        $envMap["PETNOSE_REGISTRATION_TIMING_LOG_ENABLED"] = "true"
    } -ExpectedText @("PETNOSE_REGISTRATION_TIMING_LOG_ENABLED must be false")

    Invoke-Case -Name "DOG_NOSE_ONNX_PATH fails" -ShouldPass $false -Mutate {
        param($envMap)
        $envMap["DOG_NOSE_ONNX_PATH"] = "/models/generated.onnx"
    } -ExpectedText @("DOG_NOSE_ONNX_PATH must be empty")

    Invoke-Case -Name "YOLO detector weights fail" -ShouldPass $false -Mutate {
        param($envMap)
        $envMap["DOG_NOSE_DETECTOR_WEIGHTS"] = "/models/best.pt"
    } -ExpectedText @("DOG_NOSE_DETECTOR_WEIGHTS must be empty")

    Invoke-Case -Name "SPRING_API_IMAGE=main-latest fails" -ShouldPass $false -Mutate {
        param($envMap)
        $envMap["SPRING_API_IMAGE"] = "ghcr.io/jaaesung/petnose-spring-api:main-latest"
    } -ExpectedText @("SPRING_API_IMAGE must match")

    Invoke-Case -Name "PYTHON_EMBED_REAL_IMAGE=develop tag fails" -ShouldPass $false -Mutate {
        param($envMap)
        $envMap["PYTHON_EMBED_REAL_IMAGE"] = "ghcr.io/jaaesung/petnose-python-embed-real:develop-8edd2dc"
    } -ExpectedText @("PYTHON_EMBED_REAL_IMAGE must match")

    Invoke-Case -Name "required runtime key missing fails" -ShouldPass $false -Mutate {
        param($envMap)
        $envMap.Remove("DOG_NOSE_RUNTIME")
    } -ExpectedText @("missing: DOG_NOSE_RUNTIME")

    Invoke-Case -Name "placeholder-only values warn" -ShouldPass $true -Mutate {
        param($envMap)
        $envMap["FIREBASE_PROJECT_ID"] = "<firebase-project-id>"
    } -ExpectedText @("env placeholders", "WARN")

    Write-Host "[OK] verify-server-release-policy completed"
} finally {
    Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
