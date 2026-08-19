@{
    DefaultProfile = 'Stable 160k'
    ProfileOrder = @('Stable 160k', 'MTP 160k', 'Stable 180k')
    Host = '127.0.0.1'
    Port = 8080
    HealthPath = '/health'
    StartupTimeoutSeconds = 180
    StopTimeoutSeconds = 8
    PollIntervalMilliseconds = 2000

    # Leave blank to auto-discover in this order:
    # QWEN_LLAMA_SERVER env var, .\llama.cpp\llama-server.exe, then PATH.
    LlamaServerPath = ''

    Profiles = @{
        'Stable 160k' = @(
            '-hf', 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL',
            '-c', '160000',
            '-ngl', 'auto',
            '--fit-target', '1536',
            '--cache-type-k', 'q8_0',
            '--cache-type-v', 'q4_0',
            '--flash-attn', 'on',
            '-np', '1',
            '--cache-reuse', '256',
            '-t', '8',
            '-tb', '16'
        )

        'MTP 160k' = @(
            '-hf', 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL',
            '-c', '160000',
            '-ngl', 'auto',
            '--fit-target', '1536',
            '--cache-type-k', 'q8_0',
            '--cache-type-v', 'q4_0',
            '--flash-attn', 'on',
            '-np', '1',
            '--cache-reuse', '256',
            '-t', '8',
            '-tb', '16',
            '--spec-type', 'draft-mtp',
            '--spec-draft-n-max', '2',
            '--spec-draft-p-min', '0.8'
        )

        'Stable 180k' = @(
            '-hf', 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL',
            '-c', '180000',
            '-ngl', 'auto',
            '--fit-target', '1536',
            '--cache-type-k', 'q8_0',
            '--cache-type-v', 'q4_0',
            '--flash-attn', 'on',
            '-np', '1',
            '--cache-reuse', '256',
            '-t', '8',
            '-tb', '16'
        )
    }
}
