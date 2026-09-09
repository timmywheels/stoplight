Merge queues.

### Queue sections
When a PR you can see is waiting in a merge queue, that queue gets its own section: what's ahead of it, in order, and whether the front is failing.

Nothing to configure. A queue belongs to a base branch, and orgs queue into `rc/2026-09`, `develop`, whatever they like — so Stoplight reads the branch off the PR itself. Change release branches and the section follows.

- Your own entries are tagged **yours**, and stay in their usual section too, so the positions still read correctly.
- Queue rows never light the menu bar or notify you. They're other people's PRs.
- Sources → Options: turn queues off, or change how many entries each one lists (1–25, default 10).

### Merge queue button
An expanded PR that's queued gets a **≡** button that opens its queue on GitHub, with its position in the tooltip.
