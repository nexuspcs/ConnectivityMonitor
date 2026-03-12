Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ================================================================
#  CONNECTIVITY MONITOR v3.0
#  Real-time dashboard | Smart analysis | HTML & CSV reporting
#  Flicker-free double-buffered rendering
#  JAMES COATES and Claude Opus 4.6
# ================================================================

# -------------------------
# GLOBAL STATE
# -------------------------
$script:history = [System.Collections.Generic.List[PSObject]]::new()
$script:drops = [System.Collections.Generic.List[PSObject]]::new()
$script:perTarget = @{}
$script:failCount = 0
$script:isDown = $false
$script:downStart = $null
$script:sessionStart = Get-Date
$script:totalPings = 0
$script:totalSuccess = 0
$script:shutdown = $false
$script:graphWidth = 60
$script:maxHistory = 1000
$script:lastLineCount = 0
$script:paused = $false
$script:baselineLatency = $null
$script:baselineSamples = [System.Collections.Generic.List[double]]::new()
$script:baselineLocked = $false
$script:gwHistory = [System.Collections.Generic.List[PSObject]]::new()
$script:thresholdBreaches = [System.Collections.Generic.List[PSObject]]::new()
$script:breachActive = $false
$script:breachStart = $null
$script:publicIP = "detecting..."
$script:ispName = "detecting..."

[Console]::CursorVisible = $false
chcp 65001 > $null
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# -------------------------
# CONFIG FILE
# -------------------------
$script:configPath = Join-Path (Get-Location) "monitor_config.json"

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

# -------------------------
# CONFIG PROMPTS
# -------------------------
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

# -------------------------
# ADAPTER SELECT
# -------------------------
function SelectAdapter {
    $adapters = Get-NetAdapter -Physical | Where-Object Status -ne "Not Present"
    Write-Host ""
    Write-Host "+================================================+" -ForegroundColor Cyan
    Write-Host "|       CONNECTIVITY MONITOR v3.0                 |" -ForegroundColor Cyan
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
    $n = Read-Host " Select adapter (use arrow keys)"
    return $adapters[$n - 1]
}

# -------------------------
# NETWORK TESTS
# -------------------------
function PingTest($target) {
    try {
        $r = Test-Connection $target -Count 1 -ErrorAction Stop | Select-Object -First 1
        return @{ ok = $true; lat = $r.ResponseTime; target = $target; time = Get-Date }
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

function Gateway($alias) {
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
        $script:ispName = $resp.isp
    }
    catch {
        $script:publicIP = "N/A"
        $script:ispName = "N/A"
    }
}

function GetWifiSignal {
    try {
        $out = netsh wlan show interfaces 2>$null
        $sigLine = $out | Select-String "Signal" | Select-Object -First 1
        if ($sigLine) {
            $pct = ($sigLine -replace "[^0-9]", "")
            return [int]$pct
        }
        return $null
    }
    catch { return $null }
}

# -------------------------
# METRICS ENGINE
# -------------------------
function UpdateHistory($lat, $target) {
    $entry = [PSCustomObject]@{
        Time    = Get-Date
        Latency = $lat
        Target  = $target
    }
    $script:history.Add($entry)
    $script:totalPings++
    if ($null -ne $lat) { $script:totalSuccess++ }

    while ($script:history.Count -gt $script:maxHistory) {
        $script:history.RemoveAt(0)
    }

    if (-not $script:perTarget.ContainsKey($target)) {
        $script:perTarget[$target] = @{ sent = 0; ok = 0; lats = [System.Collections.Generic.List[double]]::new() }
    }
    $script:perTarget[$target].sent++
    if ($null -ne $lat) {
        $script:perTarget[$target].ok++
        $script:perTarget[$target].lats.Add($lat)
    }

    # Baseline learning (first 30 successful pings)
    if (-not $script:baselineLocked -and $null -ne $lat) {
        $script:baselineSamples.Add($lat)
        if ($script:baselineSamples.Count -ge 30) {
            $script:baselineLatency = [math]::Round(($script:baselineSamples | Measure-Object -Average).Average, 1)
            $script:baselineLocked = $true
        }
    }
}

function UpdateGwHistory($gwLat) {
    $entry = [PSCustomObject]@{
        Time    = Get-Date
        Latency = $gwLat
    }
    $script:gwHistory.Add($entry)
    while ($script:gwHistory.Count -gt 200) {
        $script:gwHistory.RemoveAt(0)
    }
}

function Loss {
    $total = $script:history.Count
    $lost = @($script:history | Where-Object { $null -eq $_.Latency }).Count
    if ($total -eq 0) { return 0 }
    return [math]::Round(($lost / $total) * 100, 1)
}

function Avg {
    $vals = @($script:history | Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency })
    if ($vals.Count -eq 0) { return 0 }
    return [math]::Round(($vals | Measure-Object -Average).Average, 1)
}

function MinLat {
    $vals = @($script:history | Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency })
    if ($vals.Count -eq 0) { return 0 }
    return [math]::Round(($vals | Measure-Object -Minimum).Minimum, 1)
}

function MaxLat {
    $vals = @($script:history | Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency })
    if ($vals.Count -eq 0) { return 0 }
    return [math]::Round(($vals | Measure-Object -Maximum).Maximum, 1)
}

function Percentile($pct) {
    $vals = @($script:history | Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency } | Sort-Object)
    if ($vals.Count -eq 0) { return 0 }
    $idx = [math]::Floor($vals.Count * $pct / 100)
    if ($idx -ge $vals.Count) { $idx = $vals.Count - 1 }
    return [math]::Round($vals[$idx], 1)
}

function Jitter {
    $vals = @($script:history | Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency })
    if ($vals.Count -lt 2) { return 0 }
    $diffs = @()
    for ($i = 1; $i -lt $vals.Count; $i++) {
        $diffs += [math]::Abs($vals[$i] - $vals[$i - 1])
    }
    return [math]::Round(($diffs | Measure-Object -Average).Average, 1)
}

function Uptime {
    $total = $script:history.Count
    if ($total -eq 0) { return 100.0 }
    $ok = @($script:history | Where-Object { $null -ne $_.Latency }).Count
    return [math]::Round(($ok / $total) * 100, 2)
}

# -------------------------
# TREND DETECTION
# -------------------------
function GetTrend {
    $recent = @($script:history | Select-Object -Last 30 | Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency })
    if ($recent.Count -lt 10) { return @{ arrow = "->"; label = "Collecting"; color = "DarkGray" } }

    $half = [math]::Floor($recent.Count / 2)
    $first = @($recent[0..($half - 1)])
    $second = @($recent[$half..($recent.Count - 1)])

    $avgFirst = ($first | Measure-Object -Average).Average
    $avgSecond = ($second | Measure-Object -Average).Average

    $change = $avgSecond - $avgFirst
    $pctChange = 0
    if ($avgFirst -gt 0) { $pctChange = ($change / $avgFirst) * 100 }

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

