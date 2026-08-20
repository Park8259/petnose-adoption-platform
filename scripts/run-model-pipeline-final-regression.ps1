#Requires -Version 7.0
<#
.SYNOPSIS
Runs the final PetNose model-pipeline release regression gate.

.DESCRIPTION
This runner orchestrates existing validation scripts and records one sanitized
release-gate summary. It does not copy API flow logic from child scripts, does
not reset runtime data by default, and does not write raw images, vectors,
tokens, secrets, env contents, or private fixture paths to evidence.

.EXAMPLE
pwsh ./scripts/run-model-pipeline-final-regression.ps1 -Mode Static

.EXAMPLE
pwsh ./scripts/run-model-pipeline-final-regression.ps1 -Mode PlanOnly

.EXAMPLE
pwsh ./scripts/run-model-pipeline-final-regression.ps1 `
  -Mode ApiOnly `
  -RootUrl "http://server-host" `
  -BaseUrl "http://server-host/api" `
  -NoseImageDir "<fixture-dir>" `
  -PasswordResetMode skip `
  -FirebaseMode enabled `
  -WriteEvidence
#>

[CmdletBinding()]
param(
    [ValidateSet("Static", "LocalRealModel", "ApiOnly", "PlanOnly")]
    [string]$Mode = "PlanOnly",

    [string]$RootUrl = "http://localhost",
    [string]$BaseUrl = "http://localhost/api",
    [string]$PythonEmbedUrl = "http://localhost:8000",
    [string]$QdrantUrl = "http://localhost:6333",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$NoseImageDir = "",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$ProfileImagePath = "",

    [string]$EnvFile = "infra/docker/.env",

    [ValidateSet("skip", "dev-exposed", "email")]
    [string]$PasswordResetMode = "skip",

    [ValidateSet("skip", "disabled", "enabled", "auto")]
    [string]$FirebaseMode = "skip",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$FcmToken = "",

    [switch]$WriteEvidence,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$OutputDir = "",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$ChildScriptRoot = "",

    [switch]$Help,

    [switch]$InjectUnexplainedMandatorySkipForTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$script:StartedAt = (Get-Date).ToUniversalTime()
$script:Steps = New-Object 'System.Collections.Generic.List[object]'
$script:ValidationFailures = New-Object 'System.Collections.Generic.List[string]'
$script:MandatoryFailed = $false
$script:ChildRoot = if ([string]::IsNullOrWhiteSpace($ChildScriptRoot)) { Join-Path $script:RepoRoot "scripts" } else { $ChildScriptRoot }

function Show-Usage {
    @"
Usage:
  pwsh ./scripts/run-model-pipeline-final-regression.ps1 -Mode Static
  pwsh ./scripts/run-model-pipeline-final-regression.ps1 -Mode PlanOnly
  pwsh ./scripts/run-model-pipeline-final-regression.ps1 -Mode LocalRealModel -NoseImageDir <fixture-dir> -ProfileImagePath <profile-image> [-EnvFile infra/docker/.env] [-WriteEvidence]
  pwsh ./scripts/run-model-pipeline-final-regression.ps1 -Mode ApiOnly -RootUrl <root-url> -BaseUrl <api-url> -NoseImageDir <fixture-dir> [-PasswordResetMode skip|dev-exposed|email] [-FirebaseMode skip|disabled|enabled|auto] [-WriteEvidence]

Modes:
  Static          Local static gate: diff, backend tests, Python tests, policies, syntax, compose config, scans.
  LocalRealModel  Existing real-model E2E orchestration against local runtime; no reset by default.
  ApiOnly         Existing manual full-feature API smoke; forbids compose/data reset through child args.
  PlanOnly        Prints and writes the planned gate only; no subprocesses or live probes are run.

Evidence:
  Default output is under the system temp directory:
  <temp>/petnose-model-pipeline-final-regression/<timestamp>

Exit codes:
  0 PASS
  1 regression failure
  2 configuration error
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

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function ConvertTo-JsonText {
    param([Parameter(Mandatory = $true)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 80)
}

function Get-DefaultOutputDir {
    $timestamp = $script:StartedAt.ToString("yyyyMMddTHHmmssZ")
    return (Join-Path ([System.IO.Path]::GetTempPath()) (Join-Path "petnose-model-pipeline-final-regression" $timestamp))
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Get-DefaultOutputDir
}
$script:ResolvedOutputDir = [System.IO.Path]::GetFullPath($OutputDir)

function Get-SafeOutputPath {
    param([Parameter(Mandatory = $true)][string]$Leaf)
    return (Join-Path $script:ResolvedOutputDir $Leaf)
}

function Test-StatusNeedsReason {
    param([Parameter(Mandatory = $true)][string]$Status)
    return @("SKIP", "NOT_RUN", "CI_REQUIRED") -contains $Status
}

function Add-StepResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet("PASS", "FAIL", "SKIP", "NOT_RUN", "CI_REQUIRED")][string]$Status,
        [bool]$Mandatory = $true,
        [AllowNull()][Nullable[int]]$ExitCode = $null,
        [AllowNull()][Nullable[int64]]$DurationMs = $null,
        [string]$Reason = "",
        [string]$EvidencePath = "",
        [hashtable]$Details = @{}
    )

    if ((Test-StatusNeedsReason -Status $Status) -and [string]::IsNullOrWhiteSpace($Reason)) {
        $script:ValidationFailures.Add("$Name has status $Status without a reason.") | Out-Null
    }
    if ($Mandatory -and $Status -eq "FAIL") {
        $script:MandatoryFailed = $true
    }

    $safeDetails = [ordered]@{}
    foreach ($key in $Details.Keys) {
        $safeDetails[[string]$key] = $Details[$key]
    }

    $script:Steps.Add([pscustomobject]@{
        name = $Name
        status = $Status
        exit_code = $ExitCode
        duration_ms = $DurationMs
        mode = $Mode
        mandatory = [bool]$Mandatory
        skip_reason = if ([string]::IsNullOrWhiteSpace($Reason)) { $null } else { $Reason }
        evidence_path = if ([string]::IsNullOrWhiteSpace($EvidencePath)) { $null } else { $EvidencePath }
        details = $safeDetails
    }) | Out-Null
}

function Add-NotRunMandatoryStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Reason = "previous mandatory step failed"
    )
    Add-StepResult -Name $Name -Status "NOT_RUN" -Mandatory $true -Reason $Reason
}

function Get-StepTail {
    param([string[]]$Lines, [int]$MaxLines = 24)

    if ($null -eq $Lines -or $Lines.Count -eq 0) {
        return @()
    }
    if ($Lines.Count -le $MaxLines) {
        return $Lines
    }
    return $Lines[($Lines.Count - $MaxLines)..($Lines.Count - 1)]
}

function Invoke-ExternalStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$File,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $script:RepoRoot,
        [bool]$Mandatory = $true,
        [string]$EvidencePath = ""
    )

    if ($Mandatory -and $script:MandatoryFailed) {
        Add-NotRunMandatoryStep -Name $Name
        return
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lines = @()
    $exitCode = 0
    try {
        Push-Location -LiteralPath $WorkingDirectory
        try {
            $lines = & $File @Arguments 2>&1 | ForEach-Object { $_.ToString() }
            $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
        } finally {
            Pop-Location
        }
    } catch {
        $lines += $_.Exception.Message
        $exitCode = 1
    } finally {
        $stopwatch.Stop()
    }

    $tail = @(Get-StepTail -Lines $lines)
    if ($tail.Count -gt 0) {
        Write-Host "[$Name] output tail:"
        foreach ($line in $tail) {
            Write-Host "  $line"
        }
    }

    $status = if ($exitCode -eq 0) { "PASS" } else { "FAIL" }
    Add-StepResult -Name $Name -Status $status -Mandatory $Mandatory -ExitCode $exitCode -DurationMs $stopwatch.ElapsedMilliseconds -EvidencePath $EvidencePath
}

function Invoke-ScriptStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [string[]]$Arguments = @(),
        [bool]$Mandatory = $true,
        [string]$EvidencePath = ""
    )

    $scriptPath = Join-Path $script:ChildRoot $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Add-StepResult -Name $Name -Status "FAIL" -Mandatory $Mandatory -Reason "child script not found"
        return
    }

    Invoke-ExternalStep -Name $Name -File "pwsh" -Arguments (@("-NoProfile", "-File", $scriptPath) + $Arguments) -Mandatory $Mandatory -EvidencePath $EvidencePath
}

function Add-PlanStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [bool]$Mandatory = $true,
        [string]$Reason = "PlanOnly mode records the planned step without executing commands."
    )
    Add-StepResult -Name $Name -Status "NOT_RUN" -Mandatory $Mandatory -Reason $Reason
}

function Get-NoseFixtureSummary {
    if ([string]::IsNullOrWhiteSpace($NoseImageDir)) {
        return [ordered]@{
            provided = $false
            count = 0
            extensions = @()
        }
    }

    $resolved = Resolve-RepoPath $NoseImageDir
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        return [ordered]@{
            provided = $true
            exists = $false
            count = 0
            extensions = @()
        }
    }

    $files = @(Get-ChildItem -LiteralPath $resolved -File | Where-Object { $_.Extension.ToLowerInvariant() -in @(".jpg", ".jpeg", ".png") } | Sort-Object Name)
    return [ordered]@{
        provided = $true
        exists = $true
        count = $files.Count
        extensions = @($files | ForEach-Object { $_.Extension.TrimStart(".").ToLowerInvariant() } | Sort-Object -Unique)
    }
}

function Assert-RequiredFixture {
    $summary = Get-NoseFixtureSummary
    if (-not [bool]$summary.provided) {
        Add-StepResult -Name "fixture_config" -Status "FAIL" -Mandatory $true -Reason "NoseImageDir is required for $Mode mode."
        return $false
    }
    if (-not [bool]$summary.exists) {
        Add-StepResult -Name "fixture_config" -Status "FAIL" -Mandatory $true -Reason "NoseImageDir does not exist."
        return $false
    }
    if ([int]$summary.count -lt 5) {
        Add-StepResult -Name "fixture_config" -Status "FAIL" -Mandatory $true -Reason "At least five jpg/jpeg/png nose images are required."
        return $false
    }
    Add-StepResult -Name "fixture_config" -Status "PASS" -Mandatory $true -Details @{ count = [int]$summary.count; extensions = @($summary.extensions) }
    return $true
}

function Assert-LocalRealModelConfig {
    if (-not (Assert-RequiredFixture)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($ProfileImagePath)) {
        Add-StepResult -Name "profile_fixture_config" -Status "FAIL" -Mandatory $true -Reason "ProfileImagePath is required for LocalRealModel mode."
        return $false
    }
    $resolved = Resolve-RepoPath $ProfileImagePath
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        Add-StepResult -Name "profile_fixture_config" -Status "FAIL" -Mandatory $true -Reason "ProfileImagePath does not exist."
        return $false
    }
    Add-StepResult -Name "profile_fixture_config" -Status "PASS" -Mandatory $true -Details @{ provided = $true; extension = ([System.IO.Path]::GetExtension($resolved).TrimStart(".").ToLowerInvariant()) }
    return $true
}

function Invoke-ProfileFirstDisabledProbe {
    if ($script:MandatoryFailed) {
        Add-NotRunMandatoryStep -Name "profile_first_default_off_api"
        return
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $failures = New-Object 'System.Collections.Generic.List[string]'
    $observed = @()
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(30)

    try {
        $targets = @(
            [ordered]@{ name = "profile_draft_disabled"; url = "$($BaseUrl.TrimEnd('/'))/dogs/profile-draft" },
            [ordered]@{ name = "nose_verification_disabled"; url = "$($BaseUrl.TrimEnd('/'))/dogs/$([guid]::NewGuid().ToString('N'))/nose-verification" }
        )

        foreach ($target in $targets) {
            $content = [System.Net.Http.MultipartFormDataContent]::new()
            $content.Add([System.Net.Http.StringContent]::new("1"), "user_id")
            try {
                $response = $client.PostAsync([string]$target.url, $content).GetAwaiter().GetResult()
                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $statusCode = [int]$response.StatusCode
                $errorCode = ""
                try {
                    $json = $body | ConvertFrom-Json
                    $errorCode = [string]$json.error_code
                } catch {
                    $errorCode = ""
                }
                $observed += [ordered]@{
                    name = $target.name
                    http_status = $statusCode
                    error_code = $errorCode
                }
                if ($statusCode -ne 404 -or $errorCode -ne "PROFILE_FIRST_DISABLED") {
                    $failures.Add("$($target.name) expected 404 PROFILE_FIRST_DISABLED, got $statusCode $errorCode") | Out-Null
                }
            } finally {
                $content.Dispose()
            }
        }
    } catch {
        $failures.Add($_.Exception.Message) | Out-Null
    } finally {
        $client.Dispose()
        $stopwatch.Stop()
    }

    if ($failures.Count -eq 0) {
        Add-StepResult -Name "profile_first_default_off_api" -Status "PASS" -Mandatory $true -DurationMs $stopwatch.ElapsedMilliseconds -Details @{ observed = $observed }
    } else {
        Add-StepResult -Name "profile_first_default_off_api" -Status "FAIL" -Mandatory $true -DurationMs $stopwatch.ElapsedMilliseconds -Reason ($failures -join "; ") -Details @{ observed = $observed }
    }
}

function Invoke-PythonRuntimeHealthGuardrail {
    if ($script:MandatoryFailed) {
        Add-NotRunMandatoryStep -Name "python_runtime_health_guardrail"
        return
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $failures = New-Object 'System.Collections.Generic.List[string]'
    $observed = [ordered]@{}
    try {
        $url = "$($PythonEmbedUrl.TrimEnd('/'))/health"
        $response = Invoke-WebRequest -Method GET -Uri $url -TimeoutSec 30 -SkipHttpErrorCheck
        $json = $response.Content | ConvertFrom-Json
        $observed = [ordered]@{
            http_status = [int]$response.StatusCode
            status = [string]$json.status
            model_loaded = [bool]$json.model_loaded
            backend = [string]$json.backend
            model = [string]$json.model
            vector_dim = [int]$json.vector_dim
        }
        if ([int]$response.StatusCode -ne 200) { $failures.Add("Python health HTTP status must be 200") | Out-Null }
        if ([string]$json.status -ne "ok") { $failures.Add("Python health status must be ok") | Out-Null }
        if (-not [bool]$json.model_loaded) { $failures.Add("model_loaded must be true") | Out-Null }
        if ([string]$json.backend -ne "torch+timm") { $failures.Add("backend must be torch+timm") | Out-Null }
        if ([int]$json.vector_dim -ne 2048) { $failures.Add("vector_dim must be 2048") | Out-Null }
        if (-not ([string]$json.model).StartsWith("dog-nose-identification2")) { $failures.Add("model must start with dog-nose-identification2") | Out-Null }
        if ([string]$json.backend -match "onnx") { $failures.Add("ONNX Runtime backend must not be active for this release") | Out-Null }
    } catch {
        $failures.Add($_.Exception.Message) | Out-Null
    } finally {
        $stopwatch.Stop()
    }

    if ($failures.Count -eq 0) {
        Add-StepResult -Name "python_runtime_health_guardrail" -Status "PASS" -Mandatory $true -DurationMs $stopwatch.ElapsedMilliseconds -Details $observed
    } else {
        Add-StepResult -Name "python_runtime_health_guardrail" -Status "FAIL" -Mandatory $true -DurationMs $stopwatch.ElapsedMilliseconds -Reason ($failures -join "; ") -Details $observed
    }
}

function Add-ModeOptionSteps {
    if ($PasswordResetMode -eq "skip") {
        Add-StepResult -Name "password_reset_confirm" -Status "SKIP" -Mandatory $false -Reason "PasswordResetMode=skip; email reset token is not available in automated release runner."
    }
    if ($FirebaseMode -eq "skip") {
        Add-StepResult -Name "firebase_chat" -Status "SKIP" -Mandatory $false -Reason "FirebaseMode=skip."
    }
    if ($Mode -eq "ApiOnly") {
        Add-StepResult -Name "mysql_qdrant_reconciliation" -Status "SKIP" -Mandatory $false -Reason "ApiOnly mode must not use direct Qdrant/MySQL reconciliation."
    }
}

function Invoke-PlanOnly {
    Add-PlanStep -Name "git_diff_check"
    Add-PlanStep -Name "backend_tests"
    Add-PlanStep -Name "python_embed_tests"
    Add-PlanStep -Name "production_runtime_policy"
    Add-PlanStep -Name "deploy_script_policy"
    Add-PlanStep -Name "powershell_and_shell_syntax"
    Add-PlanStep -Name "compose_config_env_example"
    Add-PlanStep -Name "forbidden_artifact_scan"
    Add-PlanStep -Name "secret_private_path_scan"
    Add-StepResult -Name "onnx_optional_local" -Status "CI_REQUIRED" -Mandatory $false -Reason "PlanOnly records optional ONNX local smoke as CI-required unless local dependencies are available in Static mode."
    Add-PlanStep -Name "profile_first_default_off_api" -Reason "PlanOnly does not call live HTTP endpoints."
    Add-PlanStep -Name "local_real_model_e2e" -Reason "PlanOnly does not start runtime or use external fixtures."
    Add-PlanStep -Name "api_only_full_feature_smoke" -Reason "PlanOnly does not call server APIs."
    Add-ModeOptionSteps

    Write-Host "Final model pipeline regression plan"
    Write-Host "- Mode: PlanOnly"
    Write-Host "- Evidence dir: $script:ResolvedOutputDir"
    Write-Host "- Required external files: <fixture-dir> with five nose images; <profile-image> for LocalRealModel; infra/docker/.env for real local runtime"
    Write-Host "- Optional features: password reset confirm, Firebase enabled chat, Qdrant/MySQL reconciliation"
    Write-Host "- Data reset: none; no Docker volume-delete command is generated by this runner"
}

function Test-PowerShellSyntax {
    param([string[]]$Paths)

    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in $Paths) {
        $resolved = Resolve-RepoPath $path
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            $failures.Add("missing: $path") | Out-Null
            continue
        }
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($resolved, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) {
            $failures.Add("${path}: $($errors[0].Message)") | Out-Null
        }
    }
    if ($failures.Count -eq 0) {
        Add-StepResult -Name "powershell_syntax" -Status "PASS" -Mandatory $true
    } else {
        Add-StepResult -Name "powershell_syntax" -Status "FAIL" -Mandatory $true -Reason ($failures -join "; ")
    }
}

function Test-ForbiddenArtifacts {
    $patterns = @(
        '\.env$',
        '\.(pem|p12|jks|key|pth|pt|ckpt|onnx|h5|keras|safetensors)$',
        'firebase-service-account.*\.json$',
        'serviceAccountKey.*\.json$',
        'firebase-adminsdk.*\.json$',
        '(raw|vector|payload).*\.(json|csv|npy)$'
    )
    $allowed = @(
        'infra/docker/.env.example',
        'docs/ops-evidence/model-pipeline-analysis/ddubi_multi_reference_heatmap.png',
        'docs/ops-evidence/model-pipeline-analysis/ddubi_single_reference_heatmap.png',
        'docs/ops-evidence/model-pipeline-analysis/ddubi_single_vs_multi_summary.png',
        'docs/ops-evidence/model-pipeline-analysis/ddubi_similarity_multi.csv',
        'docs/ops-evidence/model-pipeline-analysis/ddubi_similarity_single.csv',
        'docs/ops-evidence/model-pipeline-analysis/ddubi_similarity_summary.csv'
    )
    $tracked = & git -C $script:RepoRoot ls-files 2>$null | ForEach-Object { $_.Replace("\", "/") }
    $hits = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in $tracked) {
        if ($allowed -contains $file) {
            continue
        }
        foreach ($pattern in $patterns) {
            if ($file -match $pattern) {
                $hits.Add($file) | Out-Null
                break
            }
        }
    }

    if ($hits.Count -eq 0) {
        Add-StepResult -Name "forbidden_artifact_scan" -Status "PASS" -Mandatory $true
    } else {
        Add-StepResult -Name "forbidden_artifact_scan" -Status "FAIL" -Mandatory $true -Reason ($hits -join ", ")
    }
}

function Test-SecretPrivatePathScan {
    $targets = @(
        "scripts/run-model-pipeline-final-regression.ps1",
        "scripts/tests/test-model-pipeline-final-regression.ps1",
        "docs/reference/MODEL_PIPELINE_FINAL_REGRESSION.md",
        "docs/reference/MAIN_RELEASE_SERVER_DEPLOYMENT_CHECKLIST.md",
        "docs/README.md",
        ".github/workflows/ci.yaml"
    )
    $secretPattern = '-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}|AIza[0-9A-Za-z_-]{35}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{40,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}'
    $windowsUsersPattern = '[A-Za-z]:\\' + 'Users\\' + '[^\\\s`"]+'
    $windowsDevPattern = '[A-Za-z]:\\' + 'Dev\\' + '[^\\\s`"]+'
    $macUsersPattern = '/' + 'Users/' + '[^/\s`"]+'
    $linuxHomePattern = '/' + 'home/' + '[^/\s`"]+'
    $privatePathPattern = "($windowsUsersPattern|$windowsDevPattern|$macUsersPattern|$linuxHomePattern)"
    $hits = New-Object 'System.Collections.Generic.List[string]'

    foreach ($target in $targets) {
        $path = Resolve-RepoPath $target
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        $text = Get-Content -Raw -LiteralPath $path -Encoding UTF8
        if ($text -match $secretPattern) {
            $hits.Add("$target contains a secret-like token") | Out-Null
        }
        if ($text -match $privatePathPattern) {
            $hits.Add("$target contains a private absolute path") | Out-Null
        }
    }

    if ($hits.Count -eq 0) {
        Add-StepResult -Name "secret_private_path_scan" -Status "PASS" -Mandatory $true
    } else {
        Add-StepResult -Name "secret_private_path_scan" -Status "FAIL" -Mandatory $true -Reason ($hits -join "; ")
    }
}

