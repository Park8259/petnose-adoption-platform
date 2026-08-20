#Requires -Version 7.0
<#
.SYNOPSIS
Summarizes Spring [DogRegistrationTiming] logs for dog registration latency.

.DESCRIPTION
Parses one or more Spring server log files, extracts totalMs and stagesMs values,
and writes CSV/JSON evidence with p50/mean/p95 for the requested stage. The
primary use is comparing the embed_batch stage across Python Embed CPU-thread
experiment candidates.

.EXAMPLE
pwsh -NoProfile -File .\scripts\summarize-dog-registration-timing-log.ps1 `
  -LogPath .\candidate-default.spring.log `
  -Candidate default `
  -Stage embed_batch
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$LogPath,

    [string]$Candidate = "",

    [string]$Stage = "embed_batch",

    [string]$OutputDir = "docs/ops-evidence/aws-registration-latency/log-timing",

    [switch]$Help
)

$ErrorActionPreference = "Stop"

function Show-Usage {
    Write-Host @"
PetNose DogRegistrationTiming log summarizer

Required:
  -LogPath <one or more Spring log files>

Common:
  pwsh -NoProfile -File .\scripts\summarize-dog-registration-timing-log.ps1 \
    -LogPath .\candidate-default.spring.log \
    -Candidate default \
    -Stage embed_batch

Outputs:
  <OutputDir>/<timestamp>-<candidate>/dog-registration-timing.csv
  <OutputDir>/<timestamp>-<candidate>/summary.json
"@
}

if ($Help) {
    Show-Usage
    exit 0
}

function Resolve-InputPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return (Join-Path (Get-Location).Path $Path)
}

function Get-RegexValue {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern
    )
    $match = [regex]::Match($Text, $Pattern)
    if (-not $match.Success) {
        return $null
    }
    return $match.Groups["value"].Value.Trim()
}

function To-LongOrNull {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    $parsed = 0L
    if ([long]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function To-BoolOrNull {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -eq "true") { return $true }
    if ($text -eq "false") { return $false }
    return $null
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

function Get-StatsFromValues {
    param([double[]]$Values)
    $valueList = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($valueList.Count -eq 0) {
        return [ordered]@{ count = 0 }
    }

    $sum = 0.0
    foreach ($value in $valueList) {
        $sum += $value
    }

    return [ordered]@{
        count = $valueList.Count
        mean_ms = [math]::Round($sum / $valueList.Count, 2)
        p50_ms = Get-Percentile -Values $valueList -Percentile 50
        p95_ms = Get-Percentile -Values $valueList -Percentile 95
        min_ms = [math]::Round(($valueList | Measure-Object -Minimum).Minimum, 2)
        max_ms = [math]::Round(($valueList | Measure-Object -Maximum).Maximum, 2)
    }
}

function Get-ValueCounts {
    param(
        [object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$Property
    )

    $counts = [ordered]@{}
    foreach ($group in (@($Rows) | Group-Object -Property $Property)) {
        $name = [string]$group.Name
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = "<null>"
        }
        $counts[$name] = $group.Count
    }
    return $counts
}

function Parse-TimingLine {
    param(
        [Parameter(Mandatory = $true)][string]$Line,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][int]$LineNumber,
        [Parameter(Mandatory = $true)][string]$StageName
    )

    if ($Line.IndexOf("[DogRegistrationTiming]", [StringComparison]::Ordinal) -lt 0) {
        return $null
    }

    $stagesMatch = [regex]::Match($Line, "stagesMs=\{(?<stages>[^}]*)\}")
    if (-not $stagesMatch.Success) {
        return $null
    }

    $stages = [ordered]@{}
    foreach ($match in [regex]::Matches($stagesMatch.Groups["stages"].Value, "(?<key>[A-Za-z0-9_]+)=(?<value>-?\d+)")) {
        $stages[$match.Groups["key"].Value] = [long]$match.Groups["value"].Value
    }

    $stageMs = $null
    if ($stages.Contains($StageName)) {
        $stageMs = [long]$stages[$StageName]
    }

    return [pscustomobject]@{
        source_file = $SourcePath
        line_number = $LineNumber
        completed = To-BoolOrNull (Get-RegexValue -Text $Line -Pattern "completed=(?<value>[^,]*)")
        dog_id = Get-RegexValue -Text $Line -Pattern "dogId=(?<value>[^,]*)"
        result = Get-RegexValue -Text $Line -Pattern "result=(?<value>[^,]*)"
        total_ms = To-LongOrNull (Get-RegexValue -Text $Line -Pattern "totalMs=(?<value>-?\d+)")
        stage = $StageName
        stage_ms = $stageMs
        stages_json = ($stages | ConvertTo-Json -Compress)
        raw_line = $Line
    }
}

$resolvedLogs = New-Object System.Collections.Generic.List[string]
foreach ($path in $LogPath) {
    $candidatePath = Resolve-InputPath $path
    $hits = @(Resolve-Path -Path $candidatePath -ErrorAction SilentlyContinue)
    if ($hits.Count -eq 0) {
        throw "[CONFIG] LogPath not found: $path"
    }
    foreach ($hit in $hits) {
        $resolvedLogs.Add($hit.Path) | Out-Null
    }
}

$records = New-Object System.Collections.Generic.List[object]
foreach ($log in $resolvedLogs) {
    $lineNumber = 0
    Get-Content -LiteralPath $log -Encoding UTF8 | ForEach-Object {
        $lineNumber += 1
        $record = Parse-TimingLine -Line ([string]$_) -SourcePath $log -LineNumber $lineNumber -StageName $Stage
        if ($null -ne $record) {
            $records.Add($record) | Out-Null
        }
    }
}

if ($records.Count -eq 0) {
    throw "[DATA] No [DogRegistrationTiming] records found in the provided logs."
}

$recordArray = @($records.ToArray())
$runStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$safeCandidate = if ([string]::IsNullOrWhiteSpace($Candidate)) { "timing" } else { $Candidate -replace "[^A-Za-z0-9_.-]", "_" }
$RunOutputDir = Join-Path (Resolve-InputPath $OutputDir) "$runStamp-$safeCandidate"
New-Item -ItemType Directory -Force -Path $RunOutputDir | Out-Null

$csvPath = Join-Path $RunOutputDir "dog-registration-timing.csv"
$recordArray | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

$stageValues = @($recordArray | ForEach-Object { $_.stage_ms } | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
$totalValues = @($recordArray | ForEach-Object { $_.total_ms } | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })

$summary = [ordered]@{
    generated_at = (Get-Date).ToString("o")
    candidate = $Candidate
    stage = $Stage
    source_logs = @($resolvedLogs)
    output_dir = (Join-Path $OutputDir "$runStamp-$safeCandidate")
    record_count = $recordArray.Count
    records_with_stage_count = $stageValues.Count
    completed_counts = Get-ValueCounts -Rows $recordArray -Property "completed"
    result_counts = Get-ValueCounts -Rows $recordArray -Property "result"
    total_ms = Get-StatsFromValues -Values $totalValues
    stage_ms = Get-StatsFromValues -Values $stageValues
    notes = @(
        "stage_ms is parsed from Spring [DogRegistrationTiming] stagesMs.$Stage.",
        "For the CPU-thread experiment, compare stage_ms mean/p50/p95 across default, threads=1, and threads=2.",
        "This parser does not infer client latency; pair it with scripts/measure-aws-registration-latency.ps1 summary.json."
    )
}

$summaryPath = Join-Path $RunOutputDir "summary.json"
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host "[DONE] CSV:     $csvPath"
Write-Host "[DONE] Summary: $summaryPath"
Write-Host ""
Write-Host "[SUMMARY]"
Write-Host ("  candidate={0}, stage={1}, records={2}, records_with_stage={3}" -f $Candidate, $Stage, $recordArray.Count, $stageValues.Count)
$stats = $summary.stage_ms
Write-Host ("  {0}: count={1}, mean={2}ms, p50={3}ms, p95={4}ms, min={5}ms, max={6}ms" -f `
    $Stage, $stats.count, $stats.mean_ms, $stats.p50_ms, $stats.p95_ms, $stats.min_ms, $stats.max_ms)
