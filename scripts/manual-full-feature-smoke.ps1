#Requires -Version 7.0
<#
.SYNOPSIS
Runs a manual full-feature PetNose smoke against a local/dev runtime.

.DESCRIPTION
This script walks through signup, profile/password flows, dog registration,
adoption post creation, likes, optional Firebase chat, handover verification,
adoption completion, adopted dog query, file serving, and optional Qdrant/MySQL
reconciliation.

It writes only sanitized summaries when -WriteEvidence is used. Raw passwords,
JWTs, reset tokens, Firebase tokens, FCM tokens, service account details, raw
images, raw vectors, and full Qdrant payloads are not written to evidence.

.EXAMPLE
pwsh ./scripts/manual-full-feature-smoke.ps1 -Help

.EXAMPLE
pwsh ./scripts/manual-full-feature-smoke.ps1 `
  -NoseImageDir "C:\Users\jaesung\Desktop\dog_nose\ddubi" `
  -PasswordResetMode skip `
  -FirebaseMode auto `
  -RunReconciliation `
  -WriteEvidence
#>

[CmdletBinding()]
param(
    [string]$BaseUrl = "http://localhost/api",
    [string]$RootUrl = "http://localhost",
    [string]$QdrantUrl = "http://localhost:6333",
    [string]$PythonEmbedUrl = "http://localhost:8000",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$NoseImageDir = "",

    [ValidateSet("auto", "jpg", "jpeg", "png")]
    [string]$NoseImageExtension = "auto",

    [ValidateRange(1, 5)]
    [int]$RegisterNoseImageCount = 5,

    [ValidateRange(1, 99)]
    [int]$HandoverImageIndex = 6,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$OwnerProfileImagePath = "",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$PostProfileImagePath = "",

    [ValidateSet("skip", "dev-exposed", "email")]
    [string]$PasswordResetMode = "skip",

    [ValidateSet("skip", "disabled", "enabled", "auto")]
    [string]$FirebaseMode = "auto",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$FcmToken = "",

    [switch]$RunReconciliation = $true,
    [switch]$WriteEvidence,

    [string]$OutputDir = "docs/ops-evidence/manual-full-feature-smoke-local",
    [string]$SummaryPath = "docs/ops-evidence/manual-full-feature-smoke-local/summary.json",
    [switch]$PrintApiTranscript,
    [switch]$WriteApiTranscript,
    [string]$ApiTranscriptPath = "docs/ops-evidence/manual-full-feature-smoke-local/api-transcript.md",
    [string]$ApiTranscriptJsonPath = "docs/ops-evidence/manual-full-feature-smoke-local/api-transcript.json",
    [ValidateSet("summary", "body", "full")]
    [string]$ApiTranscriptDetail = "body",
    [int]$MaxTranscriptBodyChars = 12000,
    [switch]$ShowFixtureIds,

    [switch]$StopOnOptionalFailure,
    [switch]$AllowAmbiguousHandover,
    [switch]$ResetRuntimeData,
    [switch]$StartRuntime,
    [switch]$StopRuntimeAfter,

    [string]$QdrantCollection = "dog_nose_embeddings_real_v2",
    [int]$ExpectedVectorDimension = 2048,
    [string]$ExpectedDistance = "Cosine",

    [string]$EnvFile = "infra/docker/.env",
    [string[]]$ComposeFile = @("infra/docker/compose.yaml", "infra/docker/compose.dev.yaml"),
    [AllowNull()]
    [AllowEmptyString()]
    [string]$ComposeProjectName = "petnose",
    [string]$MysqlService = "mysql",
    [AllowNull()]
    [AllowEmptyString()]
    [string]$MysqlDatabase = "",
    [AllowNull()]
    [AllowEmptyString()]
    [string]$MysqlUser = "",
    [AllowNull()]
    [AllowEmptyString()]
    [string]$MysqlPassword = "",

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Expand-ComposeFileList {
    param([string[]]$Values)

    $expanded = @()
    foreach ($value in @($Values)) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            continue
        }
        foreach ($part in ([string]$value).Split([char]";", [System.StringSplitOptions]::RemoveEmptyEntries)) {
            $trimmed = $part.Trim()
            if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
                $expanded += $trimmed
            }
        }
    }
    return $expanded
}

$ComposeFile = @(Expand-ComposeFileList -Values $ComposeFile)

$script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$script:StartedAt = (Get-Date).ToUniversalTime()
$script:SecretValues = New-Object 'System.Collections.Generic.List[string]'
$script:RegistrationImages = @()
$script:HandoverImage = ""
$script:OwnerProfileImage = ""
$script:PostProfileImage = ""
$script:OwnerEmail = ""
$script:OwnerPassword = ""
$script:OwnerToken = ""
$script:OwnerUserId = $null
$script:OwnerProfileImageUrl = ""
$script:AdopterEmail = ""
$script:AdopterPassword = ""
$script:AdopterToken = ""
$script:AdopterUserId = $null
$script:DogId = ""
$script:PostId = $null
$script:OwnerNoseImageUrl = ""
$script:PostProfileImageUrl = ""
$script:ChatRoomId = ""
$script:ApiTranscript = New-Object 'System.Collections.Generic.List[object]'
$script:ApiTranscriptCounter = 0
$script:CurrentScenarioName = ""
$script:CurrentApiRecord = $null
$script:RuntimeStartedByScript = $false

$script:Summary = [ordered]@{
    checked_at = $script:StartedAt.ToString("o")
    base_url = $BaseUrl
    root_url = $RootUrl
    qdrant_url = $QdrantUrl
    python_embed_url = $PythonEmbedUrl
    qdrant_collection = $QdrantCollection
    runtime_health = [ordered]@{}
    fixture = [ordered]@{}
    modes = [ordered]@{
        password_reset = $PasswordResetMode
        firebase = $FirebaseMode
        run_reconciliation = [bool]$RunReconciliation
        allow_ambiguous_handover = [bool]$AllowAmbiguousHandover
        compose_project_name = if ([string]::IsNullOrWhiteSpace($ComposeProjectName)) { "default" } else { $ComposeProjectName }
        api_transcript_detail = $ApiTranscriptDetail
        show_fixture_ids = [bool]$ShowFixtureIds
        reset_runtime_data = [bool]$ResetRuntimeData
        start_runtime = [bool]$StartRuntime
        stop_runtime_after = [bool]$StopRuntimeAfter
    }
    scenarios = [ordered]@{}
    markers = [ordered]@{}
    counts = [ordered]@{}
    reconciliation = [ordered]@{}
    validation_notes = @()
    redaction = [ordered]@{
        access_token = "redacted"
        password = "redacted"
        reset_token = "redacted"
        firebase_custom_token = "redacted"
        fcm_token = "redacted"
        service_account = "not recorded"
        raw_images = "not recorded"
        raw_vectors = "not recorded"
        full_qdrant_payload = "not recorded"
    }
}

function Show-Usage {
    @"
Usage:
  pwsh ./scripts/manual-full-feature-smoke.ps1 -NoseImageDir <dir> [options]

Required:
  -NoseImageDir <dir>            Directory containing indexed nose images 1..6

Defaults:
  -BaseUrl                       http://localhost/api
  -RootUrl                       http://localhost
  -QdrantUrl                     http://localhost:6333
  -PythonEmbedUrl                http://localhost:8000
  -NoseImageExtension            auto
  -RegisterNoseImageCount        5
  -HandoverImageIndex            6
  -PasswordResetMode             skip
  -FirebaseMode                  auto
  -RunReconciliation             true
  -OutputDir                     docs/ops-evidence/manual-full-feature-smoke-local
  -SummaryPath                   docs/ops-evidence/manual-full-feature-smoke-local/summary.json
  -ApiTranscriptPath             docs/ops-evidence/manual-full-feature-smoke-local/api-transcript.md
  -ApiTranscriptJsonPath         docs/ops-evidence/manual-full-feature-smoke-local/api-transcript.json
  -ApiTranscriptDetail           body
  -MaxTranscriptBodyChars        12000
  -ComposeProjectName            petnose

Modes:
  -PasswordResetMode skip|dev-exposed|email
  -FirebaseMode skip|disabled|enabled|auto

Evidence:
  -WriteEvidence                 Write sanitized summary.json and summary.md
  -PrintApiTranscript            Print sanitized API transcript to console
  -WriteApiTranscript            Write sanitized API transcript markdown/json
  -ApiTranscriptDetail summary|body|full
  -ShowFixtureIds                Include fixture user/dog/post IDs in transcript

Optional behavior:
  -StopOnOptionalFailure         Treat optional Firebase/DB side-effect failures as fatal
  -AllowAmbiguousHandover        Accept AMBIGUOUS as warning-pass for handover
  -ResetRuntimeData              Run docker compose down -v before the smoke
  -StartRuntime                  Run docker compose up -d --build before the smoke
  -StopRuntimeAfter              Run docker compose down -v after the smoke
  -RunReconciliation:`$false      Skip Qdrant/MySQL reconciliation

Exit codes:
  0 success
  1 required scenario failure
  2 configuration/runtime preflight failure
"@
}

if ($Help) {
    Show-Usage
    exit 0
}

function Resolve-RepoPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return (Join-Path $script:RepoRoot $Path)
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

function Add-Secret {
    param([AllowNull()][AllowEmptyString()][string]$Value)

    if (-not [string]::IsNullOrWhiteSpace($Value) -and -not $script:SecretValues.Contains($Value)) {
        $script:SecretValues.Add($Value) | Out-Null
    }
}

function Redact-Text {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        return ""
    }
    $result = [string]$Text
    foreach ($secret in $script:SecretValues) {
        if (-not [string]::IsNullOrWhiteSpace($secret)) {
            $result = $result.Replace($secret, "[REDACTED]")
        }
    }
    return $result
}

function Test-SensitiveName {
    param([Parameter(Mandatory = $true)][string]$Name)

    $normalized = $Name.ToLowerInvariant()
    if ($normalized -match "(password|token|authorization|credential|secret)") {
        return $true
    }
    $sensitiveNames = @(
        "access_token",
        "authorization",
        "bearer",
        "reset_token",
        "firebase_custom_token",
        "fcm_token",
        "password",
        "current_password",
        "new_password",
        "mysql_password",
        "mail_password",
        "credential",
        "credentials",
        "service_account",
        "service_account_json",
        "secret"
    )
    return $sensitiveNames -contains $normalized
}

function Test-FixtureIdName {
    param([Parameter(Mandatory = $true)][string]$Name)

    $normalized = $Name.ToLowerInvariant().Replace(".", "_")
    return $normalized -match "(^|_)(user_id|owner_user_id|adopter_user_id|author_user_id|inquirer_user_id|dog_id|expected_dog_id|post_id|adoption_post_id|room_id|message_id)$"
}

function Redact-FixtureIdsInText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    $result = Redact-Text $Text
    if ($ShowFixtureIds) {
        return $result
    }

    foreach ($id in @($script:DogId, $script:ChatRoomId)) {
        $idText = [string]$id
        if (-not [string]::IsNullOrWhiteSpace($idText) -and $idText.Length -ge 8) {
            $result = $result.Replace($idText, "[REDACTED_FIXTURE_ID]")
        }
    }
    $result = $result -replace '(?i)(/dogs/)(?!adopted(?:/|$)|me(?:/|$)|register(?:/|$))[^/?\s"]+', '$1[REDACTED_FIXTURE_ID]'
    $result = $result -replace '(?i)(/adoption-posts/)(?:\d+|[0-9a-f-]{8,})', '$1[REDACTED_FIXTURE_ID]'
    $result = $result -replace '(?i)(/chat/rooms/)[^/?\s"]+', '$1[REDACTED_FIXTURE_ID]'
    $result = $result -replace '(?i)(/files/users/)(?:\d+|[0-9a-f-]{8,})', '$1[REDACTED_FIXTURE_ID]'
    $result = $result -replace '(?i)(/files/dogs/)(?:\d+|[0-9a-f-]{8,})', '$1[REDACTED_FIXTURE_ID]'
    $result = $result -replace '(?i)([?&](?:user_id|owner_user_id|adopter_user_id|author_user_id|inquirer_user_id|dog_id|expected_dog_id|post_id|room_id|message_id)=)[^&\s"]+', '$1[REDACTED_FIXTURE_ID]'
    $result = $result -replace '(?i)("(?:user_id|owner_user_id|adopter_user_id|author_user_id|inquirer_user_id|dog_id|expected_dog_id|post_id|room_id|message_id)"\s*:\s*)"[^"]+"', '$1"[REDACTED_FIXTURE_ID]"'
    $result = $result -replace '(?i)("(?:user_id|owner_user_id|adopter_user_id|author_user_id|inquirer_user_id|dog_id|expected_dog_id|post_id|room_id|message_id)"\s*:\s*)\d+', '$1"[REDACTED_FIXTURE_ID]"'
    return $result
}