function Test-OnnxCiSmokeDeclared {
    $ciPath = Resolve-RepoPath ".github/workflows/ci.yaml"
    $text = Get-Content -Raw -LiteralPath $ciPath -Encoding UTF8
    $ok = $text -match "Optional ONNX runtime smoke" -and
        $text -match "INSTALL_ONNX_RUNTIME_DEPS=1" -and
        $text -match "DOG_NOSE_RUNTIME=onnxruntime" -and
        $text -match "/embed-batch"
    if ($ok) {
        Add-StepResult -Name "onnx_ci_smoke_declared" -Status "PASS" -Mandatory $true
    } else {
        Add-StepResult -Name "onnx_ci_smoke_declared" -Status "FAIL" -Mandatory $true -Reason "CI workflow does not declare the optional ONNX runtime smoke contract."
    }
}

function Invoke-OptionalOnnxLocalSmoke {
    if ($script:MandatoryFailed) {
        Add-StepResult -Name "onnx_optional_local" -Status "NOT_RUN" -Mandatory $false -Reason "previous mandatory step failed"
        return
    }

    $probe = & python -c "import onnxruntime, onnx" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Add-StepResult -Name "onnx_optional_local" -Status "CI_REQUIRED" -Mandatory $false -Reason "optional ONNX dependencies are not installed locally; CI optional ONNX runtime smoke is required."
        return
    }
    Invoke-ExternalStep -Name "onnx_optional_local" -File "python" -Arguments @("-m", "pytest", "-q", "python-embed/tests/test_embedder_factory.py", "python-embed/tests/test_dog_nose_onnx_embedder.py") -Mandatory $false
}

