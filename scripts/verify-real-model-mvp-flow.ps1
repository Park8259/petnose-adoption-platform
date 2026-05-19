#Requires -Version 5.1

[CmdletBinding()]
param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BaseUrl = "http://localhost",

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$NoseImagePath,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$HandoverNoseImagePath = "",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$ProfileImagePath = "",

    [switch]$StartCompose,
    [switch]$ResetRuntime,
    [switch]$KeepRuntime,

    [int]$ExpectedVectorDimension = 2048,
    [string]$ExpectedModelKeyword = "dog-nose-identification2",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$QdrantUrl = "http://localhost:6333",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$QdrantCollection = "dog_nose_embeddings_real_v1",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$PythonEmbedUrl = "http://localhost:8000",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$MySqlContainerName = "",

    [ValidateSet("auto", "skip", "require")]
    [string]$DbCheckMode = "auto"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Static review markers for the MVP flow verified below:
# /api/auth/register, /api/auth/login, /api/users/me, /api/dogs/register,
# /api/adoption-posts, /api/adoption-posts/{post_id}/handover-verifications,
# /files/{relative_path}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$DockerDir = Join-Path $RepoRoot "infra\docker"
$ComposeEnvFile = Join-Path $DockerDir ".env"
$script:StepNumber = 0
$script:StartedCompose = $false
$script:DbCheckSummary = "SKIP: DB direct check was not attempted."
$script:QdrantCheckSummary = "SKIP: Qdrant direct check was not attempted."

$Curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue
if ($null -eq $Curl) {
    throw "curl.exe is required for stable multipart/status handling on Windows PowerShell and pwsh."
}

if (-not (Test-Path -LiteralPath $NoseImagePath -PathType Leaf)) {
    throw "NoseImagePath not found: $NoseImagePath"
}
$ResolvedNoseImagePath = (Resolve-Path -LiteralPath $NoseImagePath).Path

if ([string]::IsNullOrWhiteSpace($HandoverNoseImagePath)) {
    $ResolvedHandoverNoseImagePath = $ResolvedNoseImagePath
} else {
    if (-not (Test-Path -LiteralPath $HandoverNoseImagePath -PathType Leaf)) {
        throw "HandoverNoseImagePath not found: $HandoverNoseImagePath"
    }
    $ResolvedHandoverNoseImagePath = (Resolve-Path -LiteralPath $HandoverNoseImagePath).Path
}

if ([string]::IsNullOrWhiteSpace($ProfileImagePath)) {
    $ResolvedProfileImagePath = $ResolvedNoseImagePath
} else {
    if (-not (Test-Path -LiteralPath $ProfileImagePath -PathType Leaf)) {
        throw "ProfileImagePath not found: $ProfileImagePath"
    }
    $ResolvedProfileImagePath = (Resolve-Path -LiteralPath $ProfileImagePath).Path
}

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    throw "BaseUrl must not be empty."
}

$BaseUrl = $BaseUrl.TrimEnd("/")
if ($BaseUrl.ToLowerInvariant().EndsWith("/api")) {
    $ApiBaseUrl = $BaseUrl
    $HttpRootUrl = $BaseUrl.Substring(0, $BaseUrl.Length - 4)
    if ([string]::IsNullOrWhiteSpace($HttpRootUrl)) {
        $HttpRootUrl = $BaseUrl
    }
} else {
    $HttpRootUrl = $BaseUrl
    $ApiBaseUrl = "$BaseUrl/api"
}

$QdrantUrl = $QdrantUrl.TrimEnd("/")
$PythonEmbedUrl = $PythonEmbedUrl.TrimEnd("/")

$script:ComposeArgs = @("compose")
if (Test-Path -LiteralPath $ComposeEnvFile -PathType Leaf) {
    $script:ComposeArgs += @("--env-file", $ComposeEnvFile)
} else {
    Write-Host "WARN: infra/docker/.env not found. docker compose will use file defaults and process environment." -ForegroundColor Yellow
}
$script:ComposeArgs += @(
    "-f", (Join-Path $DockerDir "compose.yaml"),
    "-f", (Join-Path $DockerDir "compose.dev.yaml"),
    "-f", (Join-Path $DockerDir "compose.real-model.yaml")
)

function Join-Url {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalizedRoot = $Root.TrimEnd("/")
    $normalizedPath = $Path.TrimStart("/")
    return "$normalizedRoot/$normalizedPath"
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
        ".webp" { return "image/webp" }
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

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$File,

        [string[]]$Arguments = @()
    )

    $output = & $File @Arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = @($output)
    }
}

