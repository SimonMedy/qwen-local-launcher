# Qwen Local Launcher

A native-feeling Windows system-tray launcher for running Qwen locally with `llama.cpp` / `llama-server`, focused on long-context coding-agent workloads, multimodal support, controllable GPU/CPU offload, and runtime monitoring.

> Unofficial community project. Not affiliated with Qwen/Alibaba, Unsloth, or llama.cpp.

## Current target

The launcher targets `unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL` and uses MTP exclusively. `MTP SPEED` is the default benchmarked speed/context profile. `MTP QUALITY 160K` prioritizes maximum quality and context while retaining the same speculative decoding recipe.

### Included profiles

| Profile | Context | KV cache | Fit target | Batch / ubatch |
| --- | ---: | --- | ---: | --- |
| MTP SPEED | 73,728 | K `q5_1`, V `q4_0` | 128 | 1024 / 512 |
| MTP QUALITY 160K | 163,840 | K `q8_0`, V `q4_0` | 128 | 1024 / 512 |

Both profiles use `-ngl auto`, Flash Attention, `--image-min-tokens 1024`, `--no-mmproj-offload`, `-np 1`, `--cache-ram 4096`, `--ctx-checkpoints 64`, `-t 8`, `-tb 16`, `-lv 4`, and `--reasoning-preserve`.

Both also use the same speculative recipe: `--spec-type draft-mtp,ngram-mod`, draft max `3`, p-min `0.75`, draft K/V `q4_0`, and ngram-mod `match 24 / min 8 / max 32`.

Sampling defaults are `--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --presence-penalty 0.0 --repeat-penalty 1.0`.

The launcher adds `--host 127.0.0.1`, `--port 8080`, and `--metrics` at runtime rather than duplicating network arguments inside each profile.

`--cache-reuse` is intentionally not used because llama.cpp disables cache reuse when multimodal is active.

## Launcher features

- Native Windows notification-area icon with `Stopped`, `Starting`, `Running`, and `Error` states.
- Manual first-run selection of `llama-server.exe`; no filesystem scanning.
- Selected executable validation with `--version` and `--list-devices`.
- Start, stop, restart, profile switching, Web UI, logs, Runtime diagnostics, startup toggle, About, and Quit actions.
- Hidden `llama-server.exe` process with stdout/stderr logs per run.
- `/health` polling and crash detection.
- `/metrics` and `/slots` monitoring.
- Windows Job Object plus forced fallbacks for process-tree teardown.
- Single-instance mutex.
- Optional tray-only Start-with-Windows shortcut.
- User-local configuration kept out of Git.

## Runtime diagnostics

`Runtime diagnostics` combines live Windows counters with llama.cpp's own endpoints and startup logs. It can expose process memory, dedicated/shared GPU memory, system RAM/commit, requested/runtime context, batch/ubatch, GPU/CPU model buffers, KV cache, compute/output buffers, GPU layer offload, mmproj backend, and speculative/MTP metrics when the corresponding data is emitted by llama.cpp.

`-lv 4` remains enabled on both profiles because Runtime diagnostics derives detailed allocation/offload information from llama.cpp startup logs. Missing startup-log data is shown as `not captured in current log` rather than a misleading zero.

Raw per-run stderr logs remain the source of truth under `logs\*.stderr.log`, and the tray maintains `logs\latest-runtime-summary.txt` for tuning-relevant lines.

## Requirements

- Windows 10/11.
- Windows PowerShell 5.1 or newer.
- A recent `llama.cpp` build containing `llama-server.exe` and the backend you want to use.
- Enough VRAM/RAM for the model, KV cache, context, and MTP state.

## Setup

1. Download/extract the `llama.cpp` build you want to use.
2. Double-click `setup.cmd`.
3. Select that build's `llama-server.exe`.
4. The launcher validates the executable and detected devices.
5. Save the selection; it is stored in ignored `config\local.psd1`.
6. The launcher executable is built to `dist\Qwen Local Launcher.exe`; Desktop and Start Menu shortcuts are created.
7. Use the tray to start the selected profile.

Run `setup.cmd` again whenever you want to switch llama.cpp builds.

## Tray behavior

Double-click opens the llama.cpp Web UI while running; when stopped it starts the selected profile.

Stopping first requests a graceful process-tree termination. The launcher then uses its Windows Job Object and forced process termination fallbacks if anything survives. `Quit` also stops the server before removing the tray icon.

## Configuration

Edit shared defaults in `config/profiles.psd1`. Machine-specific settings belong in ignored `config/local.psd1`.

The launcher adds `--host`, `--port`, and `--metrics` itself. Keep model/runtime arguments in each profile.

## Benchmark roadmap

Useful comparisons include context pressure, speculative acceptance rate, VRAM/RAM, prompt-processing tok/s, generation tok/s, TTFT, actual GPU layer offload, and multimodal stability.

## Development

Static validation runs on `windows-latest` in GitHub Actions:

```powershell
.\scripts\check.ps1
```

The check parses the PowerShell scripts, validates both MTP profiles argument-for-argument, smoke-tests the custom popup, exercises the diagnostics parser, and builds the Windows launcher.

## Safety / privacy

The launcher does not require an API key of its own and does not store credentials. Model downloads performed by llama.cpp follow llama.cpp/Hugging Face behavior. Keep private paths and any future credentials in ignored local configuration rather than committed files.
