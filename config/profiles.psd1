@{
    DefaultProfile = 'MTP 104K'
    ProfileOrder = @('MTP 104K', 'MTP 112K')
    Host = '127.0.0.1'
    Port = 8080
    HealthPath = '/health'
    StartupTimeoutSeconds = 180
    StopTimeoutSeconds = 8
    PollIntervalMilliseconds = 2000

    LlamaServerPath = ''

    Profiles = @{
        'MTP 104K' = @(
            '-hf', 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL',

            '-c', '106496',
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
            '-lv', '4',

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

        'MTP 112K' = @(
            '-hf', 'unsloth/Qwen3.8-27B-GGUF:UD-Q3_K_XL',

            '-c', '114688',
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
