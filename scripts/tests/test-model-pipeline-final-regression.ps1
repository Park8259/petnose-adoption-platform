#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$script:Runner = Join-Path $script:RepoRoot "scripts\run-model-pipeline-final-regression.ps1"
$script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("petnose-final-regression-test-" + [System.Guid]::NewGuid().ToString("N"))
$script:PythonCommand = $null

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Message
    )
    Assert-True -Condition ($Text.Contains($Needle)) -Message $Message
}

function Assert-NotContains {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Message
    )
    Assert-True -Condition (-not $Text.Contains($Needle)) -Message $Message
}

function Invoke-Runner {
    param([string[]]$Arguments)

    $output = & pwsh -NoProfile -File $script:Runner @Arguments 2>&1 | ForEach-Object { $_.ToString() }
    return [pscustomobject]@{
        ExitCode = [int]$LASTEXITCODE
        Output = ($output -join "`n")
    }
}

function Read-Summary {
    param([Parameter(Mandatory = $true)][string]$OutputDir)
    $path = Join-Path $OutputDir "summary.json"
    Assert-True -Condition (Test-Path -LiteralPath $path -PathType Leaf) -Message "summary.json was not written: $path"
    return (Get-Content -Raw -LiteralPath $path -Encoding UTF8 | ConvertFrom-Json)
}

function New-TestFixtureDir {
    $dir = Join-Path $script:TempDir "fixture"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("stub-fixture")
    for ($i = 1; $i -le 5; $i++) {
        [System.IO.File]::WriteAllBytes((Join-Path $dir "$i.png"), $bytes)
    }
    return $dir
}

function New-StubChildRoot {
    param([Parameter(Mandatory = $true)][int]$ManualExitCode)

    $root = Join-Path $script:TempDir ("child-" + [System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root "tests") -Force | Out-Null

    $manual = @'
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
if (-not [string]::IsNullOrWhiteSpace($env:PETNOSE_FINAL_REGRESSION_STUB_LOG)) {
    Add-Content -LiteralPath $env:PETNOSE_FINAL_REGRESSION_STUB_LOG -Value $MyInvocation.Line -Encoding UTF8
    Add-Content -LiteralPath $env:PETNOSE_FINAL_REGRESSION_STUB_LOG -Value ($Rest -join " ") -Encoding UTF8
}
exit $env:PETNOSE_FINAL_REGRESSION_STUB_EXIT
'@
    Set-Content -LiteralPath (Join-Path $root "manual-full-feature-smoke.ps1") -Value $manual -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root "verify-submission-real-model-e2e.ps1") -Value $manual -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root "check-qdrant-reference-consistency.ps1") -Value $manual -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $root "tests\verify-server-release-policy.ps1") -Value "exit 0" -Encoding UTF8
    $env:PETNOSE_FINAL_REGRESSION_STUB_EXIT = [string]$ManualExitCode
    return $root
}

function Get-PythonCommand {
    if ($null -ne $script:PythonCommand) {
        return $script:PythonCommand
    }
    foreach ($candidate in @("python", "python3")) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $script:PythonCommand = $command.Source
            return $script:PythonCommand
        }
    }
    throw "python or python3 is required for the local profile-first stub server test."
}

function Get-FreePort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try {
        return [int]$listener.LocalEndpoint.Port
    } finally {
        $listener.Stop()
    }
}

function Start-ProfileFirstStubServer {
    $port = Get-FreePort
    $serverScript = Join-Path $script:TempDir "profile_first_stub_server.py"
    $python = @'
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        if length:
            self.rfile.read(length)
        body = json.dumps({"error_code": "PROFILE_FIRST_DISABLED"}).encode("utf-8")
        self.send_response(404)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
'@
    Set-Content -LiteralPath $serverScript -Value $python -Encoding UTF8
    $pythonCommand = Get-PythonCommand
    if ($IsWindows) {
        $process = Start-Process -FilePath $pythonCommand -ArgumentList @($serverScript, [string]$port) -PassThru -WindowStyle Hidden
    } else {
        $process = Start-Process -FilePath $pythonCommand -ArgumentList @($serverScript, [string]$port) -PassThru
    }

    $root = "http://127.0.0.1:$port"
    for ($i = 0; $i -lt 50; $i++) {
        try {
            Invoke-WebRequest -Uri "$root/health" -TimeoutSec 2 | Out-Null
            return [pscustomobject]@{
                Process = $process
                RootUrl = $root
                BaseUrl = "$root/api"
            }
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }

    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "profile-first stub server did not start"
}

function Invoke-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )
    & $Command
    Write-Host "[PASS] $Name"
}

New-Item -ItemType Directory -Path $script:TempDir -Force | Out-Null
$server = $null

