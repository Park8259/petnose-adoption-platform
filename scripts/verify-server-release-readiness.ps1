<#
.SYNOPSIS
Verifies PetNose main release server deployment readiness.

.DESCRIPTION
Checks the production env file, required server-side secrets/artifacts, Docker
Compose config, optional health, and whether forbidden server-only files are
tracked by git. The script does not print secret values, service account private
keys, client emails, tokens, or env contents.

.EXAMPLE
pwsh ./scripts/verify-server-release-readiness.ps1 -EnvFile infra/docker/.env -IncludeFirebase

.EXAMPLE
pwsh ./scripts/verify-server-release-readiness.ps1 -EnvFile infra/docker/.env -IncludeFirebase -HealthCheck
#>
[CmdletBinding()]
param(
    [string]$EnvFile = "infra/docker/.env",
    [string[]]$ComposeFile = @(
        "infra/docker/compose.yaml",
        "infra/docker/compose.prod.yaml",
        "infra/docker/compose.prod-real-model.yaml"
    ),
    [switch]$IncludeFirebase,
    [switch]$SkipComposeConfig,
    [switch]$HealthCheck,
    [string]$HealthUrl = "http://localhost/actuator/health",
    [int]$HealthTimeoutSeconds = 60,
    [int]$HealthIntervalSeconds = 3,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:Results = New-Object 'System.Collections.Generic.List[object]'
$script:FailedCount = 0
$script:WarnCount = 0

function Show-Usage {
    @"
Usage:
  pwsh ./scripts/verify-server-release-readiness.ps1 [options]

Options:
  -EnvFile <path>              Default: infra/docker/.env
  -ComposeFile <path[]>        Default: base + prod + prod-real-model
  -IncludeFirebase             Include infra/docker/compose.firebase.yaml and require Firebase credential checks
  -SkipComposeConfig           Skip docker compose config validation
  -HealthCheck                 Run optional HTTP health check
  -HealthUrl <url>             Default: http://localhost/actuator/health
  -HealthTimeoutSeconds <int>  Default: 60
  -HealthIntervalSeconds <int> Default: 3
  -Help                        Print this help text

Expected server paths:
  /opt/petnose/infra/docker/.env
  /opt/petnose/secrets/firebase-service-account.json
  /opt/petnose/models/dog_nose_identification2/logs/s101_224/model_final.pth
"@
}

if ($Help) {
    Show-Usage
    exit 0
}

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $script:RepoRoot $Path))
}

function Add-Result {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet("PASS", "FAIL", "WARN", "SKIP")][string]$Status,
        [string]$Note = ""
    )

    $script:Results.Add([pscustomobject]@{
        name = $Name
        status = $Status
        note = $Note
    }) | Out-Null

    switch ($Status) {
        "FAIL" { $script:FailedCount++ }
        "WARN" { $script:WarnCount++ }
    }
}

function Test-TrueValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return $false
    }

    $text = ([string]$Value).Trim().ToLowerInvariant()
    return @("true", "1", "yes", "y", "on") -contains $text
}

function ConvertFrom-EnvFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = @{}
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        if ($trimmed -notmatch "^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$") {
            continue
        }

        $key = $Matches[1]
        $value = $Matches[2].Trim()
        if ($value.Length -ge 2) {
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $values[$key] = $value
    }

    return $values
}

function Get-EnvValue {
    param(
        [Parameter(Mandatory = $true)][hashtable]$EnvMap,
        [Parameter(Mandatory = $true)][string]$Key
    )

    if ($EnvMap.ContainsKey($Key)) {
        return [string]$EnvMap[$Key]
    }

    return $null
}

