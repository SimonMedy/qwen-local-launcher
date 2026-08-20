@{
    DefaultProfile = 'Stable 160k'
    ProfileOrder = @('Stable 160k', 'MTP 160k', 'Stable 180k')
    Host = '127.0.0.1'
    Port = 8080
    HealthPath = '/health'
    StartupTimeoutSeconds = 180
    StopTimeoutSeconds = 8
    PollIntervalMilliseconds = 2000

    LlamaServerPath = ''

    Profiles = @{
        'Stable 160k' = @(
            '-hf', 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL',
            '-c', '160000',
            '-ngl', 'auto',
            '--cache-type-k', 'q8_0',
            '--cache-type-v', 'q4_0',
            '--flash-attn', 'on',
            '-np', '1',
            '--cache-reuse', '256',
            '--cache-ram', '4096',
            '-t', '8',
            '-tb', '16',
            '--temp', '1.0',
            '--top-p', '0.95',
            '--top-k', '20',
            '--min-p', '0.0',
            '--presence-penalty', '0.0',
            '--repeat-penalty', '1.0'
        )

        'MTP 160k' = @(
            '-hf', 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL',
            '-c', '160000',
            '-ngl', 'auto',
            '--cache-type-k', 'q8_0',
            '--cache-type-v', 'q4_0',
            '--flash-attn', 'on',
            '-np', '1',
            '--cache-reuse', '256',
            '--cache-ram', '4096',
            '-t', '8',
            '-tb', '16',
            '--spec-type', 'draft-mtp',
            '--spec-draft-n-max', '2',
            '--spec-draft-type-k', 'q4_0',
            '--spec-draft-type-v', 'q4_0',
            '--temp', '1.0',
            '--top-p', '0.95',
            '--top-k', '20',
            '--min-p', '0.0',
            '--presence-penalty', '0.0',
            '--repeat-penalty', '1.0'
        )

        'Stable 180k' = @(
            '-hf', 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL',
            '-c', '180000',
            '-ngl', 'auto',
            '--cache-type-k', 'q8_0',
            '--cache-type-v', 'q4_0',
            '--flash-attn', 'on',
            '-np', '1',
            '--cache-reuse', '256',
            '--cache-ram', '4096',
            '-t', '8',
            '-tb', '16',
            '--temp', '1.0',
            '--top-p', '0.95',
            '--top-k', '20',
            '--min-p', '0.0',
            '--presence-penalty', '0.0',
            '--repeat-penalty', '1.0'
        )
    }
}
