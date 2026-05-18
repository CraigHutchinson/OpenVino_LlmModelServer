# OpenVINO LLM Model Server — Windows Helper Scripts

PowerShell scripts for running [OpenVINO Model Server (OVMS)](https://github.com/openvinotoolkit/model_server) as a local LLM endpoint on Windows, with VS Code Copilot / Continue integration.

Tested with: OVMS 2026.x weekly builds, Qwen3.6-27B-OV-INT4 via Intel AI Playground, Windows 11.

---

## Quick Start

### 1. Install OVMS binaries

```powershell
.\update.ps1
```

Downloads the latest OVMS weekly build from `storage.openvinotoolkit.org` and extracts it into
this directory. Run again to upgrade; your `serve-config.json` is preserved.

### 2. Install a model

Use [Intel AI Playground](https://github.com/intel/AI-Playground) to download a supported
OpenVINO model (e.g. Qwen3.6-27B-OV-INT4). The model will land under:

```
%LOCALAPPDATA%\Programs\AI Playground\resources\models\LLM\openvino\
```

### 3. Serve

```powershell
.\serve.ps1
```

On first run, `serve.ps1` auto-detects the installed model and writes `serve-config.json`. OVMS
starts on gRPC port 19000 and REST port 19001.

VS Code's `chatLanguageModels.json` is updated automatically so the model appears as a custom
endpoint named **Ovms**.

---

## serve.ps1 — Main Serve Script

```
.\serve.ps1 [-Device CPU|GPU|NPU|AUTO]
            [-ContextLength <tokens>]     # default 65536
            [-MaxOutputTokens <tokens>]   # default 8192 (VS Code display only)
            [-CacheSize <GB>]             # 0 = dynamic (default), >0 = fixed GB
            [-LogLevel INFO|DEBUG|...]
            [-LogFile <path>]
            [-Warmup] [-NoWarmup]         # pre-load model weights on startup
            [-NoTools]                    # disable tool calling (Ask-only, ~3K tokens vs ~22K)
            [-CaptureRequests]            # start HTTP capture proxy on RestPort+2
            [-ListDevices]                # list available compute devices and exit
            [-Reset]                      # wipe serve-config.json and start fresh
            [-ModelPath <path>]           # override auto-detected model directory
            [-ModelName <id>]             # override model id sent to OVMS
```

Config is persisted to `serve-config.json` — CLI flags update the saved values, so subsequent
`.\serve.ps1` invocations remember your last settings.

### Key notes

- **`cache_size: 0`** (dynamic KV cache) is required for VS Code Agent mode, which sends ~22K
  token prompts. A fixed 2 GB cache is exhausted on 27B models (~112 KB/token × 22K ≈ 2.4 GB).
- **`-NoTools`** sets `toolCalling: false` in VS Code's model config, cutting the prompt from
  ~22K tokens to ~3K tokens. Use when you only need conversational answers.
- **`-Warmup`** fires a 1-token request after OVMS becomes `AVAILABLE`, pre-loading model weights
  before the first real inference. Without warmup, the first VS Code request takes the cold-load
  penalty.
- **Device `AUTO`** selects GPU first and will crash on most consumer GPUs
  (`m_element_type.is_static()` assertion). Use `CPU` (default) unless you have a tested iGPU.

---

## capture.ps1 — HTTP Capture Proxy

```
.\capture.ps1 [-ListenPort 19003] [-TargetPort 19001] [-SaveDir d:\tools\ovms\captures]
```

Transparent HTTP proxy that saves every request body to a timestamped JSON file in `captures/`
and streams the OVMS response back to the caller. Useful for inspecting what VS Code sends.

Launched automatically by `serve.ps1 -CaptureRequests`.

> **Note:** OVMS also logs the full request body at `DEBUG` log level (line starting `servable:`),
> so `capture.ps1` is only needed when you want the raw file on disk.

---

## test-request.ps1 — Replay Captured Requests

```
.\test-request.ps1                                    # replay most recent capture
.\test-request.ps1 captures\request-20260515-153301-1.json
.\test-request.ps1 -Port 19001 -Stream                # SSE streaming output
```

Reads a captured request JSON, shows a summary (model, message count, tool count, last message
preview), and replays it against OVMS.

---

## update.ps1 — OVMS Updater

```
.\update.ps1                                          # download and install latest weekly build
.\update.ps1 -Restore ".\backup_20260515_143022"      # roll back to a previous backup
```

Fetches `ovms_windows_*_python_on.zip` from `storage.openvinotoolkit.org`, backs up the current
install, and extracts the new build in place. Scripts and `serve-config.json` are preserved.

---

## VS Code / Continue Integration

`serve.ps1` writes to:

```
%APPDATA%\Code - Insiders\User\chatLanguageModels.json
```

The endpoint appears as **Ovms** with a single model entry. Toggle between Agent mode (tool
calling, ~22K tokens/request) and Ask mode (no tools, ~3K tokens/request) with `-NoTools`.

### Token budget for a simple "hi" in Ask mode

| Section | Characters | ~Tokens |
|---|---|---|
| System prompt (persona + instructions + skills + mode) | 12,826 | 4,275 |
| User context (OS + workspace tree + memory) | 3,850 | 1,283 |
| User request + attachments | 1,431 | 477 |
| Tools × 19 (Ask mode) | 19,782 | 6,594 |
| **Total** | **~38K** | **~12.6K** |

Agent mode (66 tools) adds ~18K tokens on top of this. See
[vscode-request-analysis.md](vscode-request-analysis.md) for full breakdown.

---

## graph.pbtxt — LLM Settings

OVMS MediaPipe models are configured via `graph.pbtxt` inside the model directory, not via CLI
flags. `serve.ps1` rewrites the relevant fields on every start.

Valid `LLMCalculatorOptions` fields (as of OVMS 2026.1):

```
max_num_seqs: 256
device: "CPU"
models_path: "./"
plugin_config: '{"CACHE_DIR":"cache"}'
enable_prefix_caching: true
cache_size: 0
max_num_batched_tokens: 65536
reasoning_parser: "qwen3"
tool_parser: "hermes3"
```

> `max_output_tokens` is **not** a valid field — protobuf will reject it with a parse error.