function Test-RequiredEnvKeys {
    param(
        [Parameter(Mandatory = $true)][hashtable]$EnvMap,
        [Parameter(Mandatory = $true)][string[]]$Keys
    )

    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in $Keys) {
        if (-not $EnvMap.ContainsKey($key)) {
            $missing.Add($key) | Out-Null
        }
    }

    if ($missing.Count -eq 0) {
        Add-Result -Name "required env keys" -Status "PASS" -Note "$($Keys.Count) keys present"
    } else {
        Add-Result -Name "required env keys" -Status "FAIL" -Note "missing: $($missing -join ', ')"
    }
}

function Test-EnvPlaceholders {
    param([Parameter(Mandatory = $true)][hashtable]$EnvMap)

    $placeholderKeys = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in $EnvMap.Keys) {
        $value = [string]$EnvMap[$key]
        if ($value -match "^<[^>]+>$") {
            $placeholderKeys.Add([string]$key) | Out-Null
        }
    }

    if ($placeholderKeys.Count -eq 0) {
        Add-Result -Name "env placeholders" -Status "PASS" -Note "no placeholder-only values"
    } else {
        Add-Result -Name "env placeholders" -Status "WARN" -Note "placeholder-only values: $($placeholderKeys -join ', ')"
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 120
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    foreach ($argument in $Arguments) {
        $psi.ArgumentList.Add($argument) | Out-Null
    }
    $psi.WorkingDirectory = $script:RepoRoot
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try {
            $process.Kill()
        } catch {
        }
        throw "$File timed out after ${TimeoutSeconds}s."
    }

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        StdOut = $stdoutTask.GetAwaiter().GetResult()
        StdErr = $stderrTask.GetAwaiter().GetResult()
    }
}

function Test-Docker {
    try {
        $dockerVersion = Invoke-Native -File "docker" -Arguments @("--version") -TimeoutSeconds 20
        if ($dockerVersion.ExitCode -eq 0) {
            Add-Result -Name "docker version" -Status "PASS" -Note ($dockerVersion.StdOut.Trim())
        } else {
            Add-Result -Name "docker version" -Status "FAIL" -Note ($dockerVersion.StdErr.Trim())
            return
        }
    } catch {
        Add-Result -Name "docker version" -Status "FAIL" -Note $_.Exception.Message
        return
    }

    try {
        $composeVersion = Invoke-Native -File "docker" -Arguments @("compose", "version") -TimeoutSeconds 20
        if ($composeVersion.ExitCode -eq 0) {
            Add-Result -Name "docker compose version" -Status "PASS" -Note ($composeVersion.StdOut.Trim())
        } else {
            Add-Result -Name "docker compose version" -Status "FAIL" -Note ($composeVersion.StdErr.Trim())
        }
    } catch {
        Add-Result -Name "docker compose version" -Status "FAIL" -Note $_.Exception.Message
    }

    try {
        $dockerInfo = Invoke-Native -File "docker" -Arguments @("info", "--format", "{{.ServerVersion}}") -TimeoutSeconds 30
        if ($dockerInfo.ExitCode -eq 0) {
            Add-Result -Name "docker daemon" -Status "PASS" -Note "daemon reachable"
        } else {
            Add-Result -Name "docker daemon" -Status "FAIL" -Note "daemon not reachable"
        }
    } catch {
        Add-Result -Name "docker daemon" -Status "FAIL" -Note $_.Exception.Message
    }
}

function Test-ServiceAccount {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedProjectId
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Add-Result -Name "firebase credential path" -Status "FAIL" -Note "FIREBASE_CREDENTIALS_HOST_PATH is empty"
        return
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Result -Name "firebase credential path" -Status "FAIL" -Note "file not found"
        return
    }

    Add-Result -Name "firebase credential path" -Status "PASS" -Note "file exists"

    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $typeOk = ([string]$json.type -eq "service_account")
        $projectOk = ([string]$json.project_id -eq $ExpectedProjectId)
        $privateKeyPresent = -not [string]::IsNullOrWhiteSpace([string]$json.private_key)
        $clientEmailPresent = -not [string]::IsNullOrWhiteSpace([string]$json.client_email)

        $note = "type_service_account=$typeOk; project_id_expected=$projectOk; private_key_present=$privateKeyPresent; client_email_present=$clientEmailPresent"
        if ($typeOk -and $projectOk -and $privateKeyPresent -and $clientEmailPresent) {
            Add-Result -Name "firebase service account json" -Status "PASS" -Note $note
        } else {
            Add-Result -Name "firebase service account json" -Status "FAIL" -Note $note
        }
    } catch {
        Add-Result -Name "firebase service account json" -Status "FAIL" -Note "JSON parse failed"
    }
}

