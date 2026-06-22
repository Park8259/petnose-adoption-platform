#Requires -Version 7.0
<#
.SYNOPSIS
Runs a profile-first + YOLO demo-runtime API smoke.

.DESCRIPTION
This script verifies the opt-in profile-first product flow:

  1. POST /api/dogs/profile-draft
  2. POST /api/dogs/{dog_id}/nose-verification
  3. adoption post creation for a successfully registered dog
  4. duplicate handling and duplicate post-creation blocking
  5. backward-compatible POST /api/dogs/register fallback

It calls public HTTP APIs only. It does not reset DB/Qdrant, mutate internal
storage directly, or write raw image bytes, JWTs, passwords, vectors, or crops
to evidence.

Use -RequireNormalRegistration when the target runtime has a clean collection
or a unique fixture set and the pass path must prove Qdrant upsert through a
REGISTERED result. Without that switch, an already-populated demo runtime may
return DUPLICATE_SUSPECTED while still proving the profile-match and duplicate
contracts.

Do not delete/reset existing Qdrant collections or Docker volumes to create
clean evidence. For g4dn/develop validation, set QDRANT_COLLECTION to a
temporary collection such as dog_nose_embeddings_profile_first_demo_<utcstamp>
and redeploy the profile-first YOLO demo runtime before running this script.
#>

[CmdletBinding()]
param(
    [string]$RootUrl = "http://localhost",
    [string]$BaseUrl = "http://localhost/api",

    [string]$ProfileImagePath,

    [string]$NoseImageDir,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$MismatchNoseImageDir = "",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$PostProfileImagePath = "",

    [ValidateSet("auto", "jpg", "jpeg", "png")]
    [string]$NoseImageExtension = "auto",

    [ValidateRange(1, 20)]
    [int]$NoseImageCount = 5,

    [bool]$RequirePreviewExtracted = $true,
    [switch]$RequireNormalRegistration,
    [switch]$WriteEvidence,

    [string]$OutputDir = "docs/ops-evidence/profile-first-yolo-demo-smoke-local",
    [string]$SummaryPath = "docs/ops-evidence/profile-first-yolo-demo-smoke-local/summary.json",
    [string]$ApiTranscriptPath = "docs/ops-evidence/profile-first-yolo-demo-smoke-local/api-transcript.md",

    [switch]$Help
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Show-Usage {
    Write-Host @"
Profile-first YOLO demo smoke

Required:
  -ProfileImagePath <dog profile image>
  -NoseImageDir <directory containing 1..5 jpg/jpeg/png close-up nose images>

Recommended g4dn demo:
  pwsh -NoProfile -File .\scripts\profile-first-yolo-demo-smoke.ps1 \
    -RootUrl "http://localhost:18080" \
    -BaseUrl "http://localhost:18080/api" \
    -ProfileImagePath "C:\tmp\fixtures\profile\profile1.png" \
    -NoseImageDir "C:\tmp\fixtures\nose" \
    -MismatchNoseImageDir "C:\tmp\fixtures\other-dog-nose" \
    -RequireNormalRegistration \
    -WriteEvidence

Notes:
  - Use a clean Qdrant collection or unique fixture set with -RequireNormalRegistration.
  - Do not delete/reset existing Qdrant collections or Docker volumes for clean evidence.
  - For clean g4dn evidence, set QDRANT_COLLECTION to a temporary collection
    such as dog_nose_embeddings_profile_first_demo_20260622104732 and redeploy.
  - Raw image bytes, JWTs, passwords, vectors, and crop_base64 are never written.
"@
}

if ($Help) {
    Show-Usage
    exit 0
}

function Fail-Config {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw "[CONFIG] $Message"
}

if ([string]::IsNullOrWhiteSpace($ProfileImagePath)) {
    Fail-Config "Provide -ProfileImagePath or run with -Help."
}

if ([string]::IsNullOrWhiteSpace($NoseImageDir)) {
    Fail-Config "Provide -NoseImageDir or run with -Help."
}

function Join-Url {
    param(
        [Parameter(Mandatory = $true)][string]$Base,
        [Parameter(Mandatory = $true)][string]$Path
    )
    return $Base.TrimEnd("/") + "/" + $Path.TrimStart("/")
}

function Resolve-InputPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return (Join-Path (Get-Location).Path $Path)
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
    Fail-Config "Could not find image $Index with extension [$($extensions -join ', ')] in $Directory"
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

function Get-FileEvidence {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path
    $stream = [System.IO.File]::OpenRead($item.FullName)
    try {
        $sha = [System.Security.Cryptography.SHA256]::HashData($stream)
    } finally {
        $stream.Dispose()
    }
    return [ordered]@{
        basename = $item.Name
        size_bytes = $item.Length
        sha256 = ([Convert]::ToHexString($sha)).ToLowerInvariant()
        content_type = Get-ImageMimeType -Path $item.FullName
    }
}

function Resolve-NoseImages {
    param([Parameter(Mandatory = $true)][string]$Directory)
    $resolvedDir = Resolve-InputPath $Directory
    if (-not (Test-Path -LiteralPath $resolvedDir -PathType Container)) {
        Fail-Config "NoseImageDir not found: $Directory"
    }

    $images = @()
    for ($i = 1; $i -le $NoseImageCount; $i++) {
        $images += Find-IndexedImage -Directory $resolvedDir -Index $i -Extension $NoseImageExtension
    }
    return $images
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Actual = $null
    )
    if (-not $Value) {
        throw "[ASSERT] $Name failed. Actual: $($Actual | ConvertTo-Json -Depth 8 -Compress)"
    }
}

