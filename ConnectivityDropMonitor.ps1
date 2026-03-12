Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ================================================================
#  CONNECTIVITY MONITOR v4.0
#  5-Tab Dashboard | Dual-Pane | Toast Notifications | Traceroute
#  Daily Log Rotation | HTML & CSV Reporting | Baseline Learning
#  Flicker-Free Rendering | PowerShell 5.1 Compatible
# ================================================================

# -------------------------
# GLOBAL STATE
# -------------------------
$script:version       = "4.0"
$script:history       = [System.Collections.Generic.List[PSObject]]::new()
$script:drops         = [System.Collections.Generic.List[PSObject]]::new()
$script:perTarget     = @{}
$script:failCount     = 0
$script:isDown        = $false
$script:downStart     = $null
$script:sessionStart  = Get-Date
$script:totalPings    = 0
$script:totalSuccess  = 0
$script:shutdown      = $false
$script:maxHistory    = 1000
$script:lastLineCount = 0
$script:paused        = $false
$script:activeTab     = 1

$script:baselineLatency  = $null
$script:baselineSamples  = [System.Collections.Generic.List[double]]::new()
$script:baselineLocked   = $false

$script:gwHistory         = [System.Collections.Generic.List[PSObject]]::new()
$script:thresholdBreaches = [System.Collections.Generic.List[PSObject]]::new()
$script:breachActive      = $false
$script:breachStart       = $null

$script:publicIP   = "detecting..."
$script:ispName    = "detecting..."
$script:wifiSig    = $null

$script:traceroutes = [System.Collections.Generic.List[PSObject]]::new()
$script:heatmap     = @{}

$script:toastAvailable = $false
$script:lastDiagnosis  = @{ msg = "Initializing..."; color = "DarkGray" }
$script:currentDate    = (Get-Date).Date

[Console]::CursorVisible = $false

# ----------------------------------------------------------------
# WORKING DIRECTORY STRUCTURE
# ----------------------------------------------------------------
$script:workDir    = Join-Path $env:USERPROFILE "ConnectivityMonitor"
$script:logsDir    = Join-Path $script:workDir "logs"
$script:reportsDir = Join-Path $script:workDir "reports"
$script:configPath = Join-Path $script:workDir "monitor_config.json"

function EnsureDirectories {
    foreach ($d in @($script:workDir, $script:logsDir, $script:reportsDir)) {
        if (-not (Test-Path $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
}

function GetDatedLogFile($prefix) {
    $dateStr = (Get-Date).ToString("yyyy-MM-dd")
    return Join-Path $script:logsDir ("{0}_{1}.csv" -f $prefix, $dateStr)
}

function CheckDateRollover {
    $today = (Get-Date).Date
    if ($today -gt $script:currentDate) {
        $script:currentDate = $today
    }
}

# ----------------------------------------------------------------
# TOAST NOTIFICATIONS
# ----------------------------------------------------------------
function InitToast {
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
        $null = [Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom.XmlDocument,ContentType=WindowsRuntime]
        $script:toastAvailable = $true
    }
    catch {
        $script:toastAvailable = $false
    }
}

function ShowToast($title, $message) {
    if (-not $script:toastAvailable) { return }
    try {
        $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
        $safeMsg   = $message -replace "&","&amp;" -replace "<","&lt;" -replace ">","&gt;"
        $safeTitle = $title   -replace "&","&amp;" -replace "<","&lt;" -replace ">","&gt;"
        $xmlStr = "<toast><visual><binding template='ToastGeneric'><text>$safeTitle</text><text>$safeMsg</text></binding></visual></toast>"
        $xml.LoadXml($xmlStr)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("ConnectivityMonitor v4").Show($toast)
    }
    catch { }
}

# ----------------------------------------------------------------
# CONFIG FILE
# ----------------------------------------------------------------
function LoadConfig {
    if (Test-Path $script:configPath) {
        try {
            $cfg = Get-Content $script:configPath -Raw | ConvertFrom-Json
            return $cfg
        }
        catch { return $null }
    }
    return $null
}

function SaveConfig($cfg) {
    $cfg | ConvertTo-Json -Depth 4 | Set-Content $script:configPath -Encoding UTF8
}

function PromptDefault($prompt, $default) {
    $val = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($val)) { return $default }
    return $val
}

function PromptYesNo($prompt, $default) {
    $val = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($val)) { $val = $default }
    return $val -match "^[Yy]"
}

# ----------------------------------------------------------------
# ADAPTER SELECT
# ----------------------------------------------------------------
function SelectAdapter {
    $adapters = Get-NetAdapter -Physical | Where-Object { $_.Status -ne "Not Present" }
    Write-Host ""
    Write-Host "+================================================+" -ForegroundColor Cyan
    Write-Host "|    CONNECTIVITY MONITOR v4.0 -- Setup         |" -ForegroundColor Cyan
    Write-Host "+================================================+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host " Network Adapters Detected:" -ForegroundColor Yellow
    Write-Host ""
    $i = 1
    foreach ($a in $adapters) {
        $statusColor = "Red"
        if ($a.Status -eq "Up") { $statusColor = "Green" }
        $speed = "N/A"
        if ($a.LinkSpeed) { $speed = $a.LinkSpeed }
        $line = "  {0}) {1,-25} Speed: {2,-12} {3}" -f $i, $a.Name, $speed, $a.Status
        Write-Host $line -ForegroundColor $statusColor
        $i++
    }
    Write-Host ""
    $n = Read-Host " Select adapter number"
    $idx = ([int]$n) - 1
    return $adapters[$idx]
}

# ----------------------------------------------------------------
# NETWORK TESTS
# ----------------------------------------------------------------
function PingTest($target) {
    try {
        $r = Test-Connection $target -Count 1 -ErrorAction Stop | Select-Object -First 1
        return @{ ok = $true; lat = [long]$r.ResponseTime; target = $target; time = Get-Date }
    }
    catch {
        return @{ ok = $false; lat = $null; target = $target; time = Get-Date }
    }
}

function DnsTest($hostname) {
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        [System.Net.Dns]::GetHostAddresses($hostname) | Out-Null
        $sw.Stop()
        return @{ ok = $true; ms = $sw.ElapsedMilliseconds }
    }
    catch {
        return @{ ok = $false; ms = $null }
    }
}

function GetGateway($alias) {
    try {
        $c = Get-NetIPConfiguration -InterfaceAlias $alias -ErrorAction SilentlyContinue 2>$null
        if ($null -eq $c) { return "N/A" }
        if ($c.IPv4DefaultGateway) { return $c.IPv4DefaultGateway.NextHop }
        return "None"
    }
    catch { return "N/A" }
}

function GetLocalIP($alias) {
    try {
        $ip = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Select-Object -First 1
        if ($ip) { return $ip.IPAddress }
        return "N/A"
    }
    catch { return "N/A" }
}

function DetectPublicIP {
    try {
        $resp = Invoke-RestMethod -Uri "http://ip-api.com/json" -TimeoutSec 5 -ErrorAction Stop
        $script:publicIP = $resp.query
        $script:ispName  = $resp.isp
    }
    catch {
        $script:publicIP = "N/A"
        $script:ispName  = "N/A"
    }
}

function GetWifiSignal {
    try {
        $out = netsh wlan show interfaces 2>$null
        $sigLine = $out | Select-String "Signal" | Select-Object -First 1
        if ($sigLine) {
            $pct = ($sigLine.Line -replace "[^0-9]", "")
            if ($pct -ne "") { return [int]$pct }
        }
        return $null
    }
    catch { return $null }
}

function RunTraceroute($target) {
    try {
        $raw  = & tracert -d -w 1000 -h 20 $target 2>&1
        $hops = [System.Collections.Generic.List[PSObject]]::new()
        foreach ($line in $raw) {
            if ($line -match "^\s*(\d+)\s") {
                $hopNum = $Matches[1]
                $ip     = "timeout"
                $lat    = $null
                if ($line -match "([\d\.]{7,15})") { $ip  = $Matches[1] }
                if ($line -match "(\d+)\s*ms")     { $lat = [int]$Matches[1] }
                $hops.Add([PSCustomObject]@{ Hop = [int]$hopNum; IP = $ip; LatMs = $lat })
            }
        }
        $tr = [PSCustomObject]@{ Time = Get-Date; Target = $target; Hops = $hops }
        $script:traceroutes.Add($tr)
        while ($script:traceroutes.Count -gt 10) { $script:traceroutes.RemoveAt(0) }
    }
    catch { }
}

# ----------------------------------------------------------------
# METRICS ENGINE
# ----------------------------------------------------------------
function UpdateHistory($lat, $target) {
    $entry = [PSCustomObject]@{ Time = Get-Date; Latency = $lat; Target = $target }
    $script:history.Add($entry)
    $script:totalPings++
    if ($null -ne $lat) { $script:totalSuccess++ }
    while ($script:history.Count -gt $script:maxHistory) { $script:history.RemoveAt(0) }

    if (-not $script:perTarget.ContainsKey($target)) {
        $script:perTarget[$target] = @{
            sent = 0
            ok   = 0
            lats = [System.Collections.Generic.List[double]]::new()
        }
    }
    $script:perTarget[$target].sent++
    if ($null -ne $lat) {
        $script:perTarget[$target].ok++
        $script:perTarget[$target].lats.Add($lat)
    }

    if (-not $script:baselineLocked -and $null -ne $lat) {
        $script:baselineSamples.Add($lat)
        if ($script:baselineSamples.Count -ge 30) {
            $script:baselineLatency = [math]::Round(
                ($script:baselineSamples | Measure-Object -Average).Average, 1)
            $script:baselineLocked = $true
        }
    }

    if ($null -ne $lat) {
        $hour = (Get-Date).Hour
        if (-not $script:heatmap.ContainsKey($hour)) {
            $script:heatmap[$hour] = [System.Collections.Generic.List[double]]::new()
        }
        $script:heatmap[$hour].Add($lat)
    }
}

function UpdateGwHistory($gwLat) {
    $script:gwHistory.Add([PSCustomObject]@{ Time = Get-Date; Latency = $gwLat })
    while ($script:gwHistory.Count -gt 200) { $script:gwHistory.RemoveAt(0) }
}

function CalcLoss {
    $total = $script:history.Count
    if ($total -eq 0) { return 0 }
    $lost = @($script:history | Where-Object { $null -eq $_.Latency }).Count
    return [math]::Round(($lost / $total) * 100, 1)
}

function CalcAvg {
    $vals = @($script:history | Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency })
    if ($vals.Count -eq 0) { return 0 }
    return [math]::Round(($vals | Measure-Object -Average).Average, 1)
}

function CalcMin {
    $vals = @($script:history | Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency })
    if ($vals.Count -eq 0) { return 0 }
    return [math]::Round(($vals | Measure-Object -Minimum).Minimum, 1)
}

