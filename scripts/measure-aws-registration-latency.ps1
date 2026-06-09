#Requires -Version 7.0
<#
.SYNOPSIS
Measures PetNose AWS API latency for dog registration.

.DESCRIPTION
This is a focused client-side latency probe for the public AWS API. It creates
a test user, logs in, and repeatedly calls POST /api/dogs/register with exactly
five nose images. It also records lightweight baseline timings for actuator
health and public adoption post listing.

The script intentionally avoids direct DB, Qdrant, or Python Embed access. It
does not reset server data. Registration calls create real test users/dogs on
the target server.

.EXAMPLE
pwsh -NoProfile -File .\scripts\measure-aws-registration-latency.ps1 `
  -NoseImageDir "C:\path\to\nose-images" `
  -RootUrl "http://<server-host>" `
  -BaseUrl "http://<server-host>/api" `
  -Runs 3

.EXAMPLE
pwsh -NoProfile -File .\scripts\measure-aws-registration-latency.ps1 `
  -BaseUrl "http://<server-host>/api" `
  -RootUrl "http://<server-host>" `
  -NoseImages "C:\img\1.png","C:\img\2.png","C:\img\3.png","C:\img\4.png","C:\img\5.png" `
  -Runs 5
#>

[CmdletBinding()]
param(
    [string]$RootUrl = "",
    [string]$BaseUrl = "",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$NoseImageDir = "",

    [string[]]$NoseImages = @(),

    [ValidateSet("auto", "jpg", "jpeg", "png")]
    [string]$NoseImageExtension = "auto",

    [ValidateRange(1, 100)]
    [int]$Runs = 3,

    [switch]$RegisterUserPerRun,

    [string]$EmailPrefix = "latency",
    [string]$EmailDomain = "example.com",
    [string]$Password = "password123",

    [string]$OutputDir = "docs/ops-evidence/aws-registration-latency",

    [ValidateRange(1, 120)]
    [int]$ConnectTimeoutSeconds = 10,

    [ValidateRange(5, 600)]
    [int]$MaxTimeSeconds = 120,

    [switch]$SkipHealth,
    [switch]$SkipPublicListBaseline,
    [switch]$KeepRawResponses,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

function Show-Usage {
    Write-Host @"
PetNose AWS registration latency probe

Required:
  -NoseImageDir <dir with 1.png..5.png>  OR  -NoseImages <five files>

Common:
  pwsh -NoProfile -File .\scripts\measure-aws-registration-latency.ps1 \
    -NoseImageDir "C:\path\to\nose-images" \
    -RootUrl "http://<server-host>" \
    -BaseUrl "http://<server-host>/api" \
    -Runs 3

Outputs:
  <OutputDir>/<timestamp>/latency.csv
  <OutputDir>/<timestamp>/summary.json

Notes:
  - Calls the external API only.
  - Creates real test users/dogs on the target server.
  - First registration for a new nose set may be REGISTERED.
  - Later runs with the same images may be DUPLICATE_SUSPECTED; that is still
    useful for measuring upload + embed + Qdrant search latency.
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

function Get-ImageMimeType {
    param([Parameter(Mandatory = $true)][string]$Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".jpg" { return "image/jpeg" }
        ".jpeg" { return "image/jpeg" }
        ".png" { return "image/png" }
        default { Fail-Config "Only jpg, jpeg, and png are supported by the backend: $Path" }
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
    Fail-Config "Could not find image $Index with extension [$($extensions -join ', ')] in $Directory"
}

function Resolve-NoseImages {
    $resolved = @()
    if ($NoseImages.Count -gt 0) {
        if ($NoseImages.Count -ne 5) {
            Fail-Config "-NoseImages must contain exactly five files. Actual: $($NoseImages.Count)"
        }
        foreach ($image in $NoseImages) {
            $path = Resolve-InputPath $image
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                Fail-Config "Nose image not found: $image"
            }
            $resolved += (Resolve-Path -LiteralPath $path).Path
        }
        return $resolved
    }

    $dir = $NoseImageDir
    if ([string]::IsNullOrWhiteSpace($dir)) {
        $dir = $env:PETNOSE_LATENCY_NOSE_IMAGE_DIR
    }
    if ([string]::IsNullOrWhiteSpace($dir)) {
        Fail-Config "Provide -NoseImageDir, -NoseImages, or PETNOSE_LATENCY_NOSE_IMAGE_DIR."
    }

    $resolvedDir = Resolve-InputPath $dir
    if (-not (Test-Path -LiteralPath $resolvedDir -PathType Container)) {
        Fail-Config "NoseImageDir not found: $dir"
    }
    $resolvedDir = (Resolve-Path -LiteralPath $resolvedDir).Path

    for ($i = 1; $i -le 5; $i++) {
        $resolved += Find-IndexedImage -Directory $resolvedDir -Index $i -Extension $NoseImageExtension
    }
    return $resolved
}

function New-RequestJsonFile {
    param(
        [Parameter(Mandatory = $true)][object]$BodyObject,
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $path = Join-Path $Directory "$Name.json"
    $BodyObject | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Parse-CurlWriteOut {
    param([AllowNull()][string[]]$Lines)
    $result = @{}
    foreach ($line in @($Lines)) {
        $text = [string]$line
        $idx = $text.IndexOf("=")
        if ($idx -le 0) {
            continue
        }
        $key = $text.Substring(0, $idx)
        $value = $text.Substring($idx + 1)
        $result[$key] = $value
    }
    return $result
}

function To-DoubleOrNull {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $parsed = 0.0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function To-IntOrNull {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Get-JsonProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Invoke-CurlRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][int]$Iteration,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [hashtable]$Headers = @{},
        [AllowNull()][AllowEmptyString()][string]$JsonFile = "",
        [string[]]$Forms = @()
    )

    $responsePath = if ($KeepRawResponses) {
        Join-Path $ResponseDir ("{0:00}_{1}.response.json" -f $Iteration, ($Label -replace "[^A-Za-z0-9_.-]", "_"))
    } else {
        Join-Path ([System.IO.Path]::GetTempPath()) ("petnose_latency_{0}_{1}_{2}.tmp" -f $PID, $Iteration, ([guid]::NewGuid().ToString("N")))
    }

    $writeOut = @(
        "http_code=%{http_code}",
        "time_namelookup=%{time_namelookup}",
        "time_connect=%{time_connect}",
        "time_appconnect=%{time_appconnect}",
        "time_pretransfer=%{time_pretransfer}",
        "time_starttransfer=%{time_starttransfer}",
        "time_total=%{time_total}",
        "size_upload=%{size_upload}",
        "size_download=%{size_download}",
        "speed_upload=%{speed_upload}",
        "speed_download=%{speed_download}",
        "remote_ip=%{remote_ip}"
    ) -join "`n"

    $curlArgs = @(
        "--silent",
        "--show-error",
        "--location",
        "--request", $Method,
        "--connect-timeout", [string]$ConnectTimeoutSeconds,
        "--max-time", [string]$MaxTimeSeconds,
        "--output", $responsePath,
        "--write-out", $writeOut
    )

    foreach ($key in $Headers.Keys) {
        $curlArgs += @("--header", "${key}: $($Headers[$key])")
    }

    if (-not [string]::IsNullOrWhiteSpace($JsonFile)) {
        $curlArgs += @("--header", "Content-Type: application/json")
        $curlArgs += @("--data-binary", "@$JsonFile")
    }

    foreach ($form in $Forms) {
        $curlArgs += @("--form", $form)
    }

    $curlArgs += $Url

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $curlOutput = @(& curl.exe @curlArgs 2>&1)
    $exitCode = $LASTEXITCODE
    $watch.Stop()

    $bodyText = ""
    if (Test-Path -LiteralPath $responsePath -PathType Leaf) {
        $bodyText = Get-Content -LiteralPath $responsePath -Raw -ErrorAction SilentlyContinue
        if (-not $KeepRawResponses) {
            Remove-Item -LiteralPath $responsePath -Force -ErrorAction SilentlyContinue
        }
    }

    $timings = Parse-CurlWriteOut -Lines $curlOutput
    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($bodyText)) {
        try {
            $json = $bodyText | ConvertFrom-Json
        } catch {
            $json = $null
        }
    }

    $httpCode = To-IntOrNull $timings["http_code"]
    if ($null -eq $httpCode -and $exitCode -ne 0) {
        $httpCode = 0
    }

    return [pscustomobject]@{
        Label = $Label
        Iteration = $Iteration
        Method = $Method
        Url = $Url
        CurlExitCode = $exitCode
        HttpStatus = $httpCode
        StopwatchMs = [math]::Round($watch.Elapsed.TotalMilliseconds, 2)
        Timings = $timings
        Json = $json
        BodyText = $bodyText
        CurlOutput = ($curlOutput -join "`n")
    }
}

function Convert-ResultToRow {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [string]$Note = ""
    )
    $t = $Result.Timings
    $json = $Result.Json
    $timeTotal = To-DoubleOrNull $t["time_total"]
    $timeStartTransfer = To-DoubleOrNull $t["time_starttransfer"]
    $sizeUpload = To-DoubleOrNull $t["size_upload"]
    $speedUpload = To-DoubleOrNull $t["speed_upload"]

    $errorCode = Get-JsonProperty -Object $json -Name "error_code"
    if ($null -eq $errorCode) { $errorCode = Get-JsonProperty -Object $json -Name "error" }

    return [pscustomobject]@{
        timestamp = (Get-Date).ToString("o")
        label = $Result.Label
        iteration = $Result.Iteration
        method = $Result.Method
        url = $Result.Url
        http_status = $Result.HttpStatus
        curl_exit_code = $Result.CurlExitCode
        stopwatch_ms = $Result.StopwatchMs
        curl_total_ms = if ($null -ne $timeTotal) { [math]::Round($timeTotal * 1000.0, 2) } else { $null }
        dns_ms = if ($null -ne (To-DoubleOrNull $t["time_namelookup"])) { [math]::Round((To-DoubleOrNull $t["time_namelookup"]) * 1000.0, 2) } else { $null }
        connect_ms = if ($null -ne (To-DoubleOrNull $t["time_connect"])) { [math]::Round((To-DoubleOrNull $t["time_connect"]) * 1000.0, 2) } else { $null }
        pretransfer_ms = if ($null -ne (To-DoubleOrNull $t["time_pretransfer"])) { [math]::Round((To-DoubleOrNull $t["time_pretransfer"]) * 1000.0, 2) } else { $null }
        ttfb_ms = if ($null -ne $timeStartTransfer) { [math]::Round($timeStartTransfer * 1000.0, 2) } else { $null }
        upload_bytes = if ($null -ne $sizeUpload) { [math]::Round($sizeUpload, 0) } else { $null }
        download_bytes = To-DoubleOrNull $t["size_download"]
        upload_kbps = if ($null -ne $speedUpload) { [math]::Round(($speedUpload * 8.0) / 1000.0, 2) } else { $null }
        remote_ip = $t["remote_ip"]
        dog_id = Get-JsonProperty -Object $json -Name "dog_id"
        dog_status = Get-JsonProperty -Object $json -Name "status"
        registration_allowed = Get-JsonProperty -Object $json -Name "registration_allowed"
        verification_status = Get-JsonProperty -Object $json -Name "verification_status"
        embedding_status = Get-JsonProperty -Object $json -Name "embedding_status"
        max_similarity_score = Get-JsonProperty -Object $json -Name "max_similarity_score"
        error_code = $errorCode
        message = Get-JsonProperty -Object $json -Name "message"
        curl_output = if ($Result.CurlExitCode -ne 0) { $Result.CurlOutput } else { "" }
        note = $Note
    }
}

function Get-Percentile {
    param(
        [double[]]$Values,
        [double]$Percentile
    )
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $rank = [math]::Ceiling(($Percentile / 100.0) * $sorted.Count) - 1
    $rank = [math]::Max(0, [math]::Min($rank, $sorted.Count - 1))
    return [math]::Round($sorted[$rank], 2)
}

function Get-Stats {
    param([object[]]$Rows)
    $values = @($Rows | ForEach-Object { $_.curl_total_ms } | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($values.Count -eq 0) {
        return [ordered]@{ count = 0 }
    }
    $sum = 0.0
    foreach ($value in $values) { $sum += $value }
    return [ordered]@{
        count = $values.Count
        mean_ms = [math]::Round($sum / $values.Count, 2)
        p50_ms = Get-Percentile -Values $values -Percentile 50
        p95_ms = Get-Percentile -Values $values -Percentile 95
        min_ms = [math]::Round(($values | Measure-Object -Minimum).Minimum, 2)
        max_ms = [math]::Round(($values | Measure-Object -Maximum).Maximum, 2)
    }
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Fail-Config "curl.exe is required for stable multipart timing on Windows."
}

if ([string]::IsNullOrWhiteSpace($RootUrl)) {
    $RootUrl = $env:PETNOSE_LATENCY_ROOT_URL
}
if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    $BaseUrl = $env:PETNOSE_LATENCY_BASE_URL
}
if ([string]::IsNullOrWhiteSpace($RootUrl)) {
    Fail-Config "Provide -RootUrl or PETNOSE_LATENCY_ROOT_URL."
}
if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    Fail-Config "Provide -BaseUrl or PETNOSE_LATENCY_BASE_URL."
}

