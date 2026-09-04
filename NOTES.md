**Signed and notarized by Apple.** Download, open, done. No "Open Anyway", no Xcode, works on managed Macs.

## Install

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/timmywheels/stoplight/main/install.sh)"
```

Or download `Stoplight-0.2.0.dmg` below and drag to Applications. macOS 14+.

## What's new since 0.1.0

- **Sources.** Follow users, repos, or orgs from Settings; each gets its own section. Hide users (bots by default) and repos.
- **Stacks.** PRs based on another visible PR's branch render as a stack. Right-click to copy the whole stack as Markdown.
- **Merge queue.** "Queue #n" tag, and a notification if a PR gets kicked out.
- **Hover toolbar.** Open, copy URL, share. Share pastes as a hyperlink in Slack and Markdown in GitHub.
- **Nicknames** for PRs, labels for followed users, collapsible sections, status filters in the footer, a legend in Settings.
- **Widget works.** It fetches from the running app over loopback; no permission prompts.
- Optional dark housing behind the menu bar dots.