function ConvertTo-SafeEvidenceValue {
    param(
        [AllowNull()][object]$Value,
        [string]$Name = "",
        [int]$Depth = 0
    )

    if (-not [string]::IsNullOrWhiteSpace($Name) -and (Test-SensitiveName -Name $Name)) {
        if ($Value -is [string] -or $null -eq $Value) {
            return "[REDACTED]"
        }
        return $Value
    }
    if (-not [string]::IsNullOrWhiteSpace($Name) -and $Name -match "(?i)^(vector|payload)$") {
        return "[OMITTED]"
    }
    if ($null -eq $Value) {
        return $null
    }
    if ($Depth -gt 12) {
        return "[MAX_DEPTH]"
    }
    if ($Value -is [string]) {
        return Redact-Text $Value
    }
    if ($Value.GetType().IsPrimitive -or $Value -is [decimal] -or $Value -is [datetime]) {
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $safe = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $safe[[string]$key] = ConvertTo-SafeEvidenceValue -Value $Value[$key] -Name ([string]$key) -Depth ($Depth + 1)
        }
        return $safe
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) {
            $items += ConvertTo-SafeEvidenceValue -Value $item -Depth ($Depth + 1)
        }
        return $items
    }

    $object = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        if ($property.MemberType -in @(
                [System.Management.Automation.PSMemberTypes]::NoteProperty,
                [System.Management.Automation.PSMemberTypes]::Property
            )) {
            $object[$property.Name] = ConvertTo-SafeEvidenceValue -Value $property.Value -Name $property.Name -Depth ($Depth + 1)
        }
    }
    return $object
}

function ConvertTo-TranscriptSafeValue {
    param(
        [AllowNull()][object]$Value,
        [string]$Name = "",
        [int]$Depth = 0
    )

    if (-not [string]::IsNullOrWhiteSpace($Name) -and (Test-SensitiveName -Name $Name)) {
        if ($Value -is [string] -or $null -eq $Value) {
            return "[REDACTED]"
        }
        return $Value
    }
    if (-not $ShowFixtureIds -and -not [string]::IsNullOrWhiteSpace($Name) -and (Test-FixtureIdName -Name $Name)) {
        if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
            return $null
        }
        if ([string]$Value -in @("absent", "present", "non-empty")) {
            return $Value
        }
        return "[REDACTED_FIXTURE_ID]"
    }
    if (-not [string]::IsNullOrWhiteSpace($Name) -and $Name -match "(?i)^(vector|payload)$") {
        return "[OMITTED]"
    }
    if ($null -eq $Value) {
        return $null
    }
    if ($Depth -gt 12) {
        return "[MAX_DEPTH]"
    }
    if ($Value -is [string]) {
        return Redact-FixtureIdsInText $Value
    }
    if ($Value.GetType().IsPrimitive -or $Value -is [decimal] -or $Value -is [datetime]) {
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $safe = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $safe[[string]$key] = ConvertTo-TranscriptSafeValue -Value $Value[$key] -Name ([string]$key) -Depth ($Depth + 1)
        }
        return $safe
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) {
            $items += ConvertTo-TranscriptSafeValue -Value $item -Depth ($Depth + 1)
        }
        return $items
    }

    $object = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        if ($property.MemberType -in @(
                [System.Management.Automation.PSMemberTypes]::NoteProperty,
                [System.Management.Automation.PSMemberTypes]::Property
            )) {
            $object[$property.Name] = ConvertTo-TranscriptSafeValue -Value $property.Value -Name $property.Name -Depth ($Depth + 1)
        }
    }
    return $object
}

function ConvertTo-JsonText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }
    return ($Value | ConvertTo-Json -Depth 80)
}

function Limit-TranscriptText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    $safeText = Redact-FixtureIdsInText $Text
    if ($MaxTranscriptBodyChars -gt 0 -and $safeText.Length -gt $MaxTranscriptBodyChars) {
        return "$($safeText.Substring(0, $MaxTranscriptBodyChars))`n[TRUNCATED $($safeText.Length - $MaxTranscriptBodyChars) chars]"
    }
    return $safeText
}

function ConvertTo-TranscriptJsonText {
    param([AllowNull()][object]$Value)

    return Limit-TranscriptText (ConvertTo-JsonText (ConvertTo-TranscriptSafeValue -Value $Value))
}

function ConvertTo-TranscriptResponseBody {
    param(
        [AllowNull()][object]$Json,
        [AllowNull()][string]$BodyText
    )

    if ($null -ne $Json) {
        return ConvertTo-TranscriptSafeValue -Value $Json
    }
    return Limit-TranscriptText $BodyText
}

function Test-OmitRawResponseBody {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [AllowNull()][AllowEmptyString()][string]$ContentType = ""
    )

    if ($ContentType -match "(?i)^(image/|application/octet-stream)") {
        return $true
    }
    try {
        $uri = [System.Uri]$Url
        if ($uri.AbsolutePath -match "(?i)^/files/") {
            return $true
        }
    } catch {
        if ($Url -match "(?i)/files/") {
            return $true
        }
    }
    return $false
}

function Get-TranscriptPath {
    param([Parameter(Mandatory = $true)][string]$Url)

    $safeUrl = Redact-FixtureIdsInText $Url
    try {
        $uri = [System.Uri]$safeUrl
        return "$($uri.AbsolutePath)$($uri.Query)"
    } catch {
        return $safeUrl
    }
}

function New-TranscriptCurl {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [AllowNull()][AllowEmptyString()][string]$ContentType = "",
        [AllowNull()][object]$BodyObject = $null,
        [AllowNull()][hashtable]$Fields = $null,
        [AllowNull()][object[]]$Files = @(),
        [bool]$Authenticated = $false
    )

    if ($ApiTranscriptDetail -ne "full") {
        return $null
    }

    $parts = New-Object 'System.Collections.Generic.List[string]'
    $parts.Add("curl") | Out-Null
    $parts.Add("-X") | Out-Null
    $parts.Add($Method.ToUpperInvariant()) | Out-Null
    $parts.Add("'$(Redact-FixtureIdsInText $Url)'") | Out-Null
    $parts.Add("-H 'Accept: application/json'") | Out-Null
    if ($Authenticated) {
        $parts.Add("-H 'Authorization: Bearer [REDACTED]'") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($ContentType)) {
        $parts.Add("-H 'Content-Type: $ContentType'") | Out-Null
    }
    if ($null -ne $BodyObject) {
        $json = (ConvertTo-TranscriptJsonText -Value $BodyObject).Replace("'", "'\''")
        $parts.Add("--data '$json'") | Out-Null
    }
    if ($null -ne $Fields) {
        foreach ($key in ($Fields.Keys | Sort-Object)) {
            if ($null -eq $Fields[$key]) {
                continue
            }
            $value = ConvertTo-TranscriptSafeValue -Value $Fields[$key] -Name ([string]$key)
            $parts.Add("-F '$key=$value'") | Out-Null
        }
    }
    foreach ($file in @($Files)) {
        $path = [string](Get-PropertyValue -Object $file -Name "Path")
        $fieldName = [string](Get-PropertyValue -Object $file -Name "FieldName")
        $parts.Add("-F '$fieldName=@$([System.IO.Path]::GetFileName($path))'") | Out-Null
    }
    return ($parts -join " ")
}

function New-ApiTranscriptRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [AllowNull()][AllowEmptyString()][string]$ContentType = "",
        [AllowNull()][object]$RequestBody = $null,
        [AllowNull()][hashtable]$Fields = $null,
        [AllowNull()][object[]]$Files = @(),
        [bool]$Authenticated = $false
    )

    $script:ApiTranscriptCounter += 1
    $request = [ordered]@{
        content_type = if ([string]::IsNullOrWhiteSpace($ContentType)) { $null } else { $ContentType }
        body = $null
        fields = $null
        files = @()
        curl = $null
    }
    if ($ApiTranscriptDetail -in @("body", "full")) {
        if ($null -ne $RequestBody) {
            $request["body"] = ConvertTo-TranscriptSafeValue -Value $RequestBody
        }
        if ($null -ne $Fields) {
            $safeFields = [ordered]@{}
            foreach ($key in ($Fields.Keys | Sort-Object)) {
                $safeFields[[string]$key] = ConvertTo-TranscriptSafeValue -Value $Fields[$key] -Name ([string]$key)
            }
            $request["fields"] = $safeFields
        }
        $safeFiles = @()
        foreach ($file in @($Files)) {
            $path = [string](Get-PropertyValue -Object $file -Name "Path")
            $fieldName = [string](Get-PropertyValue -Object $file -Name "FieldName")
            $mimeType = [string](Get-PropertyValue -Object $file -Name "MimeType")
            if ([string]::IsNullOrWhiteSpace($mimeType)) {
                $mimeType = Get-ImageMimeType -Path $path
            }
            $fileEvidence = Get-FileEvidence -Path $path
            $safeFiles += [ordered]@{
                field = $fieldName
                basename = $fileEvidence.basename
                size_bytes = $fileEvidence.size_bytes
                sha256 = $fileEvidence.sha256
                content_type = $mimeType
            }
        }
        $request["files"] = $safeFiles
    }
    if ($ApiTranscriptDetail -eq "full") {
        $request["curl"] = New-TranscriptCurl -Method $Method -Url $Url -ContentType $ContentType -BodyObject $RequestBody -Fields $Fields -Files $Files -Authenticated $Authenticated
    }

    $record = [ordered]@{
        index = $script:ApiTranscriptCounter
        scenario = if ([string]::IsNullOrWhiteSpace($script:CurrentScenarioName)) { "unscoped" } else { $script:CurrentScenarioName }
        name = "$($Method.ToUpperInvariant()) $(Get-TranscriptPath -Url $Url)"
        method = $Method.ToUpperInvariant()
        url = Redact-FixtureIdsInText $Url
        path = Get-TranscriptPath -Url $Url
        auth = [ordered]@{
            bearer = [bool]$Authenticated
        }
        request = $request
        response = [ordered]@{
            status = $null
            body = $null
        }
        assertions = New-Object 'System.Collections.Generic.List[object]'
        result = "PASS"
        _printed = $false
    }
    $script:ApiTranscript.Add($record) | Out-Null
    $script:CurrentApiRecord = $record
    return $record
}

function Complete-ApiTranscriptResponse {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [AllowNull()][Nullable[int]]$StatusCode = $null,
        [AllowNull()][object]$Json = $null,
        [AllowNull()][string]$BodyText = ""
    )

    $Record["response"]["status"] = $StatusCode
    if ($ApiTranscriptDetail -in @("body", "full")) {
        $Record["response"]["body"] = ConvertTo-TranscriptResponseBody -Json $Json -BodyText $BodyText
    }
}

function Add-ApiAssertion {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()][object]$Expected = $null,
        [AllowNull()][object]$Actual = $null
    )

    if ($null -eq $script:CurrentApiRecord) {
        return
    }

    $assertion = [ordered]@{
        status = $Status
        description = Redact-FixtureIdsInText $Description
        expected = ConvertTo-TranscriptSafeValue -Value $Expected -Name $Description
        actual = ConvertTo-TranscriptSafeValue -Value $Actual -Name $Description
    }
    $script:CurrentApiRecord["assertions"].Add($assertion) | Out-Null
    if ($Status -eq "FAIL") {
        $script:CurrentApiRecord["result"] = "FAIL"
    }
}

function Set-CurrentApiResult {
    param([Parameter(Mandatory = $true)][string]$Result)

    if ($null -ne $script:CurrentApiRecord) {
        $script:CurrentApiRecord["result"] = $Result
    }
}

function ConvertTo-PublicApiTranscriptRecord {
    param([Parameter(Mandatory = $true)][object]$Record)

    $copy = [ordered]@{}
    foreach ($key in $Record.Keys) {
        if (-not ([string]$key).StartsWith("_")) {
            $copy[$key] = $Record[$key]
        }
    }
    return $copy
}

function Get-TranscriptRecordValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.DictionaryEntry]) {
        return Get-TranscriptRecordValue -Object $Object.Value -Name $Name
    }
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-TranscriptRecordItems {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return @()
    }
    if ($Value -is [string]) {
        return @($Value)
    }
    if ($Value -is [System.Collections.IDictionary]) {
        return @($Value)
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) {
            $items += $item
        }
        return $items
    }
    return @($Value)
}

