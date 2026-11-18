$ErrorActionPreference = "Stop"

$stdinStream = [Console]::OpenStandardInput()
$reader = New-Object System.IO.StreamReader($stdinStream, [System.Text.Encoding]::UTF8)
$stdinText = $reader.ReadToEnd()

if ([string]::IsNullOrWhiteSpace($stdinText)) {
  [Console]::Out.Write("{}")
  exit 0
}

$payload = $stdinText | ConvertFrom-Json
$rawInput = [string]$payload.lastUserInput
$userQuery = if ($rawInput -match '<USER_REQUEST>([\s\S]*?)</USER_REQUEST>') {
  $Matches[1].Trim()
} else {
  $rawInput.Trim()
}
$firstLine = ($userQuery -split '\r?\n')[0].Trim()

if ($firstLine -notmatch '(?i)^/context(?:\s+.*)?$') {
  [Console]::Out.Write("{}")
  exit 0
}

$convId = [string]$payload.conversationId
$candidates = New-Object System.Collections.Generic.List[string]
if (-not [string]::IsNullOrWhiteSpace([string]$payload.transcriptPath)) {
  $candidates.Add([string]$payload.transcriptPath)
}
if (-not [string]::IsNullOrWhiteSpace($convId)) {
  $candidates.Add((Join-Path $env:USERPROFILE ".gemini\antigravity\brain\$convId\.system_generated\logs\transcript.jsonl"))
}
if (-not [string]::IsNullOrWhiteSpace([string]$payload.artifactDirectoryPath)) {
  $candidates.Add((Join-Path ([string]$payload.artifactDirectoryPath) ".system_generated\logs\transcript.jsonl"))
}

$resolvedTranscript = ""
foreach ($candidate in $candidates) {
  if (Test-Path -LiteralPath $candidate) {
    $resolvedTranscript = $candidate
    break
  }
}

$hudScript = Join-Path $PSScriptRoot "show-context-hud.ps1"
$argParts = @(
  "-NoProfile",
  "-STA",
  "-ExecutionPolicy", "Bypass",
  "-WindowStyle", "Hidden",
  "-File", "`"$hudScript`""
)
if (-not [string]::IsNullOrWhiteSpace($resolvedTranscript)) {
  $argParts += @("-TranscriptPath", "`"$resolvedTranscript`"")
}
if (-not [string]::IsNullOrWhiteSpace($convId)) {
  $argParts += @("-ConversationId", "`"$convId`"")
}

$cmdLine = "powershell.exe " + ($argParts -join " ")
$startup = New-CimInstance -Namespace root/cimv2 -ClassName Win32_ProcessStartup -Property @{ ShowWindow = [uint16]0 } -ClientOnly
$null = Invoke-CimMethod -Namespace root/cimv2 -ClassName Win32_Process -MethodName Create -Arguments @{
  CommandLine = $cmdLine
  ProcessStartupInformation = $startup
}

[Console]::Out.Write('{"terminationBehavior":"terminate"}')