function Invoke-Static {
    Invoke-ExternalStep -Name "git_diff_check" -File "git" -Arguments @("diff", "--check")
    Invoke-ExternalStep -Name "backend_tests" -File "gradle" -Arguments @("test", "--no-daemon", "--stacktrace") -WorkingDirectory (Resolve-RepoPath "backend")
    Invoke-ExternalStep -Name "python_embed_tests" -File "python" -Arguments @("-m", "pytest", "-q") -WorkingDirectory (Resolve-RepoPath "python-embed")
    Invoke-ScriptStep -Name "production_runtime_policy" -ScriptName "tests/verify-server-release-policy.ps1"

    if (Get-Command bash -ErrorAction SilentlyContinue) {
        Invoke-ExternalStep -Name "deploy_script_policy" -File "bash" -Arguments @("infra/scripts/tests/test-production-runtime-policy.sh")
        Invoke-ExternalStep -Name "shell_syntax" -File "bash" -Arguments @("-n", "infra/scripts/deploy-real-model.sh")
    } else {
        Add-StepResult -Name "deploy_script_policy" -Status "CI_REQUIRED" -Mandatory $true -Reason "bash is not available locally; CI must run deploy policy shell tests."
        Add-StepResult -Name "shell_syntax" -Status "CI_REQUIRED" -Mandatory $true -Reason "bash is not available locally; CI must run shell syntax checks."
    }

    Test-PowerShellSyntax -Paths @(
        "scripts/run-model-pipeline-final-regression.ps1",
        "scripts/manual-full-feature-smoke.ps1",
        "scripts/verify-submission-real-model-e2e.ps1",
        "scripts/verify-server-release-readiness.ps1",
        "scripts/check-qdrant-reference-consistency.ps1"
    )

    Invoke-ExternalStep -Name "compose_config_env_example" -File "docker" -Arguments @(
        "compose",
        "--env-file",
        "infra/docker/.env.example",
        "-f",
        "infra/docker/compose.yaml",
        "-f",
        "infra/docker/compose.dev.yaml",
        "config"
    )

    Test-OnnxCiSmokeDeclared
    Invoke-OptionalOnnxLocalSmoke
    Test-ForbiddenArtifacts
    Test-SecretPrivatePathScan
}

