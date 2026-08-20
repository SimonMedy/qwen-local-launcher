@{
    DefaultProfile = 'MTP SPEED'
    ProfileOrder = @('MTP SPEED', 'MTP QUALITY 160K')
    Host = '127.0.0.1'
    Port = 8080
    HealthPath = '/health'
    StartupTimeoutSeconds = 180
    StopTimeoutSeconds = 8
    PollIntervalMilliseconds = 2000

    LlamaServerPath = ''

    Profiles = @{
        'MTP SPEED' = @(
            '-hf', 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL',

            '-c', '73728',
            '-ngl', 'auto',

            '--cache-type-k', 'q5_1',
            '--cache-type-v', 'q4_0',
            '--fit-target', '128',

            '--flash-attn', 'on',
            '--image-min-tokens', '1024',
            '--no-mmproj-offload',
            '-np', '1',

            '-b', '1024',
            '-ub', '512',

            '--cache-ram', '4096',
            '--ctx-checkpoints', '64',
            '-t', '8',
            '-tb', '16',
            '-lv', '4',

            '--spec-type', 'draft-mtp,ngram-mod',
            '--spec-draft-n-max', '3',
            '--spec-draft-p-min', '0.75',
            '--spec-draft-type-k', 'q4_0',
            '--spec-draft-type-v', 'q4_0',

            '--spec-ngram-mod-n-match', '24',
            '--spec-ngram-mod-n-min', '8',
            '--spec-ngram-mod-n-max', '32',

            '--reasoning-preserve',
            '--temp', '1.0',
            '--top-p', '0.95',
            '--top-k', '20',
            '--min-p', '0.0',
            '--presence-penalty', '0.0',
            '--repeat-penalty', '1.0'
        )

        'MTP QUALITY 160K' = @(
            '-hf', 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL',

            '-c', '163840',
            '-ngl', 'auto',

            '--cache-type-k', 'q8_0',
            '--cache-type-v', 'q4_0',
            '--fit-target', '128',

            '--flash-attn', 'on',
            '--image-min-tokens', '1024',
            '--no-mmproj-offload',
            '-np', '1',

            '-b', '1024',
            '-ub', '512',

            '--cache-ram', '4096',
            '--ctx-checkpoints', '64',
            '-t', '8',
            '-tb', '16',
            '-lv', '4',

            '--spec-type', 'draft-mtp,ngram-mod',
            '--spec-draft-n-max', '3',
            '--spec-draft-p-min', '0.75',
            '--spec-draft-type-k', 'q4_0',
            '--spec-draft-type-v', 'q4_0',

            '--spec-ngram-mod-n-match', '24',
            '--spec-ngram-mod-n-min', '8',
            '--spec-ngram-mod-n-max', '32',

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