function Invoke-DockerCompose {
    param(
        [string[]]$Arguments = @(),
        [switch]$AllowFailure
    )

    $result = Invoke-NativeCapture -File "docker" -Arguments ($script:ComposeArgs + $Arguments)
    if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
        throw "docker compose $($Arguments -join ' ') failed with exit code $($result.ExitCode): $($result.Output -join ' ')"
    }
    return $result
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

function Format-ResponseSummary {
    param([Parameter(Mandatory = $true)]$Response)

    $body = $Response.BodyText
    if ($null -eq $body) {
        $body = ""
    }
    if ($body.Length -gt 1200) {
        $body = $body.Substring(0, 1200) + "...(truncated)"
    }
    return "HTTP $($Response.StatusCode) $($Response.Method) $($Response.Url) body=$body"
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

function Assert-StatusIn {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][int[]]$ExpectedStatuses
    )

    if ($ExpectedStatuses -notcontains $Response.StatusCode) {
        throw "Expected HTTP status in [$($ExpectedStatuses -join ', ')], actual $($Response.StatusCode). $(Format-ResponseSummary $Response)"
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

function Assert-FieldAbsent {
    param(
        [Parameter(Mandatory = $false)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if (Test-JsonField -Object $Object -Name $Name) {
        throw "$Context must not expose field '$Name'."
    }
}

function Assert-NotNullOrEmpty {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value) {
        throw "$Name must be present, actual null."
    }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name must be non-empty."
    }
}

function Assert-Null {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -ne $Value) {
        throw "$Name must be null, actual '$Value'."
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

function Assert-False {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Value -ne $false) {
        throw "$Name must be false, actual '$Value'."
    }
}

function Assert-NumberAtLeast {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [double]$Minimum,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value) {
        throw "$Name must be present."
    }
    $actual = [double]$Value
    if ($actual -lt $Minimum) {
        throw "$Name must be >= $Minimum, actual $actual."
    }
}

function Assert-StringContains {
    param(
        [Parameter(Mandatory = $false)]$Value,
        [Parameter(Mandatory = $true)][string]$Needle,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Value -or -not "$Value".Contains($Needle)) {
        throw "$Name must contain '$Needle', actual '$Value'."
    }
}

function Assert-ErrorCodeIn {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][string[]]$ExpectedErrorCodes
    )

    if ($null -eq $Response.Json -or -not (Test-JsonField -Object $Response.Json -Name "error_code")) {
        throw "Expected error_code in response. $(Format-ResponseSummary $Response)"
    }
    if ($ExpectedErrorCodes -notcontains $Response.Json.error_code) {
        throw "Expected error_code in [$($ExpectedErrorCodes -join ', ')], actual '$($Response.Json.error_code)'. $(Format-ResponseSummary $Response)"
    }
}