function Invoke-ApiOnly {
    if (-not (Assert-RequiredFixture)) {
        return
    }

    Invoke-ProfileFirstDisabledProbe
    Add-ModeOptionSteps

    $childOutputDir = Join-Path $script:ResolvedOutputDir "manual-full-feature-smoke"
    $childSummary = Join-Path $childOutputDir "summary.json"
    $args = @(
        "-ApiOnly",
        "-SkipInternalPreflight",
        "-RootUrl",
        $RootUrl,
        "-BaseUrl",
        $BaseUrl,
        "-NoseImageDir",
        $NoseImageDir,
        "-PasswordResetMode",
        $PasswordResetMode,
        "-FirebaseMode",
        $FirebaseMode,
        "-RunReconciliation:`$false",
        "-OutputDir",
        $childOutputDir,
        "-SummaryPath",
        $childSummary
    )
    if (-not [string]::IsNullOrWhiteSpace($FcmToken)) {
        $args += @("-FcmToken", $FcmToken)
    }
    if ($WriteEvidence) {
        $args += "-WriteEvidence"
    }

    Invoke-ScriptStep -Name "api_only_full_feature_smoke" -ScriptName "manual-full-feature-smoke.ps1" -Arguments $args -EvidencePath "<runner-output>/manual-full-feature-smoke/summary.json"
}

