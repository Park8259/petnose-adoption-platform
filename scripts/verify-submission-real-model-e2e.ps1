#Requires -Version 7.0
<#
.SYNOPSIS
Runs the final PetNose submission real-model E2E smoke and writes sanitized evidence.

.DESCRIPTION
This script verifies the develop submission flow against Spring Boot, Python Embed,
MySQL, Qdrant, and Nginx/file serving. It intentionally keeps passwords, JWTs,
raw images, raw vectors, and full Qdrant payloads out of stdout and committed
evidence.

.EXAMPLE
pwsh ./scripts/verify-submission-real-model-e2e.ps1 -Help

.EXAMPLE
pwsh ./scripts/verify-submission-real-model-e2e.ps1 `
  -BaseUrl http://localhost `
  -QdrantUrl http://localhost:6333 `
  -NoseImageDir "C:\tmp\petnose-submission-fixture\nose-set" `
  -ProfileImagePath "C:\Dev\sample\profile1.jpg" `
  -WriteEvidence `
  -RunReconciliation

.EXAMPLE
pwsh ./scripts/verify-submission-real-model-e2e.ps1 `
  -StartCompose `
  -NoseImageDir "C:\tmp\petnose-submission-fixture\nose-set" `
  -ProfileImagePath "C:\Dev\sample\profile1.jpg" `
  -WriteEvidence `
  -RunReconciliation
#>

[CmdletBinding()]
param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BaseUrl = "http://localhost",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$QdrantUrl = "http://localhost:6333",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$PythonEmbedUrl = "http://localhost:8000",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$NoseImageDir = "",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$ProfileImagePath = "",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$EnvFile = "infra/docker/.env",

    [switch]$StartCompose,
    [switch]$ResetRuntime,
    [switch]$KeepRuntime,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$OutputDir = "docs/ops-evidence/submission-real-model-e2e-local",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$SummaryPath = "docs/ops-evidence/submission-real-model-e2e-summary.json",

    [switch]$WriteEvidence,
    [switch]$RunReconciliation = $true,
    [switch]$SkipDuplicateCase,
    [switch]$SkipHandoverCase,
    [switch]$SkipAdoptionCompletionCase,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$script:EvidenceMarkdownPath = Join-Path $script:RepoRoot "docs\ops-evidence\submission-real-model-e2e-log.md"
$script:StartedCompose = $false
$script:QdrantCollection = "dog_nose_embeddings_real_v2"
$script:ExpectedVectorDimension = 2048
$script:ExpectedDistance = "Cosine"
$script:ComposeFiles = @(
    "infra/docker/compose.yaml",
    "infra/docker/compose.dev.yaml",
    "infra/docker/compose.real-model.yaml"
)

function Show-Usage {
    @"
Usage:
  pwsh ./scripts/verify-submission-real-model-e2e.ps1 [options]

Required for real E2E:
  -NoseImageDir <dir>       Directory outside the repo with exactly 5 jpg/jpeg/png nose images
  -ProfileImagePath <file>  Single jpg/jpeg/png profile image outside the repo

Defaults:
  -BaseUrl                  http://localhost
  -QdrantUrl                http://localhost:6333
  -PythonEmbedUrl           http://localhost:8000
  -EnvFile                  infra/docker/.env
  -OutputDir                docs/ops-evidence/submission-real-model-e2e-local
  -SummaryPath              docs/ops-evidence/submission-real-model-e2e-summary.json
  -RunReconciliation        true

Runtime:
  -StartCompose             Run docker compose up -d --build with real-model compose files
  -ResetRuntime             With -StartCompose, run docker compose down -v first
  -KeepRuntime              With -StartCompose, leave runtime running after the smoke

Evidence:
  -WriteEvidence            Write sanitized Markdown and JSON evidence

Optional skips:
  -SkipDuplicateCase
  -SkipHandoverCase
  -SkipAdoptionCompletionCase

Exit codes:
  0 success
  1 E2E assertion failure
  2 config/runtime error
"@
}

if ($Help) {
    Show-Usage
    exit 0
}

function Fail-Assert {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw "ASSERT: $Message"
}

function Fail-Config {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw "CONFIG: $Message"
}

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return (Join-Path $script:RepoRoot $Path)
}

function Resolve-ExistingFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $resolved = Resolve-RepoPath $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        Fail-Config "$Label not found: $Path"
    }
    return (Resolve-Path -LiteralPath $resolved).Path
}

function Resolve-ExistingDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $resolved = Resolve-RepoPath $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        Fail-Config "$Label not found: $Path"
    }
    return (Resolve-Path -LiteralPath $resolved).Path
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Join-Url {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    return "$($Root.TrimEnd('/'))/$($Path.TrimStart('/'))"
}

function ConvertTo-JsonText {
    param([Parameter(Mandatory = $true)][object]$Value)
    return ($Value | ConvertTo-Json -Depth 80)
}

function Get-PropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Test-Property {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }
    return ($Object.PSObject.Properties.Name -contains $Name)
}

function Test-ContainsPropertyDeep {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$Depth = 0
    )

    if ($null -eq $Object) {
        return $false
    }
    if ($Depth -gt 20) {
        return $false
    }
    if ($Object -is [string] -or $Object.GetType().IsPrimitive -or $Object -is [datetime] -or $Object -is [decimal]) {
        return $false
    }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ([string]$key -eq $Name) {
                return $true
            }
            if (Test-ContainsPropertyDeep -Object $Object[$key] -Name $Name -Depth ($Depth + 1)) {
                return $true
            }
        }
        return $false
    }
    if ($Object -is [System.Array]) {
        foreach ($item in $Object) {
            if (Test-ContainsPropertyDeep -Object $item -Name $Name -Depth ($Depth + 1)) {
                return $true
            }
        }
        return $false
    }
    $properties = @($Object.PSObject.Properties | Where-Object {
        $_.MemberType -in @(
            [System.Management.Automation.PSMemberTypes]::NoteProperty,
            [System.Management.Automation.PSMemberTypes]::Property
        )
    })
    foreach ($property in $properties) {
        if ($property.Name -eq $Name) {
            return $true
        }
        if (Test-ContainsPropertyDeep -Object $property.Value -Name $Name -Depth ($Depth + 1)) {
            return $true
        }
    }
    return $false
}

function Assert-True {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -ne $true) {
        Fail-Assert "$Name must be true. Actual: $Value"
    }
}

function Assert-False {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -ne $false) {
        Fail-Assert "$Name must be false. Actual: $Value"
    }
}

function Assert-Equal {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ("$Actual" -ne "$Expected") {
        Fail-Assert "$Name mismatch. Expected '$Expected', actual '$Actual'."
    }
}

function Assert-NotNullOrEmpty {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value) {
        Fail-Assert "$Name must be present."
    }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
        Fail-Assert "$Name must be non-empty."
    }
}

function Assert-Null {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -ne $Value) {
        Fail-Assert "$Name must be null. Actual: $Value"
    }
}

function Assert-Count {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][int]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $count = @($Value).Count
    if ($count -ne $Expected) {
        Fail-Assert "$Name count mismatch. Expected $Expected, actual $count."
    }
}

function Assert-Status {
    param(
        [Parameter(Mandatory = $true)][object]$Response,
        [Parameter(Mandatory = $true)][int]$ExpectedStatus
    )

    if ([int]$Response.StatusCode -ne $ExpectedStatus) {
        Fail-Assert "Expected HTTP $ExpectedStatus for $($Response.Method) $($Response.Url), actual $($Response.StatusCode)."
    }
}

function Assert-NotContainsProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if (Test-ContainsPropertyDeep -Object $Object -Name $Name) {
        Fail-Assert "$Context must not expose '$Name'."
    }
}

function Read-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }
        $separator = $trimmed.IndexOf("=")
        if ($separator -lt 1) {
            continue
        }
        $key = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $values[$key] = $value
        }
    }
    return $values
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Values,
        [Parameter(Mandatory = $true)][string[]]$Keys,
        [AllowNull()][string]$Fallback
    )

    foreach ($key in $Keys) {
        if ($Values.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$Values[$key])) {
            return [string]$Values[$key]
        }
    }
    return $Fallback
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)][string]$File,
        [string[]]$Arguments = @(),
        [switch]$AllowFailure,
        [string]$Redact = ""
    )

    $output = & $File @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $lines = @($output | ForEach-Object {
        $line = [string]$_
        if (-not [string]::IsNullOrEmpty($Redact)) {
            $line = $line.Replace($Redact, "[REDACTED]")
        }
        $line
    })
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        Fail-Config "$File $($Arguments -join ' ') failed with exit code $exitCode. Output: $($lines -join ' ')"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $lines
    }
}

