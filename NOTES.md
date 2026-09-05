Signed and notarized by Apple. On 0.2.1 or later, the **Update** button in the popover footer does the rest.

## Install or update

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/timmywheels/stoplight/main/install.sh)"
```

## What's new

- **Follow branches.** Settings → Sources → Branches: `owner/repo@main` shows the latest CI verdict on that branch and notifies when it goes red. Patterns like `owner/repo@rc/*` follow whichever release branch has the newest commit, add a section of PRs targeting it, and notify when a new one is cut.
- **Merged rows show branch health.** Each merged PR gets a `⑂ main` badge colored by the base branch's current CI. A merge only alerts while it's red and the branch is still red.
- **Move and pin the panel.** Drag the handle at the top, pin it open from the footer or the dots' right-click menu, reset position and size from the same menu. The panel shrinks to fit collapsed sections.
- **Keyboard:** Tab cycles the buttons in an expanded PR, ↩ presses one. ⌘K opens the Actions run summary.
- **Widget taps** open Stoplight on that PR, expanding its section.
- Responsive footer, agent icon, description capping, Escape handling in text fields, and a dozen smaller fixes.