function CalcMax {
    $vals = @($script:history | Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency })
    if ($vals.Count -eq 0) { return 0 }
    return [math]::Round(($vals | Measure-Object -Maximum).Maximum, 1)
}

function CalcPercentile($pct) {
    $vals = @($script:history | Where-Object { $null -ne $_.Latency } |
              ForEach-Object { $_.Latency } | Sort-Object)
    if ($vals.Count -eq 0) { return 0 }
    $idx = [math]::Floor($vals.Count * $pct / 100)
    if ($idx -ge $vals.Count) { $idx = $vals.Count - 1 }
    return [math]::Round($vals[$idx], 1)
}

function CalcJitter {
    $vals = @($script:history | Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency })
    if ($vals.Count -lt 2) { return 0 }
    $diffs = @()
    for ($i = 1; $i -lt $vals.Count; $i++) {
        $diffs += [math]::Abs($vals[$i] - $vals[$i - 1])
    }
    return [math]::Round(($diffs | Measure-Object -Average).Average, 1)
}

function CalcUptime {
    $total = $script:history.Count
    if ($total -eq 0) { return 100.0 }
    $ok = @($script:history | Where-Object { $null -ne $_.Latency }).Count
    return [math]::Round(($ok / $total) * 100, 2)
}

# ----------------------------------------------------------------
# TREND DETECTION
# ----------------------------------------------------------------
function GetTrend {
    $recent = @($script:history | Select-Object -Last 30 |
                Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency })
    if ($recent.Count -lt 10) {
        return @{ arrow = "->"; label = "Collecting"; color = "DarkGray" }
    }
    $half      = [math]::Floor($recent.Count / 2)
    $first     = @($recent[0..($half - 1)])
    $second    = @($recent[$half..($recent.Count - 1)])
    $avgFirst  = ($first  | Measure-Object -Average).Average
    $avgSecond = ($second | Measure-Object -Average).Average
    $pctChange = 0
    if ($avgFirst -gt 0) { $pctChange = (($avgSecond - $avgFirst) / $avgFirst) * 100 }

    if ($pctChange -gt 20) {
        return @{ arrow = "^^"; label = "Degrading"; color = "Red" }
    }
    elseif ($pctChange -gt 8) {
        return @{ arrow = "^ "; label = "Rising"; color = "Yellow" }
    }
    elseif ($pctChange -lt -20) {
        return @{ arrow = "vv"; label = "Improving"; color = "Green" }
    }
    elseif ($pctChange -lt -8) {
        return @{ arrow = "v "; label = "Falling"; color = "Green" }
    }
    else {
        return @{ arrow = "->"; label = "Stable"; color = "Cyan" }
    }
}

# ----------------------------------------------------------------
# HEALTH SCORE
# ----------------------------------------------------------------
function GetHealthScore {
    $loss   = CalcLoss
    $avg    = CalcAvg
    $jitter = CalcJitter
    $score  = 100

    $score -= ($loss * 3)
    if ($avg -gt 100)       { $score -= 20 }
    elseif ($avg -gt 50)    { $score -= 10 }
    elseif ($avg -gt 30)    { $score -= 5  }
    if ($jitter -gt 30)     { $score -= 15 }
    elseif ($jitter -gt 15) { $score -= 8  }
    elseif ($jitter -gt 5)  { $score -= 3  }

    $score = [math]::Max(0, [math]::Min(100, [math]::Round($score)))

    $grade = "A+"
    $color = "Green"
    if ($score -lt 50)     { $grade = "F"; $color = "Red"    }
    elseif ($score -lt 60) { $grade = "D"; $color = "Red"    }
    elseif ($score -lt 70) { $grade = "C"; $color = "Yellow" }
    elseif ($score -lt 80) { $grade = "B"; $color = "Yellow" }
    elseif ($score -lt 90) { $grade = "A"; $color = "Green"  }

    return @{ score = $score; grade = $grade; color = $color }
}

# ----------------------------------------------------------------
# NETWORK WEATHER
# ----------------------------------------------------------------
function GetWeather {
    $loss   = CalcLoss
    $avg    = CalcAvg
    $jitter = CalcJitter

    if ($script:isDown -or $loss -ge 10) {
        return @{ name = "HURRICANE";     icon = "///"; color = "Red"    }
    }
    elseif ($loss -ge 3 -or $avg -gt 150) {
        return @{ name = "STORMY";        icon = "/! "; color = "Red"    }
    }
    elseif ($jitter -gt 20 -or $avg -gt 80) {
        return @{ name = "CLOUDY";        icon = "~~~"; color = "Yellow" }
    }
    elseif ($jitter -gt 8 -or $avg -gt 40) {
        return @{ name = "PARTLY CLOUDY"; icon = " ~ "; color = "Yellow" }
    }
    else {
        return @{ name = "SUNNY";         icon = " * "; color = "Green"  }
    }
}

# ----------------------------------------------------------------
# AUTO-DIAGNOSIS
# ----------------------------------------------------------------
function DiagnoseIssue($gwPing, $extPing) {
    if ($gwPing.ok -and $extPing.ok) {
        return @{ msg = "All clear"; color = "Green" }
    }
    if (-not $gwPing.ok -and -not $extPing.ok) {
        return @{ msg = "Local network down (gateway unreachable)"; color = "Red" }
    }
    if ($gwPing.ok -and -not $extPing.ok) {
        return @{ msg = "ISP/upstream issue (gateway OK, internet down)"; color = "Yellow" }
    }
    return @{ msg = "Unusual state"; color = "DarkYellow" }
}

# ----------------------------------------------------------------
# HELPERS
# ----------------------------------------------------------------
function LatencyColor($ms) {
    if ($null -eq $ms) { return "Red"    }
    if ($ms -lt 30)    { return "Green"  }
    if ($ms -lt 80)    { return "Yellow" }
    return "Red"
}

function LossColor($pct) {
    if ($pct -eq 0) { return "Green"  }
    if ($pct -lt 5) { return "Yellow" }
    return "Red"
}

function FormatDuration($ts) {
    if ($ts.TotalHours -ge 1) {
        return "{0}h {1}m {2}s" -f [math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds
    }
    if ($ts.TotalMinutes -ge 1) {
        return "{0}m {1}s" -f [math]::Floor($ts.TotalMinutes), $ts.Seconds
    }
    return "{0}s" -f $ts.Seconds
}

function PadRight($str, $width) {
    $s = [string]$str
    if ($s.Length -ge $width) { return $s.Substring(0, $width) }
    return $s + (" " * ($width - $s.Length))
}

# ----------------------------------------------------------------
# ASCII ART
# ----------------------------------------------------------------
function GetOnlineArt {
    return @(
        "   ___  _  _ _    ___ _  _ ___   ",
        "  / _ \| \| | |  |_ _| \| | __|  ",
        " | (_) | .  | |__ | || .  | _|   ",
        "  \___/|_|\_|____|___|_|\_|___|  "
    )
}

function GetOfflineArt {
    return @(
        "   ___  ___ ___ _    ___ _  _ ___   ",
        "  / _ \| __| __| |  |_ _| \| | __|  ",
        " | (_) | _|| _|| |__ | || .  | _|   ",
        "  \___/|_| |_| |____|___|_|\_|___|  "
    )
}

# ----------------------------------------------------------------
# SPARKLINE
# ----------------------------------------------------------------
function BuildSparkline($count) {
    if ($count -le 0) { $count = 80 }
    $vals = @($script:history | Select-Object -Last $count | ForEach-Object { $_.Latency })
    if ($vals.Count -eq 0) { return "" }

    $chars   = @("_", ".", "-", "~", "^")
    $numVals = @($vals | Where-Object { $null -ne $_ })
    if ($numVals.Count -eq 0) { return "X" * $vals.Count }

    $maxV = ($numVals | Measure-Object -Maximum).Maximum
    if ($maxV -eq 0) { $maxV = 1 }

    $spark = ""
    foreach ($v in $vals) {
        if ($null -eq $v) {
            $spark += "X"
        }
        else {
            $idx = [math]::Floor(($v / $maxV) * ($chars.Count - 1))
            if ($idx -ge $chars.Count) { $idx = $chars.Count - 1 }
            $spark += $chars[$idx]
        }
    }
    return $spark
}

# ----------------------------------------------------------------
# UPTIME TIMELINE BAR
# ----------------------------------------------------------------
function BuildUptimeBar($width) {
    $vals = @($script:history | Select-Object -Last $width | ForEach-Object { $_.Latency })
    if ($vals.Count -eq 0) { return "" }
    $bar = ""
    foreach ($v in $vals) {
        if ($null -eq $v)   { $bar += "X" }
        elseif ($v -gt 100) { $bar += "!" }
        elseif ($v -gt 50)  { $bar += "~" }
        else                { $bar += "-" }
    }
    return $bar
}

# ----------------------------------------------------------------
# LATENCY GRAPH
# ----------------------------------------------------------------
function BuildLatencyGraph($width, $height) {
    $vals = @($script:history | Select-Object -Last $width | ForEach-Object { $_.Latency })
    if ($vals.Count -eq 0) { return @() }

    $numericVals = @($vals | Where-Object { $null -ne $_ })
    if ($numericVals.Count -eq 0) { $maxVal = 1 }
    else {
        $maxVal = ($numericVals | Measure-Object -Maximum).Maximum
        if ($maxVal -eq 0) { $maxVal = 1 }
    }

    $lines = @()
    $lines += ("  Latency (ms) - last {0} pings  [max: {1}ms]" -f $vals.Count, [math]::Round($maxVal, 0))

    for ($row = $height; $row -ge 1; $row--) {
        $rowThreshold = ($row / $height) * $maxVal
        $line = ""
        foreach ($v in $vals) {
            if ($null -eq $v) { $line += "X" }
            elseif ($v -ge $rowThreshold) {
                if ($v -lt 10)      { $line += "." }
                elseif ($v -lt 50)  { $line += "o" }
                elseif ($v -lt 100) { $line += "O" }
                else                { $line += "@" }
            }
            else { $line += " " }
        }
        $label = "{0,6}" -f [math]::Round($rowThreshold, 0)
        $lines += ($label + " |" + $line + "|")
    }

    $lines += ("       +" + ("-" * $vals.Count) + "+")
    $lines += "       Legend: . <10ms  o <50ms  O <100ms  @ >100ms  X drop"
    return $lines
}

# ----------------------------------------------------------------
# HISTOGRAM
# ----------------------------------------------------------------
function BuildHistogram {
    $vals = @($script:history | Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency })
    if ($vals.Count -lt 5) { return @("  (need more data for histogram)") }

    $bucketNames  = @("  0-10ms ", " 10-25ms ", " 25-50ms ", " 50-100ms", "100-200ms", "  200ms+ ")
    $bucketCounts = @(0, 0, 0, 0, 0, 0)

    foreach ($v in $vals) {
        if ($v -lt 10)      { $bucketCounts[0]++ }
        elseif ($v -lt 25)  { $bucketCounts[1]++ }
        elseif ($v -lt 50)  { $bucketCounts[2]++ }
        elseif ($v -lt 100) { $bucketCounts[3]++ }
        elseif ($v -lt 200) { $bucketCounts[4]++ }
        else                { $bucketCounts[5]++ }
    }

    $maxCount = ($bucketCounts | Measure-Object -Maximum).Maximum
    if ($maxCount -eq 0) { $maxCount = 1 }
    $barMax = 20

    $lines = @()
    $lines += "  Latency Distribution:"
    for ($b = 0; $b -lt $bucketNames.Count; $b++) {
        $count  = $bucketCounts[$b]
        $barLen = [math]::Round(($count / $maxCount) * $barMax)
        $bar    = "=" * $barLen
        $pct    = [math]::Round(($count / $vals.Count) * 100, 0)
        $lines += ("  {0} |{1,-20} {2,4} ({3}%)" -f $bucketNames[$b], $bar, $count, $pct)
    }
    return $lines
}

