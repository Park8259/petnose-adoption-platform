#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ExpectedBranch = "refactor/dog-id-centered-adoption-flow"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$BackendDir = Join-Path $RepoRoot "backend"
$ScriptRelativePath = "scripts/verify-dog-id-centered-flow.ps1"
$GradleFile = "gradle"
$script:StepNumber = 0

if (Test-Path (Join-Path $BackendDir "gradlew.bat") -PathType Leaf) {
    $GradleFile = ".\gradlew.bat"
}

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [string]$File,

        [string[]]$Arguments
    )

    & $File @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $File $($Arguments -join ' ')"
    }
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Command,

        [string]$WorkingDirectory = $RepoRoot
    )

    $script:StepNumber++
    Write-Host ""
    Write-Host "[$script:StepNumber] $Name" -ForegroundColor Cyan
    Push-Location $WorkingDirectory
    try {
        & $Command
        Write-Host "PASS: $Name" -ForegroundColor Green
    } catch {
        Write-Host "FAIL: $Name" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        throw
    } finally {
        Pop-Location
    }
}

function Read-TextFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath
    )

    $path = Join-Path $RepoRoot $RelativePath
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Required file not found: $RelativePath"
    }
    return Get-Content $path -Raw -Encoding UTF8
}

function Assert-ContainsAny {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string[]]$Needles,

        [Parameter(Mandatory = $true)]
        [string]$Subject
    )

    foreach ($needle in $Needles) {
        if ($Text.Contains($needle)) {
            return
        }
    }
    throw "$Subject is missing all required patterns: $($Needles -join ', ')"
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Needle,

        [Parameter(Mandatory = $true)]
        [string]$Subject
    )

    if (-not $Text.Contains($Needle)) {
        throw "$Subject is missing required pattern: $Needle"
    }
}

function Assert-NotContainsAny {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string[]]$Needles,

        [Parameter(Mandatory = $true)]
        [string]$Subject
    )

    foreach ($needle in $Needles) {
        if ($Text.Contains($needle)) {
            throw "$Subject contains forbidden pattern: $needle"
        }
    }
}

function Assert-Regex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [string]$Subject
    )

    if ($Text -notmatch $Pattern) {
        throw "$Subject is missing required regex: $Pattern"
    }
}

function Assert-NotRegex {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Pattern,

        [Parameter(Mandatory = $true)]
        [string]$Subject
    )

    if ($Text -match $Pattern) {
        throw "$Subject contains forbidden regex: $Pattern"
    }
}

function Get-SearchableRepoFiles {
    $files = & git ls-files --cached --modified --others --exclude-standard
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to enumerate repository files."
    }

    $extensions = @(
        ".java", ".kt", ".dart", ".md", ".txt", ".sql", ".dbml", ".yaml", ".yml",
        ".properties", ".gradle", ".ps1", ".json", ".xml", ".html", ".js", ".ts"
    )

    foreach ($file in $files) {
        $normalized = $file.Replace("\", "/")
        if ($normalized -eq $ScriptRelativePath) {
            continue
        }

        $absolute = Join-Path $RepoRoot $file
        if (-not (Test-Path $absolute -PathType Leaf)) {
            continue
        }

        $extension = [System.IO.Path]::GetExtension($file)
        if ($extensions -contains $extension) {
            $normalized
        }
    }
}

function Find-FixedStringMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Needle
    )

    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($relativePath in Get-SearchableRepoFiles) {
        $absolutePath = Join-Path $RepoRoot $relativePath
        $lines = Get-Content $absolutePath -Encoding UTF8
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Contains($Needle)) {
                $matches.Add([pscustomobject]@{
                    Path = $relativePath
                    Line = $i + 1
                    Text = $lines[$i].Trim()
                })
            }
        }
    }
    return $matches
}

function Format-MatchList {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Matches
    )

    return ($Matches | ForEach-Object { "$($_.Path):$($_.Line): $($_.Text)" }) -join [Environment]::NewLine
}

