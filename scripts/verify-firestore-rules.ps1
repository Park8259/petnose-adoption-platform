#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$RulesProjectDir = Join-Path $RepoRoot "tools\firebase-rules"
$PackageLockPath = Join-Path $RulesProjectDir "package-lock.json"
$script:StepNumber = 0

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Command
    )

    $script:StepNumber++
    Write-Host ""
    Write-Host "[$script:StepNumber] $Name" -ForegroundColor Cyan
    try {
        & $Command
        Write-Host "PASS: $Name" -ForegroundColor Green
    } catch {
        Write-Host "FAIL: $Name" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        throw
    }
}

function Assert-CommandAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name is required to run Firestore rules emulator tests."
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [string]$File,

        [string[]]$Arguments = @(),

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $File @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$File $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
        }
    } finally {
        Pop-Location
    }
}

Write-Host "PetNose Firestore rules emulator validation" -ForegroundColor Cyan
Write-Host "RulesProjectDir: $RulesProjectDir"
Write-Host "Mode: emulator-only; no Firebase credentials or .env files are required."

Invoke-Step "Check Node.js and npm" {
    Assert-CommandAvailable "node"
    Assert-CommandAvailable "npm"
    Invoke-Native -File "node" -Arguments @("--version") -WorkingDirectory $RulesProjectDir
    Invoke-Native -File "npm" -Arguments @("--version") -WorkingDirectory $RulesProjectDir
}

Invoke-Step "Install Firebase rules test dependencies" {
    if (Test-Path -LiteralPath $PackageLockPath -PathType Leaf) {
        Invoke-Native -File "npm" -Arguments @("ci") -WorkingDirectory $RulesProjectDir
    } else {
        Invoke-Native -File "npm" -Arguments @("install") -WorkingDirectory $RulesProjectDir
    }
}

Invoke-Step "Run Firestore rules emulator tests" {
    Invoke-Native -File "npm" -Arguments @("test") -WorkingDirectory $RulesProjectDir
}

Write-Host ""
Write-Host "FIRESTORE RULES EMULATOR VALIDATION PASSED" -ForegroundColor Green
