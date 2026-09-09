The merge queue gets its own tab, and PRs show where they stand with reviewers.

### Queue tab
The queue no longer sits among your own PRs. When a queue exists, a **PRs / Queue** switch appears; `⌃⇥` moves between them, and nothing changes when there's no queue to show.

- **Real queue order.** Entries were being regrouped by state and recency, which is exactly what you don't want when position is the information. Queue sections now keep GitHub's order.
- **Position always shows**, including for blocked entries, which previously reported none. `≡ Queue 3`, or the same number with a red glyph when that entry is blocking everything behind it.

### Review state
Every PR shows where it stands with reviewers, as a glyph rather than a word: a green seal for approved, a red bubble for changes requested, a dashed circle when review is still required.

Notifications follow: changes requested tells you in both modes, approval when notifications are set to everything.

### Fixed
- **Adversarial review reused the fix session.** Sessions were keyed by PR alone, so ⇧⌘F focused the window ⌘F had opened. Fixing and reviewing now get their own windows.
- **`can't change option: zle` appearing as a git error.** An interactive login shell complains in a non-tty, and that noise was being captured as command output.