function Redact-JsonText {
    param([AllowNull()][object]$Object)
    if ($null -eq $Object) {
        return "null"
    }
    $json = $Object | ConvertTo-Json -Depth 30
    $json = $json -replace '"access_token"\s*:\s*"[^"]+"', '"access_token":"[REDACTED]"'
    $json = $json -replace '"token_type"\s*:\s*"[^"]+"', '"token_type":"[REDACTED]"'
    $json = $json -replace '"password"\s*:\s*"[^"]+"', '"password":"[REDACTED]"'
    $json = $json -replace '"current_password"\s*:\s*"[^"]+"', '"current_password":"[REDACTED]"'
    $json = $json -replace '"new_password"\s*:\s*"[^"]+"', '"new_password":"[REDACTED]"'
    $json = $json -replace '"crop_base64"\s*:\s*"[^"]+"', '"crop_base64":"[REDACTED]"'
    $json = $json -replace '"vector"\s*:\s*\[[^\]]*\]', '"vector":"[REDACTED]"'
    $json = $json -replace '"user_id"\s*:\s*\d+', '"user_id":"[REDACTED_FIXTURE_ID]"'
    $json = $json -replace '"dog_id"\s*:\s*"[^"]+"', '"dog_id":"[REDACTED_FIXTURE_ID]"'
    $json = $json -replace '"post_id"\s*:\s*\d+', '"post_id":"[REDACTED_FIXTURE_ID]"'
    return $json
}

function Parse-JsonOrNull {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    return $Text | ConvertFrom-Json
}

$script:Client = [System.Net.Http.HttpClient]::new()
$script:Transcript = New-Object 'System.Collections.Generic.List[string]'

function Add-Transcript {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][int]$Status,
        [AllowNull()][object]$Response,
        [AllowNull()][object]$RequestSummary = $null
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add("## $Name") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Request: ``$Method $Url``") | Out-Null
    $lines.Add("- Response: $Status") | Out-Null
    if ($null -ne $RequestSummary) {
        $lines.Add("") | Out-Null
        $lines.Add("Request summary:") | Out-Null
        $lines.Add("") | Out-Null
        $lines.Add("``````json") | Out-Null
        $lines.Add((Redact-JsonText $RequestSummary)) | Out-Null
        $lines.Add("``````") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("Response body:") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("``````json") | Out-Null
    $lines.Add((Redact-JsonText $Response)) | Out-Null
    $lines.Add("``````") | Out-Null
    $script:Transcript.Add(($lines -join "`n")) | Out-Null
}

function Invoke-JsonApi {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [AllowNull()][object]$Body,
        [AllowNull()][AllowEmptyString()][string]$Token = ""
    )

    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Url)
    $request.Headers.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new("application/json"))
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $Token)
    }
    if ($null -ne $Body) {
        $jsonBody = $Body | ConvertTo-Json -Depth 20
        $request.Content = [System.Net.Http.StringContent]::new($jsonBody, [System.Text.Encoding]::UTF8, "application/json")
    }

    $response = $script:Client.SendAsync($request).GetAwaiter().GetResult()
    $bodyText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $json = Parse-JsonOrNull $bodyText
    Add-Transcript -Name $Name -Method $Method -Url $Url -Status ([int]$response.StatusCode) -Response $json -RequestSummary $Body
    return [pscustomobject]@{ Status = [int]$response.StatusCode; Json = $json; BodyText = $bodyText }
}