# ----------------------------------------------------------------
# HEATMAP (TAB 5)
# ----------------------------------------------------------------
function BuildHeatmap {
    $lines = @()
    $lines += "  Time-of-Day Average Latency Heatmap (today)"
    $lines += "  Hour  | Value | Bar                    | Avg    Min    Max    Count"
    $lines += "  ------+-------+------------------------+----------------------------------"

    for ($h = 0; $h -lt 24; $h++) {
        $label = "{0:D2}:00" -f $h
        if ($script:heatmap.ContainsKey($h) -and $script:heatmap[$h].Count -gt 0) {
            $lats   = $script:heatmap[$h]
            $hAvg   = [math]::Round(($lats | Measure-Object -Average).Average, 1)
            $hMin   = [math]::Round(($lats | Measure-Object -Minimum).Minimum, 1)
            $hMax   = [math]::Round(($lats | Measure-Object -Maximum).Maximum, 1)
            $hCount = $lats.Count

            if ($hAvg -lt 10)      { $char = "." }
            elseif ($hAvg -lt 30)  { $char = "o" }
            elseif ($hAvg -lt 60)  { $char = "O" }
            elseif ($hAvg -lt 100) { $char = "@" }
            else                   { $char = "#" }

            $barW   = [math]::Min(20, [math]::Round($hAvg / 5))
            $barStr = $char * $barW

            $lines += ("  {0}  | {1,5} | {2,-24}| {3,6}ms {4,6}ms {5,6}ms {6,6}" -f
                $label, ("{0}ms" -f $hAvg), $barStr, $hAvg, $hMin, $hMax, $hCount)
        }
        else {
            $lines += ("  {0}  |     - |                        | no data" -f $label)
        }
    }
    $lines += ""
    $lines += "  Legend: . <10ms  o <30ms  O <60ms  @ <100ms  # >100ms"
    return $lines
}

# ----------------------------------------------------------------
# LOGGING (ENRICHED CSV)
# ----------------------------------------------------------------
function LogPing($pingResult, $gwResult, $dnsResult, $wifiSig, $file) {
    $latVal = ""
    if ($null -ne $pingResult.lat) { $latVal = $pingResult.lat }

    $gwLatVal = ""
    if ($null -ne $gwResult -and $gwResult.ok -and $null -ne $gwResult.lat) {
        $gwLatVal = $gwResult.lat
    }

    $dnsMs = ""
    if ($null -ne $dnsResult -and $dnsResult.ok -and $null -ne $dnsResult.ms) {
        $dnsMs = $dnsResult.ms
    }

    $wifiVal = ""
    if ($null -ne $wifiSig) { $wifiVal = $wifiSig }

    $trend  = GetTrend
    $health = GetHealthScore

    $baselineVal = ""
    if ($script:baselineLatency) { $baselineVal = $script:baselineLatency }

    $record = [PSCustomObject]@{
        Timestamp     = $pingResult.time.ToString("yyyy-MM-dd HH:mm:ss.fff")
        Target        = $pingResult.target
        Success       = $pingResult.ok
        LatencyMs     = $latVal
        GatewayMs     = $gwLatVal
        DnsMs         = $dnsMs
        WifiSignalPct = $wifiVal
        PacketLossPct = CalcLoss
        AvgLatencyMs  = CalcAvg
        JitterMs      = CalcJitter
        P95Ms         = CalcPercentile 95
        UptimePct     = CalcUptime
        Trend         = $trend.label
        HealthScore   = $health.score
        HealthGrade   = $health.grade
        BaselineMs    = $baselineVal
        PublicIP      = $script:publicIP
        ISP           = $script:ispName
    }

    $dir = Split-Path $file
    if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if (!(Test-Path $file)) {
        $record | Export-Csv $file -NoTypeInformation -Force
    }
    else {
        $record | Export-Csv $file -Append -NoTypeInformation -Force
    }
}

function LogDrop($start, $end, $target, $diagnosis, $file) {
    $dur = [math]::Round(($end - $start).TotalSeconds, 2)
    $record = [PSCustomObject]@{
        Start     = $start.ToString("yyyy-MM-dd HH:mm:ss.fff")
        End       = $end.ToString("yyyy-MM-dd HH:mm:ss.fff")
        Duration  = $dur
        Target    = $target
        Diagnosis = $diagnosis
    }

    $dir = Split-Path $file
    if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if (!(Test-Path $file)) {
        $record | Export-Csv $file -NoTypeInformation -Force
    }
    else {
        $record | Export-Csv $file -Append -NoTypeInformation -Force
    }

    $script:drops.Add($record)
}

function LogBreach($start, $end, $avgLat, $file) {
    $dur = [math]::Round(($end - $start).TotalSeconds, 2)
    $record = [PSCustomObject]@{
        Start      = $start.ToString("yyyy-MM-dd HH:mm:ss.fff")
        End        = $end.ToString("yyyy-MM-dd HH:mm:ss.fff")
        Duration   = $dur
        AvgLatency = $avgLat
    }

    $dir = Split-Path $file
    if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if (!(Test-Path $file)) {
        $record | Export-Csv $file -NoTypeInformation -Force
    }
    else {
        $record | Export-Csv $file -Append -NoTypeInformation -Force
    }

    $script:thresholdBreaches.Add($record)
}

# ================================================================
# FLICKER-FREE RENDERER
# ================================================================
function RenderFrame($frameLines, $consoleWidth) {
    [Console]::SetCursorPosition(0, 0)

    foreach ($fl in $frameLines) {
        $text  = $fl.Text
        $color = $fl.Color
        if ($text.Length -gt $consoleWidth) { $text = $text.Substring(0, $consoleWidth) }
        $padLen = $consoleWidth - $text.Length
        if ($padLen -lt 0) { $padLen = 0 }
        $padded = $text + (" " * $padLen)
        Write-Host $padded -ForegroundColor $color -NoNewline
        Write-Host ""
    }

    $currentCount = $frameLines.Count
    if ($script:lastLineCount -gt $currentCount) {
        $blank = " " * $consoleWidth
        for ($i = 0; $i -lt ($script:lastLineCount - $currentCount); $i++) {
            Write-Host $blank
        }
    }
    $script:lastLineCount = $currentCount
}

# ================================================================
# TAB BAR
# ================================================================
function BuildTabBar {
    $tabData = @(
        @{ n = 1; label = " Overview " },
        @{ n = 2; label = " Full Graph " },
        @{ n = 3; label = " Drops/Traces " },
        @{ n = 4; label = " Per-Target " },
        @{ n = 5; label = " Heatmap " }
    )
    $bar = ""
    foreach ($t in $tabData) {
        if ($t.n -eq $script:activeTab) {
            $bar += "[{0}:{1}]" -f $t.n, $t.label
        }
        else {
            $bar += " {0}:{1} " -f $t.n, $t.label
        }
    }
    return $bar
}

