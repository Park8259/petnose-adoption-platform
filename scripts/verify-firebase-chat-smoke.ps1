#Requires -Version 5.1

[CmdletBinding()]
param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BaseUrl = "http://localhost:8080",

    [ValidateSet("disabled", "enabled")]
    [string]$Mode = "disabled",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$BearerToken = "",

    [long]$PostId = 0,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$RoomId = "",

    [ValidateNotNullOrEmpty()]
    [string]$FcmToken = "firebase-chat-smoke-dummy-token",

    [ValidateSet("ANDROID", "IOS", "WEB")]
    [string]$Platform = "WEB",

    [ValidateNotNullOrEmpty()]
    [string]$MessageText = "Firebase chat smoke test"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:StepNumber = 0
$script:EffectiveRoomId = ""

$Curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue
if ($null -eq $Curl) {
    throw "curl.exe is required for stable HTTP status handling on Windows PowerShell and pwsh."
}

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    throw "BaseUrl must not be empty."
}

$BaseUrl = $BaseUrl.TrimEnd("/")
if ($BaseUrl.ToLowerInvariant().EndsWith("/api")) {
    $ApiBaseUrl = $BaseUrl
} else {
    $ApiBaseUrl = "$BaseUrl/api"
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

function Assert-ErrorCode {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][string]$ExpectedErrorCode
    )

    if ($null -eq $Response.Json -or -not (Test-JsonField -Object $Response.Json -Name "error_code")) {
        throw "Expected error_code in response. $(Format-ResponseSummary $Response)"
    }
    if ($Response.Json.error_code -ne $ExpectedErrorCode) {
        throw "Expected error_code '$ExpectedErrorCode', actual '$($Response.Json.error_code)'. $(Format-ResponseSummary $Response)"
    }
}

function Assert-FirebaseDisabled {
    param([Parameter(Mandatory = $true)]$Response)

    Assert-Status -Response $Response -ExpectedStatus 503
    Assert-ErrorCode -Response $Response -ExpectedErrorCode "FIREBASE_DISABLED"
}

function Assert-AuthTokenPresent {
    if ([string]::IsNullOrWhiteSpace($BearerToken)) {
        throw "BearerToken is required because Firebase chat endpoints require a Spring Bearer token."
    }
}

function Invoke-DisabledSmoke {
    Assert-AuthTokenPresent

    $disabledPostId = $PostId
    if ($disabledPostId -le 0) {
        $disabledPostId = 1
    }

    $disabledRoomId = $RoomId
    if ([string]::IsNullOrWhiteSpace($disabledRoomId)) {
        $disabledRoomId = "post_1_user_1"
    }

    Invoke-Step "Firebase custom token returns FIREBASE_DISABLED" {
        $response = Invoke-JsonRequest -Method "POST" -Url (Join-Url $ApiBaseUrl "firebase/custom-token") -BearerToken $BearerToken
        Assert-FirebaseDisabled -Response $response
    }

    Invoke-Step "FCM token registration returns FIREBASE_DISABLED" {
        $body = @{
            fcm_token = $FcmToken
            platform = $Platform
        }
        $response = Invoke-JsonRequest -Method "PUT" -Url (Join-Url $ApiBaseUrl "users/me/fcm-token") -BodyObject $body -BearerToken $BearerToken
        Assert-FirebaseDisabled -Response $response
    }

    Invoke-Step "Chat room creation returns FIREBASE_DISABLED" {
        $body = @{ post_id = $disabledPostId }
        $response = Invoke-JsonRequest -Method "POST" -Url (Join-Url $ApiBaseUrl "chat/rooms") -BodyObject $body -BearerToken $BearerToken
        Assert-FirebaseDisabled -Response $response
    }

    Invoke-Step "Chat room list returns FIREBASE_DISABLED" {
        $response = Invoke-JsonRequest -Method "GET" -Url (Join-Url $ApiBaseUrl "chat/rooms") -BearerToken $BearerToken
        Assert-FirebaseDisabled -Response $response
    }

    Invoke-Step "Message send returns FIREBASE_DISABLED" {
        $body = @{
            text = "hello"
            client_message_id = "disabled-smoke-1"
        }
        $response = Invoke-JsonRequest -Method "POST" -Url (Join-Url $ApiBaseUrl "chat/rooms/$disabledRoomId/messages") -BodyObject $body -BearerToken $BearerToken
        Assert-FirebaseDisabled -Response $response
    }

    Invoke-Step "Read marking returns FIREBASE_DISABLED" {
        $response = Invoke-JsonRequest -Method "PATCH" -Url (Join-Url $ApiBaseUrl "chat/rooms/$disabledRoomId/read") -BearerToken $BearerToken
        Assert-FirebaseDisabled -Response $response
    }
}

