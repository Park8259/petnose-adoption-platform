#Requires -Version 5.1

[CmdletBinding()]
param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BaseUrl = "http://localhost:8080",

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$NoseImagePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ProfileImagePath,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$OutputEnvFile = (Join-Path $env:TEMP "petnose-firebase-chat-smoke-env.ps1"),

    [ValidateNotNullOrEmpty()]
    [string]$ProjectAlias = "dev-firebase",

    [ValidateNotNullOrEmpty()]
    [string]$Environment = "local-dev",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$FcmToken = "petnose-smoke-dummy-fcm-token",

    [ValidateSet("ANDROID", "IOS", "WEB")]
    [string]$Platform = "WEB",

    [switch]$RunSmoke,
    [switch]$FailIfDuplicate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script:StepNumber = 0
$script:AuthorEmail = ""
$script:InquirerEmail = ""
$script:AuthorToken = ""
$script:InquirerToken = ""
$script:DogId = ""
$script:PostId = ""

$Curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue
if ($null -eq $Curl) {
    throw "curl.exe is required for stable multipart/status handling on Windows PowerShell and pwsh."
}

if (-not (Test-Path -LiteralPath $NoseImagePath -PathType Leaf)) {
    throw "NoseImagePath not found: $NoseImagePath"
}
$ResolvedNoseImagePath = (Resolve-Path -LiteralPath $NoseImagePath).Path

if (-not (Test-Path -LiteralPath $ProfileImagePath -PathType Leaf)) {
    throw "ProfileImagePath not found: $ProfileImagePath"
}
$ResolvedProfileImagePath = (Resolve-Path -LiteralPath $ProfileImagePath).Path

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    throw "BaseUrl must not be empty."
}

if ([string]::IsNullOrWhiteSpace($OutputEnvFile)) {
    throw "OutputEnvFile must not be empty."
}

if ([string]::IsNullOrWhiteSpace($FcmToken)) {
    $FcmToken = "petnose-smoke-dummy-fcm-token"
}

$BaseUrl = $BaseUrl.TrimEnd("/")
if ($BaseUrl.ToLowerInvariant().EndsWith("/api")) {
    $ApiBaseUrl = $BaseUrl
} else {
    $ApiBaseUrl = "$BaseUrl/api"
}