try {
    $fixtureDir = New-TestFixtureDir
    $stubLog = Join-Path $script:TempDir "stub-args.log"
    $env:PETNOSE_FINAL_REGRESSION_STUB_LOG = $stubLog
    $server = Start-ProfileFirstStubServer

    Invoke-Case -Name "Help exits 0" -Command {
        $result = Invoke-Runner -Arguments @("-Help")
        Assert-True -Condition ($result.ExitCode -eq 0) -Message "-Help should exit 0"
        Assert-Contains -Text $result.Output -Needle "Usage:" -Message "help output should contain usage"
    }

    Invoke-Case -Name "PlanOnly runs no subprocess" -Command {
        $outputDir = Join-Path $script:TempDir "plan-only"
        $childRoot = New-StubChildRoot -ManualExitCode 99
        $result = Invoke-Runner -Arguments @("-Mode", "PlanOnly", "-ChildScriptRoot", $childRoot, "-OutputDir", $outputDir)
        Assert-True -Condition ($result.ExitCode -eq 0) -Message "PlanOnly should pass"
        Assert-True -Condition (-not (Test-Path -LiteralPath $stubLog -PathType Leaf)) -Message "PlanOnly should not invoke child scripts"
        $summary = Read-Summary -OutputDir $outputDir
        Assert-True -Condition ($summary.overall_status -eq "PASS") -Message "PlanOnly summary should pass"
    }

    Invoke-Case -Name "Invalid mode is rejected" -Command {
        $result = Invoke-Runner -Arguments @("-Mode", "Nope")
        Assert-True -Condition ($result.ExitCode -ne 0) -Message "invalid mode should be non-zero"
        Assert-Contains -Text $result.Output -Needle "ValidateSet" -Message "invalid mode should be rejected by validation"
    }

    Invoke-Case -Name "Missing fixture is config error" -Command {
        $outputDir = Join-Path $script:TempDir "missing-fixture"
        $childRoot = New-StubChildRoot -ManualExitCode 0
        $result = Invoke-Runner -Arguments @(
            "-Mode", "ApiOnly",
            "-RootUrl", $server.RootUrl,
            "-BaseUrl", $server.BaseUrl,
            "-ChildScriptRoot", $childRoot,
            "-OutputDir", $outputDir
        )
        Assert-True -Condition ($result.ExitCode -ne 0) -Message "ApiOnly without NoseImageDir should fail"
        $summary = Read-Summary -OutputDir $outputDir
        Assert-True -Condition ($summary.overall_status -eq "FAIL") -Message "missing fixture summary should fail"
        Assert-Contains -Text ($summary.steps | ConvertTo-Json -Depth 20) -Needle "NoseImageDir is required" -Message "missing fixture reason should be recorded"
    }

    Invoke-Case -Name "ApiOnly child pass propagates and avoids reset controls" -Command {
        Remove-Item -LiteralPath $stubLog -Force -ErrorAction SilentlyContinue
        $outputDir = Join-Path $script:TempDir "api-pass"
        $childRoot = New-StubChildRoot -ManualExitCode 0
        $secret = "PETNOSE_TEST_FCM_SECRET_SHOULD_NOT_APPEAR"
        $result = Invoke-Runner -Arguments @(
            "-Mode", "ApiOnly",
            "-RootUrl", $server.RootUrl,
            "-BaseUrl", $server.BaseUrl,
            "-NoseImageDir", $fixtureDir,
            "-FirebaseMode", "skip",
            "-PasswordResetMode", "skip",
            "-FcmToken", $secret,
            "-ChildScriptRoot", $childRoot,
            "-OutputDir", $outputDir
        )
        Assert-True -Condition ($result.ExitCode -eq 0) -Message "ApiOnly with passing child should pass"
        $invocation = Get-Content -Raw -LiteralPath $stubLog -Encoding UTF8
        Assert-Contains -Text $invocation -Needle "-ApiOnly" -Message "manual smoke should be invoked in ApiOnly mode"
        Assert-Contains -Text $invocation -Needle "-SkipInternalPreflight" -Message "ApiOnly should skip internal preflight"
        Assert-Contains -Text $invocation -Needle "-RunReconciliation" -Message "ApiOnly should pass reconciliation flag"
        Assert-Contains -Text $invocation -Needle "False" -Message "ApiOnly should disable reconciliation"
        Assert-NotContains -Text $invocation -Needle "-ResetRuntimeData" -Message "ApiOnly must not pass reset flag"
        Assert-NotContains -Text $invocation -Needle "-StartRuntime" -Message "ApiOnly must not pass compose start flag"
        Assert-NotContains -Text $invocation -Needle "-StopRuntimeAfter" -Message "ApiOnly must not pass compose stop flag"
        Assert-NotContains -Text $invocation -Needle "down -v" -Message "ApiOnly must not generate volume deletion"

        $summaryPath = Join-Path $outputDir "summary.json"
        $summaryText = Get-Content -Raw -LiteralPath $summaryPath -Encoding UTF8
        $summary = Read-Summary -OutputDir $outputDir
        Assert-True -Condition ($summary.schema_version -eq 1) -Message "schema_version should be 1"
        Assert-True -Condition ($summary.scope -eq "model-pipeline-final-regression") -Message "scope should match"
        Assert-True -Condition ($summary.runtime_policy.expected_backend -eq "torch+timm") -Message "runtime policy expected backend should be torch+timm"
        Assert-True -Condition ($summary.overall_status -eq "PASS") -Message "ApiOnly pass summary should pass"
        Assert-NotContains -Text $summaryText -Needle $secret -Message "summary must redact FCM token"
        Assert-NotContains -Text $summaryText -Needle $fixtureDir -Message "summary must not store absolute fixture path"
        Assert-True -Condition ($summaryText -notmatch '\[[\s\r\n]*-?0?\.\d+[\s\r\n]*,\s*-?0?\.\d+[\s\r\n]*,\s*-?0?\.\d+') -Message "summary must not contain vector-like arrays"

        $optionalSteps = @($summary.steps | Where-Object { $_.name -in @("password_reset_confirm", "firebase_chat", "mysql_qdrant_reconciliation") })
        Assert-True -Condition ($optionalSteps.Count -ge 3) -Message "optional skip steps should be recorded"
        foreach ($step in $optionalSteps) {
            Assert-True -Condition ($step.status -eq "SKIP") -Message "$($step.name) should be SKIP"
            Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$step.skip_reason)) -Message "$($step.name) should have skip reason"
        }
    }

    Invoke-Case -Name "Child failure propagates overall failure" -Command {
        Remove-Item -LiteralPath $stubLog -Force -ErrorAction SilentlyContinue
        $outputDir = Join-Path $script:TempDir "api-fail"
        $childRoot = New-StubChildRoot -ManualExitCode 7
        $result = Invoke-Runner -Arguments @(
            "-Mode", "ApiOnly",
            "-RootUrl", $server.RootUrl,
            "-BaseUrl", $server.BaseUrl,
            "-NoseImageDir", $fixtureDir,
            "-ChildScriptRoot", $childRoot,
            "-OutputDir", $outputDir
        )
        Assert-True -Condition ($result.ExitCode -ne 0) -Message "failing child should fail runner"
        $summary = Read-Summary -OutputDir $outputDir
        $childStep = $summary.steps | Where-Object { $_.name -eq "api_only_full_feature_smoke" } | Select-Object -First 1
        Assert-True -Condition ($summary.overall_status -eq "FAIL") -Message "overall should fail"
        Assert-True -Condition ($childStep.status -eq "FAIL") -Message "child step should fail"
        Assert-True -Condition ($childStep.exit_code -eq 7) -Message "child exit code should be recorded"
    }

    Invoke-Case -Name "Mandatory unexplained skip fails summary validation" -Command {
        $outputDir = Join-Path $script:TempDir "unexplained-skip"
        $env:PETNOSE_FINAL_REGRESSION_TEST_HOOKS = "1"
        try {
            $result = Invoke-Runner -Arguments @("-Mode", "PlanOnly", "-OutputDir", $outputDir, "-InjectUnexplainedMandatorySkipForTest")
        } finally {
            Remove-Item Env:\PETNOSE_FINAL_REGRESSION_TEST_HOOKS -ErrorAction SilentlyContinue
        }
        Assert-True -Condition ($result.ExitCode -ne 0) -Message "unexplained mandatory skip should fail"
        $summary = Read-Summary -OutputDir $outputDir
        Assert-True -Condition ($summary.overall_status -eq "FAIL") -Message "unexplained skip summary should fail"
        Assert-Contains -Text ($summary.validation_failures | ConvertTo-Json -Depth 10) -Needle "without a reason" -Message "validation failure should mention missing reason"
    }

    Invoke-Case -Name "Generated plan has no volume delete command" -Command {
        $outputDir = Join-Path $script:TempDir "plan-no-volume-delete"
        $result = Invoke-Runner -Arguments @("-Mode", "PlanOnly", "-OutputDir", $outputDir)
        Assert-True -Condition ($result.ExitCode -eq 0) -Message "PlanOnly should pass"
        $combined = $result.Output + "`n" + (Get-Content -Raw -LiteralPath (Join-Path $outputDir "summary.md") -Encoding UTF8)
        Assert-NotContains -Text $combined -Needle "down -v" -Message "plan must not contain docker volume deletion command"
    }

    Write-Host "[OK] test-model-pipeline-final-regression completed"
} finally {
    if ($null -ne $server -and $null -ne $server.Process) {
        Stop-Process -Id $server.Process.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item Env:\PETNOSE_FINAL_REGRESSION_STUB_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\PETNOSE_FINAL_REGRESSION_STUB_EXIT -ErrorAction SilentlyContinue
    Remove-Item Env:\PETNOSE_FINAL_REGRESSION_TEST_HOOKS -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