function GetHealthScore {
    $loss = Loss
    $avg = Avg
    $jitter = Jitter
    $score = 100

    # Deduct for loss
    $score -= ($loss * 3)
    # Deduct for high latency
    if ($avg -gt 100) { $score -= 20 }
    elseif ($avg -gt 50) { $score -= 10 }
    elseif ($avg -gt 30) { $score -= 5 }
    # Deduct for jitter
    if ($jitter -gt 30) { $score -= 15 }
    elseif ($jitter -gt 15) { $score -= 8 }
    elseif ($jitter -gt 5) { $score -= 3 }

    $score = [math]::Max(0, [math]::Min(100, [math]::Round($score)))

    $grade = "A+"
    $color = "Green"
    if ($score -lt 50) { $grade = "F"; $color = "Red" }
    elseif ($score -lt 60) { $grade = "D"; $color = "Red" }
    elseif ($score -lt 70) { $grade = "C"; $color = "Yellow" }
    elseif ($score -lt 80) { $grade = "B"; $color = "Yellow" }
    elseif ($score -lt 90) { $grade = "A"; $color = "Green" }

    return @{ score = $score; grade = $grade; color = $color }
}

function DiagnoseIssue($gwPing, $extPing) {
    if ($gwPing.ok -and $extPing.ok) { return @{ msg = "All clear"; color = "Green" } }
    if (-not $gwPing.ok -and -not $extPing.ok) { return @{ msg = "Local network issue (gateway unreachable)"; color = "Red" } }
    if ($gwPing.ok -and -not $extPing.ok) { return @{ msg = "ISP / upstream issue (gateway OK, internet down)"; color = "Yellow" } }
    return @{ msg = "Unusual state"; color = "DarkYellow" }
}

# -------------------------
# ASCII GRAPH (returns lines)
# -------------------------
function BuildLatencyGraph($width, $height) {
    $vals = @($script:history | Select-Object -Last $width | ForEach-Object { $_.Latency })
    if ($vals.Count -eq 0) { return @() }

    $numericVals = @($vals | Where-Object { $null -ne $_ })
    if ($numericVals.Count -eq 0) {
        $maxVal = 1
    }
    else {
        $maxVal = ($numericVals | Measure-Object -Maximum).Maximum
        if ($maxVal -eq 0) { $maxVal = 1 }
    }

    $lines = @()
    $lines += ("  Latency (ms) -- last {0} pings  [max: {1}ms]" -f $vals.Count, [math]::Round($maxVal, 0))

    for ($row = $height; $row -ge 1; $row--) {
        $rowThreshold = ($row / $height) * $maxVal
        $line = ""
        foreach ($v in $vals) {
            if ($null -eq $v) {
                $line += "X"
            }
            elseif ($v -ge $rowThreshold) {
                if ($v -lt 10) { $line += "." }
                elseif ($v -lt 50) { $line += "o" }
                elseif ($v -lt 100) { $line += "O" }
                else { $line += "@" }
            }
            else {
                $line += " "
            }
        }
        $label = "{0,6}" -f [math]::Round($rowThreshold, 0)
        $lines += ($label + " |" + $line + "|")
    }

    $lines += ("       +" + ("-" * $vals.Count) + "+")
    $lines += "       Legend: . <10ms  o <50ms  O <100ms  @ >100ms  X drop"
    return $lines
}

function BuildSparkline {
    $vals = @($script:history | Select-Object -Last 80 | ForEach-Object { $_.Latency })
    if ($vals.Count -eq 0) { return "" }

    $chars = @("_", ".", "-", "~", "^")
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

function BuildHistogram {
    $vals = @($script:history | Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency })
    if ($vals.Count -lt 5) { return @("  (need more data for histogram)") }

    $bucketNames = @("  0-10ms", " 10-25ms", " 25-50ms", " 50-100ms", "100-200ms", "  200ms+")
    $bucketCounts = @(0, 0, 0, 0, 0, 0)

    foreach ($v in $vals) {
        if ($v -lt 10) { $bucketCounts[0]++ }
        elseif ($v -lt 25) { $bucketCounts[1]++ }
        elseif ($v -lt 50) { $bucketCounts[2]++ }
        elseif ($v -lt 100) { $bucketCounts[3]++ }
        elseif ($v -lt 200) { $bucketCounts[4]++ }
        else { $bucketCounts[5]++ }
    }

    $maxCount = ($bucketCounts | Measure-Object -Maximum).Maximum
    if ($maxCount -eq 0) { $maxCount = 1 }
    $barMax = 30

    $lines = @()
    $lines += "  Latency Distribution:"
    for ($b = 0; $b -lt $bucketNames.Count; $b++) {
        $count = $bucketCounts[$b]
        $barLen = [math]::Round(($count / $maxCount) * $barMax)
        $bar = "=" * $barLen
        $pct = [math]::Round(($count / $vals.Count) * 100, 0)
        $lines += ("  {0} |{1,-30} {2,4} ({3}%)" -f $bucketNames[$b], $bar, $count, $pct)
    }
    return $lines
}