function Invoke-MultipartApi {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [hashtable]$Fields = @{},
        [object[]]$Files = @(),
        [AllowNull()][AllowEmptyString()][string]$Token = ""
    )

    $content = [System.Net.Http.MultipartFormDataContent]::new()
    $streams = New-Object 'System.Collections.Generic.List[System.IDisposable]'
    $requestSummary = [ordered]@{ fields = [ordered]@{}; files = @() }
    try {
        foreach ($key in $Fields.Keys) {
            if ($null -eq $Fields[$key]) {
                continue
            }
            $content.Add([System.Net.Http.StringContent]::new([string]$Fields[$key], [System.Text.Encoding]::UTF8), [string]$key)
            $requestSummary.fields[$key] = $Fields[$key]
        }

        foreach ($file in $Files) {
            $path = [string]$file.Path
            $fieldName = [string]$file.FieldName
            $stream = [System.IO.File]::OpenRead($path)
            $streams.Add($stream) | Out-Null
            $fileContent = [System.Net.Http.StreamContent]::new($stream)
            $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse((Get-ImageMimeType -Path $path))
            $content.Add($fileContent, $fieldName, [System.IO.Path]::GetFileName($path))
            $requestSummary.files += ([ordered]@{ field = $fieldName } + (Get-FileEvidence -Path $path))
        }

        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Url)
        $request.Headers.Accept.Add([System.Net.Http.Headers.MediaTypeWithQualityHeaderValue]::new("application/json"))
        if (-not [string]::IsNullOrWhiteSpace($Token)) {
            $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $Token)
        }
        $request.Content = $content

        $response = $script:Client.SendAsync($request).GetAwaiter().GetResult()
        $bodyText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $json = Parse-JsonOrNull $bodyText
        Add-Transcript -Name $Name -Method $Method -Url $Url -Status ([int]$response.StatusCode) -Response $json -RequestSummary $requestSummary
        return [pscustomobject]@{ Status = [int]$response.StatusCode; Json = $json; BodyText = $bodyText }
    } finally {
        foreach ($stream in $streams) {
            $stream.Dispose()
        }
        $content.Dispose()
    }
}

function New-AuthFixture {
    param([Parameter(Mandatory = $true)][string]$Label)
    $email = "profile-first-$Label-$(Get-Date -Format yyyyMMddHHmmss)-$([guid]::NewGuid().ToString('N').Substring(0,8))@example.test"
    $password = "password123"
    $register = Invoke-JsonApi -Name "$Label-register" -Method "POST" -Url (Join-Url $BaseUrl "auth/register") -Body ([ordered]@{
        email = $email
        password = $password
        display_name = "ProfileFirst$Label"
        contact_phone = "01012345678"
        region = "Seoul"
    })
    Assert-True -Name "$Label register status" -Value ($register.Status -eq 201) -Actual $register.Json
    $login = Invoke-JsonApi -Name "$Label-login" -Method "POST" -Url (Join-Url $BaseUrl "auth/login") -Body ([ordered]@{
        email = $email
        password = $password
    })
    Assert-True -Name "$Label login status" -Value ($login.Status -eq 200) -Actual $login.Json
    return [pscustomobject]@{ Email = $email; Token = [string]$login.Json.access_token }
}

function New-NoseFileParts {
    param(
        [Parameter(Mandatory = $true)][string[]]$Paths,
        [string]$FieldName = "nose_images"
    )
    return @($Paths | ForEach-Object { [pscustomobject]@{ FieldName = $FieldName; Path = $_ } })
}