$OutputEnvDirectory = Split-Path -Parent $OutputEnvFile
if ([string]::IsNullOrWhiteSpace($OutputEnvDirectory)) {
    $OutputEnvDirectory = (Get-Location).Path
}
$ResolvedOutputEnvDirectory = [System.IO.Path]::GetFullPath($OutputEnvDirectory)
$ResolvedOutputEnvFile = [System.IO.Path]::GetFullPath((Join-Path $ResolvedOutputEnvDirectory (Split-Path -Leaf $OutputEnvFile)))
$ResolvedRepoRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
if ($ResolvedOutputEnvFile.StartsWith($ResolvedRepoRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputEnvFile must be outside the repository because it contains a Spring JWT. Path: $ResolvedOutputEnvFile"
}
if (-not (Test-Path -LiteralPath $ResolvedOutputEnvDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $ResolvedOutputEnvDirectory -Force | Out-Null
}

function Join-Url {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return "$($Root.TrimEnd('/'))/$($Path.TrimStart('/'))"
}

function New-JsonTempFile {
    param(
        [Parameter(Mandatory = $true)]
        [object]$BodyObject
    )

    $path = [System.IO.Path]::GetTempFileName()
    $json = $BodyObject | ConvertTo-Json -Depth 20 -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
    return $path
}

function Convert-BodyToJson {
    param([string]$BodyText)

    if ([string]::IsNullOrWhiteSpace($BodyText)) {
        return $null
    }

    try {
        return $BodyText | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Redact-ResponseBody {
    param([AllowNull()][string]$BodyText)

    if ([string]::IsNullOrWhiteSpace($BodyText)) {
        return ""
    }

    $redacted = $BodyText
    $redacted = $redacted -replace '("access_token"\s*:\s*")[^"]*(")', '$1<redacted>$2'
    $redacted = $redacted -replace '("firebase_custom_token"\s*:\s*")[^"]*(")', '$1<redacted>$2'
    $redacted = $redacted -replace '("fcm_token"\s*:\s*")[^"]*(")', '$1<redacted>$2'
    if ($redacted.Length -gt 1200) {
        return $redacted.Substring(0, 1200) + "...(truncated)"
    }
    return $redacted
}

function Format-ResponseSummary {
    param([Parameter(Mandatory = $true)]$Response)

    return "HTTP $($Response.StatusCode) $($Response.Method) $($Response.Url) body=$(Redact-ResponseBody $Response.BodyText)"
}

function Invoke-CurlRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Url,

        [string[]]$CurlArguments = @()
    )

    $bodyFile = [System.IO.Path]::GetTempFileName()
    try {
        $arguments = @("-sS", "-X", $Method, $Url, "-o", $bodyFile, "-w", "%{http_code}") + $CurlArguments
        $statusOutput = & curl.exe @arguments 2>&1
        $exitCode = $LASTEXITCODE
        $bodyText = ""
        if (Test-Path -LiteralPath $bodyFile -PathType Leaf) {
            $bodyText = [System.IO.File]::ReadAllText($bodyFile, [System.Text.Encoding]::UTF8)
        }

        if ($exitCode -ne 0) {
            throw "curl.exe failed for $Method $Url with exit code $exitCode. Output: $($statusOutput -join ' ')"
        }

        $statusLine = (@($statusOutput) | Select-Object -Last 1).ToString().Trim()
        [int]$statusCode = 0
        if (-not [int]::TryParse($statusLine, [ref]$statusCode)) {
            throw "Could not parse HTTP status from curl output for $Method $Url. Output: $($statusOutput -join ' ')"
        }

        return [pscustomobject]@{
            Method = $Method
            Url = $Url
            StatusCode = $statusCode
            BodyText = $bodyText
            Json = Convert-BodyToJson $bodyText
        }
    } finally {
        Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-JsonRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Url,

        [object]$BodyObject = $null,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$BearerToken = ""
    )

    $jsonFile = $null
    try {
        $arguments = @("-H", "Accept: application/json")
        if (-not [string]::IsNullOrWhiteSpace($BearerToken)) {
            $arguments += @("-H", "Authorization: Bearer $BearerToken")
        }
        if ($null -ne $BodyObject) {
            $jsonFile = New-JsonTempFile $BodyObject
            $arguments += @("-H", "Content-Type: application/json", "--data-binary", "@$jsonFile")
        }

        return Invoke-CurlRequest -Method $Method -Url $Url -CurlArguments $arguments
    } finally {
        if ($null -ne $jsonFile) {
            Remove-Item -LiteralPath $jsonFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ImageMimeType {
    param([Parameter(Mandatory = $true)][string]$Path)

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($extension) {
        ".jpg" { return "image/jpeg" }
        ".jpeg" { return "image/jpeg" }
        ".png" { return "image/png" }
        default { return "application/octet-stream" }
    }
}

function Invoke-MultipartRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [hashtable]$Fields = @{},

        [hashtable]$Files = @{},

        [AllowNull()]
        [AllowEmptyString()]
        [string]$BearerToken = ""
    )

    $arguments = @("-H", "Accept: application/json")
    if (-not [string]::IsNullOrWhiteSpace($BearerToken)) {
        $arguments += @("-H", "Authorization: Bearer $BearerToken")
    }

    foreach ($key in $Fields.Keys) {
        $arguments += @("-F", "$key=$($Fields[$key])")
    }

    foreach ($key in $Files.Keys) {
        $fileSpec = $Files[$key]
        $arguments += @("-F", "$key=@$($fileSpec.Path);type=$($fileSpec.MimeType)")
    }

    return Invoke-CurlRequest -Method "POST" -Url $Url -CurlArguments $arguments
}

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

function Test-JsonField {
    param(
        [Parameter(Mandatory = $false)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }
    return $Object.PSObject.Properties.Name -contains $Name
}

function Assert-Status {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][int]$ExpectedStatus
    )

    if ($Response.StatusCode -ne $ExpectedStatus) {
        throw "Expected HTTP $ExpectedStatus, actual $($Response.StatusCode). $(Format-ResponseSummary $Response)"
    }
}

function Assert-Field {
    param(
        [Parameter(Mandatory = $false)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not (Test-JsonField -Object $Object -Name $Name)) {
        throw "Expected JSON field '$Name' to be present."
    }
    $value = $Object.$Name
    if ($null -eq $value) {
        throw "Expected JSON field '$Name' to be non-null."
    }
    if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) {
        throw "Expected JSON field '$Name' to be non-empty."
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $false)]$Actual,
        [Parameter(Mandatory = $false)]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ("$Actual" -ne "$Expected") {
        throw "$Name mismatch. Expected '$Expected', actual '$Actual'."
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -ne $true) {
        throw "$Name must be true, actual '$Value'."
    }
}

function Assert-RegistrationAllowed {
    param([Parameter(Mandatory = $true)]$Response)

    if ($Response.StatusCode -eq 200 -and $null -ne $Response.Json -and (Test-JsonField -Object $Response.Json -Name "registration_allowed") -and $Response.Json.registration_allowed -eq $false) {
        $message = "Dog registration returned duplicate suspected. Reset dev runtime/Qdrant or use a different nose image before retrying Firebase chat smoke fixture preparation."
        if ($FailIfDuplicate) {
            throw $message
        }
        throw $message
    }

    Assert-Status -Response $Response -ExpectedStatus 201
    Assert-True -Value $Response.Json.registration_allowed -Name "registration_allowed"
    Assert-Equal -Actual $Response.Json.status -Expected "REGISTERED" -Name "dog.status"
    Assert-Field -Object $Response.Json -Name "dog_id"
}

function Protect-PowerShellValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) {
        return ""
    }
    return $Value.Replace("'", "''")
}