function Get-GitValue {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $result = Invoke-NativeCapture -File "git" -Arguments $Arguments
    return (($result.Output | Select-Object -First 1) -as [string]).Trim()
}

function Invoke-HttpRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [AllowNull()][object]$BodyObject = $null,
        [AllowNull()][AllowEmptyString()][string]$BearerToken = ""
    )

    $headers = @{
        Accept = "application/json"
    }
    if (-not [string]::IsNullOrWhiteSpace($BearerToken)) {
        $headers["Authorization"] = "Bearer $BearerToken"
    }

    $parameters = @{
        Method = $Method
        Uri = $Url
        Headers = $headers
        SkipHttpErrorCheck = $true
    }
    if ($null -ne $BodyObject) {
        $parameters["ContentType"] = "application/json"
        $parameters["Body"] = ConvertTo-JsonText $BodyObject
    }

    try {
        $response = Invoke-WebRequest @parameters
    } catch {
        Fail-Config "HTTP request failed before response: $Method $Url. $($_.Exception.Message)"
    }

    $bodyText = [string]$response.Content
    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
        try {
            $json = $bodyText | ConvertFrom-Json
        } catch {
            $json = $null
        }
    }

    return [pscustomobject]@{
        Method = $Method
        Url = $Url
        StatusCode = [int]$response.StatusCode
        Json = $json
        BodyText = $bodyText
    }
}

function Get-ImageMimeType {
    param([Parameter(Mandatory = $true)][string]$Path)

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".jpg" { return "image/jpeg" }
        ".jpeg" { return "image/jpeg" }
        ".png" { return "image/png" }
        default { Fail-Config "Only jpg, jpeg, and png are supported: $Path" }
    }
}

function Invoke-MultipartRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [hashtable]$Fields = @{},
        [object[]]$Files = @(),
        [AllowNull()][AllowEmptyString()][string]$BearerToken = ""
    )

    $client = [System.Net.Http.HttpClient]::new()
    $content = [System.Net.Http.MultipartFormDataContent]::new()
    $request = $null
    $response = $null
    $streams = New-Object 'System.Collections.Generic.List[System.IDisposable]'

    try {
        foreach ($key in $Fields.Keys) {
            $fieldContent = [System.Net.Http.StringContent]::new([string]$Fields[$key], [System.Text.Encoding]::UTF8)
            $content.Add($fieldContent, $key)
        }

        foreach ($file in $Files) {
            $stream = [System.IO.File]::OpenRead([string]$file.Path)
            $streams.Add($stream) | Out-Null
            $fileContent = [System.Net.Http.StreamContent]::new($stream)
            $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse([string]$file.MimeType)
            $content.Add($fileContent, [string]$file.FieldName, [System.IO.Path]::GetFileName([string]$file.Path))
        }

        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $Url)
        $request.Content = $content
        $request.Headers.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new("application/json"))
        if (-not [string]::IsNullOrWhiteSpace($BearerToken)) {
            $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $BearerToken)
        }

        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $bodyText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $json = $null
        if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
            try {
                $json = $bodyText | ConvertFrom-Json
            } catch {
                $json = $null
            }
        }

        return [pscustomobject]@{
            Method = "POST"
            Url = $Url
            StatusCode = [int]$response.StatusCode
            Json = $json
            BodyText = $bodyText
        }
    } catch {
        Fail-Config "Multipart request failed before response: POST $Url. $($_.Exception.Message)"
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        if ($null -ne $content) { $content.Dispose() }
        foreach ($stream in $streams) { $stream.Dispose() }
        $client.Dispose()
    }
}

function Get-ImageFiles {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $files = @(Get-ChildItem -LiteralPath $Directory -File |
        Where-Object { $_.Extension.ToLowerInvariant() -in @(".jpg", ".jpeg", ".png") } |
        Sort-Object Name)

    if ($files.Count -ne 5) {
        Fail-Config "NoseImageDir must contain exactly 5 jpg/jpeg/png files. Actual: $($files.Count). Directory: $Directory"
    }
    return $files
}

function Get-FileEvidence {
    param([Parameter(Mandatory = $true)][System.IO.FileInfo[]]$Files)

    $items = @()
    foreach ($file in $Files) {
        $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
        $items += [ordered]@{
            basename = $file.Name
            size_bytes = $file.Length
            sha256 = $hash.Hash.ToLowerInvariant()
        }
    }
    return $items
}

function Invoke-DockerCompose {
    param(
        [string[]]$Arguments = @(),
        [switch]$AllowFailure
    )

    $composeArgs = @("compose", "--env-file", $script:ResolvedEnvFile)
    foreach ($file in $script:ResolvedComposeFiles) {
        $composeArgs += @("-f", $file)
    }
    $composeArgs += $Arguments
    return Invoke-NativeCapture -File "docker" -Arguments $composeArgs -AllowFailure:$AllowFailure -Redact $script:MysqlPassword
}

function Invoke-MySqlQuery {
    param([Parameter(Mandatory = $true)][string]$Query)

    $composeArgs = @("compose", "--env-file", $script:ResolvedEnvFile)
    foreach ($file in $script:ResolvedComposeFiles) {
        $composeArgs += @("-f", $file)
    }
    $composeArgs += @(
        "exec",
        "-T",
        "-e",
        "MYSQL_PWD",
        "mysql",
        "mysql",
        "--batch",
        "--raw",
        "--skip-column-names",
        "--default-character-set=utf8mb4",
        "-h",
        "127.0.0.1",
        "-u",
        $script:MysqlUser,
        $script:MysqlDatabase,
        "-e",
        $Query
    )

    $previousMysqlPwd = [Environment]::GetEnvironmentVariable("MYSQL_PWD", "Process")
    [Environment]::SetEnvironmentVariable("MYSQL_PWD", $script:MysqlPassword, "Process")
    try {
        $result = Invoke-NativeCapture -File "docker" -Arguments $composeArgs -Redact $script:MysqlPassword
    } finally {
        [Environment]::SetEnvironmentVariable("MYSQL_PWD", $previousMysqlPwd, "Process")
    }

    return @($result.Output | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_) -and
        -not ([string]$_).StartsWith("mysql: [Warning]") -and
        -not ([string]$_).StartsWith("Warning:")
    })
}

function Quote-SqlString {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) {
        return "NULL"
    }
    return "'" + $Value.Replace("'", "''") + "'"
}

function Get-DbScalar {
    param([Parameter(Mandatory = $true)][string]$Query)

    $lines = @(Invoke-MySqlQuery -Query $Query)
    if ($lines.Count -lt 1) {
        return $null
    }
    return ([string]($lines | Select-Object -First 1)).Trim()
}

function Get-DbCountsForDog {
    param([Parameter(Mandatory = $true)][string]$DogId)

    $dog = Quote-SqlString $DogId
    return [ordered]@{
        nose_images = [int](Get-DbScalar "SELECT COUNT(*) FROM dog_images WHERE dog_id = $dog AND image_type = 'NOSE';")
        profile_images = [int](Get-DbScalar "SELECT COUNT(*) FROM dog_images WHERE dog_id = $dog AND image_type = 'PROFILE';")
        references_total = [int](Get-DbScalar "SELECT COUNT(*) FROM dog_nose_references WHERE dog_id = $dog;")
        references_reference = [int](Get-DbScalar "SELECT COUNT(*) FROM dog_nose_references WHERE dog_id = $dog AND embedding_kind = 'REFERENCE';")
        references_centroid = [int](Get-DbScalar "SELECT COUNT(*) FROM dog_nose_references WHERE dog_id = $dog AND embedding_kind = 'CENTROID';")
        verification_logs = [int](Get-DbScalar "SELECT COUNT(*) FROM verification_logs WHERE dog_id = $dog;")
        latest_verification_result = Get-DbScalar "SELECT result FROM verification_logs WHERE dog_id = $dog ORDER BY created_at DESC, id DESC LIMIT 1;"
        dog_status = Get-DbScalar "SELECT status FROM dogs WHERE id = $dog;"
        owner_user_id = Get-DbScalar "SELECT CAST(owner_user_id AS CHAR) FROM dogs WHERE id = $dog;"
    }
}

