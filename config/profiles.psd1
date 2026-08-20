@{
    DefaultProfile = 'Stable 160k'
    ProfileOrder = @('Stable 160k', 'MTP Tuned')
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

            '-c', '50000',
            '-ngl', 'auto',

            '--cache-type-k', 'q8_0',
            '--cache-type-v', 'q4_0',
            '--flash-attn', 'on',

            '--image-min-tokens', '1024',
            '--no-mmproj-offload',

            '-np', '1',

            '--cache-ram', '2048',

            '-b', '1024',
            '-ub', '512',

            '-t', '8',
            '-tb', '16',

            '--reasoning-preserve',

            '--temp', '1.0',
            '--top-p', '0.95',
            '--top-k', '20',
            '--min-p', '0.0',
            '--presence-penalty', '0.0',
            '--repeat-penalty', '1.0'
        )

        'MTP Tuned' = @(
            '-hf', 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL',

            '-c', '50000',
            '-ngl', 'auto',
            '--fit-target', '512',

            '--cache-type-k', 'q5_1',
            '--cache-type-v', 'q5_1',
            '--flash-attn', 'on',

            '--image-min-tokens', '1024',
            '--no-mmproj-offload',

            '-np', '1',

            '-b', '1024',
            '-ub', '128',

            '--cache-ram', '2048',
            '--ctx-checkpoints', '64',

            '-t', '8',
            '-tb', '16',

            '--spec-type', 'draft-mtp,ngram-mod',
            '--spec-draft-n-max', '2',
            '--spec-draft-p-min', '0.82',

            '--spec-draft-type-k', 'q4_0',
            '--spec-draft-type-v', 'q4_0',

            '--spec-ngram-mod-n-match', '24',
            '--spec-ngram-mod-n-min', '48',
            '--spec-ngram-mod-n-max', '64',

            '--reasoning-preserve',

            '--temp', '1.0',
            '--top-p', '0.95',
            '--top-k', '20',
            '--min-p', '0.0',
            '--presence-penalty', '0.0',
            '--repeat-penalty', '1.0'
        )
    }
}
