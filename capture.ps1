#Requires -Version 7
<#
.SYNOPSIS
    HTTP capture proxy — saves every request body to disk, forwards to OVMS.

.DESCRIPTION
    Listens on ListenPort, saves the full JSON request body to a timestamped
    file under SaveDir, then proxies the request to OVMS on TargetPort.
    Handles streaming/SSE responses correctly so VS Code works normally.

.EXAMPLE
    .\capture.ps1 -ListenPort 19003 -TargetPort 19001 -SaveDir d:\tools\ovms\captures
#>
param(
    [int]    $ListenPort = 19003,
    [int]    $TargetPort = 19001,
    [string] $SaveDir    = (Join-Path $PSScriptRoot 'captures')
)

New-Item -ItemType Directory -Force -Path $SaveDir | Out-Null

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://+:$ListenPort/")
$listener.Start()

Write-Host "Capture proxy: :$ListenPort → OVMS :$TargetPort"
Write-Host "Saving bodies to: $SaveDir`n"

$idx = 0
try {
    while ($true) {
        $ctx  = $listener.GetContext()
        $req  = $ctx.Request
        $resp = $ctx.Response

        # ── Read full request body ──────────────────────────────────────────────
        $bodyMem = [System.IO.MemoryStream]::new()
        $req.InputStream.CopyTo($bodyMem)
        $bodyBytes = $bodyMem.ToArray()
        $bodyStr   = [System.Text.Encoding]::UTF8.GetString($bodyBytes)

        # ── Save to disk ────────────────────────────────────────────────────────
        $idx++
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $file  = Join-Path $SaveDir "request-$stamp-$idx.json"
        $bodyStr | Set-Content $file -Encoding UTF8

        # Quick summary for the console (avoid printing 24K tokens)
        $summary = try {
            $parsed = $bodyStr | ConvertFrom-Json
            $msgs   = $parsed.messages
            $last   = if ($msgs) { $msgs[-1] } else { $null }
            $role   = if ($last)  { $last.role } else { '?' }
            $text   = if ($last.content -is [string]) { $last.content } else { '[structured]' }
            $short  = if ($text.Length -gt 80) { $text.Substring(0, 80) + '…' } else { $text }
            "model=$($parsed.model)  msgs=$($msgs.Count)  last=[$role] $short"
        } catch { "(non-JSON or parse error)" }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $($req.HttpMethod) $($req.RawUrl)  $($bodyBytes.Length) bytes" -ForegroundColor Cyan
        Write-Host "  $summary" -ForegroundColor DarkCyan
        Write-Host "  → $file"

        # ── Forward to OVMS, stream response back ───────────────────────────────
        try {
            $fwd                  = [System.Net.HttpWebRequest]::CreateHttp("http://localhost:$TargetPort$($req.RawUrl)")
            $fwd.Method           = $req.HttpMethod
            $fwd.ContentType      = $req.ContentType
            $fwd.Timeout          = 600000
            $fwd.ReadWriteTimeout = 600000
            $fwd.AllowAutoRedirect = $false

            foreach ($h in $req.Headers.AllKeys) {
                if ($h -in @('Content-Type','Content-Length','Host','Connection',
                             'Accept-Encoding','Transfer-Encoding')) { continue }
                try { $fwd.Headers[$h] = $req.Headers[$h] } catch {}
            }

            if ($bodyBytes.Length -gt 0) {
                $fwd.ContentLength = $bodyBytes.Length
                $ws = $fwd.GetRequestStream()
                $ws.Write($bodyBytes, 0, $bodyBytes.Length)
                $ws.Close()
            }

            $fwdResp = $fwd.GetResponse()
            $resp.StatusCode    = [int]$fwdResp.StatusCode
            $resp.ContentType   = $fwdResp.ContentType
            $resp.SendChunked   = $true   # required for SSE passthrough
            foreach ($h in $fwdResp.Headers.AllKeys) {
                if ($h -in @('Content-Length','Transfer-Encoding','Connection')) { continue }
                try { $resp.AddHeader($h, $fwdResp.Headers[$h]) } catch {}
            }
            $fwdResp.GetResponseStream().CopyTo($resp.OutputStream)
            $fwdResp.Close()
            Write-Host "  ✓ $([int]$fwdResp.StatusCode)" -ForegroundColor Green
        } catch [System.Net.WebException] {
            $we = $_.Exception
            if ($we.Response) {
                $resp.StatusCode = [int]$we.Response.StatusCode
                $we.Response.GetResponseStream().CopyTo($resp.OutputStream)
                $we.Response.Close()
            } else {
                $resp.StatusCode = 502
                $eb = [System.Text.Encoding]::UTF8.GetBytes($we.Message)
                $resp.OutputStream.Write($eb, 0, $eb.Length)
            }
            Write-Host "  ✗ forward error: $($we.Message)" -ForegroundColor Red
        } finally {
            try { $resp.OutputStream.Flush(); $resp.OutputStream.Close() } catch {}
        }
    }
} finally {
    $listener.Stop()
    Write-Host "Capture proxy stopped."
}