function Format-ApiTranscriptRecord {
    param([Parameter(Mandatory = $true)][object]$Record)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $requestRecord = Get-TranscriptRecordValue -Object $Record -Name "request"
    $responseRecord = Get-TranscriptRecordValue -Object $Record -Name "response"
    $authRecord = Get-TranscriptRecordValue -Object $Record -Name "auth"
    $index = Get-TranscriptRecordValue -Object $Record -Name "index"
    $scenario = Get-TranscriptRecordValue -Object $Record -Name "scenario"
    $result = Get-TranscriptRecordValue -Object $Record -Name "result"
    $method = Get-TranscriptRecordValue -Object $Record -Name "method"
    $path = Get-TranscriptRecordValue -Object $Record -Name "path"
    $authLabel = if (Get-TranscriptRecordValue -Object $authRecord -Name "bearer") { "bearer" } else { "none" }
    $contentTypeValue = Get-TranscriptRecordValue -Object $requestRecord -Name "content_type"
    $contentType = if ($null -ne $contentTypeValue) { $contentTypeValue } else { "none" }
    $status = Get-TranscriptRecordValue -Object $responseRecord -Name "status"
    $lines.Add(("### API {0} - {1}" -f $index, $scenario)) | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add(("- Result: {0}" -f $result)) | Out-Null
    $lines.Add(('- Request: `{0} {1}`' -f $method, $path)) | Out-Null
    $lines.Add(("- Auth: {0}" -f $authLabel)) | Out-Null
    $lines.Add(("- Content-Type: {0}" -f $contentType)) | Out-Null
    $lines.Add(("- Response: {0}" -f $status)) | Out-Null
    if ($ApiTranscriptDetail -in @("body", "full")) {
        $requestBody = Get-TranscriptRecordValue -Object $requestRecord -Name "body"
        $requestFields = Get-TranscriptRecordValue -Object $requestRecord -Name "fields"
        $requestFiles = Get-TranscriptRecordItems -Value (Get-TranscriptRecordValue -Object $requestRecord -Name "files")
        if ($null -ne $requestBody -or $null -ne $requestFields -or @($requestFiles).Count -gt 0) {
            $lines.Add("") | Out-Null
            $lines.Add("Request summary:") | Out-Null
            $lines.Add("") | Out-Null
            $lines.Add('```json') | Out-Null
            $requestSummary = [ordered]@{
                body = $requestBody
                fields = $requestFields
                files = $requestFiles
            }
            $requestSummaryJson = ConvertTo-JsonText -Value $requestSummary
            $lines.Add((Limit-TranscriptText -Text $requestSummaryJson)) | Out-Null
            $lines.Add('```') | Out-Null
        }
        $responseBody = Get-TranscriptRecordValue -Object $responseRecord -Name "body"
        if ($null -ne $responseBody) {
            $lines.Add("") | Out-Null
            $lines.Add("Response body:") | Out-Null
            $lines.Add("") | Out-Null
            $lines.Add('```json') | Out-Null
            $responseBodyJson = ConvertTo-JsonText -Value $responseBody
            $lines.Add((Limit-TranscriptText -Text $responseBodyJson)) | Out-Null
            $lines.Add('```') | Out-Null
        }
    }
    $curl = Get-TranscriptRecordValue -Object $requestRecord -Name "curl"
    if ($ApiTranscriptDetail -eq "full" -and $null -ne $curl) {
        $lines.Add("") | Out-Null
        $lines.Add("Curl example:") | Out-Null
        $lines.Add("") | Out-Null
        $lines.Add('```bash') | Out-Null
        $lines.Add($curl) | Out-Null
        $lines.Add('```') | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("Assertions:") | Out-Null
    $assertions = Get-TranscriptRecordItems -Value (Get-TranscriptRecordValue -Object $Record -Name "assertions")
    foreach ($assertion in $assertions) {
        $assertionStatus = Get-TranscriptRecordValue -Object $assertion -Name "status"
        $assertionDescription = Get-TranscriptRecordValue -Object $assertion -Name "description"
        $assertionExpected = Get-TranscriptRecordValue -Object $assertion -Name "expected"
        $assertionActual = Get-TranscriptRecordValue -Object $assertion -Name "actual"
        $expectedJson = ConvertTo-JsonText -Value $assertionExpected
        $actualJson = ConvertTo-JsonText -Value $assertionActual
        $lines.Add("- ${assertionStatus}: $assertionDescription (expected: $expectedJson; actual: $actualJson)") | Out-Null
    }
    if (@($assertions).Count -eq 0) {
        $lines.Add("- PASS: response captured") | Out-Null
    }
    $lines.Add("") | Out-Null
    return ($lines -join "`n")
}

function Complete-ApiTranscriptScenario {
    param(
        [Parameter(Mandatory = $true)][string]$ScenarioName,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()][string]$Note = ""
    )

    try {
        foreach ($record in $script:ApiTranscript) {
            if ($record["scenario"] -ne $ScenarioName) {
                continue
            }
            $isCurrentRecord = [object]::ReferenceEquals($record, $script:CurrentApiRecord)
            $hasFailedAssertion = @($record["assertions"] | Where-Object {
                    if ($_ -is [System.Collections.IDictionary]) {
                        $_["status"] -eq "FAIL"
                    } else {
                        $_.status -eq "FAIL"
                    }
                }).Count -gt 0
            if ($Status -eq "FAIL" -and $record["result"] -ne "FAIL" -and ($isCurrentRecord -or $hasFailedAssertion)) {
                $record["result"] = "FAIL"
                $record["assertions"].Add([ordered]@{
                    status = "FAIL"
                    description = "scenario completed with failure"
                    expected = "PASS"
                    actual = Redact-FixtureIdsInText $Note
                }) | Out-Null
            } elseif ($record["result"] -eq "") {
                $record["result"] = $Status
            }

            if ($PrintApiTranscript -and -not [bool]$record["_printed"]) {
                Write-Host ""
                Write-Host (Format-ApiTranscriptRecord -Record $record)
                $record["_printed"] = $true
            }
        }
    } catch {
        throw "API transcript completion failed for ${ScenarioName}: $(Redact-Text $_.Exception.Message). $($_.ScriptStackTrace)"
    }
}

function Save-ApiTranscript {
    if (-not $WriteApiTranscript) {
        return
    }

    $records = @()
    foreach ($record in $script:ApiTranscript) {
        $records += ConvertTo-PublicApiTranscriptRecord -Record $record
    }

    $resolvedMarkdownPath = Resolve-RepoPath $ApiTranscriptPath
    $resolvedJsonPath = Resolve-RepoPath $ApiTranscriptJsonPath
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("# Manual Full Feature Smoke API Transcript") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Checked at: $($script:Summary.checked_at)") | Out-Null
    $lines.Add("- Detail: $ApiTranscriptDetail") | Out-Null
    $lines.Add("- Fixture IDs shown: $([bool]$ShowFixtureIds)") | Out-Null
    $lines.Add("- Redaction: JWT/password/reset/Firebase/FCM tokens, raw images, raw vectors, and full Qdrant payloads are not recorded.") | Out-Null
    $lines.Add("") | Out-Null
    foreach ($record in $records) {
        $lines.Add((Format-ApiTranscriptRecord -Record $record)) | Out-Null
    }

    Write-Utf8NoBom -Path $resolvedMarkdownPath -Text (($lines -join "`n") + "`n")
    Write-Utf8NoBom -Path $resolvedJsonPath -Text ((ConvertTo-JsonText -Value $records) + "`n")
    Write-Host "Wrote sanitized API transcript:"
    Write-Host "  $resolvedMarkdownPath"
    Write-Host "  $resolvedJsonPath"
}

function Get-PropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
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
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }
    return ($Object.PSObject.Properties.Name -contains $Name)
}

function Test-ContainsPropertyDeep {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$Depth = 0
    )

    if ($null -eq $Object -or $Depth -gt 20) {
        return $false
    }
    if ($Object -is [string] -or $Object.GetType().IsPrimitive -or $Object -is [decimal] -or $Object -is [datetime]) {
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
    if ($Object -is [System.Collections.IEnumerable]) {
        foreach ($item in $Object) {
            if (Test-ContainsPropertyDeep -Object $item -Name $Name -Depth ($Depth + 1)) {
                return $true
            }
        }
        return $false
    }
    foreach ($property in $Object.PSObject.Properties) {
        if ($property.Name -eq $Name) {
            return $true
        }
        if (Test-ContainsPropertyDeep -Object $property.Value -Name $Name -Depth ($Depth + 1)) {
            return $true
        }
    }
    return $false
}

function Fail-Assert {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw "ASSERT: $Message"
}

function Fail-Config {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw "CONFIG: $Message"
}

function Assert-Status {
    param(
        [Parameter(Mandatory = $true)][object]$Response,
        [Parameter(Mandatory = $true)][int]$ExpectedStatus
    )

    if ([int]$Response.StatusCode -ne $ExpectedStatus) {
        Add-ApiAssertion -Status "FAIL" -Description "HTTP status for $($Response.Method) $($Response.Url)" -Expected $ExpectedStatus -Actual ([int]$Response.StatusCode)
        $safeBody = ConvertTo-SanitizedBodyText -BodyText $Response.BodyText
        Fail-Assert "Expected HTTP $ExpectedStatus for $($Response.Method) $($Response.Url), actual $($Response.StatusCode). Body: $safeBody"
    }
    Add-ApiAssertion -Status "PASS" -Description "HTTP status for $($Response.Method) $($Response.Url)" -Expected $ExpectedStatus -Actual ([int]$Response.StatusCode)
}

function Assert-StatusIn {
    param(
        [Parameter(Mandatory = $true)][object]$Response,
        [Parameter(Mandatory = $true)][int[]]$ExpectedStatuses,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not ($ExpectedStatuses -contains [int]$Response.StatusCode)) {
        Add-ApiAssertion -Status "FAIL" -Description "$Name HTTP status" -Expected ($ExpectedStatuses -join ",") -Actual ([int]$Response.StatusCode)
        $safeBody = ConvertTo-SanitizedBodyText -BodyText $Response.BodyText
        Fail-Assert "$Name expected HTTP status in [$($ExpectedStatuses -join ', ')], actual $($Response.StatusCode). Body: $safeBody"
    }
    Add-ApiAssertion -Status "PASS" -Description "$Name HTTP status" -Expected ($ExpectedStatuses -join ",") -Actual ([int]$Response.StatusCode)
}

function Assert-Equal {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ("$Actual" -ne "$Expected") {
        Add-ApiAssertion -Status "FAIL" -Description $Name -Expected $Expected -Actual $Actual
        Fail-Assert "$Name mismatch. Expected '$Expected', actual '$Actual'."
    }
    Add-ApiAssertion -Status "PASS" -Description $Name -Expected $Expected -Actual $Actual
}

function Assert-True {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -ne $true) {
        Add-ApiAssertion -Status "FAIL" -Description $Name -Expected $true -Actual $Value
        Fail-Assert "$Name must be true. Actual: $Value"
    }
    Add-ApiAssertion -Status "PASS" -Description $Name -Expected $true -Actual $Value
}

function Assert-False {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -ne $false) {
        Add-ApiAssertion -Status "FAIL" -Description $Name -Expected $false -Actual $Value
        Fail-Assert "$Name must be false. Actual: $Value"
    }
    Add-ApiAssertion -Status "PASS" -Description $Name -Expected $false -Actual $Value
}

function Assert-Null {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -ne $Value) {
        Add-ApiAssertion -Status "FAIL" -Description $Name -Expected $null -Actual $Value
        Fail-Assert "$Name must be null. Actual: $Value"
    }
    Add-ApiAssertion -Status "PASS" -Description $Name -Expected $null -Actual $Value
}

function Assert-NotNullOrEmpty {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value) {
        Add-ApiAssertion -Status "FAIL" -Description $Name -Expected "present" -Actual $null
        Fail-Assert "$Name must be present."
    }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
        Add-ApiAssertion -Status "FAIL" -Description $Name -Expected "non-empty" -Actual $Value
        Fail-Assert "$Name must be non-empty."
    }
    Add-ApiAssertion -Status "PASS" -Description $Name -Expected "non-empty" -Actual $Value
}

function Assert-Count {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][int]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $count = @($Value).Count
    if ($count -ne $Expected) {
        Add-ApiAssertion -Status "FAIL" -Description $Name -Expected $Expected -Actual $count
        Fail-Assert "$Name count mismatch. Expected $Expected, actual $count."
    }
    Add-ApiAssertion -Status "PASS" -Description $Name -Expected $Expected -Actual $count
}

function Assert-NotHasProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if (Test-ContainsPropertyDeep -Object $Object -Name $Name) {
        Add-ApiAssertion -Status "FAIL" -Description "$Context hides $Name" -Expected "absent" -Actual "present"
        Fail-Assert "$Context must not expose '$Name'."
    }
    Add-ApiAssertion -Status "PASS" -Description "$Context hides $Name" -Expected "absent" -Actual "absent"
}

function Find-ItemByProperty {
    param(
        [AllowNull()][object]$Items,
        [Parameter(Mandatory = $true)][string]$Property,
        [Parameter(Mandatory = $true)][object]$Expected
    )

    foreach ($item in @($Items)) {
        if ("$(Get-PropertyValue -Object $item -Name $Property)" -eq "$Expected") {
            return $item
        }
    }
    return $null
}

function ConvertTo-SanitizedBodyText {
    param([AllowNull()][string]$BodyText)

    if ([string]::IsNullOrWhiteSpace($BodyText)) {
        return ""
    }
    try {
        $json = $BodyText | ConvertFrom-Json
        return ConvertTo-JsonText (ConvertTo-SafeEvidenceValue -Value $json)
    } catch {
        return Redact-Text $BodyText
    }
}