function Write-SmokeEnvFile {
    $content = @"
`$env:PETNOSE_FIREBASE_SMOKE_BASE_URL = '$(Protect-PowerShellValue $BaseUrl)'
`$env:PETNOSE_FIREBASE_SMOKE_BEARER_TOKEN = '$(Protect-PowerShellValue $script:InquirerToken)'
`$env:PETNOSE_FIREBASE_SMOKE_POST_ID = '$(Protect-PowerShellValue "$script:PostId")'
`$env:PETNOSE_FIREBASE_SMOKE_PROJECT_ALIAS = '$(Protect-PowerShellValue $ProjectAlias)'
`$env:PETNOSE_FIREBASE_SMOKE_ENVIRONMENT = '$(Protect-PowerShellValue $Environment)'
`$env:PETNOSE_FIREBASE_SMOKE_PLATFORM = '$(Protect-PowerShellValue $Platform)'
`$env:PETNOSE_FIREBASE_SMOKE_FCM_TOKEN = '$(Protect-PowerShellValue $FcmToken)'
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ResolvedOutputEnvFile, $content, $utf8NoBom)
}

$noseMimeType = Get-ImageMimeType -Path $ResolvedNoseImagePath
$profileMimeType = Get-ImageMimeType -Path $ResolvedProfileImagePath
$allowedUploadMimeTypes = @("image/jpeg", "image/png")
if ($allowedUploadMimeTypes -notcontains $noseMimeType) {
    throw "NoseImagePath must be a JPEG or PNG image file. Detected MIME from extension: $noseMimeType"
}
if ($allowedUploadMimeTypes -notcontains $profileMimeType) {
    throw "ProfileImagePath must be a JPEG or PNG image file. Detected MIME from extension: $profileMimeType"
}

$timestamp = Get-Date -Format "yyyyMMddHHmmssfff"
$authorEmail = "firebase-chat-author-$timestamp@example.com"
$inquirerEmail = "firebase-chat-inquirer-$timestamp@example.com"

Write-Host "PetNose Firebase chat smoke fixture preparation" -ForegroundColor Cyan
Write-Host "ApiBaseUrl: $ApiBaseUrl"
Write-Host "NoseImagePath: $ResolvedNoseImagePath"
Write-Host "ProfileImagePath: $ResolvedProfileImagePath"
Write-Host "OutputEnvFile: $ResolvedOutputEnvFile"
Write-Host "Output env file is sensitive because it contains a Spring JWT. Do not commit it." -ForegroundColor Yellow

Invoke-Step "Register author user" {
    $body = @{
        email = $authorEmail
        password = "password123"
        display_name = "연기자"
        contact_phone = "01012341234"
        region = "Seoul"
    }
    $response = Invoke-JsonRequest -Method "POST" -Url (Join-Url $ApiBaseUrl "auth/register") -BodyObject $body
    Assert-Status -Response $response -ExpectedStatus 201
    Assert-Field -Object $response.Json -Name "user_id"
    $script:AuthorEmail = $authorEmail
    Write-Host "author_email=$script:AuthorEmail"
}

Invoke-Step "Login author user" {
    $body = @{
        email = $authorEmail
        password = "password123"
    }
    $response = Invoke-JsonRequest -Method "POST" -Url (Join-Url $ApiBaseUrl "auth/login") -BodyObject $body
    Assert-Status -Response $response -ExpectedStatus 200
    Assert-Field -Object $response.Json -Name "access_token"
    $script:AuthorToken = $response.Json.access_token
    Write-Host "author_login=ok"
}

Invoke-Step "Register inquirer user" {
    $body = @{
        email = $inquirerEmail
        password = "password123"
        display_name = "문의자"
        contact_phone = "01012345678"
        region = "Seoul"
    }
    $response = Invoke-JsonRequest -Method "POST" -Url (Join-Url $ApiBaseUrl "auth/register") -BodyObject $body
    Assert-Status -Response $response -ExpectedStatus 201
    Assert-Field -Object $response.Json -Name "user_id"
    $script:InquirerEmail = $inquirerEmail
    Write-Host "inquirer_email=$script:InquirerEmail"
}

Invoke-Step "Login inquirer user" {
    $body = @{
        email = $inquirerEmail
        password = "password123"
    }
    $response = Invoke-JsonRequest -Method "POST" -Url (Join-Url $ApiBaseUrl "auth/login") -BodyObject $body
    Assert-Status -Response $response -ExpectedStatus 200
    Assert-Field -Object $response.Json -Name "access_token"
    $script:InquirerToken = $response.Json.access_token
    Write-Host "inquirer_login=ok"
}

Invoke-Step "Register dog for author" {
    $fields = @{
        name = "채팅스모크"
        breed = "Maltese"
        gender = "UNKNOWN"
        birth_date = "2024-01-01"
        description = "Firebase chat smoke fixture dog"
    }
    $files = @{
        nose_image = [pscustomobject]@{ Path = $ResolvedNoseImagePath; MimeType = $noseMimeType }
    }
    $response = Invoke-MultipartRequest -Url (Join-Url $ApiBaseUrl "dogs/register") -Fields $fields -Files $files -BearerToken $script:AuthorToken
    Assert-RegistrationAllowed -Response $response
    $script:DogId = $response.Json.dog_id
    Write-Host "dog_id=$script:DogId"
}

Invoke-Step "Create OPEN adoption post for author" {
    $fields = @{
        dog_id = $script:DogId
        title = "Firebase chat smoke post $timestamp"
        content = "Firebase chat smoke fixture post"
        status = "OPEN"
    }
    $files = @{
        profile_image = [pscustomobject]@{ Path = $ResolvedProfileImagePath; MimeType = $profileMimeType }
    }
    $response = Invoke-MultipartRequest -Url (Join-Url $ApiBaseUrl "adoption-posts") -Fields $fields -Files $files -BearerToken $script:AuthorToken
    Assert-Status -Response $response -ExpectedStatus 201
    Assert-Equal -Actual $response.Json.status -Expected "OPEN" -Name "post.status"
    Assert-Field -Object $response.Json -Name "post_id"
    $script:PostId = $response.Json.post_id
    Write-Host "post_id=$script:PostId"
}

Invoke-Step "Write smoke environment file" {
    Write-SmokeEnvFile
    Write-Host "output_env_file=$ResolvedOutputEnvFile"
    Write-Host "Use: . '$ResolvedOutputEnvFile'" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Fixture summary" -ForegroundColor Cyan
Write-Host "author_email=$script:AuthorEmail"
Write-Host "inquirer_email=$script:InquirerEmail"
Write-Host "dog_id=$script:DogId"
Write-Host "post_id=$script:PostId"
Write-Host "output_env_file=$ResolvedOutputEnvFile"
Write-Host "JWT and FCM token values were not printed." -ForegroundColor Yellow

if ($RunSmoke) {
    Invoke-Step "Run Firebase enabled chat smoke" {
        $smokeScript = Join-Path $PSScriptRoot "verify-firebase-chat-smoke.ps1"
        & $smokeScript `
            -Mode enabled `
            -BaseUrl $BaseUrl `
            -BearerToken $script:InquirerToken `
            -PostId $script:PostId `
            -FcmToken $FcmToken `
            -Platform $Platform
        if ($LASTEXITCODE -ne 0) {
            throw "verify-firebase-chat-smoke.ps1 failed with exit code $LASTEXITCODE."
        }
    }
}

Write-Host ""
Write-Host "FIREBASE CHAT SMOKE FIXTURE PREPARATION PASSED" -ForegroundColor Green