$images = Resolve-NoseImages
$imageEvidence = @()
$imageIndex = 0
foreach ($image in $images) {
    $imageIndex += 1
    $item = Get-Item -LiteralPath $image
    $imageEvidence += [ordered]@{
        path = ("image_{0}{1}" -f $imageIndex, $item.Extension)
        bytes = $item.Length
        mime_type = Get-ImageMimeType -Path $item.FullName
    }
}

$runStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$RunOutputDir = Join-Path (Resolve-InputPath $OutputDir) $runStamp
$ResponseDir = Join-Path $RunOutputDir "responses"
$RequestDir = Join-Path ([System.IO.Path]::GetTempPath()) ("petnose_latency_requests_{0}_{1}" -f $PID, $runStamp)
New-Item -ItemType Directory -Force -Path $RunOutputDir, $RequestDir | Out-Null
if ($KeepRawResponses) {
    New-Item -ItemType Directory -Force -Path $ResponseDir | Out-Null
}

$rows = New-Object System.Collections.Generic.List[object]
$suffix = "{0}_{1}" -f $runStamp, ([guid]::NewGuid().ToString("N").Substring(0, 8))
$ownerEmail = "$EmailPrefix.$suffix@$EmailDomain".ToLowerInvariant()
$ownerToken = ""

