param(
  [string]$TranscriptPath = "",
  [int]$WindowLimit = 1048576
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$resolvedPath = $TranscriptPath
if ([string]::IsNullOrWhiteSpace($resolvedPath) -or -not (Test-Path -LiteralPath $resolvedPath)) {
  $searchPattern = Join-Path $env:USERPROFILE ".gemini\antigravity\brain\*\.system_generated\logs\transcript.jsonl"
  $latestFile = Get-ChildItem -Path $searchPattern -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if ($null -eq $latestFile) {
    Write-Error "No transcript.jsonl file found."
    exit 1
  }
  $resolvedPath = $latestFile.FullName
}

$resolvedPath = (Resolve-Path -LiteralPath $resolvedPath).Path

$conversationId = ""
if ($resolvedPath -match 'brain[\\/]([^\\/]+)[\\/]\.system_generated') {
  $conversationId = $Matches[1]
}

$lines = [System.IO.File]::ReadAllLines($resolvedPath, [System.Text.Encoding]::UTF8)

$userTurns = 0
$plannerList = New-Object System.Collections.Generic.List[object]

foreach ($line in $lines) {
  if ([string]::IsNullOrWhiteSpace($line)) {
    continue
  }

  # Match top-level JSON fields at the start of the JSONL record before nested/escaped payloads.
  if ($line -match '^\{"step_index"\s*:\s*\d+\s*,\s*"source"\s*:\s*"[^"]*"\s*,\s*"type"\s*:\s*"USER_INPUT"') {
    $userTurns++
    continue
  }

  if ($line -match '^\{"step_index"\s*:\s*(\d+)\s*,\s*"source"\s*:\s*"[^"]*"\s*,\s*"type"\s*:\s*"PLANNER_RESPONSE"') {
    $stepIndex = [int]$Matches[1]

    # Slice before content/thinking/tool_calls/media so regex only inspects top-level metadata fields.
    $header = $line
    if ($line -match '^(.*?),(?:"content"|"thinking"|"tool_calls"|"media"|"truncated_fields")\s*:') {
      $header = $Matches[1]
    }

    $createdAt = if ($header -match '"created_at"\s*:\s*"([^"]+)"') { $Matches[1] } else { "" }
    $inputTokens = if ($header -match '"input_tokens"\s*:\s*(\d+)') { [long]$Matches[1] } else { 0L }
    $cacheReadTokens = if ($header -match '"cache_read_tokens"\s*:\s*(\d+)') { [long]$Matches[1] } else { 0L }
    $outputTokens = if ($header -match '"output_tokens"\s*:\s*(\d+)') { [long]$Matches[1] } else { 0L }
    $activeTokens = $inputTokens + $cacheReadTokens

    $plannerList.Add([PSCustomObject]@{
      step_index        = $stepIndex
      created_at        = $createdAt
      input_tokens      = $inputTokens
      cache_read_tokens = $cacheReadTokens
      output_tokens     = $outputTokens
      active_tokens     = $activeTokens
    })
  }
}

$plannerSteps = $plannerList.Count
if ($plannerSteps -eq 0) {
  $emptyResult = [PSCustomObject]@{
    transcript_path              = $resolvedPath
    conversation_id              = $conversationId
    window_limit                 = $WindowLimit
    user_turns                   = $userTurns
    planner_steps                = 0
    initial_context_tokens       = 0
    latest_step                  = 0
    latest_created_at            = ""
    latest_input_tokens          = 0
    latest_cache_read_tokens     = 0
    latest_output_tokens         = 0
    active_context_tokens        = 0
    session_growth_tokens        = 0
    remaining_tokens             = $WindowLimit
    used_percent                 = 0.0
    remaining_percent            = 100.0
    latest_cache_hit_rate        = 0.0
    cumulative_input_tokens      = 0
    cumulative_cache_read_tokens = 0
    cumulative_output_tokens     = 0
    compaction_count             = 0
    recent_steps                 = @()
  }
  $emptyResult | ConvertTo-Json -Depth 4
  exit 0
}

$first = $plannerList[0]
$latest = $plannerList[$plannerSteps - 1]

$initialContextTokens = [long]$first.active_tokens
$activeContextTokens = [long]$latest.active_tokens
$sessionGrowthTokens = [Math]::Max(0L, $activeContextTokens - $initialContextTokens)
$remainingTokens = [Math]::Max(0L, [long]$WindowLimit - $activeContextTokens)

$usedPercent = [Math]::Round(($activeContextTokens / [double]$WindowLimit) * 100, 2)
$remainingPercent = [Math]::Round(100.0 - $usedPercent, 2)
$latestCacheHitRate = [Math]::Round(($latest.cache_read_tokens / [double][Math]::Max(1L, $activeContextTokens)) * 100, 1)

$cumulativeInput = 0L
$cumulativeCacheRead = 0L
$cumulativeOutput = 0L
$compactionCount = 0

for ($i = 0; $i -lt $plannerSteps; $i++) {
  $item = $plannerList[$i]
  $cumulativeInput += $item.input_tokens
  $cumulativeCacheRead += $item.cache_read_tokens
  $cumulativeOutput += $item.output_tokens

  if ($i -gt 0) {
    $prev = $plannerList[$i - 1]
    if (($prev.active_tokens - $item.active_tokens) -gt 2000) {
      $compactionCount++
    }
  }
}

$recentCount = [Math]::Min(5, $plannerSteps)
$startIdx = $plannerSteps - $recentCount
$recentSteps = @()
for ($i = $startIdx; $i -lt $plannerSteps; $i++) {
  $recentSteps += $plannerList[$i]
}

$result = [PSCustomObject]@{
  transcript_path              = $resolvedPath
  conversation_id              = $conversationId
  window_limit                 = $WindowLimit
  user_turns                   = $userTurns
  planner_steps                = $plannerSteps
  initial_context_tokens       = $initialContextTokens
  latest_step                  = $latest.step_index
  latest_created_at            = $latest.created_at
  latest_input_tokens          = $latest.input_tokens
  latest_cache_read_tokens     = $latest.cache_read_tokens
  latest_output_tokens         = $latest.output_tokens
  active_context_tokens        = $activeContextTokens
  session_growth_tokens        = $sessionGrowthTokens
  remaining_tokens             = $remainingTokens
  used_percent                 = $usedPercent
  remaining_percent            = $remainingPercent
  latest_cache_hit_rate        = $latestCacheHitRate
  cumulative_input_tokens      = $cumulativeInput
  cumulative_cache_read_tokens = $cumulativeCacheRead
  cumulative_output_tokens     = $cumulativeOutput
  compaction_count             = $compactionCount
  recent_steps                 = $recentSteps
}

$result | ConvertTo-Json -Depth 4