function Invoke-LocalRealModel {
    if (-not (Assert-LocalRealModelConfig)) {
        return
    }

    Invoke-PythonRuntimeHealthGuardrail
    Invoke-ProfileFirstDisabledProbe
    Add-ModeOptionSteps

    $childOutputDir = Join-Path $script:ResolvedOutputDir "submission-real-model-e2e"
    $childSummary = Join-Path $childOutputDir "summary.json"
    $args = @(
        "-BaseUrl",
        $RootUrl,
        "-QdrantUrl",
        $QdrantUrl,
        "-PythonEmbedUrl",
        $PythonEmbedUrl,
        "-NoseImageDir",
        $NoseImageDir,
        "-ProfileImagePath",
        $ProfileImagePath,
        "-EnvFile",
        $EnvFile,
        "-OutputDir",
        $childOutputDir,
        "-SummaryPath",
        $childSummary
    )
    if ($WriteEvidence) {
        $args += "-WriteEvidence"
    }

    Invoke-ScriptStep -Name "local_real_model_e2e" -ScriptName "verify-submission-real-model-e2e.ps1" -Arguments $args -EvidencePath "<runner-output>/submission-real-model-e2e/summary.json"

    if (-not $script:MandatoryFailed) {
        $reconciliationOutput = Join-Path $script:ResolvedOutputDir "qdrant-reference-consistency.json"
        Invoke-ScriptStep -Name "mysql_qdrant_reconciliation" -ScriptName "check-qdrant-reference-consistency.ps1" -Arguments @(
            "-QdrantUrl",
            $QdrantUrl,
            "-EnvFile",
            $EnvFile,
            "-OutputPath",
            $reconciliationOutput,
            "-FailOnDrift"
        ) -EvidencePath "<runner-output>/qdrant-reference-consistency.json"
    } else {
        Add-NotRunMandatoryStep -Name "mysql_qdrant_reconciliation"
    }
}