function Invoke-Json {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [AllowNull()][object]$BodyObject = $null,
        [AllowNull()][AllowEmptyString()][string]$BearerToken = ""
    )

    $authenticated = -not [string]::IsNullOrWhiteSpace($BearerToken)
    $contentType = if ($null -ne $BodyObject) { "application/json" } else { "" }
    $transcriptRecord = New-ApiTranscriptRecord -Method $Method -Url $Url -ContentType $contentType -RequestBody $BodyObject -Authenticated $authenticated

    $headers = @{
        Accept = "application/json"
    }
    if ($authenticated) {
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
        Complete-ApiTranscriptResponse -Record $transcriptRecord -StatusCode $null -BodyText ""
        Add-ApiAssertion -Status "FAIL" -Description "HTTP request returned a response" -Expected "response" -Actual (Redact-FixtureIdsInText $_.Exception.Message)
        throw "HTTP request failed before response: $Method $Url. $(Redact-Text $_.Exception.Message)"
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

    $responseContentType = ""
    if ($response.Headers.ContainsKey("Content-Type")) {
        $responseContentType = [string]$response.Headers["Content-Type"]
    }
    $transcriptJson = $json
    $transcriptBodyText = $bodyText
    if (Test-OmitRawResponseBody -Url $Url -ContentType $responseContentType) {
        $transcriptJson = $null
        $transcriptBodyText = "[OMITTED_RAW_IMAGE_CONTENT]"
    }
    Complete-ApiTranscriptResponse -Record $transcriptRecord -StatusCode ([int]$response.StatusCode) -Json $transcriptJson -BodyText $transcriptBodyText

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

function Invoke-Multipart {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
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
    $authenticated = -not [string]::IsNullOrWhiteSpace($BearerToken)
    $transcriptRecord = New-ApiTranscriptRecord -Method $Method -Url $Url -ContentType "multipart/form-data" -Fields $Fields -Files $Files -Authenticated $authenticated

    try {
        foreach ($key in $Fields.Keys) {
            if ($null -eq $Fields[$key]) {
                continue
            }
            $fieldContent = [System.Net.Http.StringContent]::new([string]$Fields[$key], [System.Text.Encoding]::UTF8)
            $content.Add($fieldContent, [string]$key)
        }

        foreach ($file in $Files) {
            $path = [string](Get-PropertyValue -Object $file -Name "Path")
            $fieldName = [string](Get-PropertyValue -Object $file -Name "FieldName")
            $mimeType = [string](Get-PropertyValue -Object $file -Name "MimeType")
            if ([string]::IsNullOrWhiteSpace($mimeType)) {
                $mimeType = Get-ImageMimeType -Path $path
            }
            $stream = [System.IO.File]::OpenRead($path)
            $streams.Add($stream) | Out-Null
            $fileContent = [System.Net.Http.StreamContent]::new($stream)
            $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($mimeType)
            $content.Add($fileContent, $fieldName, [System.IO.Path]::GetFileName($path))
        }

        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Url)
        $request.Content = $content
        $request.Headers.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new("application/json"))
        if ($authenticated) {
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

        Complete-ApiTranscriptResponse -Record $transcriptRecord -StatusCode ([int]$response.StatusCode) -Json $json -BodyText $bodyText

        return [pscustomobject]@{
            Method = $Method
            Url = $Url
            StatusCode = [int]$response.StatusCode
            Json = $json
            BodyText = $bodyText
        }
    } catch {
        Complete-ApiTranscriptResponse -Record $transcriptRecord -StatusCode $null -BodyText ""
        Add-ApiAssertion -Status "FAIL" -Description "multipart request returned a response" -Expected "response" -Actual (Redact-FixtureIdsInText $_.Exception.Message)
        throw "Multipart request failed before response: $Method $Url. $(Redact-Text $_.Exception.Message)"
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        if ($null -ne $content) { $content.Dispose() }
        foreach ($stream in $streams) { $stream.Dispose() }
        $client.Dispose()
    }
}

function Find-IndexedImage {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][int]$Index,
        [Parameter(Mandatory = $true)][string]$Extension
    )

    $extensions = if ($Extension -eq "auto") { @("jpg", "jpeg", "png") } else { @($Extension.TrimStart(".")) }
    foreach ($candidateExtension in $extensions) {
        $candidate = Join-Path $Directory "$Index.$candidateExtension"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    Fail-Config "Indexed nose image not found: $Index.[jpg|jpeg|png] in $Directory"
}

function Get-FileEvidence {
    param([Parameter(Mandatory = $true)][string]$Path)

    $file = Get-Item -LiteralPath $Path
    $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
    return [ordered]@{
        basename = $file.Name
        size_bytes = $file.Length
        sha256 = $hash.Hash.ToLowerInvariant()
    }
}

function New-SmokeSuffix {
    return "$(Get-Date -Format 'yyyyMMddHHmmssfff')-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
}

function New-SmokeEmail {
    param([Parameter(Mandatory = $true)][string]$Prefix)

    return "$Prefix-$(New-SmokeSuffix)@example.test"
}

function New-SmokePassword {
    param([Parameter(Mandatory = $true)][string]$Prefix)

    return "$Prefix-$([System.Guid]::NewGuid().ToString('N'))!"
}

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Name)
    Write-Host "==> $Name"
}

function Set-ScenarioResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()][string]$Note = "",
        [bool]$Optional = $false
    )

    $script:Summary["scenarios"][$Name] = [ordered]@{
        status = $Status
        optional = $Optional
        note = Redact-Text $Note
    }
}

function Skip-Scenario {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Note,
        [bool]$Optional = $false
    )

    Write-Host "SKIP $Name - $Note"
    Set-ScenarioResult -Name $Name -Status "SKIP" -Note $Note -Optional $Optional
    Complete-ApiTranscriptScenario -ScenarioName $Name -Status "SKIP" -Note $Note
}

function Invoke-Scenario {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Command,
        [switch]$Optional
    )

    Write-Step $Name
    $previousScenarioName = $script:CurrentScenarioName
    $script:CurrentScenarioName = $Name
    $script:CurrentApiRecord = $null
    try {
        & $Command
        Set-ScenarioResult -Name $Name -Status "PASS" -Optional ([bool]$Optional)
        Write-Host "PASS $Name"
        Complete-ApiTranscriptScenario -ScenarioName $Name -Status "PASS"
    } catch {
        $message = Redact-Text $_.Exception.Message
        Set-ScenarioResult -Name $Name -Status "FAIL" -Note $message -Optional ([bool]$Optional)
        Write-Host "FAIL $Name - $message"
        Complete-ApiTranscriptScenario -ScenarioName $Name -Status "FAIL" -Note $message
        if ($Optional -and -not $StopOnOptionalFailure) {
            return
        }
        throw
    } finally {
        $script:CurrentScenarioName = $previousScenarioName
        $script:CurrentApiRecord = $null
    }
}

function Get-VectorContract {
    param([AllowNull()][object]$CollectionResponse)

    $dimension = $null
    $distance = $null
    $result = Get-PropertyValue -Object $CollectionResponse -Name "result"
    $config = Get-PropertyValue -Object $result -Name "config"
    $params = Get-PropertyValue -Object $config -Name "params"
    $vectors = Get-PropertyValue -Object $params -Name "vectors"
    if ($null -ne $vectors) {
        if (Test-Property -Object $vectors -Name "size") {
            $dimension = Get-PropertyValue -Object $vectors -Name "size"
            $distance = Get-PropertyValue -Object $vectors -Name "distance"
        } else {
            $firstVector = $vectors.PSObject.Properties | Select-Object -First 1
            if ($null -ne $firstVector) {
                $dimension = Get-PropertyValue -Object $firstVector.Value -Name "size"
                $distance = Get-PropertyValue -Object $firstVector.Value -Name "distance"
            }
        }
    }
    return [pscustomobject]@{
        dimension = $dimension
        distance = $distance
    }
}

function Get-BearerHeaders {
    param([Parameter(Mandatory = $true)][string]$Token)
    return @{ Authorization = "Bearer $Token" }
}

function Resolve-FileUrl {
    param([Parameter(Mandatory = $true)][string]$MaybeRelativeUrl)

    if ($MaybeRelativeUrl.StartsWith("http://", [System.StringComparison]::OrdinalIgnoreCase) -or
        $MaybeRelativeUrl.StartsWith("https://", [System.StringComparison]::OrdinalIgnoreCase)) {
        return $MaybeRelativeUrl
    }
    return Join-Url $RootUrl $MaybeRelativeUrl
}

function Test-FileUrl {
    param(
        [Parameter(Mandatory = $true)][string]$MaybeRelativeUrl,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $url = Resolve-FileUrl -MaybeRelativeUrl $MaybeRelativeUrl
    $response = Invoke-Json -Method "GET" -Url $url
    Assert-Status -Response $response -ExpectedStatus 200
    $script:Summary["counts"]["$($Name)_http_status"] = $response.StatusCode
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
        [switch]$AllowFailure
    )

    $output = & $File @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $lines = @($output | ForEach-Object { Redact-Text ([string]$_) })
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "$File $($Arguments -join ' ') failed with exit code $exitCode. Output: $($lines -join ' ')"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $lines
    }
}

function Get-RequiredComposeProjectName {
    if ([string]::IsNullOrWhiteSpace($ComposeProjectName)) {
        Fail-Config "ComposeProjectName must not be empty for docker compose commands."
    }
    return $ComposeProjectName
}

function New-DockerComposeArguments {
    param([string[]]$CommandArguments = @())

    $resolvedEnvFile = Resolve-RepoPath $EnvFile
    if (-not (Test-Path -LiteralPath $resolvedEnvFile -PathType Leaf)) {
        Fail-Config "EnvFile not found: $EnvFile"
    }
    if ((Split-Path -Leaf $resolvedEnvFile) -eq ".env.example") {
        Fail-Config "Refusing to read .env.example as runtime secrets."
    }

    $resolvedComposeFiles = @()
    foreach ($file in $ComposeFile) {
        $resolved = Resolve-RepoPath $file
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            Fail-Config "ComposeFile not found: $file"
        }
        $resolvedComposeFiles += $resolved
    }

    $composeArgs = @("compose", "-p", (Get-RequiredComposeProjectName), "--env-file", $resolvedEnvFile)
    foreach ($file in $resolvedComposeFiles) {
        $composeArgs += @("-f", $file)
    }
    $composeArgs += $CommandArguments
    return $composeArgs
}

function Invoke-DockerComposeCommand {
    param(
        [string[]]$CommandArguments = @(),
        [switch]$AllowFailure
    )

    $composeArgs = New-DockerComposeArguments -CommandArguments $CommandArguments
    return Invoke-NativeCapture -File "docker" -Arguments $composeArgs -AllowFailure:$AllowFailure
}

function Test-HttpOk {
    param([Parameter(Mandatory = $true)][string]$Url)

    try {
        $response = Invoke-WebRequest -Method "GET" -Uri $Url -SkipHttpErrorCheck -TimeoutSec 5
        return ([int]$response.StatusCode -eq 200)
    } catch {
        return $false
    }
}

function Wait-RuntimeHealth {
    $deadline = (Get-Date).AddMinutes(5)
    $rootHealthUrl = Join-Url $RootUrl "actuator/health"
    $pythonHealthUrl = Join-Url $PythonEmbedUrl "health"
    $qdrantHealthUrl = Join-Url $QdrantUrl "healthz"

    while ((Get-Date) -lt $deadline) {
        if ((Test-HttpOk -Url $rootHealthUrl) -and
            (Test-HttpOk -Url $pythonHealthUrl) -and
            (Test-HttpOk -Url $qdrantHealthUrl)) {
            return
        }
        Start-Sleep -Seconds 5
    }
    Fail-Config "Runtime did not become healthy within 5 minutes after docker compose up."
}

function Initialize-RuntimeIfRequested {
    if ($ResetRuntimeData) {
        Write-Step "runtime_reset"
        Invoke-DockerComposeCommand -CommandArguments @("down", "-v") | Out-Null
    }
    if ($StartRuntime) {
        Write-Step "runtime_start"
        Invoke-DockerComposeCommand -CommandArguments @("up", "-d", "--build") | Out-Null
        $script:RuntimeStartedByScript = $true
        Wait-RuntimeHealth
    }
}

function Stop-RuntimeIfRequested {
    if (-not $StopRuntimeAfter) {
        return
    }
    try {
        Write-Step "runtime_stop"
        Invoke-DockerComposeCommand -CommandArguments @("down", "-v") -AllowFailure | Out-Null
    } catch {
        Write-Warning "Could not stop runtime after smoke: $(Redact-Text $_.Exception.Message)"
    }
}

