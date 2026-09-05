Signed and notarized by Apple. If you're on 0.2.1, the **Update to 0.3.0** button in the popover footer does the rest.

## Install or update

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/timmywheels/stoplight/main/install.sh)"
```

## What's new

- **A real window.** The popover is a resizable panel: drag any edge, size is remembered. ⌥⌘S opens it from anywhere.
- **Expanding rows.** Double-click (or ⌘-click) a PR to see its description, which checks failed, and circular buttons: open, Actions run summary, copy URL, share, pin, fix. Single click opens the PR on GitHub. Hover for quick copy and share.
- **Fix with your agent.** Settings → Agent: pick Claude Code, Codex, Gemini CLI, Aider, or a custom command, plus your terminal. One click on a red PR checks out the branch in a fresh worktree, opens the terminal there, and starts the agent with the failure already explained.
- **Keyboard everything.** ↑↓ ↩ Space, Tab through the buttons, ⌘C/⇧⌘C/⌘B/⌘P/⌘F/⌘H/⌘K on the selected PR, ⌘1/2/3 filters. ⌘/ shows the sheet.
- **Merged section.** Your PRs merged in the last 24 hours (or 7 days, or off). When checks run on the merge commit, their status shows there and a failure lights the dots and notifies.
- **Sections.** Drag headers to reorder, click to collapse; collapsed headers show per-state counts.
- **Widgets mirror the popover.** Same sections, same order; new large size; clicking a row opens Stoplight on that PR.
- **Hide individual PRs**, reversible in Settings; hidden PRs drop off once merged.
- **Guided tour** on first run, replayable from Settings or right-click on the dots. Right-click also has Keyboard Shortcuts, Open at Login, Quit.
- **Built-in updater.**