function Test-RealModelArtifact {
    param([AllowNull()][string]$ModelDir)

    if ([string]::IsNullOrWhiteSpace($ModelDir)) {
        Add-Result -Name "real model directory" -Status "FAIL" -Note "DOG_NOSE_MODEL_DIR_HOST is empty"
        Add-Result -Name "model_final.pth" -Status "FAIL" -Note "cannot check without DOG_NOSE_MODEL_DIR_HOST"
        return
    }

    if (Test-Path -LiteralPath $ModelDir -PathType Container) {
        Add-Result -Name "real model directory" -Status "PASS" -Note "directory exists"
    } else {
        Add-Result -Name "real model directory" -Status "FAIL" -Note "directory not found"
    }

    $checkpoint = Join-Path $ModelDir "logs/s101_224/model_final.pth"
    if (Test-Path -LiteralPath $checkpoint -PathType Leaf) {
        Add-Result -Name "model_final.pth" -Status "PASS" -Note "checkpoint exists"
    } else {
        Add-Result -Name "model_final.pth" -Status "FAIL" -Note "checkpoint not found at DOG_NOSE_MODEL_DIR_HOST/logs/s101_224/model_final.pth"
    }
}

function Test-ComposeConfig {
    param(
        [Parameter(Mandatory = $true)][string]$EnvFilePath,
        [Parameter(Mandatory = $true)][string[]]$ComposeFiles
    )

    $args = @("compose", "--env-file", $EnvFilePath)
    foreach ($composeFile in $ComposeFiles) {
        $args += @("-f", $composeFile)
    }
    $args += "config"

    try {
        $result = Invoke-Native -File "docker" -Arguments $args -TimeoutSeconds 180
        if ($result.ExitCode -eq 0) {
            Add-Result -Name "compose config" -Status "PASS" -Note "$($ComposeFiles.Count) compose files"
        } else {
            $message = (($result.StdErr + " " + $result.StdOut).Trim() -replace "\s+", " ")
            if ($message.Length -gt 240) {
                $message = $message.Substring(0, 240)
            }
            Add-Result -Name "compose config" -Status "FAIL" -Note $message
        }
    } catch {
        Add-Result -Name "compose config" -Status "FAIL" -Note $_.Exception.Message
    }
}

function Test-HealthEndpoint {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSeconds,
        [int]$IntervalSeconds
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -Uri $Url -Method GET -TimeoutSec 5 -UseBasicParsing
            if ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300) {
                Add-Result -Name "health check" -Status "PASS" -Note "HTTP $($response.StatusCode)"
                return
            }
        } catch {
        }

        Start-Sleep -Seconds $IntervalSeconds
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    Add-Result -Name "health check" -Status "FAIL" -Note "no 2xx response from $Url"
}