function Invoke-MySqlQueryOptional {
    param([Parameter(Mandatory = $true)][string]$Query)

    $resolvedEnvFile = Resolve-RepoPath $EnvFile
    if (-not (Test-Path -LiteralPath $resolvedEnvFile -PathType Leaf)) {
        return [pscustomobject]@{
            Available = $false
            Rows = @()
            Note = "EnvFile not found: $EnvFile"
        }
    }
    if ((Split-Path -Leaf $resolvedEnvFile) -eq ".env.example") {
        return [pscustomobject]@{
            Available = $false
            Rows = @()
            Note = "Refusing to read .env.example as runtime secrets."
        }
    }

    $resolvedComposeFiles = @()
    foreach ($file in $ComposeFile) {
        $resolved = Resolve-RepoPath $file
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            return [pscustomobject]@{
                Available = $false
                Rows = @()
                Note = "ComposeFile not found: $file"
            }
        }
        $resolvedComposeFiles += $resolved
    }

    try {
        $envValues = Read-DotEnv -Path $resolvedEnvFile
        $database = if ([string]::IsNullOrWhiteSpace($MysqlDatabase)) { Get-ConfigValue -Values $envValues -Keys @("MYSQL_DATABASE") -Fallback "petnose" } else { $MysqlDatabase }
        $user = if ([string]::IsNullOrWhiteSpace($MysqlUser)) { Get-ConfigValue -Values $envValues -Keys @("MYSQL_USER", "SPRING_DATASOURCE_USERNAME") -Fallback "petnose" } else { $MysqlUser }
        $password = if ([string]::IsNullOrWhiteSpace($MysqlPassword)) { Get-ConfigValue -Values $envValues -Keys @("MYSQL_PASSWORD", "SPRING_DATASOURCE_PASSWORD") -Fallback "" } else { $MysqlPassword }
        if ([string]::IsNullOrWhiteSpace($password)) {
            return [pscustomobject]@{
                Available = $false
                Rows = @()
                Note = "MysqlPassword was not provided and was not found in EnvFile."
            }
        }
        Add-Secret $password

        $composeArgs = New-DockerComposeArguments -CommandArguments @(
            "exec",
            "-T",
            "-e",
            "MYSQL_PWD",
            $MysqlService,
            "mysql",
            "--batch",
            "--raw",
            "--skip-column-names",
            "--default-character-set=utf8mb4",
            "-h",
            "127.0.0.1",
            "-u",
            $user,
            $database,
            "-e",
            $Query
        )

        $previousMysqlPwd = [Environment]::GetEnvironmentVariable("MYSQL_PWD", "Process")
        [Environment]::SetEnvironmentVariable("MYSQL_PWD", $password, "Process")
        try {
            $result = Invoke-NativeCapture -File "docker" -Arguments $composeArgs
        } finally {
            [Environment]::SetEnvironmentVariable("MYSQL_PWD", $previousMysqlPwd, "Process")
        }
        return [pscustomobject]@{
            Available = $true
            Rows = @($result.Output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            Note = ""
        }
    } catch {
        return [pscustomobject]@{
            Available = $false
            Rows = @()
            Note = Redact-Text $_.Exception.Message
        }
    }
}

function Get-DogDbSnapshotOptional {
    param([Parameter(Mandatory = $true)][string]$DogId)

    $safeDogId = $DogId.Replace("'", "''")
    $query = @"
SELECT
  (SELECT COUNT(*) FROM dog_images WHERE dog_id = '$safeDogId' AND image_type = 'NOSE'),
  (SELECT COUNT(*) FROM verification_logs WHERE dog_id = '$safeDogId'),
  (SELECT status FROM dogs WHERE id = '$safeDogId'),
  (SELECT owner_user_id FROM dogs WHERE id = '$safeDogId');
"@
    $result = Invoke-MySqlQueryOptional -Query $query
    if (-not $result.Available -or @($result.Rows).Count -eq 0) {
        return [pscustomobject]@{
            Available = $false
            Note = $result.Note
        }
    }
    $columns = ([string]@($result.Rows)[0]).Split([char]"`t")
    if ($columns.Count -lt 4) {
        return [pscustomobject]@{
            Available = $false
            Note = "Could not parse DB snapshot row."
        }
    }
    return [pscustomobject]@{
        Available = $true
        nose_images = [int]$columns[0]
        verification_logs = [int]$columns[1]
        dog_status = [string]$columns[2]
        owner_user_id = [string]$columns[3]
        Note = ""
    }
}

function Get-InitialDbCounts {
    $query = @"
SELECT
  (SELECT COUNT(*) FROM users),
  (SELECT COUNT(*) FROM dogs),
  (SELECT COUNT(*) FROM dog_images),
  (SELECT COUNT(*) FROM dog_nose_references),
  (SELECT COUNT(*) FROM verification_logs),
  (SELECT COUNT(*) FROM adoption_posts),
  (SELECT COUNT(*) FROM adoption_post_likes);
"@
    $result = Invoke-MySqlQueryOptional -Query $query
    if (-not $result.Available -or @($result.Rows).Count -eq 0) {
        Fail-Assert "Initial DB row count check unavailable: $($result.Note)"
    }

    $columns = ([string]@($result.Rows)[0]).Split([char]"`t")
    if ($columns.Count -lt 7) {
        Fail-Assert "Initial DB row count check returned an unexpected row shape."
    }

    return [ordered]@{
        users = [int]$columns[0]
        dogs = [int]$columns[1]
        dog_images = [int]$columns[2]
        dog_nose_references = [int]$columns[3]
        verification_logs = [int]$columns[4]
        adoption_posts = [int]$columns[5]
        adoption_post_likes = [int]$columns[6]
    }
}

function Get-QdrantActivePointCount {
    $response = Invoke-Json -Method "POST" -Url (Join-Url $QdrantUrl "collections/$QdrantCollection/points/count") -BodyObject @{
        exact = $true
        filter = @{
            must = @(
                @{
                    key = "is_active"
                    match = @{
                        value = $true
                    }
                }
            )
        }
    }
    Assert-Status -Response $response -ExpectedStatus 200
    $result = Get-PropertyValue -Object $response.Json -Name "result"
    $count = Get-PropertyValue -Object $result -Name "count"
    Assert-NotNullOrEmpty -Value $count -Name "initial_qdrant_active_points.count"
    return [int64]$count
}

function Verify-CleanRuntimeData {
    $dbCounts = Get-InitialDbCounts
    $qdrantActivePoints = Get-QdrantActivePointCount
    $script:Summary["counts"]["initial_db"] = $dbCounts
    $script:Summary["counts"]["initial_qdrant_active_points"] = $qdrantActivePoints

    foreach ($name in $dbCounts.Keys) {
        Assert-Equal -Actual $dbCounts[$name] -Expected 0 -Name "initial_db.$name"
    }
    Assert-Equal -Actual $qdrantActivePoints -Expected 0 -Name "initial_qdrant_active_points"
}

function Invoke-Reconciliation {
    $outputDirectory = Resolve-RepoPath $OutputDir
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    $relativeOutput = Join-Path $OutputDir "reconciliation-summary.json"
    $scriptPath = Join-Path $script:RepoRoot "scripts\check-qdrant-reference-consistency.ps1"
    $arguments = @(
        "-NoProfile",
        "-File",
        $scriptPath,
        "-QdrantUrl",
        $QdrantUrl,
        "-Collection",
        $QdrantCollection,
        "-EnvFile",
        $EnvFile,
        "-MysqlService",
        $MysqlService,
        "-OutputPath",
        $relativeOutput,
        "-ExpectedDimension",
        "$ExpectedVectorDimension",
        "-ExpectedDistance",
        $ExpectedDistance,
        "-FailOnDrift"
    )
    if (-not [string]::IsNullOrWhiteSpace($MysqlDatabase)) {
        $arguments += @("-MysqlDatabase", $MysqlDatabase)
    }
    if (-not [string]::IsNullOrWhiteSpace($MysqlUser)) {
        $arguments += @("-MysqlUser", $MysqlUser)
    }
    if (-not [string]::IsNullOrWhiteSpace($MysqlPassword)) {
        Add-Secret $MysqlPassword
        $arguments += @("-MysqlPassword", $MysqlPassword)
    }
    if ($ComposeFile.Count -gt 0) {
        $arguments += @("-ComposeFile", ($ComposeFile -join ";"))
    }
    if (-not [string]::IsNullOrWhiteSpace($ComposeProjectName)) {
        $arguments += @("-ComposeProjectName", $ComposeProjectName)
    }

    $result = Invoke-NativeCapture -File "pwsh" -Arguments $arguments -AllowFailure
    if ($result.ExitCode -ne 0) {
        throw "Reconciliation failed with exit code $($result.ExitCode). Output: $($result.Output -join ' ')"
    }

    $jsonText = ($result.Output -join "`n").Trim()
    $json = $jsonText | ConvertFrom-Json
    Assert-True -Value (Get-PropertyValue -Object $json -Name "consistent") -Name "reconciliation.consistent"
    $missing = @(Get-PropertyValue -Object $json -Name "missing_in_qdrant")
    $orphan = @(Get-PropertyValue -Object $json -Name "orphan_in_qdrant")
    $mismatch = @(Get-PropertyValue -Object $json -Name "payload_mismatches")
    Assert-Equal -Actual $missing.Count -Expected 0 -Name "reconciliation.missing_in_qdrant"
    Assert-Equal -Actual $orphan.Count -Expected 0 -Name "reconciliation.orphan_in_qdrant"
    Assert-Equal -Actual $mismatch.Count -Expected 0 -Name "reconciliation.payload_mismatches"

    $script:Summary["reconciliation"] = [ordered]@{
        consistent = [bool](Get-PropertyValue -Object $json -Name "consistent")
        missing_in_qdrant_count = $missing.Count
        orphan_in_qdrant_count = $orphan.Count
        payload_mismatch_count = $mismatch.Count
        output_json_path = $relativeOutput
    }
}