# -------------------------
# LOGGING (ENRICHED CSV)
# -------------------------
function LogPing($pingResult, $gwResult, $dnsResult, $wifiSig, $file) {
    $latVal = ""
    if ($null -ne $pingResult.lat) { $latVal = $pingResult.lat }
    $gwLatVal = ""
    if ($null -ne $gwResult -and $gwResult.ok) { $gwLatVal = $gwResult.lat }
    $dnsMs = ""
    if ($null -ne $dnsResult -and $dnsResult.ok -and $null -ne $dnsResult.ms) { $dnsMs = $dnsResult.ms }
    $wifiVal = ""
    if ($null -ne $wifiSig) { $wifiVal = $wifiSig }

    $trend = GetTrend
    $health = GetHealthScore

    $record = [PSCustomObject]@{
        Timestamp     = $pingResult.time.ToString("yyyy-MM-dd HH:mm:ss.fff")
        Target        = $pingResult.target
        Success       = $pingResult.ok
        LatencyMs     = $latVal
        GatewayMs     = $gwLatVal
        DnsMs         = $dnsMs
        WifiSignalPct = $wifiVal
        PacketLossPct = Loss
        AvgLatencyMs  = Avg
        JitterMs      = Jitter
        P95Ms         = Percentile 95
        UptimePct     = Uptime
        Trend         = $trend.label
        HealthScore   = $health.score
        HealthGrade   = $health.grade
        BaselineMs    = $(if ($script:baselineLatency) { $script:baselineLatency } else { "" })
        PublicIP      = $script:publicIP
        ISP           = $script:ispName
    }

    $dir = Split-Path $file
    if ($dir -and !(Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }

    if (!(Test-Path $file)) {
        $record | Export-Csv $file -NoTypeInformation
    }
    else {
        $record | Export-Csv $file -Append -NoTypeInformation
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
    if ($dir -and !(Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }

    if (!(Test-Path $file)) {
        $record | Export-Csv $file -NoTypeInformation
    }
    else {
        $record | Export-Csv $file -Append -NoTypeInformation
    }

    $script:drops.Add($record)
}

function LogThresholdBreach($start, $end, $avgLat, $file) {
    $dur = [math]::Round(($end - $start).TotalSeconds, 2)
    $record = [PSCustomObject]@{
        Start      = $start.ToString("yyyy-MM-dd HH:mm:ss.fff")
        End        = $end.ToString("yyyy-MM-dd HH:mm:ss.fff")
        Duration   = $dur
        AvgLatency = $avgLat
    }

    $dir = Split-Path $file
    if ($dir -and !(Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }

    $breachFile = $file -replace "\.csv$", "_breaches.csv"
    if (!(Test-Path $breachFile)) {
        $record | Export-Csv $breachFile -NoTypeInformation
    }
    else {
        $record | Export-Csv $breachFile -Append -NoTypeInformation
    }

    $script:thresholdBreaches.Add($record)
}

# -------------------------
# COLOR HELPERS
# -------------------------
function LatencyColor($ms) {
    if ($null -eq $ms) { return "Red" }
    if ($ms -lt 30) { return "Green" }
    if ($ms -lt 80) { return "Yellow" }
    return "Red"
}

function LossColor($pct) {
    if ($pct -eq 0) { return "Green" }
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

# =========================================================
# DOUBLE-BUFFERED RENDERER
# =========================================================
function RenderFrame($frameLines, $consoleWidth) {
    [Console]::SetCursorPosition(0, 0)

    foreach ($fl in $frameLines) {
        $text = $fl.Text
        $color = $fl.Color
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

# -------------------------
# BUILD FRAME
# -------------------------
function BuildFrame($adapter, $gw, $localIP, $target, $ping, $gwPing, $dnsResult, $latWarn, $enableDns, $wifiSig, $diagnosis) {
    $loss = Loss
    $avg = Avg
    $jitter = Jitter
    $min = MinLat
    $max = MaxLat
    $p95 = Percentile 95
    $up = Uptime
    $elapsed = (Get-Date) - $script:sessionStart
    $trend = GetTrend
    $health = GetHealthScore

    $frame = [System.Collections.Generic.List[hashtable]]::new()

    function AddLine($text, $color) {
        $frame.Add(@{ Text = $text; Color = $color })
    }

    # -- HEADER --
    $headerTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    AddLine "+================================================================+" "Cyan"
    AddLine ("|  [*] CONNECTIVITY MONITOR v3.0          {0}     |" -f $headerTime) "Cyan"
    AddLine "+================================================================+" "Cyan"

    # Sparkline
    $spark = BuildSparkline
    if ($spark.Length -gt 0) {
        AddLine ("  Spark: {0}" -f $spark) "DarkCyan"
    }
    AddLine "" "White"

    # -- CONNECTION INFO --
    AddLine ("  Adapter  : {0}" -f $adapter.Name) "White"
    AddLine ("  Local IP : {0}" -f $localIP) "White"
    AddLine ("  Gateway  : {0}" -f $gw) "White"
    AddLine ("  Public   : {0}  ({1})" -f $script:publicIP, $script:ispName) "White"
    AddLine ("  Target   : {0}" -f $target) "Yellow"
    AddLine ("  Session  : {0}" -f (FormatDuration $elapsed)) "White"

    if ($null -ne $wifiSig) {
        $wifiColor = "Green"
        if ($wifiSig -lt 40) { $wifiColor = "Red" }
        elseif ($wifiSig -lt 70) { $wifiColor = "Yellow" }
        AddLine ("  WiFi     : {0}%" -f $wifiSig) $wifiColor
    }

    if ($script:baselineLocked) {
        AddLine ("  Baseline : {0} ms (learned)" -f $script:baselineLatency) "DarkCyan"
    }
    else {
        $remaining = 30 - $script:baselineSamples.Count
        AddLine ("  Baseline : learning... ({0} more samples)" -f $remaining) "DarkGray"
    }

    AddLine "" "White"

    # -- HEALTH SCORE --
    AddLine ("  Health: {0}/100  Grade: {1}  Trend: {2} {3}" -f $health.score, $health.grade, $trend.arrow, $trend.label) $health.color

    # -- DIAGNOSIS --
    if ($null -ne $diagnosis) {
        AddLine ("  Diagnosis: {0}" -f $diagnosis.msg) $diagnosis.color
    }

    if ($script:paused) {
        AddLine "  ** PAUSED ** (press P to resume)" "Yellow"
    }
    AddLine "" "White"

    # -- STATUS PANEL --
    AddLine "  +-------------------------------------+" "DarkGray"

    $linkStr = "[DOWN]"
    if ($adapter.Status -eq "Up") { $linkStr = "[UP]  " }
    if ($adapter.Status -ne "Up") { $inet = "DOWN" }
    elseif ($ping.ok) { $inet = "OK" }
    else { $inet = "FAIL" }

    $gwStr = ""
    if ($null -ne $gwPing) {
        if ($gwPing.ok) { $gwStr = "  GW: OK({0}ms)" -f $gwPing.lat }
        else { $gwStr = "  GW: FAIL" }
    }

    $dnsStr = ""
    if ($enableDns) {
        if ($dnsResult.ok) { $dnsStr = "  DNS: OK({0}ms)" -f $dnsResult.ms }
        else { $dnsStr = "  DNS: FAIL" }
    }

    $statusLine = "  |  Link: {0}  Net: {1}{2}{3}" -f $linkStr, $inet, $gwStr, $dnsStr
    $statusColor = "Green"
    if ($adapter.Status -ne "Up" -or !$ping.ok) { $statusColor = "Red" }
    $stPad = 39 - $statusLine.Length
    if ($stPad -lt 1) { $stPad = 1 }
    $statusLine += (" " * $stPad) + "|"
    AddLine $statusLine $statusColor

    # Latency line
    if ($null -ne $ping.lat) {
        $latStr = "{0} ms" -f $ping.lat
        if ($ping.lat -ge $latWarn) { $latStr += " !! HIGH" }
    }
    else { $latStr = "--" }
    $lc = LatencyColor $ping.lat
    $latLine = "  |  Latency  : {0}" -f $latStr
    $latPad = 39 - $latLine.Length
    if ($latPad -lt 1) { $latPad = 1 }
    $latLine += (" " * $latPad) + "|"
    AddLine $latLine $lc

    AddLine "  +-------------------------------------+" "DarkGray"
    AddLine "" "White"

    # -- STATISTICS --
    AddLine "  +---- Statistics ---------------------+" "DarkGray"

    $lossStr = "{0}%" -f $loss
    $lossLine = "  |  Pkt Loss  : {0}" -f $lossStr
    $lossPad = 39 - $lossLine.Length
    if ($lossPad -lt 1) { $lossPad = 1 }
    $lossLine += (" " * $lossPad) + "|"
    AddLine $lossLine (LossColor $loss)

    $statLabels = @("Avg", "Min", "Max", "P95", "Jitter", "Uptime")
    $statValues = @(
        ("{0} ms" -f $avg),
        ("{0} ms" -f $min),
        ("{0} ms" -f $max),
        ("{0} ms" -f $p95),
        ("{0} ms" -f $jitter),
        ("{0}%" -f $up)
    )

    for ($si = 0; $si -lt $statLabels.Count; $si++) {
        $slabel = $statLabels[$si]
        $svalue = $statValues[$si]
        $padLabel = 10 - $slabel.Length
        if ($padLabel -lt 0) { $padLabel = 0 }
        $sLine = "  |  {0}{1}: {2}" -f $slabel, (" " * $padLabel), $svalue
        $sPad = 39 - $sLine.Length
        if ($sPad -lt 1) { $sPad = 1 }
        $sLine += (" " * $sPad) + "|"
        AddLine $sLine "White"
    }

    AddLine "  +-------------------------------------+" "DarkGray"
    AddLine "" "White"

    # -- LATENCY GRAPH --
    $graphLines = BuildLatencyGraph $script:graphWidth 8
    foreach ($gl in $graphLines) {
        $graphColor = "DarkGray"
        if ($gl.Contains("X")) { $graphColor = "Yellow" }
        elseif ($gl.Contains("@")) { $graphColor = "Red" }
        elseif ($gl.Contains("O")) { $graphColor = "DarkYellow" }
        elseif ($gl.Contains("o")) { $graphColor = "Cyan" }
        elseif ($gl.Contains(".")) { $graphColor = "Green" }
        AddLine $gl $graphColor
    }
    AddLine "" "White"

    # -- HISTOGRAM --
    $histLines = BuildHistogram
    foreach ($hl in $histLines) {
        AddLine $hl "DarkCyan"
    }
    AddLine "" "White"

    # -- RECENT DROPS --
    AddLine "  Recent Drops:" "Yellow"
    if ($script:drops.Count -eq 0) {
        AddLine "    (none)" "DarkGray"
    }
    else {
        AddLine ("    {0,-22} {1,-10} {2,-15} {3}" -f "Start", "Duration", "Target", "Diagnosis") "DarkYellow"
        foreach ($d in ($script:drops | Select-Object -Last 8)) {
            $durVal = [double]$d.Duration
            $dColor = "White"
            if ($durVal -ge 30) { $dColor = "Red" }
            elseif ($durVal -ge 10) { $dColor = "Yellow" }
            AddLine ("    {0,-22} {1,-10} {2,-15} {3}" -f $d.Start, ("{0}s" -f $d.Duration), $d.Target, $d.Diagnosis) $dColor
        }
    }

    # -- THRESHOLD BREACHES --
    if ($script:thresholdBreaches.Count -gt 0) {
        AddLine "" "White"
        AddLine "  High Latency Events:" "DarkYellow"
        foreach ($b in ($script:thresholdBreaches | Select-Object -Last 5)) {
            AddLine ("    {0}  {1}s  avg:{2}ms" -f $b.Start, $b.Duration, $b.AvgLatency) "DarkYellow"
        }
    }

    # -- PER-TARGET STATS --
    AddLine "" "White"
    AddLine "  Per-Target Health:" "Magenta"
    foreach ($t in $script:perTarget.Keys) {
        $info = $script:perTarget[$t]
        $tLoss = 0
        if ($info.sent -gt 0) { $tLoss = [math]::Round((1 - $info.ok / $info.sent) * 100, 1) }
        $tAvg = 0
        if ($info.lats.Count -gt 0) { $tAvg = [math]::Round(($info.lats | Measure-Object -Average).Average, 1) }
        $tColor = "White"
        if ($tLoss -gt 0) { $tColor = "Yellow" }
        if ($tLoss -ge 5) { $tColor = "Red" }
        AddLine ("    {0,-18} Loss:{1,5}%  Avg:{2,6}ms  ({3} pings)" -f $t, $tLoss, $tAvg, $info.sent) $tColor
    }

    # -- HOTKEYS --
    AddLine "" "White"
    AddLine "  [P]ause  [R]eset  [Q]uit  |  Ctrl+C to stop" "DarkGray"

    return $frame
}

# ===================================================================
# HTML REPORT GENERATOR
# ===================================================================
function GenerateHtmlReport($reportFile) {
    $elapsed = (Get-Date) - $script:sessionStart
    $loss = Loss
    $avg = Avg
    $min = MinLat
    $max = MaxLat
    $p95 = Percentile 95
    $p99 = Percentile 99
    $jitter = Jitter
    $up = Uptime
    $health = GetHealthScore

    # Build latency data for chart (JS array)
    $chartLabels = [System.Collections.Generic.List[string]]::new()
    $chartData = [System.Collections.Generic.List[string]]::new()
    $chartGw = [System.Collections.Generic.List[string]]::new()

    foreach ($h in $script:history) {
        $chartLabels.Add('"' + $h.Time.ToString("HH:mm:ss") + '"')
        if ($null -ne $h.Latency) {
            $chartData.Add($h.Latency.ToString())
        }
        else {
            $chartData.Add("null")
        }
    }

    foreach ($g in $script:gwHistory) {
        if ($null -ne $g.Latency) {
            $chartGw.Add($g.Latency.ToString())
        }
        else {
            $chartGw.Add("null")
        }
    }

    # Pad gateway data to match length
    while ($chartGw.Count -lt $chartData.Count) {
        $chartGw.Insert(0, "null")
    }

    $labelsJs = $chartLabels -join ","
    $dataJs = $chartData -join ","
    $gwJs = $chartGw -join ","

    # Histogram data
    $histData = @(0, 0, 0, 0, 0, 0)
    $vals = @($script:history | Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency })
    foreach ($v in $vals) {
        if ($v -lt 10) { $histData[0]++ }
        elseif ($v -lt 25) { $histData[1]++ }
        elseif ($v -lt 50) { $histData[2]++ }
        elseif ($v -lt 100) { $histData[3]++ }
        elseif ($v -lt 200) { $histData[4]++ }
        else { $histData[5]++ }
    }
    $histJs = $histData -join ","

    # Per-target table rows
    $targetRows = ""
    foreach ($t in $script:perTarget.Keys) {
        $info = $script:perTarget[$t]
        $tLoss = 0
        if ($info.sent -gt 0) { $tLoss = [math]::Round((1 - $info.ok / $info.sent) * 100, 1) }
        $tAvg = 0; $tMin = 0; $tMax = 0
        if ($info.lats.Count -gt 0) {
            $tAvg = [math]::Round(($info.lats | Measure-Object -Average).Average, 1)
            $tMin = [math]::Round(($info.lats | Measure-Object -Minimum).Minimum, 1)
            $tMax = [math]::Round(($info.lats | Measure-Object -Maximum).Maximum, 1)
        }
        $rowClass = ""
        if ($tLoss -ge 5) { $rowClass = ' class="bad"' }
        elseif ($tLoss -gt 0) { $rowClass = ' class="warn"' }
        $targetRows += "<tr$rowClass><td>$t</td><td>$($info.sent)</td><td>$($info.ok)</td><td>${tLoss}%</td><td>${tAvg}ms</td><td>${tMin}ms</td><td>${tMax}ms</td></tr>`n"
    }

    # Drop table rows
    $dropRows = ""
    foreach ($d in $script:drops) {
        $rowClass = ""
        $dv = [double]$d.Duration
        if ($dv -ge 30) { $rowClass = ' class="bad"' }
        elseif ($dv -ge 10) { $rowClass = ' class="warn"' }
        $dropRows += "<tr$rowClass><td>$($d.Start)</td><td>$($d.End)</td><td>$($d.Duration)s</td><td>$($d.Target)</td><td>$($d.Diagnosis)</td></tr>`n"
    }

    # Breach table rows
    $breachRows = ""
    foreach ($b in $script:thresholdBreaches) {
        $breachRows += "<tr><td>$($b.Start)</td><td>$($b.End)</td><td>$($b.Duration)s</td><td>$($b.AvgLatency)ms</td></tr>`n"
    }

    # Total downtime
    $totalDowntime = 0
    $longestDrop = 0
    if ($script:drops.Count -gt 0) {
        $totalDowntime = [math]::Round(($script:drops | ForEach-Object { [double]$_.Duration } | Measure-Object -Sum).Sum, 2)
        $longestDrop = [math]::Round(($script:drops | ForEach-Object { [double]$_.Duration } | Measure-Object -Maximum).Maximum, 2)
    }

    # Health color for CSS
    $healthCssColor = "#22c55e"
    if ($health.score -lt 60) { $healthCssColor = "#ef4444" }
    elseif ($health.score -lt 80) { $healthCssColor = "#f59e0b" }

    $uptimeCssColor = "#22c55e"
    if ($up -lt 95) { $uptimeCssColor = "#ef4444" }
    elseif ($up -lt 99) { $uptimeCssColor = "#f59e0b" }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Network Report - $(Get-Date -Format "yyyy-MM-dd HH:mm")</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
  :root {
    --bg: #0f172a;
    --card: #1e293b;
    --border: #334155;
    --text: #e2e8f0;
    --muted: #94a3b8;
    --accent: #38bdf8;
    --green: #22c55e;
    --yellow: #f59e0b;
    --red: #ef4444;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.6;
    padding: 20px;
  }
  .container { max-width: 1400px; margin: 0 auto; }

  /* Header */
  .header {
    text-align: center;
    padding: 40px 20px;
    background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%);
    border: 1px solid var(--border);
    border-radius: 16px;
    margin-bottom: 24px;
  }
  .header h1 {
    font-size: 2rem;
    font-weight: 700;
    background: linear-gradient(90deg, #38bdf8, #818cf8);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    margin-bottom: 8px;
  }
  .header .subtitle { color: var(--muted); font-size: 0.95rem; }
  .header .session-info {
    display: flex;
    justify-content: center;
    gap: 32px;
    margin-top: 16px;
    flex-wrap: wrap;
  }
  .header .session-info span {
    color: var(--muted);
    font-size: 0.85rem;
  }
  .header .session-info strong { color: var(--text); }

  /* Score Cards Row */
  .score-row {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 16px;
    margin-bottom: 24px;
  }
  .score-card {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 20px;
    text-align: center;
  }
  .score-card .label {
    font-size: 0.8rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    color: var(--muted);
    margin-bottom: 8px;
  }
  .score-card .value {
    font-size: 2rem;
    font-weight: 700;
  }
  .score-card .sub {
    font-size: 0.8rem;
    color: var(--muted);
    margin-top: 4px;
  }

  /* Charts */
  .chart-card {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 24px;
    margin-bottom: 24px;
  }
  .chart-card h2 {
    font-size: 1.1rem;
    font-weight: 600;
    margin-bottom: 16px;
    color: var(--accent);
  }
  .chart-row {
    display: grid;
    grid-template-columns: 2fr 1fr;
    gap: 24px;
    margin-bottom: 24px;
  }
  @media (max-width: 900px) {
    .chart-row { grid-template-columns: 1fr; }
  }

  /* Tables */
  .table-card {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 24px;
    margin-bottom: 24px;
    overflow-x: auto;
  }
  .table-card h2 {
    font-size: 1.1rem;
    font-weight: 600;
    margin-bottom: 16px;
    color: var(--accent);
  }
  table {
    width: 100%;
    border-collapse: collapse;
    font-size: 0.9rem;
  }
  th {
    text-align: left;
    padding: 10px 12px;
    border-bottom: 2px solid var(--border);
    color: var(--muted);
    font-weight: 600;
    text-transform: uppercase;
    font-size: 0.75rem;
    letter-spacing: 0.5px;
  }
  td {
    padding: 10px 12px;
    border-bottom: 1px solid var(--border);
  }
  tr:hover { background: rgba(56, 189, 248, 0.05); }
  tr.bad { background: rgba(239, 68, 68, 0.1); }
  tr.warn { background: rgba(245, 158, 11, 0.1); }
  .empty { color: var(--muted); font-style: italic; padding: 20px; text-align: center; }

  /* Stats Grid */
  .stats-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));
    gap: 12px;
  }
  .stat-item {
    background: rgba(15, 23, 42, 0.5);
    padding: 14px;
    border-radius: 8px;
    border: 1px solid var(--border);
  }
  .stat-item .stat-label {
    font-size: 0.75rem;
    text-transform: uppercase;
    color: var(--muted);
    letter-spacing: 0.5px;
  }
  .stat-item .stat-value {
    font-size: 1.3rem;
    font-weight: 700;
    margin-top: 4px;
  }

  /* Footer */
  .footer {
    text-align: center;
    padding: 24px;
    color: var(--muted);
    font-size: 0.8rem;
  }
</style>
</head>
<body>
<div class="container">

  <!-- HEADER -->
  <div class="header">
    <h1>Network Connectivity Report</h1>
    <p class="subtitle">Generated by Connectivity Monitor v3.0</p>
    <div class="session-info">
      <span>Started: <strong>$($script:sessionStart.ToString("yyyy-MM-dd HH:mm:ss"))</strong></span>
      <span>Duration: <strong>$(FormatDuration $elapsed)</strong></span>
      <span>ISP: <strong>$($script:ispName)</strong></span>
      <span>Public IP: <strong>$($script:publicIP)</strong></span>
    </div>
  </div>

  <!-- SCORE CARDS -->
  <div class="score-row">
    <div class="score-card">
      <div class="label">Health Score</div>
      <div class="value" style="color: $healthCssColor">$($health.score)/100</div>
      <div class="sub">Grade: $($health.grade)</div>
    </div>
    <div class="score-card">
      <div class="label">Uptime</div>
      <div class="value" style="color: $uptimeCssColor">${up}%</div>
      <div class="sub">$($script:totalSuccess) / $($script:totalPings) pings</div>
    </div>
    <div class="score-card">
      <div class="label">Avg Latency</div>
      <div class="value" style="color: $(if ($avg -lt 30) { '#22c55e' } elseif ($avg -lt 80) { '#f59e0b' } else { '#ef4444' })">${avg}ms</div>
      <div class="sub">Baseline: $(if ($script:baselineLatency) { "$($script:baselineLatency)ms" } else { "N/A" })</div>
    </div>
    <div class="score-card">
      <div class="label">Packet Loss</div>
      <div class="value" style="color: $(if ($loss -eq 0) { '#22c55e' } elseif ($loss -lt 5) { '#f59e0b' } else { '#ef4444' })">${loss}%</div>
      <div class="sub">$($script:totalPings - $script:totalSuccess) packets lost</div>
    </div>
    <div class="score-card">
      <div class="label">Jitter</div>
      <div class="value" style="color: $(if ($jitter -lt 5) { '#22c55e' } elseif ($jitter -lt 15) { '#f59e0b' } else { '#ef4444' })">${jitter}ms</div>
      <div class="sub">Avg variation</div>
    </div>
    <div class="score-card">
      <div class="label">Outages</div>
      <div class="value" style="color: $(if ($script:drops.Count -eq 0) { '#22c55e' } else { '#ef4444' })">$($script:drops.Count)</div>
      <div class="sub">Total: ${totalDowntime}s</div>
    </div>
  </div>

  <!-- DETAILED STATS -->
  <div class="chart-card">
    <h2>Detailed Statistics</h2>
    <div class="stats-grid">
      <div class="stat-item">
        <div class="stat-label">Min Latency</div>
        <div class="stat-value" style="color: var(--green)">${min}ms</div>
      </div>
      <div class="stat-item">
        <div class="stat-label">Max Latency</div>
        <div class="stat-value" style="color: var(--red)">${max}ms</div>
      </div>
      <div class="stat-item">
        <div class="stat-label">P95 Latency</div>
        <div class="stat-value" style="color: var(--yellow)">${p95}ms</div>
      </div>
      <div class="stat-item">
        <div class="stat-label">P99 Latency</div>
        <div class="stat-value" style="color: var(--yellow)">${p99}ms</div>
      </div>
      <div class="stat-item">
        <div class="stat-label">Longest Drop</div>
        <div class="stat-value" style="color: var(--red)">${longestDrop}s</div>
      </div>
      <div class="stat-item">
        <div class="stat-label">Total Pings</div>
        <div class="stat-value">$($script:totalPings)</div>
      </div>
    </div>
  </div>

  <!-- CHARTS -->
  <div class="chart-row">
    <div class="chart-card">
      <h2>Latency Over Time</h2>
      <canvas id="latencyChart" height="100"></canvas>
    </div>
    <div class="chart-card">
      <h2>Latency Distribution</h2>
      <canvas id="histChart" height="100"></canvas>
    </div>
  </div>

  <!-- PER-TARGET TABLE -->
  <div class="table-card">
    <h2>Per-Target Breakdown</h2>
    <table>
      <thead><tr><th>Target</th><th>Sent</th><th>OK</th><th>Loss</th><th>Avg</th><th>Min</th><th>Max</th></tr></thead>
      <tbody>
        $targetRows
      </tbody>
    </table>
  </div>

  <!-- OUTAGES TABLE -->
  <div class="table-card">
    <h2>Connection Drops</h2>
    $(if ($script:drops.Count -eq 0) {
      '<p class="empty">No connection drops recorded during this session.</p>'
    } else {
      "<table><thead><tr><th>Start</th><th>End</th><th>Duration</th><th>Target</th><th>Diagnosis</th></tr></thead><tbody>$dropRows</tbody></table>"
    })
  </div>

  <!-- HIGH LATENCY TABLE -->
  <div class="table-card">
    <h2>High Latency Events</h2>
    $(if ($script:thresholdBreaches.Count -eq 0) {
      '<p class="empty">No high latency events recorded during this session.</p>'
    } else {
      "<table><thead><tr><th>Start</th><th>End</th><th>Duration</th><th>Avg Latency</th></tr></thead><tbody>$breachRows</tbody></table>"
    })
  </div>

  <div class="footer">
    Report generated on $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") | Connectivity Monitor v3.0
  </div>

</div>

<script>
const ctx1 = document.getElementById('latencyChart').getContext('2d');
new Chart(ctx1, {
  type: 'line',
  data: {
    labels: [$labelsJs],
    datasets: [
      {
        label: 'Latency (ms)',
        data: [$dataJs],
        borderColor: '#38bdf8',
        backgroundColor: 'rgba(56,189,248,0.1)',
        borderWidth: 1.5,
        pointRadius: 0,
        fill: true,
        tension: 0.3,
        spanGaps: false
      },
      {
        label: 'Gateway (ms)',
        data: [$gwJs],
        borderColor: '#818cf8',
        backgroundColor: 'rgba(129,140,248,0.05)',
        borderWidth: 1,
        pointRadius: 0,
        fill: false,
        tension: 0.3,
        spanGaps: false
      }
    ]
  },
  options: {
    responsive: true,
    interaction: { intersect: false, mode: 'index' },
    plugins: {
      legend: { labels: { color: '#94a3b8' } }
    },
    scales: {
      x: {
        ticks: { color: '#64748b', maxTicksLimit: 20, maxRotation: 45 },
        grid: { color: 'rgba(51,65,85,0.5)' }
      },
      y: {
        beginAtZero: true,
        ticks: { color: '#64748b' },
        grid: { color: 'rgba(51,65,85,0.5)' },
        title: { display: true, text: 'ms', color: '#64748b' }
      }
    }
  }
});

const ctx2 = document.getElementById('histChart').getContext('2d');
new Chart(ctx2, {
  type: 'bar',
  data: {
    labels: ['0-10ms','10-25ms','25-50ms','50-100ms','100-200ms','200ms+'],
    datasets: [{
      label: 'Count',
      data: [$histJs],
      backgroundColor: ['#22c55e','#4ade80','#facc15','#f59e0b','#f97316','#ef4444'],
      borderRadius: 6
    }]
  },
  options: {
    responsive: true,
    plugins: {
      legend: { display: false }
    },
    scales: {
      x: { ticks: { color: '#64748b' }, grid: { display: false } },
      y: {
        beginAtZero: true,
        ticks: { color: '#64748b' },
        grid: { color: 'rgba(51,65,85,0.5)' }
      }
    }
  }
});
</script>
</body>
</html>
"@

    $dir = Split-Path $reportFile
    if ($dir -and !(Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }

    $html | Set-Content $reportFile -Encoding UTF8
}
# -------------------------
# SESSION SUMMARY (CONSOLE)
# -------------------------
function ShowSummary {
    $elapsed = (Get-Date) - $script:sessionStart
    $health = GetHealthScore
    Write-Host ""
    Write-Host "+================================================================+" -ForegroundColor Cyan
    Write-Host "|                     SESSION SUMMARY                             |" -ForegroundColor Cyan
    Write-Host "+================================================================+" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ("  Health Score : {0}/100 ({1})" -f $health.score, $health.grade) -ForegroundColor $health.color
    Write-Host ("  Duration     : {0}" -f (FormatDuration $elapsed)) -ForegroundColor White
    Write-Host ("  Total Pings  : {0}" -f $script:totalPings) -ForegroundColor White
    Write-Host ("  Successful   : {0}" -f $script:totalSuccess) -ForegroundColor Green
    Write-Host ("  Failed       : {0}" -f ($script:totalPings - $script:totalSuccess)) -ForegroundColor Red

    $currentLoss = Loss
    Write-Host ("  Packet Loss  : {0}%" -f $currentLoss) -ForegroundColor (LossColor $currentLoss)
    Write-Host ("  Uptime       : {0}%" -f (Uptime)) -ForegroundColor White
    Write-Host ""
    Write-Host ("  Latency  Avg : {0} ms" -f (Avg)) -ForegroundColor White
    Write-Host ("           Min : {0} ms" -f (MinLat)) -ForegroundColor Green
    Write-Host ("           Max : {0} ms" -f (MaxLat)) -ForegroundColor Red
    Write-Host ("           P95 : {0} ms" -f (Percentile 95)) -ForegroundColor Yellow
    Write-Host ("           P99 : {0} ms" -f (Percentile 99)) -ForegroundColor Yellow
    Write-Host ("        Jitter : {0} ms" -f (Jitter)) -ForegroundColor White

    if ($script:baselineLocked) {
        Write-Host ("      Baseline : {0} ms" -f $script:baselineLatency) -ForegroundColor Cyan
    }

    Write-Host ""
    Write-Host ("  ISP          : {0}" -f $script:ispName) -ForegroundColor White
    Write-Host ("  Public IP    : {0}" -f $script:publicIP) -ForegroundColor White
    Write-Host ""

    $dropColor = "Green"
    if ($script:drops.Count -gt 0) { $dropColor = "Red" }
    Write-Host ("  Total Drops  : {0}" -f $script:drops.Count) -ForegroundColor $dropColor

    if ($script:drops.Count -gt 0) {
        $totalDown = ($script:drops | ForEach-Object { [double]$_.Duration } | Measure-Object -Sum).Sum
        $longestDrop = ($script:drops | ForEach-Object { [double]$_.Duration } | Measure-Object -Maximum).Maximum
        Write-Host ("  Total Downtime : {0}s" -f [math]::Round($totalDown, 2)) -ForegroundColor Red
        Write-Host ("  Longest Drop   : {0}s" -f [math]::Round($longestDrop, 2)) -ForegroundColor Red
    }

    Write-Host ("  Latency Breaches : {0}" -f $script:thresholdBreaches.Count) -ForegroundColor DarkYellow
    Write-Host ""

    Write-Host "  Per-Target Summary:" -ForegroundColor Magenta
    foreach ($t in $script:perTarget.Keys) {
        $info = $script:perTarget[$t]
        $tLoss = 0
        if ($info.sent -gt 0) { $tLoss = [math]::Round((1 - $info.ok / $info.sent) * 100, 1) }
        $tAvg = 0; $tMin = 0; $tMax = 0
        if ($info.lats.Count -gt 0) {
            $tAvg = [math]::Round(($info.lats | Measure-Object -Average).Average, 1)
            $tMin = [math]::Round(($info.lats | Measure-Object -Minimum).Minimum, 1)
            $tMax = [math]::Round(($info.lats | Measure-Object -Maximum).Maximum, 1)
        }
        Write-Host ("    {0,-18} Sent:{1,5}  Loss:{2,6}%  Avg:{3,6}ms  Min:{4,6}ms  Max:{5,6}ms" -f $t, $info.sent, $tLoss, $tAvg, $tMin, $tMax) -ForegroundColor White
    }

    Write-Host ""
    Write-Host "=================================================================" -ForegroundColor Cyan
    Write-Host ""
}

# ================================================================
#  STARTUP
# ================================================================

# Try to load saved config
$savedConfig = LoadConfig
$useConfig = $false

if ($null -ne $savedConfig) {
    Write-Host ""
    Write-Host " Found saved configuration." -ForegroundColor Green
    Write-Host ("   Targets   : {0}" -f $savedConfig.targets) -ForegroundColor Gray
    Write-Host ("   Poll      : {0}s" -f $savedConfig.poll) -ForegroundColor Gray
    Write-Host ("   Threshold : {0}" -f $savedConfig.threshold) -ForegroundColor Gray
    $useConfig = PromptYesNo " Use saved config?" "Y"
}

if ($useConfig -and $null -ne $savedConfig) {
    $adapter = Get-NetAdapter -Name $savedConfig.adapter -ErrorAction SilentlyContinue
    if ($null -eq $adapter) {
        Write-Host " Saved adapter not found, selecting manually..." -ForegroundColor Yellow
        $adapter = SelectAdapter
    }
    $poll = [int]$savedConfig.poll
    $threshold = [int]$savedConfig.threshold
    $targets = $savedConfig.targets.Split(",") | ForEach-Object { $_.Trim() }
    $latWarn = [int]$savedConfig.latWarn
    $enableDns = [bool]$savedConfig.enableDns
    $dnsTarget = $savedConfig.dnsTarget
    $enableBeep = [bool]$savedConfig.enableBeep
    $pingLogFile = $savedConfig.pingLogFile
    $dropLogFile = $savedConfig.dropLogFile
    $htmlFile = $savedConfig.htmlFile
}
else {
    $adapter = SelectAdapter
    Write-Host ""
    $poll = [int](PromptDefault " Poll interval (seconds)" "2")
    $threshold = [int](PromptDefault " Failure threshold for drop" "4")
    $targetsRaw = PromptDefault " Ping targets (comma-sep)" "1.1.1.1,8.8.8.8,208.67.222.222"
    $targets = $targetsRaw.Split(",") | ForEach-Object { $_.Trim() }
    $latWarn = [int](PromptDefault " Latency warning (ms)" "100")
    $enableDns = PromptYesNo " Enable DNS health check?" "Y"
    $dnsTarget = ""
    if ($enableDns) { $dnsTarget = PromptDefault " DNS test hostname" "google.com" }
    $enableBeep = PromptYesNo " Audible alert on drop?" "N"

    $defaultPingLog = Join-Path (Get-Location) "ping_log.csv"
    $defaultDropLog = Join-Path (Get-Location) "drops.csv"
    $defaultHtml = Join-Path (Get-Location) "network_report.html"
    $pingLogFile = PromptDefault " Ping log CSV" $defaultPingLog
    $dropLogFile = PromptDefault " Drop log CSV" $defaultDropLog
    $htmlFile = PromptDefault " HTML report file" $defaultHtml

    # Save config for next time
    $configToSave = @{
        adapter     = $adapter.Name
        poll        = $poll
        threshold   = $threshold
        targets     = ($targets -join ",")
        latWarn     = $latWarn
        enableDns   = $enableDns
        dnsTarget   = $dnsTarget
        enableBeep  = $enableBeep
        pingLogFile = $pingLogFile
        dropLogFile = $dropLogFile
        htmlFile    = $htmlFile
    }
    SaveConfig $configToSave
    Write-Host " Config saved to $($script:configPath)" -ForegroundColor DarkGray
}

$winWidth = $Host.UI.RawUI.WindowSize.Width
$script:graphWidth = $winWidth - 20
if ($script:graphWidth -gt 60) { $script:graphWidth = 60 }
if ($script:graphWidth -lt 20) { $script:graphWidth = 20 }

# Detect public IP in background
Write-Host " Detecting public IP..." -ForegroundColor DarkGray
DetectPublicIP

Clear-Host
$rr = 0
$script:lastDiagnosis = @{ msg = "Initializing..."; color = "DarkGray" }

# ================================================================
#  MAIN LOOP
# ================================================================

Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress -Action {
    $script:shutdown = $true
    $_.Cancel = $true
} | Out-Null

while (-not $script:shutdown) {

    # Handle hotkeys (non-blocking)
    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            "P" { $script:paused = -not $script:paused }
            "R" {
                $script:history.Clear()
                $script:drops.Clear()
                $script:perTarget.Clear()
                $script:gwHistory.Clear()
                $script:thresholdBreaches.Clear()
                $script:failCount = 0
                $script:isDown = $false
                $script:totalPings = 0
                $script:totalSuccess = 0
                $script:sessionStart = Get-Date
                $script:baselineSamples.Clear()
                $script:baselineLatency = $null
                $script:baselineLocked = $false
            }
            "Q" { $script:shutdown = $true; continue }
            "E" {
                # Snapshot HTML export
                $snapFile = Join-Path (Get-Location) ("snapshot_{0}.html" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
                GenerateHtmlReport $snapFile
            }
        }
    }

    if ($script:paused) {
        $consoleWidth = $Host.UI.RawUI.WindowSize.Width
        $frame = BuildFrame $a $gw $localIP $target $p $gwPing $dnsResult $latWarn $enableDns $wifiSig $script:lastDiagnosis
        RenderFrame $frame $consoleWidth
        Start-Sleep -Milliseconds 500
        continue
    }

    $a = Get-NetAdapter -Name $adapter.Name
    $gw = Gateway $a.Name
    $localIP = GetLocalIP $a.Name
    $target = $targets[$rr % $targets.Count]
    $rr++

    # Ping target
    if ($a.Status -ne "Up") {
        $p = @{ ok = $false; lat = $null; target = $target; time = Get-Date }
        UpdateHistory $null $target
    }
    else {
        $p = PingTest $target
        if ($p.ok) { UpdateHistory $p.lat $target }
        else { UpdateHistory $null $target }
    }

    # Ping gateway
    $gwPing = @{ ok = $false; lat = $null }
    if ($a.Status -eq "Up" -and $gw -ne "N/A" -and $gw -ne "None") {
        $gwPing = PingTest $gw
        if ($gwPing.ok) {
            UpdateGwHistory $gwPing.lat
        }
        else {
            UpdateGwHistory $null
        }
    }

    # DNS
    $dnsResult = @{ ok = $true; ms = $null }
    if ($enableDns -and $a.Status -eq "Up") {
        $dnsResult = DnsTest $dnsTarget
    }

    # WiFi signal (only check every 5th iteration to reduce overhead)
    $wifiSig = $null
    if ($rr % 5 -eq 0) {
        $wifiSig = GetWifiSignal
    }

    # Diagnose
    $script:lastDiagnosis = DiagnoseIssue $gwPing $p

    # Log every ping
    LogPing $p $gwPing $dnsResult $wifiSig $pingLogFile

    # Outage detection
    if (!$p.ok) {
        $script:failCount++
        if ($script:failCount -ge $threshold -and !$script:isDown) {
            $script:isDown = $true
            $script:downStart = Get-Date
            if ($enableBeep) { [Console]::Beep(1000, 300) }
        }
    }
    else {
        if ($script:isDown) {
            $end = Get-Date
            LogDrop $script:downStart $end $target $script:lastDiagnosis.msg $dropLogFile
            $script:isDown = $false
            if ($enableBeep) {
                [Console]::Beep(600, 150)
                [Console]::Beep(800, 150)
            }
        }
        $script:failCount = 0
    }

    # High latency threshold breach tracking
    if ($p.ok -and $null -ne $p.lat -and $p.lat -ge $latWarn) {
        if (-not $script:breachActive) {
            $script:breachActive = $true
            $script:breachStart = Get-Date
        }
        if ($enableBeep) { [Console]::Beep(500, 100) }
    }
    else {
        if ($script:breachActive) {
            $breachEnd = Get-Date
            $breachAvg = Avg
            LogThresholdBreach $script:breachStart $breachEnd $breachAvg $pingLogFile
            $script:breachActive = $false
        }
    }

    # Re-detect public IP every 100 pings (in case it changes)
    if ($script:totalPings % 100 -eq 0 -and $script:totalPings -gt 0) {
        DetectPublicIP
    }

    # Auto-generate HTML report every 500 pings
    if ($script:totalPings % 500 -eq 0 -and $script:totalPings -gt 0) {
        GenerateHtmlReport $htmlFile
    }

    # Render
    $consoleWidth = $Host.UI.RawUI.WindowSize.Width
    $frame = BuildFrame $a $gw $localIP $target $p $gwPing $dnsResult $latWarn $enableDns $wifiSig $script:lastDiagnosis
    RenderFrame $frame $consoleWidth

    Start-Sleep $poll
}

# ================================================================
#  SHUTDOWN
# ================================================================

if ($script:isDown) {
    $end = Get-Date
    LogDrop $script:downStart $end "N/A" "Session ended during outage" $dropLogFile
}

if ($script:breachActive) {
    $breachEnd = Get-Date
    LogThresholdBreach $script:breachStart $breachEnd (Avg) $pingLogFile
}

# Generate final HTML report
Clear-Host
Write-Host " Generating HTML report..." -ForegroundColor Cyan
GenerateHtmlReport $htmlFile

ShowSummary

Write-Host " Logs saved to:" -ForegroundColor Gray
Write-Host ("   Ping log   : {0}" -f $pingLogFile) -ForegroundColor White
Write-Host ("   Drop log   : {0}" -f $dropLogFile) -ForegroundColor White
Write-Host ("   HTML report : {0}" -f $htmlFile) -ForegroundColor White
Write-Host ("   Config      : {0}" -f $script:configPath) -ForegroundColor White

$breachFile = $pingLogFile -replace "\.csv$", "_breaches.csv"
if (Test-Path $breachFile) {
    Write-Host ("   Breaches    : {0}" -f $breachFile) -ForegroundColor White
}

Write-Host ""

# Ask to open HTML report
$openReport = PromptYesNo " Open HTML report in browser?" "Y"
if ($openReport) {
    Start-Process $htmlFile
}

Write-Host ""
Write-Host " Monitor stopped." -ForegroundColor Cyan
[Console]::CursorVisible = $true