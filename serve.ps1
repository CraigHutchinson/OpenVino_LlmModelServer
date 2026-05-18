#Requires -Version 7
<#
.SYNOPSIS
    Bootstrap OVMS for Qwen3.6 27B with persisted config, device selection,
    KV cache tuning, post-load memory reporting, and editor integration.

.PARAMETER Device
    OpenVINO device: CPU, GPU, NPU, AUTO. Saved between runs.

.PARAMETER ContextLength
    Max tokens per sequence (default 65536). Qwen3.6 supports up to 262144.

.PARAMETER MaxOutputTokens
    Max tokens the model may generate per reply (default 8192). Reported to
    VS Code so it reserves headroom within the context window.

.PARAMETER KvCachePrecision
    KV cache precision: u8 (halves VRAM) or "" (model default fp16).

.PARAMETER CacheSize
    KV cache size in GB. 0 = dynamic (default).

.PARAMETER LogLevel
    OVMS log level: TRACE, DEBUG, INFO, WARNING, ERROR (default: INFO).

.PARAMETER Warmup
    Send a warmup inference after server ready to trigger lazy model loading.
    Saved between runs. Use -NoWarmup to disable and revert to default (off).

.PARAMETER ListDevices
    Enumerate available OpenVINO devices and exit.

.PARAMETER Reset
    Clear saved config and return to defaults.

.PARAMETER NoTools
    Register a second VS Code endpoint ("Chat") with toolCalling:false alongside the
    full agent endpoint. The Chat entry sends ~2-3K tokens per request instead of the
    ~22K sent when VS Code includes all 66 agent tool definitions. Use it for plain
    conversation; switch to the Agent entry when you need file editing or terminal tools.

.PARAMETER CaptureRequests
    Start a capture proxy on port RestPort+2 that saves every raw request body
    to d:\tools\ovms\captures\ before forwarding to OVMS. VS Code is pointed at
    the proxy port automatically. Replay saved requests with test-request.ps1.

.PARAMETER ModelPath
    Full path to the model directory (contains graph.pbtxt). Saved between runs.
    Auto-detected from the AI Playground models folder if not set.

.PARAMETER ModelName
    Name OVMS registers the model under (used in API requests). Saved between runs.
    Derived from the directory name when auto-detected.

.EXAMPLE
    .\serve.ps1
    .\serve.ps1 -Device GPU -ContextLength 131072 -KvCachePrecision u8
    .\serve.ps1 -ModelPath "C:\models\mymodel" -ModelName my-model
    .\serve.ps1 -ListDevices
    .\serve.ps1 -Reset
    .\serve.ps1 -Warmup -CaptureRequests
#>
param(
    [string] $ModelPath,
    [string] $ModelName,
    [string] $Device,
    [int]    $ContextLength,
    [int]    $MaxOutputTokens,
    [string] $KvCachePrecision,
    [int]    $CacheSize  = -1,
    [string] $LogLevel,
    [string] $LogFile,
    [switch] $Warmup,
    [switch] $NoWarmup,
    [switch] $NoTools,
    [switch] $CaptureRequests,
    [switch] $ListDevices,
    [switch] $Reset
)

$ErrorActionPreference = 'Stop'
$OvmsDir    = $PSScriptRoot
$ConfigFile = Join-Path $OvmsDir 'serve-config.json'

# Base path scanned for auto-detection when ModelPath/ModelName are not set
$AiPlaygroundModelBase = "$env:LOCALAPPDATA\Programs\AI Playground\resources\models\LLM\openvino"

# Python that has the OpenVINO package (AI Playground ships it)
$OvPython   = "$env:LOCALAPPDATA\Programs\AI Playground\resources\OpenVINO\.venv\Scripts\python.exe"

# Editor config paths
$ContinueConfig  = "$env:USERPROFILE\.continue\config.yaml"
$VsCodeInsiders  = "$env:APPDATA\Code - Insiders\User\chatLanguageModels.json"

# ── Defaults ──────────────────────────────────────────────────────────────────
$defaults = [ordered]@{
    Device           = 'CPU'
    ContextLength    = 65536
    MaxOutputTokens  = 8192
    KvCachePrecision = ''
    CacheSize        = 0
    LogLevel         = 'INFO'
    Warmup           = $false
    Port             = 19000     # gRPC  — unique, avoids common port clashes
    RestPort         = 19001     # REST
}