function Save-Summary {
    if (-not $WriteEvidence) {
        return
    }

    $resolvedSummaryPath = Resolve-RepoPath $SummaryPath
    $resolvedOutputDir = Resolve-RepoPath $OutputDir
    if (-not (Test-Path -LiteralPath $resolvedOutputDir -PathType Container)) {
        New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null
    }

    $safeSummary = ConvertTo-SafeEvidenceValue -Value $script:Summary
    $jsonText = ConvertTo-JsonText $safeSummary
    Write-Utf8NoBom -Path $resolvedSummaryPath -Text ($jsonText + "`n")

    $markdownPath = Join-Path $resolvedOutputDir "summary.md"
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("# Manual Full Feature Smoke Summary") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Checked at: $($script:Summary.checked_at)") | Out-Null
    $lines.Add("- Base URL: $BaseUrl") | Out-Null
    $lines.Add("- Firebase mode: $FirebaseMode") | Out-Null
    $lines.Add("- Password reset mode: $PasswordResetMode") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("## Scenario Results") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("| Scenario | Status | Optional | Note |") | Out-Null
    $lines.Add("| --- | --- | --- | --- |") | Out-Null
    foreach ($name in $script:Summary["scenarios"].Keys) {
        $scenario = $script:Summary["scenarios"][$name]
        $note = ([string]$scenario.note).Replace("|", "\|")
        $lines.Add("| $name | $($scenario.status) | $($scenario.optional) | $note |") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("## Redaction") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- JWT/password/reset token/Firebase custom token/FCM token are redacted.") | Out-Null
    $lines.Add("- Service account paths/content, raw images, raw vectors, and full Qdrant payloads are not recorded.") | Out-Null
    Write-Utf8NoBom -Path $markdownPath -Text (($lines -join "`n") + "`n")

    Write-Host "Wrote sanitized evidence:"
    Write-Host "  $resolvedSummaryPath"
    Write-Host "  $markdownPath"
}

function Initialize-Fixtures {
    if ([string]::IsNullOrWhiteSpace($NoseImageDir)) {
        Fail-Config "NoseImageDir is required. Use -Help for examples."
    }
    $resolvedNoseImageDir = Resolve-RepoPath $NoseImageDir
    if (-not (Test-Path -LiteralPath $resolvedNoseImageDir -PathType Container)) {
        Fail-Config "NoseImageDir not found: $NoseImageDir"
    }
    $resolvedNoseImageDir = (Resolve-Path -LiteralPath $resolvedNoseImageDir).Path

    $images = @()
    for ($index = 1; $index -le $RegisterNoseImageCount; $index++) {
        $images += Find-IndexedImage -Directory $resolvedNoseImageDir -Index $index -Extension $NoseImageExtension
    }
    $script:RegistrationImages = $images
    $script:HandoverImage = Find-IndexedImage -Directory $resolvedNoseImageDir -Index $HandoverImageIndex -Extension $NoseImageExtension

    if ([string]::IsNullOrWhiteSpace($OwnerProfileImagePath)) {
        $script:OwnerProfileImage = $script:RegistrationImages[0]
    } else {
        $resolvedOwnerProfile = Resolve-RepoPath $OwnerProfileImagePath
        if (-not (Test-Path -LiteralPath $resolvedOwnerProfile -PathType Leaf)) {
            Fail-Config "OwnerProfileImagePath not found: $OwnerProfileImagePath"
        }
        $script:OwnerProfileImage = (Resolve-Path -LiteralPath $resolvedOwnerProfile).Path
    }

    if ([string]::IsNullOrWhiteSpace($PostProfileImagePath)) {
        $script:PostProfileImage = $script:OwnerProfileImage
    } else {
        $resolvedPostProfile = Resolve-RepoPath $PostProfileImagePath
        if (-not (Test-Path -LiteralPath $resolvedPostProfile -PathType Leaf)) {
            Fail-Config "PostProfileImagePath not found: $PostProfileImagePath"
        }
        $script:PostProfileImage = (Resolve-Path -LiteralPath $resolvedPostProfile).Path
    }

    $fixtureImages = @()
    foreach ($image in $script:RegistrationImages) {
        $fixtureImages += Get-FileEvidence -Path $image
    }
    $script:Summary["fixture"] = [ordered]@{
        nose_image_dir_basename = (Split-Path -Leaf $resolvedNoseImageDir)
        registration_image_count = $script:RegistrationImages.Count
        registration_images = $fixtureImages
        handover_image = Get-FileEvidence -Path $script:HandoverImage
        owner_profile_image = Get-FileEvidence -Path $script:OwnerProfileImage
        post_profile_image = Get-FileEvidence -Path $script:PostProfileImage
    }
}

function Invoke-Preflight {
    Initialize-Fixtures

    $rootHealth = Invoke-Json -Method "GET" -Url (Join-Url $RootUrl "actuator/health")
    Assert-Status -Response $rootHealth -ExpectedStatus 200
    $script:Summary["runtime_health"]["spring_status"] = Get-PropertyValue -Object $rootHealth.Json -Name "status"

    $pythonHealth = Invoke-Json -Method "GET" -Url (Join-Url $PythonEmbedUrl "health")
    Assert-Status -Response $pythonHealth -ExpectedStatus 200
    $script:Summary["runtime_health"]["python"] = ConvertTo-SafeEvidenceValue -Value $pythonHealth.Json

    $qdrantHealth = Invoke-Json -Method "GET" -Url (Join-Url $QdrantUrl "healthz")
    Assert-Status -Response $qdrantHealth -ExpectedStatus 200
    $script:Summary["runtime_health"]["qdrant_healthz"] = "ok"

    $collection = Invoke-Json -Method "GET" -Url (Join-Url $QdrantUrl "collections/$QdrantCollection")
    Assert-Status -Response $collection -ExpectedStatus 200
    $contract = Get-VectorContract -CollectionResponse $collection.Json
    Assert-Equal -Actual $contract.dimension -Expected $ExpectedVectorDimension -Name "qdrant.collection.dimension"
    if ($null -ne $contract.distance) {
        if (-not ([string]$contract.distance).Equals($ExpectedDistance, [System.StringComparison]::OrdinalIgnoreCase)) {
            Fail-Assert "qdrant.collection.distance mismatch. Expected '$ExpectedDistance', actual '$($contract.distance)'."
        }
    }
    $script:Summary["runtime_health"]["qdrant_collection"] = [ordered]@{
        collection = $QdrantCollection
        dimension = $contract.dimension
        distance = $contract.distance
    }

    $devPing = Invoke-Json -Method "GET" -Url (Join-Url $BaseUrl "dev/ping")
    if ($devPing.StatusCode -eq 200) {
        $script:Summary["runtime_health"]["base_url_dev_ping"] = "ok"
    } elseif ($devPing.StatusCode -eq 404 -or $devPing.StatusCode -eq 403) {
        $script:Summary["runtime_health"]["base_url_dev_ping"] = "not available in this profile"
    } else {
        Assert-StatusIn -Response $devPing -ExpectedStatuses @(200, 404, 403) -Name "base_url_dev_ping"
    }
}

function Register-Owner {
    $script:OwnerEmail = New-SmokeEmail -Prefix "manual-smoke-owner"
    $script:OwnerPassword = New-SmokePassword -Prefix "Owner"
    Add-Secret $script:OwnerPassword
    $response = Invoke-Multipart -Method "POST" -Url (Join-Url $BaseUrl "auth/register") -Fields @{
        email = $script:OwnerEmail
        password = $script:OwnerPassword
        display_name = "SmokeOwner"
        contact_phone = "01012345678"
        region = "Seoul"
    } -Files @(
        [pscustomobject]@{
            FieldName = "profile_image"
            Path = $script:OwnerProfileImage
            MimeType = Get-ImageMimeType -Path $script:OwnerProfileImage
        }
    )
    Assert-Status -Response $response -ExpectedStatus 201
    Assert-NotNullOrEmpty -Value (Get-PropertyValue -Object $response.Json -Name "user_id") -Name "owner.user_id"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "email") -Expected $script:OwnerEmail -Name "owner.email"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "role") -Expected "USER" -Name "owner.role"
    Assert-True -Value (Get-PropertyValue -Object $response.Json -Name "is_active") -Name "owner.is_active"
    Assert-NotHasProperty -Object $response.Json -Name "password_hash" -Context "owner register response"
    Assert-NotNullOrEmpty -Value (Get-PropertyValue -Object $response.Json -Name "profile_image_url") -Name "owner.profile_image_url"
    $script:OwnerUserId = Get-PropertyValue -Object $response.Json -Name "user_id"
    $script:OwnerProfileImageUrl = [string](Get-PropertyValue -Object $response.Json -Name "profile_image_url")
    $script:Summary["markers"]["owner_user_id"] = "present"
}

function Login-Owner {
    $response = Invoke-Json -Method "POST" -Url (Join-Url $BaseUrl "auth/login") -BodyObject @{
        email = $script:OwnerEmail
        password = $script:OwnerPassword
    }
    Assert-Status -Response $response -ExpectedStatus 200
    $token = Get-PropertyValue -Object $response.Json -Name "access_token"
    Assert-NotNullOrEmpty -Value $token -Name "owner.access_token"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "token_type") -Expected "Bearer" -Name "owner.token_type"
    $user = Get-PropertyValue -Object $response.Json -Name "user"
    Assert-Equal -Actual (Get-PropertyValue -Object $user -Name "user_id") -Expected $script:OwnerUserId -Name "owner.login.user_id"
    $script:OwnerToken = [string]$token
    Add-Secret $script:OwnerToken
}

function Get-OwnerMe {
    $response = Invoke-Json -Method "GET" -Url (Join-Url $BaseUrl "users/me") -BearerToken $script:OwnerToken
    Assert-Status -Response $response -ExpectedStatus 200
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "user_id") -Expected $script:OwnerUserId -Name "owner.me.user_id"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "email") -Expected $script:OwnerEmail -Name "owner.me.email"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "role") -Expected "USER" -Name "owner.me.role"
    Assert-True -Value (Get-PropertyValue -Object $response.Json -Name "is_active") -Name "owner.me.is_active"
    Assert-NotHasProperty -Object $response.Json -Name "password_hash" -Context "owner me response"
}

function Update-OwnerProfile {
    $response = Invoke-Json -Method "PATCH" -Url (Join-Url $BaseUrl "users/me/profile") -BearerToken $script:OwnerToken -BodyObject @{
        display_name = "Owner2"
        contact_phone = "01087654321"
        region = "Busan"
    }
    Assert-Status -Response $response -ExpectedStatus 200
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "user_id") -Expected $script:OwnerUserId -Name "profile.user_id"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "display_name") -Expected "Owner2" -Name "profile.display_name"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "contact_phone") -Expected "01087654321" -Name "profile.contact_phone"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "region") -Expected "Busan" -Name "profile.region"
    Assert-NotHasProperty -Object $response.Json -Name "password_hash" -Context "profile update response"
}

function Update-OwnerProfileImage {
    $response = Invoke-Multipart -Method "PATCH" -Url (Join-Url $BaseUrl "users/me/profile-image") -BearerToken $script:OwnerToken -Files @(
        [pscustomobject]@{
            FieldName = "profile_image"
            Path = $script:OwnerProfileImage
            MimeType = Get-ImageMimeType -Path $script:OwnerProfileImage
        }
    )
    Assert-Status -Response $response -ExpectedStatus 200
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "user_id") -Expected $script:OwnerUserId -Name "profile_image.user_id"
    Assert-NotNullOrEmpty -Value (Get-PropertyValue -Object $response.Json -Name "profile_image_url") -Name "profile_image.profile_image_url"
    $script:OwnerProfileImageUrl = [string](Get-PropertyValue -Object $response.Json -Name "profile_image_url")
}

function Change-OwnerPassword {
    $oldPassword = $script:OwnerPassword
    $newPassword = New-SmokePassword -Prefix "OwnerChanged"
    Add-Secret $newPassword
    $response = Invoke-Json -Method "PATCH" -Url (Join-Url $BaseUrl "users/me/password") -BearerToken $script:OwnerToken -BodyObject @{
        current_password = $oldPassword
        new_password = $newPassword
    }
    Assert-Status -Response $response -ExpectedStatus 200
    Assert-True -Value (Get-PropertyValue -Object $response.Json -Name "changed") -Name "password.changed"

    $oldLogin = Invoke-Json -Method "POST" -Url (Join-Url $BaseUrl "auth/login") -BodyObject @{
        email = $script:OwnerEmail
        password = $oldPassword
    }
    if ($oldLogin.StatusCode -eq 200) {
        Fail-Assert "old password login must fail after password change."
    }

    $script:OwnerPassword = $newPassword
    $newLogin = Invoke-Json -Method "POST" -Url (Join-Url $BaseUrl "auth/login") -BodyObject @{
        email = $script:OwnerEmail
        password = $script:OwnerPassword
    }
    Assert-Status -Response $newLogin -ExpectedStatus 200
    $script:OwnerToken = [string](Get-PropertyValue -Object $newLogin.Json -Name "access_token")
    Assert-NotNullOrEmpty -Value $script:OwnerToken -Name "owner.new_access_token"
    Add-Secret $script:OwnerToken
}

function Invoke-PasswordResetFlow {
    if ($PasswordResetMode -eq "skip") {
        Skip-Scenario -Name "password_reset" -Note "Skipped by -PasswordResetMode skip."
        return
    }

    Invoke-Scenario -Name "password_reset" -Command {
        $requestResponse = Invoke-Json -Method "POST" -Url (Join-Url $BaseUrl "auth/password-reset/request") -BodyObject @{
            email = $script:OwnerEmail
        }
        Assert-Status -Response $requestResponse -ExpectedStatus 200
        Assert-True -Value (Get-PropertyValue -Object $requestResponse.Json -Name "requested") -Name "password_reset.requested"

        $resetToken = ""
        if ($PasswordResetMode -eq "dev-exposed") {
            $resetToken = [string](Get-PropertyValue -Object $requestResponse.Json -Name "reset_token")
            Assert-NotNullOrEmpty -Value $resetToken -Name "password_reset.reset_token"
        } elseif ($PasswordResetMode -eq "email") {
            $resetToken = Read-Host "Enter reset token from email, or press Enter to skip confirm"
            if ([string]::IsNullOrWhiteSpace($resetToken)) {
                $script:Summary["validation_notes"] += "Password reset email request passed; confirm skipped because no token was entered."
                return
            }
        }
        Add-Secret $resetToken

        $resetPassword = New-SmokePassword -Prefix "OwnerReset"
        Add-Secret $resetPassword
        $confirm = Invoke-Json -Method "POST" -Url (Join-Url $BaseUrl "auth/password-reset/confirm") -BodyObject @{
            reset_token = $resetToken
            new_password = $resetPassword
        }
        Assert-Status -Response $confirm -ExpectedStatus 200
        Assert-True -Value (Get-PropertyValue -Object $confirm.Json -Name "reset") -Name "password_reset.reset"

        $login = Invoke-Json -Method "POST" -Url (Join-Url $BaseUrl "auth/login") -BodyObject @{
            email = $script:OwnerEmail
            password = $resetPassword
        }
        Assert-Status -Response $login -ExpectedStatus 200
        $script:OwnerPassword = $resetPassword
        $script:OwnerToken = [string](Get-PropertyValue -Object $login.Json -Name "access_token")
        Assert-NotNullOrEmpty -Value $script:OwnerToken -Name "password_reset.login.access_token"
        Add-Secret $script:OwnerToken

        $reuse = Invoke-Json -Method "POST" -Url (Join-Url $BaseUrl "auth/password-reset/confirm") -BodyObject @{
            reset_token = $resetToken
            new_password = (New-SmokePassword -Prefix "ReuseShouldFail")
        }
        if ($reuse.StatusCode -eq 200) {
            Fail-Assert "password reset token reuse must fail."
        }
    }
}

function Register-Dog {
    $files = @()
    foreach ($image in $script:RegistrationImages) {
        $files += [pscustomobject]@{
            FieldName = "nose_images"
            Path = $image
            MimeType = Get-ImageMimeType -Path $image
        }
    }
    $response = Invoke-Multipart -Method "POST" -Url (Join-Url $BaseUrl "dogs/register") -BearerToken $script:OwnerToken -Fields @{
        name = "Ddubi Manual Smoke"
        breed = "Maltese"
        gender = "MALE"
        birth_date = "2024-01-01"
        description = "Manual full-feature smoke registration"
    } -Files $files

    Assert-Status -Response $response -ExpectedStatus 201
    Assert-True -Value (Get-PropertyValue -Object $response.Json -Name "registration_allowed") -Name "dog.registration_allowed"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "status") -Expected "REGISTERED" -Name "dog.status"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "verification_status") -Expected "VERIFIED" -Name "dog.verification_status"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "embedding_status") -Expected "COMPLETED" -Name "dog.embedding_status"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "embedding_mode") -Expected "MULTI_REFERENCE" -Name "dog.embedding_mode"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "reference_count") -Expected $RegisterNoseImageCount -Name "dog.reference_count"
    Assert-Null -Value (Get-PropertyValue -Object $response.Json -Name "qdrant_point_id") -Name "dog.qdrant_point_id"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "dimension") -Expected $ExpectedVectorDimension -Name "dog.dimension"
    Assert-Count -Value (Get-PropertyValue -Object $response.Json -Name "nose_image_urls") -Expected $RegisterNoseImageCount -Name "dog.nose_image_urls"
    $script:DogId = [string](Get-PropertyValue -Object $response.Json -Name "dog_id")
    Assert-NotNullOrEmpty -Value $script:DogId -Name "dog.dog_id"
    $script:OwnerNoseImageUrl = [string](@(Get-PropertyValue -Object $response.Json -Name "nose_image_urls") | Select-Object -First 1)
    $script:Summary["markers"]["dog_id"] = "present"
}

