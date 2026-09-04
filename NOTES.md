Signed and notarized by Apple. Download, open, done.

## Install or update

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/timmywheels/stoplight/main/install.sh)"
```

From this version on, Stoplight updates itself: an **Update to X** button appears in the popover footer and in Settings when a new release is out.

## What's new

- **Built-in updater.** Checks every 6 hours, downloads the notarized zip, verifies it with Gatekeeper, swaps the app, relaunches.
- **Hide individual PRs.** Right-click → Hide this PR. Reversible in Settings → Sources → Hide. Hidden PRs drop off once merged.
- **Hide repo** moved to Settings only; too easy to hit by accident from a row.
- **Open merge queue** on right-click for a queued PR.
- **Hover toolbar:** open, copy URL, share. Share pastes the PR title as a hyperlink in Slack, Markdown in GitHub.
- **Status filters** with counts in the footer; **legend** in Settings; nicknames; description on right-click.
- Version string now reports correctly (0.2.0 showed as 1.0).