function Get-OverallStatus {
    if ($script:ValidationFailures.Count -gt 0) {
        return "FAIL"
    }
    foreach ($step in $script:Steps) {
        if ($step.status -eq "FAIL") {
            return "FAIL"
        }
    }
    return "PASS"
}

function New-SummaryObject {
    param([Parameter(Mandatory = $true)][string]$OverallStatus)

    $fixture = Get-NoseFixtureSummary
    $head = [string]((& git -C $script:RepoRoot rev-parse HEAD 2>$null) -join "")
    $branch = [string]((& git -C $script:RepoRoot branch --show-current 2>$null) -join "")
    $summaryJson = Get-SafeOutputPath "summary.json"
    $summaryMd = Get-SafeOutputPath "summary.md"
    $stepsCsv = Get-SafeOutputPath "steps.csv"
    $validationFailures = @($script:ValidationFailures.ToArray())
    $steps = @($script:Steps.ToArray())

    return [ordered]@{
        schema_version = 1
        scope = "model-pipeline-final-regression"
        mode = $Mode
        started_at = $script:StartedAt.ToString("o")
        finished_at = (Get-Date).ToUniversalTime().ToString("o")
        overall_status = $OverallStatus
        repository = [ordered]@{
            head = $head
            branch = $branch
        }
        runtime_policy = [ordered]@{
            expected_backend = "torch+timm"
            expected_runtime = "torch"
            expected_model_prefix = "dog-nose-identification2"
            expected_vector_dim = 2048
            onnx_enabled = $false
            yolo_enabled = $false
            profile_first_enabled = $false
            registration_timing_log_enabled = $false
        }
        evidence = [ordered]@{
            output_dir = $script:ResolvedOutputDir
            summary_json = $summaryJson
            summary_md = $summaryMd
            steps_csv = $stepsCsv
            redaction = "password/JWT/reset token/Firebase token/FCM token/service account/env contents/raw images/raw vectors/full Qdrant payload/private fixture paths are not recorded"
        }
        fixture = $fixture
        validation_failures = $validationFailures
        steps = $steps
    }
}