function Get-PostDbState {
    param([Parameter(Mandatory = $true)][string]$PostId)

    $post = [long]$PostId
    return [ordered]@{
        status = Get-DbScalar "SELECT status FROM adoption_posts WHERE id = $post;"
        adopter_user_id = Get-DbScalar "SELECT COALESCE(CAST(adopter_user_id AS CHAR), '') FROM adoption_posts WHERE id = $post;"
        adopted_at_present = [int](Get-DbScalar "SELECT IF(adopted_at IS NULL, 0, 1) FROM adoption_posts WHERE id = $post;")
    }
}

function Invoke-QdrantJson {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][object]$BodyObject = $null
    )

    $response = Invoke-HttpRequest -Method $Method -Url (Join-Url $script:QdrantUrlNormalized $Path) -BodyObject $BodyObject
    if ($response.StatusCode -ne 200) {
        Fail-Config "Qdrant $Method $Path returned HTTP $($response.StatusCode)."
    }
    return $response.Json
}

function Get-QdrantCollectionInfo {
    $json = Invoke-QdrantJson -Method "GET" -Path "collections/$script:QdrantCollection"
    $vectors = $json.result.config.params.vectors
    $dimension = $null
    $distance = $null
    if (Test-Property -Object $vectors -Name "size") {
        $dimension = [int]$vectors.size
        $distance = [string]$vectors.distance
    } else {
        $first = $vectors.PSObject.Properties | Select-Object -First 1
        if ($null -ne $first) {
            $dimension = [int]$first.Value.size
            $distance = [string]$first.Value.distance
        }
    }
    return [ordered]@{
        collection = $script:QdrantCollection
        dimension = $dimension
        distance = $distance
    }
}

function Get-QdrantPointCountForDog {
    param([Parameter(Mandatory = $true)][string]$DogId)

    $body = [ordered]@{
        exact = $true
        filter = [ordered]@{
            must = @(
                [ordered]@{
                    key = "dog_id"
                    match = [ordered]@{ value = $DogId }
                },
                [ordered]@{
                    key = "is_active"
                    match = [ordered]@{ value = $true }
                }
            )
        }
    }
    $json = Invoke-QdrantJson -Method "POST" -Path "collections/$script:QdrantCollection/points/count" -BodyObject $body
    return [int]$json.result.count
}

function Wait-Until {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][scriptblock]$Check,
        [int]$TimeoutSeconds = 240,
        [int]$IntervalSeconds = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = ""
    while ((Get-Date) -lt $deadline) {
        try {
            $result = & $Check
            if ($result -eq $true) {
                Write-Host "READY: $Label"
                return
            }
            if ($null -ne $result) {
                $last = [string]$result
            }
        } catch {
            $last = $_.Exception.Message
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
    Fail-Config "Timed out waiting for $Label. Last result: $last"
}

function Set-ScenarioResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Note = ""
    )

    $script:RunData.scenarios[$Name] = $Status
    if (-not [string]::IsNullOrWhiteSpace($Note)) {
        $script:RunData.scenario_notes[$Name] = $Note
    }
}

function Invoke-Scenario {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    Write-Host ""
    Write-Host "Scenario: $Name"
    & $Command
    Set-ScenarioResult -Name $Name -Status "PASS"
    Write-Host "PASS: $Name"
}

function Find-ItemByProperty {
    param(
        [AllowNull()][object]$Items,
        [Parameter(Mandatory = $true)][string]$Property,
        [Parameter(Mandatory = $true)][string]$Expected
    )

    foreach ($item in @($Items)) {
        if ("$(Get-PropertyValue -Object $item -Name $Property)" -eq $Expected) {
            return $item
        }
    }
    return $null
}

function Get-FileUrl {
    param([Parameter(Mandatory = $true)][string]$MaybeRelativeUrl)

    if ($MaybeRelativeUrl -match "^https?://") {
        return $MaybeRelativeUrl
    }
    return Join-Url $script:HttpRootUrl $MaybeRelativeUrl
}

function Add-ValidationCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Result
    )

    $script:RunData.validation_commands += [ordered]@{
        command = $Command
        result = $Result
    }
}

function New-FixtureContactPhone {
    $suffix = Get-Random -Minimum 10000000 -Maximum 99999999
    return "010$suffix"
}

function Invoke-Reconciliation {
    $localOutput = Join-Path $script:ResolvedOutputDir "reconciliation-summary.json"
    $reconciliationScript = Join-Path $script:RepoRoot "scripts\check-qdrant-reference-consistency.ps1"
    $args = @(
        "-NoProfile",
        "-File",
        $reconciliationScript,
        "-QdrantUrl",
        $script:QdrantUrlNormalized,
        "-Collection",
        $script:QdrantCollection,
        "-EnvFile",
        $script:ResolvedEnvFile,
        "-OutputPath",
        $localOutput,
        "-ExpectedDimension",
        "$script:ExpectedVectorDimension",
        "-ExpectedDistance",
        $script:ExpectedDistance,
        "-FailOnDrift"
    )
    $result = Invoke-NativeCapture -File "pwsh" -Arguments $args -AllowFailure -Redact $script:MysqlPassword
    if ($result.ExitCode -ne 0) {
        Fail-Assert "Qdrant/MySQL reconciliation failed with exit code $($result.ExitCode). Output: $($result.Output -join ' ')"
    }
    $summary = Get-Content -Raw -LiteralPath $localOutput -Encoding UTF8 | ConvertFrom-Json
    Assert-True -Value $summary.consistent -Name "reconciliation.consistent"
    Assert-Equal -Actual @($summary.missing_in_qdrant).Count -Expected 0 -Name "reconciliation.missing_in_qdrant"
    Assert-Equal -Actual @($summary.orphan_in_qdrant).Count -Expected 0 -Name "reconciliation.orphan_in_qdrant"
    Assert-Equal -Actual @($summary.payload_mismatches).Count -Expected 0 -Name "reconciliation.payload_mismatches"
    Assert-Equal -Actual $summary.collection_contract.dimension -Expected $script:ExpectedVectorDimension -Name "reconciliation.collection_dimension"
    Assert-Equal -Actual $summary.collection_contract.distance -Expected $script:ExpectedDistance -Name "reconciliation.collection_distance"
    $script:RunData.reconciliation = [ordered]@{
        consistent = [bool]$summary.consistent
        missing_in_qdrant_count = @($summary.missing_in_qdrant).Count
        orphan_in_qdrant_count = @($summary.orphan_in_qdrant).Count
        payload_mismatch_count = @($summary.payload_mismatches).Count
        output_json_path = "docs/ops-evidence/submission-real-model-e2e-local/reconciliation-summary.json"
    }
}

function Write-EvidenceJson {
    $path = Resolve-RepoPath $SummaryPath
    $json = ConvertTo-JsonText $script:RunData
    Write-Utf8NoBom -Path $path -Text ($json + [Environment]::NewLine)
}

function Convert-ScenarioLabel {
    param([Parameter(Mandatory = $true)][string]$Name)

    switch ($Name) {
        "auth" { return "Auth register/login/me" }
        "dog_registration_normal" { return "Dog registration normal" }
        "dog_registration_duplicate" { return "Duplicate suspected" }
        "adoption_post_create" { return "Adoption post create" }
        "public_privacy" { return "Public privacy" }
        "dog_query" { return "Dog query owner/public" }
        "handover_verification" { return "Handover verification" }
        "adoption_completion" { return "Adoption completion" }
        "my_adopted_dogs" { return "My adopted dogs" }
        "file_serving" { return "File serving" }
        "reconciliation" { return "Reconciliation" }
        default { return $Name }
    }
}

function Add-MarkdownTable {
    param(
        [Parameter(Mandatory = $true)][object]$Lines,
        [Parameter(Mandatory = $true)][string[]]$Header,
        [Parameter(Mandatory = $true)][object[]]$Rows
    )

    $Lines.Add("| $($Header -join ' | ') |") | Out-Null
    $Lines.Add("| $((@($Header | ForEach-Object { '---' })) -join ' | ') |") | Out-Null
    foreach ($row in $Rows) {
        $values = @($row | ForEach-Object { "$_".Replace("`r", " ").Replace("`n", " ") })
        $Lines.Add("| $($values -join ' | ') |") | Out-Null
    }
}

