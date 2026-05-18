#Requires -Version 7
<#
.SYNOPSIS
    Replay a captured request body against OVMS and print the response.

.EXAMPLE
    .\test-request.ps1                                      # replay latest capture
    .\test-request.ps1 captures\request-20260515-153301-1.json
    .\test-request.ps1 -Port 19001 -Stream
#>
param(
    [string] $RequestFile,
    [int]    $Port   = 19001,
    [switch] $Stream
)

$OvmsDir = $PSScriptRoot

# Default to the most recently modified capture file
if (-not $RequestFile) {
    $captureDir = Join-Path $OvmsDir 'captures'
    $latest = Get-ChildItem $captureDir -Filter 'request-*.json' -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { Write-Error "No captures found in $captureDir. Run .\serve.ps1 -CaptureRequests first."; return }
    $RequestFile = $latest.FullName
    Write-Host "Using latest capture: $RequestFile`n" -ForegroundColor Cyan
}

$body = Get-Content $RequestFile -Raw -Encoding UTF8

# Show summary
try {
    $parsed = $body | ConvertFrom-Json
    $msgs   = $parsed.messages
    Write-Host "Model   : $($parsed.model)"
    Write-Host "Messages: $($msgs.Count)"
    Write-Host "Stream  : $($parsed.stream)"
    Write-Host "MaxTok  : $($parsed.max_tokens)"
    if ($parsed.tools) { Write-Host "Tools   : $($parsed.tools.Count) defined" }
    $last = $msgs[-1]
    $text = if ($last.content -is [string]) { $last.content } else { ($last.content | ConvertTo-Json -Compress) }
    Write-Host "Last msg: [$($last.role)] $(if ($text.Length -gt 200) { $text.Substring(0,200)+'…' } else { $text })`n"
} catch {
    Write-Host "(could not parse as JSON — replaying raw)`n" -ForegroundColor Yellow
}

$uri = "http://localhost:$Port/v3/chat/completions"
Write-Host "POST $uri`n" -ForegroundColor DarkGray

if ($Stream) {
    # Stream mode: print SSE chunks as they arrive
    $req                  = [System.Net.HttpWebRequest]::CreateHttp($uri)
    $req.Method           = 'POST'
    $req.ContentType      = 'application/json'
    $req.Timeout          = 600000
    $req.ReadWriteTimeout = 600000
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    $req.ContentLength = $bodyBytes.Length
    $ws = $req.GetRequestStream()
    $ws.Write($bodyBytes, 0, $bodyBytes.Length)
    $ws.Close()

    $resp   = $req.GetResponse()
    $reader = [System.IO.StreamReader]::new($resp.GetResponseStream())
    $tokens = 0
    while (-not $reader.EndOfStream) {
        $line = $reader.ReadLine()
        if ($line -match '^data: (.+)$' -and $Matches[1] -ne '[DONE]') {
            try {
                $chunk = $Matches[1] | ConvertFrom-Json
                $delta = $chunk.choices[0].delta.content
                if ($delta) { Write-Host $delta -NoNewline; $tokens++ }
            } catch {}
        } elseif ($line -eq 'data: [DONE]') {
            Write-Host "`n`n[DONE] ($tokens chunks)" -ForegroundColor Green
        }
    }
    $reader.Close(); $resp.Close()
} else {
    # Non-stream: force stream:false, collect full response
    $obj = $body | ConvertFrom-Json -AsHashtable
    $obj['stream'] = $false
    $replayBody = $obj | ConvertTo-Json -Depth 10 -Compress

    try {
        $result = Invoke-RestMethod -Uri $uri -Method POST -ContentType 'application/json' `
                    -Body $replayBody -TimeoutSec 600
        Write-Host "Response:" -ForegroundColor Green
        Write-Host ($result | ConvertTo-Json -Depth 10)
    } catch {
        Write-Host "Request failed: $_" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
    }
}
