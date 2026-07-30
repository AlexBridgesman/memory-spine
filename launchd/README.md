# launchd jobs (macOS, optional)

Render a template with your home directory and load it:

```bash
sed "s|__HOME__|$HOME|g" ai.spine.sync.plist.template > ~/Library/LaunchAgents/ai.spine.sync.plist
launchctl load ~/Library/LaunchAgents/ai.spine.sync.plist
```

- `ai.spine.sync` — commits vault changes every 5 minutes, regenerates indexes/packets, flushes the notification dead-letter queue.
- `ai.spine.backup` — nightly local bare-mirror backup + optional external volume copy (see `config/backup.conf.example`).
- `ai.spine.digest` — morning summary to your push channel (see `config/notify.conf.example`).

On Linux, run the same binaries from cron or systemd timers.
