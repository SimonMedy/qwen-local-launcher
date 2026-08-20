@{
    DefaultProfile = 'Stable 160k'
    ProfileOrder = @('Stable 160k', 'MTP 128k')
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
            '--fit-ctx', '160000',
            '-ngl', 'auto',
            '--cache-type-k', 'q8_0',
            '--cache-type-v', 'q4_0',
            '--flash-attn', 'on',
            '--image-min-tokens', '1024',
            '--no-mmproj-offload',
            '-np', '1',
            '--cache-ram', '4096',
            '-b', '1024',
            '-ub', '128',
            '-t', '8',
            '-tb', '16',
            '--reasoning-preserve',
            '-lv', '4',
            '--temp', '1.0',
            '--top-p', '0.95',
            '--top-k', '20',
            '--min-p', '0.0',
            '--presence-penalty', '0.0',
            '--repeat-penalty', '1.0'
        )

        'MTP 128k' = @(
            '-hf', 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL',
            '-c', '131072',
            '--fit-ctx', '131072',
            '-ngl', 'auto',
            '--cache-type-k', 'q8_0',
            '--cache-type-v', 'q4_0',
            '--flash-attn', 'on',
            '--image-min-tokens', '1024',
            '--no-mmproj-offload',
            '-np', '1',
            '--cache-ram', '4096',
            '-b', '1024',
            '-ub', '128',
            '-t', '8',
            '-tb', '16',
            '--spec-type', 'draft-mtp',
            '--spec-draft-n-max', '2',
            '--spec-draft-type-k', 'q4_0',
            '--spec-draft-type-v', 'q4_0',
            '--reasoning-preserve',
            '-lv', '4',
            '--temp', '1.0',
            '--top-p', '0.95',
            '--top-k', '20',
            '--min-p', '0.0',
            '--presence-penalty', '0.0',
            '--repeat-penalty', '1.0'
        )
    }
}