Write-Host "[INFO] Target root: $RootUrl"
Write-Host "[INFO] Target API:  $BaseUrl"
Write-Host "[INFO] Images:      $($images -join ', ')"
Write-Host "[INFO] Output:      $RunOutputDir"

if (-not $SkipHealth) {
    $health = Invoke-CurlRequest -Label "health" -Iteration 0 -Method "GET" -Url (Join-Url $RootUrl "actuator/health")
    $rows.Add((Convert-ResultToRow -Result $health)) | Out-Null
    Write-Host ("[MEASURE] health status={0} total={1}ms ttfb={2}ms" -f $health.HttpStatus, ($rows[-1].curl_total_ms), ($rows[-1].ttfb_ms))
}

if (-not $SkipPublicListBaseline) {
    $publicList = Invoke-CurlRequest -Label "public_adoption_list" -Iteration 0 -Method "GET" -Url (Join-Url $BaseUrl "adoption-posts?status=OPEN&page=0&size=1")
    $rows.Add((Convert-ResultToRow -Result $publicList)) | Out-Null
    Write-Host ("[MEASURE] public_adoption_list status={0} total={1}ms ttfb={2}ms" -f $publicList.HttpStatus, ($rows[-1].curl_total_ms), ($rows[-1].ttfb_ms))
}

