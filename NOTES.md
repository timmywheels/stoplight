Queue rows say what's actually happening, with less on screen.

- **The dots were showing the wrong checks.** A queued PR's own checks passed before it was enqueued; the queue is testing a *merge group* — your branch combined with everything ahead of it. Queue rows now read the merge group's checks, so an entry whose merge-group run is still going shows yellow instead of a stale green.
- **Position moved to the gutter.** The `Queue 7` badge is gone: the number sits to the left of the dot, and turns red when that entry is what everything behind it is waiting on.
- **No approval seal on queue rows.** A PR in the queue is approved by definition.
- **The queue section links to its queue** on GitHub, from a small arrow in the header.
- **The PRs / Queue switch shrank** to two glyphs in the top bar beside the pin, with the active one in the accent colour. `⌃⇥` still switches.