function New-ProfileDraft {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$DogName
    )
    $fields = @{
        name = $DogName
        breed = "Maltese"
        gender = "MALE"
        birth_date = "2024-01-01"
        description = "Profile-first YOLO demo smoke"
    }
    $files = @([pscustomobject]@{ FieldName = "profile_image"; Path = $script:ProfileImageResolved })
    $response = Invoke-MultipartApi -Name $Name -Method "POST" -Url (Join-Url $BaseUrl "dogs/profile-draft") -Fields $fields -Files $files -Token $Token
    Assert-True -Name "$Name status" -Value ($response.Status -eq 201) -Actual $response.Json
    Assert-True -Name "$Name dog status" -Value ([string]$response.Json.status -eq "PENDING") -Actual $response.Json.status
    Assert-True -Name "$Name dog_id" -Value (-not [string]::IsNullOrWhiteSpace([string]$response.Json.dog_id)) -Actual $response.Json
    if ($RequirePreviewExtracted) {
        Assert-True -Name "$Name preview extracted" -Value ([bool]$response.Json.profile_nose_preview.extracted) -Actual $response.Json.profile_nose_preview
        Assert-True -Name "$Name preview crop width" -Value ([int]$response.Json.profile_nose_preview.crop_width -eq 224) -Actual $response.Json.profile_nose_preview
    }
    return $response
}

