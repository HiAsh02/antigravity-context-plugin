param(
  [string]$TranscriptPath = "",
  [string]$ConversationId = ""
)

$ErrorActionPreference = "Stop"

# Single-instance cleanup: close any previously opened HUD window before showing the new one.
$existingHud = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '(?i)^"?(?:[^"\r\n]*\\)?powershell(?:\.exe)?"?\s+[^\r\n]*-File\s+"?[^"\r\n]*show-context-hud\.ps1' })
foreach ($old in $existingHud) {
  Stop-Process -Id $old.ProcessId -Force -ErrorAction SilentlyContinue
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

function Unescape-Text([string]$text) {
  return [System.Text.RegularExpressions.Regex]::Unescape($text)
}

function Format-Num([long]$value) {
  return $value.ToString("N0", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Read-Utf8([string]$path) {
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { return "" }
  return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}

function Parse-HexRgb([string]$hex, [string]$fallback) {
  $h = if ($hex) { $hex.Trim().TrimStart('#') } else { "" }
  if ($h.Length -eq 3) {
    $h = "$($h[0])$($h[0])$($h[1])$($h[1])$($h[2])$($h[2])"
  }
  if ($h -notmatch '^[0-9a-fA-F]{6}$') {
    $h = $fallback.TrimStart('#')
  }
  return @(
    [Convert]::ToInt32($h.Substring(0, 2), 16),
    [Convert]::ToInt32($h.Substring(2, 2), 16),
    [Convert]::ToInt32($h.Substring(4, 2), 16)
  )
}

function Mix-HexColor([string]$hex1, [string]$hex2, [double]$weight1) {
  $c1 = Parse-HexRgb $hex1 "#000000"
  $c2 = Parse-HexRgb $hex2 "#FFFFFF"
  $w1 = [Math]::Max(0.0, [Math]::Min(1.0, $weight1))
  $w2 = 1.0 - $w1
  $r = [int][Math]::Round($c1[0] * $w1 + $c2[0] * $w2)
  $g = [int][Math]::Round($c1[1] * $w1 + $c2[1] * $w2)
  $b = [int][Math]::Round($c1[2] * $w1 + $c2[2] * $w2)
  return ('#{0:X2}{1:X2}{2:X2}' -f $r, $g, $b)
}

function Normalize-Hex([string]$hex, [string]$fallback) {
  $rgb = Parse-HexRgb $hex $fallback
  return ('#{0:X2}{1:X2}{2:X2}' -f $rgb[0], $rgb[1], $rgb[2])
}

function Get-ClientThemePalette {
  $configPath = Join-Path $env:USERPROFILE ".gemini\config\config.json"
  $cfg = $null
  $cfgText = Read-Utf8 $configPath
  if ($cfgText) { try { $cfg = $cfgText | ConvertFrom-Json } catch {} }

  $us = if ($cfg -and $cfg.userSettings) { $cfg.userSettings } else { $null }
  $mode = if ($us -and $us.themeMode) { [string]$us.themeMode } else { "THEME_MODE_SYSTEM" }

  $isLight = $true
  if ($mode -eq "THEME_MODE_LIGHT") {
    $isLight = $true
  } elseif ($mode -eq "THEME_MODE_DARK") {
    $isLight = $false
  } else {
    try {
      $regVal = Get-ItemPropertyValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "AppsUseLightTheme" -ErrorAction Stop
      $isLight = ([int]$regVal -ne 0)
    } catch {
      $isLight = $true
    }
  }

  if ($isLight) {
    $seeds = if ($us -and $us.customThemeSeedsLight) { $us.customThemeSeedsLight } else { $null }
    $bgRaw = if ($seeds -and $seeds.background) { [string]$seeds.background } else { "#F7F7F8" }
    $fgRaw = if ($seeds -and $seeds.foregroundOverride) { [string]$seeds.foregroundOverride } elseif ($seeds -and $seeds.foreground) { [string]$seeds.foreground } else { "#1D1F21" }
    $priRaw = if ($seeds -and $seeds.primary) { [string]$seeds.primary } else { "#0EA5E9" }

    $bg = Normalize-Hex $bgRaw "#F7F7F8"
    $fg = Normalize-Hex $fgRaw "#1D1F21"
    $pri = Normalize-Hex $priRaw "#0EA5E9"

    return [PSCustomObject]@{
      isLight       = $true
      WindowBg      = $bg
      CardBg        = Mix-HexColor "#FFFFFF" $bg 0.65
      FillBg        = Mix-HexColor $fg $bg 0.06
      ChipBg        = Mix-HexColor $fg $bg 0.05
      CardBorder    = Mix-HexColor $fg $bg 0.12
      OuterBorder   = Mix-HexColor $fg $bg 0.20
      FgMain        = $fg
      FgSecondary   = Mix-HexColor $fg $bg 0.82
      FgMuted       = Mix-HexColor $fg $bg 0.58
      BaseBar       = "#0EA5E9"
      GrowthBar     = "#10B981"
      Warn          = "#D97706"
      WarnBg        = Mix-HexColor "#F59E0B" $bg 0.14
      WarnBorder    = Mix-HexColor "#D97706" $bg 0.35
      Danger        = "#DC2626"
      Primary       = $pri
      ShadowOpacity = 0.18
    }
  } else {
    $seeds = if ($us -and $us.customThemeSeedsDark) { $us.customThemeSeedsDark } else { $null }
    $bgRaw = if ($seeds -and $seeds.background) { [string]$seeds.background } else { "#14161B" }
    $fgRaw = if ($seeds -and $seeds.foregroundOverride) { [string]$seeds.foregroundOverride } elseif ($seeds -and $seeds.foreground) { [string]$seeds.foreground } else { "#F3F4F6" }
    $priRaw = if ($seeds -and $seeds.primary) { [string]$seeds.primary } else { "#38BDF8" }

    $bg = Normalize-Hex $bgRaw "#14161B"
    $fg = Normalize-Hex $fgRaw "#F3F4F6"
    $pri = Normalize-Hex $priRaw "#38BDF8"

    return [PSCustomObject]@{
      isLight       = $false
      WindowBg      = $bg
      CardBg        = Mix-HexColor "#FFFFFF" $bg 0.05
      FillBg        = Mix-HexColor $fg $bg 0.09
      ChipBg        = Mix-HexColor $fg $bg 0.07
      CardBorder    = Mix-HexColor $fg $bg 0.12
      OuterBorder   = Mix-HexColor $fg $bg 0.22
      FgMain        = $fg
      FgSecondary   = Mix-HexColor $fg $bg 0.82
      FgMuted       = Mix-HexColor $fg $bg 0.60
      BaseBar       = "#38BDF8"
      GrowthBar     = "#34D399"
      Warn          = "#FBBF24"
      WarnBg        = Mix-HexColor "#F59E0B" $bg 0.16
      WarnBorder    = Mix-HexColor "#FBBF24" $bg 0.35
      Danger        = "#F87171"
      Primary       = $pri
      ShadowOpacity = 0.50
    }
  }
}

function Estimate-Tokens([string]$text) {
  if ([string]::IsNullOrEmpty($text)) { return 0L }
  $cjkMatches = [regex]::Matches($text, '[\u4e00-\u9fff\u3400-\u4dbf\u3000-\u303f\uff00-\uffef]')
  $cjk = $cjkMatches.Count
  $rest = $text.Length - $cjk
  return [long][Math]::Max(1, [Math]::Round($cjk * 0.85 + $rest / 3.8))
}

function Parse-SkillSummary([string]$skillDir) {
  $skillFile = Join-Path $skillDir "SKILL.md"
  $content = Read-Utf8 $skillFile
  if ([string]::IsNullOrEmpty($content)) { return $null }
  $name = Split-Path -Leaf $skillDir
  $desc = ""
  if ($content -match '(?s)^---\r?\n(.*?)\r?\n---') {
    $fm = $Matches[1] -split '\r?\n'
    for ($i = 0; $i -lt $fm.Length; $i++) {
      if ($fm[$i] -match '^name\s*:\s*(.+)$') {
        $name = $Matches[1].Trim().Trim('"', "'")
      } elseif ($fm[$i] -match '^description\s*:\s*(.*)$') {
        $v = $Matches[1].Trim()
        if ($v -in '>-', '>', '|-', '|') {
          $parts = @()
          for ($j = $i + 1; $j -lt $fm.Length; $j++) {
            if ($fm[$j] -match '^[ \t]+\S') {
              $parts += $fm[$j].Trim()
              $i = $j
            } elseif ([string]::IsNullOrWhiteSpace($fm[$j]) -and $parts.Count -gt 0) {
              $i = $j
            } else {
              break
            }
          }
          $desc = $parts -join ' '
        } else {
          $desc = $v.Trim('"', "'")
        }
      }
    }
  }
  return [PSCustomObject]@{
    name   = $name
    tokens = Estimate-Tokens "- $name ($skillFile): $desc"
  }
}

function Get-DetailedBaseBreakdown([long]$initialTokens) {
  $isEstimated = ($initialTokens -le 0)
  $configDir = Join-Path $env:USERPROFILE ".gemini\config"
  $appDataDir = Join-Path $env:USERPROFILE ".gemini\antigravity"

  $cfg = $null
  $cfgText = Read-Utf8 (Join-Path $configDir "config.json")
  if ($cfgText) { try { $cfg = $cfgText | ConvertFrom-Json } catch {} }

  $plugins = New-Object System.Collections.Generic.List[object]
  $seenPluginDirs = @{}
  foreach ($rootEntry in @(
    @{ path = (Join-Path $configDir "plugins"); isBuiltin = $false },
    @{ path = (Join-Path $appDataDir "builtin\plugins"); isBuiltin = $true }
  )) {
    if (-not (Test-Path -LiteralPath $rootEntry.path)) { continue }
    foreach ($dir in (Get-ChildItem -LiteralPath $rootEntry.path -Directory -ErrorAction SilentlyContinue)) {
      if ($seenPluginDirs.ContainsKey($dir.Name)) { continue }
      $seenPluginDirs[$dir.Name] = $true
      $manifest = $null
      $mText = Read-Utf8 (Join-Path $dir.FullName "plugin.json")
      if ($mText) { try { $manifest = $mText | ConvertFrom-Json } catch {} }

      $enabled = $true
      if ($cfg -and $cfg.plugins -and $cfg.plugins.PSObject.Properties[$dir.Name]) {
        $pState = $cfg.plugins.PSObject.Properties[$dir.Name].Value
        if ($null -ne $pState.enabled) { $enabled = [bool]$pState.enabled }
      } elseif ($manifest -and $null -ne $manifest.disabled) {
        $enabled = -not [bool]$manifest.disabled
      }
      if (-not $enabled) { continue }

      $pName = if ($manifest -and $manifest.name) { [string]$manifest.name } else { $dir.Name }
      $mcpCfg = $null
      $mcpCfgText = Read-Utf8 (Join-Path $dir.FullName "mcp_config.json")
      if ($mcpCfgText) { try { $mcpCfg = $mcpCfgText | ConvertFrom-Json } catch {} }
      $mcpServers = @()
      if ($mcpCfg -and $mcpCfg.mcpServers) {
        $mcpServers = @($mcpCfg.mcpServers.PSObject.Properties | ForEach-Object { $_.Name })
      }

      $plugins.Add([PSCustomObject]@{
        dir          = $dir.Name
        name         = $pName
        root         = $dir.FullName
        mcpServers   = $mcpServers
        skillsTokens = 0L
        mcpTokens    = 0L
        rulesTokens  = 0L
        skillCount   = 0
        mcpToolCount = 0
      })
    }
  }

  $rulesTk = 0L
  $rulesNames = @()
  foreach ($f in @("GEMINI.md", "AGENTS.md")) {
    $t = Read-Utf8 (Join-Path $configDir $f)
    if ($t) {
      $tk = Estimate-Tokens $t
      $rulesTk += $tk
      $rulesNames += $f
    }
  }
  foreach ($p in $plugins) {
    $rDir = Join-Path $p.root "rules"
    if (Test-Path -LiteralPath $rDir) {
      foreach ($rf in (Get-ChildItem -LiteralPath $rDir -Filter "*.md" -File -ErrorAction SilentlyContinue)) {
        $tk = Estimate-Tokens (Read-Utf8 $rf.FullName)
        $rulesTk += $tk
        $p.rulesTokens += $tk
        $rulesNames += "$($p.name)/$($rf.Name)"
      }
    }
  }

  $mcpTk = 0L
  $mcpFileCount = 0
  $mcpRoot = Join-Path $appDataDir "mcp"
  if (Test-Path -LiteralPath $mcpRoot) {
    foreach ($srv in (Get-ChildItem -LiteralPath $mcpRoot -Directory -ErrorAction SilentlyContinue)) {
      $ownerPlugin = $null
      foreach ($p in $plugins) {
        if ($srv.Name.StartsWith("$($p.name)_") -or ($p.mcpServers | Where-Object { $srv.Name -eq "$($p.name)_$_" })) {
          $ownerPlugin = $p
          break
        }
      }
      foreach ($mf in (Get-ChildItem -LiteralPath $srv.FullName -File -ErrorAction SilentlyContinue)) {
        if ($mf.Name -eq "instructions.md" -or $mf.Extension -eq ".json") {
          $tk = Estimate-Tokens (Read-Utf8 $mf.FullName)
          $mcpTk += $tk
          $mcpFileCount++
          if ($null -ne $ownerPlugin) {
            $ownerPlugin.mcpTokens += $tk
            if ($mf.Extension -eq ".json") { $ownerPlugin.mcpToolCount++ }
          }
        }
      }
    }
  }

  $skillsTk = 0L
  $skillCount = 0
  $seenSkills = @{}
  $userSkillCount = 0
  $pluginSkillCount = 0
  $builtinSkillCount = 0

  $userSkillsRoot = Join-Path $configDir "skills"
  if (Test-Path -LiteralPath $userSkillsRoot) {
    foreach ($sd in (Get-ChildItem -LiteralPath $userSkillsRoot -Directory -ErrorAction SilentlyContinue)) {
      $parsed = Parse-SkillSummary $sd.FullName
      if ($parsed -and -not $seenSkills.ContainsKey($parsed.name)) {
        $seenSkills[$parsed.name] = $true
        $skillsTk += $parsed.tokens
        $skillCount++
        $userSkillCount++
      }
    }
  }

  foreach ($p in $plugins) {
    $pSkillsDir = Join-Path $p.root "skills"
    if (Test-Path -LiteralPath $pSkillsDir) {
      foreach ($sd in (Get-ChildItem -LiteralPath $pSkillsDir -Directory -ErrorAction SilentlyContinue)) {
        $parsed = Parse-SkillSummary $sd.FullName
        if ($parsed -and -not $seenSkills.ContainsKey($parsed.name)) {
          $seenSkills[$parsed.name] = $true
          $skillsTk += $parsed.tokens
          $skillCount++
          $pluginSkillCount++
          $p.skillsTokens += $parsed.tokens
          $p.skillCount++
        }
      }
    }
  }

  $builtinSkillsRoot = Join-Path $appDataDir "builtin\skills"
  if (Test-Path -LiteralPath $builtinSkillsRoot) {
    foreach ($sd in (Get-ChildItem -LiteralPath $builtinSkillsRoot -Directory -ErrorAction SilentlyContinue)) {
      $parsed = Parse-SkillSummary $sd.FullName
      if ($parsed -and -not $seenSkills.ContainsKey($parsed.name)) {
        $seenSkills[$parsed.name] = $true
        $skillsTk += $parsed.tokens
        $skillCount++
        $builtinSkillCount++
      }
    }
  }

  $pluginsCatalogTk = 880L
  $systemTk = 10900L
  $total = $initialTokens
  if ($isEstimated) {
    $total = $rulesTk + $mcpTk + $skillsTk + $pluginsCatalogTk + $systemTk
  } else {
    $customSum = $rulesTk + $mcpTk + $skillsTk
    if ($customSum -gt $total) {
      $scale = $total / [double]$customSum
      $rulesTk = [long][Math]::Round($rulesTk * $scale)
      $mcpTk = [long][Math]::Round($mcpTk * $scale)
      $skillsTk = [long][Math]::Max(0, $total - $rulesTk - $mcpTk)
      $pluginsCatalogTk = 0L
    } else {
      $pluginsCatalogTk = [long][Math]::Min(880, [Math]::Max(0, $total - $customSum))
    }
    $systemTk = [long][Math]::Max(0, $total - ($rulesTk + $mcpTk + $skillsTk + $pluginsCatalogTk))
  }

  $pluginRows = @()
  foreach ($p in $plugins) {
    $comb = $p.skillsTokens + $p.mcpTokens + $p.rulesTokens
    $parts = @()
    if ($p.skillCount -gt 0) { $parts += "$($p.skillCount) Skill" }
    if ($p.mcpToolCount -gt 0) { $parts += "$($p.mcpToolCount) " + (Unescape-Text 'MCP \u5de5\u5177') }
    if ($p.rulesTokens -gt 0) { $parts += "Rules" }
    if ($parts.Count -eq 0) { $parts += (Unescape-Text 'Sidecar / \u8f7b\u91cf\u5316') }
    $pluginRows += [PSCustomObject]@{
      name       = $p.name
      components = ($parts -join ' / ')
      tokens     = $comb
    }
  }
  $pluginRows = @($pluginRows | Sort-Object tokens -Descending)

  return [PSCustomObject]@{
    isEstimated       = $isEstimated
    total             = $total
    system            = $systemTk
    skills            = $skillsTk
    rules             = $rulesTk
    mcp               = $mcpTk
    pluginsCatalog    = $pluginsCatalogTk
    skillCount        = $skillCount
    userSkillCount    = $userSkillCount
    pluginSkillCount  = $pluginSkillCount
    builtinSkillCount = $builtinSkillCount
    rulesNames        = ($rulesNames -join ', ')
    mcpFileCount      = $mcpFileCount
    pluginCount       = $plugins.Count
    pluginRows        = $pluginRows
  }
}

$palette = Get-ClientThemePalette
$windowLimit = 1048576L
$usage = $null
if (-not [string]::IsNullOrWhiteSpace($TranscriptPath) -and (Test-Path -LiteralPath $TranscriptPath)) {
  $usageScript = Join-Path $PSScriptRoot "get-context-usage.ps1"
  $usageJson = (& $usageScript -TranscriptPath $TranscriptPath | Out-String).Trim()
  if ($usageJson) { $usage = $usageJson | ConvertFrom-Json }
}

$hasSteps = ($null -ne $usage -and [int]$usage.planner_steps -gt 0)
$convId = if ($usage -and $usage.conversation_id) { [string]$usage.conversation_id } else { $ConversationId }
$initTokens = if ($hasSteps) { [long]$usage.initial_context_tokens } else { 0L }
$bd = Get-DetailedBaseBreakdown $initTokens

$activeTokens = if ($hasSteps) { [long]$usage.active_context_tokens } else { $bd.total }
$growthTokens = if ($hasSteps) { [long]$usage.session_growth_tokens } else { 0L }
$remTokens = [long][Math]::Max(0L, $windowLimit - $activeTokens)
$usedPct = [Math]::Round(($activeTokens / [double]$windowLimit) * 100, 2)
$remPct = [Math]::Round([Math]::Max(0.0, 100.0 - $usedPct), 2)
$baseClamped = [Math]::Min($bd.total, $activeTokens)
$basePct = [Math]::Round(($baseClamped / [double]$windowLimit) * 100, 2)
$growthPct = [Math]::Round([Math]::Max(0.0, $usedPct - $basePct), 2)

$inv = [System.Globalization.CultureInfo]::InvariantCulture

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        WindowStartupLocation="CenterScreen"
        Topmost="True"
        ShowInTaskbar="True"
        Width="610"
        MaxHeight="760"
        SizeToContent="Height"
        ResizeMode="NoResize">
  <Border x:Name="OuterBorder" CornerRadius="12" BorderThickness="1" Padding="16">
    <Border.Effect>
      <DropShadowEffect x:Name="OuterShadow" BlurRadius="22" ShadowDepth="5" Color="#000000"/>
    </Border.Effect>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
      </Grid.RowDefinitions>

      <!-- Title Bar -->
      <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent" Margin="0,0,0,12" Cursor="SizeAll">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock x:Name="HeaderIcon" FontSize="15" Margin="0,0,7,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="TitleText" Text="Context Window Monitor" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <Border x:Name="ConvBadgeBorder" CornerRadius="9" BorderThickness="1" Padding="7,2" Margin="9,0,0,0" VerticalAlignment="Center">
            <TextBlock x:Name="ConvBadgeText" FontSize="11" FontFamily="Consolas"/>
          </Border>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock x:Name="EscHintText" FontSize="11" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <Button x:Name="CloseBtn" Width="24" Height="24" BorderThickness="1" Cursor="Hand" FontSize="12" Padding="0">
            <Button.Resources>
              <Style TargetType="Border">
                <Setter Property="CornerRadius" Value="6"/>
              </Style>
            </Button.Resources>
          </Button>
        </StackPanel>
      </Grid>

      <!-- Scrollable Body -->
      <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel>
          <!-- Hero Card -->
          <Border x:Name="CardHero" CornerRadius="8" BorderThickness="1" Padding="13" Margin="0,0,0,10">
            <StackPanel>
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock x:Name="HeroLabel" FontSize="11" Margin="0,0,0,2"/>
                  <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock x:Name="HeroPctText" FontSize="24" FontWeight="Bold" FontFamily="Consolas"/>
                    <Border x:Name="CompactBadge" Visibility="Collapsed" CornerRadius="9" BorderThickness="1" Padding="7,2" Margin="8,0,0,0" VerticalAlignment="Center">
                      <TextBlock x:Name="CompactBadgeText" FontSize="11" FontWeight="SemiBold"/>
                    </Border>
                  </StackPanel>
                </StackPanel>
                <StackPanel Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Bottom">
                  <TextBlock x:Name="HeroActiveText" FontSize="12.5" FontWeight="SemiBold" FontFamily="Consolas" HorizontalAlignment="Right"/>
                  <TextBlock x:Name="HeroRemText" FontSize="11" HorizontalAlignment="Right" Margin="0,2,0,0"/>
                </StackPanel>
              </Grid>

              <!-- Dual-Segment Progress Bar -->
              <Border x:Name="HeroBarTrack" CornerRadius="5" Height="9" ClipToBounds="True" Margin="0,10,0,8">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition x:Name="BarColBase" Width="0*"/>
                    <ColumnDefinition x:Name="BarColGrowth" Width="0*"/>
                    <ColumnDefinition x:Name="BarColRem" Width="100*"/>
                  </Grid.ColumnDefinitions>
                  <Border x:Name="BarBaseSeg" Grid.Column="0"/>
                  <Border x:Name="BarGrowthSeg" Grid.Column="1"/>
                </Grid>
              </Border>

              <!-- Legend -->
              <StackPanel Orientation="Horizontal">
                <Border x:Name="LegBaseSwatch" Width="8" Height="8" CornerRadius="2" VerticalAlignment="Center" Margin="0,0,5,0"/>
                <TextBlock x:Name="LegBaseText" FontSize="11" Margin="0,0,14,0"/>
                <Border x:Name="LegGrowthSwatch" Width="8" Height="8" CornerRadius="2" VerticalAlignment="Center" Margin="0,0,5,0"/>
                <TextBlock x:Name="LegGrowthText" FontSize="11" Margin="0,0,14,0"/>
                <Border x:Name="LegRemSwatch" Width="8" Height="8" CornerRadius="2" BorderThickness="1" VerticalAlignment="Center" Margin="0,0,5,0"/>
                <TextBlock x:Name="LegRemText" FontSize="11"/>
              </StackPanel>
            </StackPanel>
          </Border>

          <!-- 2x2 Stat Grid -->
          <UniformGrid Columns="2" Rows="2" Margin="0,0,0,10">
            <Border x:Name="CardStat1" CornerRadius="8" BorderThickness="1" Padding="11" Margin="0,0,5,5">
              <StackPanel>
                <TextBlock x:Name="Stat1Title" FontSize="11"/>
                <TextBlock x:Name="Stat1Val" FontSize="16" FontWeight="Bold" FontFamily="Consolas" Margin="0,2,0,2"/>
                <TextBlock x:Name="Stat1Sub" FontSize="10.5" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
            </Border>
            <Border x:Name="CardStat2" CornerRadius="8" BorderThickness="1" Padding="11" Margin="5,0,0,5">
              <StackPanel>
                <TextBlock x:Name="Stat2Title" FontSize="11"/>
                <TextBlock x:Name="Stat2Val" FontSize="16" FontWeight="Bold" FontFamily="Consolas" Margin="0,2,0,2"/>
                <TextBlock x:Name="Stat2Sub" FontSize="10.5" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
            </Border>
            <Border x:Name="CardStat3" CornerRadius="8" BorderThickness="1" Padding="11" Margin="0,5,5,0">
              <StackPanel>
                <TextBlock x:Name="Stat3Title" FontSize="11"/>
                <TextBlock x:Name="Stat3Val" FontSize="16" FontWeight="Bold" FontFamily="Consolas" Margin="0,2,0,2"/>
                <TextBlock x:Name="Stat3Sub" FontSize="10.5" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
            </Border>
            <Border x:Name="CardStat4" CornerRadius="8" BorderThickness="1" Padding="11" Margin="5,5,0,0">
              <StackPanel>
                <TextBlock x:Name="Stat4Title" FontSize="11"/>
                <TextBlock x:Name="Stat4Val" FontSize="16" FontWeight="Bold" FontFamily="Consolas" Margin="0,2,0,2"/>
                <TextBlock x:Name="Stat4Sub" FontSize="10.5" TextTrimming="CharacterEllipsis"/>
              </StackPanel>
            </Border>
          </UniformGrid>

          <!-- Base Breakdown Card -->
          <Border x:Name="CardBreakdown" CornerRadius="8" BorderThickness="1" Padding="13" Margin="0,0,0,10">
            <StackPanel>
              <Grid Margin="0,0,0,8">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="BdTitle" FontSize="12" FontWeight="SemiBold"/>
                <TextBlock x:Name="BdMeta" Grid.Column="1" FontSize="11" FontFamily="Consolas"/>
              </Grid>

              <Border x:Name="BdBarTrack" CornerRadius="4" Height="7" ClipToBounds="True" Margin="0,0,0,9">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition x:Name="BdColSys" Width="1*"/>
                    <ColumnDefinition x:Name="BdColSkills" Width="1*"/>
                    <ColumnDefinition x:Name="BdColRules" Width="1*"/>
                    <ColumnDefinition x:Name="BdColMcp" Width="1*"/>
                    <ColumnDefinition x:Name="BdColPlug" Width="1*"/>
                  </Grid.ColumnDefinitions>
                  <Border x:Name="BdSegSys" Grid.Column="0"/>
                  <Border Grid.Column="1" Background="#8B5CF6"/>
                  <Border Grid.Column="2" Background="#10B981"/>
                  <Border Grid.Column="3" Background="#F59E0B"/>
                  <Border Grid.Column="4" Background="#EC4899"/>
                </Grid>
              </Border>

              <StackPanel x:Name="BdRowsPanel"/>

              <Border x:Name="BdDivider" BorderThickness="0,1,0,0" Margin="0,7,0,6" Padding="0,7,0,0">
                <StackPanel>
                  <TextBlock x:Name="PlugSubHeader" FontSize="10.5" Margin="0,0,0,4"/>
                  <WrapPanel x:Name="PluginChipsPanel"/>
                </StackPanel>
              </Border>
            </StackPanel>
          </Border>

          <!-- Recent 5 Steps Card -->
          <Border x:Name="CardRecent" CornerRadius="8" BorderThickness="1" Padding="13">
            <StackPanel>
              <Grid Margin="0,0,0,6">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="RecentTitle" FontSize="12" FontWeight="SemiBold"/>
                <TextBlock x:Name="RecentMeta" Grid.Column="1" FontSize="11"/>
              </Grid>
              <StackPanel x:Name="RecentRowsPanel"/>
            </StackPanel>
          </Border>
        </StackPanel>
      </ScrollViewer>
    </Grid>
  </Border>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$el = @{}
foreach ($name in @(
  "OuterBorder", "OuterShadow", "TitleBar", "HeaderIcon", "TitleText", "ConvBadgeBorder", "ConvBadgeText",
  "EscHintText", "CloseBtn", "CardHero", "HeroLabel", "HeroPctText", "CompactBadge", "CompactBadgeText",
  "HeroActiveText", "HeroRemText", "HeroBarTrack", "BarColBase", "BarColGrowth", "BarColRem",
  "BarBaseSeg", "BarGrowthSeg", "LegBaseSwatch", "LegBaseText", "LegGrowthSwatch", "LegGrowthText",
  "LegRemSwatch", "LegRemText", "CardStat1", "CardStat2", "CardStat3", "CardStat4",
  "Stat1Title", "Stat1Val", "Stat1Sub", "Stat2Title", "Stat2Val", "Stat2Sub",
  "Stat3Title", "Stat3Val", "Stat3Sub", "Stat4Title", "Stat4Val", "Stat4Sub",
  "CardBreakdown", "BdTitle", "BdMeta", "BdBarTrack", "BdColSys", "BdColSkills", "BdColRules",
  "BdColMcp", "BdColPlug", "BdSegSys", "BdRowsPanel", "BdDivider", "PlugSubHeader", "PluginChipsPanel",
  "CardRecent", "RecentTitle", "RecentMeta", "RecentRowsPanel"
)) {
  $el[$name] = $window.FindName($name)
}

$bc = [System.Windows.Media.BrushConverter]::new()
$brWinBg = $bc.ConvertFromString($palette.WindowBg)
$brCardBg = $bc.ConvertFromString($palette.CardBg)
$brFillBg = $bc.ConvertFromString($palette.FillBg)
$brChipBg = $bc.ConvertFromString($palette.ChipBg)
$brCardBorder = $bc.ConvertFromString($palette.CardBorder)
$brOuterBorder = $bc.ConvertFromString($palette.OuterBorder)
$brFgMain = $bc.ConvertFromString($palette.FgMain)
$brFgSec = $bc.ConvertFromString($palette.FgSecondary)
$brFgMuted = $bc.ConvertFromString($palette.FgMuted)
$brBaseBar = $bc.ConvertFromString($palette.BaseBar)
$brGrowthBar = $bc.ConvertFromString($palette.GrowthBar)
$brWarn = $bc.ConvertFromString($palette.Warn)
$brDanger = $bc.ConvertFromString($palette.Danger)

# Apply theme palette to shell and static cards
$el["OuterBorder"].Background = $brWinBg
$el["OuterBorder"].BorderBrush = $brOuterBorder
$el["OuterShadow"].Opacity = $palette.ShadowOpacity
$el["TitleText"].Foreground = $brFgMain
$el["ConvBadgeBorder"].Background = $brFillBg
$el["ConvBadgeBorder"].BorderBrush = $brCardBorder
$el["ConvBadgeText"].Foreground = $brFgMuted
$el["EscHintText"].Foreground = $brFgMuted
$el["CloseBtn"].Background = $brFillBg
$el["CloseBtn"].Foreground = $brFgSec
$el["CloseBtn"].BorderBrush = $brCardBorder

foreach ($cardName in @("CardHero", "CardStat1", "CardStat2", "CardStat3", "CardStat4", "CardBreakdown", "CardRecent")) {
  $el[$cardName].Background = $brCardBg
  $el[$cardName].BorderBrush = $brCardBorder
}

$el["CompactBadge"].Background = $bc.ConvertFromString($palette.WarnBg)
$el["CompactBadge"].BorderBrush = $bc.ConvertFromString($palette.WarnBorder)
$el["CompactBadgeText"].Foreground = $brWarn

foreach ($mutedName in @(
  "HeroLabel", "HeroRemText", "LegBaseText", "LegGrowthText", "LegRemText",
  "Stat1Title", "Stat1Sub", "Stat2Title", "Stat2Sub", "Stat3Title", "Stat3Sub", "Stat4Title", "Stat4Sub",
  "BdMeta", "PlugSubHeader", "RecentMeta"
)) {
  $el[$mutedName].Foreground = $brFgMuted
}

foreach ($mainName in @("HeroPctText", "Stat1Val", "Stat2Val", "Stat3Val", "Stat4Val")) {
  $el[$mainName].Foreground = $brFgMain
}

foreach ($secName in @("HeroActiveText", "BdTitle", "RecentTitle")) {
  $el[$secName].Foreground = $brFgSec
}

$el["HeroBarTrack"].Background = $brFillBg
$el["BdBarTrack"].Background = $brFillBg
$el["LegRemSwatch"].Background = $brFillBg
$el["LegRemSwatch"].BorderBrush = $brCardBorder
$el["BdDivider"].BorderBrush = $brCardBorder

$el["BarBaseSeg"].Background = $brBaseBar
$el["LegBaseSwatch"].Background = $brBaseBar
$el["BdSegSys"].Background = $brBaseBar

$activeGrowthBrush = $brGrowthBar
if ($usedPct -ge 85.0) {
  $activeGrowthBrush = $brDanger
} elseif ($usedPct -ge 60.0) {
  $activeGrowthBrush = $brWarn
}
$el["BarGrowthSeg"].Background = $activeGrowthBrush
$el["LegGrowthSwatch"].Background = $activeGrowthBrush

# Populate values
$el["HeaderIcon"].Text = Unescape-Text '\ud83d\udcca'
$el["EscHintText"].Text = Unescape-Text 'Esc \u5173\u95ed'
$el["CloseBtn"].Content = Unescape-Text '\u2715'

if ($convId) {
  $shortId = if ($convId.Length -gt 8) { $convId.Substring(0, 8) } else { $convId }
  $el["ConvBadgeText"].Text = $shortId
} else {
  $el["ConvBadgeBorder"].Visibility = [System.Windows.Visibility]::Collapsed
}

$el["HeroLabel"].Text = Unescape-Text '\u5f53\u524d\u4e0a\u4e0b\u6587\u7a97\u53e3\u5360\u7528'
$el["HeroPctText"].Text = $usedPct.ToString("0.00", $inv) + "%"
if ($usedPct -ge 60.0) {
  $el["CompactBadge"].Visibility = [System.Windows.Visibility]::Visible
  $el["CompactBadgeText"].Text = Unescape-Text '\u5efa\u8bae /compact'
}

$el["HeroActiveText"].Text = "$(Format-Num $activeTokens) / $(Format-Num $windowLimit)"
$el["HeroRemText"].Text = (Unescape-Text '\u5269\u4f59 ') + (Format-Num $remTokens) + " tokens ($($remPct.ToString('0.##', $inv))%)"

$el["BarColBase"].Width = New-Object System.Windows.GridLength ([Math]::Max(0.0, $basePct)), ([System.Windows.GridUnitType]::Star)
$el["BarColGrowth"].Width = New-Object System.Windows.GridLength ([Math]::Max(0.0, $growthPct)), ([System.Windows.GridUnitType]::Star)
$el["BarColRem"].Width = New-Object System.Windows.GridLength ([Math]::Max(0.01, $remPct)), ([System.Windows.GridUnitType]::Star)

$el["LegBaseText"].Text = (Unescape-Text '\u57fa\u7840\u5f00\u9500 ') + (Format-Num $bd.total)
$el["LegGrowthText"].Text = (Unescape-Text '\u4f1a\u8bdd\u589e\u91cf ') + (Format-Num $growthTokens)
$el["LegRemText"].Text = (Unescape-Text '\u5269\u4f59 ') + (Format-Num $remTokens)

$winPctLabel = Unescape-Text '\u5360\u7a97\u53e3'
$el["Stat1Title"].Text = Unescape-Text '\u57fa\u7840\u7cfb\u7edf\u5f00\u9500'
$el["Stat1Val"].Text = Format-Num $bd.total
$el["Stat1Sub"].Text = "$winPctLabel $($basePct.ToString('0.00', $inv))% · System / Skills / Rules / MCP"

$el["Stat2Title"].Text = Unescape-Text '\u4f1a\u8bdd\u7d2f\u8ba1\u589e\u91cf'
$el["Stat2Val"].Text = "+$(Format-Num $growthTokens)"
if ($hasSteps) {
  $el["Stat2Sub"].Text = "$($usage.user_turns) " + (Unescape-Text '\u8f6e\u63d0\u95ee') + " · $($usage.planner_steps) " + (Unescape-Text '\u6b21\u8c03\u7528')
  $el["Stat3Title"].Text = Unescape-Text '\u6700\u65b0\u8f6e\u6b21\u7f13\u5b58\u547d\u4e2d'
  $el["Stat3Val"].Text = "$([double]$usage.latest_cache_hit_rate)%"
  $el["Stat3Sub"].Text = (Unescape-Text '\u7f13\u5b58 ') + (Format-Num ([long]$usage.latest_cache_read_tokens)) + " · " + (Unescape-Text '\u65b0\u589e ') + (Format-Num ([long]$usage.latest_input_tokens))

  $cumPrompt = [long]$usage.cumulative_input_tokens + [long]$usage.cumulative_cache_read_tokens
  $overallHit = if ($cumPrompt -gt 0) { [Math]::Round(([long]$usage.cumulative_cache_read_tokens / [double]$cumPrompt) * 100, 1) } else { 0 }
  $el["Stat4Title"].Text = Unescape-Text '\u4f1a\u8bdd\u7d2f\u8ba1\u6d88\u8017'
  $el["Stat4Val"].Text = (Format-Num ([long]$usage.cumulative_output_tokens)) + " " + (Unescape-Text '\u8f93\u51fa')
  $el["Stat4Sub"].Text = (Unescape-Text '\u603b\u547d\u4e2d ') + "$overallHit% · " + (Unescape-Text '\u538b\u7f29 ') + "$($usage.compaction_count) " + (Unescape-Text '\u6b21')
} else {
  $el["Stat2Sub"].Text = Unescape-Text '0 \u8f6e\u63d0\u95ee · 0 \u6b21\u8c03\u7528'
  $el["Stat3Title"].Text = Unescape-Text '\u6700\u65b0\u8f6e\u6b21\u7f13\u5b58\u547d\u4e2d'
  $el["Stat3Val"].Text = "--"
  $el["Stat3Sub"].Text = Unescape-Text '\u65b0\u4f1a\u8bdd\u5c1a\u672a\u4ea7\u751f\u6a21\u578b\u8c03\u7528\uff08\u9884\u8ba1\u57fa\u51c6\uff09'
  $el["Stat4Title"].Text = Unescape-Text '\u4f1a\u8bdd\u7d2f\u8ba1\u6d88\u8017'
  $el["Stat4Val"].Text = "0 " + (Unescape-Text '\u8f93\u51fa')
  $el["Stat4Sub"].Text = "--"
}

$el["BdTitle"].Text = Unescape-Text '\u57fa\u7840\u7cfb\u7edf\u5f00\u9500\u8be6\u7ec6\u62c6\u89e3'
$bdWinPct = [Math]::Round(($bd.total / [double]$windowLimit) * 100, 2)
$el["BdMeta"].Text = "$(Format-Num $bd.total) tokens · $winPctLabel $($bdWinPct.ToString('0.00', $inv))%"

$el["BdColSys"].Width = New-Object System.Windows.GridLength ([Math]::Max(1, $bd.system)), ([System.Windows.GridUnitType]::Star)
$el["BdColSkills"].Width = New-Object System.Windows.GridLength ([Math]::Max(1, $bd.skills)), ([System.Windows.GridUnitType]::Star)
$el["BdColRules"].Width = New-Object System.Windows.GridLength ([Math]::Max(1, $bd.rules)), ([System.Windows.GridUnitType]::Star)
$el["BdColMcp"].Width = New-Object System.Windows.GridLength ([Math]::Max(1, $bd.mcp)), ([System.Windows.GridUnitType]::Star)
$el["BdColPlug"].Width = New-Object System.Windows.GridLength ([Math]::Max(1, $bd.pluginsCatalog)), ([System.Windows.GridUnitType]::Star)

$catDefs = @(
  @{ color = $palette.BaseBar; name = (Unescape-Text '\u7cfb\u7edf\u6838\u5fc3\u4e0e\u5185\u7f6e\u5de5\u5177'); desc = (Unescape-Text 'System Prompt + 19 \u4e2a\u5185\u7f6e\u5de5\u5177'); tk = $bd.system },
  @{ color = "#8B5CF6"; name = (Unescape-Text '\u6280\u80fd\u6458\u8981 (Skills)'); desc = (Unescape-Text '\u5171 ') + "$($bd.skillCount) " + (Unescape-Text '\u4e2a Skill') + " (User $($bd.userSkillCount) / Plugin $($bd.pluginSkillCount) / Builtin $($bd.builtinSkillCount))"; tk = $bd.skills },
  @{ color = "#10B981"; name = (Unescape-Text '\u6307\u4ee4\u4e0e\u89c4\u5219 (Rules)'); desc = $(if ($bd.rulesNames) { $bd.rulesNames } else { Unescape-Text 'GEMINI.md \u4e0e\u63d2\u4ef6\u89c4\u5219' }); tk = $bd.rules },
  @{ color = "#F59E0B"; name = (Unescape-Text 'MCP \u670d\u52a1\u4e0e\u5de5\u5177 Schema'); desc = "$($bd.mcpFileCount) " + (Unescape-Text '\u4e2a MCP') + " Schema / Instructions"; tk = $bd.mcp },
  @{ color = "#EC4899"; name = (Unescape-Text '\u63d2\u4ef6\u76ee\u5f55 (Plugins)'); desc = "$($bd.pluginCount) " + (Unescape-Text '\u4e2a\u5df2\u542f\u7528\u63d2\u4ef6') + " + Marketplace"; tk = $bd.pluginsCatalog }
)

foreach ($cat in $catDefs) {
  $pct = if ($bd.total -gt 0) { [Math]::Round(($cat.tk / [double]$bd.total) * 100, 1) } else { 0 }
  $rowGrid = New-Object System.Windows.Controls.Grid
  $rowGrid.Margin = New-Object System.Windows.Thickness(0, 2.5, 0, 2.5)
  $c1 = New-Object System.Windows.Controls.ColumnDefinition
  $c1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
  $c2 = New-Object System.Windows.Controls.ColumnDefinition
  $c2.Width = [System.Windows.GridLength]::Auto
  $rowGrid.ColumnDefinitions.Add($c1)
  $rowGrid.ColumnDefinitions.Add($c2)

  $leftSp = New-Object System.Windows.Controls.StackPanel
  $leftSp.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $dot = New-Object System.Windows.Controls.Border
  $dot.Width = 8
  $dot.Height = 8
  $dot.CornerRadius = New-Object System.Windows.CornerRadius(2)
  $dot.Background = $bc.ConvertFromString($cat.color)
  $dot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $dot.Margin = New-Object System.Windows.Thickness(0, 0, 7, 0)

  $t1 = New-Object System.Windows.Controls.TextBlock
  $t1.Text = $cat.name
  $t1.Foreground = $brFgMain
  $t1.FontSize = 11.5
  $t1.FontWeight = [System.Windows.FontWeights]::SemiBold
  $t1.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

  $t2 = New-Object System.Windows.Controls.TextBlock
  $t2.Text = "  $($cat.desc)"
  $t2.Foreground = $brFgMuted
  $t2.FontSize = 10.5
  $t2.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

  [void]$leftSp.Children.Add($dot)
  [void]$leftSp.Children.Add($t1)
  [void]$leftSp.Children.Add($t2)

  $rightTb = New-Object System.Windows.Controls.TextBlock
  $rightTb.Text = "$(Format-Num $cat.tk)  ($pct%)"
  $rightTb.Foreground = $brFgSec
  $rightTb.FontSize = 11.5
  $rightTb.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
  [System.Windows.Controls.Grid]::SetColumn($rightTb, 1)

  [void]$rowGrid.Children.Add($leftSp)
  [void]$rowGrid.Children.Add($rightTb)
  [void]$el["BdRowsPanel"].Children.Add($rowGrid)
}

$el["PlugSubHeader"].Text = (Unescape-Text '\u5df2\u542f\u7528\u63d2\u4ef6\u5f52\u56e0') + " (Skills + MCP + Rules)"
foreach ($pr in $bd.pluginRows) {
  $chip = New-Object System.Windows.Controls.Border
  $chip.CornerRadius = New-Object System.Windows.CornerRadius(6)
  $chip.Background = $brChipBg
  $chip.BorderBrush = $brCardBorder
  $chip.BorderThickness = New-Object System.Windows.Thickness(1)
  $chip.Padding = New-Object System.Windows.Thickness(7, 3, 7, 3)
  $chip.Margin = New-Object System.Windows.Thickness(0, 2, 6, 2)

  $chipTb = New-Object System.Windows.Controls.TextBlock
  $chipTb.Text = "$($pr.name): $(Format-Num $pr.tokens) ($($pr.components))"
  $chipTb.Foreground = $brFgSec
  $chipTb.FontSize = 10.5
  $chip.Child = $chipTb
  [void]$el["PluginChipsPanel"].Children.Add($chip)
}

$el["RecentTitle"].Text = Unescape-Text '\u6700\u8fd1 5 \u6b65\u8c03\u7528'
if ($hasSteps) {
  $el["RecentMeta"].Text = "Step $($usage.recent_steps[0].step_index) -> $($usage.latest_step)"
  $stepsRev = @($usage.recent_steps)
  [array]::Reverse($stepsRev)
  foreach ($st in $stepsRev) {
    $sr = New-Object System.Windows.Controls.Grid
    $sr.Margin = New-Object System.Windows.Thickness(0, 2, 0, 2)
    $sc1 = New-Object System.Windows.Controls.ColumnDefinition
    $sc1.Width = New-Object System.Windows.GridLength(64)
    $sc2 = New-Object System.Windows.Controls.ColumnDefinition
    $sc2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $sc3 = New-Object System.Windows.Controls.ColumnDefinition
    $sc3.Width = [System.Windows.GridLength]::Auto
    $sr.ColumnDefinitions.Add($sc1)
    $sr.ColumnDefinitions.Add($sc2)
    $sr.ColumnDefinitions.Add($sc3)

    $tbStep = New-Object System.Windows.Controls.TextBlock
    $tbStep.Text = "#$($st.step_index)"
    $tbStep.Foreground = $brBaseBar
    $tbStep.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
    $tbStep.FontSize = 11.5
    $tbStep.FontWeight = [System.Windows.FontWeights]::SemiBold

    $tbActive = New-Object System.Windows.Controls.TextBlock
    $tbActive.Text = (Unescape-Text '\u603b\u4e0a\u4e0b\u6587 ') + (Format-Num ([long]$st.active_tokens))
    $tbActive.Foreground = $brFgMain
    $tbActive.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
    $tbActive.FontSize = 11
    [System.Windows.Controls.Grid]::SetColumn($tbActive, 1)

    $tbDetail = New-Object System.Windows.Controls.TextBlock
    $tbDetail.Text = (Unescape-Text '\u7f13\u5b58 ') + (Format-Num ([long]$st.cache_read_tokens)) + " + " + (Unescape-Text '\u65b0\u589e ') + (Format-Num ([long]$st.input_tokens)) + " | " + (Unescape-Text '\u8f93\u51fa ') + (Format-Num ([long]$st.output_tokens))
    $tbDetail.Foreground = $brFgMuted
    $tbDetail.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
    $tbDetail.FontSize = 10.5
    [System.Windows.Controls.Grid]::SetColumn($tbDetail, 2)

    [void]$sr.Children.Add($tbStep)
    [void]$sr.Children.Add($tbActive)
    [void]$sr.Children.Add($tbDetail)
    [void]$el["RecentRowsPanel"].Children.Add($sr)
  }
} else {
  $el["RecentMeta"].Text = "--"
  $emptyTb = New-Object System.Windows.Controls.TextBlock
  $emptyTb.Text = Unescape-Text '\u65b0\u4f1a\u8bdd\u5c1a\u672a\u4ea7\u751f\u6a21\u578b\u8c03\u7528\uff08\u9884\u8ba1\u57fa\u51c6\uff09'
  $emptyTb.Foreground = $brFgMuted
  $emptyTb.FontSize = 11
  [void]$el["RecentRowsPanel"].Children.Add($emptyTb)
}

$el["TitleBar"].Add_MouseLeftButtonDown({
  $window.DragMove()
})
$el["CloseBtn"].Add_Click({
  $window.Close()
})
$window.Add_KeyDown({
  param($sender, $e)
  if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
    $window.Close()
  }
})

[void]$window.ShowDialog()