function Test-HistoricalMatchAllowed {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Match,

        [Parameter(Mandatory = $true)]
        [string]$Keyword
    )

    $path = $Match.Path.Replace("\", "/")
    $text = [string]$Match.Text
    if ($path -like "backend/src/main/resources/db/migration/V3__*") { return $true }
    if ($path -like "backend/src/main/resources/db/migration/V4__*") { return $true }
    if ($path -like "docs/reference/*") { return $true }
    if ($path -like "docs/archive/*") { return $true }
    if ($path -like "docs/ops-evidence/*") { return $true }
    if ($path -like "backend/src/test/*" -and ($path -like "*Migration*" -or $path -like "*CanonicalEntityShapeTest.java")) { return $true }
    if ($Keyword -eq "nose_verification_attempts" -and $path -eq "backend/README.md") { return $true }
    if (($text -like "*historical*" -or $text -like "*V3__*" -or $text -like "*V4__*") -and
            ($text -like "*migration*" -or $text -like "*마이그레이션*")) { return $true }
    return $false
}

function Assert-ForbiddenKeywordAbsent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Keyword
    )

    $matches = @(Find-FixedStringMatches -Needle $Keyword)
    if ($matches.Count -gt 0) {
        throw "Forbidden keyword '$Keyword' found outside allowed usage:$([Environment]::NewLine)$(Format-MatchList -Matches $matches)"
    }
}

function Assert-HistoricalKeywordOnly {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Keyword
    )

    $matches = @(Find-FixedStringMatches -Needle $Keyword)
    $invalid = @($matches | Where-Object { -not (Test-HistoricalMatchAllowed -Match $_ -Keyword $Keyword) })
    if ($invalid.Count -gt 0) {
        throw "Historical-only keyword '$Keyword' found in active location:$([Environment]::NewLine)$(Format-MatchList -Matches $invalid)"
    }
}

function Assert-RequiredKeywordPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Keyword
    )

    $matches = @(Find-FixedStringMatches -Needle $Keyword)
    if ($matches.Count -eq 0) {
        throw "Required keyword '$Keyword' was not found."
    }
}

function Test-KeywordPolicy {
    foreach ($keyword in @("nose_verification_id", "NoseVerificationAttempt", "NoseVerificationStatus", "ADOPTION_POST_PRECHECK")) {
        Assert-ForbiddenKeywordAbsent -Keyword $keyword
    }

    foreach ($keyword in @("/api/nose-verifications", "nose_verification_attempts")) {
        Assert-HistoricalKeywordOnly -Keyword $keyword
    }

    foreach ($keyword in @("profile_image", "DogImageType.PROFILE", "dog_id")) {
        Assert-RequiredKeywordPresent -Keyword $keyword
    }
}

function Test-AdoptionPostCreateFlow {
    $controllerPath = "backend/src/main/java/com/petnose/api/controller/AdoptionPostController.java"
    $requestPath = "backend/src/main/java/com/petnose/api/dto/adoption/AdoptionPostCreateRequest.java"
    $servicePath = "backend/src/main/java/com/petnose/api/service/AdoptionPostService.java"

    $controller = Read-TextFile -RelativePath $controllerPath
    $request = Read-TextFile -RelativePath $requestPath
    $service = Read-TextFile -RelativePath $servicePath

    Assert-ContainsAny -Text $request -Needles @("dogId", "dog_id") -Subject $requestPath
    Assert-ContainsAny -Text $request -Needles @("profileImage", "profile_image", "MultipartFile") -Subject $requestPath
    Assert-NotContainsAny -Text $request -Needles @("noseVerificationId", "nose_verification_id", "dogName", "breed", "birthDate", "noseImage") -Subject $requestPath

    Assert-ContainsAny -Text $controller -Needles @("MULTIPART_FORM_DATA_VALUE", "multipart/form-data", "@ModelAttribute") -Subject $controllerPath

    Assert-ContainsAny -Text $service -Needles @("saveRequiredProfileImage", "DogImageType.PROFILE") -Subject $servicePath
    Assert-ContainsAny -Text $service -Needles @("validateLatestVerificationLog", "findFirstByDogIdOrderByCreatedAtDescIdDesc") -Subject $servicePath
    Assert-ContainsAny -Text $service -Needles @("validateNoActivePost", "existsByDogIdAndStatusIn") -Subject $servicePath
    Assert-NotContainsAny -Text $service -Needles @(
        "NoseVerificationAttempt",
        "noseVerificationId",
        "createDog(",
        "createNoseImage(",
        "EmbedClient",
        "embedClient.embed",
        "QdrantDogVectorClient",
        "qdrantDogVectorClient.upsert",
        "upsertDogVector"
    ) -Subject $servicePath
}