function Invoke-NoseVerification {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$DogId,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string[]]$Images
    )
    return Invoke-MultipartApi `
        -Name $Name `
        -Method "POST" `
        -Url (Join-Url $BaseUrl "dogs/$DogId/nose-verification") `
        -Files (New-NoseFileParts -Paths $Images) `
        -Token $Token
}

function New-AdoptionPost {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$DogId,
        [Parameter(Mandatory = $true)][string]$Token
    )
    $fields = @{
        dog_id = $DogId
        title = "Profile-first YOLO demo post"
        content = "Profile-first YOLO demo smoke adoption post"
        status = "OPEN"
    }
    $files = @([pscustomobject]@{ FieldName = "profile_image"; Path = $script:PostProfileImageResolved })
    return Invoke-MultipartApi -Name $Name -Method "POST" -Url (Join-Url $BaseUrl "adoption-posts") -Fields $fields -Files $files -Token $Token
}

$script:StartedAt = (Get-Date).ToUniversalTime()
$script:ProfileImageResolved = Resolve-InputPath $ProfileImagePath
if (-not (Test-Path -LiteralPath $script:ProfileImageResolved -PathType Leaf)) {
    Fail-Config "ProfileImagePath not found: $ProfileImagePath"
}
$script:PostProfileImageResolved = if ([string]::IsNullOrWhiteSpace($PostProfileImagePath)) {
    $script:ProfileImageResolved
} else {
    Resolve-InputPath $PostProfileImagePath
}
if (-not (Test-Path -LiteralPath $script:PostProfileImageResolved -PathType Leaf)) {
    Fail-Config "PostProfileImagePath not found: $PostProfileImagePath"
}

$registrationImages = Resolve-NoseImages -Directory $NoseImageDir
$mismatchImages = @()
if (-not [string]::IsNullOrWhiteSpace($MismatchNoseImageDir)) {
    $mismatchImages = Resolve-NoseImages -Directory $MismatchNoseImageDir
}

$summary = [ordered]@{
    checked_at = $script:StartedAt.ToString("o")
    root_url = $RootUrl
    base_url = $BaseUrl
    modes = [ordered]@{
        require_preview_extracted = [bool]$RequirePreviewExtracted
        require_normal_registration = [bool]$RequireNormalRegistration
        mismatch_flow_requested = $mismatchImages.Count -gt 0
    }
    fixture = [ordered]@{
        profile_image = Get-FileEvidence -Path $script:ProfileImageResolved
        post_profile_image = Get-FileEvidence -Path $script:PostProfileImageResolved
        registration_images = @($registrationImages | ForEach-Object { Get-FileEvidence -Path $_ })
        mismatch_images = @($mismatchImages | ForEach-Object { Get-FileEvidence -Path $_ })
    }
    scenarios = [ordered]@{}
    markers = [ordered]@{}
}

try {
    $health = Invoke-JsonApi -Name "actuator-health" -Method "GET" -Url (Join-Url $RootUrl "actuator/health") -Body $null
    Assert-True -Name "actuator health status" -Value ($health.Status -eq 200) -Actual $health.Json
    Assert-True -Name "actuator health UP" -Value ([string]$health.Json.status -eq "UP") -Actual $health.Json.status
    $summary.scenarios["actuator_health"] = "PASS"

    $owner = New-AuthFixture -Label "owner"

    if ($mismatchImages.Count -gt 0) {
        $mismatchDraft = New-ProfileDraft -Name "profile-draft-mismatch" -Token $owner.Token -DogName "Mismatch Draft"
        $mismatchDogId = [string]$mismatchDraft.Json.dog_id
        $mismatch = Invoke-NoseVerification -Name "nose-verification-mismatch" -DogId $mismatchDogId -Token $owner.Token -Images $mismatchImages
        Assert-True -Name "mismatch verify status" -Value ($mismatch.Status -eq 200) -Actual $mismatch.Json
        Assert-True -Name "mismatch profile allowed" -Value ([bool]$mismatch.Json.profile_match_allowed -eq $false) -Actual $mismatch.Json
        Assert-True -Name "mismatch registration allowed" -Value ([bool]$mismatch.Json.registration_allowed -eq $false) -Actual $mismatch.Json
        Assert-True -Name "mismatch dog remains pending" -Value ([string]$mismatch.Json.status -eq "PENDING") -Actual $mismatch.Json.status

        $detail = Invoke-JsonApi -Name "mismatch-dog-detail" -Method "GET" -Url (Join-Url $BaseUrl "dogs/$mismatchDogId") -Body $null -Token $owner.Token
        Assert-True -Name "mismatch detail status" -Value ($detail.Status -eq 200) -Actual $detail.Json
        Assert-True -Name "mismatch detail pending" -Value ([string]$detail.Json.status -eq "PENDING") -Actual $detail.Json.status
        Assert-True -Name "mismatch detail no nose image" -Value ($null -eq $detail.Json.nose_image_url) -Actual $detail.Json
        Assert-True -Name "mismatch detail cannot create post" -Value ([bool]$detail.Json.can_create_post -eq $false) -Actual $detail.Json

        $blocked = New-AdoptionPost -Name "mismatch-post-blocked" -DogId $mismatchDogId -Token $owner.Token
        Assert-True -Name "mismatch post blocked status" -Value ($blocked.Status -in @(400, 409)) -Actual $blocked.Json
        $summary.markers["mismatch_failure_reason"] = [string]$mismatch.Json.failure_reason
        $summary.scenarios["profile_mismatch_no_api_side_effects"] = "PASS"
    } else {
        $summary.scenarios["profile_mismatch_no_api_side_effects"] = "NOT_RUN"
    }

    $passDraft = New-ProfileDraft -Name "profile-draft-pass" -Token $owner.Token -DogName "Profile Pass Dog"
    $passDogId = [string]$passDraft.Json.dog_id
    $pass = Invoke-NoseVerification -Name "nose-verification-pass" -DogId $passDogId -Token $owner.Token -Images $registrationImages
    Assert-True -Name "pass verify status" -Value ($pass.Status -eq 200) -Actual $pass.Json
    Assert-True -Name "pass profile allowed" -Value ([bool]$pass.Json.profile_match_allowed -eq $true) -Actual $pass.Json
    Assert-True -Name "pass profile status" -Value ([string]$pass.Json.profile_match_status -eq "PASSED") -Actual $pass.Json
    Assert-True -Name "pass dimension" -Value ([int]$pass.Json.dimension -eq 2048) -Actual $pass.Json.dimension
    Assert-True -Name "pass model" -Value ([string]$pass.Json.model -like "dog-nose-identification2*") -Actual $pass.Json.model

    if ($RequireNormalRegistration) {
        Assert-True -Name "pass registration allowed" -Value ([bool]$pass.Json.registration_allowed -eq $true) -Actual $pass.Json
        Assert-True -Name "pass dog registered" -Value ([string]$pass.Json.status -eq "REGISTERED") -Actual $pass.Json
        Assert-True -Name "pass qdrant reference count" -Value ([int]$pass.Json.reference_count -eq 5) -Actual $pass.Json
    } else {
        Assert-True -Name "pass final status allowed set" -Value ([string]$pass.Json.status -in @("REGISTERED", "DUPLICATE_SUSPECTED", "REVIEW_REQUIRED")) -Actual $pass.Json
    }
    $summary.markers["profile_pass_status"] = [string]$pass.Json.status
    $summary.markers["profile_pass_registration_allowed"] = [bool]$pass.Json.registration_allowed
    $summary.scenarios["profile_match_pass"] = "PASS"

    if ([bool]$pass.Json.registration_allowed) {
        $post = New-AdoptionPost -Name "profile-pass-post-create" -DogId $passDogId -Token $owner.Token
        Assert-True -Name "profile pass post created" -Value ($post.Status -eq 201) -Actual $post.Json
        $summary.scenarios["profile_pass_post_creation"] = "PASS"
    } else {
        $summary.scenarios["profile_pass_post_creation"] = "SKIP_DUPLICATE_OR_REVIEW_RESULT"
    }

    $dupDraft = New-ProfileDraft -Name "profile-draft-duplicate" -Token $owner.Token -DogName "Profile Duplicate Dog"
    $dupDogId = [string]$dupDraft.Json.dog_id
    $duplicate = Invoke-NoseVerification -Name "nose-verification-duplicate" -DogId $dupDogId -Token $owner.Token -Images $registrationImages
    Assert-True -Name "duplicate verify status" -Value ($duplicate.Status -eq 200) -Actual $duplicate.Json
    Assert-True -Name "duplicate profile allowed" -Value ([bool]$duplicate.Json.profile_match_allowed -eq $true) -Actual $duplicate.Json
    Assert-True -Name "duplicate registration denied" -Value ([bool]$duplicate.Json.registration_allowed -eq $false) -Actual $duplicate.Json
    Assert-True -Name "duplicate status" -Value ([string]$duplicate.Json.status -eq "DUPLICATE_SUSPECTED") -Actual $duplicate.Json

    $duplicateBlocked = New-AdoptionPost -Name "duplicate-post-blocked" -DogId $dupDogId -Token $owner.Token
    Assert-True -Name "duplicate post blocked" -Value ($duplicateBlocked.Status -in @(400, 409)) -Actual $duplicateBlocked.Json
    $summary.scenarios["profile_duplicate_blocked"] = "PASS"

    $fallbackOwner = New-AuthFixture -Label "fallback"
    $fallbackFields = @{
        name = "Fallback Register Dog"
        breed = "Maltese"
        gender = "MALE"
        birth_date = "2024-01-01"
        description = "Fallback register smoke"
    }
    $fallback = Invoke-MultipartApi -Name "fallback-dogs-register" -Method "POST" -Url (Join-Url $BaseUrl "dogs/register") -Fields $fallbackFields -Files (New-NoseFileParts -Paths $registrationImages) -Token $fallbackOwner.Token
    Assert-True -Name "fallback status code" -Value ($fallback.Status -in @(200, 201)) -Actual $fallback.Json
    Assert-True -Name "fallback dimension" -Value ([int]$fallback.Json.dimension -eq 2048) -Actual $fallback.Json
    Assert-True -Name "fallback model" -Value ([string]$fallback.Json.model -like "dog-nose-identification2*") -Actual $fallback.Json.model
    Assert-True -Name "fallback status allowed set" -Value ([string]$fallback.Json.status -in @("REGISTERED", "DUPLICATE_SUSPECTED", "REVIEW_REQUIRED")) -Actual $fallback.Json
    $summary.markers["fallback_status"] = [string]$fallback.Json.status
    $summary.scenarios["dogs_register_fallback"] = "PASS"

    $failed = @($summary.scenarios.GetEnumerator() | Where-Object { $_.Value -notin @("PASS", "NOT_RUN", "SKIP_DUPLICATE_OR_REVIEW_RESULT") })
    $summary["result"] = if ($failed.Count -eq 0) { "PASS" } else { "FAIL" }
} catch {
    $summary["result"] = "FAIL"
    $summary["error"] = $_.Exception.Message
    throw
} finally {
    if ($WriteEvidence) {
        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
        $summary | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $SummaryPath -Encoding UTF8
        $header = @(
            "# Profile-first YOLO Demo API Transcript",
            "",
            "- Checked at: $($script:StartedAt.ToString("o"))",
            "- Redaction: JWT/password/raw image/crop_base64/vector values are not recorded.",
            ""
        ) -join "`n"
        ($header + "`n" + ($script:Transcript -join "`n`n")) | Set-Content -LiteralPath $ApiTranscriptPath -Encoding UTF8
        Write-Host "Wrote sanitized evidence:"
        Write-Host "  $SummaryPath"
        Write-Host "  $ApiTranscriptPath"
    }
}

if ($summary.result -eq "PASS") {
    Write-Host "PROFILE-FIRST YOLO DEMO SMOKE PASSED"
} else {
    Write-Host "PROFILE-FIRST YOLO DEMO SMOKE FAILED"
    exit 1
}