function Get-MyDogsBeforePost {
    $response = Invoke-Json -Method "GET" -Url (Join-Url $BaseUrl "dogs/me?page=0&size=50") -BearerToken $script:OwnerToken
    Assert-Status -Response $response -ExpectedStatus 200
    $item = Find-ItemByProperty -Items (Get-PropertyValue -Object $response.Json -Name "items") -Property "dog_id" -Expected $script:DogId
    Assert-NotNullOrEmpty -Value $item -Name "dogs_me.item"
    Assert-Equal -Actual (Get-PropertyValue -Object $item -Name "status") -Expected "REGISTERED" -Name "dogs_me.status"
    Assert-Equal -Actual (Get-PropertyValue -Object $item -Name "verification_status") -Expected "VERIFIED" -Name "dogs_me.verification_status"
    Assert-True -Value (Get-PropertyValue -Object $item -Name "can_create_post") -Name "dogs_me.can_create_post"
    Assert-False -Value (Get-PropertyValue -Object $item -Name "has_active_post") -Name "dogs_me.has_active_post"
    Assert-Null -Value (Get-PropertyValue -Object $item -Name "active_post_id") -Name "dogs_me.active_post_id"
    Assert-NotHasProperty -Object $item -Name "nose_image_url" -Context "owner dog list item"
}

function Get-OwnerDogDetail {
    $response = Invoke-Json -Method "GET" -Url (Join-Url $BaseUrl "dogs/$script:DogId") -BearerToken $script:OwnerToken
    Assert-Status -Response $response -ExpectedStatus 200
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "dog_id") -Expected $script:DogId -Name "owner_dog_detail.dog_id"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "status") -Expected "REGISTERED" -Name "owner_dog_detail.status"
    Assert-NotNullOrEmpty -Value (Get-PropertyValue -Object $response.Json -Name "nose_image_url") -Name "owner_dog_detail.nose_image_url"
    $script:OwnerNoseImageUrl = [string](Get-PropertyValue -Object $response.Json -Name "nose_image_url")
}

function Create-AdoptionPost {
    $response = Invoke-Multipart -Method "POST" -Url (Join-Url $BaseUrl "adoption-posts") -BearerToken $script:OwnerToken -Fields @{
        dog_id = $script:DogId
        title = "Manual smoke adoption post"
        content = "Manual full-feature smoke adoption post"
        status = "OPEN"
    } -Files @(
        [pscustomobject]@{
            FieldName = "profile_image"
            Path = $script:PostProfileImage
            MimeType = Get-ImageMimeType -Path $script:PostProfileImage
        }
    )
    Assert-Status -Response $response -ExpectedStatus 201
    $script:PostId = Get-PropertyValue -Object $response.Json -Name "post_id"
    Assert-NotNullOrEmpty -Value $script:PostId -Name "post.post_id"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "dog_id") -Expected $script:DogId -Name "post.dog_id"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "status") -Expected "OPEN" -Name "post.status"
    $script:Summary["markers"]["post_id"] = "present"
}

function Get-MyDogsAfterPost {
    $response = Invoke-Json -Method "GET" -Url (Join-Url $BaseUrl "dogs/me?page=0&size=50") -BearerToken $script:OwnerToken
    Assert-Status -Response $response -ExpectedStatus 200
    $item = Find-ItemByProperty -Items (Get-PropertyValue -Object $response.Json -Name "items") -Property "dog_id" -Expected $script:DogId
    Assert-NotNullOrEmpty -Value $item -Name "dogs_me_after_post.item"
    Assert-True -Value (Get-PropertyValue -Object $item -Name "has_active_post") -Name "dogs_me_after_post.has_active_post"
    Assert-False -Value (Get-PropertyValue -Object $item -Name "can_create_post") -Name "dogs_me_after_post.can_create_post"
    Assert-Equal -Actual (Get-PropertyValue -Object $item -Name "active_post_id") -Expected $script:PostId -Name "dogs_me_after_post.active_post_id"
}

function Verify-PublicAdoptionPrivacy {
    $list = Invoke-Json -Method "GET" -Url (Join-Url $BaseUrl "adoption-posts?status=OPEN&page=0&size=50")
    Assert-Status -Response $list -ExpectedStatus 200
    $item = Find-ItemByProperty -Items (Get-PropertyValue -Object $list.Json -Name "items") -Property "post_id" -Expected $script:PostId
    Assert-NotNullOrEmpty -Value $item -Name "public_post_list.item"
    Assert-NotHasProperty -Object $item -Name "nose_image_url" -Context "public adoption list item"
    Assert-NotHasProperty -Object $item -Name "payload" -Context "public adoption list item"
    Assert-NotHasProperty -Object $item -Name "vector" -Context "public adoption list item"
    Assert-NotNullOrEmpty -Value (Get-PropertyValue -Object $item -Name "profile_image_url") -Name "public_post_list.profile_image_url"
    $script:PostProfileImageUrl = [string](Get-PropertyValue -Object $item -Name "profile_image_url")

    $detail = Invoke-Json -Method "GET" -Url (Join-Url $BaseUrl "adoption-posts/$script:PostId")
    Assert-Status -Response $detail -ExpectedStatus 200
    Assert-Equal -Actual (Get-PropertyValue -Object $detail.Json -Name "post_id") -Expected $script:PostId -Name "public_post_detail.post_id"
    Assert-NotHasProperty -Object $detail.Json -Name "nose_image_url" -Context "public adoption detail"
    Assert-NotHasProperty -Object $detail.Json -Name "payload" -Context "public adoption detail"
    Assert-NotHasProperty -Object $detail.Json -Name "vector" -Context "public adoption detail"
    Assert-NotNullOrEmpty -Value (Get-PropertyValue -Object $detail.Json -Name "profile_image_url") -Name "public_post_detail.profile_image_url"
    $script:PostProfileImageUrl = [string](Get-PropertyValue -Object $detail.Json -Name "profile_image_url")
}

function Register-And-LoginAdopter {
    $script:AdopterEmail = New-SmokeEmail -Prefix "manual-smoke-adopter"
    $script:AdopterPassword = New-SmokePassword -Prefix "Adopter"
    Add-Secret $script:AdopterPassword
    $register = Invoke-Json -Method "POST" -Url (Join-Url $BaseUrl "auth/register") -BodyObject @{
        email = $script:AdopterEmail
        password = $script:AdopterPassword
        display_name = "Adopter1"
        contact_phone = "01022223333"
        region = "Daegu"
    }
    Assert-Status -Response $register -ExpectedStatus 201
    $script:AdopterUserId = Get-PropertyValue -Object $register.Json -Name "user_id"
    Assert-NotNullOrEmpty -Value $script:AdopterUserId -Name "adopter.user_id"
    Assert-NotHasProperty -Object $register.Json -Name "password_hash" -Context "adopter register response"

    $login = Invoke-Json -Method "POST" -Url (Join-Url $BaseUrl "auth/login") -BodyObject @{
        email = $script:AdopterEmail
        password = $script:AdopterPassword
    }
    Assert-Status -Response $login -ExpectedStatus 200
    $script:AdopterToken = [string](Get-PropertyValue -Object $login.Json -Name "access_token")
    Assert-NotNullOrEmpty -Value $script:AdopterToken -Name "adopter.access_token"
    Add-Secret $script:AdopterToken
    $script:Summary["markers"]["adopter_user_id"] = "present"
}

function Verify-LikeFlow {
    $like = Invoke-Json -Method "PUT" -Url (Join-Url $BaseUrl "adoption-posts/$script:PostId/like") -BearerToken $script:AdopterToken
    Assert-Status -Response $like -ExpectedStatus 200
    Assert-Equal -Actual (Get-PropertyValue -Object $like.Json -Name "post_id") -Expected $script:PostId -Name "like.post_id"
    Assert-True -Value (Get-PropertyValue -Object $like.Json -Name "liked") -Name "like.liked"

    $liked = Invoke-Json -Method "GET" -Url (Join-Url $BaseUrl "adoption-posts/liked/me?page=0&size=50") -BearerToken $script:AdopterToken
    Assert-Status -Response $liked -ExpectedStatus 200
    $item = Find-ItemByProperty -Items (Get-PropertyValue -Object $liked.Json -Name "items") -Property "post_id" -Expected $script:PostId
    Assert-NotNullOrEmpty -Value $item -Name "liked_list.item"
    Assert-Equal -Actual (Get-PropertyValue -Object $item -Name "dog_id") -Expected $script:DogId -Name "liked_list.dog_id"
    Assert-True -Value (Get-PropertyValue -Object $item -Name "liked") -Name "liked_list.liked"
    Assert-NotHasProperty -Object $item -Name "nose_image_url" -Context "liked list item"

    $unlike = Invoke-Json -Method "DELETE" -Url (Join-Url $BaseUrl "adoption-posts/$script:PostId/like") -BearerToken $script:AdopterToken
    Assert-Status -Response $unlike -ExpectedStatus 200
    Assert-False -Value (Get-PropertyValue -Object $unlike.Json -Name "liked") -Name "unlike.liked"

    $relike = Invoke-Json -Method "PUT" -Url (Join-Url $BaseUrl "adoption-posts/$script:PostId/like") -BearerToken $script:AdopterToken
    Assert-Status -Response $relike -ExpectedStatus 200
    Assert-True -Value (Get-PropertyValue -Object $relike.Json -Name "liked") -Name "relike.liked"
}

function Test-FirebaseDisabledResponse {
    param([Parameter(Mandatory = $true)][object]$Response)

    if ([int]$Response.StatusCode -ne 503) {
        return $false
    }
    $isDisabled = "$(Get-PropertyValue -Object $Response.Json -Name "error_code")" -eq "FIREBASE_DISABLED"
    if ($isDisabled) {
        Add-ApiAssertion -Status "PASS" -Description "Firebase disabled response" -Expected "503 FIREBASE_DISABLED" -Actual "503 FIREBASE_DISABLED"
        Set-CurrentApiResult -Result "EXPECTED_DISABLED"
    }
    return $isDisabled
}

function Invoke-EnabledChatFlow {
    param([AllowNull()][object]$ExistingTokenResponse = $null)

    $tokenResponse = $ExistingTokenResponse
    if ($null -eq $tokenResponse) {
        $tokenResponse = Invoke-Json -Method "POST" -Url (Join-Url $BaseUrl "firebase/custom-token") -BearerToken $script:AdopterToken
        Assert-Status -Response $tokenResponse -ExpectedStatus 200
    }
    $customToken = [string](Get-PropertyValue -Object $tokenResponse.Json -Name "firebase_custom_token")
    Assert-NotNullOrEmpty -Value $customToken -Name "firebase.firebase_custom_token"
    Add-Secret $customToken

    $tokenToRegister = $FcmToken
    if ([string]::IsNullOrWhiteSpace($tokenToRegister)) {
        $tokenToRegister = "manual-smoke-fcm-token-$(New-SmokeSuffix)"
    }
    Add-Secret $tokenToRegister
    $fcm = Invoke-Json -Method "PUT" -Url (Join-Url $BaseUrl "users/me/fcm-token") -BearerToken $script:AdopterToken -BodyObject @{
        fcm_token = $tokenToRegister
        platform = "WEB"
    }
    Assert-Status -Response $fcm -ExpectedStatus 200
    Assert-True -Value (Get-PropertyValue -Object $fcm.Json -Name "registered") -Name "fcm.registered"

    $room = Invoke-Json -Method "POST" -Url (Join-Url $BaseUrl "chat/rooms") -BearerToken $script:AdopterToken -BodyObject @{
        post_id = [long]$script:PostId
    }
    Assert-Status -Response $room -ExpectedStatus 201
    $script:ChatRoomId = [string](Get-PropertyValue -Object $room.Json -Name "room_id")
    Assert-NotNullOrEmpty -Value $script:ChatRoomId -Name "chat.room_id"

    $rooms = Invoke-Json -Method "GET" -Url (Join-Url $BaseUrl "chat/rooms?page=0&size=20") -BearerToken $script:AdopterToken
    Assert-Status -Response $rooms -ExpectedStatus 200
    $roomItem = Find-ItemByProperty -Items (Get-PropertyValue -Object $rooms.Json -Name "items") -Property "room_id" -Expected $script:ChatRoomId
    Assert-NotNullOrEmpty -Value $roomItem -Name "chat.room_list.item"

    $message = Invoke-Json -Method "POST" -Url (Join-Url $BaseUrl "chat/rooms/$script:ChatRoomId/messages") -BearerToken $script:AdopterToken -BodyObject @{
        text = "manual smoke test message"
        client_message_id = "manual-smoke-$(New-SmokeSuffix)"
    }
    Assert-Status -Response $message -ExpectedStatus 201
    Assert-NotNullOrEmpty -Value (Get-PropertyValue -Object $message.Json -Name "message_id") -Name "chat.message_id"

    $read = Invoke-Json -Method "PATCH" -Url (Join-Url $BaseUrl "chat/rooms/$script:ChatRoomId/read") -BearerToken $script:AdopterToken
    Assert-Status -Response $read -ExpectedStatus 200
    Assert-True -Value (Get-PropertyValue -Object $read.Json -Name "read") -Name "chat.read"
}