# ── Setup environment ─────────────────────────────────────────────────────────
. (Join-Path $OvmsDir 'setupvars.ps1')

# Helper: run AI Playground Python without OVMS's PYTHONHOME poisoning it
function Invoke-OvPython ([string]$Code) {
    $saved = $env:PYTHONHOME
    $env:PYTHONHOME = $null
    try   { & $OvPython -c $Code }
    finally { $env:PYTHONHOME = $saved }
}

# ── List devices via OpenVINO Core API ────────────────────────────────────────
if ($ListDevices) {
    Write-Host "`nAvailable OpenVINO devices:`n"
    Invoke-OvPython @'
from openvino import Core
c = Core()
for d in c.available_devices:
    name = d
    mem = ""
    try: name = c.get_property(d, "FULL_DEVICE_NAME")
    except: pass
    try:
        raw = c.get_property(d, "GPU_DEVICE_TOTAL_MEM_SIZE")
        mem = "  ({:,.0f} MB)".format(int(raw) / 1024**2)
    except: pass
    print("  {:<8} {}{}".format(d, name, mem))
print()
print("  AUTO     Let OpenVINO choose the best available device")
'@
    Write-Host ""
    return
}

# Scan AI Playground openvino models folder; return @{Path;Name} for first model with graph.pbtxt
function Find-OvmsModel ([string]$BasePath) {
    if (-not (Test-Path $BasePath)) { return $null }
    $candidates = @(Get-ChildItem $BasePath -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'graph.pbtxt') })
    if (-not $candidates) { return $null }
    $dir  = $candidates[0]
    # Strip vendor prefix (anything up to and including ---) then uppercase for the OVMS model name
    $name = ($dir.Name -replace '^.+---', '').ToUpper()
    if ($candidates.Count -gt 1) {
        Write-Warning "Multiple models found in $BasePath — using '$name'. Pass -ModelPath to specify."
    }
    return @{ Path = $dir.FullName; Name = $name }
}

# ── Reset config ──────────────────────────────────────────────────────────────
if ($Reset) {
    if (Test-Path $ConfigFile) { Remove-Item $ConfigFile }
    Write-Host "Config reset to defaults."
}

# ── Load and merge config ─────────────────────────────────────────────────────
$cfg = if (Test-Path $ConfigFile) {
    Get-Content $ConfigFile | ConvertFrom-Json -AsHashtable
} else { @{} }

foreach ($key in $defaults.Keys) {
    if (-not $cfg.ContainsKey($key)) { $cfg[$key] = $defaults[$key] }
}
if ($ModelPath)        { $cfg.ModelPath         = $ModelPath }
if ($ModelName)        { $cfg.ModelName         = $ModelName }
if ($Device)           { $cfg.Device            = $Device }
if ($ContextLength)    { $cfg.ContextLength      = $ContextLength }
if ($MaxOutputTokens)  { $cfg.MaxOutputTokens    = $MaxOutputTokens }
if ($PSBoundParameters.ContainsKey('KvCachePrecision')) {
                         $cfg.KvCachePrecision   = $KvCachePrecision }
if ($CacheSize -ge 0)  { $cfg.CacheSize          = $CacheSize }
if ($LogLevel)         { $cfg.LogLevel           = $LogLevel }
if ($Warmup)           { $cfg.Warmup             = $true }
if ($NoWarmup)         { $cfg.Warmup             = $false }

# Resolve model path/name: param > config > auto-detect
if (-not $cfg.ModelPath -or -not $cfg.ModelName) {
    $detected = Find-OvmsModel $AiPlaygroundModelBase
    if ($detected) {
        if (-not $cfg.ModelPath) { $cfg.ModelPath = $detected.Path; Write-Host "  Auto-detected model path : $($cfg.ModelPath)" -ForegroundColor Cyan }
        if (-not $cfg.ModelName) { $cfg.ModelName = $detected.Name; Write-Host "  Auto-detected model name : $($cfg.ModelName)" -ForegroundColor Cyan }
    } else {
        throw "No model found. Pass -ModelPath and -ModelName, or place a model in $AiPlaygroundModelBase"
    }
}

$cfg | ConvertTo-Json | Set-Content $ConfigFile

# Convenience locals used throughout the rest of the script
$ModelPath = $cfg.ModelPath
$ModelName = $cfg.ModelName
$GraphPath = Join-Path $ModelPath 'graph.pbtxt'