# ================================================================
# TAB 1 - DUAL PANE OVERVIEW
# ================================================================
function BuildTab1($adapter, $gw, $localIP, $target, $ping, $gwPing, $dnsResult, $latWarn, $enableDns, $wifiSig, $diagnosis) {
    $loss    = CalcLoss
    $avg     = CalcAvg
    $jitter  = CalcJitter
    $minLat  = CalcMin
    $maxLat  = CalcMax
    $p95     = CalcPercentile 95
    $up      = CalcUptime
    $elapsed = (Get-Date) - $script:sessionStart
    $trend   = GetTrend
    $health  = GetHealthScore
    $weather = GetWeather

    $frame = [System.Collections.Generic.List[hashtable]]::new()

    $frame.Add(@{ Text = (BuildTabBar); Color = "DarkCyan" })
    $frame.Add(@{ Text = ""; Color = "White" })

    $now = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $frame.Add(@{ Text = "+======================================================================+"; Color = "Cyan" })
    $frame.Add(@{ Text = ("|  [*] CONNECTIVITY MONITOR v4.0               {0}    |" -f $now); Color = "Cyan" })
    $frame.Add(@{ Text = "+======================================================================+"; Color = "Cyan" })

    if ($script:paused) {
        $frame.Add(@{ Text = "  *** PAUSED *** (press P to resume)"; Color = "Yellow" })
    }

    $leftLines  = [System.Collections.Generic.List[hashtable]]::new()
    $rightLines = [System.Collections.Generic.List[hashtable]]::new()

    # --- LEFT PANE ---
    if ($ping.ok) {
        $artLines = GetOnlineArt
        $artColor = "Green"
    }
    else {
        $artLines = GetOfflineArt
        $artColor = "Red"
    }
    foreach ($al in $artLines) { $leftLines.Add(@{ Text = $al; Color = $artColor }) }
    $leftLines.Add(@{ Text = ""; Color = "White" })

    $spark = BuildSparkline 60
    if ($spark.Length -gt 0) {
        $leftLines.Add(@{ Text = ("  Spark : {0}" -f $spark); Color = "DarkCyan" })
    }

    $ubar = BuildUptimeBar 60
    if ($ubar.Length -gt 0) {
        $leftLines.Add(@{ Text = ("  Time  : {0}" -f $ubar); Color = "DarkGray" })
        $leftLines.Add(@{ Text = "           - ok  ~ >50ms  ! >100ms  X drop"; Color = "DarkGray" })
    }
    $leftLines.Add(@{ Text = ""; Color = "White" })

    $leftLines.Add(@{ Text = ("  Adapter  : {0}" -f $adapter.Name); Color = "White" })
    $leftLines.Add(@{ Text = ("  Local IP : {0}" -f $localIP);     Color = "White" })
    $leftLines.Add(@{ Text = ("  Gateway  : {0}" -f $gw);          Color = "White" })
    $leftLines.Add(@{ Text = ("  Public   : {0}  ({1})" -f $script:publicIP, $script:ispName); Color = "White" })
    $leftLines.Add(@{ Text = ("  Target   : {0}" -f $target);      Color = "Yellow" })
    $leftLines.Add(@{ Text = ("  Session  : {0}" -f (FormatDuration $elapsed)); Color = "White" })

    if ($null -ne $wifiSig) {
        $wifiColor = "Green"
        if ($wifiSig -lt 40)     { $wifiColor = "Red"    }
        elseif ($wifiSig -lt 70) { $wifiColor = "Yellow" }
        $leftLines.Add(@{ Text = ("  WiFi     : {0}%" -f $wifiSig); Color = $wifiColor })
    }

    if ($script:baselineLocked) {
        $leftLines.Add(@{ Text = ("  Baseline : {0} ms (learned)" -f $script:baselineLatency); Color = "DarkCyan" })
    }
    else {
        $remaining = 30 - $script:baselineSamples.Count
        $leftLines.Add(@{ Text = ("  Baseline : learning... ({0} more)" -f $remaining); Color = "DarkGray" })
    }
    $leftLines.Add(@{ Text = ""; Color = "White" })

    $leftLines.Add(@{ Text = "  +----------------------------------+"; Color = "DarkGray" })
    if ($adapter.Status -eq "Up") { $linkStr = "[UP]  " } else { $linkStr = "[DOWN]" }
    if ($adapter.Status -ne "Up") { $inet = "DOWN" }
    elseif ($ping.ok)             { $inet = "OK"   }
    else                          { $inet = "FAIL" }

    $gwStr = ""
    if ($null -ne $gwPing) {
        if ($gwPing.ok) { $gwStr = "  GW:{0}ms" -f $gwPing.lat }
        else            { $gwStr = "  GW:FAIL" }
    }
    $dnsStr = ""
    if ($enableDns) {
        if ($dnsResult.ok) { $dnsStr = "  DNS:{0}ms" -f $dnsResult.ms }
        else               { $dnsStr = "  DNS:FAIL" }
    }
    $statusLine  = "  | Link:{0}  Net:{1}{2}{3}" -f $linkStr, $inet, $gwStr, $dnsStr
    $statusColor = "Green"
    if ($adapter.Status -ne "Up" -or -not $ping.ok) { $statusColor = "Red" }
    $leftLines.Add(@{ Text = (PadRight $statusLine 38); Color = $statusColor })

    if ($null -ne $ping.lat) {
        $latStr = "{0} ms" -f $ping.lat
        if ($ping.lat -ge $latWarn) { $latStr += " !! HIGH" }
    }
    else { $latStr = "--" }
    $latLine = "  | Latency : {0}" -f $latStr
    $leftLines.Add(@{ Text = (PadRight $latLine 38); Color = (LatencyColor $ping.lat) })
    $leftLines.Add(@{ Text = "  +----------------------------------+"; Color = "DarkGray" })
    $leftLines.Add(@{ Text = ""; Color = "White" })

    $leftLines.Add(@{ Text = ("  Weather  : {0} {1}" -f $weather.icon, $weather.name); Color = $weather.color })
    $leftLines.Add(@{ Text = ("  Health   : {0}/100  Grade:{1}  {2} {3}" -f $health.score, $health.grade, $trend.arrow, $trend.label); Color = $health.color })

    if ($null -ne $diagnosis) {
        $leftLines.Add(@{ Text = ("  Diagnose : {0}" -f $diagnosis.msg); Color = $diagnosis.color })
    }
    $leftLines.Add(@{ Text = ""; Color = "White" })

    $leftLines.Add(@{ Text = "  +---- Statistics ----------------+"; Color = "DarkGray" })
    $leftLines.Add(@{ Text = ("  | Loss   : {0,5}%   Uptime: {1,6}% |" -f $loss, $up); Color = (LossColor $loss) })
    $leftLines.Add(@{ Text = ("  | Avg    : {0,5}ms  P95   : {1,6}ms |" -f $avg, $p95); Color = "White" })
    $leftLines.Add(@{ Text = ("  | Min    : {0,5}ms  Max   : {1,6}ms |" -f $minLat, $maxLat); Color = "White" })
    $leftLines.Add(@{ Text = ("  | Jitter : {0,5}ms  Pings : {1,6}   |" -f $jitter, $script:totalPings); Color = "White" })
    $leftLines.Add(@{ Text = "  +----------------------------------+"; Color = "DarkGray" })

    # --- RIGHT PANE ---
    $compactGraph = BuildLatencyGraph 28 6
    foreach ($gl in $compactGraph) {
        $gc = "DarkGray"
        if ($gl.Contains("X"))      { $gc = "Yellow"     }
        elseif ($gl.Contains("@"))  { $gc = "Red"        }
        elseif ($gl.Contains("O"))  { $gc = "DarkYellow" }
        elseif ($gl.Contains("o"))  { $gc = "Cyan"       }
        elseif ($gl.Contains("."))  { $gc = "Green"      }
        $rightLines.Add(@{ Text = $gl; Color = $gc })
    }
    $rightLines.Add(@{ Text = ""; Color = "White" })

    $histLines = BuildHistogram
    foreach ($hl in $histLines) { $rightLines.Add(@{ Text = $hl; Color = "DarkCyan" }) }
    $rightLines.Add(@{ Text = ""; Color = "White" })

    $rightLines.Add(@{ Text = "  Recent Drops:"; Color = "Yellow" })
    if ($script:drops.Count -eq 0) {
        $rightLines.Add(@{ Text = "    (none)"; Color = "DarkGray" })
    }
    else {
        $rightLines.Add(@{ Text = ("    {0,-18} {1,-8} {2}" -f "Time", "Dur(s)", "Diagnosis"); Color = "DarkYellow" })
        foreach ($d in ($script:drops | Select-Object -Last 8)) {
            $dv = [double]$d.Duration
            $dc = "White"
            if ($dv -ge 30)     { $dc = "Red"    }
            elseif ($dv -ge 10) { $dc = "Yellow" }
            $timeShort = $d.Start.Substring(11, 8)
            $rightLines.Add(@{ Text = ("    {0,-18} {1,-8} {2}" -f $timeShort, ("{0}s" -f $d.Duration), $d.Diagnosis); Color = $dc })
        }
    }
    $rightLines.Add(@{ Text = ""; Color = "White" })

    $rightLines.Add(@{ Text = "  Per-Target:"; Color = "Magenta" })
    foreach ($t in $script:perTarget.Keys) {
        $info  = $script:perTarget[$t]
        $tLoss = 0
        if ($info.sent -gt 0) { $tLoss = [math]::Round((1 - $info.ok / $info.sent) * 100, 1) }
        $tAvg = 0
        if ($info.lats.Count -gt 0) {
            $tAvg = [math]::Round(($info.lats | Measure-Object -Average).Average, 1)
        }
        $tc = "White"
        if ($tLoss -gt 0) { $tc = "Yellow" }
        if ($tLoss -ge 5) { $tc = "Red"    }
        $rightLines.Add(@{ Text = ("    {0,-16} L:{1,4}%  A:{2,5}ms" -f $t, $tLoss, $tAvg); Color = $tc })
    }

    # Merge panes
    $leftW   = 52
    $sep     = " | "
    $maxRows = [math]::Max($leftLines.Count, $rightLines.Count)

    for ($r = 0; $r -lt $maxRows; $r++) {
        if ($r -lt $leftLines.Count) {
            $lText  = $leftLines[$r].Text
            $lColor = $leftLines[$r].Color
        }
        else {
            $lText  = ""
            $lColor = "White"
        }
        if ($r -lt $rightLines.Count) { $rText = $rightLines[$r].Text }
        else                          { $rText = "" }

        $combined = (PadRight $lText $leftW) + $sep + $rText
        $frame.Add(@{ Text = $combined; Color = $lColor })
    }

    $frame.Add(@{ Text = ""; Color = "White" })
    $frame.Add(@{ Text = "  [1-5] Tabs  [P] Pause  [R] Reset  [E] Export HTML  [Q] Quit"; Color = "DarkGray" })

    return $frame
}

# ================================================================
# TAB 2 - FULL GRAPH
# ================================================================
function BuildTab2 {
    $frame = [System.Collections.Generic.List[hashtable]]::new()

    $frame.Add(@{ Text = (BuildTabBar); Color = "DarkCyan" })
    $frame.Add(@{ Text = ""; Color = "White" })
    $frame.Add(@{ Text = "  Full Latency Graph"; Color = "Cyan" })
    $frame.Add(@{ Text = ""; Color = "White" })

    $graphLines = BuildLatencyGraph 100 12
    foreach ($gl in $graphLines) {
        $gc = "DarkGray"
        if ($gl.Contains("X"))     { $gc = "Yellow"     }
        elseif ($gl.Contains("@")) { $gc = "Red"        }
        elseif ($gl.Contains("O")) { $gc = "DarkYellow" }
        elseif ($gl.Contains("o")) { $gc = "Cyan"       }
        elseif ($gl.Contains(".")) { $gc = "Green"      }
        $frame.Add(@{ Text = $gl; Color = $gc })
    }

    $frame.Add(@{ Text = ""; Color = "White" })
    $ubar = BuildUptimeBar 100
    if ($ubar.Length -gt 0) {
        $frame.Add(@{ Text = ("  Uptime: {0}" -f $ubar); Color = "DarkGray" })
        $frame.Add(@{ Text = "          - ok  ~ >50ms  ! >100ms  X drop"; Color = "DarkGray" })
    }

    $frame.Add(@{ Text = ""; Color = "White" })
    $histLines = BuildHistogram
    foreach ($hl in $histLines) { $frame.Add(@{ Text = $hl; Color = "DarkCyan" }) }

    $frame.Add(@{ Text = ""; Color = "White" })
    $frame.Add(@{ Text = "  [1-5] Tabs  [P] Pause  [R] Reset  [E] Export HTML  [Q] Quit"; Color = "DarkGray" })

    return $frame
}

