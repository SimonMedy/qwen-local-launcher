# Qwen Local Launcher

A native-feeling Windows system-tray launcher for running Qwen locally with `llama.cpp` / `llama-server`, focused on long-context coding-agent workloads, multimodal support, controllable GPU/CPU offload, and easy profile switching.

> Unofficial community project. Not affiliated with Qwen/Alibaba, Unsloth, or llama.cpp.

## Current target

The default profiles target `unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL` with a 160k context window, plus experimental MTP and 180k variants. Multimodal support is intentionally preserved: no profile passes `--no-mmproj`.

### Included profiles

| Profile | Context | MTP | KV cache | Threads |
| --- | ---: | --- | --- | --- |
| Stable 160k | 160,000 | Off | K `q8_0`, V `q4_0` | `-t 8 -tb 16` |
| MTP 160k | 160,000 | `draft-mtp`, max 2, p-min 0.8 | K `q8_0`, V `q4_0` | `-t 8 -tb 16` |
| Stable 180k | 180,000 | Off | K `q8_0`, V `q4_0` | `-t 8 -tb 16` |

All profiles use `-ngl auto`, `--fit-target 1536`, Flash Attention, `-np 1`, and `--cache-reuse 256`.

## Launcher features

- Native Windows notification-area icon with `Stopped`, `Starting`, `Running`, and `Error` states.
- Start, stop, restart, profile switching, Web UI, logs, startup toggle, About, and Quit actions.
- Hidden `llama-server.exe` process with stdout/stderr logs per run.
- `/health` polling instead of assuming that a live PID means the model is ready.
- Crash detection with exit code and Windows balloon notification.
- Single-instance mutex.
- Optional Start-with-Windows shortcut.
- User-local configuration kept out of Git.

## Requirements

- Windows 10/11.
- Windows PowerShell 5.1 or newer.
- A recent `llama.cpp` build containing `llama-server.exe` and the backend you want to test (Vulkan or HIP/ROCm).
- Enough VRAM/RAM for the selected model, KV cache, context, and optional MTP state.

## Setup

1. Obtain a current Windows build of `llama.cpp` suitable for your GPU/backend.
2. Either place it at `llama.cpp\llama-server.exe`, add `llama-server.exe` to `PATH`, set `QWEN_LLAMA_SERVER`, or create `config\local.psd1` with an explicit path.
3. Double-click `scripts\launch-hidden.vbs`.
4. Right-click the tray icon and choose **Start**.

Example `config\local.psd1`:

```powershell
@{
    LlamaServerPath = 'D:\AI\llama.cpp\llama-server.exe'
}
```

`config/local.psd1`, logs, runtime state, GGUF files, and a repo-local `llama.cpp` directory are ignored by Git.

## Tray behavior

The status icon uses a simple native-drawn Q badge so the project does not need to ship binary icon assets:

- green: Running
- amber: Starting / health pending
- gray: Stopped
- red: Error

Double-click opens the llama.cpp Web UI while running; when stopped it starts the selected profile.

Stopping first asks Windows to terminate the process tree without `/F`, waits for the configured timeout, then falls back to a forced termination only if needed. `Quit` stops the server before removing the tray icon.

## Configuration

Edit shared defaults in `config/profiles.psd1`. For machine-specific settings, prefer the ignored `config/local.psd1`.

The launcher adds `--host` and `--port` itself. Keep model/runtime arguments in each profile.

Useful settings include:

```powershell
@{
    Host = '127.0.0.1'
    Port = 8080
    StartupTimeoutSeconds = 180
    StopTimeoutSeconds = 8
    PollIntervalMilliseconds = 2000
    LlamaServerPath = ''
}
```

## Benchmark roadmap

Planned comparisons for the target RX 9070 XT setup:

- Vulkan vs HIP/ROCm.
- Stable vs MTP.
- `-t 8` vs `-t 16`.
- `--cache-reuse 256` vs `512`.
- `-ub 256 / 512 / 1024`.
- 160k vs 180k context.
- VRAM/RAM, prompt processing tok/s, generation tok/s, TTFT, MTP acceptance rate, actual GPU layer offload, and multimodal stability.

The initial implementation deliberately keeps Stable 160k as the default and treats MTP as an opt-in profile until it has been benchmarked on the target machine.

## Development

Static validation runs on `windows-latest` in GitHub Actions:

```powershell
.\scripts\check.ps1
```

The check parses the PowerShell scripts and validates important profile invariants, including preserving multimodal support.

## Safety / privacy

The launcher does not require an API key of its own and does not store credentials. Model downloads performed by llama.cpp follow llama.cpp/Hugging Face behavior. Keep private paths and any future credentials in ignored local configuration rather than committed files.
