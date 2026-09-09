Settings got a rebuild, the panel got a refresh button, and the agent can now find clones anywhere on disk.

### Settings
- **Four tabs**: General, Display, Sources, Agent. Bulky things fold away; long explanations moved into section footers.
- **ⓘ buttons** on every setting whose name can't carry its meaning. Hover for a tooltip, click for a popover.
- **Legend** is a real table — glyph, name, meaning — instead of a centered wall of text.
- **Sources** is two lists instead of six: one **Following** (users, orgs, repos, branches, watched PRs) and one **Hidden**, each row tagged with what it is. Add through a single menu.
- **About** section with a link to the repo and a proper Quit row.

### Panel
- **Refresh button** in the footer, beside Settings, with a native spinner while it works.
- **Last refresh** now reads `9s` and sits next to that button, ticking on its own.
- **Expand/collapse all** moved off the top bar into the section header's right-click menu.

### New settings
- **Check GitHub**: automatic, or every 30s / 1m / 2m / 5m / 15m. Any choice still speeds up while checks run and backs off near the rate limit.
- **Clicking a PR**: open it on GitHub, or expand it. The other action moves to double-click.

### Agent
- **Multiple scan folders.** Projects rarely live under one tree, so add as many as you keep them in.
- The clone map folds behind a count, with a filter and Forget All.
- Prompt placeholders are listed in the section footer, visible without expanding anything.
- Sparkles replaced with `cpu` for the agent, a wrench for Fix.