function Test-ForbiddenTrackedFiles {
    try {
        $result = Invoke-Native -File "git" -Arguments @("ls-files") -TimeoutSeconds 30
        if ($result.ExitCode -ne 0) {
            Add-Result -Name "forbidden tracked files" -Status "WARN" -Note "git ls-files unavailable"
            return
        }

        $forbidden = New-Object 'System.Collections.Generic.List[string]'
        $paths = $result.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        foreach ($path in $paths) {
            $normalized = $path -replace "\\", "/"
            $leaf = [System.IO.Path]::GetFileName($normalized)

            $isEnv = ($leaf -like ".env*") -and ($leaf -ne ".env.example")
            $isServiceAccount = ($leaf -like "firebase-service-account*.json") -or ($leaf -like "*-firebase-adminsdk-*.json") -or ($leaf -like "serviceAccountKey*.json")
            $isModel = $leaf -match "\.(pt|pth|ckpt|onnx|h5|keras|safetensors)$"

            if ($normalized -eq "infra/docker/.env" -or $isEnv -or $isServiceAccount -or $isModel) {
                $forbidden.Add($normalized) | Out-Null
            }
        }

        if ($forbidden.Count -eq 0) {
            Add-Result -Name "forbidden tracked files" -Status "PASS" -Note "no tracked .env/service account/model files"
        } else {
            Add-Result -Name "forbidden tracked files" -Status "FAIL" -Note ($forbidden -join ", ")
        }
    } catch {
        Add-Result -Name "forbidden tracked files" -Status "WARN" -Note $_.Exception.Message
    }
}

$envFilePath = Resolve-RepoPath $EnvFile
Write-Host "PetNose main release server readiness"
Write-Host "Repo root: $script:RepoRoot"
Write-Host "Env file: $envFilePath"

if (-not (Test-Path -LiteralPath $envFilePath -PathType Leaf)) {
    Add-Result -Name "env file" -Status "FAIL" -Note "file not found"
    $envMap = @{}
} else {
    Add-Result -Name "env file" -Status "PASS" -Note "file exists"
    $envMap = ConvertFrom-EnvFile -Path $envFilePath
}

$requiredKeys = @(
    "APP_ENV",
    "SPRING_PROFILES_ACTIVE",
    "SPRING_API_IMAGE",
    "PYTHON_EMBED_REAL_IMAGE",
    "MYSQL_DATABASE",
    "MYSQL_USER",
    "MYSQL_PASSWORD",
    "MYSQL_ROOT_PASSWORD",
    "SPRING_DATASOURCE_URL",
    "SPRING_DATASOURCE_USERNAME",
    "SPRING_DATASOURCE_PASSWORD",
    "AUTH_JWT_SECRET",
    "AUTH_JWT_ACCESS_TOKEN_TTL_SECONDS",
    "EMBED_MODEL",
    "EMBED_VECTOR_DIM",
    "PYTHON_EMBED_INSTALL_REAL_DEPS",
    "DOG_NOSE_MODEL_DIR_HOST",
    "QDRANT_COLLECTION",
    "QDRANT_VECTOR_DIM",
    "QDRANT_DISTANCE",
    "FIREBASE_ENABLED",
    "PETNOSE_INCLUDE_FIREBASE",
    "FIREBASE_PROJECT_ID",
    "FIREBASE_CREDENTIALS_HOST_PATH",
    "AUTH_PASSWORD_RESET_EMAIL_ENABLED",
    "AUTH_PASSWORD_RESET_EXPOSE_TOKEN_IN_RESPONSE",
    "AUTH_PASSWORD_RESET_URL_TEMPLATE",
    "AUTH_PASSWORD_RESET_MAIL_FROM",
    "MAIL_HOST",
    "MAIL_PORT",
    "MAIL_USERNAME",
    "MAIL_PASSWORD",
    "MAIL_SMTP_AUTH",
    "MAIL_SMTP_STARTTLS_ENABLE",
    "MAIL_SMTP_CONNECTION_TIMEOUT_MS",
    "MAIL_SMTP_TIMEOUT_MS",
    "MAIL_SMTP_WRITE_TIMEOUT_MS",
    "MANAGEMENT_HEALTH_MAIL_ENABLED",
    "NGINX_PORT",
    "UPLOAD_BASE_PATH",
    "MAX_UPLOAD_SIZE_MB"
)