function Write-SummaryMarkdown {
    param(
        [Parameter(Mandatory = $true)][object]$Summary,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("# Model Pipeline Final Regression Summary") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Mode: $($Summary.mode)") | Out-Null
    $lines.Add("- Overall: $($Summary.overall_status)") | Out-Null
    $lines.Add("- Started: $($Summary.started_at)") | Out-Null
    $lines.Add("- Finished: $($Summary.finished_at)") | Out-Null
    $lines.Add("- Evidence dir: $($Summary.evidence.output_dir)") | Out-Null
    $lines.Add("- Data reset: none by default; this runner does not generate volume-delete commands") | Out-Null
    $lines.Add("- Runtime policy: torch runtime, torch+timm backend, 2048 dim, ONNX/YOLO/profile-first/timing disabled") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("| step | status | mandatory | reason | duration_ms |") | Out-Null
    $lines.Add("|---|---:|---:|---|---:|") | Out-Null
    foreach ($step in $Summary.steps) {
        $reason = if ($null -eq $step.skip_reason) { "" } else { ([string]$step.skip_reason).Replace("|", "/") }
        $duration = if ($null -eq $step.duration_ms) { "" } else { [string]$step.duration_ms }
        $lines.Add("| $($step.name) | $($step.status) | $($step.mandatory) | $reason | $duration |") | Out-Null
    }
    Write-Utf8NoBom -Path $Path -Text (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Write-StepsCsv {
    param(
        [Parameter(Mandatory = $true)][object[]]$Steps,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $rows = New-Object 'System.Collections.Generic.List[string]'
    $rows.Add("name,status,exit_code,duration_ms,mode,mandatory,skip_reason,evidence_path") | Out-Null
    foreach ($step in $Steps) {
        $values = @(
            $step.name,
            $step.status,
            $step.exit_code,
            $step.duration_ms,
            $step.mode,
            $step.mandatory,
            $step.skip_reason,
            $step.evidence_path
        )
        $escaped = $values | ForEach-Object {
            $text = if ($null -eq $_) { "" } else { [string]$_ }
            '"' + $text.Replace('"', '""') + '"'
        }
        $rows.Add(($escaped -join ",")) | Out-Null
    }
    Write-Utf8NoBom -Path $Path -Text (($rows -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Assert-SummarySanitized {
    param([Parameter(Mandatory = $true)][string]$SummaryJsonPath)

    $text = Get-Content -Raw -LiteralPath $SummaryJsonPath -Encoding UTF8
    $patterns = @(
        'password"\s*:\s*"[^"]+',
        'token"\s*:\s*"[^"]+',
        'firebase_custom_token',
        'fcm_token"\s*:\s*"[^"]+',
        '-----BEGIN [A-Z ]*PRIVATE KEY-----',
        'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}',
        '\[[\s\r\n]*-?0?\.\d+[\s\r\n]*,\s*-?0?\.\d+[\s\r\n]*,\s*-?0?\.\d+',
        [regex]::Escape($NoseImageDir),
        [regex]::Escape($ProfileImagePath)
    )
    foreach ($pattern in $patterns) {
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and $text -match $pattern) {
            throw "summary evidence failed sanitization pattern: $pattern"
        }
    }
}

try {
    if ($InjectUnexplainedMandatorySkipForTest -and $env:PETNOSE_FINAL_REGRESSION_TEST_HOOKS -eq "1") {
        Add-StepResult -Name "injected_unexplained_mandatory_skip" -Status "SKIP" -Mandatory $true
    }

    switch ($Mode) {
        "PlanOnly" { Invoke-PlanOnly }
        "Static" { Invoke-Static }
        "ApiOnly" { Invoke-ApiOnly }
        "LocalRealModel" { Invoke-LocalRealModel }
    }

    $overall = Get-OverallStatus
    $summary = New-SummaryObject -OverallStatus $overall
    $summaryJsonPath = Get-SafeOutputPath "summary.json"
    $summaryMdPath = Get-SafeOutputPath "summary.md"
    $stepsCsvPath = Get-SafeOutputPath "steps.csv"
    Write-Utf8NoBom -Path $summaryJsonPath -Text ((ConvertTo-JsonText $summary) + [Environment]::NewLine)
    Write-SummaryMarkdown -Summary $summary -Path $summaryMdPath
    Write-StepsCsv -Steps @($script:Steps.ToArray()) -Path $stepsCsvPath
    Assert-SummarySanitized -SummaryJsonPath $summaryJsonPath

    Write-Host "Final regression summary:"
    Write-Host "  overall_status=$overall"
    Write-Host "  summary_json=$summaryJsonPath"
    Write-Host "  summary_md=$summaryMdPath"
    Write-Host "  steps_csv=$stepsCsvPath"

    if ($overall -eq "PASS") {
        exit 0
    }
    exit 1
} catch {
    $message = $_.Exception.Message
    Add-StepResult -Name "runner_config_or_sanitization" -Status "FAIL" -Mandatory $true -Reason $message
    try {
        $summary = New-SummaryObject -OverallStatus "FAIL"
        $summaryJsonPath = Get-SafeOutputPath "summary.json"
        $summaryMdPath = Get-SafeOutputPath "summary.md"
        $stepsCsvPath = Get-SafeOutputPath "steps.csv"
        Write-Utf8NoBom -Path $summaryJsonPath -Text ((ConvertTo-JsonText $summary) + [Environment]::NewLine)
        Write-SummaryMarkdown -Summary $summary -Path $summaryMdPath
        Write-StepsCsv -Steps @($script:Steps.ToArray()) -Path $stepsCsvPath
    } catch {
        Write-Host "Failed to write failure summary: $($_.Exception.Message)"
    }
    Write-Host "Final regression failed: $message"
    exit 2
}