function Invoke-ChatFlow {
    if ($FirebaseMode -eq "skip") {
        Skip-Scenario -Name "chat" -Note "Skipped by -FirebaseMode skip." -Optional $true
        return
    }

    Invoke-Scenario -Name "chat" -Optional -Command {
        if ($FirebaseMode -eq "disabled") {
            $disabled = Invoke-Json -Method "POST" -Url (Join-Url $BaseUrl "firebase/custom-token") -BearerToken $script:AdopterToken
            if (-not (Test-FirebaseDisabledResponse -Response $disabled)) {
                Add-ApiAssertion -Status "FAIL" -Description "Firebase disabled response" -Expected "503 FIREBASE_DISABLED" -Actual "$($disabled.StatusCode) $(Get-PropertyValue -Object $disabled.Json -Name "error_code")"
                Fail-Assert "Firebase disabled mode expected 503 FIREBASE_DISABLED, actual HTTP $($disabled.StatusCode)."
            }
            $script:Summary["markers"]["chat_result"] = "FIREBASE_DISABLED expected PASS"
            return
        }

        if ($FirebaseMode -eq "enabled") {
            Invoke-EnabledChatFlow
            $script:Summary["markers"]["chat_result"] = "enabled PASS"
            return
        }

        $probe = Invoke-Json -Method "POST" -Url (Join-Url $BaseUrl "firebase/custom-token") -BearerToken $script:AdopterToken
        if (Test-FirebaseDisabledResponse -Response $probe) {
            $script:Summary["validation_notes"] += "Firebase auto mode observed FIREBASE_DISABLED and treated disabled runtime as PASS."
            $script:Summary["markers"]["chat_result"] = "FIREBASE_DISABLED expected PASS"
            return
        }
        Assert-Status -Response $probe -ExpectedStatus 200
        Invoke-EnabledChatFlow -ExistingTokenResponse $probe
        $script:Summary["markers"]["chat_result"] = "enabled PASS"
    }
}

function Verify-Handover {
    $beforeSnapshot = Get-DogDbSnapshotOptional -DogId $script:DogId
    if (-not $beforeSnapshot.Available) {
        $script:Summary["validation_notes"] += "Handover DB side-effect check skipped: $($beforeSnapshot.Note)"
    }

    $response = Invoke-Multipart -Method "POST" -Url (Join-Url $BaseUrl "adoption-posts/$script:PostId/handover-verifications") -BearerToken $script:AdopterToken -Files @(
        [pscustomobject]@{
            FieldName = "nose_image"
            Path = $script:HandoverImage
            MimeType = Get-ImageMimeType -Path $script:HandoverImage
        }
    )
    Assert-Status -Response $response -ExpectedStatus 200
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "expected_dog_id") -Expected $script:DogId -Name "handover.expected_dog_id"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "dimension") -Expected $ExpectedVectorDimension -Name "handover.dimension"
    $decision = [string](Get-PropertyValue -Object $response.Json -Name "decision")
    $matched = Get-PropertyValue -Object $response.Json -Name "matched"
    $script:Summary["markers"]["handover_decision"] = $decision
    $script:Summary["markers"]["handover_matched"] = $matched
    $script:Summary["counts"]["handover_similarity_score"] = Get-PropertyValue -Object $response.Json -Name "similarity_score"
    if ($decision -eq "MATCHED") {
        Assert-True -Value $matched -Name "handover.matched"
    } elseif ($decision -eq "AMBIGUOUS" -and $AllowAmbiguousHandover) {
        $script:Summary["validation_notes"] += "Handover returned AMBIGUOUS and was accepted because -AllowAmbiguousHandover was set."
    } else {
        Fail-Assert "handover decision must be MATCHED$(if ($AllowAmbiguousHandover) { ' or AMBIGUOUS' } else { '' }). Actual: $decision"
    }
    Assert-NotHasProperty -Object $response.Json -Name "nose_image_url" -Context "handover response"
    Assert-NotHasProperty -Object $response.Json -Name "payload" -Context "handover response"
    Assert-NotHasProperty -Object $response.Json -Name "vector" -Context "handover response"
    Assert-NotHasProperty -Object $response.Json -Name "author_user_id" -Context "handover response"

    if ($beforeSnapshot.Available) {
        $afterSnapshot = Get-DogDbSnapshotOptional -DogId $script:DogId
        if (-not $afterSnapshot.Available) {
            $message = "Handover DB side-effect after snapshot skipped: $($afterSnapshot.Note)"
            if ($StopOnOptionalFailure) {
                Fail-Assert $message
            }
            $script:Summary["validation_notes"] += $message
        } else {
            Assert-Equal -Actual $afterSnapshot.nose_images -Expected $beforeSnapshot.nose_images -Name "handover.dog_images.side_effect"
            Assert-Equal -Actual $afterSnapshot.verification_logs -Expected $beforeSnapshot.verification_logs -Name "handover.verification_logs.side_effect"
            Assert-Equal -Actual $afterSnapshot.dog_status -Expected $beforeSnapshot.dog_status -Name "handover.dog_status.side_effect"
            $script:Summary["counts"]["handover_created_dog_images"] = $afterSnapshot.nose_images - $beforeSnapshot.nose_images
            $script:Summary["counts"]["handover_created_verification_logs"] = $afterSnapshot.verification_logs - $beforeSnapshot.verification_logs
        }
    }
}

function Complete-Adoption {
    $beforeSnapshot = Get-DogDbSnapshotOptional -DogId $script:DogId
    $response = Invoke-Json -Method "PATCH" -Url (Join-Url $BaseUrl "adoption-posts/$script:PostId/status") -BearerToken $script:OwnerToken -BodyObject @{
        status = "COMPLETED"
        adopter_user_id = [long]$script:AdopterUserId
    }
    Assert-Status -Response $response -ExpectedStatus 200
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "status") -Expected "COMPLETED" -Name "completion.status"
    Assert-Equal -Actual (Get-PropertyValue -Object $response.Json -Name "adopter_user_id") -Expected $script:AdopterUserId -Name "completion.adopter_user_id"
    Assert-NotNullOrEmpty -Value (Get-PropertyValue -Object $response.Json -Name "adopted_at") -Name "completion.adopted_at"

    $ownerDetail = Invoke-Json -Method "GET" -Url (Join-Url $BaseUrl "dogs/$script:DogId") -BearerToken $script:OwnerToken
    Assert-Status -Response $ownerDetail -ExpectedStatus 200
    Assert-Equal -Actual (Get-PropertyValue -Object $ownerDetail.Json -Name "status") -Expected "ADOPTED" -Name "completion.dog_status"

    if ($beforeSnapshot.Available) {
        $afterSnapshot = Get-DogDbSnapshotOptional -DogId $script:DogId
        if ($afterSnapshot.Available) {
            Assert-Equal -Actual $afterSnapshot.dog_status -Expected "ADOPTED" -Name "db.dogs.status_after_completion"
            Assert-Equal -Actual $afterSnapshot.owner_user_id -Expected $beforeSnapshot.owner_user_id -Name "db.dogs.owner_user_id_unchanged"
            $script:Summary["counts"]["dogs_status_after_completion"] = $afterSnapshot.dog_status
            $script:Summary["counts"]["dogs_owner_user_id_unchanged"] = ($afterSnapshot.owner_user_id -eq $beforeSnapshot.owner_user_id)
        } else {
            $script:Summary["validation_notes"] += "Adoption completion DB snapshot skipped after completion: $($afterSnapshot.Note)"
        }
    } else {
        $script:Summary["validation_notes"] += "Adoption completion DB owner check skipped: $($beforeSnapshot.Note)"
    }
}

function Verify-AdoptedDogs {
    $response = Invoke-Json -Method "GET" -Url (Join-Url $BaseUrl "dogs/adopted/me?page=0&size=50") -BearerToken $script:AdopterToken
    Assert-Status -Response $response -ExpectedStatus 200
    $item = Find-ItemByProperty -Items (Get-PropertyValue -Object $response.Json -Name "items") -Property "dog_id" -Expected $script:DogId
    Assert-NotNullOrEmpty -Value $item -Name "adopted_dogs.item"
    Assert-Equal -Actual (Get-PropertyValue -Object $item -Name "post_id") -Expected $script:PostId -Name "adopted_dogs.post_id"
    Assert-Equal -Actual (Get-PropertyValue -Object $item -Name "status") -Expected "ADOPTED" -Name "adopted_dogs.status"
    Assert-NotNullOrEmpty -Value (Get-PropertyValue -Object $item -Name "profile_image_url") -Name "adopted_dogs.profile_image_url"
    Assert-NotHasProperty -Object $item -Name "nose_image_url" -Context "adopted dog list item"
    Assert-NotHasProperty -Object $item -Name "author_user_id" -Context "adopted dog list item"
    Assert-NotHasProperty -Object $item -Name "adopter_user_id" -Context "adopted dog list item"
}

function Verify-FileServing {
    Assert-NotNullOrEmpty -Value $script:OwnerProfileImageUrl -Name "owner_profile_image_url"
    Test-FileUrl -MaybeRelativeUrl $script:OwnerProfileImageUrl -Name "owner_profile_image"
    Assert-NotNullOrEmpty -Value $script:PostProfileImageUrl -Name "post_profile_image_url"
    Test-FileUrl -MaybeRelativeUrl $script:PostProfileImageUrl -Name "post_profile_image"
    Assert-NotNullOrEmpty -Value $script:OwnerNoseImageUrl -Name "owner_nose_image_url"
    Test-FileUrl -MaybeRelativeUrl $script:OwnerNoseImageUrl -Name "owner_nose_image"
}

try {
    Initialize-RuntimeIfRequested
    Invoke-Scenario -Name "preflight" -Command { Invoke-Preflight }
    Invoke-Scenario -Name "initial_runtime_cleanliness" -Command { Verify-CleanRuntimeData }
    Invoke-Scenario -Name "owner_register_multipart" -Command { Register-Owner }
    Invoke-Scenario -Name "owner_login" -Command { Login-Owner }
    Invoke-Scenario -Name "users_me" -Command { Get-OwnerMe }
    Invoke-Scenario -Name "profile_update" -Command { Update-OwnerProfile }
    Invoke-Scenario -Name "profile_image_update" -Command { Update-OwnerProfileImage }
    Invoke-Scenario -Name "password_change" -Command { Change-OwnerPassword }
    Invoke-PasswordResetFlow
    Invoke-Scenario -Name "dog_registration" -Command { Register-Dog }
    Invoke-Scenario -Name "dogs_me_before_post" -Command { Get-MyDogsBeforePost }
    Invoke-Scenario -Name "owner_dog_detail" -Command { Get-OwnerDogDetail }
    Invoke-Scenario -Name "adoption_post_create" -Command { Create-AdoptionPost }
    Invoke-Scenario -Name "dogs_me_after_post" -Command { Get-MyDogsAfterPost }
    Invoke-Scenario -Name "public_adoption_privacy" -Command { Verify-PublicAdoptionPrivacy }
    Invoke-Scenario -Name "adopter_register_login" -Command { Register-And-LoginAdopter }
    Invoke-Scenario -Name "likes" -Command { Verify-LikeFlow }
    Invoke-ChatFlow
    Invoke-Scenario -Name "handover_verification" -Command { Verify-Handover }
    Invoke-Scenario -Name "adoption_completion" -Command { Complete-Adoption }
    Invoke-Scenario -Name "adopted_dogs" -Command { Verify-AdoptedDogs }
    Invoke-Scenario -Name "file_serving" -Command { Verify-FileServing }
    if ($RunReconciliation) {
        Invoke-Scenario -Name "reconciliation" -Command { Invoke-Reconciliation }
    } else {
        Skip-Scenario -Name "reconciliation" -Note "Skipped with -RunReconciliation:`$false."
    }

    Save-Summary
    Save-ApiTranscript
    Write-Host ""
    Write-Host "MANUAL FULL FEATURE SMOKE PASSED"
    exit 0
} catch {
    $message = Redact-Text $_.Exception.Message
    Write-Error $message
    try {
        Save-Summary
        Save-ApiTranscript
    } catch {
        Write-Warning "Could not write sanitized evidence after failure: $(Redact-Text $_.Exception.Message)"
    }
    if ($message.StartsWith("CONFIG:")) {
        exit 2
    }
    exit 1
} finally {
    Stop-RuntimeIfRequested
}