function Write-EvidenceMarkdown {
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("# Submission Real-Model E2E Log") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Scope") | Out-Null
    $lines.Add("- Final develop submission smoke") | Out-Null
    $lines.Add("- Real dog nose model") | Out-Null
    $lines.Add("- MySQL/Qdrant/Python/Spring/Nginx end-to-end") | Out-Null
    $lines.Add("- No raw image/model/secret committed") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Environment") | Out-Null
    $lines.Add("- Date/time KST: $($script:RunData.checked_at)") | Out-Null
    $lines.Add("- Branch name: $($script:RunData.branch)") | Out-Null
    $lines.Add("- Commit SHA: $($script:RunData.commit_sha)") | Out-Null
    $lines.Add("- Base develop SHA: $($script:RunData.base_develop_sha)") | Out-Null
    $lines.Add("- Compose files: $($script:RunData.environment.compose_files -join ', ')") | Out-Null
    $lines.Add("- Runtime mode: $($script:RunData.environment.runtime_mode)") | Out-Null
    $lines.Add("- Model: $($script:RunData.runtime.python_model)") | Out-Null
    $lines.Add("- Vector dimension: $($script:RunData.runtime.python_vector_dim)") | Out-Null
    $lines.Add("- Qdrant collection: $($script:RunData.runtime.qdrant_collection)") | Out-Null
    $lines.Add("- Qdrant distance: $($script:RunData.runtime.qdrant_distance)") | Out-Null
    $lines.Add("- Evidence redaction policy: tokens/passwords/raw images/raw vectors/full payloads are not written") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Preflight") | Out-Null
    Add-MarkdownTable -Lines $lines -Header @("Check", "Result", "Observed") -Rows @(
        @("Spring health", $script:RunData.preflight.spring_health_result, $script:RunData.runtime.spring_health),
        @("Python health", $script:RunData.preflight.python_health_result, $script:RunData.runtime.python_model),
        @("model_loaded", $script:RunData.preflight.python_model_loaded_result, $script:RunData.runtime.python_model_loaded),
        @("vector_dim", $script:RunData.preflight.python_vector_dim_result, $script:RunData.runtime.python_vector_dim),
        @("Qdrant collection exists", $script:RunData.preflight.qdrant_collection_result, $script:RunData.runtime.qdrant_collection),
        @("collection dimension", $script:RunData.preflight.qdrant_dimension_result, $script:RunData.runtime.qdrant_vector_size),
        @("collection distance", $script:RunData.preflight.qdrant_distance_result, $script:RunData.runtime.qdrant_distance),
        @("DB migrated", $script:RunData.preflight.db_migrated_result, $script:RunData.preflight.db_migration_summary)
    )
    $lines.Add("") | Out-Null
    $lines.Add("## Scenario Results") | Out-Null
    $scenarioRows = @()
    foreach ($key in $script:RunData.scenarios.Keys) {
        $note = ""
        if ($script:RunData.scenario_notes.Contains($key)) {
            $note = $script:RunData.scenario_notes[$key]
        }
        $scenarioRows += ,@((Convert-ScenarioLabel -Name ([string]$key)), $script:RunData.scenarios[$key], $note)
    }
    Add-MarkdownTable -Lines $lines -Header @("Scenario", "Result", "Note") -Rows $scenarioRows
    $lines.Add("") | Out-Null
    $lines.Add("## Count Assertions") | Out-Null
    $countRows = @()
    foreach ($key in $script:RunData.counts.Keys) {
        $countRows += ,@($key, $script:RunData.counts[$key])
    }
    Add-MarkdownTable -Lines $lines -Header @("Assertion", "Value") -Rows $countRows
    $lines.Add("") | Out-Null
    $lines.Add("## Reconciliation Summary") | Out-Null
    $lines.Add("- consistent=$($script:RunData.reconciliation.consistent)") | Out-Null
    $lines.Add("- missing/orphan/mismatch counts: $($script:RunData.reconciliation.missing_in_qdrant_count)/$($script:RunData.reconciliation.orphan_in_qdrant_count)/$($script:RunData.reconciliation.payload_mismatch_count)") | Out-Null
    $lines.Add("- output JSON path: $($script:RunData.reconciliation.output_json_path)") | Out-Null
    $lines.Add("- no raw Qdrant vector stored") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Redaction") | Out-Null
    $lines.Add("- JWT redacted") | Out-Null
    $lines.Add("- password redacted") | Out-Null
    $lines.Add("- reset token redacted") | Out-Null
    $lines.Add("- Firebase token redacted") | Out-Null
    $lines.Add("- FCM token redacted") | Out-Null
    $lines.Add("- service account not used/not committed") | Out-Null
    $lines.Add("- real images not committed") | Out-Null
    $lines.Add("- model checkpoint not committed") | Out-Null
    $lines.Add("- private email/phone fixture-only or redacted") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Validation Commands") | Out-Null
    $commandRows = @()
    foreach ($command in $script:RunData.validation_commands) {
        $commandRows += ,@($command.command, $command.result)
    }
    Add-MarkdownTable -Lines $lines -Header @("Command", "Result") -Rows $commandRows
    $lines.Add("") | Out-Null
    $lines.Add("## Fixture Inputs") | Out-Null
    $lines.Add("- Nose image source: local path outside repository, basename/count/hash only recorded") | Out-Null
    $lines.Add("- Nose image count: $($script:RunData.fixture.nose_images.count)") | Out-Null
    $lines.Add("- Profile image source: local path outside repository, basename/hash only recorded") | Out-Null
    $lines.Add("- Profile image basename: $($script:RunData.fixture.profile_image.basename)") | Out-Null
    $lines.Add("") | Out-Null

    Write-Utf8NoBom -Path $script:EvidenceMarkdownPath -Text (($lines -join [Environment]::NewLine) + [Environment]::NewLine)
}