# ================================================================
# TAB 3 - DROPS & TRACEROUTES
# ================================================================
function BuildTab3 {
    $frame = [System.Collections.Generic.List[hashtable]]::new()

    $frame.Add(@{ Text = (BuildTabBar); Color = "DarkCyan" })
    $frame.Add(@{ Text = ""; Color = "White" })
    $frame.Add(@{ Text = "  Drop History (last 20)"; Color = "Cyan" })
    $frame.Add(@{ Text = ""; Color = "White" })

    if ($script:drops.Count -eq 0) {
        $frame.Add(@{ Text = "  (no drops recorded)"; Color = "DarkGray" })
    }
    else {
        $frame.Add(@{ Text = ("  {0,-23} {1,-23} {2,-8} {3,-16} {4}" -f "Start", "End", "Dur(s)", "Target", "Diagnosis"); Color = "DarkYellow" })
        $frame.Add(@{ Text = ("  {0}" -f ("-" * 90)); Color = "DarkGray" })
        foreach ($d in ($script:drops | Select-Object -Last 20)) {
            $dv = [double]$d.Duration
            $dc = "White"
            if ($dv -ge 30)     { $dc = "Red"    }
            elseif ($dv -ge 10) { $dc = "Yellow" }
            $frame.Add(@{ Text = ("  {0,-23} {1,-23} {2,-8} {3,-16} {4}" -f $d.Start, $d.End, ("{0}s" -f $d.Duration), $d.Target, $d.Diagnosis); Color = $dc })
        }
    }

    $frame.Add(@{ Text = ""; Color = "White" })
    $frame.Add(@{ Text = "  High Latency Breaches:"; Color = "DarkYellow" })
    if ($script:thresholdBreaches.Count -eq 0) {
        $frame.Add(@{ Text = "  (none)"; Color = "DarkGray" })
    }
    else {
        $frame.Add(@{ Text = ("  {0,-23} {1,-23} {2,-8} {3}" -f "Start", "End", "Dur(s)", "Avg Lat"); Color = "DarkYellow" })
        foreach ($b in ($script:thresholdBreaches | Select-Object -Last 10)) {
            $frame.Add(@{ Text = ("  {0,-23} {1,-23} {2,-8} {3}ms" -f $b.Start, $b.End, ("{0}s" -f $b.Duration), $b.AvgLatency); Color = "Yellow" })
        }
    }

    $frame.Add(@{ Text = ""; Color = "White" })
    $frame.Add(@{ Text = "  Recent Traceroutes (last 3):"; Color = "Cyan" })

    $lastTraces = @($script:traceroutes | Select-Object -Last 3)
    if ($lastTraces.Count -eq 0) {
        $frame.Add(@{ Text = "  (traceroute runs automatically on outage)"; Color = "DarkGray" })
    }
    else {
        foreach ($tr in $lastTraces) {
            $frame.Add(@{ Text = ("  -- Traceroute at {0} to {1} --" -f $tr.Time.ToString("HH:mm:ss"), $tr.Target); Color = "Cyan" })
            $frame.Add(@{ Text = ("    {0,-5} {1,-18} {2}" -f "Hop", "IP", "Latency"); Color = "DarkYellow" })
            foreach ($hop in $tr.Hops) {
                $hopLat = "--"
                if ($null -ne $hop.LatMs) { $hopLat = "{0}ms" -f $hop.LatMs }
                $frame.Add(@{ Text = ("    {0,-5} {1,-18} {2}" -f $hop.Hop, $hop.IP, $hopLat); Color = "White" })
            }
            $frame.Add(@{ Text = ""; Color = "White" })
        }
    }

    $frame.Add(@{ Text = ""; Color = "White" })
    $frame.Add(@{ Text = "  [1-5] Tabs  [P] Pause  [R] Reset  [E] Export HTML  [Q] Quit"; Color = "DarkGray" })

    return $frame
}

# ================================================================
# TAB 4 - PER-TARGET DETAIL
# ================================================================
function BuildTab4 {
    $frame = [System.Collections.Generic.List[hashtable]]::new()

    $frame.Add(@{ Text = (BuildTabBar); Color = "DarkCyan" })
    $frame.Add(@{ Text = ""; Color = "White" })
    $frame.Add(@{ Text = "  Per-Target Statistics"; Color = "Cyan" })
    $frame.Add(@{ Text = ""; Color = "White" })

    $frame.Add(@{ Text = ("  {0,-18} {1,6} {2,6} {3,7} {4,8} {5,8} {6,8} {7,8}" -f "Target", "Sent", "OK", "Loss%", "Avg(ms)", "Min(ms)", "Max(ms)", "P95(ms)"); Color = "DarkYellow" })
    $frame.Add(@{ Text = ("  {0}" -f ("-" * 80)); Color = "DarkGray" })

    foreach ($t in $script:perTarget.Keys) {
        $info  = $script:perTarget[$t]
        $tLoss = 0
        if ($info.sent -gt 0) { $tLoss = [math]::Round((1 - $info.ok / $info.sent) * 100, 1) }

        $tAvg = 0; $tMin = 0; $tMax = 0; $tP95 = 0
        if ($info.lats.Count -gt 0) {
            $sorted = @($info.lats | Sort-Object)
            $tAvg   = [math]::Round(($sorted | Measure-Object -Average).Average, 1)
            $tMin   = [math]::Round(($sorted | Measure-Object -Minimum).Minimum, 1)
            $tMax   = [math]::Round(($sorted | Measure-Object -Maximum).Maximum, 1)
            $p95idx = [math]::Min([math]::Floor($sorted.Count * 0.95), $sorted.Count - 1)
            $tP95   = [math]::Round($sorted[$p95idx], 1)
        }

        $tc = "White"
        if ($tLoss -gt 0) { $tc = "Yellow" }
        if ($tLoss -ge 5) { $tc = "Red"    }
        $frame.Add(@{ Text = ("  {0,-18} {1,6} {2,6} {3,7} {4,8} {5,8} {6,8} {7,8}" -f $t, $info.sent, $info.ok, ("{0}%" -f $tLoss), ("{0}ms" -f $tAvg), ("{0}ms" -f $tMin), ("{0}ms" -f $tMax), ("{0}ms" -f $tP95)); Color = $tc })
    }

    $frame.Add(@{ Text = ""; Color = "White" })
    $frame.Add(@{ Text = "  Gateway Latency History:"; Color = "Cyan" })
    $gwVals = @($script:gwHistory | Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency })
    if ($gwVals.Count -gt 0) {
        $gwAvg = [math]::Round(($gwVals | Measure-Object -Average).Average, 1)
        $gwMin = [math]::Round(($gwVals | Measure-Object -Minimum).Minimum, 1)
        $gwMax = [math]::Round(($gwVals | Measure-Object -Maximum).Maximum, 1)
        $frame.Add(@{ Text = ("    Samples: {0}  Avg: {1}ms  Min: {2}ms  Max: {3}ms" -f $gwVals.Count, $gwAvg, $gwMin, $gwMax); Color = "White" })
    }
    else {
        $frame.Add(@{ Text = "    (no gateway data)"; Color = "DarkGray" })
    }

    $frame.Add(@{ Text = ""; Color = "White" })
    $frame.Add(@{ Text = "  [1-5] Tabs  [P] Pause  [R] Reset  [E] Export HTML  [Q] Quit"; Color = "DarkGray" })

    return $frame
}

# ================================================================
# TAB 5 - HEATMAP
# ================================================================
function BuildTab5 {
    $frame = [System.Collections.Generic.List[hashtable]]::new()

    $frame.Add(@{ Text = (BuildTabBar); Color = "DarkCyan" })
    $frame.Add(@{ Text = ""; Color = "White" })

    $hmLines = BuildHeatmap
    foreach ($hl in $hmLines) {
        $hc = "White"
        if ($hl.Contains("#"))     { $hc = "Red"        }
        elseif ($hl.Contains("@")) { $hc = "DarkYellow" }
        elseif ($hl.Contains("O")) { $hc = "Yellow"     }
        elseif ($hl.Contains("o")) { $hc = "Cyan"       }
        elseif ($hl.Contains(".")) { $hc = "Green"      }
        elseif ($hl.Contains("-")) { $hc = "DarkGray"   }
        else                       { $hc = "DarkCyan"   }
        $frame.Add(@{ Text = $hl; Color = $hc })
    }

    $frame.Add(@{ Text = ""; Color = "White" })
    $frame.Add(@{ Text = "  [1-5] Tabs  [P] Pause  [R] Reset  [E] Export HTML  [Q] Quit"; Color = "DarkGray" })

    return $frame
}