Test-RequiredEnvKeys -EnvMap $envMap -Keys $requiredKeys
Test-EnvPlaceholders -EnvMap $envMap

$firebaseEnabled = $IncludeFirebase -or (Test-TrueValue (Get-EnvValue -EnvMap $envMap -Key "FIREBASE_ENABLED")) -or (Test-TrueValue (Get-EnvValue -EnvMap $envMap -Key "PETNOSE_INCLUDE_FIREBASE"))
if ($firebaseEnabled) {
    $firebasePath = Get-EnvValue -EnvMap $envMap -Key "FIREBASE_CREDENTIALS_HOST_PATH"
    Test-ServiceAccount -Path $firebasePath -ExpectedProjectId "petnose-c6ec5"
} else {
    Add-Result -Name "firebase service account json" -Status "SKIP" -Note "Firebase disabled"
}

$realModelEnabled = ((Get-EnvValue -EnvMap $envMap -Key "EMBED_MODEL") -eq "dog-nose-identification2") -or
    (Test-TrueValue (Get-EnvValue -EnvMap $envMap -Key "PYTHON_EMBED_INSTALL_REAL_DEPS")) -or
    (-not [string]::IsNullOrWhiteSpace((Get-EnvValue -EnvMap $envMap -Key "PYTHON_EMBED_REAL_IMAGE")))

if ($realModelEnabled) {
    Test-RealModelArtifact -ModelDir (Get-EnvValue -EnvMap $envMap -Key "DOG_NOSE_MODEL_DIR_HOST")
} else {
    Add-Result -Name "real model directory" -Status "SKIP" -Note "real-model env not enabled"
    Add-Result -Name "model_final.pth" -Status "SKIP" -Note "real-model env not enabled"
}

$composeFilesResolved = New-Object 'System.Collections.Generic.List[string]'
foreach ($path in $ComposeFile) {
    $resolved = Resolve-RepoPath $path
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        Add-Result -Name "compose file: $path" -Status "PASS" -Note "file exists"
        $composeFilesResolved.Add($resolved) | Out-Null
    } else {
        Add-Result -Name "compose file: $path" -Status "FAIL" -Note "missing"
    }
}

if ($firebaseEnabled) {
    $firebaseCompose = Resolve-RepoPath "infra/docker/compose.firebase.yaml"
    if ($composeFilesResolved -notcontains $firebaseCompose) {
        if (Test-Path -LiteralPath $firebaseCompose -PathType Leaf) {
            Add-Result -Name "compose file: infra/docker/compose.firebase.yaml" -Status "PASS" -Note "file exists"
            $composeFilesResolved.Add($firebaseCompose) | Out-Null
        } else {
            Add-Result -Name "compose file: infra/docker/compose.firebase.yaml" -Status "FAIL" -Note "missing"
        }
    }
}

Test-Docker

if ($SkipComposeConfig) {
    Add-Result -Name "compose config" -Status "SKIP" -Note "skipped by -SkipComposeConfig"
} elseif ($composeFilesResolved.Count -gt 0 -and (Test-Path -LiteralPath $envFilePath -PathType Leaf)) {
    Test-ComposeConfig -EnvFilePath $envFilePath -ComposeFiles $composeFilesResolved.ToArray()
} else {
    Add-Result -Name "compose config" -Status "FAIL" -Note "missing env or compose files"
}

if ($HealthCheck) {
    Test-HealthEndpoint -Url $HealthUrl -TimeoutSeconds $HealthTimeoutSeconds -IntervalSeconds $HealthIntervalSeconds
} else {
    Add-Result -Name "health check" -Status "SKIP" -Note "not requested"
}

Test-ForbiddenTrackedFiles

Write-Host ""
Write-Host "Result summary"
$script:Results | Format-Table -AutoSize
Write-Host "Failures: $script:FailedCount"
Write-Host "Warnings: $script:WarnCount"

if ($script:FailedCount -gt 0) {
    exit 1
}

exit 0