function Test-DogRegistrationFlow {
    $servicePath = "backend/src/main/java/com/petnose/api/service/DogRegistrationService.java"
    $service = Read-TextFile -RelativePath $servicePath

    Assert-ContainsAny -Text $service -Needles @(
        "qdrantDogVectorClient.upsert(dog.getId()",
        "qdrantDogVectorClient.upsert(pending.dogId()",
        ".upsert(dog.getId()",
        ".upsert(pending.dogId()"
    ) -Subject $servicePath
    Assert-Contains -Text $service -Needle "VerificationLog" -Subject $servicePath
    Assert-Contains -Text $service -Needle "DUPLICATE_SUSPECTED" -Subject $servicePath
}

function Test-CanonicalSchema {
    $sqlPath = "docs/db/V20260508__mvp_canonical_schema.sql"
    $dbmlPath = "docs/db/petnose_mvp_schema.dbml"
    $sql = Read-TextFile -RelativePath $sqlPath
    $dbml = Read-TextFile -RelativePath $dbmlPath
    $tables = @("users", "dogs", "dog_images", "verification_logs", "adoption_posts")

    foreach ($table in $tables) {
        Assert-Regex -Text $sql -Pattern ("(?im)CREATE\s+TABLE\s+`?" + [regex]::Escape($table) + "`?\s*\(") -Subject $sqlPath
        Assert-Regex -Text $dbml -Pattern ("(?im)^Table\s+`?" + [regex]::Escape($table) + "`?\s*\{") -Subject $dbmlPath
    }

    Assert-NotRegex -Text $sql -Pattern "(?im)CREATE\s+TABLE\s+`?nose_verification_attempts`?\s*\(" -Subject $sqlPath
    Assert-NotRegex -Text $dbml -Pattern "(?im)^Table\s+`?nose_verification_attempts`?\s*\{" -Subject $dbmlPath
}

Push-Location $RepoRoot
try {
    $currentBranch = (& git branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read current git branch."
    }

    Write-Host "Current branch: $currentBranch" -ForegroundColor Green
    Write-Host "Gradle command: $GradleFile" -ForegroundColor Green
    if ($currentBranch -eq "develop") {
        throw "Refusing to run on develop. Switch to the refactor branch first."
    }
    if ($ExpectedBranch -and $currentBranch -ne $ExpectedBranch) {
        throw "Expected branch '$ExpectedBranch', but current branch is '$currentBranch'."
    }

    Invoke-Step -Name "git status --short" -Command {
        Invoke-Native -File "git" -Arguments @("status", "--short")
    }

    Invoke-Step -Name "git diff --check" -Command {
        Invoke-Native -File "git" -Arguments @("diff", "--check")
    }

    Invoke-Step -Name "forbidden and required keyword policy" -Command {
        Test-KeywordPolicy
    }

    Invoke-Step -Name "adoption post create dog_id/profile_image flow" -Command {
        Test-AdoptionPostCreateFlow
    }

    Invoke-Step -Name "dog registration vector/log flow" -Command {
        Test-DogRegistrationFlow
    }

    Invoke-Step -Name "canonical 5-table schema shape" -Command {
        Test-CanonicalSchema
    }

    Invoke-Step -Name "$GradleFile test --no-daemon --stacktrace" -WorkingDirectory $BackendDir -Command {
        Invoke-Native -File $GradleFile -Arguments @("test", "--no-daemon", "--stacktrace")
    }

    Invoke-Step -Name "$GradleFile bootJar --no-daemon" -WorkingDirectory $BackendDir -Command {
        Invoke-Native -File $GradleFile -Arguments @("bootJar", "--no-daemon")
    }

    Invoke-Step -Name "docker compose dev config --quiet" -Command {
        Invoke-Native -File "docker" -Arguments @("compose", "-f", "infra/docker/compose.yaml", "-f", "infra/docker/compose.dev.yaml", "config", "--quiet")
    }

    Invoke-Step -Name "docker compose real-model config --quiet" -Command {
        Invoke-Native -File "docker" -Arguments @("compose", "-f", "infra/docker/compose.yaml", "-f", "infra/docker/compose.real-model.yaml", "config", "--quiet")
    }

    Write-Host ""
    Write-Host "VERIFICATION PASSED: dog_id-centered adoption flow is consistent." -ForegroundColor Green
} finally {
    Pop-Location
}