function Invoke-EnabledSmoke {
    Assert-AuthTokenPresent
    if ($PostId -le 0) {
        throw "PostId is required in enabled mode and must point to an existing OPEN adoption post owned by another user."
    }

    $script:EffectiveRoomId = $RoomId

    Invoke-Step "Firebase custom token can be issued" {
        $response = Invoke-JsonRequest -Method "POST" -Url (Join-Url $ApiBaseUrl "firebase/custom-token") -BearerToken $BearerToken
        Assert-Status -Response $response -ExpectedStatus 200
        Assert-Field -Object $response.Json -Name "firebase_uid"
        Assert-Field -Object $response.Json -Name "firebase_custom_token"
        Write-Host "firebase_uid=$($response.Json.firebase_uid)"
    }

    Invoke-Step "FCM token can be registered" {
        $body = @{
            fcm_token = $FcmToken
            platform = $Platform
        }
        $response = Invoke-JsonRequest -Method "PUT" -Url (Join-Url $ApiBaseUrl "users/me/fcm-token") -BodyObject $body -BearerToken $BearerToken
        Assert-Status -Response $response -ExpectedStatus 200
        Assert-True -Value $response.Json.registered -Name "registered"
    }

    Invoke-Step "Chat room can be created or returned" {
        $body = @{ post_id = $PostId }
        $response = Invoke-JsonRequest -Method "POST" -Url (Join-Url $ApiBaseUrl "chat/rooms") -BodyObject $body -BearerToken $BearerToken
        Assert-Status -Response $response -ExpectedStatus 201
        Assert-Field -Object $response.Json -Name "room_id"
        Assert-Equal -Actual $response.Json.post_id -Expected $PostId -Name "post_id"
        if ([string]::IsNullOrWhiteSpace($script:EffectiveRoomId)) {
            $script:EffectiveRoomId = $response.Json.room_id
        }
        if ([string]::IsNullOrWhiteSpace($script:EffectiveRoomId)) {
            throw "RoomId was not provided and create-room did not return one."
        }
        Write-Host "room_id=$script:EffectiveRoomId"
    }

    Invoke-Step "Message can be sent through Spring API" {
        if ([string]::IsNullOrWhiteSpace($script:EffectiveRoomId)) {
            throw "RoomId was not provided and create-room did not return one."
        }
        $clientMessageId = "firebase-smoke-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
        $body = @{
            text = $MessageText
            client_message_id = $clientMessageId
        }
        $response = Invoke-JsonRequest -Method "POST" -Url (Join-Url $ApiBaseUrl "chat/rooms/$script:EffectiveRoomId/messages") -BodyObject $body -BearerToken $BearerToken
        Assert-Status -Response $response -ExpectedStatus 201
        Assert-Field -Object $response.Json -Name "message_id"
        Assert-Equal -Actual $response.Json.room_id -Expected $script:EffectiveRoomId -Name "room_id"
        Assert-Equal -Actual $response.Json.text -Expected $MessageText -Name "text"
        Write-Host "message_id=$($response.Json.message_id)"
    }

    Invoke-Step "Chat room can be marked read" {
        if ([string]::IsNullOrWhiteSpace($script:EffectiveRoomId)) {
            throw "RoomId was not provided and create-room did not return one."
        }
        $response = Invoke-JsonRequest -Method "PATCH" -Url (Join-Url $ApiBaseUrl "chat/rooms/$script:EffectiveRoomId/read") -BearerToken $BearerToken
        Assert-Status -Response $response -ExpectedStatus 200
        Assert-Equal -Actual $response.Json.room_id -Expected $script:EffectiveRoomId -Name "room_id"
        Assert-True -Value $response.Json.read -Name "read"
    }

    Invoke-Step "Chat room list can be queried" {
        $response = Invoke-JsonRequest -Method "GET" -Url (Join-Url $ApiBaseUrl "chat/rooms") -BearerToken $BearerToken
        Assert-Status -Response $response -ExpectedStatus 200
        Assert-Field -Object $response.Json -Name "items"
        Assert-Field -Object $response.Json -Name "page"
        Assert-Field -Object $response.Json -Name "size"
        Assert-Field -Object $response.Json -Name "total_count"
    }
}

Write-Host "PetNose Firebase chat smoke verification" -ForegroundColor Cyan
Write-Host "Mode: $Mode"
Write-Host "ApiBaseUrl: $ApiBaseUrl"

if ($Mode -eq "disabled") {
    Invoke-DisabledSmoke
    Write-Host ""
    Write-Host "FIREBASE CHAT DISABLED SMOKE PASSED" -ForegroundColor Green
} else {
    Invoke-EnabledSmoke
    Write-Host ""
    Write-Host "FIREBASE CHAT ENABLED SMOKE PASSED" -ForegroundColor Green
}