# ================================================================
# HTML REPORT GENERATOR
# ================================================================
function GenerateHtmlReport($reportFile) {
    $elapsed = (Get-Date) - $script:sessionStart
    $loss    = CalcLoss
    $avg     = CalcAvg
    $minLat  = CalcMin
    $maxLat  = CalcMax
    $p95     = CalcPercentile 95
    $p99     = CalcPercentile 99
    $jitter  = CalcJitter
    $up      = CalcUptime
    $health  = GetHealthScore

    $chartLabels = [System.Collections.Generic.List[string]]::new()
    $chartData   = [System.Collections.Generic.List[string]]::new()
    $chartGw     = [System.Collections.Generic.List[string]]::new()

    foreach ($h in $script:history) {
        $chartLabels.Add('"' + $h.Time.ToString("HH:mm:ss") + '"')
        if ($null -ne $h.Latency) { $chartData.Add($h.Latency.ToString()) }
        else                       { $chartData.Add("null") }
    }
    foreach ($g in $script:gwHistory) {
        if ($null -ne $g.Latency) { $chartGw.Add($g.Latency.ToString()) }
        else                       { $chartGw.Add("null") }
    }
    while ($chartGw.Count -lt $chartData.Count) { $chartGw.Insert(0, "null") }

    $labelsJs = $chartLabels -join ","
    $dataJs   = $chartData   -join ","
    $gwJs     = $chartGw     -join ","

    $histData = @(0, 0, 0, 0, 0, 0)
    $vals = @($script:history | Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency })
    foreach ($v in $vals) {
        if ($v -lt 10)      { $histData[0]++ }
        elseif ($v -lt 25)  { $histData[1]++ }
        elseif ($v -lt 50)  { $histData[2]++ }
        elseif ($v -lt 100) { $histData[3]++ }
        elseif ($v -lt 200) { $histData[4]++ }
        else                { $histData[5]++ }
    }
    $histJs = $histData -join ","

    $heatLabels = [System.Collections.Generic.List[string]]::new()
    $heatData   = [System.Collections.Generic.List[string]]::new()
    for ($h = 0; $h -lt 24; $h++) {
        $heatLabels.Add('"' + ("{0:D2}:00" -f $h) + '"')
        if ($script:heatmap.ContainsKey($h) -and $script:heatmap[$h].Count -gt 0) {
            $hAvg = [math]::Round(($script:heatmap[$h] | Measure-Object -Average).Average, 1)
            $heatData.Add($hAvg.ToString())
        }
        else { $heatData.Add("null") }
    }
    $heatLabelsJs = $heatLabels -join ","
    $heatDataJs   = $heatData   -join ","

    $targetRows = ""
    foreach ($t in $script:perTarget.Keys) {
        $info  = $script:perTarget[$t]
        $tLoss = 0
        if ($info.sent -gt 0) { $tLoss = [math]::Round((1 - $info.ok / $info.sent) * 100, 1) }
        $tAvg = 0; $tMin = 0; $tMax = 0; $tP95r = 0
        if ($info.lats.Count -gt 0) {
            $sorted = @($info.lats | Sort-Object)
            $tAvg   = [math]::Round(($sorted | Measure-Object -Average).Average, 1)
            $tMin   = [math]::Round(($sorted | Measure-Object -Minimum).Minimum, 1)
            $tMax   = [math]::Round(($sorted | Measure-Object -Maximum).Maximum, 1)
            $p95idx = [math]::Min([math]::Floor($sorted.Count * 0.95), $sorted.Count - 1)
            $tP95r  = [math]::Round($sorted[$p95idx], 1)
        }
        $rowClass = ""
        if ($tLoss -ge 5)     { $rowClass = ' class="bad"'  }
        elseif ($tLoss -gt 0) { $rowClass = ' class="warn"' }
        $targetRows += "<tr$rowClass><td>$t</td><td>$($info.sent)</td><td>$($info.ok)</td><td>${tLoss}%</td><td>${tAvg}ms</td><td>${tMin}ms</td><td>${tMax}ms</td><td>${tP95r}ms</td></tr>`n"
    }

    $dropRows = ""
    foreach ($d in $script:drops) {
        $rowClass = ""
        $dv = [double]$d.Duration
        if ($dv -ge 30)     { $rowClass = ' class="bad"'  }
        elseif ($dv -ge 10) { $rowClass = ' class="warn"' }
        $dropRows += "<tr$rowClass><td>$($d.Start)</td><td>$($d.End)</td><td>$($d.Duration)s</td><td>$($d.Target)</td><td>$($d.Diagnosis)</td></tr>`n"
    }

    $breachRows = ""
    foreach ($b in $script:thresholdBreaches) {
        $breachRows += "<tr><td>$($b.Start)</td><td>$($b.End)</td><td>$($b.Duration)s</td><td>$($b.AvgLatency)ms</td></tr>`n"
    }

    $traceSection = ""
    foreach ($tr in $script:traceroutes) {
        $traceSection += "<h3 style='color:#38bdf8;margin:12px 0 8px'>Traceroute at {0} to {1}</h3>`n" -f $tr.Time.ToString("HH:mm:ss"), $tr.Target
        $traceSection += "<table><thead><tr><th>Hop</th><th>IP</th><th>Latency</th></tr></thead><tbody>`n"
        foreach ($hop in $tr.Hops) {
            $hopLat = "--"
            if ($null -ne $hop.LatMs) { $hopLat = "{0}ms" -f $hop.LatMs }
            $traceSection += "<tr><td>$($hop.Hop)</td><td>$($hop.IP)</td><td>$hopLat</td></tr>`n"
        }
        $traceSection += "</tbody></table>`n"
    }

    $totalDowntime = 0
    $longestDrop   = 0
    if ($script:drops.Count -gt 0) {
        $totalDowntime = [math]::Round(($script:drops | ForEach-Object { [double]$_.Duration } | Measure-Object -Sum).Sum, 2)
        $longestDrop   = [math]::Round(($script:drops | ForEach-Object { [double]$_.Duration } | Measure-Object -Maximum).Maximum, 2)
    }

    $healthCssColor = "#22c55e"
    if ($health.score -lt 60)     { $healthCssColor = "#ef4444" }
    elseif ($health.score -lt 80) { $healthCssColor = "#f59e0b" }

    $uptimeCssColor = "#22c55e"
    if ($up -lt 95)     { $uptimeCssColor = "#ef4444" }
    elseif ($up -lt 99) { $uptimeCssColor = "#f59e0b" }

    $avgCssColor = "#22c55e"
    if ($avg -gt 80)     { $avgCssColor = "#ef4444" }
    elseif ($avg -gt 30) { $avgCssColor = "#f59e0b" }

    $lossCssColor = "#22c55e"
    if ($loss -gt 5)     { $lossCssColor = "#ef4444" }
    elseif ($loss -gt 0) { $lossCssColor = "#f59e0b" }

    $jitterCssColor = "#22c55e"
    if ($jitter -gt 15)    { $jitterCssColor = "#ef4444" }
    elseif ($jitter -gt 5) { $jitterCssColor = "#f59e0b" }

    $dropsCssColor = "#22c55e"
    if ($script:drops.Count -gt 0) { $dropsCssColor = "#ef4444" }

    $baselineStr = "N/A"
    if ($script:baselineLatency) { $baselineStr = "$($script:baselineLatency)ms" }

    $dropsTableHtml = ""
    if ($script:drops.Count -eq 0) {
        $dropsTableHtml = '<p class="empty">No connection drops recorded during this session.</p>'
    }
    else {
        $dropsTableHtml = "<table><thead><tr><th>Start</th><th>End</th><th>Duration</th><th>Target</th><th>Diagnosis</th></tr></thead><tbody>$dropRows</tbody></table>"
    }

    $breachTableHtml = ""
    if ($script:thresholdBreaches.Count -eq 0) {
        $breachTableHtml = '<p class="empty">No high latency events recorded during this session.</p>'
    }
    else {
        $breachTableHtml = "<table><thead><tr><th>Start</th><th>End</th><th>Duration</th><th>Avg Latency</th></tr></thead><tbody>$breachRows</tbody></table>"
    }

    $traceSectionHtml = ""
    if ($script:traceroutes.Count -eq 0) {
        $traceSectionHtml = '<p class="empty">No traceroutes captured (runs automatically on outage).</p>'
    }
    else {
        $traceSectionHtml = $traceSection
    }

    $sessionStartStr  = $script:sessionStart.ToString("yyyy-MM-dd HH:mm:ss")
    $durationStr      = FormatDuration $elapsed
    $generatedDateStr = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $reportTitleDate  = Get-Date -Format "yyyy-MM-dd HH:mm"

    $htmlParts = [System.Collections.Generic.List[string]]::new()
    $htmlParts.Add('<!DOCTYPE html><html lang="en"><head>')
    $htmlParts.Add('<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">')
    $htmlParts.Add("<title>Network Report - $reportTitleDate</title>")
    $htmlParts.Add('<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>')
    $htmlParts.Add('<style>:root{--bg:#0f172a;--card:#1e293b;--border:#334155;--text:#e2e8f0;--muted:#94a3b8;--accent:#38bdf8;--green:#22c55e;--yellow:#f59e0b;--red:#ef4444}')
    $htmlParts.Add('*{margin:0;padding:0;box-sizing:border-box}body{font-family:"Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--text);line-height:1.6;padding:20px}.container{max-width:1400px;margin:0 auto}')
    $htmlParts.Add('.header{text-align:center;padding:40px 20px;background:linear-gradient(135deg,#1e293b 0%,#0f172a 100%);border:1px solid var(--border);border-radius:16px;margin-bottom:24px}')
    $htmlParts.Add('.header h1{font-size:2rem;font-weight:700;background:linear-gradient(90deg,#38bdf8,#818cf8);-webkit-background-clip:text;-webkit-text-fill-color:transparent;margin-bottom:8px}')
    $htmlParts.Add('.header .subtitle{color:var(--muted);font-size:0.95rem}.header .session-info{display:flex;justify-content:center;gap:32px;margin-top:16px;flex-wrap:wrap}.header .session-info span{color:var(--muted);font-size:0.85rem}.header .session-info strong{color:var(--text)}')
    $htmlParts.Add('.score-row{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:16px;margin-bottom:24px}.score-card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:20px;text-align:center}')
    $htmlParts.Add('.score-card .label{font-size:0.8rem;text-transform:uppercase;letter-spacing:1px;color:var(--muted);margin-bottom:8px}.score-card .value{font-size:2rem;font-weight:700}.score-card .sub{font-size:0.8rem;color:var(--muted);margin-top:4px}')
    $htmlParts.Add('.chart-card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:24px;margin-bottom:24px}.chart-card h2{font-size:1.1rem;font-weight:600;margin-bottom:16px;color:var(--accent)}')
    $htmlParts.Add('.chart-row{display:grid;grid-template-columns:2fr 1fr;gap:24px;margin-bottom:24px}@media(max-width:900px){.chart-row{grid-template-columns:1fr}}')
    $htmlParts.Add('.table-card{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:24px;margin-bottom:24px;overflow-x:auto}.table-card h2{font-size:1.1rem;font-weight:600;margin-bottom:16px;color:var(--accent)}')
    $htmlParts.Add('table{width:100%;border-collapse:collapse;font-size:0.9rem}th{text-align:left;padding:10px 12px;border-bottom:2px solid var(--border);color:var(--muted);font-weight:600;text-transform:uppercase;font-size:0.75rem;letter-spacing:0.5px}')
    $htmlParts.Add('td{padding:10px 12px;border-bottom:1px solid var(--border)}tr:hover{background:rgba(56,189,248,0.05)}tr.bad{background:rgba(239,68,68,0.1)}tr.warn{background:rgba(245,158,11,0.1)}.empty{color:var(--muted);font-style:italic;padding:20px;text-align:center}')
    $htmlParts.Add('.stats-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px}.stat-item{background:rgba(15,23,42,0.5);padding:14px;border-radius:8px;border:1px solid var(--border)}.stat-item .stat-label{font-size:0.75rem;text-transform:uppercase;color:var(--muted);letter-spacing:0.5px}.stat-item .stat-value{font-size:1.3rem;font-weight:700;margin-top:4px}')
    $htmlParts.Add('.footer{text-align:center;padding:24px;color:var(--muted);font-size:0.8rem}</style></head><body><div class="container">')
    $htmlParts.Add('<div class="header"><h1>Network Connectivity Report</h1><p class="subtitle">Generated by Connectivity Monitor v4.0</p>')
    $htmlParts.Add('<div class="session-info">')
    $htmlParts.Add("<span>Started: <strong>$sessionStartStr</strong></span>")
    $htmlParts.Add("<span>Duration: <strong>$durationStr</strong></span>")
    $htmlParts.Add("<span>ISP: <strong>$($script:ispName)</strong></span>")
    $htmlParts.Add("<span>Public IP: <strong>$($script:publicIP)</strong></span>")
    $htmlParts.Add('</div></div>')
    $htmlParts.Add('<div class="score-row">')
    $htmlParts.Add("<div class='score-card'><div class='label'>Health Score</div><div class='value' style='color:$healthCssColor'>$($health.score)/100</div><div class='sub'>Grade: $($health.grade)</div></div>")
    $htmlParts.Add("<div class='score-card'><div class='label'>Uptime</div><div class='value' style='color:$uptimeCssColor'>${up}%</div><div class='sub'>$($script:totalSuccess) / $($script:totalPings) pings</div></div>")
    $htmlParts.Add("<div class='score-card'><div class='label'>Avg Latency</div><div class='value' style='color:$avgCssColor'>${avg}ms</div><div class='sub'>Baseline: $baselineStr</div></div>")
    $htmlParts.Add("<div class='score-card'><div class='label'>Packet Loss</div><div class='value' style='color:$lossCssColor'>${loss}%</div><div class='sub'>$($script:totalPings - $script:totalSuccess) lost</div></div>")
    $htmlParts.Add("<div class='score-card'><div class='label'>Jitter</div><div class='value' style='color:$jitterCssColor'>${jitter}ms</div><div class='sub'>Avg variation</div></div>")
    $htmlParts.Add("<div class='score-card'><div class='label'>Outages</div><div class='value' style='color:$dropsCssColor'>$($script:drops.Count)</div><div class='sub'>Total: ${totalDowntime}s down</div></div>")
    $htmlParts.Add('</div>')
    $htmlParts.Add('<div class="chart-card"><h2>Detailed Statistics</h2><div class="stats-grid">')
    $htmlParts.Add("<div class='stat-item'><div class='stat-label'>Min Latency</div><div class='stat-value' style='color:var(--green)'>${minLat}ms</div></div>")
    $htmlParts.Add("<div class='stat-item'><div class='stat-label'>Max Latency</div><div class='stat-value' style='color:var(--red)'>${maxLat}ms</div></div>")
    $htmlParts.Add("<div class='stat-item'><div class='stat-label'>P95 Latency</div><div class='stat-value' style='color:var(--yellow)'>${p95}ms</div></div>")
    $htmlParts.Add("<div class='stat-item'><div class='stat-label'>P99 Latency</div><div class='stat-value' style='color:var(--yellow)'>${p99}ms</div></div>")
    $htmlParts.Add("<div class='stat-item'><div class='stat-label'>Longest Drop</div><div class='stat-value' style='color:var(--red)'>${longestDrop}s</div></div>")
    $htmlParts.Add("<div class='stat-item'><div class='stat-label'>Total Pings</div><div class='stat-value'>$($script:totalPings)</div></div>")
    $htmlParts.Add('</div></div>')
    $htmlParts.Add('<div class="chart-row"><div class="chart-card"><h2>Latency Over Time</h2><canvas id="latencyChart" height="100"></canvas></div>')
    $htmlParts.Add('<div class="chart-card"><h2>Latency Distribution</h2><canvas id="histChart" height="100"></canvas></div></div>')
    $htmlParts.Add('<div class="chart-card"><h2>Time-of-Day Latency Heatmap</h2><canvas id="heatChart" height="60"></canvas></div>')
    $htmlParts.Add('<div class="table-card"><h2>Per-Target Breakdown</h2><table><thead><tr><th>Target</th><th>Sent</th><th>OK</th><th>Loss</th><th>Avg</th><th>Min</th><th>Max</th><th>P95</th></tr></thead>')
    $htmlParts.Add("<tbody>$targetRows</tbody></table></div>")
    $htmlParts.Add("<div class='table-card'><h2>Connection Drops</h2>$dropsTableHtml</div>")
    $htmlParts.Add("<div class='table-card'><h2>High Latency Events</h2>$breachTableHtml</div>")
    $htmlParts.Add("<div class='table-card'><h2>Traceroutes</h2>$traceSectionHtml</div>")
    $htmlParts.Add("<div class='footer'>Report generated on $generatedDateStr | Connectivity Monitor v4.0</div>")
    $htmlParts.Add('</div><script>')
    $htmlParts.Add("const cDef={plugins:{legend:{labels:{color:'#94a3b8'}}},scales:{x:{ticks:{color:'#64748b',maxTicksLimit:20,maxRotation:45},grid:{color:'rgba(51,65,85,0.5)'}},y:{beginAtZero:true,ticks:{color:'#64748b'},grid:{color:'rgba(51,65,85,0.5)'}}}};")
    $htmlParts.Add("new Chart(document.getElementById('latencyChart'),{type:'line',data:{labels:[$labelsJs],datasets:[{label:'External (ms)',data:[$dataJs],borderColor:'#38bdf8',backgroundColor:'rgba(56,189,248,0.1)',borderWidth:1.5,pointRadius:0,fill:true,tension:0.3,spanGaps:false},{label:'Gateway (ms)',data:[$gwJs],borderColor:'#818cf8',backgroundColor:'rgba(129,140,248,0.05)',borderWidth:1,pointRadius:0,fill:false,tension:0.3,spanGaps:false}]},options:{responsive:true,interaction:{intersect:false,mode:'index'},...cDef}});")
    $htmlParts.Add("new Chart(document.getElementById('histChart'),{type:'bar',data:{labels:['0-10ms','10-25ms','25-50ms','50-100ms','100-200ms','200ms+'],datasets:[{label:'Count',data:[$histJs],backgroundColor:['#22c55e','#4ade80','#facc15','#f59e0b','#f97316','#ef4444'],borderRadius:6}]},options:{responsive:true,plugins:{legend:{display:false}},scales:{x:{ticks:{color:'#64748b'},grid:{display:false}},y:{beginAtZero:true,ticks:{color:'#64748b'},grid:{color:'rgba(51,65,85,0.5)'}}}}});")
    $htmlParts.Add("const hR=[$heatDataJs];new Chart(document.getElementById('heatChart'),{type:'bar',data:{labels:[$heatLabelsJs],datasets:[{label:'Avg Latency (ms)',data:hR,backgroundColor:hR.map(v=>v===null?'#334155':v<10?'#22c55e':v<30?'#4ade80':v<60?'#f59e0b':v<100?'#f97316':'#ef4444'),borderRadius:4}]},options:{responsive:true,plugins:{legend:{display:false},tooltip:{callbacks:{label:ctx=>ctx.raw===null?'No data':ctx.raw+'ms'}}},scales:{x:{ticks:{color:'#64748b'},grid:{display:false}},y:{beginAtZero:true,ticks:{color:'#64748b',callback:v=>v+'ms'},grid:{color:'rgba(51,65,85,0.5)'}}}}});")
    $htmlParts.Add('</script></body></html>')

    $html = $htmlParts -join "`n"

    $dir = Split-Path $reportFile
    if ($dir -and !(Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $html | Set-Content $reportFile -Encoding UTF8
}

# ================================================================
# SESSION SUMMARY
# ================================================================
function ShowSummary {
    $elapsed = (Get-Date) - $script:sessionStart
    $health  = GetHealthScore
    Write-Host ""
    Write-Host "+================================================================+" -ForegroundColor Cyan
    Write-Host "|                  SESSION SUMMARY - v4.0                        |" -ForegroundColor Cyan
    Write-Host "+================================================================+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("  Health Score : {0}/100 ({1})" -f $health.score, $health.grade) -ForegroundColor $health.color
    Write-Host ("  Duration     : {0}" -f (FormatDuration $elapsed)) -ForegroundColor White
    Write-Host ("  Total Pings  : {0}" -f $script:totalPings) -ForegroundColor White
    Write-Host ("  Successful   : {0}" -f $script:totalSuccess) -ForegroundColor Green
    Write-Host ("  Failed       : {0}" -f ($script:totalPings - $script:totalSuccess)) -ForegroundColor Red

    $lossVal = CalcLoss
    Write-Host ("  Packet Loss  : {0}%" -f $lossVal) -ForegroundColor (LossColor $lossVal)
    Write-Host ("  Uptime       : {0}%" -f (CalcUptime)) -ForegroundColor White
    Write-Host ""
    Write-Host ("  Latency  Avg : {0} ms"  -f (CalcAvg))           -ForegroundColor White
    Write-Host ("           Min : {0} ms"  -f (CalcMin))           -ForegroundColor Green
    Write-Host ("           Max : {0} ms"  -f (CalcMax))           -ForegroundColor Red
    Write-Host ("           P95 : {0} ms"  -f (CalcPercentile 95)) -ForegroundColor Yellow
    Write-Host ("           P99 : {0} ms"  -f (CalcPercentile 99)) -ForegroundColor Yellow
    Write-Host ("        Jitter : {0} ms"  -f (CalcJitter))        -ForegroundColor White

    if ($script:baselineLocked) {
        Write-Host ("      Baseline : {0} ms" -f $script:baselineLatency) -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host ("  ISP          : {0}" -f $script:ispName)  -ForegroundColor White
    Write-Host ("  Public IP    : {0}" -f $script:publicIP) -ForegroundColor White
    Write-Host ""

    $dropColor = "Green"
    if ($script:drops.Count -gt 0) { $dropColor = "Red" }
    Write-Host ("  Total Drops     : {0}" -f $script:drops.Count) -ForegroundColor $dropColor

    if ($script:drops.Count -gt 0) {
        $totalDown   = ($script:drops | ForEach-Object { [double]$_.Duration } | Measure-Object -Sum).Sum
        $longestDrop = ($script:drops | ForEach-Object { [double]$_.Duration } | Measure-Object -Maximum).Maximum
        Write-Host ("  Total Downtime  : {0}s" -f [math]::Round($totalDown, 2))   -ForegroundColor Red
        Write-Host ("  Longest Drop    : {0}s" -f [math]::Round($longestDrop, 2)) -ForegroundColor Red
    }

    Write-Host ("  Latency Breaches: {0}" -f $script:thresholdBreaches.Count) -ForegroundColor DarkYellow
    Write-Host ("  Traceroutes     : {0}" -f $script:traceroutes.Count) -ForegroundColor White
    Write-Host ""

    Write-Host "  Per-Target Summary:" -ForegroundColor Magenta
    foreach ($t in $script:perTarget.Keys) {
        $info  = $script:perTarget[$t]
        $tLoss = 0
        if ($info.sent -gt 0) { $tLoss = [math]::Round((1 - $info.ok / $info.sent) * 100, 1) }
        $tAvg = 0; $tMin = 0; $tMax = 0
        if ($info.lats.Count -gt 0) {
            $tAvg = [math]::Round(($info.lats | Measure-Object -Average).Average, 1)
            $tMin = [math]::Round(($info.lats | Measure-Object -Minimum).Minimum, 1)
            $tMax = [math]::Round(($info.lats | Measure-Object -Maximum).Maximum, 1)
        }
        Write-Host ("    {0,-18} Sent:{1,5}  Loss:{2,6}%  Avg:{3,6}ms  Min:{4,6}ms  Max:{5,6}ms" -f
            $t, $info.sent, $tLoss, $tAvg, $tMin, $tMax) -ForegroundColor White
    }

    Write-Host ""
    Write-Host "+================================================================+" -ForegroundColor Cyan
    Write-Host ""
}

# ================================================================
#  STARTUP
# ================================================================
EnsureDirectories
InitToast

Write-Host ""
Write-Host "+================================================+" -ForegroundColor Cyan
Write-Host "|     CONNECTIVITY MONITOR v4.0                  |" -ForegroundColor Cyan
Write-Host "+================================================+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Working dir : $($script:workDir)"    -ForegroundColor Gray
Write-Host "  Logs dir    : $($script:logsDir)"    -ForegroundColor Gray
Write-Host "  Reports dir : $($script:reportsDir)" -ForegroundColor Gray
Write-Host ""

$savedConfig = LoadConfig
$useConfig   = $false

if ($null -ne $savedConfig) {
    Write-Host " Found saved configuration:" -ForegroundColor Green
    Write-Host ("   Adapter   : {0}" -f $savedConfig.adapter)   -ForegroundColor Gray
    Write-Host ("   Targets   : {0}" -f $savedConfig.targets)   -ForegroundColor Gray
    Write-Host ("   Poll      : {0}s" -f $savedConfig.poll)     -ForegroundColor Gray
    Write-Host ("   Threshold : {0}" -f $savedConfig.threshold) -ForegroundColor Gray
    Write-Host ("   Lat Warn  : {0}ms" -f $savedConfig.latWarn) -ForegroundColor Gray
    Write-Host ""
    $useConfig = PromptYesNo " Use saved config?" "Y"
}

if ($useConfig -and $null -ne $savedConfig) {
    $adapter = Get-NetAdapter -Name $savedConfig.adapter -ErrorAction SilentlyContinue
    if ($null -eq $adapter) {
        Write-Host " Saved adapter not found, selecting manually..." -ForegroundColor Yellow
        $adapter = SelectAdapter
    }
    $poll       = [int]$savedConfig.poll
    $threshold  = [int]$savedConfig.threshold
    $targets    = $savedConfig.targets.Split(",") | ForEach-Object { $_.Trim() }
    $latWarn    = [int]$savedConfig.latWarn
    $enableDns  = [bool]$savedConfig.enableDns
    $dnsTarget  = $savedConfig.dnsTarget
    $enableBeep = [bool]$savedConfig.enableBeep
}
else {
    $adapter    = SelectAdapter
    Write-Host ""
    $poll       = [int](PromptDefault " Poll interval (seconds)"        "2")
    $threshold  = [int](PromptDefault " Failure threshold for drop"     "4")
    $targetsRaw = PromptDefault " Ping targets (comma-separated)"       "1.1.1.1,8.8.8.8,208.67.222.222"
    $targets    = $targetsRaw.Split(",") | ForEach-Object { $_.Trim() }
    $latWarn    = [int](PromptDefault " Latency warning threshold (ms)" "100")
    $enableDns  = PromptYesNo " Enable DNS health check?"               "Y"
    $dnsTarget  = ""
    if ($enableDns) { $dnsTarget = PromptDefault " DNS test hostname" "google.com" }
    $enableBeep = PromptYesNo " Audible alert on drop?"                 "N"

    $configToSave = @{
        adapter    = $adapter.Name
        poll       = $poll
        threshold  = $threshold
        targets    = ($targets -join ",")
        latWarn    = $latWarn
        enableDns  = $enableDns
        dnsTarget  = $dnsTarget
        enableBeep = $enableBeep
    }
    SaveConfig $configToSave
    Write-Host " Config saved to $($script:configPath)" -ForegroundColor DarkGray
}

Write-Host " Detecting public IP..." -ForegroundColor DarkGray
DetectPublicIP

Clear-Host
$rr               = 0
$script:currentDate = (Get-Date).Date

# ================================================================
#  MAIN LOOP
# ================================================================
Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress -Action {
    $script:shutdown = $true
    $_.Cancel = $true
} | Out-Null

# Init loop variables for first paused frame
$a         = Get-NetAdapter -Name $adapter.Name
$gw        = GetGateway $a.Name
$localIP   = GetLocalIP $a.Name
$target    = $targets[0]
$p         = @{ ok = $false; lat = $null; target = $target; time = Get-Date }
$gwPing    = @{ ok = $false; lat = $null }
$dnsResult = @{ ok = $true; ms = $null }
$wifiSig   = $null

while (-not $script:shutdown) {

    while ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        switch ($key.KeyChar) {
            "1" { $script:activeTab = 1 }
            "2" { $script:activeTab = 2 }
            "3" { $script:activeTab = 3 }
            "4" { $script:activeTab = 4 }
            "5" { $script:activeTab = 5 }
        }
        switch ($key.Key) {
            "P" { $script:paused = -not $script:paused }
            "R" {
                $script:history.Clear()
                $script:drops.Clear()
                $script:perTarget.Clear()
                $script:gwHistory.Clear()
                $script:thresholdBreaches.Clear()
                $script:traceroutes.Clear()
                $script:heatmap       = @{}
                $script:failCount     = 0
                $script:isDown        = $false
                $script:totalPings    = 0
                $script:totalSuccess  = 0
                $script:sessionStart  = Get-Date
                $script:baselineSamples.Clear()
                $script:baselineLatency = $null
                $script:baselineLocked  = $false
            }
            "Q" { $script:shutdown = $true; break }
            "E" {
                $snapFile = Join-Path $script:reportsDir ("report_{0}.html" -f (Get-Date -Format "yyyy-MM-dd_HHmmss"))
                GenerateHtmlReport $snapFile
            }
        }
    }

    if ($script:paused) {
        $consoleWidth = $Host.UI.RawUI.WindowSize.Width
        $frame = BuildTab1 $a $gw $localIP $target $p $gwPing $dnsResult $latWarn $enableDns $wifiSig $script:lastDiagnosis
        RenderFrame $frame $consoleWidth
        Start-Sleep -Milliseconds 500
        continue
    }

    CheckDateRollover

    $a       = Get-NetAdapter -Name $adapter.Name
    $gw      = GetGateway $a.Name
    $localIP = GetLocalIP $a.Name
    $target  = $targets[$rr % $targets.Count]
    $rr++

    if ($a.Status -ne "Up") {
        $p = @{ ok = $false; lat = $null; target = $target; time = Get-Date }
        UpdateHistory $null $target
    }
    else {
        $p = PingTest $target
        if ($p.ok) { UpdateHistory $p.lat $target }
        else       { UpdateHistory $null $target  }
    }

    $gwPing = @{ ok = $false; lat = $null }
    if ($a.Status -eq "Up" -and $gw -ne "N/A" -and $gw -ne "None") {
        $gwPing = PingTest $gw
        if ($gwPing.ok) { UpdateGwHistory $gwPing.lat }
        else            { UpdateGwHistory $null        }
    }

    $dnsResult = @{ ok = $true; ms = $null }
    if ($enableDns -and $a.Status -eq "Up") {
        $dnsResult = DnsTest $dnsTarget
    }

    if ($rr % 5 -eq 0) { $wifiSig = GetWifiSignal }

    $script:lastDiagnosis = DiagnoseIssue $gwPing $p

    $pingLogFile = GetDatedLogFile "ping_log"
    LogPing $p $gwPing $dnsResult $wifiSig $pingLogFile

    if (-not $p.ok) {
        $script:failCount++
        if ($script:failCount -ge $threshold -and -not $script:isDown) {
            $script:isDown    = $true
            $script:downStart = Get-Date
            if ($enableBeep) { [Console]::Beep(1000, 300) }
            ShowToast "Connection Lost" ("Target: {0} | {1}" -f $target, $script:lastDiagnosis.msg)
            $trTarget = $target
            $null = [System.Threading.Tasks.Task]::Run([Action]{ RunTraceroute $trTarget })
        }
    }
    else {
        if ($script:isDown) {
            $outageEnd   = Get-Date
            $dropLogFile = GetDatedLogFile "drops"
            LogDrop $script:downStart $outageEnd $target $script:lastDiagnosis.msg $dropLogFile
            $durSecs = [math]::Round(($outageEnd - $script:downStart).TotalSeconds, 1)
            ShowToast "Connection Restored" ("Target: {0} | Down for {1}s" -f $target, $durSecs)
            $script:isDown = $false
            if ($enableBeep) { [Console]::Beep(600, 150); [Console]::Beep(800, 150) }
        }
        $script:failCount = 0
    }

    if ($p.ok -and $null -ne $p.lat -and $p.lat -ge $latWarn) {
        if (-not $script:breachActive) {
            $script:breachActive = $true
            $script:breachStart  = Get-Date
        }
        if ($enableBeep) { [Console]::Beep(500, 100) }
    }
    else {
        if ($script:breachActive) {
            $breachEnd  = Get-Date
            $breachFile = GetDatedLogFile "breaches"
            LogBreach $script:breachStart $breachEnd (CalcAvg) $breachFile
            $script:breachActive = $false
        }
    }

    if ($script:totalPings % 100 -eq 0 -and $script:totalPings -gt 0) { DetectPublicIP }

    if ($script:totalPings % 500 -eq 0 -and $script:totalPings -gt 0) {
        $autoReport = Join-Path $script:reportsDir ("report_{0}.html" -f (Get-Date -Format "yyyy-MM-dd_HHmmss"))
        GenerateHtmlReport $autoReport
    }

    $consoleWidth = $Host.UI.RawUI.WindowSize.Width
    switch ($script:activeTab) {
        1 { $frame = BuildTab1 $a $gw $localIP $target $p $gwPing $dnsResult $latWarn $enableDns $wifiSig $script:lastDiagnosis }
        2 { $frame = BuildTab2 }
        3 { $frame = BuildTab3 }
        4 { $frame = BuildTab4 }
        5 { $frame = BuildTab5 }
    }

    RenderFrame $frame $consoleWidth
    Start-Sleep $poll
}

# ================================================================
#  SHUTDOWN
# ================================================================
if ($script:isDown) {
    $outageEnd   = Get-Date
    $dropLogFile = GetDatedLogFile "drops"
    LogDrop $script:downStart $outageEnd "N/A" "Session ended during outage" $dropLogFile
}

if ($script:breachActive) {
    $breachEnd  = Get-Date
    $breachFile = GetDatedLogFile "breaches"
    LogBreach $script:breachStart $breachEnd (CalcAvg) $breachFile
}

Clear-Host
Write-Host " Generating final HTML report..." -ForegroundColor Cyan
$finalReport = Join-Path $script:reportsDir ("report_{0}.html" -f (Get-Date -Format "yyyy-MM-dd_HHmmss"))
GenerateHtmlReport $finalReport

ShowSummary

Write-Host " Output files:" -ForegroundColor Cyan
Write-Host ("   Config       : {0}" -f $script:configPath)   -ForegroundColor White
Write-Host ("   Logs dir     : {0}" -f $script:logsDir)      -ForegroundColor White
Write-Host ("   Reports dir  : {0}" -f $script:reportsDir)   -ForegroundColor White
Write-Host ("   Last report  : {0}" -f $finalReport)         -ForegroundColor White
Write-Host ""

$openReport = PromptYesNo " Open HTML report in browser?" "Y"
if ($openReport) { Start-Process $finalReport }

Write-Host ""
Write-Host " Connectivity Monitor v4.0 stopped." -ForegroundColor Cyan
