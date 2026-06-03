#Requires -Version 5.1
<#
.SYNOPSIS
Checks dry-run consistency between MySQL dog_nose_references and Qdrant active points.

.DESCRIPTION
Compares active MySQL dog_nose_references rows with active Qdrant points in a local/dev
Docker Compose runtime. The default mode has no write or delete side effects.

.EXAMPLE
pwsh ./scripts/check-qdrant-reference-consistency.ps1 -FailOnDrift

.EXAMPLE
pwsh ./scripts/check-qdrant-reference-consistency.ps1 `
  -EnvFile infra/docker/.env `
  -QdrantUrl http://localhost:6333 `
  -Collection dog_nose_embeddings_real_v2 `
  -OutputPath docs/ops-evidence/local-qdrant-reconciliation-dry-run.json
#>

[CmdletBinding()]
param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$QdrantUrl = "http://localhost:6333",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$Collection = "dog_nose_embeddings_real_v2",

    [AllowNull()]
    [AllowEmptyString()]
    [string]$EnvFile = "infra/docker/.env",

    [string[]]$ComposeFile = @(
        "infra/docker/compose.yaml",
        "infra/docker/compose.dev.yaml"
    ),

    [AllowNull()]
    [AllowEmptyString()]
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

    [AllowNull()]
    [AllowEmptyString()]
    [string]$OutputPath = "",

    [switch]$FailOnDrift,
    [switch]$DeleteOrphans,
    [switch]$ConfirmDelete,

    [int]$ExpectedDimension = 2048,

    [AllowNull()]
    [AllowEmptyString()]
    [string]$ExpectedDistance = "Cosine",

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Show-Usage {
    @"
Usage:
  pwsh ./scripts/check-qdrant-reference-consistency.ps1 [options]

Default behavior:
  - Dry-run only
  - No Qdrant deletes
  - Writes JSON summary to stdout
  - Writes JSON evidence only when -OutputPath is provided

Key options:
  -QdrantUrl <url>              Default: http://localhost:6333
  -Collection <name>            Default: dog_nose_embeddings_real_v2
  -EnvFile <path>               Default: infra/docker/.env
  -ComposeFile <paths[]>        Default: infra/docker/compose.yaml, infra/docker/compose.dev.yaml
  -MysqlService <service>       Default: mysql
  -MysqlDatabase <database>     Default: MYSQL_DATABASE from env file, then petnose
  -MysqlUser <user>             Default: MYSQL_USER from env file, then petnose
  -MysqlPassword <password>     Default: MYSQL_PASSWORD, then SPRING_DATASOURCE_PASSWORD
  -OutputPath <path>            Optional JSON evidence path
  -ExpectedDimension <int>      Default: 2048
  -ExpectedDistance <name>      Default: Cosine
  -FailOnDrift                  Exit 1 when consistency drift is found
  -DeleteOrphans                Delete Qdrant orphans only with -ConfirmDelete
  -ConfirmDelete                Required together with -DeleteOrphans
  -Help                         Print this help and exit

Safety:
  - Missing Qdrant points are never regenerated.
  - Payload mismatches are never patched.
  - Orphans are deleted only when both -DeleteOrphans and -ConfirmDelete are provided.
"@
}

if ($Help) {
    Show-Usage
    exit 0
}

try {
    if ($DeleteOrphans -and -not $ConfirmDelete) {
        throw "DeleteOrphans requires ConfirmDelete. Re-run with both flags only after saving evidence and receiving approval."
    }

    if ([string]::IsNullOrWhiteSpace($QdrantUrl)) {
        throw "QdrantUrl must not be empty."
    }
    if ([string]::IsNullOrWhiteSpace($Collection)) {
        throw "Collection must not be empty."
    }
    if ([string]::IsNullOrWhiteSpace($EnvFile)) {
        throw "EnvFile must not be empty."
    }
    if ([string]::IsNullOrWhiteSpace($MysqlService)) {
        throw "MysqlService must not be empty."
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedDistance)) {
        throw "ExpectedDistance must not be empty."
    }
    if ($ExpectedDimension -le 0) {
        throw "ExpectedDimension must be greater than zero."
    }

    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    function Resolve-RepoPath {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path
        )

        if ([System.IO.Path]::IsPathRooted($Path)) {
            return $Path
        }
        return (Join-Path $RepoRoot $Path)
    }

    function Resolve-ExistingRepoFile {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path,

            [Parameter(Mandatory = $true)]
            [string]$Label
        )

        $resolved = Resolve-RepoPath $Path
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "$Label not found: $Path"
        }
        return (Resolve-Path -LiteralPath $resolved).Path
    }

    $ResolvedEnvFile = Resolve-ExistingRepoFile $EnvFile "EnvFile"
    if ((Split-Path -Leaf $ResolvedEnvFile) -eq ".env.example") {
        throw "Refusing to use .env.example as runtime secrets. Copy it to infra/docker/.env and replace secret placeholders first."
    }

    $ResolvedComposeFiles = @()
    foreach ($file in $ComposeFile) {
        if ([string]::IsNullOrWhiteSpace($file)) {
            throw "ComposeFile contains an empty path."
        }
        $ResolvedComposeFiles += Resolve-ExistingRepoFile $file "ComposeFile"
    }

    function Read-DotEnv {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Path
        )

        $values = @{}
        $lines = Get-Content -LiteralPath $Path -Encoding UTF8
        foreach ($line in $lines) {
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
            [Parameter(Mandatory = $true)]
            [hashtable]$Values,

            [Parameter(Mandatory = $true)]
            [string[]]$Keys,

            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string]$Fallback
        )

        foreach ($key in $Keys) {
            if ($Values.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace([string]$Values[$key])) {
                return [string]$Values[$key]
            }
        }
        return $Fallback
    }

    $EnvValues = Read-DotEnv $ResolvedEnvFile
    if ([string]::IsNullOrWhiteSpace($MysqlDatabase)) {
        $MysqlDatabase = Get-ConfigValue $EnvValues @("MYSQL_DATABASE") "petnose"
    }
    if ([string]::IsNullOrWhiteSpace($MysqlUser)) {
        $MysqlUser = Get-ConfigValue $EnvValues @("MYSQL_USER", "SPRING_DATASOURCE_USERNAME") "petnose"
    }
    if ([string]::IsNullOrWhiteSpace($MysqlPassword)) {
        $MysqlPassword = Get-ConfigValue $EnvValues @("MYSQL_PASSWORD", "SPRING_DATASOURCE_PASSWORD") ""
    }
    if ([string]::IsNullOrWhiteSpace($MysqlPassword)) {
        throw "MysqlPassword was not provided and MYSQL_PASSWORD/SPRING_DATASOURCE_PASSWORD was not found in EnvFile."
    }

    $QdrantUrl = $QdrantUrl.TrimEnd("/")

    function Convert-ToNullableLong {
        param([object]$Value)

        if ($null -eq $Value) {
            return $null
        }
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }
        return [long]$text
    }

    function Convert-ToNullableInt {
        param([object]$Value)

        if ($null -eq $Value) {
            return $null
        }
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }
        return [int]$text
    }

    function Convert-ToNullableString {
        param([object]$Value)

        if ($null -eq $Value) {
            return $null
        }
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }
        return $text
    }

    function Convert-ToBoolOrNull {
        param([object]$Value)

        if ($null -eq $Value) {
            return $null
        }
        if ($Value -is [bool]) {
            return $Value
        }
        $text = ([string]$Value).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }
        if ($text -eq "1" -or $text.Equals("true", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        if ($text -eq "0" -or $text.Equals("false", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        return $null
    }

    function Convert-ForCompare {
        param([object]$Value)

        if ($null -eq $Value) {
            return ""
        }
        if ($Value -is [bool]) {
            return $Value.ToString().ToLowerInvariant()
        }
        return [string]$Value
    }

    function Convert-ForJson {
        param([object]$Value)

        if ($null -eq $Value) {
            return $null
        }
        return $Value
    }

    function Get-ObjectValue {
        param(
            [AllowNull()]
            [object]$Object,

            [Parameter(Mandatory = $true)]
            [string]$Name
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

    function Add-MismatchIfDifferent {
        param(
            [Parameter(Mandatory = $true)]
            [object]$Mismatches,

            [Parameter(Mandatory = $true)]
            [string]$PointId,

            [Parameter(Mandatory = $true)]
            [string]$Field,

            [AllowNull()]
            [object]$MysqlValue,

            [AllowNull()]
            [object]$QdrantValue
        )

        if ((Convert-ForCompare $MysqlValue) -ne (Convert-ForCompare $QdrantValue)) {
            if ($null -eq $Mismatches -or -not ($Mismatches.PSObject.Methods.Name -contains "Add")) {
                throw "Mismatches must be a mutable collection."
            }
            $Mismatches.Add([pscustomobject]@{
                qdrant_point_id = $PointId
                field = $Field
                mysql = Convert-ForJson $MysqlValue
                qdrant = Convert-ForJson $QdrantValue
            }) | Out-Null
        }
    }

    function Sanitize-NativeOutput {
        param([object[]]$Output)

        $text = ($Output | ForEach-Object { [string]$_ }) -join " "
        if ([string]::IsNullOrWhiteSpace($text)) {
            return ""
        }
        return $text -replace [regex]::Escape($MysqlPassword), "[REDACTED]"
    }

    function Invoke-MySqlQuery {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Query
        )

        $composeArgs = @("compose", "--env-file", $ResolvedEnvFile)
        foreach ($file in $ResolvedComposeFiles) {
            $composeArgs += @("-f", $file)
        }
        $composeArgs += @(
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
            $MysqlUser,
            $MysqlDatabase,
            "-e",
            $Query
        )

        $previousMysqlPwd = [Environment]::GetEnvironmentVariable("MYSQL_PWD", "Process")
        [Environment]::SetEnvironmentVariable("MYSQL_PWD", $MysqlPassword, "Process")
        try {
            $output = & docker @composeArgs 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "docker compose mysql query failed with exit code $LASTEXITCODE. Output: $(Sanitize-NativeOutput $output)"
            }
            return @($output)
        } finally {
            [Environment]::SetEnvironmentVariable("MYSQL_PWD", $previousMysqlPwd, "Process")
        }
    }

    function Get-MySqlActiveReferences {
        $query = @"
SELECT
  qdrant_point_id,
  dog_id,
  embedding_kind,
  COALESCE(CAST(dog_image_id AS CHAR), ''),
  COALESCE(CAST(reference_index AS CHAR), ''),
  model,
  CAST(dimension AS CHAR),
  preprocess_version,
  quality_status,
  IF(is_active = 1, 'true', 'false')
FROM dog_nose_references
WHERE is_active = 1
ORDER BY qdrant_point_id;
"@
        $rows = Invoke-MySqlQuery $query
        $references = @()
        foreach ($row in $rows) {
            $line = [string]$row
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            $columns = $line.Split([char]"`t")
            if ($columns.Count -lt 10) {
                throw "Could not parse MySQL row. Expected 10 TSV columns."
            }
            $references += [pscustomobject]@{
                qdrant_point_id = Convert-ToNullableString $columns[0]
                dog_id = Convert-ToNullableString $columns[1]
                embedding_kind = Convert-ToNullableString $columns[2]
                dog_image_id = Convert-ToNullableLong $columns[3]
                reference_index = Convert-ToNullableInt $columns[4]
                model = Convert-ToNullableString $columns[5]
                dimension = Convert-ToNullableInt $columns[6]
                preprocess_version = Convert-ToNullableString $columns[7]
                quality_status = Convert-ToNullableString $columns[8]
                is_active = Convert-ToBoolOrNull $columns[9]
            }
        }
        return @($references)
    }

    function Get-HttpStatusCode {
        param([Parameter(Mandatory = $true)]$ErrorRecord)

        $response = $ErrorRecord.Exception.Response
        if ($null -eq $response) {
            return $null
        }
        if ($response.PSObject.Properties.Name -contains "StatusCode") {
            return [int]$response.StatusCode
        }
        return $null
    }

    function Invoke-QdrantJson {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Method,

            [Parameter(Mandatory = $true)]
            [string]$Path,

            [object]$Body = $null,

            [switch]$AllowNotFound
        )

        $uri = "$QdrantUrl/$($Path.TrimStart('/'))"
        try {
            if ($null -eq $Body) {
                return Invoke-RestMethod -Method $Method -Uri $uri
            }
            $json = $Body | ConvertTo-Json -Depth 30 -Compress
            return Invoke-RestMethod -Method $Method -Uri $uri -ContentType "application/json" -Body $json
        } catch {
            $statusCode = Get-HttpStatusCode $_
            if ($AllowNotFound -and $statusCode -eq 404) {
                return $null
            }
            throw "Qdrant request failed: $Method $uri. $($_.Exception.Message)"
        }
    }

    function Get-CollectionContract {
        $metadata = Invoke-QdrantJson -Method "GET" -Path "collections/$Collection" -AllowNotFound
        if ($null -eq $metadata) {
            return [pscustomobject]@{
                exists = $false
                dimension = $null
                distance = $null
            }
        }

        $dimension = $null
        $distance = $null
        $result = Get-ObjectValue $metadata "result"
        $config = Get-ObjectValue $result "config"
        $params = Get-ObjectValue $config "params"
        $vectors = Get-ObjectValue $params "vectors"
        if ($null -ne $vectors) {
            if ($vectors.PSObject.Properties.Name -contains "size") {
                $dimension = Convert-ToNullableInt (Get-ObjectValue $vectors "size")
                $distance = Convert-ToNullableString (Get-ObjectValue $vectors "distance")
            } else {
                $firstVector = $vectors.PSObject.Properties | Select-Object -First 1
                if ($null -ne $firstVector) {
                    $dimension = Convert-ToNullableInt (Get-ObjectValue $firstVector.Value "size")
                    $distance = Convert-ToNullableString (Get-ObjectValue $firstVector.Value "distance")
                }
            }
        }

        return [pscustomobject]@{
            exists = $true
            dimension = $dimension
            distance = $distance
        }
    }

    function Get-QdrantActivePoints {
        param(
            [Parameter(Mandatory = $true)]
            [bool]$CollectionExists
        )

        if (-not $CollectionExists) {
            return @()
        }

        $points = @()
        $nextOffset = $null
        do {
            $body = [ordered]@{
                limit = 256
                with_payload = $true
                with_vector = $false
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
            if ($null -ne $nextOffset) {
                $body.offset = $nextOffset
            }

            $response = Invoke-QdrantJson -Method "POST" -Path "collections/$Collection/points/scroll" -Body $body
            $result = Get-ObjectValue $response "result"
            $resultPoints = Get-ObjectValue $result "points"
            if ($null -eq $result -or $null -eq $resultPoints) {
                break
            }

            foreach ($point in @($resultPoints)) {
                $payload = Get-ObjectValue $point "payload"
                $points += [pscustomobject]@{
                    qdrant_point_id = [string](Get-ObjectValue $point "id")
                    dog_id = Convert-ToNullableString (Get-ObjectValue $payload "dog_id")
                    embedding_kind = Convert-ToNullableString (Get-ObjectValue $payload "embedding_kind")
                    dog_image_id = Convert-ToNullableLong (Get-ObjectValue $payload "dog_image_id")
                    reference_index = Convert-ToNullableInt (Get-ObjectValue $payload "reference_index")
                    model = Convert-ToNullableString (Get-ObjectValue $payload "model")
                    dimension = Convert-ToNullableInt (Get-ObjectValue $payload "dimension")
                    preprocess_version = Convert-ToNullableString (Get-ObjectValue $payload "preprocess_version")
                    is_active = Convert-ToBoolOrNull (Get-ObjectValue $payload "is_active")
                }
            }
            $nextOffset = Get-ObjectValue $result "next_page_offset"
        } while ($null -ne $nextOffset)

        return @($points)
    }

    function Convert-ReferenceSummary {
        param(
            [Parameter(Mandatory = $true)]
            [object]$Reference
        )

        return [pscustomobject]@{
            qdrant_point_id = $Reference.qdrant_point_id
            dog_id = $Reference.dog_id
            embedding_kind = $Reference.embedding_kind
            dog_image_id = $Reference.dog_image_id
            reference_index = $Reference.reference_index
            model = $Reference.model
            dimension = $Reference.dimension
            preprocess_version = $Reference.preprocess_version
        }
    }

    function Invoke-QdrantDeletePoints {
        param(
            [Parameter(Mandatory = $true)]
            [string[]]$PointIds
        )

        if ($PointIds.Count -eq 0) {
            return
        }

        $body = @{
            points = @($PointIds)
        }
        Invoke-QdrantJson -Method "POST" -Path "collections/$Collection/points/delete?wait=true" -Body $body | Out-Null
    }

    $mysqlReferences = Get-MySqlActiveReferences
    $collectionContract = Get-CollectionContract
    $qdrantPoints = Get-QdrantActivePoints -CollectionExists ([bool]$collectionContract.exists)

    $mysqlByPointId = @{}
    foreach ($reference in $mysqlReferences) {
        if ([string]::IsNullOrWhiteSpace($reference.qdrant_point_id)) {
            throw "MySQL active reference has empty qdrant_point_id."
        }
        $mysqlByPointId[$reference.qdrant_point_id] = $reference
    }

    $qdrantByPointId = @{}
    foreach ($point in $qdrantPoints) {
        if ([string]::IsNullOrWhiteSpace($point.qdrant_point_id)) {
            continue
        }
        $qdrantByPointId[$point.qdrant_point_id] = $point
    }

    $missingInQdrant = New-Object 'System.Collections.Generic.List[object]'
    $orphanInQdrant = New-Object 'System.Collections.Generic.List[object]'
    $payloadMismatches = New-Object 'System.Collections.Generic.List[object]'

    foreach ($reference in $mysqlReferences) {
        if (-not $qdrantByPointId.ContainsKey($reference.qdrant_point_id)) {
            $missingInQdrant.Add((Convert-ReferenceSummary $reference)) | Out-Null
            continue
        }

        $point = $qdrantByPointId[$reference.qdrant_point_id]
        Add-MismatchIfDifferent -Mismatches $payloadMismatches -PointId $reference.qdrant_point_id -Field "dog_id" -MysqlValue $reference.dog_id -QdrantValue $point.dog_id
        Add-MismatchIfDifferent -Mismatches $payloadMismatches -PointId $reference.qdrant_point_id -Field "embedding_kind" -MysqlValue $reference.embedding_kind -QdrantValue $point.embedding_kind
        Add-MismatchIfDifferent -Mismatches $payloadMismatches -PointId $reference.qdrant_point_id -Field "dog_image_id" -MysqlValue $reference.dog_image_id -QdrantValue $point.dog_image_id
        Add-MismatchIfDifferent -Mismatches $payloadMismatches -PointId $reference.qdrant_point_id -Field "reference_index" -MysqlValue $reference.reference_index -QdrantValue $point.reference_index
        Add-MismatchIfDifferent -Mismatches $payloadMismatches -PointId $reference.qdrant_point_id -Field "model" -MysqlValue $reference.model -QdrantValue $point.model
        Add-MismatchIfDifferent -Mismatches $payloadMismatches -PointId $reference.qdrant_point_id -Field "dimension" -MysqlValue $reference.dimension -QdrantValue $point.dimension
        Add-MismatchIfDifferent -Mismatches $payloadMismatches -PointId $reference.qdrant_point_id -Field "preprocess_version" -MysqlValue $reference.preprocess_version -QdrantValue $point.preprocess_version
        Add-MismatchIfDifferent -Mismatches $payloadMismatches -PointId $reference.qdrant_point_id -Field "is_active" -MysqlValue $reference.is_active -QdrantValue $point.is_active
    }

    foreach ($point in $qdrantPoints) {
        if (-not $mysqlByPointId.ContainsKey($point.qdrant_point_id)) {
            $orphanInQdrant.Add((Convert-ReferenceSummary $point)) | Out-Null
        }
    }

    $deletedOrphans = @()
    if ($DeleteOrphans -and $ConfirmDelete -and $orphanInQdrant.Count -gt 0) {
        $orphanPointIds = @($orphanInQdrant | ForEach-Object { [string]$_.qdrant_point_id })
        Invoke-QdrantDeletePoints -PointIds $orphanPointIds
        $deletedOrphans = $orphanPointIds
    }

    $distanceMatches = $false
    if ($null -ne $collectionContract.distance) {
        $distanceMatches = ([string]$collectionContract.distance).Equals($ExpectedDistance, [System.StringComparison]::OrdinalIgnoreCase)
    }

    $consistent = (
        [bool]$collectionContract.exists -and
        $collectionContract.dimension -eq $ExpectedDimension -and
        $distanceMatches -and
        $missingInQdrant.Count -eq 0 -and
        $orphanInQdrant.Count -eq 0 -and
        $payloadMismatches.Count -eq 0
    )

    $summary = [ordered]@{
        collection = $Collection
        checked_at = (Get-Date).ToUniversalTime().ToString("o")
        mysql_active_reference_count = $mysqlReferences.Count
        qdrant_active_point_count = $qdrantPoints.Count
        missing_in_qdrant = $missingInQdrant.ToArray()
        orphan_in_qdrant = $orphanInQdrant.ToArray()
        payload_mismatches = $payloadMismatches.ToArray()
        collection_contract = [ordered]@{
            exists = [bool]$collectionContract.exists
            dimension = $collectionContract.dimension
            distance = $collectionContract.distance
        }
        consistent = [bool]$consistent
        deleted_orphans = @($deletedOrphans)
    }

    $summaryJson = $summary | ConvertTo-Json -Depth 30
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutputPath = Resolve-RepoPath $OutputPath
        $outputDirectory = Split-Path -Parent $resolvedOutputPath
        if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($resolvedOutputPath, $summaryJson, $utf8NoBom)
    }

    Write-Output $summaryJson

    if (-not $consistent -and $FailOnDrift) {
        exit 1
    }
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 2
}