function Register-And-LoginUser {
    param([Parameter(Mandatory = $true)][int]$Iteration)

    $email = if ($RegisterUserPerRun) {
        "$EmailPrefix.$suffix.$Iteration@$EmailDomain".ToLowerInvariant()
    } else {
        $ownerEmail
    }

    $registerJson = New-RequestJsonFile -Directory $RequestDir -Name ("register_user_{0:00}" -f $Iteration) -BodyObject ([ordered]@{
        email = $email
        password = $Password
        display_name = "Latency$Iteration"
        contact_phone = "01012345678"
        region = "Seoul"
    })

    $register = Invoke-CurlRequest -Label "auth_register" -Iteration $Iteration -Method "POST" -Url (Join-Url $BaseUrl "auth/register") -JsonFile $registerJson
    $rows.Add((Convert-ResultToRow -Result $register -Note $email)) | Out-Null
    Write-Host ("[MEASURE] auth_register run={0} status={1} total={2}ms" -f $Iteration, $register.HttpStatus, ($rows[-1].curl_total_ms))
    if ($register.HttpStatus -lt 200 -or $register.HttpStatus -ge 300) {
        throw "auth_register failed: HTTP $($register.HttpStatus) body=$($register.BodyText) curl=$($register.CurlOutput)"
    }

    $loginJson = New-RequestJsonFile -Directory $RequestDir -Name ("login_user_{0:00}" -f $Iteration) -BodyObject ([ordered]@{
        email = $email
        password = $Password
    })

    $login = Invoke-CurlRequest -Label "auth_login" -Iteration $Iteration -Method "POST" -Url (Join-Url $BaseUrl "auth/login") -JsonFile $loginJson
    $rows.Add((Convert-ResultToRow -Result $login -Note $email)) | Out-Null
    Write-Host ("[MEASURE] auth_login run={0} status={1} total={2}ms" -f $Iteration, $login.HttpStatus, ($rows[-1].curl_total_ms))
    if ($login.HttpStatus -lt 200 -or $login.HttpStatus -ge 300) {
        throw "auth_login failed: HTTP $($login.HttpStatus) body=$($login.BodyText) curl=$($login.CurlOutput)"
    }

    $token = Get-JsonProperty -Object $login.Json -Name "access_token"
    if ([string]::IsNullOrWhiteSpace([string]$token)) {
        throw "auth_login response did not include access_token."
    }
    return [string]$token
}

