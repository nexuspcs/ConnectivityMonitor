Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ================================================================
#  CONNECTIVITY MONITOR v4.0
#  Tab-based dashboard | Dual-pane | Smart analysis
#  HTML & CSV reporting | Daily log rotation
#  Flicker-free rendering | ASCII-only display
#  JAMES COATES and Claude Opus 4.6
# ================================================================

# ================================================================
#  GLOBAL STATE
# ================================================================
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
$script:activeTab = 1
$script:traceroutes = [System.Collections.Generic.List[PSObject]]::new()
$script:hourlyData = @{}
$script:currentDate = (Get-Date).ToString("yyyy-MM-dd")
$script:lastDiagnosis = @{ msg = "Initializing..."; color = "DarkGray" }
$script:lastTraceTime = [datetime]::MinValue
$script:traceJob = $null

[Console]::CursorVisible = $false

# Ensure cursor is restored if script terminates unexpectedly
trap {
    [Console]::CursorVisible = $true
}

# ================================================================
#  WORKING DIRECTORY SETUP
# ================================================================
$script:baseDir = Join-Path $env:USERPROFILE "ConnectivityMonitor"
$script:logsDir = Join-Path $script:baseDir "logs"
$script:reportsDir = Join-Path $script:baseDir "reports"

foreach ($dir in @($script:baseDir, $script:logsDir, $script:reportsDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$script:configPath = Join-Path $script:baseDir "monitor_config.json"

# ================================================================
#  DAILY LOG FILE PATHS
# ================================================================
$script:pingLogFile = ""
$script:dropLogFile = ""
$script:breachLogFile = ""

function GetDailyLogPaths {
    $date = (Get-Date).ToString("yyyy-MM-dd")
    $script:currentDate = $date
    $script:pingLogFile = Join-Path $script:logsDir ("ping_log_{0}.csv" -f $date)
    $script:dropLogFile = Join-Path $script:logsDir ("drops_{0}.csv" -f $date)
    $script:breachLogFile = Join-Path $script:logsDir ("breaches_{0}.csv" -f $date)
}

function CheckDateRoll {
    $today = (Get-Date).ToString("yyyy-MM-dd")
    if ($today -ne $script:currentDate) {
        GetDailyLogPaths
    }
}

GetDailyLogPaths

# ================================================================
#  CONFIG FILE
# ================================================================
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

# ================================================================
#  PROMPT HELPERS
# ================================================================
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

# ================================================================
#  ADAPTER SELECTION
# ================================================================
function SelectAdapter {
    $adapters = Get-NetAdapter -Physical | Where-Object Status -ne "Not Present"
    Write-Host ""
    Write-Host "+================================================+" -ForegroundColor Cyan
    Write-Host "|       CONNECTIVITY MONITOR v4.0                |" -ForegroundColor Cyan
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
    return $adapters[$n - 1]
}

# ================================================================
#  NETWORK TESTS
# ================================================================
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

function StartTraceroute($target) {
    if ($null -ne $script:traceJob) { return }
    $now = Get-Date
    if (($now - $script:lastTraceTime).TotalSeconds -lt 60) { return }
    $script:lastTraceTime = $now
    $script:traceJob = Start-Job -ScriptBlock {
        param($t)
        $output = cmd /c "tracert -d -w 500 -h 10 $t" 2>&1
        return $output
    } -ArgumentList $target
}

function CollectTraceroute($target) {
    if ($null -eq $script:traceJob) { return }
    $jobState = $script:traceJob.State
    if ($jobState -eq "Completed" -or $jobState -eq "Failed") {
        $hops = [System.Collections.Generic.List[PSObject]]::new()
        if ($jobState -eq "Completed") {
            $raw = @(Receive-Job $script:traceJob)
            foreach ($rawLine in $raw) {
                $lineStr = "$rawLine".Trim()
                if ($lineStr -match "^\d") {
                    $parts = $lineStr -split "\s+" | Where-Object { $_ -ne "" }
                    $hopNum = $parts[0]
                    $hopIP = "*"
                    $hopLat = "*"
                    foreach ($p in $parts) {
                        if ($p -match "^\d+\.\d+\.\d+\.\d+$") {
                            $hopIP = $p
                        }
                    }
                    for ($pi = 1; $pi -lt $parts.Count; $pi++) {
                        if ($parts[$pi] -match "^\d+$" -or $parts[$pi] -match "^<\d+$") {
                            $hopLat = $parts[$pi] + "ms"
                            break
                        }
                    }
                    $hops.Add([PSCustomObject]@{
                        Hop = $hopNum
                        IP = $hopIP
                        Latency = $hopLat
                    })
                }
            }
        }
        Remove-Job $script:traceJob -Force
        $script:traceJob = $null

        $entry = [PSCustomObject]@{
            Target = $target
            Time = (Get-Date).ToString("HH:mm:ss")
            Hops = $hops
        }
        $script:traceroutes.Add($entry)
        while ($script:traceroutes.Count -gt 3) {
            $script:traceroutes.RemoveAt(0)
        }
    }
}

# ================================================================
#  METRICS ENGINE
# ================================================================
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
        $script:perTarget[$target] = @{
            sent = 0
            ok = 0
            lats = [System.Collections.Generic.List[double]]::new()
        }
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

function UpdateHourlyData($lat) {
    if ($null -eq $lat) { return }
    $hour = (Get-Date).Hour
    if (-not $script:hourlyData.ContainsKey($hour)) {
        $script:hourlyData[$hour] = [System.Collections.Generic.List[double]]::new()
    }
    $script:hourlyData[$hour].Add($lat)
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

# ================================================================
#  TREND DETECTION
# ================================================================
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

    $score -= ($loss * 3)
    if ($avg -gt 100) { $score -= 20 }
    elseif ($avg -gt 50) { $score -= 10 }
    elseif ($avg -gt 30) { $score -= 5 }
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
    if (-not $gwPing.ok -and -not $extPing.ok) { return @{ msg = "Local network down (gateway unreachable)"; color = "Red" } }
    if ($gwPing.ok -and -not $extPing.ok) { return @{ msg = "ISP / upstream issue (gateway OK, internet down)"; color = "Yellow" } }
    return @{ msg = "Unusual state"; color = "DarkYellow" }
}

function GetNetworkWeather {
    $health = GetHealthScore
    $s = $health.score
    if ($s -gt 90) {
        return @{ label = "SUNNY"; icon = " \  |  / "; icon2 = "  (  .  )  "; icon3 = " /  |  \ "; color = "Green" }
    }
    elseif ($s -gt 75) {
        return @{ label = "PARTLY CLOUDY"; icon = "    .-~~-.  "; icon2 = " .-(      )-."; icon3 = "(____________)"; color = "Cyan" }
    }
    elseif ($s -gt 50) {
        return @{ label = "CLOUDY"; icon = "   .------. "; icon2 = " .(        )."; icon3 = "(___________)"; color = "Gray" }
    }
    elseif ($s -gt 25) {
        return @{ label = "STORMY"; icon = "   .------. "; icon2 = " .(        )."; icon3 = "(___________) '; ' "; color = "DarkYellow" }
    }
    else {
        return @{ label = "HURRICANE"; icon = "   .======. "; icon2 = " .(########)."; icon3 = "(###########) X X X"; color = "Red" }
    }
}

# ================================================================
#  ASCII ART DEFINITIONS
# ================================================================
function GetOnlineArt {
    $lines = @()
    $lines += "  ___        _ _            "
    $lines += " / _ \ _ __ | (_)_ __   ___ "
    $lines += "| | | | '_ \| | | '_ \ / _ \"
    $lines += "| |_| | | | | | | | | |  __/"
    $lines += " \___/|_| |_|_|_|_| |_|\___|"
    return $lines
}

function GetOfflineArt {
    $lines = @()
    $lines += "  ___   __  __ _ _            "
    $lines += " / _ \ / _|/ _| (_)_ __   ___ "
    $lines += "| | | | |_| |_| | | '_ \ / _ \"
    $lines += "| |_| |  _|  _| | | | | |  __/"
    $lines += " \___/|_| |_| |_|_|_| |_|\___|"
    return $lines
}

# ================================================================
#  COLOR HELPERS
# ================================================================
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

# ================================================================
#  GRAPH BUILDERS
# ================================================================
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
    $lines += "       Legend: . <10  o <50  O <100  @ >100  X drop"
    return $lines
}

function BuildSparkline {
    $vals = @($script:history | Select-Object -Last 50 | ForEach-Object { $_.Latency })
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

function BuildUptimeTimeline {
    $vals = @($script:history | Select-Object -Last 60 | ForEach-Object { $_.Latency })
    if ($vals.Count -eq 0) { return "" }
    $bar = ""
    foreach ($v in $vals) {
        if ($null -eq $v) { $bar += "X" }
        elseif ($v -gt 100) { $bar += "!" }
        elseif ($v -gt 50) { $bar += "~" }
        else { $bar += "-" }
    }
    return $bar
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
    $barMax = 20

    $lines = @()
    $lines += "  Latency Distribution:"
    for ($b = 0; $b -lt $bucketNames.Count; $b++) {
        $count = $bucketCounts[$b]
        $barLen = [math]::Round(($count / $maxCount) * $barMax)
        $bar = "=" * $barLen
        $pct = [math]::Round(($count / $vals.Count) * 100, 0)
        $lines += ("  {0} |{1,-20} {2,4} ({3}%)" -f $bucketNames[$b], $bar, $count, $pct)
    }
    return $lines
}

function BuildHeatmap {
    $lines = @()
    $lines += "  Time-of-Day Latency Heatmap (today):"
    $lines += ""

    # Build hour labels
    $hourLabels = "  Hour: "
    for ($h = 0; $h -lt 24; $h++) {
        $hourLabels += ("{0,3}" -f $h)
    }
    $lines += $hourLabels

    # Build heatmap row
    $heatRow = "        "
    for ($h = 0; $h -lt 24; $h++) {
        if ($script:hourlyData.ContainsKey($h) -and $script:hourlyData[$h].Count -gt 0) {
            $havg = ($script:hourlyData[$h] | Measure-Object -Average).Average
            if ($havg -lt 10) { $ch = "." }
            elseif ($havg -lt 30) { $ch = "o" }
            elseif ($havg -lt 60) { $ch = "O" }
            elseif ($havg -lt 100) { $ch = "@" }
            else { $ch = "#" }
            $heatRow += ("  " + $ch)
        }
        else {
            $heatRow += "  -"
        }
    }
    $lines += $heatRow
    $lines += ""
    $lines += "  Legend: - none  . <10ms  o <30ms  O <60ms  @ <100ms  # >100ms"
    $lines += ""

    # Hourly detail
    $lines += ("  {0,-6} {1,-8} {2,-8} {3,-8} {4,-6} {5}" -f "Hour", "Avg", "Min", "Max", "Count", "Bar")
    $lines += ("  {0} {1} {2} {3} {4} {5}" -f "------", "--------", "--------", "--------", "------", "--------------------")

    for ($h = 0; $h -lt 24; $h++) {
        if ($script:hourlyData.ContainsKey($h) -and $script:hourlyData[$h].Count -gt 0) {
            $hdata = $script:hourlyData[$h]
            $havg = [math]::Round(($hdata | Measure-Object -Average).Average, 1)
            $hmin = [math]::Round(($hdata | Measure-Object -Minimum).Minimum, 1)
            $hmax = [math]::Round(($hdata | Measure-Object -Maximum).Maximum, 1)
            $hcount = $hdata.Count

            $allCounts = @()
            foreach ($hk in $script:hourlyData.Keys) {
                $allCounts += $script:hourlyData[$hk].Count
            }
            $maxCnt = 1
            if ($allCounts.Count -gt 0) {
                $maxCnt = ($allCounts | Measure-Object -Maximum).Maximum
                if ($maxCnt -eq 0) { $maxCnt = 1 }
            }
            $barLen = [math]::Round(($hcount / $maxCnt) * 20)
            $bar = "=" * $barLen

            $lines += ("  {0,-6} {1,-8} {2,-8} {3,-8} {4,-6} {5}" -f ("{0:D2}:00" -f $h), ("{0}ms" -f $havg), ("{0}ms" -f $hmin), ("{0}ms" -f $hmax), $hcount, $bar)
        }
    }

    return $lines
}

# ================================================================
#  RENDERER (supports simple lines and multi-segment lines)
# ================================================================
function RenderFrame($frameLines, $consoleWidth) {
    [Console]::SetCursorPosition(0, 0)

    foreach ($fl in $frameLines) {
        if ($fl.ContainsKey("Segments")) {
            $totalLen = 0
            foreach ($seg in $fl.Segments) {
                Write-Host $seg.Text -ForegroundColor $seg.Color -NoNewline
                $totalLen += $seg.Text.Length
            }
            $pad = $consoleWidth - $totalLen
            if ($pad -gt 0) { Write-Host (" " * $pad) }
            else { Write-Host "" }
        }
        else {
            $text = $fl.Text
            $color = $fl.Color
            $padLen = $consoleWidth - $text.Length
            if ($padLen -lt 0) { $padLen = 0 }
            $padded = $text + (" " * $padLen)
            Write-Host $padded -ForegroundColor $color -NoNewline
            Write-Host ""
        }
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
#  TAB BAR
# ================================================================
function BuildTabBar {
    $tabNames = @("Overview", "Graph", "Drops", "Targets", "Heatmap")
    $bar = "  "
    for ($t = 0; $t -lt $tabNames.Count; $t++) {
        $num = $t + 1
        if ($num -eq $script:activeTab) {
            $bar += "[{0}:{1}]  " -f $num, $tabNames[$t]
        }
        else {
            $bar += " {0}:{1}   " -f $num, $tabNames[$t]
        }
    }
    return $bar
}

# ================================================================
#  TAB 1: OVERVIEW (DUAL-PANE)
# ================================================================
function BuildTab1Left($adapter, $gw, $localIP, $target, $ping, $gwPing, $dnsResult, $latWarn, $enableDns, $wifiSig, $diagnosis, $leftWidth) {
    $left = [System.Collections.Generic.List[hashtable]]::new()

    function AddLeft($text, $color) {
        if ($text.Length -gt $leftWidth) {
            $text = $text.Substring(0, $leftWidth)
        }
        $left.Add(@{ Text = $text; Color = $color })
    }

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
    $weather = GetNetworkWeather

    # Header
    $headerTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    AddLeft ("+-- CONNECTIVITY MONITOR v4.0 -- {0} --+" -f $headerTime) "Cyan"

    # ASCII art
    if ($ping.ok) {
        $artLines = GetOnlineArt
        foreach ($al in $artLines) { AddLeft ("  " + $al) "Green" }
    }
    else {
        $artLines = GetOfflineArt
        foreach ($al in $artLines) { AddLeft ("  " + $al) "Red" }
    }

    # Sparkline
    $spark = BuildSparkline
    if ($spark.Length -gt 0) {
        AddLeft ("  Spark: " + $spark) "DarkCyan"
    }

    # Uptime timeline
    $timeline = BuildUptimeTimeline
    if ($timeline.Length -gt 0) {
        AddLeft ("  Up:    " + $timeline) "DarkGray"
    }
    AddLeft "" "White"

    # Connection info
    AddLeft ("  Adapter  : {0}" -f $adapter.Name) "White"
    AddLeft ("  Local IP : {0}" -f $localIP) "White"
    AddLeft ("  Gateway  : {0}" -f $gw) "White"
    AddLeft ("  Public   : {0}  ({1})" -f $script:publicIP, $script:ispName) "White"
    AddLeft ("  Target   : {0}" -f $target) "Yellow"
    AddLeft ("  Session  : {0}" -f (FormatDuration $elapsed)) "White"

    if ($null -ne $wifiSig) {
        $wifiColor = "Green"
        if ($wifiSig -lt 40) { $wifiColor = "Red" }
        elseif ($wifiSig -lt 70) { $wifiColor = "Yellow" }
        AddLeft ("  WiFi     : {0}%" -f $wifiSig) $wifiColor
    }

    if ($script:baselineLocked) {
        AddLeft ("  Baseline : {0} ms (learned)" -f $script:baselineLatency) "DarkCyan"
    }
    else {
        $remaining = 30 - $script:baselineSamples.Count
        AddLeft ("  Baseline : learning... ({0} more)" -f $remaining) "DarkGray"
    }
    AddLeft "" "White"

    # Status panel
    AddLeft "  +--- Status ----------------------------+" "DarkGray"

    $linkStr = "[DOWN]"
    if ($adapter.Status -eq "Up") { $linkStr = "[UP]  " }
    $inet = "DOWN"
    if ($adapter.Status -eq "Up") {
        if ($ping.ok) { $inet = "OK" }
        else { $inet = "FAIL" }
    }

    $gwStr = ""
    if ($null -ne $gwPing) {
        if ($gwPing.ok) { $gwStr = "  GW:OK({0}ms)" -f $gwPing.lat }
        else { $gwStr = "  GW:FAIL" }
    }

    $dnsStr = ""
    if ($enableDns) {
        if ($dnsResult.ok) { $dnsStr = "  DNS:OK({0}ms)" -f $dnsResult.ms }
        else { $dnsStr = "  DNS:FAIL" }
    }

    $statusColor = "Green"
    if ($adapter.Status -ne "Up" -or -not $ping.ok) { $statusColor = "Red" }
    AddLeft ("  |  Link:{0} Net:{1}{2}{3}" -f $linkStr, $inet, $gwStr, $dnsStr) $statusColor

    # Current latency
    if ($null -ne $ping.lat) {
        $latStr = "{0} ms" -f $ping.lat
        if ($ping.lat -ge $latWarn) { $latStr += " !! HIGH" }
    }
    else { $latStr = "--" }
    $lc = LatencyColor $ping.lat
    AddLeft ("  |  Latency: {0}" -f $latStr) $lc
    AddLeft "  +---------------------------------------+" "DarkGray"
    AddLeft "" "White"

    # Network weather
    AddLeft ("  Weather: {0}" -f $weather.label) $weather.color
    AddLeft ("    {0}" -f $weather.icon) $weather.color
    AddLeft ("    {0}" -f $weather.icon2) $weather.color
    AddLeft ("    {0}" -f $weather.icon3) $weather.color
    AddLeft "" "White"

    # Health score
    AddLeft ("  Health: {0}/100  Grade: {1}  Trend: {2} {3}" -f $health.score, $health.grade, $trend.arrow, $trend.label) $health.color

    # Diagnosis
    if ($null -ne $diagnosis) {
        AddLeft ("  Diagnosis: {0}" -f $diagnosis.msg) $diagnosis.color
    }

    if ($script:paused) {
        AddLeft "  ** PAUSED ** (press P to resume)" "Yellow"
    }
    AddLeft "" "White"

    # Stats
    AddLeft "  +--- Stats -----------------------------+" "DarkGray"
    AddLeft ("  |  Loss   : {0}%" -f $loss) (LossColor $loss)
    AddLeft ("  |  Avg    : {0} ms" -f $avg) "White"
    AddLeft ("  |  Min    : {0} ms" -f $min) "Green"
    AddLeft ("  |  Max    : {0} ms" -f $max) "Red"
    AddLeft ("  |  P95    : {0} ms" -f $p95) "Yellow"
    AddLeft ("  |  Jitter : {0} ms" -f $jitter) "White"
    AddLeft ("  |  Uptime : {0}%" -f $up) "White"
    AddLeft "  +---------------------------------------+" "DarkGray"

    return $left
}

function BuildTab1Right($leftWidth) {
    $right = [System.Collections.Generic.List[hashtable]]::new()
    $rightWidth = 32

    function AddRight($text, $color) {
        if ($text.Length -gt $rightWidth) {
            $text = $text.Substring(0, $rightWidth)
        }
        $right.Add(@{ Text = $text; Color = $color })
    }

    # Compact latency graph (28 wide, 6 tall)
    $graphLines = BuildLatencyGraph 28 6
    foreach ($gl in $graphLines) {
        $graphColor = "DarkGray"
        if ($gl.Contains("X")) { $graphColor = "Yellow" }
        elseif ($gl.Contains("@")) { $graphColor = "Red" }
        elseif ($gl.Contains("O")) { $graphColor = "DarkYellow" }
        elseif ($gl.Contains("o")) { $graphColor = "Cyan" }
        elseif ($gl.Contains(".")) { $graphColor = "Green" }
        AddRight $gl $graphColor
    }
    AddRight "" "White"

    # Compact histogram
    $histLines = BuildHistogram
    foreach ($hl in $histLines) {
        AddRight $hl "DarkCyan"
    }
    AddRight "" "White"

    # Recent drops (last 8)
    AddRight " Recent Drops:" "Yellow"
    if ($script:drops.Count -eq 0) {
        AddRight "   (none)" "DarkGray"
    }
    else {
        $recentDrops = @($script:drops | Select-Object -Last 8)
        foreach ($d in $recentDrops) {
            $dropTime = $d.Start
            if ($dropTime.Length -gt 19) {
                $dropTime = $dropTime.Substring(11, 8)
            }
            $durVal = [double]$d.Duration
            $dColor = "White"
            if ($durVal -ge 30) { $dColor = "Red" }
            elseif ($durVal -ge 10) { $dColor = "Yellow" }
            AddRight ("  {0} {1}s {2}" -f $dropTime, $d.Duration, $d.Diagnosis) $dColor
        }
    }
    AddRight "" "White"

    # Per-target health
    AddRight " Per-Target:" "Magenta"
    foreach ($t in $script:perTarget.Keys) {
        $info = $script:perTarget[$t]
        $tLoss = 0
        if ($info.sent -gt 0) { $tLoss = [math]::Round((1 - $info.ok / $info.sent) * 100, 1) }
        $tAvg = 0
        if ($info.lats.Count -gt 0) { $tAvg = [math]::Round(($info.lats | Measure-Object -Average).Average, 1) }
        $tColor = "White"
        if ($tLoss -gt 0) { $tColor = "Yellow" }
        if ($tLoss -ge 5) { $tColor = "Red" }
        $shortTarget = $t
        if ($shortTarget.Length -gt 15) { $shortTarget = $shortTarget.Substring(0, 15) }
        AddRight ("  {0,-15} L:{1}% A:{2}ms" -f $shortTarget, $tLoss, $tAvg) $tColor
    }

    return $right
}

function MergeDualPane($leftLines, $rightLines, $leftWidth, $consoleWidth) {
    $sep = " | "
    $rightWidth = $consoleWidth - $leftWidth - $sep.Length
    if ($rightWidth -lt 10) { $rightWidth = 10 }

    $maxLines = $leftLines.Count
    if ($rightLines.Count -gt $maxLines) { $maxLines = $rightLines.Count }

    $merged = [System.Collections.Generic.List[hashtable]]::new()

    for ($i = 0; $i -lt $maxLines; $i++) {
        $lText = ""
        $lColor = "White"
        if ($i -lt $leftLines.Count) {
            $lText = $leftLines[$i].Text
            $lColor = $leftLines[$i].Color
        }
        # Pad left to exact width
        if ($lText.Length -gt $leftWidth) {
            $lText = $lText.Substring(0, $leftWidth)
        }
        elseif ($lText.Length -lt $leftWidth) {
            $lText = $lText + (" " * ($leftWidth - $lText.Length))
        }

        $rText = ""
        $rColor = "White"
        if ($i -lt $rightLines.Count) {
            $rText = $rightLines[$i].Text
            $rColor = $rightLines[$i].Color
        }
        if ($rText.Length -gt $rightWidth) {
            $rText = $rText.Substring(0, $rightWidth)
        }

        $segs = [System.Collections.Generic.List[hashtable]]::new()
        $segs.Add(@{ Text = $lText; Color = $lColor })
        $segs.Add(@{ Text = $sep; Color = "DarkGray" })
        $segs.Add(@{ Text = $rText; Color = $rColor })
        $merged.Add(@{ Segments = $segs })
    }

    return $merged
}

# ================================================================
#  TAB 2: FULL GRAPH
# ================================================================
function BuildTab2 {
    $frame = [System.Collections.Generic.List[hashtable]]::new()

    function Add2($text, $color) {
        $frame.Add(@{ Text = $text; Color = $color })
    }

    Add2 "" "White"
    Add2 "  === FULL LATENCY GRAPH ===" "Cyan"
    Add2 "" "White"

    $consW = 80
    try { $consW = $Host.UI.RawUI.WindowSize.Width } catch {}
    $graphW = $consW - 20
    if ($graphW -gt 100) { $graphW = 100 }
    if ($graphW -lt 20) { $graphW = 20 }

    $graphLines = BuildLatencyGraph $graphW 12
    foreach ($gl in $graphLines) {
        $graphColor = "DarkGray"
        if ($gl.Contains("X")) { $graphColor = "Yellow" }
        elseif ($gl.Contains("@")) { $graphColor = "Red" }
        elseif ($gl.Contains("O")) { $graphColor = "DarkYellow" }
        elseif ($gl.Contains("o")) { $graphColor = "Cyan" }
        elseif ($gl.Contains(".")) { $graphColor = "Green" }
        Add2 $gl $graphColor
    }
    Add2 "" "White"

    # Full uptime timeline
    $vals = @($script:history | Select-Object -Last 100 | ForEach-Object { $_.Latency })
    if ($vals.Count -gt 0) {
        $bar = ""
        foreach ($v in $vals) {
            if ($null -eq $v) { $bar += "X" }
            elseif ($v -gt 100) { $bar += "!" }
            elseif ($v -gt 50) { $bar += "~" }
            else { $bar += "-" }
        }
        Add2 ("  Uptime:  " + $bar) "DarkGray"
        Add2 "  Legend:  - OK  ~ >50ms  ! >100ms  X drop" "DarkGray"
    }
    Add2 "" "White"

    # Full histogram
    $histLines = BuildHistogram
    foreach ($hl in $histLines) {
        Add2 $hl "DarkCyan"
    }

    return $frame
}

# ================================================================
#  TAB 3: DROPS & TRACEROUTES
# ================================================================
function BuildTab3 {
    $frame = [System.Collections.Generic.List[hashtable]]::new()

    function Add3($text, $color) {
        $frame.Add(@{ Text = $text; Color = $color })
    }

    Add3 "" "White"
    Add3 "  === DROP HISTORY ===" "Yellow"
    Add3 "" "White"

    if ($script:drops.Count -eq 0) {
        Add3 "    (no drops recorded)" "DarkGray"
    }
    else {
        Add3 ("    {0,-22} {1,-22} {2,-10} {3,-18} {4}" -f "Start", "End", "Duration", "Target", "Diagnosis") "DarkYellow"
        Add3 ("    {0} {1} {2} {3} {4}" -f ("-" * 22), ("-" * 22), ("-" * 10), ("-" * 18), ("-" * 20)) "DarkGray"
        $recentDrops = @($script:drops | Select-Object -Last 20)
        foreach ($d in $recentDrops) {
            $durVal = [double]$d.Duration
            $dColor = "White"
            if ($durVal -ge 30) { $dColor = "Red" }
            elseif ($durVal -ge 10) { $dColor = "Yellow" }
            Add3 ("    {0,-22} {1,-22} {2,-10} {3,-18} {4}" -f $d.Start, $d.End, ("{0}s" -f $d.Duration), $d.Target, $d.Diagnosis) $dColor
        }
    }

    Add3 "" "White"
    Add3 "  === HIGH LATENCY BREACHES ===" "DarkYellow"
    Add3 "" "White"

    if ($script:thresholdBreaches.Count -eq 0) {
        Add3 "    (no breaches recorded)" "DarkGray"
    }
    else {
        Add3 ("    {0,-22} {1,-22} {2,-10} {3}" -f "Start", "End", "Duration", "Avg Latency") "DarkYellow"
        Add3 ("    {0} {1} {2} {3}" -f ("-" * 22), ("-" * 22), ("-" * 10), ("-" * 12)) "DarkGray"
        foreach ($b in ($script:thresholdBreaches | Select-Object -Last 15)) {
            Add3 ("    {0,-22} {1,-22} {2,-10} {3}ms" -f $b.Start, $b.End, ("{0}s" -f $b.Duration), $b.AvgLatency) "DarkYellow"
        }
    }

    Add3 "" "White"
    Add3 "  === TRACEROUTE RESULTS (last 3) ===" "Cyan"
    Add3 "" "White"

    if ($script:traceroutes.Count -eq 0) {
        Add3 "    (no traceroutes recorded yet)" "DarkGray"
        Add3 "    Traceroutes run automatically on outages." "DarkGray"
    }
    else {
        foreach ($tr in $script:traceroutes) {
            Add3 ("    Target: {0}  Time: {1}" -f $tr.Target, $tr.Time) "Cyan"
            if ($tr.Hops.Count -eq 0) {
                Add3 "      (no hops captured)" "DarkGray"
            }
            else {
                Add3 ("      {0,-5} {1,-18} {2}" -f "Hop", "IP", "Latency") "DarkCyan"
                foreach ($hop in $tr.Hops) {
                    Add3 ("      {0,-5} {1,-18} {2}" -f $hop.Hop, $hop.IP, $hop.Latency) "White"
                }
            }
            Add3 "" "White"
        }
    }

    return $frame
}

# ================================================================
#  TAB 4: PER-TARGET DETAIL
# ================================================================
function BuildTab4 {
    $frame = [System.Collections.Generic.List[hashtable]]::new()

    function Add4($text, $color) {
        $frame.Add(@{ Text = $text; Color = $color })
    }

    Add4 "" "White"
    Add4 "  === PER-TARGET DETAIL ===" "Magenta"
    Add4 "" "White"

    if ($script:perTarget.Keys.Count -eq 0) {
        Add4 "    (no target data yet)" "DarkGray"
    }
    else {
        Add4 ("    {0,-20} {1,6} {2,6} {3,7} {4,8} {5,8} {6,8} {7,8}" -f "Target", "Sent", "OK", "Loss%", "Avg", "Min", "Max", "P95") "DarkCyan"
        Add4 ("    {0} {1} {2} {3} {4} {5} {6} {7}" -f ("-" * 20), ("-" * 6), ("-" * 6), ("-" * 7), ("-" * 8), ("-" * 8), ("-" * 8), ("-" * 8)) "DarkGray"

        foreach ($t in $script:perTarget.Keys) {
            $info = $script:perTarget[$t]
            $tLoss = 0
            if ($info.sent -gt 0) { $tLoss = [math]::Round((1 - $info.ok / $info.sent) * 100, 1) }
            $tAvg = 0; $tMin = 0; $tMax = 0; $tP95 = 0
            if ($info.lats.Count -gt 0) {
                $tAvg = [math]::Round(($info.lats | Measure-Object -Average).Average, 1)
                $tMin = [math]::Round(($info.lats | Measure-Object -Minimum).Minimum, 1)
                $tMax = [math]::Round(($info.lats | Measure-Object -Maximum).Maximum, 1)
                $sorted = @($info.lats | Sort-Object)
                $idx95 = [math]::Floor($sorted.Count * 0.95)
                if ($idx95 -ge $sorted.Count) { $idx95 = $sorted.Count - 1 }
                $tP95 = [math]::Round($sorted[$idx95], 1)
            }
            $tColor = "White"
            if ($tLoss -gt 0) { $tColor = "Yellow" }
            if ($tLoss -ge 5) { $tColor = "Red" }
            Add4 ("    {0,-20} {1,6} {2,6} {3,6}% {4,7}ms {5,7}ms {6,7}ms {7,7}ms" -f $t, $info.sent, $info.ok, $tLoss, $tAvg, $tMin, $tMax, $tP95) $tColor
        }
    }

    Add4 "" "White"
    Add4 "  === GATEWAY LATENCY ===" "Cyan"
    Add4 "" "White"

    $gwVals = @($script:gwHistory | Where-Object { $null -ne $_.Latency } | ForEach-Object { $_.Latency })
    if ($gwVals.Count -eq 0) {
        Add4 "    (no gateway data yet)" "DarkGray"
    }
    else {
        $gwAvg = [math]::Round(($gwVals | Measure-Object -Average).Average, 1)
        $gwMin = [math]::Round(($gwVals | Measure-Object -Minimum).Minimum, 1)
        $gwMax = [math]::Round(($gwVals | Measure-Object -Maximum).Maximum, 1)
        Add4 ("    Samples: {0}    Avg: {1}ms    Min: {2}ms    Max: {3}ms" -f $gwVals.Count, $gwAvg, $gwMin, $gwMax) "White"
    }

    return $frame
}

# ================================================================
#  TAB 5: TIME-OF-DAY HEATMAP
# ================================================================
function BuildTab5 {
    $frame = [System.Collections.Generic.List[hashtable]]::new()

    function Add5($text, $color) {
        $frame.Add(@{ Text = $text; Color = $color })
    }

    Add5 "" "White"
    Add5 "  === TIME-OF-DAY HEATMAP ===" "Green"
    Add5 "" "White"

    $hmLines = BuildHeatmap
    foreach ($hml in $hmLines) {
        Add5 $hml "White"
    }

    return $frame
}

# ================================================================
#  MASTER FRAME BUILDER
# ================================================================
function BuildFrame($adapter, $gw, $localIP, $target, $ping, $gwPing, $dnsResult, $latWarn, $enableDns, $wifiSig, $diagnosis) {
    $consoleWidth = 120
    try { $consoleWidth = $Host.UI.RawUI.WindowSize.Width } catch {}
    if ($consoleWidth -lt 60) { $consoleWidth = 60 }

    $frame = [System.Collections.Generic.List[hashtable]]::new()

    # Tab bar (always at top)
    $tabBar = BuildTabBar
    $frame.Add(@{ Text = $tabBar; Color = "Cyan" })
    $frame.Add(@{ Text = ("  " + ("=" * ($consoleWidth - 4))); Color = "DarkGray" })

    switch ($script:activeTab) {
        1 {
            $leftWidth = [math]::Floor($consoleWidth * 0.52)
            if ($leftWidth -lt 40) { $leftWidth = 40 }
            $leftLines = BuildTab1Left $adapter $gw $localIP $target $ping $gwPing $dnsResult $latWarn $enableDns $wifiSig $diagnosis $leftWidth
            $rightLines = BuildTab1Right $leftWidth
            $merged = MergeDualPane $leftLines $rightLines $leftWidth $consoleWidth
            foreach ($m in $merged) {
                $frame.Add($m)
            }
        }
        2 {
            $tab2 = BuildTab2
            foreach ($t2 in $tab2) { $frame.Add($t2) }
        }
        3 {
            $tab3 = BuildTab3
            foreach ($t3 in $tab3) { $frame.Add($t3) }
        }
        4 {
            $tab4 = BuildTab4
            foreach ($t4 in $tab4) { $frame.Add($t4) }
        }
        5 {
            $tab5 = BuildTab5
            foreach ($t5 in $tab5) { $frame.Add($t5) }
        }
    }

    # Footer with hotkeys
    $frame.Add(@{ Text = ""; Color = "White" })
    $frame.Add(@{ Text = "  [1-5] Tab  [P]ause  [R]eset  [E]xport  [Q]uit  |  Ctrl+C stop"; Color = "DarkGray" })

    return $frame
}

# ================================================================
#  LOGGING (ENRICHED CSV with -Force)
# ================================================================
function LogPing($pingResult, $gwResult, $dnsResult, $wifiSig) {
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

    $blVal = ""
    if ($script:baselineLatency) { $blVal = $script:baselineLatency }

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
        BaselineMs    = $blVal
        PublicIP      = $script:publicIP
        ISP           = $script:ispName
    }

    $file = $script:pingLogFile
    if (-not (Test-Path $file)) {
        $record | Export-Csv $file -NoTypeInformation
    }
    else {
        $record | Export-Csv $file -Append -NoTypeInformation -Force
    }
}

function LogDrop($start, $end, $target, $diagnosis) {
    $dur = [math]::Round(($end - $start).TotalSeconds, 2)
    $record = [PSCustomObject]@{
        Start     = $start.ToString("yyyy-MM-dd HH:mm:ss.fff")
        End       = $end.ToString("yyyy-MM-dd HH:mm:ss.fff")
        Duration  = $dur
        Target    = $target
        Diagnosis = $diagnosis
    }

    $file = $script:dropLogFile
    if (-not (Test-Path $file)) {
        $record | Export-Csv $file -NoTypeInformation
    }
    else {
        $record | Export-Csv $file -Append -NoTypeInformation -Force
    }

    $script:drops.Add($record)
}

function LogThresholdBreach($start, $end, $avgLat) {
    $dur = [math]::Round(($end - $start).TotalSeconds, 2)
    $record = [PSCustomObject]@{
        Start      = $start.ToString("yyyy-MM-dd HH:mm:ss.fff")
        End        = $end.ToString("yyyy-MM-dd HH:mm:ss.fff")
        Duration   = $dur
        AvgLatency = $avgLat
    }

    $file = $script:breachLogFile
    if (-not (Test-Path $file)) {
        $record | Export-Csv $file -NoTypeInformation
    }
    else {
        $record | Export-Csv $file -Append -NoTypeInformation -Force
    }

    $script:thresholdBreaches.Add($record)
}

# ================================================================
#  HTML REPORT GENERATOR
# ================================================================
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

    # Build latency data for chart
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

    # Avg CSS color
    $avgCssColor = "#22c55e"
    if ($avg -ge 80) { $avgCssColor = "#ef4444" }
    elseif ($avg -ge 30) { $avgCssColor = "#f59e0b" }

    # Loss CSS color
    $lossCssColor = "#22c55e"
    if ($loss -ge 5) { $lossCssColor = "#ef4444" }
    elseif ($loss -gt 0) { $lossCssColor = "#f59e0b" }

    # Jitter CSS color
    $jitterCssColor = "#22c55e"
    if ($jitter -ge 15) { $jitterCssColor = "#ef4444" }
    elseif ($jitter -ge 5) { $jitterCssColor = "#f59e0b" }

    # Drops CSS color
    $dropsCssColor = "#22c55e"
    if ($script:drops.Count -gt 0) { $dropsCssColor = "#ef4444" }

    # Baseline text
    $baselineText = "N/A"
    if ($script:baselineLatency) { $baselineText = "$($script:baselineLatency)ms" }

    # Outages drop table
    $dropsTableHtml = '<p class="empty">No connection drops recorded during this session.</p>'
    if ($script:drops.Count -gt 0) {
        $dropsTableHtml = "<table><thead><tr><th>Start</th><th>End</th><th>Duration</th><th>Target</th><th>Diagnosis</th></tr></thead><tbody>$dropRows</tbody></table>"
    }

    # Breaches table
    $breachTableHtml = '<p class="empty">No high latency events recorded during this session.</p>'
    if ($script:thresholdBreaches.Count -gt 0) {
        $breachTableHtml = "<table><thead><tr><th>Start</th><th>End</th><th>Duration</th><th>Avg Latency</th></tr></thead><tbody>$breachRows</tbody></table>"
    }

    # Heatmap data for HTML
    $heatmapHtml = ""
    for ($hh = 0; $hh -lt 24; $hh++) {
        $hhLabel = "{0:D2}:00" -f $hh
        $hhAvg = "-"
        $hhCount = 0
        $hhColor = "#64748b"
        if ($script:hourlyData.ContainsKey($hh) -and $script:hourlyData[$hh].Count -gt 0) {
            $hhAvgVal = [math]::Round(($script:hourlyData[$hh] | Measure-Object -Average).Average, 1)
            $hhAvg = "${hhAvgVal}ms"
            $hhCount = $script:hourlyData[$hh].Count
            if ($hhAvgVal -lt 30) { $hhColor = "#22c55e" }
            elseif ($hhAvgVal -lt 60) { $hhColor = "#f59e0b" }
            else { $hhColor = "#ef4444" }
        }
        $heatmapHtml += "<div class='heat-cell' style='background:$hhColor'><span class='heat-hour'>$hhLabel</span><span class='heat-val'>$hhAvg</span></div>"
    }

    $reportDate = Get-Date -Format "yyyy-MM-dd HH:mm"
    $sessionStartStr = $script:sessionStart.ToString("yyyy-MM-dd HH:mm:ss")
    $durationStr = FormatDuration $elapsed
    $reportGenStr = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $totalPingsLost = $script:totalPings - $script:totalSuccess

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Network Report - $reportDate</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
  :root {
    --bg: #0f172a; --card: #1e293b; --border: #334155;
    --text: #e2e8f0; --muted: #94a3b8; --accent: #38bdf8;
    --green: #22c55e; --yellow: #f59e0b; --red: #ef4444;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
    background: var(--bg); color: var(--text); line-height: 1.6; padding: 20px;
  }
  .container { max-width: 1400px; margin: 0 auto; }
  .header {
    text-align: center; padding: 40px 20px;
    background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%);
    border: 1px solid var(--border); border-radius: 16px; margin-bottom: 24px;
  }
  .header h1 {
    font-size: 2rem; font-weight: 700;
    background: linear-gradient(90deg, #38bdf8, #818cf8);
    -webkit-background-clip: text; -webkit-text-fill-color: transparent; margin-bottom: 8px;
  }
  .header .subtitle { color: var(--muted); font-size: 0.95rem; }
  .header .session-info {
    display: flex; justify-content: center; gap: 32px; margin-top: 16px; flex-wrap: wrap;
  }
  .header .session-info span { color: var(--muted); font-size: 0.85rem; }
  .header .session-info strong { color: var(--text); }
  .score-row {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
    gap: 16px; margin-bottom: 24px;
  }
  .score-card {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; padding: 20px; text-align: center;
  }
  .score-card .label {
    font-size: 0.8rem; text-transform: uppercase; letter-spacing: 1px;
    color: var(--muted); margin-bottom: 8px;
  }
  .score-card .value { font-size: 2rem; font-weight: 700; }
  .score-card .sub { font-size: 0.8rem; color: var(--muted); margin-top: 4px; }
  .chart-card {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; padding: 24px; margin-bottom: 24px;
  }
  .chart-card h2 { font-size: 1.1rem; font-weight: 600; margin-bottom: 16px; color: var(--accent); }
  .chart-row { display: grid; grid-template-columns: 2fr 1fr; gap: 24px; margin-bottom: 24px; }
  @media (max-width: 900px) { .chart-row { grid-template-columns: 1fr; } }
  .table-card {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; padding: 24px; margin-bottom: 24px; overflow-x: auto;
  }
  .table-card h2 { font-size: 1.1rem; font-weight: 600; margin-bottom: 16px; color: var(--accent); }
  table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
  th {
    text-align: left; padding: 10px 12px; border-bottom: 2px solid var(--border);
    color: var(--muted); font-weight: 600; text-transform: uppercase; font-size: 0.75rem; letter-spacing: 0.5px;
  }
  td { padding: 10px 12px; border-bottom: 1px solid var(--border); }
  tr:hover { background: rgba(56, 189, 248, 0.05); }
  tr.bad { background: rgba(239, 68, 68, 0.1); }
  tr.warn { background: rgba(245, 158, 11, 0.1); }
  .empty { color: var(--muted); font-style: italic; padding: 20px; text-align: center; }
  .stats-grid {
    display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px;
  }
  .stat-item {
    background: rgba(15, 23, 42, 0.5); padding: 14px; border-radius: 8px; border: 1px solid var(--border);
  }
  .stat-item .stat-label { font-size: 0.75rem; text-transform: uppercase; color: var(--muted); letter-spacing: 0.5px; }
  .stat-item .stat-value { font-size: 1.3rem; font-weight: 700; margin-top: 4px; }
  .heat-grid { display: grid; grid-template-columns: repeat(24, 1fr); gap: 4px; margin: 16px 0; }
  .heat-cell { padding: 8px 4px; border-radius: 6px; text-align: center; color: #fff; font-size: 0.7rem; }
  .heat-hour { display: block; font-weight: 600; }
  .heat-val { display: block; font-size: 0.65rem; opacity: 0.8; }
  .footer { text-align: center; padding: 24px; color: var(--muted); font-size: 0.8rem; }
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <h1>Network Connectivity Report</h1>
    <p class="subtitle">Generated by Connectivity Monitor v4.0</p>
    <div class="session-info">
      <span>Started: <strong>$sessionStartStr</strong></span>
      <span>Duration: <strong>$durationStr</strong></span>
      <span>ISP: <strong>$($script:ispName)</strong></span>
      <span>Public IP: <strong>$($script:publicIP)</strong></span>
    </div>
  </div>
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
      <div class="value" style="color: $avgCssColor">${avg}ms</div>
      <div class="sub">Baseline: $baselineText</div>
    </div>
    <div class="score-card">
      <div class="label">Packet Loss</div>
      <div class="value" style="color: $lossCssColor">${loss}%</div>
      <div class="sub">$totalPingsLost packets lost</div>
    </div>
    <div class="score-card">
      <div class="label">Jitter</div>
      <div class="value" style="color: $jitterCssColor">${jitter}ms</div>
      <div class="sub">Avg variation</div>
    </div>
    <div class="score-card">
      <div class="label">Outages</div>
      <div class="value" style="color: $dropsCssColor">$($script:drops.Count)</div>
      <div class="sub">Total: ${totalDowntime}s</div>
    </div>
  </div>
  <div class="chart-card">
    <h2>Detailed Statistics</h2>
    <div class="stats-grid">
      <div class="stat-item"><div class="stat-label">Min Latency</div><div class="stat-value" style="color:var(--green)">${min}ms</div></div>
      <div class="stat-item"><div class="stat-label">Max Latency</div><div class="stat-value" style="color:var(--red)">${max}ms</div></div>
      <div class="stat-item"><div class="stat-label">P95 Latency</div><div class="stat-value" style="color:var(--yellow)">${p95}ms</div></div>
      <div class="stat-item"><div class="stat-label">P99 Latency</div><div class="stat-value" style="color:var(--yellow)">${p99}ms</div></div>
      <div class="stat-item"><div class="stat-label">Longest Drop</div><div class="stat-value" style="color:var(--red)">${longestDrop}s</div></div>
      <div class="stat-item"><div class="stat-label">Total Pings</div><div class="stat-value">$($script:totalPings)</div></div>
    </div>
  </div>
  <div class="chart-card">
    <h2>Time-of-Day Heatmap</h2>
    <div class="heat-grid">$heatmapHtml</div>
  </div>
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
  <div class="table-card">
    <h2>Per-Target Breakdown</h2>
    <table>
      <thead><tr><th>Target</th><th>Sent</th><th>OK</th><th>Loss</th><th>Avg</th><th>Min</th><th>Max</th></tr></thead>
      <tbody>$targetRows</tbody>
    </table>
  </div>
  <div class="table-card"><h2>Connection Drops</h2>$dropsTableHtml</div>
  <div class="table-card"><h2>High Latency Events</h2>$breachTableHtml</div>
  <div class="footer">Report generated on $reportGenStr | Connectivity Monitor v4.0</div>
</div>
<script>
const ctx1 = document.getElementById('latencyChart').getContext('2d');
new Chart(ctx1, {
  type: 'line',
  data: {
    labels: [$labelsJs],
    datasets: [
      { label: 'Latency (ms)', data: [$dataJs], borderColor: '#38bdf8', backgroundColor: 'rgba(56,189,248,0.1)', borderWidth: 1.5, pointRadius: 0, fill: true, tension: 0.3, spanGaps: false },
      { label: 'Gateway (ms)', data: [$gwJs], borderColor: '#818cf8', backgroundColor: 'rgba(129,140,248,0.05)', borderWidth: 1, pointRadius: 0, fill: false, tension: 0.3, spanGaps: false }
    ]
  },
  options: {
    responsive: true, interaction: { intersect: false, mode: 'index' },
    plugins: { legend: { labels: { color: '#94a3b8' } } },
    scales: {
      x: { ticks: { color: '#64748b', maxTicksLimit: 20, maxRotation: 45 }, grid: { color: 'rgba(51,65,85,0.5)' } },
      y: { beginAtZero: true, ticks: { color: '#64748b' }, grid: { color: 'rgba(51,65,85,0.5)' }, title: { display: true, text: 'ms', color: '#64748b' } }
    }
  }
});
const ctx2 = document.getElementById('histChart').getContext('2d');
new Chart(ctx2, {
  type: 'bar',
  data: {
    labels: ['0-10ms','10-25ms','25-50ms','50-100ms','100-200ms','200ms+'],
    datasets: [{ label: 'Count', data: [$histJs], backgroundColor: ['#22c55e','#4ade80','#facc15','#f59e0b','#f97316','#ef4444'], borderRadius: 6 }]
  },
  options: {
    responsive: true, plugins: { legend: { display: false } },
    scales: { x: { ticks: { color: '#64748b' }, grid: { display: false } }, y: { beginAtZero: true, ticks: { color: '#64748b' }, grid: { color: 'rgba(51,65,85,0.5)' } } }
  }
});
</script>
</body>
</html>
"@

    $dir = Split-Path $reportFile
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $html | Set-Content $reportFile -Encoding UTF8
}

# ================================================================
#  SESSION SUMMARY (CONSOLE)
# ================================================================
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
        $longestDropVal = ($script:drops | ForEach-Object { [double]$_.Duration } | Measure-Object -Maximum).Maximum
        Write-Host ("  Total Downtime : {0}s" -f [math]::Round($totalDown, 2)) -ForegroundColor Red
        Write-Host ("  Longest Drop   : {0}s" -f [math]::Round($longestDropVal, 2)) -ForegroundColor Red
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
    Write-Host ("   Adapter   : {0}" -f $savedConfig.adapter) -ForegroundColor Gray
    Write-Host ("   Targets   : {0}" -f $savedConfig.targets) -ForegroundColor Gray
    Write-Host ("   Poll      : {0}s" -f $savedConfig.poll) -ForegroundColor Gray
    Write-Host ("   Threshold : {0}" -f $savedConfig.threshold) -ForegroundColor Gray
    Write-Host ("   Lat Warn  : {0}ms" -f $savedConfig.latWarn) -ForegroundColor Gray
    Write-Host ("   DNS       : {0}" -f $savedConfig.enableDns) -ForegroundColor Gray
    Write-Host ("   Beep      : {0}" -f $savedConfig.enableBeep) -ForegroundColor Gray
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

    # Save config
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

# Detect public IP
Write-Host " Detecting public IP..." -ForegroundColor DarkGray
DetectPublicIP

Clear-Host
$rr = 0
$script:lastDiagnosis = @{ msg = "Initializing..."; color = "DarkGray" }
$script:lastWifiSig = $null

# ================================================================
#  MAIN LOOP
# ================================================================

Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress -Action {
    $script:shutdown = $true
    $_.Cancel = $true
} | Out-Null

while (-not $script:shutdown) {

    # Check for daily log rotation
    CheckDateRoll

    # Handle hotkeys (non-blocking)
    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            "D1" { $script:activeTab = 1 }
            "D2" { $script:activeTab = 2 }
            "D3" { $script:activeTab = 3 }
            "D4" { $script:activeTab = 4 }
            "D5" { $script:activeTab = 5 }
            "NumPad1" { $script:activeTab = 1 }
            "NumPad2" { $script:activeTab = 2 }
            "NumPad3" { $script:activeTab = 3 }
            "NumPad4" { $script:activeTab = 4 }
            "NumPad5" { $script:activeTab = 5 }
            "P" { $script:paused = -not $script:paused }
            "R" {
                $script:history.Clear()
                $script:drops.Clear()
                $script:perTarget.Clear()
                $script:gwHistory.Clear()
                $script:thresholdBreaches.Clear()
                $script:traceroutes.Clear()
                $script:hourlyData.Clear()
                $script:failCount = 0
                $script:isDown = $false
                $script:totalPings = 0
                $script:totalSuccess = 0
                $script:sessionStart = Get-Date
                $script:baselineSamples.Clear()
                $script:baselineLatency = $null
                $script:baselineLocked = $false
                $script:lastLineCount = 0
            }
            "Q" { $script:shutdown = $true; continue }
            "E" {
                $snapFile = Join-Path $script:reportsDir ("report_{0}.html" -f (Get-Date -Format "yyyy-MM-dd_HHmmss"))
                GenerateHtmlReport $snapFile
            }
        }
    }

    if ($script:paused) {
        $consoleWidth = 120
        try { $consoleWidth = $Host.UI.RawUI.WindowSize.Width } catch {}
        $frame = BuildFrame $a $gw $localIP $target $p $gwPing $dnsResult $latWarn $enableDns $script:lastWifiSig $script:lastDiagnosis
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

    # Update hourly data
    if ($p.ok -and $null -ne $p.lat) {
        UpdateHourlyData $p.lat
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

    # WiFi signal (every 5th iteration)
    if ($rr % 5 -eq 0) {
        $script:lastWifiSig = GetWifiSignal
    }

    # Diagnose
    $script:lastDiagnosis = DiagnoseIssue $gwPing $p

    # Log every ping
    LogPing $p $gwPing $dnsResult $script:lastWifiSig

    # Collect any background traceroute results
    CollectTraceroute $target

    # Outage detection
    if (-not $p.ok) {
        $script:failCount++
        if ($script:failCount -ge $threshold -and -not $script:isDown) {
            $script:isDown = $true
            $script:downStart = Get-Date
            if ($enableBeep) { [Console]::Beep(1000, 300) }
            # Start background traceroute on outage
            StartTraceroute $target
        }
    }
    else {
        if ($script:isDown) {
            $end = Get-Date
            LogDrop $script:downStart $end $target $script:lastDiagnosis.msg
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
            LogThresholdBreach $script:breachStart $breachEnd $breachAvg
            $script:breachActive = $false
        }
    }

    # Re-detect public IP every 100 pings
    if ($script:totalPings % 100 -eq 0 -and $script:totalPings -gt 0) {
        DetectPublicIP
    }

    # Auto-generate HTML report every 500 pings
    if ($script:totalPings % 500 -eq 0 -and $script:totalPings -gt 0) {
        $autoReport = Join-Path $script:reportsDir ("report_{0}.html" -f (Get-Date -Format "yyyy-MM-dd_HHmmss"))
        GenerateHtmlReport $autoReport
    }

    # Render
    $consoleWidth = 120
    try { $consoleWidth = $Host.UI.RawUI.WindowSize.Width } catch {}
    $frame = BuildFrame $a $gw $localIP $target $p $gwPing $dnsResult $latWarn $enableDns $script:lastWifiSig $script:lastDiagnosis
    RenderFrame $frame $consoleWidth

    Start-Sleep $poll
}

# ================================================================
#  SHUTDOWN
# ================================================================

# Clean up background traceroute job if running
if ($null -ne $script:traceJob) {
    try {
        Remove-Job $script:traceJob -Force -ErrorAction SilentlyContinue
    }
    catch {}
    $script:traceJob = $null
}

if ($script:isDown) {
    $end = Get-Date
    LogDrop $script:downStart $end "N/A" "Session ended during outage"
}

if ($script:breachActive) {
    $breachEnd = Get-Date
    LogThresholdBreach $script:breachStart $breachEnd (Avg)
}

# Generate final HTML report
Clear-Host
Write-Host " Generating HTML report..." -ForegroundColor Cyan
$finalReport = Join-Path $script:reportsDir ("report_{0}.html" -f (Get-Date -Format "yyyy-MM-dd_HHmmss"))
GenerateHtmlReport $finalReport

ShowSummary

Write-Host " Files saved to:" -ForegroundColor Gray
Write-Host ("   Base dir    : {0}" -f $script:baseDir) -ForegroundColor White
Write-Host ("   Ping log    : {0}" -f $script:pingLogFile) -ForegroundColor White
Write-Host ("   Drop log    : {0}" -f $script:dropLogFile) -ForegroundColor White
Write-Host ("   Breach log  : {0}" -f $script:breachLogFile) -ForegroundColor White
Write-Host ("   HTML report : {0}" -f $finalReport) -ForegroundColor White
Write-Host ("   Config      : {0}" -f $script:configPath) -ForegroundColor White
Write-Host ""

# Ask to open HTML report
$openReport = PromptYesNo " Open HTML report in browser?" "Y"
if ($openReport) {
    Start-Process $finalReport
}

[Console]::CursorVisible = $true
Write-Host ""
Write-Host " Monitor stopped." -ForegroundColor Cyan