function Wait-Until {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Check,

        [int]$TimeoutSeconds = 180,
        [int]$IntervalSeconds = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = ""
    while ((Get-Date) -lt $deadline) {
        try {
            $result = & $Check
            if ($result -eq $true) {
                Write-Host "READY: $Label" -ForegroundColor Green
                return
            }
            if ($null -ne $result) {
                $lastError = "$result"
            }
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds $IntervalSeconds
    }

    throw "Timed out waiting for $Label after ${TimeoutSeconds}s. Last result: $lastError"
}

function Get-QdrantVectorSize {
    param([Parameter(Mandatory = $true)]$CollectionJson)

    $vectors = $CollectionJson.result.config.params.vectors
    if ($null -eq $vectors) {
        return $null
    }
    if (Test-JsonField -Object $vectors -Name "size") {
        return [int]$vectors.size
    }
    $firstVector = $vectors.PSObject.Properties | Select-Object -First 1
    if ($null -ne $firstVector -and $null -ne $firstVector.Value -and (Test-JsonField -Object $firstVector.Value -Name "size")) {
        return [int]$firstVector.Value.size
    }
    return $null
}

function Get-QdrantPoint {
    param([Parameter(Mandatory = $true)][string]$PointId)

    if ([string]::IsNullOrWhiteSpace($QdrantUrl) -or [string]::IsNullOrWhiteSpace($QdrantCollection)) {
        throw "QdrantUrl and QdrantCollection are required for direct point checks."
    }

    $request = @{
        ids = @($PointId)
        with_payload = $true
        with_vector = $false
    }
    $response = Invoke-JsonRequest -Method "POST" -Url (Join-Url $QdrantUrl "collections/$QdrantCollection/points") -BodyObject $request
    Assert-Status -Response $response -ExpectedStatus 200
    return @($response.Json.result)
}

function Invoke-DbQuery {
    param([Parameter(Mandatory = $true)][string]$Sql)

    $escapedSql = $Sql.Replace("`"", "\`"")
    $shellCommand = "MYSQL_PWD=`"`$MYSQL_PASSWORD`" mysql -u`"`$MYSQL_USER`" `"`$MYSQL_DATABASE`" --batch --raw --skip-column-names -e `"$escapedSql`""

    if (-not [string]::IsNullOrWhiteSpace($MySqlContainerName)) {
        return Invoke-NativeCapture -File "docker" -Arguments @("exec", "-i", $MySqlContainerName, "sh", "-lc", $shellCommand)
    }

    return Invoke-DockerCompose -Arguments @("exec", "-T", "mysql", "sh", "-lc", $shellCommand) -AllowFailure
}

function Get-DbResultLines {
    param([object[]]$Output)

    return @($Output) |
            ForEach-Object { "$_".Trim() } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                -not $_.StartsWith("mysql: [Warning]") -and
                -not $_.StartsWith("Warning:")
            }
}

function Assert-DbScalar {
    param(
        [Parameter(Mandatory = $true)][string]$Sql,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $result = Invoke-DbQuery -Sql $Sql
    if ($result.ExitCode -ne 0) {
        throw "DB query failed for $Name. Output: $($result.Output -join ' ')"
    }
    $lines = @(Get-DbResultLines -Output $result.Output)
    if ($lines.Count -lt 1) {
        throw "DB query returned no scalar result for $Name. SQL: $Sql"
    }
    $actual = ($lines | Select-Object -First 1).ToString().Trim()
    if ($actual -ne $Expected) {
        throw "DB assertion failed for $Name. Expected '$Expected', actual '$actual'. SQL: $Sql"
    }
}

function Try-RunDbChecks {
    param(
        [Parameter(Mandatory = $true)][string]$FirstDogId,
        [Parameter(Mandatory = $true)][string]$DuplicateDogId,
        [Parameter(Mandatory = $true)][string]$PostId
    )

    if ($DbCheckMode -eq "skip") {
        $script:DbCheckSummary = "SKIP: DbCheckMode=skip."
        Write-Host $script:DbCheckSummary -ForegroundColor Yellow
        return
    }

    $probe = Invoke-DbQuery -Sql "SELECT 1"
    if ($probe.ExitCode -ne 0 -or @(Get-DbResultLines -Output $probe.Output).Count -lt 1) {
        if ($DbCheckMode -eq "require") {
            throw "DB probe failed: $($probe.Output -join ' ')"
        }
        $script:DbCheckSummary = "SKIP: DB direct check unavailable in auto mode. Probe output: $($probe.Output -join ' ')"
        Write-Host $script:DbCheckSummary -ForegroundColor Yellow
        return
    }

    Assert-DbScalar -Sql "SELECT status FROM dogs WHERE id = '$FirstDogId'" -Expected "ADOPTED" -Name "first dog adopted after completion"
    Assert-DbScalar -Sql "SELECT status FROM dogs WHERE id = '$DuplicateDogId'" -Expected "DUPLICATE_SUSPECTED" -Name "duplicate dog status"
    Assert-DbScalar -Sql "SELECT COUNT(*) FROM verification_logs WHERE dog_id = '$FirstDogId' AND result = 'PASSED'" -Expected "1" -Name "PASSED verification log"
    Assert-DbScalar -Sql "SELECT COUNT(*) FROM verification_logs WHERE dog_id = '$DuplicateDogId' AND result = 'DUPLICATE_SUSPECTED'" -Expected "1" -Name "DUPLICATE_SUSPECTED verification log"
    Assert-DbScalar -Sql "SELECT status FROM adoption_posts WHERE id = $PostId" -Expected "COMPLETED" -Name "post completed status"
    Assert-DbScalar -Sql "SELECT COUNT(*) FROM dog_images WHERE dog_id = '$FirstDogId' AND image_type = 'NOSE'" -Expected "1" -Name "NOSE image row"
    Assert-DbScalar -Sql "SELECT COUNT(*) FROM dog_images WHERE dog_id = '$FirstDogId' AND image_type = 'PROFILE'" -Expected "1" -Name "PROFILE image row"
    $legacyPrecheckTable = "nose_verification" + "_attempts"
    Assert-DbScalar -Sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '$legacyPrecheckTable'" -Expected "0" -Name "legacy precheck table absence"

    $script:DbCheckSummary = "PASS: DB direct checks passed for dogs, verification_logs, adoption_posts, dog_images, and table absence."
    Write-Host $script:DbCheckSummary -ForegroundColor Green
}

function Try-RunQdrantPointChecks {
    param(
        [Parameter(Mandatory = $true)][string]$FirstDogId,
        [Parameter(Mandatory = $true)][string]$DuplicateDogId
    )

    try {
        $firstPoints = Get-QdrantPoint -PointId $FirstDogId
        if (@($firstPoints).Count -lt 1) {
            throw "Expected Qdrant point for registered dog_id '$FirstDogId', but no point was returned."
        }

        $duplicatePoints = Get-QdrantPoint -PointId $DuplicateDogId
        if (@($duplicatePoints).Count -gt 0) {
            throw "Duplicate suspected dog_id '$DuplicateDogId' must not have a Qdrant point."
        }

        $script:QdrantCheckSummary = "PASS: Qdrant point exists for registered dog and is absent for duplicate suspected dog."
        Write-Host $script:QdrantCheckSummary -ForegroundColor Green
    } catch {
        $message = $_.Exception.Message
        if ($message -match "must not have a Qdrant point|Expected Qdrant point") {
            throw
        }
        $script:QdrantCheckSummary = "SKIP: Qdrant direct check unavailable. $message"
        Write-Host $script:QdrantCheckSummary -ForegroundColor Yellow
    }
}

function Wait-ForRuntimeReadiness {
    Invoke-Step "Readiness: Spring actuator health is UP" {
        Wait-Until -Label "Spring actuator health" -TimeoutSeconds 240 -IntervalSeconds 5 -Check {
            $response = Invoke-JsonRequest -Method "GET" -Url (Join-Url $HttpRootUrl "actuator/health")
            if ($response.StatusCode -ne 200) {
                return "HTTP $($response.StatusCode)"
            }
            if ($null -eq $response.Json -or $response.Json.status -ne "UP") {
                return "status=$($response.BodyText)"
            }
            return $true
        }
    }

    Invoke-Step "Readiness: Python embed real model health" {
        if ([string]::IsNullOrWhiteSpace($PythonEmbedUrl)) {
            Write-Host "SKIP: PythonEmbedUrl is empty." -ForegroundColor Yellow
            return
        }
        Wait-Until -Label "Python embed health" -TimeoutSeconds 240 -IntervalSeconds 5 -Check {
            $response = Invoke-JsonRequest -Method "GET" -Url (Join-Url $PythonEmbedUrl "health")
            if ($response.StatusCode -ne 200) {
                return "HTTP $($response.StatusCode)"
            }
            if ($null -eq $response.Json) {
                return "non-JSON response=$($response.BodyText)"
            }
            if ($response.Json.model_loaded -ne $true) {
                return "model_loaded=$($response.Json.model_loaded), load_error=$($response.Json.load_error)"
            }
            if ([int]$response.Json.vector_dim -ne $ExpectedVectorDimension) {
                return "vector_dim=$($response.Json.vector_dim)"
            }
            if ($null -eq $response.Json.model -or -not "$($response.Json.model)".Contains($ExpectedModelKeyword)) {
                return "model=$($response.Json.model)"
            }
            return $true
        }
    }

    Invoke-Step "Readiness: Qdrant collection is available" {
        if ([string]::IsNullOrWhiteSpace($QdrantUrl) -or [string]::IsNullOrWhiteSpace($QdrantCollection)) {
            Write-Host "SKIP: QdrantUrl or QdrantCollection is empty." -ForegroundColor Yellow
            return
        }
        Wait-Until -Label "Qdrant collection $QdrantCollection" -TimeoutSeconds 240 -IntervalSeconds 5 -Check {
            $health = Invoke-CurlRequest -Method "GET" -Url (Join-Url $QdrantUrl "healthz")
            if ($health.StatusCode -ne 200) {
                return "healthz HTTP $($health.StatusCode)"
            }

            $response = Invoke-JsonRequest -Method "GET" -Url (Join-Url $QdrantUrl "collections/$QdrantCollection")
            if ($response.StatusCode -ne 200) {
                return "collection HTTP $($response.StatusCode): $($response.BodyText)"
            }
            if ($null -eq $response.Json) {
                return "collection response is not JSON"
            }
            $size = Get-QdrantVectorSize -CollectionJson $response.Json
            if ($null -ne $size -and [int]$size -ne $ExpectedVectorDimension) {
                return "collection vector size=$size"
            }
            return $true
        }
    }

    Invoke-Step "Readiness: Spring dev qdrant config matches real-model settings" {
        $response = Invoke-JsonRequest -Method "GET" -Url (Join-Url $ApiBaseUrl "dev/qdrant-config")
        if ($response.StatusCode -eq 404) {
            Write-Host "SKIP: /api/dev/qdrant-config is not available for this profile." -ForegroundColor Yellow
            return
        }
        Assert-Status -Response $response -ExpectedStatus 200
        Assert-Equal -Actual $response.Json.collection -Expected $QdrantCollection -Name "dev qdrant collection"
        Assert-Equal -Actual $response.Json.vector_dimension -Expected $ExpectedVectorDimension -Name "dev qdrant vector_dimension"
    }
}

function Get-FileUrl {
    param([Parameter(Mandatory = $true)][string]$MaybeRelativeUrl)

    if ($MaybeRelativeUrl -match "^https?://") {
        return $MaybeRelativeUrl
    }
    return Join-Url $HttpRootUrl $MaybeRelativeUrl
}

$noseMimeType = Get-ImageMimeType -Path $ResolvedNoseImagePath
$handoverNoseMimeType = Get-ImageMimeType -Path $ResolvedHandoverNoseImagePath
$profileMimeType = Get-ImageMimeType -Path $ResolvedProfileImagePath
$allowedUploadMimeTypes = @("image/jpeg", "image/png")
if ($allowedUploadMimeTypes -notcontains $noseMimeType) {
    throw "NoseImagePath must be a real JPEG or PNG image file. Detected MIME from extension: $noseMimeType"
}
if ($allowedUploadMimeTypes -notcontains $handoverNoseMimeType) {
    throw "HandoverNoseImagePath must be a real JPEG or PNG image file. Detected MIME from extension: $handoverNoseMimeType"
}
if ($allowedUploadMimeTypes -notcontains $profileMimeType) {
    throw "ProfileImagePath must be a real JPEG or PNG image file. Detected MIME from extension: $profileMimeType"
}
$timestamp = Get-Date -Format "yyyyMMddHHmmssfff"
$email = "e2e-$timestamp@example.com"
$accessToken = $null
$firstDogId = $null
$duplicateDogId = $null
$postId = $null
$noseImageUrl = $null
$profileImageUrl = $null

Write-Host "PetNose real-model MVP E2E verification" -ForegroundColor Cyan
Write-Host "BaseUrl: $HttpRootUrl"
Write-Host "ApiBaseUrl: $ApiBaseUrl"
Write-Host "NoseImagePath: $ResolvedNoseImagePath"
Write-Host "HandoverNoseImagePath: $ResolvedHandoverNoseImagePath"
Write-Host "ProfileImagePath: $ResolvedProfileImagePath"
Write-Host "QdrantUrl: $QdrantUrl"
Write-Host "QdrantCollection: $QdrantCollection"

try {
    if ($StartCompose) {
        Invoke-Step "Docker compose config validation" {
            Invoke-DockerCompose -Arguments @("config", "--quiet") | Out-Null
        }

        if ($ResetRuntime) {
            Invoke-Step "Reset PetNose docker runtime" {
                Write-Host "ResetRuntime removes only the fixed PetNose compose project containers/volumes." -ForegroundColor Yellow
                Invoke-DockerCompose -Arguments @("down", "-v", "--remove-orphans") | Out-Null
            }
        }

        Invoke-Step "Start real-model docker runtime" {
            Invoke-DockerCompose -Arguments @("up", "-d", "--build") | Out-Null
            $script:StartedCompose = $true
        }
    }

    Wait-ForRuntimeReadiness

    Invoke-Step "A. Register user" {
        $body = @{
            email = $email
            password = "password123"
            display_name = "E2E유저"
            contact_phone = "01012341234"
            region = "Seoul"
        }
        $response = Invoke-JsonRequest -Method "POST" -Url (Join-Url $ApiBaseUrl "auth/register") -BodyObject $body
        Assert-Status -Response $response -ExpectedStatus 201
        Assert-NotNullOrEmpty -Value $response.Json.user_id -Name "register.user_id"
        Assert-Equal -Actual $response.Json.role -Expected "USER" -Name "register.role"
        Assert-FieldAbsent -Object $response.Json -Name "password_hash" -Context "register response"
        Write-Host "registered user_id=$($response.Json.user_id), email=$($response.Json.email)"
    }

    Invoke-Step "B. Login" {
        $body = @{
            email = $email
            password = "password123"
        }
        $response = Invoke-JsonRequest -Method "POST" -Url (Join-Url $ApiBaseUrl "auth/login") -BodyObject $body
        Assert-Status -Response $response -ExpectedStatus 200
        Assert-NotNullOrEmpty -Value $response.Json.access_token -Name "login.access_token"
        Assert-Equal -Actual $response.Json.token_type -Expected "Bearer" -Name "login.token_type"
        Assert-NotNullOrEmpty -Value $response.Json.expires_in -Name "login.expires_in"
        Assert-NotNullOrEmpty -Value $response.Json.user.user_id -Name "login.user.user_id"
        $script:accessToken = $response.Json.access_token
        Write-Host "login user_id=$($response.Json.user.user_id), token_type=$($response.Json.token_type)"
    }

    Invoke-Step "C. Get current user profile" {
        $response = Invoke-JsonRequest -Method "GET" -Url (Join-Url $ApiBaseUrl "users/me") -BearerToken $script:accessToken
        Assert-Status -Response $response -ExpectedStatus 200
        Assert-NotNullOrEmpty -Value $response.Json.user_id -Name "me.user_id"
        Assert-NotNullOrEmpty -Value $response.Json.email -Name "me.email"
        Assert-Equal -Actual $response.Json.role -Expected "USER" -Name "me.role"
        Assert-NotNullOrEmpty -Value $response.Json.display_name -Name "me.display_name"
        Assert-NotNullOrEmpty -Value $response.Json.contact_phone -Name "me.contact_phone"
        Assert-NotNullOrEmpty -Value $response.Json.region -Name "me.region"
        Assert-True -Value $response.Json.is_active -Name "me.is_active"
    }

    Invoke-Step "D. Register first dog with nose image" {
        $fields = @{
            name = "E2E초코"
            breed = "Maltese"
            gender = "MALE"
            birth_date = "2024-01-01"
            description = "E2E 정상 등록 테스트"
        }
        $files = @{
            nose_image = [pscustomobject]@{ Path = $ResolvedNoseImagePath; MimeType = $noseMimeType }
        }
        $response = Invoke-MultipartRequest -Url (Join-Url $ApiBaseUrl "dogs/register") -Fields $fields -Files $files -BearerToken $script:accessToken
        Assert-Status -Response $response -ExpectedStatus 201
        Assert-True -Value $response.Json.registration_allowed -Name "first dog registration_allowed"
        Assert-Equal -Actual $response.Json.status -Expected "REGISTERED" -Name "first dog status"
        Assert-Equal -Actual $response.Json.verification_status -Expected "VERIFIED" -Name "first dog verification_status"
        Assert-Equal -Actual $response.Json.embedding_status -Expected "COMPLETED" -Name "first dog embedding_status"
        Assert-NotNullOrEmpty -Value $response.Json.dog_id -Name "first dog dog_id"
        Assert-Equal -Actual $response.Json.qdrant_point_id -Expected $response.Json.dog_id -Name "first dog qdrant_point_id"
        Assert-Equal -Actual $response.Json.dimension -Expected $ExpectedVectorDimension -Name "first dog dimension"
        Assert-StringContains -Value $response.Json.model -Needle $ExpectedModelKeyword -Name "first dog model"
        Assert-NotNullOrEmpty -Value $response.Json.nose_image_url -Name "first dog nose_image_url"
        Assert-Null -Value $response.Json.profile_image_url -Name "first dog profile_image_url"
        Assert-Null -Value $response.Json.top_match -Name "first dog top_match"
        $script:firstDogId = $response.Json.dog_id
        $script:noseImageUrl = $response.Json.nose_image_url
        Write-Host "first dog_id=$script:firstDogId, qdrant_point_id=$($response.Json.qdrant_point_id)"
    }

    Invoke-Step "E. Register duplicate dog with same nose image" {
        $fields = @{
            name = "E2E중복초코"
            breed = "Maltese"
            gender = "MALE"
            birth_date = "2024-01-01"
            description = "E2E 중복 등록 테스트"
        }
        $files = @{
            nose_image = [pscustomobject]@{ Path = $ResolvedNoseImagePath; MimeType = $noseMimeType }
        }
        $response = Invoke-MultipartRequest -Url (Join-Url $ApiBaseUrl "dogs/register") -Fields $fields -Files $files -BearerToken $script:accessToken
        Assert-Status -Response $response -ExpectedStatus 200
        Assert-False -Value $response.Json.registration_allowed -Name "duplicate registration_allowed"
        Assert-Equal -Actual $response.Json.status -Expected "DUPLICATE_SUSPECTED" -Name "duplicate status"
        Assert-Equal -Actual $response.Json.verification_status -Expected "DUPLICATE_SUSPECTED" -Name "duplicate verification_status"
        Assert-Equal -Actual $response.Json.embedding_status -Expected "SKIPPED_DUPLICATE" -Name "duplicate embedding_status"
        Assert-NotNullOrEmpty -Value $response.Json.dog_id -Name "duplicate dog_id"
        Assert-Null -Value $response.Json.qdrant_point_id -Name "duplicate qdrant_point_id"
        Assert-NotNullOrEmpty -Value $response.Json.top_match -Name "duplicate top_match"
        Assert-Equal -Actual $response.Json.top_match.dog_id -Expected $script:firstDogId -Name "duplicate top_match.dog_id"
        Assert-NumberAtLeast -Value $response.Json.top_match.similarity_score -Minimum 0.70 -Name "duplicate top_match.similarity_score"
        Assert-FieldAbsent -Object $response.Json.top_match -Name "nose_image_url" -Context "duplicate top_match"
        $script:duplicateDogId = $response.Json.dog_id
        Write-Host "duplicate dog_id=$script:duplicateDogId, matched original=$($response.Json.top_match.dog_id)"
    }

    Invoke-Step "F. Create adoption post for registered dog" {
        $fields = @{
            dog_id = $script:firstDogId
            title = "E2E 말티즈 가족을 찾습니다"
            content = "E2E 테스트 분양글입니다."
            status = "OPEN"
        }
        $files = @{
            profile_image = [pscustomobject]@{ Path = $ResolvedProfileImagePath; MimeType = $profileMimeType }
        }
        $response = Invoke-MultipartRequest -Url (Join-Url $ApiBaseUrl "adoption-posts") -Fields $fields -Files $files -BearerToken $script:accessToken
        Assert-Status -Response $response -ExpectedStatus 201
        Assert-NotNullOrEmpty -Value $response.Json.post_id -Name "post.post_id"
        Assert-Equal -Actual $response.Json.dog_id -Expected $script:firstDogId -Name "post.dog_id"
        Assert-Equal -Actual $response.Json.status -Expected "OPEN" -Name "post.status"
        Assert-NotNullOrEmpty -Value $response.Json.published_at -Name "post.published_at"
        Assert-NotNullOrEmpty -Value $response.Json.created_at -Name "post.created_at"
        Assert-FieldAbsent -Object $response.Json -Name "author_user_id" -Context "post create response"
        $script:postId = $response.Json.post_id
        Write-Host "post_id=$script:postId"
    }

    Invoke-Step "G. Block adoption post for duplicate suspected dog" {
        $fields = @{
            dog_id = $script:duplicateDogId
            title = "E2E 중복견 게시글"
            content = "이 요청은 실패해야 합니다."
            status = "OPEN"
        }
        $files = @{
            profile_image = [pscustomobject]@{ Path = $ResolvedProfileImagePath; MimeType = $profileMimeType }
        }
        $response = Invoke-MultipartRequest -Url (Join-Url $ApiBaseUrl "adoption-posts") -Fields $fields -Files $files -BearerToken $script:accessToken
        Assert-StatusIn -Response $response -ExpectedStatuses @(400, 403, 404, 409)
        Assert-ErrorCodeIn -Response $response -ExpectedErrorCodes @("DOG_NOT_REGISTERED", "DOG_NOT_VERIFIED")
        Write-Host "blocked with error_code=$($response.Json.error_code)"
    }

    Invoke-Step "H. Public adoption post list hides nose image" {
        $response = Invoke-JsonRequest -Method "GET" -Url (Join-Url $ApiBaseUrl "adoption-posts?status=OPEN&page=0&size=20")
        Assert-Status -Response $response -ExpectedStatus 200
        Assert-NotNullOrEmpty -Value $response.Json.items -Name "list.items"
        $items = @($response.Json.items)
        $item = $items | Where-Object { "$($_.post_id)" -eq "$script:postId" } | Select-Object -First 1
        Assert-NotNullOrEmpty -Value $item -Name "created post in public list"
        Assert-NotNullOrEmpty -Value $item.profile_image_url -Name "list item profile_image_url"
        Assert-FieldAbsent -Object $item -Name "nose_image_url" -Context "public list item"
        $script:profileImageUrl = $item.profile_image_url
        Write-Host "public list contains post_id=$script:postId"
    }

    Invoke-Step "I. Public adoption post detail hides nose image" {
        $response = Invoke-JsonRequest -Method "GET" -Url (Join-Url $ApiBaseUrl "adoption-posts/$script:postId")
        Assert-Status -Response $response -ExpectedStatus 200
        Assert-Equal -Actual $response.Json.post_id -Expected $script:postId -Name "detail.post_id"
        Assert-Equal -Actual $response.Json.dog_id -Expected $script:firstDogId -Name "detail.dog_id"
        Assert-NotNullOrEmpty -Value $response.Json.profile_image_url -Name "detail.profile_image_url"
        Assert-FieldAbsent -Object $response.Json -Name "nose_image_url" -Context "public detail"
        Assert-FieldAbsent -Object $response.Json -Name "author_user_id" -Context "public detail"
        $script:profileImageUrl = $response.Json.profile_image_url
    }

    Invoke-Step "J. Handover verification matches handover nose image against registered dog" {
        $files = @{
            nose_image = [pscustomobject]@{ Path = $ResolvedHandoverNoseImagePath; MimeType = $handoverNoseMimeType }
        }
        $response = Invoke-MultipartRequest -Url (Join-Url $ApiBaseUrl "adoption-posts/$script:postId/handover-verifications") -Files $files -BearerToken $script:accessToken
        Assert-Status -Response $response -ExpectedStatus 200
        $handoverThreshold = 0.70
        if (Test-JsonField -Object $response.Json -Name "threshold") {
            $handoverThreshold = [double]$response.Json.threshold
        }
        Write-Host "handover image=$ResolvedHandoverNoseImagePath, similarity_score=$($response.Json.similarity_score), threshold=$handoverThreshold, decision=$($response.Json.decision), matched=$($response.Json.matched), model=$($response.Json.model), dimension=$($response.Json.dimension)"
        if ($response.Json.matched -ne $true -or "$($response.Json.decision)" -ne "MATCHED" -or [double]$response.Json.similarity_score -lt 0.70) {
            throw "Handover match failed. expected matched=true decision=MATCHED similarity_score>=0.70; actual matched=$($response.Json.matched), decision=$($response.Json.decision), similarity_score=$($response.Json.similarity_score), threshold=$handoverThreshold, image=$ResolvedHandoverNoseImagePath, model=$($response.Json.model), dimension=$($response.Json.dimension)"
        }
        Assert-Equal -Actual $response.Json.expected_dog_id -Expected $script:firstDogId -Name "handover.expected_dog_id"
        if (Test-JsonField -Object $response.Json -Name "match_threshold") {
            Assert-Equal -Actual $response.Json.match_threshold -Expected "0.70" -Name "handover.match_threshold"
        }
        if (Test-JsonField -Object $response.Json -Name "threshold") {
            Assert-Equal -Actual ([double]$response.Json.threshold) -Expected ([double]0.70) -Name "handover.threshold"
        }
        Assert-FieldAbsent -Object $response.Json -Name "nose_image_url" -Context "handover response"
        Assert-FieldAbsent -Object $response.Json -Name "top_matched_dog_id" -Context "handover response"
        Assert-FieldAbsent -Object $response.Json -Name "payload" -Context "handover response"
        Assert-FieldAbsent -Object $response.Json -Name "author_user_id" -Context "handover response"
    }

    Invoke-Step "K. Owner updates post status to COMPLETED" {
        $body = @{ status = "COMPLETED" }
        $response = Invoke-JsonRequest -Method "PATCH" -Url (Join-Url $ApiBaseUrl "adoption-posts/$script:postId/status") -BodyObject $body -BearerToken $script:accessToken
        Assert-Status -Response $response -ExpectedStatus 200
        Assert-Equal -Actual $response.Json.post_id -Expected $script:postId -Name "status.post_id"
        Assert-Equal -Actual $response.Json.status -Expected "COMPLETED" -Name "status.status"
        Assert-NotNullOrEmpty -Value $response.Json.closed_at -Name "status.closed_at"
    }

    Invoke-Step "L. Handover verification is rejected after COMPLETED" {
        $files = @{
            nose_image = [pscustomobject]@{ Path = $ResolvedHandoverNoseImagePath; MimeType = $handoverNoseMimeType }
        }
        $response = Invoke-MultipartRequest -Url (Join-Url $ApiBaseUrl "adoption-posts/$script:postId/handover-verifications") -Files $files -BearerToken $script:accessToken
        Assert-StatusIn -Response $response -ExpectedStatuses @(400, 409)
        Assert-ErrorCodeIn -Response $response -ExpectedErrorCodes @("POST_NOT_VERIFIABLE")
        Write-Host "rejected with error_code=$($response.Json.error_code)"
    }

    Invoke-Step "M. Static file URL is reachable" {
        $filePath = $script:profileImageUrl
        if ([string]::IsNullOrWhiteSpace($filePath)) {
            $filePath = $script:noseImageUrl
        }
        Assert-NotNullOrEmpty -Value $filePath -Name "file URL candidate"
        $fileUrl = Get-FileUrl -MaybeRelativeUrl $filePath
        $response = Invoke-CurlRequest -Method "GET" -Url $fileUrl
        Assert-Status -Response $response -ExpectedStatus 200
        Write-Host "file url OK: $fileUrl"
    }

    Invoke-Step "N. Qdrant direct point verification" {
        Try-RunQdrantPointChecks -FirstDogId $script:firstDogId -DuplicateDogId $script:duplicateDogId
    }

    Invoke-Step "O. Optional DB direct verification" {
        Try-RunDbChecks -FirstDogId $script:firstDogId -DuplicateDogId $script:duplicateDogId -PostId "$script:postId"
    }

    Write-Host ""
    Write-Host "Qdrant direct result: $script:QdrantCheckSummary" -ForegroundColor Cyan
    Write-Host "DB direct result: $script:DbCheckSummary" -ForegroundColor Cyan
    Write-Host "REAL MODEL MVP E2E VERIFICATION PASSED" -ForegroundColor Green
} finally {
    if ($script:StartedCompose -and -not $KeepRuntime) {
        Write-Host ""
        Write-Host "Cleaning up compose runtime started by this script. Use -KeepRuntime to leave it running." -ForegroundColor Yellow
        try {
            Invoke-DockerCompose -Arguments @("down", "--remove-orphans") -AllowFailure | Out-Null
        } catch {
            Write-Host "WARN: compose cleanup failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}