# ── Update editor integrations ────────────────────────────────────────────────
function Update-ContinueConfig {
    param([string]$Path, [string]$Name, [string]$ModelId, [int]$Port)
    if (-not (Test-Path $Path)) { return }

    $apiBase  = "http://localhost:$Port/v3"
    $lines    = Get-Content $Path
    $out      = [System.Collections.Generic.List[string]]::new()
    $skip     = $false
    $injected = $false

    foreach ($line in $lines) {
        # Detect start of our managed entry (2-space indent list item)
        if ($line -match "^  - name:\s+$([regex]::Escape($Name))\s*$") {
            $skip = $true
            continue
        }
        # Detect start of the next list item — stop skipping
        if ($skip -and $line -match '^  - ') { $skip = $false }
        if ($skip) { continue }

        $out.Add($line)

        # Inject our entry right after the 'models:' line
        if (-not $injected -and $line -match '^models:\s*$') {
            $out.Add("  - name: $Name")
            $out.Add("    provider: openai")
            $out.Add("    model: $ModelId")
            $out.Add("    apiBase: $apiBase")
            $out.Add("    apiKey: unused")
            $injected = $true
        }
    }

    Set-Content $Path $out
    Write-Host "  Updated Continue config  : $Path  (REST :$Port)"
}

function Update-VsCodeInsiders {
    param([string]$Path, [string]$ModelId, [int]$Port,
          [int]$MaxInput, [int]$MaxOutput, [switch]$NoTools)
    $models = if (Test-Path $Path) {
        Get-Content $Path -Raw | ConvertFrom-Json
    } else { @() }

    $models = @($models | Where-Object { $_.name -ne 'Ovms' -and $_.name -ne 'OvmsChat' })
    $models += [PSCustomObject]@{
        name   = 'Ovms'
        vendor = 'customendpoint'
        models = @(
            [PSCustomObject]@{
                id              = $ModelId
                name            = if ($NoTools) { 'Qwen3.6 27B (Chat)' } else { 'Qwen3.6 27B (Agent)' }
                url             = "http://localhost:$Port/v3"
                toolCalling     = -not $NoTools.IsPresent
                vision          = $true
                maxInputTokens  = $MaxInput
                maxOutputTokens = $MaxOutput
            }
        )
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    $models | ConvertTo-Json -AsArray -Depth 10 | Set-Content $Path
    $mode = if ($NoTools) { 'Chat (no tools, ~2-3K tokens/req)' } else { 'Agent (tools enabled, ~22K tokens/req)' }
    Write-Host "  Updated VS Code Insiders : $Path  [$mode]"
}

# ── Patch graph.pbtxt with user config ───────────────────────────────────────
# MediaPipe graph models ignore CLI flags like --target_device; all LLM settings
# live inside graph.pbtxt's LLMCalculatorOptions and must be set there.
function Update-ModelGraph {
    param([hashtable]$Config, [string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Warning "graph.pbtxt not found at $Path — model settings not applied"
        return
    }

    $content = Get-Content $Path -Raw
    Copy-Item $Path ($Path + '.bak') -Force

    # Device
    $content = $content -replace '(device:\s*")[^"]*(")', "`${1}$($Config.Device)`$2"

    # KV cache size in GB — always write so stale manual edits to graph.pbtxt don't persist.
    # 0 = dynamic (OVMS manages allocation); required for large-context requests like VS Code's
    # 22K-token system prompt which exhausts a 2GB fixed cache and produces 0 completion tokens.
    $content = $content -replace '(cache_size:\s*)\d+', "`${1}$($Config.CacheSize)"

    # Context length — add or update max_num_batched_tokens
    if ($content -match 'max_num_batched_tokens:\s*\d+') {
        $content = $content -replace '(max_num_batched_tokens:\s*)\d+', "`${1}$($Config.ContextLength)"
    } else {
        $content = $content -replace '(cache_size:\s*\d+)', "`$1`n            max_num_batched_tokens: $($Config.ContextLength)"
    }

    [System.IO.File]::WriteAllText($Path, $content)
    $szLabel = if ($Config.CacheSize -gt 0) { "$($Config.CacheSize) GB" } else { 'dynamic' }
    Write-Host "  Updated graph.pbtxt      : device=$($Config.Device)  cache=$szLabel  ctx=$($Config.ContextLength)"
    if ($Config.KvCachePrecision) {
        Write-Host "  Note: KV cache precision ($($Config.KvCachePrecision)) applies to GPU devices only — set in graph.pbtxt plugin_config manually if needed." -ForegroundColor Yellow
    }
}

# When -CaptureRequests is set, VS Code points at the proxy port (RestPort+2);
# the proxy forwards to OVMS at RestPort. Not saved to config.
$vsCodePort = if ($CaptureRequests) { $cfg.RestPort + 2 } else { $cfg.RestPort }

Write-Host "`nUpdating editor integrations..."
Update-ContinueConfig -Path $ContinueConfig -Name "Qwen3.6 27B (OVMS)" -ModelId $ModelName -Port $cfg.RestPort
Update-VsCodeInsiders -Path $VsCodeInsiders -ModelId $ModelName -Port $vsCodePort -MaxInput $cfg.ContextLength -MaxOutput $cfg.MaxOutputTokens -NoTools:$NoTools
Update-ModelGraph     -Config $cfg           -Path $GraphPath

# ── Display active config ─────────────────────────────────────────────────────
Write-Host @"

  Model        : $ModelName
  Device       : $($cfg.Device)
  Context      : $("{0:N0}" -f $cfg.ContextLength) tokens  (max input)
  Max output   : $("{0:N0}" -f $cfg.MaxOutputTokens) tokens
  KV precision : $(if ($cfg.KvCachePrecision) { $cfg.KvCachePrecision } else { 'model default (fp16)' })
  KV cache     : $(if ($cfg.CacheSize -eq 0) { 'dynamic' } else { "$($cfg.CacheSize) GB" })
  Log level    : $($cfg.LogLevel)
  Warmup       : $(if ($cfg.Warmup) { 'yes' } else { 'no  (-Warmup to enable)' })
  gRPC port    : $($cfg.Port)
  REST port    : $($cfg.RestPort)

"@

# ── Build OVMS args ───────────────────────────────────────────────────────────
# LLM settings (device, cache_size, context, kv_precision) are patched directly
# into graph.pbtxt above — passing them as CLI flags causes an immediate exit 3.
$ovmsArgs = @(
    '--model_path',    $ModelPath
    '--model_name',    $ModelName
    '--port',          $cfg.Port
    '--rest_port',     $cfg.RestPort
    '--log_level',     $cfg.LogLevel
    '--metrics_enable'
)

# Return process info (Id, Name, Path) for whoever owns a TCP listen port, or $null if free.
function Get-PortOwner ([int]$Port) {
    $tcp = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (-not $tcp) { return $null }
    $pidNum = $tcp.OwningProcess | Select-Object -First 1
    $proc = Get-Process -Id $pidNum -ErrorAction SilentlyContinue
    if (-not $proc) { return [pscustomobject]@{ Pid = $pidNum; Name = '?'; Path = $null } }
    [pscustomobject]@{ Pid = $proc.Id; Name = $proc.ProcessName; Path = $proc.Path }
}

# Pre-flight: check the ports OVMS is about to bind. Report clearly which PID owns
# each conflict and exit before launching, so the user doesn't have to parse OVMS's
# gRPC-internal error spew (wsa_error 10048 etc.).
$portsToCheck = @{ 'gRPC' = [int]$cfg.Port; 'REST' = [int]$cfg.RestPort }
if ($CaptureRequests) { $portsToCheck['Capture proxy'] = [int]$cfg.RestPort + 2 }

$conflicts = @()
foreach ($label in $portsToCheck.Keys) {
    $owner = Get-PortOwner $portsToCheck[$label]
    if ($owner) { $conflicts += [pscustomobject]@{ Label = $label; Port = $portsToCheck[$label]; Owner = $owner } }
}

if ($conflicts.Count) {
    Write-Host "`nPort conflict — cannot start OVMS:`n" -ForegroundColor Red
    foreach ($c in $conflicts) {
        Write-Host ("  {0,-14} port {1}  →  PID {2}  ({3})" -f $c.Label, $c.Port, $c.Owner.Pid, $c.Owner.Name) -ForegroundColor Yellow
        if ($c.Owner.Path) { Write-Host ("                                 {0}" -f $c.Owner.Path) -ForegroundColor DarkGray }
    }
    # If our own previous instance is the culprit, offer one-liner fix
    $stale = $conflicts | Where-Object { $_.Owner.Name -eq 'ovms' } | Select-Object -First 1
    if ($stale) {
        Write-Host "`n  Looks like a previous OVMS instance is still running. To kill it:" -ForegroundColor Cyan
        Write-Host "    Get-Process ovms | Stop-Process -Force" -ForegroundColor White
    } else {
        Write-Host "`n  To kill the conflicting process:" -ForegroundColor Cyan
        Write-Host ("    Stop-Process -Id {0} -Force" -f ($conflicts[0].Owner.Pid)) -ForegroundColor White
    }
    Write-Host ""
    return
}

Write-Host "Starting OVMS..."
Write-Host "  ovms.exe $($ovmsArgs -join ' ')`n"

# ── Launch and stream output ──────────────────────────────────────────────────
$psi                        = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName               = Join-Path $OvmsDir 'ovms.exe'
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.UseShellExecute        = $false
$psi.WorkingDirectory       = $OvmsDir
# Use ArgumentList so paths with spaces are quoted correctly
foreach ($arg in $ovmsArgs) { $psi.ArgumentList.Add([string]$arg) }

$proc = [System.Diagnostics.Process]::new()
$proc.StartInfo = $psi
$proc.Start() | Out-Null

# Read both stdout and stderr on background threads into a shared queue
$queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$readerBlock = {
    param($stream, $q)
    while (-not $stream.EndOfStream) {
        $line = $stream.ReadLine()
        if ($null -ne $line) { $q.Enqueue($line) }
    }
}
$null = Start-ThreadJob -ScriptBlock $readerBlock -ArgumentList $proc.StandardOutput, $queue
$null = Start-ThreadJob -ScriptBlock $readerBlock -ArgumentList $proc.StandardError,  $queue

$ready = $false
$memDone = $false

function Show-MemoryReport ([int]$ProcessId) {
    Write-Host "`n--- Memory after model load ---" -ForegroundColor Cyan
    try {
        $p = Get-Process -Id $ProcessId
        Write-Host ("  Process workingset   : {0,8:N0} MB" -f ($p.WorkingSet64/1MB)) -ForegroundColor Cyan
    } catch {}
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        Write-Host ("  System RAM free      : {0,8:N0} MB of {1:N0} MB" -f ($os.FreePhysicalMemory/1KB), ($os.TotalVisibleMemorySize/1KB)) -ForegroundColor Cyan
    } catch {}
    try {
        $gpu = Get-Counter '\GPU Process Memory(*)\Local Usage' -ErrorAction Stop
        $byProc = $gpu.CounterSamples | Where-Object { $_.InstanceName -match "pid_$ProcessId" -and $_.CookedValue -gt 0 }
        if ($byProc) {
            Write-Host ("  GPU VRAM (this proc) : {0,8:N0} MB" -f ($byProc | Measure-Object CookedValue -Sum).Sum/1MB) -ForegroundColor Cyan
        }
        $total = ($gpu.CounterSamples | Where-Object CookedValue -gt 0 | Measure-Object CookedValue -Sum).Sum
        if ($total) {
            Write-Host ("  GPU VRAM (all procs) : {0,8:N0} MB" -f ($total/1MB)) -ForegroundColor Cyan
        }
    } catch {}
    try {
        Get-CimInstance Win32_VideoController | Where-Object AdapterRAM |
            ForEach-Object { Write-Host ("  VRAM capacity        : {0,8:N0} MB  ({1})" -f ($_.AdapterRAM/1MB), $_.Caption.Trim()) -ForegroundColor Cyan }
    } catch {}

    # Context headroom guide
    try {
        $freeMB      = (Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB
        $kvPerKTok   = if ($cfg.KvCachePrecision -eq 'u8') { 0.25 } else { 0.5 }
        $maxCtx      = [int](($freeMB * 0.7) / $kvPerKTok * 1000)
        $kvLabel     = if ($cfg.KvCachePrecision -eq 'u8') { 'u8 KV cache' } else { 'fp16 KV cache' }
        Write-Host "`n--- Context scaling guide ---" -ForegroundColor Yellow
        Write-Host ("  Active context       : {0,8:N0} tokens" -f $cfg.ContextLength)   -ForegroundColor Yellow
        Write-Host ("  Free RAM headroom    : {0,8:N0} tokens  ({1})" -f $maxCtx, $kvLabel) -ForegroundColor Yellow
        if ($cfg.KvCachePrecision -ne 'u8') {
            Write-Host ("  Tip: -KvCachePrecision u8 roughly doubles context capacity")  -ForegroundColor Yellow
        }
    } catch {}
}

# Fetch Prometheus metrics from OVMS into a flat name→value hashtable.
# Returns $null if the endpoint is unreachable or metrics aren't enabled.
function Get-OvmsMetrics ([string]$Url) {
    try {
        $r   = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        $map = @{}
        foreach ($rawLine in ($r.Content -split "`n")) {
            $rawLine = $rawLine.Trim()
            if ($rawLine.StartsWith('#') -or $rawLine.Length -eq 0) { continue }
            if ($rawLine -match '^([A-Za-z_:][A-Za-z0-9_:{},="]*)\s+(\S+)') {
                $val = 0.0
                if ([double]::TryParse($Matches[2],
                        [System.Globalization.NumberStyles]::Float,
                        [System.Globalization.CultureInfo]::InvariantCulture, [ref]$val)) {
                    if (-not $map.ContainsKey($Matches[1]) -or $map[$Matches[1]] -lt $val) {
                        $map[$Matches[1]] = $val
                    }
                }
            }
        }
        return if ($map.Count) { $map } else { $null }
    } catch { return $null }
}

# Display current queue/active load from Prometheus (every 2 s, only when active > 0).
# OVMS Prometheus metrics don't include token counters, so PP/TG throughput comes
# from log parsing — see the $reqStartTime / $reqGenToks tracking in the main loop.
function Show-LoadLine {
    param([hashtable]$Snap, [string]$LogFile)
    if ($null -eq $Snap) { return }

    # Actual OVMS metric names (confirmed from binary string analysis)
    $active = $null; $queue = $null
    foreach ($k in $Snap.Keys) {
        if ($k -match 'infer_req_active|current_requests') { $active = [int]$Snap[$k] }
        if ($k -match 'infer_req_queue_size')              { $queue  = [int]$Snap[$k] }
    }
    if ($null -eq $active -and $null -eq $queue) { return }  # metrics not present
    if ($active -eq 0 -and ($null -eq $queue -or $queue -eq 0)) { return }  # idle — no noise

    $plain = '  · active {0}  queue {1}' -f $active, ($queue ?? '?')
    Write-Host '  · ' -NoNewline -ForegroundColor DarkGray
    Write-Host 'active ' -NoNewline -ForegroundColor DarkGray
    Write-Host $active   -NoNewline -ForegroundColor White
    if ($null -ne $queue) {
        Write-Host '  queue ' -NoNewline -ForegroundColor DarkGray
        Write-Host $queue     -NoNewline -ForegroundColor White
    }
    Write-Host ''
    if ($LogFile) { Add-Content -Path $LogFile -Value $plain -Encoding UTF8 }
}

# Display per-request PP/TG stats derived from log line timestamps and token counts.
# promptToks : tokens in the prompt (from "Number of prompt tokens: N" log line)
# genToks    : tokens generated   (from "Generated tokens: N" log line)
# elapsedSec : wall-clock time between those two log lines
function Show-RequestStats {
    param([int]$PromptToks, [int]$GenToks, [double]$ElapsedSec, [string]$LogFile)
    if ($ElapsedSec -le 0.1) { return }

    # TG throughput = gen_tokens / total_elapsed  (lower bound; prefill takes some of that time)
    # PP is reported as token count only — we can't isolate prefill time from the logs alone.
    $tgRate = $GenToks / $ElapsedSec

    $plain = '  ◆ PP {0,6:N0} tok  TG {1,5:N0} tok [{2:N1} t/s]  {3:N1} s' `
             -f $PromptToks, $GenToks, $tgRate, $ElapsedSec

    Write-Host '  ◆ ' -NoNewline -ForegroundColor DarkGray
    Write-Host 'PP ' -NoNewline -ForegroundColor DarkCyan
    Write-Host ('{0:N0} tok' -f $PromptToks) -NoNewline -ForegroundColor Cyan
    Write-Host '  TG ' -NoNewline -ForegroundColor DarkGreen
    Write-Host ('{0:N0} tok' -f $GenToks) -NoNewline -ForegroundColor Green
    Write-Host (' [{0:N1} t/s]' -f $tgRate) -NoNewline -ForegroundColor Green
    Write-Host ('  {0:N1} s' -f $ElapsedSec) -ForegroundColor DarkGray

    if ($LogFile) { Add-Content -Path $LogFile -Value $plain -Encoding UTF8 }
}

# ── Start capture proxy if requested ─────────────────────────────────────────
$captureJob = $null
if ($CaptureRequests) {
    $captureScript = Join-Path $OvmsDir 'capture.ps1'
    $captureDir    = Join-Path $OvmsDir 'captures'
    $captureJob    = Start-Job -ScriptBlock {
        param($script, $listenPort, $targetPort, $saveDir)
        & $script -ListenPort $listenPort -TargetPort $targetPort -SaveDir $saveDir
    } -ArgumentList $captureScript, $vsCodePort, $cfg.RestPort, $captureDir
    Write-Host "  Capture proxy started     : :$vsCodePort → OVMS :$($cfg.RestPort)" -ForegroundColor Magenta
    Write-Host "  Request bodies saved to   : $captureDir`n" -ForegroundColor Magenta
}

# Metrics polling state (populated after server ready)
$metricsUrl      = "http://localhost:$($cfg.RestPort)/metrics"
$lastMetricsPoll = [DateTime]::MinValue

Write-Host "Waiting for model to load  (Ctrl+C to stop)...`n"

$resolvedLogFile = $null
if ($LogFile) {
    $resolvedLogFile = [System.IO.Path]::GetFullPath($LogFile)
    [System.IO.File]::WriteAllText($resolvedLogFile, '')   # truncate / create
    Write-Host "  Logging OVMS output to   : $resolvedLogFile`n"
}

# Per-request token tracking — populated from OVMS log lines
$reqStartTime  = $null
$reqPromptToks = 0

# Rolling buffer of recent OVMS output, used for failure diagnostics if the process
# exits without becoming ready. Caps at 80 lines to keep memory bounded.
$recentLines = [System.Collections.Generic.Queue[string]]::new()
$procStart   = [DateTime]::UtcNow

try {
    while (-not $proc.HasExited) {
        $line = $null
        while ($queue.TryDequeue([ref]$line)) {
            Write-Host $line
            if ($resolvedLogFile) { Add-Content -Path $resolvedLogFile -Value $line -Encoding UTF8 }
            $recentLines.Enqueue($line)
            while ($recentLines.Count -gt 80) { [void]$recentLines.Dequeue() }

            if (-not $ready -and ($line -match 'ServableManagerModule started|state changed to: AVAILABLE')) {
                $ready = $true
                Write-Host "`n========================================" -ForegroundColor Green
                Write-Host "  SERVER READY" -ForegroundColor Green
                Write-Host "  REST :$($cfg.RestPort)/v3" -ForegroundColor Green
                Write-Host "========================================`n"  -ForegroundColor Green
            }

            if ($ready -and -not $memDone) {
                $memDone = $true
                if ($cfg.Warmup) {
                    # Warmup triggers lazy model weight loading; blocks until first inference done
                    Write-Host "Warming up model (first load may take 1-3 min on CPU)..." -ForegroundColor Yellow
                    try {
                        $warmupBody = @{
                            model      = $ModelName
                            messages   = @(@{ role = 'user'; content = 'Hi' })
                            max_tokens = 1
                        } | ConvertTo-Json -Compress
                        Invoke-RestMethod -Uri "http://localhost:$($cfg.RestPort)/v3/chat/completions" `
                            -Method POST -ContentType 'application/json' -Body $warmupBody `
                            -TimeoutSec 600 | Out-Null
                        Write-Host "Model warm — ready for requests." -ForegroundColor Green
                    } catch {
                        Write-Host "Warmup request failed: $_" -ForegroundColor Yellow
                    }
                } else {
                    Start-Sleep -Milliseconds 500
                }
                Show-MemoryReport -ProcessId $proc.Id
                Write-Host ""
            }

            # ── Token throughput from log parsing ────────────────────────────
            # OVMS Prometheus metrics carry no token counts — PP/TG data comes
            # from these two log lines that bracket each inference request.
            if ($ready -and $line -match 'Number of prompt tokens:\s*(\d+)') {
                $reqStartTime  = [DateTime]::UtcNow
                $reqPromptToks = [int]$Matches[1]
            }
            if ($ready -and $line -match 'Generated tokens:\s*(\d+)') {
                $genToks = [int]$Matches[1]
                if ($null -ne $reqStartTime -and $genToks -gt 0) {
                    $elapsed = ([DateTime]::UtcNow - $reqStartTime).TotalSeconds
                    Show-RequestStats -PromptToks $reqPromptToks -GenToks $genToks `
                        -ElapsedSec $elapsed -LogFile $resolvedLogFile
                }
                $reqStartTime = $null
            }
        }

        # Poll /metrics every 2 s to show active/queue load while inference is running
        if ($ready) {
            $now = [DateTime]::UtcNow
            if (($now - $lastMetricsPoll).TotalMilliseconds -ge 2000) {
                $snap = Get-OvmsMetrics $metricsUrl
                Show-LoadLine -Snap $snap -LogFile $resolvedLogFile
                $lastMetricsPoll = $now
            }
        }

        Start-Sleep -Milliseconds 100
    }
} finally {
    if (-not $proc.HasExited) { $proc.Kill() }
    $proc.WaitForExit()
    if ($CaptureRequests -and $captureJob) { Stop-Job $captureJob; Remove-Job $captureJob }
    # Drain any lines buffered after the loop exited — keep them in $recentLines too
    $line = $null
    while ($queue.TryDequeue([ref]$line)) {
        Write-Host $line
        if ($resolvedLogFile) { Add-Content -Path $resolvedLogFile -Value $line -Encoding UTF8 }
        $recentLines.Enqueue($line)
        while ($recentLines.Count -gt 80) { [void]$recentLines.Dequeue() }
    }
}

Write-Host "`nOVMS exited (code $($proc.ExitCode))"

# ── Failure diagnostics ───────────────────────────────────────────────────────
# Run only if OVMS died before serving anything. Pattern-match recent output for
# known failure modes and report a clear cause + suggested fix.
$runTime = ([DateTime]::UtcNow - $procStart).TotalSeconds
if (-not $ready -or ($proc.ExitCode -ne 0 -and $runTime -lt 30)) {
    $allOutput = ($recentLines -join "`n")

    Write-Host "`n--- Startup failure diagnostics ---" -ForegroundColor Yellow
    Write-Host ("  Process ran for {0:N1} s before exiting" -f $runTime) -ForegroundColor Yellow

    $diagnosed = $false

    if ($allOutput -match 'wsa_error\D*10048|Only one usage of each socket address|Failed to start gRPC server') {
        Write-Host "`n  CAUSE: Port already in use." -ForegroundColor Red
        foreach ($p in @($cfg.Port, $cfg.RestPort)) {
            $owner = Get-PortOwner $p
            if ($owner) {
                Write-Host ("    Port {0} held by PID {1} ({2})" -f $p, $owner.Pid, $owner.Name) -ForegroundColor Yellow
            }
        }
        Write-Host "  FIX:   Get-Process ovms | Stop-Process -Force   (or kill the offending PID above)" -ForegroundColor Cyan
        $diagnosed = $true
    }

    if ($allOutput -match 'm_element_type\.is_static') {
        Write-Host "`n  CAUSE: Device crash — typically AUTO/GPU on an incompatible iGPU." -ForegroundColor Red
        Write-Host "  FIX:   .\serve.ps1 -Device CPU" -ForegroundColor Cyan
        $diagnosed = $true
    }

    if ($allOutput -match 'has no field named|protobuf.*parse|Couldn''t parse plugin config') {
        Write-Host "`n  CAUSE: Invalid graph.pbtxt — protobuf rejected a field." -ForegroundColor Red
        Write-Host "  FIX:   Check graph.pbtxt for unknown LLMCalculatorOptions fields" -ForegroundColor Cyan
        Write-Host "         (e.g. max_output_tokens is NOT valid; use max_num_batched_tokens)" -ForegroundColor Cyan
        $diagnosed = $true
    }

    if ($allOutput -match 'CUDA out of memory|bad_alloc|Failed to allocate|out of memory') {
        Write-Host "`n  CAUSE: Out of memory (likely KV cache during model load)." -ForegroundColor Red
        Write-Host "  FIX:   Lower -ContextLength, or set -CacheSize to a smaller value" -ForegroundColor Cyan
        $diagnosed = $true
    }

    if ($allOutput -match 'No such file or directory|Failed to open|does not exist') {
        Write-Host "`n  CAUSE: Missing file — model path or graph.pbtxt not found." -ForegroundColor Red
        Write-Host ("  CHECK: ModelPath = {0}" -f $ModelPath) -ForegroundColor Cyan
        $diagnosed = $true
    }

    if (-not $diagnosed) {
        Write-Host "`n  No known failure pattern matched. Last lines of OVMS output:" -ForegroundColor Yellow
        $recentLines | Select-Object -Last 15 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
    Write-Host ""
}