try {
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        Fail-Config "BaseUrl must not be empty."
    }
    if ([string]::IsNullOrWhiteSpace($QdrantUrl)) {
        Fail-Config "QdrantUrl must not be empty."
    }
    if ([string]::IsNullOrWhiteSpace($PythonEmbedUrl)) {
        Fail-Config "PythonEmbedUrl must not be empty."
    }
    if ([string]::IsNullOrWhiteSpace($NoseImageDir)) {
        Fail-Config "NoseImageDir is required unless -Help is used."
    }
    if ([string]::IsNullOrWhiteSpace($ProfileImagePath)) {
        Fail-Config "ProfileImagePath is required unless -Help is used."
    }
    if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        Fail-Config "OutputDir must not be empty."
    }
    if ([string]::IsNullOrWhiteSpace($SummaryPath)) {
        Fail-Config "SummaryPath must not be empty."
    }

    $script:ResolvedEnvFile = Resolve-ExistingFile -Path $EnvFile -Label "EnvFile"
    if ((Split-Path -Leaf $script:ResolvedEnvFile) -eq ".env.example") {
        Fail-Config "Refusing to use .env.example as runtime secrets."
    }
    $script:ResolvedComposeFiles = @()
    foreach ($file in $script:ComposeFiles) {
        $script:ResolvedComposeFiles += Resolve-ExistingFile -Path $file -Label "ComposeFile"
    }
    $script:ResolvedOutputDir = Resolve-RepoPath $OutputDir
    if (-not (Test-Path -LiteralPath $script:ResolvedOutputDir -PathType Container)) {
        New-Item -ItemType Directory -Path $script:ResolvedOutputDir -Force | Out-Null
    }

    $envValues = Read-DotEnv -Path $script:ResolvedEnvFile
    $script:MysqlDatabase = Get-ConfigValue -Values $envValues -Keys @("MYSQL_DATABASE") -Fallback "petnose"
    $script:MysqlUser = Get-ConfigValue -Values $envValues -Keys @("MYSQL_USER", "SPRING_DATASOURCE_USERNAME") -Fallback "petnose"
    $script:MysqlPassword = Get-ConfigValue -Values $envValues -Keys @("MYSQL_PASSWORD", "SPRING_DATASOURCE_PASSWORD") -Fallback ""
    if ([string]::IsNullOrWhiteSpace($script:MysqlPassword)) {
        Fail-Config "MYSQL_PASSWORD/SPRING_DATASOURCE_PASSWORD not found in EnvFile."
    }

    $resolvedNoseImageDir = Resolve-ExistingDirectory -Path $NoseImageDir -Label "NoseImageDir"
    $noseFiles = @(Get-ImageFiles -Directory $resolvedNoseImageDir)
    $resolvedProfileImagePath = Resolve-ExistingFile -Path $ProfileImagePath -Label "ProfileImagePath"
    $profileMimeType = Get-ImageMimeType -Path $resolvedProfileImagePath
    $noseEvidence = @(Get-FileEvidence -Files $noseFiles)
    $profileHash = Get-FileHash -LiteralPath $resolvedProfileImagePath -Algorithm SHA256

    $BaseUrl = $BaseUrl.TrimEnd("/")
    if ($BaseUrl.ToLowerInvariant().EndsWith("/api")) {
        $script:ApiBaseUrl = $BaseUrl
        $script:HttpRootUrl = $BaseUrl.Substring(0, $BaseUrl.Length - 4).TrimEnd("/")
    } else {
        $script:HttpRootUrl = $BaseUrl
        $script:ApiBaseUrl = Join-Url $BaseUrl "api"
    }
    $script:QdrantUrlNormalized = $QdrantUrl.TrimEnd("/")
    $script:PythonEmbedUrlNormalized = $PythonEmbedUrl.TrimEnd("/")

    $branch = Get-GitValue -Arguments @("branch", "--show-current")
    $commitSha = Get-GitValue -Arguments @("rev-parse", "HEAD")
    $baseDevelopSha = Get-GitValue -Arguments @("rev-parse", "origin/develop")

    $scenarioNames = @(
        "auth",
        "dog_registration_normal",
        "dog_registration_duplicate",
        "adoption_post_create",
        "public_privacy",
        "dog_query",
        "handover_verification",
        "adoption_completion",
        "my_adopted_dogs",
        "file_serving",
        "reconciliation"
    )
    $scenarios = [ordered]@{}
    foreach ($name in $scenarioNames) {
        $scenarios[$name] = "PENDING"
    }

    $script:RunData = [ordered]@{
        checked_at = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
        branch = $branch
        commit_sha = $commitSha
        base_develop_sha = $baseDevelopSha
        environment = [ordered]@{
            compose_files = $script:ComposeFiles
            runtime_mode = "real-model"
            base_url = $script:HttpRootUrl
            api_base_url = $script:ApiBaseUrl
            qdrant_url = $script:QdrantUrlNormalized
            python_embed_url = $script:PythonEmbedUrlNormalized
            output_dir = "docs/ops-evidence/submission-real-model-e2e-local"
            redaction_policy = "JWT/password/reset token/Firebase token/FCM token/service account/raw images/raw vectors/full Qdrant payloads are not written."
        }
        fixture = [ordered]@{
            nose_images = [ordered]@{
                count = $noseFiles.Count
                files = $noseEvidence
            }
            profile_image = [ordered]@{
                basename = [System.IO.Path]::GetFileName($resolvedProfileImagePath)
                size_bytes = (Get-Item -LiteralPath $resolvedProfileImagePath).Length
                sha256 = $profileHash.Hash.ToLowerInvariant()
            }
        }
        runtime = [ordered]@{
            spring_health = $null
            python_model_loaded = $null
            python_model = $null
            python_vector_dim = $null
            qdrant_collection = $script:QdrantCollection
            qdrant_vector_size = $null
            qdrant_distance = $null
        }
        preflight = [ordered]@{}
        scenarios = $scenarios
        scenario_notes = [ordered]@{}
        counts = [ordered]@{}
        reconciliation = [ordered]@{
            consistent = $false
            missing_in_qdrant_count = $null
            orphan_in_qdrant_count = $null
            payload_mismatch_count = $null
            output_json_path = ""
        }
        redaction = [ordered]@{
            tokens_redacted = $true
            raw_vectors_committed = $false
            raw_images_committed = $false
            model_checkpoint_committed = $false
            env_committed = $false
        }
        validation_commands = @()
    }

    Write-Host "PetNose final submission real-model E2E"
    Write-Host "Branch: $branch"
    Write-Host "Commit under test: $commitSha"
    Write-Host "Base develop: $baseDevelopSha"
    Write-Host "Nose image count: $($noseFiles.Count)"

    if ($StartCompose) {
        Add-ValidationCommand -Command "docker compose --env-file infra/docker/.env -f infra/docker/compose.yaml -f infra/docker/compose.dev.yaml -f infra/docker/compose.real-model.yaml config" -Result "PASS"
        Invoke-DockerCompose -Arguments @("config") | Out-Null
        if ($ResetRuntime) {
            Invoke-DockerCompose -Arguments @("down", "-v", "--remove-orphans") | Out-Null
        }
        Invoke-DockerCompose -Arguments @("up", "-d", "--build") | Out-Null
        $script:StartedCompose = $true
    }

    Wait-Until -Label "Spring actuator health" -Check {
        $health = Invoke-HttpRequest -Method "GET" -Url (Join-Url $script:HttpRootUrl "actuator/health")
        if ($health.StatusCode -ne 200) {
            return "HTTP $($health.StatusCode)"
        }
        if ((Get-PropertyValue -Object $health.Json -Name "status") -ne "UP") {
            return "status=$((Get-PropertyValue -Object $health.Json -Name 'status'))"
        }
        return $true
    }
    $springHealth = Invoke-HttpRequest -Method "GET" -Url (Join-Url $script:HttpRootUrl "actuator/health")
    Assert-Status -Response $springHealth -ExpectedStatus 200
    Assert-Equal -Actual $springHealth.Json.status -Expected "UP" -Name "spring health"
    $script:RunData.runtime.spring_health = "UP"
    $script:RunData.preflight.spring_health_result = "PASS"
    Add-ValidationCommand -Command "GET /actuator/health" -Result "PASS"

    $pythonHealth = Invoke-HttpRequest -Method "GET" -Url (Join-Url $script:PythonEmbedUrlNormalized "health")
    Assert-Status -Response $pythonHealth -ExpectedStatus 200
    Assert-True -Value $pythonHealth.Json.model_loaded -Name "python.model_loaded"
    Assert-Equal -Actual $pythonHealth.Json.vector_dim -Expected $script:ExpectedVectorDimension -Name "python.vector_dim"
    if (-not ([string]$pythonHealth.Json.model).Contains("dog-nose-identification2")) {
        Fail-Assert "python.model must be the active real model. Actual: $($pythonHealth.Json.model)"
    }
    $script:RunData.runtime.python_model_loaded = [bool]$pythonHealth.Json.model_loaded
    $script:RunData.runtime.python_model = [string]$pythonHealth.Json.model
    $script:RunData.runtime.python_vector_dim = [int]$pythonHealth.Json.vector_dim
    $script:RunData.preflight.python_health_result = "PASS"
    $script:RunData.preflight.python_model_loaded_result = "PASS"
    $script:RunData.preflight.python_vector_dim_result = "PASS"
    Add-ValidationCommand -Command "GET /health (Python Embed)" -Result "PASS"

    $qdrantInfo = Get-QdrantCollectionInfo
    Assert-Equal -Actual $qdrantInfo.collection -Expected $script:QdrantCollection -Name "qdrant.collection"
    Assert-Equal -Actual $qdrantInfo.dimension -Expected $script:ExpectedVectorDimension -Name "qdrant.dimension"
    Assert-Equal -Actual $qdrantInfo.distance -Expected $script:ExpectedDistance -Name "qdrant.distance"
    $script:RunData.runtime.qdrant_vector_size = [int]$qdrantInfo.dimension
    $script:RunData.runtime.qdrant_distance = [string]$qdrantInfo.distance
    $script:RunData.preflight.qdrant_collection_result = "PASS"
    $script:RunData.preflight.qdrant_dimension_result = "PASS"
    $script:RunData.preflight.qdrant_distance_result = "PASS"
    Add-ValidationCommand -Command "GET /collections/dog_nose_embeddings_real_v2" -Result "PASS"

    $migrationVersion = Get-DbScalar "SELECT COALESCE(MAX(version), '') FROM flyway_schema_history WHERE success = 1;"
    $referenceTableExists = [int](Get-DbScalar "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = 'dog_nose_references';")
    Assert-Equal -Actual $referenceTableExists -Expected 1 -Name "DB dog_nose_references table exists"
    $script:RunData.preflight.db_migrated_result = "PASS"
    $script:RunData.preflight.db_migration_summary = "flyway_max_version=$migrationVersion"
    Add-ValidationCommand -Command "MySQL flyway/table preflight" -Result "PASS"

    $timestamp = Get-Date -Format "yyyyMMddHHmmssfff"
    $random = Get-Random -Minimum 1000 -Maximum 9999
    $ownerEmail = "submission-owner-$timestamp-$random@example.test"
    $adopterEmail = "submission-adopter-$timestamp-$random@example.test"
    $password = "Petnose-$timestamp-$random!"
    $ownerToken = ""
    $adopterToken = ""
    $ownerUserId = ""
    $adopterUserId = ""
    $normalDogId = ""
    $duplicateDogId = ""
    $postId = ""
    $profileImageUrl = ""
    $ownerNoseImageUrl = ""
    $qdrantCountAfterNormal = $null
    $normalCountsAfterPost = $null
    $handoverBeforeCounts = $null
    $handoverBeforePostState = $null

    Invoke-Scenario -Name "auth" -Command {
        $ownerRegister = Invoke-HttpRequest -Method "POST" -Url (Join-Url $script:ApiBaseUrl "auth/register") -BodyObject @{
            email = $ownerEmail
            password = $password
            display_name = "Submission Owner"
            contact_phone = New-FixtureContactPhone
            region = "Seoul"
        }
        Assert-Status -Response $ownerRegister -ExpectedStatus 201
        Assert-NotNullOrEmpty -Value $ownerRegister.Json.user_id -Name "owner register user_id"
        Assert-NotContainsProperty -Object $ownerRegister.Json -Name "password_hash" -Context "owner register response"
        $script:ownerUserId = [string]$ownerRegister.Json.user_id

        $adopterRegister = Invoke-HttpRequest -Method "POST" -Url (Join-Url $script:ApiBaseUrl "auth/register") -BodyObject @{
            email = $adopterEmail
            password = $password
            display_name = "Submission Adopter"
            contact_phone = New-FixtureContactPhone
            region = "Busan"
        }
        Assert-Status -Response $adopterRegister -ExpectedStatus 201
        Assert-NotNullOrEmpty -Value $adopterRegister.Json.user_id -Name "adopter register user_id"
        Assert-NotContainsProperty -Object $adopterRegister.Json -Name "password_hash" -Context "adopter register response"
        $script:adopterUserId = [string]$adopterRegister.Json.user_id

        $ownerLogin = Invoke-HttpRequest -Method "POST" -Url (Join-Url $script:ApiBaseUrl "auth/login") -BodyObject @{
            email = $ownerEmail
            password = $password
        }
        Assert-Status -Response $ownerLogin -ExpectedStatus 200
        Assert-NotNullOrEmpty -Value $ownerLogin.Json.access_token -Name "owner access token"
        Assert-Equal -Actual $ownerLogin.Json.token_type -Expected "Bearer" -Name "owner token_type"
        $script:ownerToken = [string]$ownerLogin.Json.access_token

        $adopterLogin = Invoke-HttpRequest -Method "POST" -Url (Join-Url $script:ApiBaseUrl "auth/login") -BodyObject @{
            email = $adopterEmail
            password = $password
        }
        Assert-Status -Response $adopterLogin -ExpectedStatus 200
        Assert-NotNullOrEmpty -Value $adopterLogin.Json.access_token -Name "adopter access token"
        $script:adopterToken = [string]$adopterLogin.Json.access_token

        $me = Invoke-HttpRequest -Method "GET" -Url (Join-Url $script:ApiBaseUrl "users/me") -BearerToken $script:ownerToken
        Assert-Status -Response $me -ExpectedStatus 200
        Assert-Equal -Actual $me.Json.user_id -Expected $script:ownerUserId -Name "users/me user_id"
        Assert-NotContainsProperty -Object $me.Json -Name "password_hash" -Context "users/me response"
        $script:RunData.counts["owner_user_id_fixture"] = "<redacted-fixture-user-id-present>"
        $script:RunData.counts["adopter_user_id_fixture"] = "<redacted-fixture-user-id-present>"
    }

    Invoke-Scenario -Name "dog_registration_normal" -Command {
        $files = @()
        foreach ($noseFile in $noseFiles) {
            $files += [pscustomobject]@{
                FieldName = "nose_images"
                Path = $noseFile.FullName
                MimeType = Get-ImageMimeType -Path $noseFile.FullName
            }
        }
        $response = Invoke-MultipartRequest -Url (Join-Url $script:ApiBaseUrl "dogs/register") -Fields @{
            name = "Submission Choco"
            breed = "Maltese"
            gender = "MALE"
            birth_date = "2024-01-01"
            description = "Submission real-model E2E normal registration"
        } -Files $files -BearerToken $script:ownerToken

        Assert-Status -Response $response -ExpectedStatus 201
        Assert-True -Value $response.Json.registration_allowed -Name "normal.registration_allowed"
        Assert-Equal -Actual $response.Json.status -Expected "REGISTERED" -Name "normal.status"
        Assert-Equal -Actual $response.Json.verification_status -Expected "VERIFIED" -Name "normal.verification_status"
        Assert-Equal -Actual $response.Json.embedding_status -Expected "COMPLETED" -Name "normal.embedding_status"
        Assert-Null -Value $response.Json.qdrant_point_id -Name "normal.qdrant_point_id"
        Assert-Equal -Actual $response.Json.embedding_mode -Expected "MULTI_REFERENCE" -Name "normal.embedding_mode"
        Assert-Equal -Actual $response.Json.reference_count -Expected 5 -Name "normal.reference_count"
        Assert-Count -Value $response.Json.nose_image_urls -Expected 5 -Name "normal.nose_image_urls"
        Assert-NotNullOrEmpty -Value $response.Json.score_breakdown -Name "normal.score_breakdown"
        Assert-Equal -Actual $response.Json.dimension -Expected $script:ExpectedVectorDimension -Name "normal.dimension"
        Assert-NotNullOrEmpty -Value $response.Json.dog_id -Name "normal.dog_id"
        $script:normalDogId = [string]$response.Json.dog_id
        $script:ownerNoseImageUrl = [string](@($response.Json.nose_image_urls) | Select-Object -First 1)

        $counts = Get-DbCountsForDog -DogId $script:normalDogId
        $qdrantCount = Get-QdrantPointCountForDog -DogId $script:normalDogId
        Assert-Equal -Actual $counts.nose_images -Expected 5 -Name "normal dog nose images DB count"
        Assert-Equal -Actual $counts.references_total -Expected 6 -Name "normal dog references total"
        Assert-Equal -Actual $counts.references_reference -Expected 5 -Name "normal dog REFERENCE count"
        Assert-Equal -Actual $counts.references_centroid -Expected 1 -Name "normal dog CENTROID count"
        Assert-Equal -Actual $qdrantCount -Expected 6 -Name "normal dog Qdrant active points"
        Assert-Equal -Actual $counts.latest_verification_result -Expected "PASSED" -Name "normal latest verification result"
        Assert-Equal -Actual $counts.dog_status -Expected "REGISTERED" -Name "normal dog DB status"
        $script:qdrantCountAfterNormal = $qdrantCount
        $script:RunData.counts["normal_nose_images"] = $counts.nose_images
        $script:RunData.counts["normal_references_total"] = $counts.references_total
        $script:RunData.counts["normal_references_reference"] = $counts.references_reference
        $script:RunData.counts["normal_references_centroid"] = $counts.references_centroid
        $script:RunData.counts["qdrant_active_point_count_after_normal"] = $qdrantCount
        $script:RunData.counts["normal_latest_verification_result"] = $counts.latest_verification_result
        $script:RunData.counts["normal_dog_status"] = $counts.dog_status
    }

    if ($SkipDuplicateCase) {
        Set-ScenarioResult -Name "dog_registration_duplicate" -Status "SKIP" -Note "Skipped by -SkipDuplicateCase."
    } else {
        Invoke-Scenario -Name "dog_registration_duplicate" -Command {
            $files = @()
            foreach ($noseFile in $noseFiles) {
                $files += [pscustomobject]@{
                    FieldName = "nose_images"
                    Path = $noseFile.FullName
                    MimeType = Get-ImageMimeType -Path $noseFile.FullName
                }
            }
            $response = Invoke-MultipartRequest -Url (Join-Url $script:ApiBaseUrl "dogs/register") -Fields @{
                name = "Submission Duplicate"
                breed = "Maltese"
                gender = "MALE"
                birth_date = "2024-01-01"
                description = "Submission real-model E2E duplicate registration"
            } -Files $files -BearerToken $script:ownerToken

            Assert-Status -Response $response -ExpectedStatus 200
            Assert-False -Value $response.Json.registration_allowed -Name "duplicate.registration_allowed"
            Assert-Equal -Actual $response.Json.status -Expected "DUPLICATE_SUSPECTED" -Name "duplicate.status"
            Assert-Equal -Actual $response.Json.embedding_status -Expected "SKIPPED_DUPLICATE" -Name "duplicate.embedding_status"
            Assert-Null -Value $response.Json.qdrant_point_id -Name "duplicate.qdrant_point_id"
            Assert-NotNullOrEmpty -Value $response.Json.top_match -Name "duplicate.top_match"
            Assert-NotNullOrEmpty -Value $response.Json.dog_id -Name "duplicate.dog_id"
            $script:duplicateDogId = [string]$response.Json.dog_id

            $duplicateCounts = Get-DbCountsForDog -DogId $script:duplicateDogId
            $qdrantCountAfterDuplicate = Get-QdrantPointCountForDog -DogId $script:normalDogId
            Assert-Equal -Actual $duplicateCounts.nose_images -Expected 5 -Name "duplicate dog nose images DB count"
            Assert-Equal -Actual $duplicateCounts.references_total -Expected 0 -Name "duplicate dog references total"
            Assert-Equal -Actual $duplicateCounts.latest_verification_result -Expected "DUPLICATE_SUSPECTED" -Name "duplicate latest verification result"
            Assert-Equal -Actual $qdrantCountAfterDuplicate -Expected $script:qdrantCountAfterNormal -Name "Qdrant active point count unchanged after duplicate"
            $script:RunData.counts["duplicate_nose_images"] = $duplicateCounts.nose_images
            $script:RunData.counts["duplicate_references_total"] = $duplicateCounts.references_total
            $script:RunData.counts["duplicate_latest_verification_result"] = $duplicateCounts.latest_verification_result
            $script:RunData.counts["qdrant_active_point_count_after_duplicate"] = $qdrantCountAfterDuplicate
            $script:RunData.counts["qdrant_duplicate_unchanged"] = ($qdrantCountAfterDuplicate -eq $script:qdrantCountAfterNormal)
        }
    }

    Invoke-Scenario -Name "adoption_post_create" -Command {
        $response = Invoke-MultipartRequest -Url (Join-Url $script:ApiBaseUrl "adoption-posts") -Fields @{
            dog_id = $script:normalDogId
            title = "Submission E2E adoption post"
            content = "Submission real-model E2E adoption post"
            status = "OPEN"
        } -Files @(
            [pscustomobject]@{
                FieldName = "profile_image"
                Path = $resolvedProfileImagePath
                MimeType = $profileMimeType
            }
        ) -BearerToken $script:ownerToken

        Assert-Status -Response $response -ExpectedStatus 201
        Assert-NotNullOrEmpty -Value $response.Json.post_id -Name "post.post_id"
        Assert-Equal -Actual $response.Json.dog_id -Expected $script:normalDogId -Name "post.dog_id"
        Assert-Equal -Actual $response.Json.status -Expected "OPEN" -Name "post.status"
        $script:postId = [string]$response.Json.post_id

        $postDogCounts = Get-DbCountsForDog -DogId $script:normalDogId
        $qdrantCountAfterPost = Get-QdrantPointCountForDog -DogId $script:normalDogId
        Assert-Equal -Actual $postDogCounts.profile_images -Expected 1 -Name "post profile image DB count"
        Assert-Equal -Actual $qdrantCountAfterPost -Expected $script:qdrantCountAfterNormal -Name "Qdrant count unchanged after post create"
        $script:normalCountsAfterPost = $postDogCounts
        $script:RunData.counts["profile_images_after_post"] = $postDogCounts.profile_images
        $script:RunData.counts["qdrant_after_post_unchanged"] = ($qdrantCountAfterPost -eq $script:qdrantCountAfterNormal)
    }

    Invoke-Scenario -Name "public_privacy" -Command {
        $list = Invoke-HttpRequest -Method "GET" -Url (Join-Url $script:ApiBaseUrl "adoption-posts?status=OPEN&page=0&size=50")
        Assert-Status -Response $list -ExpectedStatus 200
        $item = Find-ItemByProperty -Items $list.Json.items -Property "post_id" -Expected $script:postId
        Assert-NotNullOrEmpty -Value $item -Name "created post in public list"
        Assert-NotContainsProperty -Object $item -Name "nose_image_url" -Context "public adoption list item"
        Assert-NotContainsProperty -Object $item -Name "author_user_id" -Context "public adoption list item"
        Assert-NotContainsProperty -Object $item -Name "payload" -Context "public adoption list item"
        Assert-NotContainsProperty -Object $item -Name "vector" -Context "public adoption list item"
        Assert-NotNullOrEmpty -Value $item.profile_image_url -Name "public list profile_image_url"
        $script:profileImageUrl = [string]$item.profile_image_url

        $detail = Invoke-HttpRequest -Method "GET" -Url (Join-Url $script:ApiBaseUrl "adoption-posts/$script:postId")
        Assert-Status -Response $detail -ExpectedStatus 200
        Assert-Equal -Actual $detail.Json.post_id -Expected $script:postId -Name "public detail post_id"
        Assert-NotContainsProperty -Object $detail.Json -Name "nose_image_url" -Context "public adoption detail"
        Assert-NotContainsProperty -Object $detail.Json -Name "author_user_id" -Context "public adoption detail"
        Assert-NotContainsProperty -Object $detail.Json -Name "payload" -Context "public adoption detail"
        Assert-NotContainsProperty -Object $detail.Json -Name "vector" -Context "public adoption detail"
        Assert-NotNullOrEmpty -Value $detail.Json.profile_image_url -Name "public detail profile_image_url"
        $script:profileImageUrl = [string]$detail.Json.profile_image_url
    }

    Invoke-Scenario -Name "dog_query" -Command {
        $mine = Invoke-HttpRequest -Method "GET" -Url (Join-Url $script:ApiBaseUrl "dogs/me?page=0&size=50") -BearerToken $script:ownerToken
        Assert-Status -Response $mine -ExpectedStatus 200
        $mineItem = Find-ItemByProperty -Items $mine.Json.items -Property "dog_id" -Expected $script:normalDogId
        Assert-NotNullOrEmpty -Value $mineItem -Name "normal dog in owner list"
        Assert-False -Value $mineItem.can_create_post -Name "owner list can_create_post after active post"

        $ownerDetail = Invoke-HttpRequest -Method "GET" -Url (Join-Url $script:ApiBaseUrl "dogs/$script:normalDogId") -BearerToken $script:ownerToken
        Assert-Status -Response $ownerDetail -ExpectedStatus 200
        Assert-Equal -Actual $ownerDetail.Json.dog_id -Expected $script:normalDogId -Name "owner dog detail dog_id"
        Assert-NotNullOrEmpty -Value $ownerDetail.Json.nose_image_url -Name "owner dog detail nose_image_url"
        Assert-False -Value $ownerDetail.Json.can_create_post -Name "owner detail can_create_post after active post"
        $script:ownerNoseImageUrl = [string]$ownerDetail.Json.nose_image_url

        $publicDetail = Invoke-HttpRequest -Method "GET" -Url (Join-Url $script:ApiBaseUrl "dogs/$script:normalDogId")
        Assert-Status -Response $publicDetail -ExpectedStatus 200
        Assert-NotContainsProperty -Object $publicDetail.Json -Name "nose_image_url" -Context "public dog detail"

        $otherDetail = Invoke-HttpRequest -Method "GET" -Url (Join-Url $script:ApiBaseUrl "dogs/$script:normalDogId") -BearerToken $script:adopterToken
        Assert-Status -Response $otherDetail -ExpectedStatus 200
        Assert-NotContainsProperty -Object $otherDetail.Json -Name "nose_image_url" -Context "other-user dog detail"
    }

    if ($SkipHandoverCase) {
        Set-ScenarioResult -Name "handover_verification" -Status "SKIP" -Note "Skipped by -SkipHandoverCase."
    } else {
        Invoke-Scenario -Name "handover_verification" -Command {
            $script:handoverBeforeCounts = Get-DbCountsForDog -DogId $script:normalDogId
            $script:handoverBeforePostState = Get-PostDbState -PostId $script:postId
            $handoverImage = $noseFiles[0]
            $response = Invoke-MultipartRequest -Url (Join-Url $script:ApiBaseUrl "adoption-posts/$script:postId/handover-verifications") -Files @(
                [pscustomobject]@{
                    FieldName = "nose_image"
                    Path = $handoverImage.FullName
                    MimeType = Get-ImageMimeType -Path $handoverImage.FullName
                }
            ) -BearerToken $script:ownerToken

            Assert-Status -Response $response -ExpectedStatus 200
            Assert-Equal -Actual $response.Json.expected_dog_id -Expected $script:normalDogId -Name "handover.expected_dog_id"
            Assert-True -Value $response.Json.matched -Name "handover.matched"
            Assert-Equal -Actual $response.Json.decision -Expected "MATCHED" -Name "handover.decision"
            Assert-Equal -Actual $response.Json.dimension -Expected $script:ExpectedVectorDimension -Name "handover.dimension"
            Assert-NotNullOrEmpty -Value $response.Json.score_breakdown -Name "handover.score_breakdown"
            Assert-NotContainsProperty -Object $response.Json -Name "nose_image_url" -Context "handover response"
            Assert-NotContainsProperty -Object $response.Json -Name "author_user_id" -Context "handover response"
            Assert-NotContainsProperty -Object $response.Json -Name "payload" -Context "handover response"
            Assert-NotContainsProperty -Object $response.Json -Name "vector" -Context "handover response"

            $afterCounts = Get-DbCountsForDog -DogId $script:normalDogId
            $afterPostState = Get-PostDbState -PostId $script:postId
            Assert-Equal -Actual $afterCounts.nose_images -Expected $script:handoverBeforeCounts.nose_images -Name "handover dog_images side effect"
            Assert-Equal -Actual $afterCounts.verification_logs -Expected $script:handoverBeforeCounts.verification_logs -Name "handover verification_logs side effect"
            Assert-Equal -Actual $afterPostState.status -Expected $script:handoverBeforePostState.status -Name "handover post status side effect"
            Assert-Equal -Actual $afterCounts.dog_status -Expected $script:handoverBeforeCounts.dog_status -Name "handover dog status side effect"
            $script:RunData.counts["handover_created_dog_images"] = $afterCounts.nose_images - $script:handoverBeforeCounts.nose_images
            $script:RunData.counts["handover_created_verification_logs"] = $afterCounts.verification_logs - $script:handoverBeforeCounts.verification_logs
            $script:RunData.counts["handover_post_status_unchanged"] = ($afterPostState.status -eq $script:handoverBeforePostState.status)
            $script:RunData.counts["handover_dog_status_unchanged"] = ($afterCounts.dog_status -eq $script:handoverBeforeCounts.dog_status)
        }
    }

    if ($SkipAdoptionCompletionCase) {
        Set-ScenarioResult -Name "adoption_completion" -Status "SKIP" -Note "Skipped by -SkipAdoptionCompletionCase."
        Set-ScenarioResult -Name "my_adopted_dogs" -Status "SKIP" -Note "Skipped because adoption completion was skipped."
    } else {
        Invoke-Scenario -Name "adoption_completion" -Command {
            $body = @{
                status = "COMPLETED"
                adopter_user_id = [long]$script:adopterUserId
            }
            $response = Invoke-HttpRequest -Method "PATCH" -Url (Join-Url $script:ApiBaseUrl "adoption-posts/$script:postId/status") -BodyObject $body -BearerToken $script:ownerToken
            Assert-Status -Response $response -ExpectedStatus 200
            Assert-Equal -Actual $response.Json.status -Expected "COMPLETED" -Name "completion.status"
            Assert-Equal -Actual $response.Json.adopter_user_id -Expected $script:adopterUserId -Name "completion.adopter_user_id"
            Assert-NotNullOrEmpty -Value $response.Json.adopted_at -Name "completion.adopted_at"

            $postState = Get-PostDbState -PostId $script:postId
            $dogCounts = Get-DbCountsForDog -DogId $script:normalDogId
            Assert-Equal -Actual $postState.status -Expected "COMPLETED" -Name "DB adoption_posts.status"
            Assert-Equal -Actual $postState.adopter_user_id -Expected $script:adopterUserId -Name "DB adoption_posts.adopter_user_id"
            Assert-Equal -Actual $postState.adopted_at_present -Expected 1 -Name "DB adoption_posts.adopted_at"
            Assert-Equal -Actual $dogCounts.dog_status -Expected "ADOPTED" -Name "DB dogs.status"
            Assert-Equal -Actual $dogCounts.owner_user_id -Expected $script:ownerUserId -Name "DB dogs.owner_user_id unchanged"
            $script:RunData.counts["adoption_posts_status"] = $postState.status
            $script:RunData.counts["adoption_posts_adopter_user_id_matches"] = ($postState.adopter_user_id -eq $script:adopterUserId)
            $script:RunData.counts["adoption_posts_adopted_at_present"] = ([int]$postState.adopted_at_present -eq 1)
            $script:RunData.counts["dogs_status_after_completion"] = $dogCounts.dog_status
            $script:RunData.counts["dogs_owner_user_id_unchanged"] = ($dogCounts.owner_user_id -eq $script:ownerUserId)
        }

        Invoke-Scenario -Name "my_adopted_dogs" -Command {
            $response = Invoke-HttpRequest -Method "GET" -Url (Join-Url $script:ApiBaseUrl "dogs/adopted/me?page=0&size=50") -BearerToken $script:adopterToken
            Assert-Status -Response $response -ExpectedStatus 200
            $item = Find-ItemByProperty -Items $response.Json.items -Property "dog_id" -Expected $script:normalDogId
            Assert-NotNullOrEmpty -Value $item -Name "completed dog in adopted list"
            Assert-Equal -Actual $item.post_id -Expected $script:postId -Name "adopted list post_id"
            Assert-NotContainsProperty -Object $item -Name "nose_image_url" -Context "adopted dog list item"
            Assert-NotContainsProperty -Object $item -Name "author_user_id" -Context "adopted dog list item"
            Assert-NotContainsProperty -Object $item -Name "adopter_user_id" -Context "adopted dog list item"
            Assert-NotNullOrEmpty -Value $item.profile_image_url -Name "adopted list profile_image_url"
            Assert-NotNullOrEmpty -Value $item.adopted_at -Name "adopted list adopted_at"
        }
    }

    Invoke-Scenario -Name "file_serving" -Command {
        Assert-NotNullOrEmpty -Value $script:profileImageUrl -Name "profile_image_url"
        $profileUrl = Get-FileUrl -MaybeRelativeUrl $script:profileImageUrl
        $profileResponse = Invoke-HttpRequest -Method "GET" -Url $profileUrl
        Assert-Status -Response $profileResponse -ExpectedStatus 200
        $script:RunData.counts["profile_image_file_serving_http_status"] = $profileResponse.StatusCode

        if (-not [string]::IsNullOrWhiteSpace($script:ownerNoseImageUrl)) {
            $noseUrl = Get-FileUrl -MaybeRelativeUrl $script:ownerNoseImageUrl
            $noseResponse = Invoke-HttpRequest -Method "GET" -Url $noseUrl
            Assert-Status -Response $noseResponse -ExpectedStatus 200
            $script:RunData.counts["owner_nose_image_file_serving_http_status"] = $noseResponse.StatusCode
        }
    }

    if ($RunReconciliation) {
        Invoke-Scenario -Name "reconciliation" -Command {
            Invoke-Reconciliation
        }
    } else {
        Set-ScenarioResult -Name "reconciliation" -Status "SKIP" -Note "Skipped with -RunReconciliation:`$false."
        $script:RunData.reconciliation = [ordered]@{
            consistent = $null
            missing_in_qdrant_count = $null
            orphan_in_qdrant_count = $null
            payload_mismatch_count = $null
            output_json_path = ""
        }
    }

    Add-ValidationCommand -Command "pwsh ./scripts/check-qdrant-reference-consistency.ps1 -FailOnDrift -OutputPath <local-output-json>" -Result $script:RunData.scenarios["reconciliation"]

    if ($WriteEvidence) {
        Write-EvidenceJson
        Write-EvidenceMarkdown
        Write-Host ""
        Write-Host "Wrote sanitized evidence:"
        Write-Host "  $script:EvidenceMarkdownPath"
        Write-Host "  $(Resolve-RepoPath $SummaryPath)"
    }

    Write-Host ""
    Write-Host "SUBMISSION REAL-MODEL E2E PASSED"
    exit 0
} catch {
    $message = $_.Exception.Message
    Write-Error $message
    if ($message.StartsWith("ASSERT:")) {
        exit 1
    }
    exit 2
} finally {
    if ($script:StartedCompose -and -not $KeepRuntime) {
        try {
            Invoke-DockerCompose -Arguments @("down", "--remove-orphans") -AllowFailure | Out-Null
        } catch {
            Write-Warning "Compose cleanup failed: $($_.Exception.Message)"
        }
    }
}