if (-not $RegisterUserPerRun) {
    $ownerToken = Register-And-LoginUser -Iteration 0
}

for ($run = 1; $run -le $Runs; $run++) {
    if ($RegisterUserPerRun) {
        $ownerToken = Register-And-LoginUser -Iteration $run
    }

    $forms = @(
        "name=LatencyDog-$suffix-$run",
        "breed=MIX",
        "gender=UNKNOWN",
        "age=1",
        "price=0",
        "description=latency measurement $suffix run $run",
        "health=healthy"
    )
    foreach ($image in $images) {
        $forms += "nose_images=@$image;type=$(Get-ImageMimeType -Path $image)"
    }

    $dogRegister = Invoke-CurlRequest `
        -Label "dog_registration" `
        -Iteration $run `
        -Method "POST" `
        -Url (Join-Url $BaseUrl "dogs/register") `
        -Headers @{ Authorization = "Bearer $ownerToken" } `
        -Forms $forms

    $row = Convert-ResultToRow -Result $dogRegister
    $rows.Add($row) | Out-Null

    Write-Host ("[MEASURE] dog_registration run={0} status={1} total={2}ms ttfb={3}ms upload={4}B allowed={5} dog_status={6} error={7}" -f `
        $run,
        $dogRegister.HttpStatus,
        $row.curl_total_ms,
        $row.ttfb_ms,
        $row.upload_bytes,
        $row.registration_allowed,
        $row.dog_status,
        $row.error_code)

    if ($dogRegister.HttpStatus -lt 200 -or $dogRegister.HttpStatus -ge 300) {
        Write-Warning "dog_registration returned non-2xx. Body: $($dogRegister.BodyText)"
    }
}

$csvPath = Join-Path $RunOutputDir "latency.csv"
$rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

$summaryByLabel = [ordered]@{}
foreach ($group in ($rows | Group-Object label)) {
    $summaryByLabel[$group.Name] = Get-Stats -Rows @($group.Group)
}

$totalImageBytes = 0L
foreach ($image in $imageEvidence) {
    $totalImageBytes += [long]$image["bytes"]
}

$dogRows = @($rows | Where-Object { $_.label -eq "dog_registration" })
$summary = [ordered]@{
    generated_at = (Get-Date).ToString("o")
    root_url = $RootUrl
    base_url = $BaseUrl
    runs = $Runs
    register_user_per_run = [bool]$RegisterUserPerRun
    output_dir = (Join-Path $OutputDir $runStamp)
    images = $imageEvidence
    total_image_bytes_per_registration = $totalImageBytes
    stats_by_label = $summaryByLabel
    dog_registration_statuses = @($dogRows | ForEach-Object {
        [ordered]@{
            iteration = $_.iteration
            http_status = $_.http_status
            total_ms = $_.curl_total_ms
            ttfb_ms = $_.ttfb_ms
            upload_bytes = $_.upload_bytes
            registration_allowed = $_.registration_allowed
            dog_status = $_.dog_status
            verification_status = $_.verification_status
            embedding_status = $_.embedding_status
            error_code = $_.error_code
            message = $_.message
        }
    })
    notes = @(
        "This is client-observed latency from the machine running the script.",
        "time_starttransfer includes server processing time until first response byte.",
        "dog_registration after the first successful registration with the same images may be DUPLICATE_SUSPECTED.",
        "Image paths are redacted in summary.json; only size and MIME type are retained.",
        "Raw responses are not retained unless -KeepRawResponses is passed, to avoid storing JWTs."
    )
}

$summaryPath = Join-Path $RunOutputDir "summary.json"
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Remove-Item -LiteralPath $RequestDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "[DONE] CSV:     $csvPath"
Write-Host "[DONE] Summary: $summaryPath"
Write-Host ""
Write-Host "[SUMMARY]"
foreach ($key in $summaryByLabel.Keys) {
    $stats = $summaryByLabel[$key]
    Write-Host ("  {0}: count={1}, mean={2}ms, p50={3}ms, p95={4}ms, min={5}ms, max={6}ms" -f `
        $key, $stats.count, $stats.mean_ms, $stats.p50_ms, $stats.p95_ms, $stats.min_ms, $stats.max_ms)
}
