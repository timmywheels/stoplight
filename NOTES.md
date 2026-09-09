A bug fix and a nicer stack copy.

### Fixed
- **PRs no longer vanish for a refresh.** GitHub's search index is eventually consistent: a query that returned seven of your PRs a minute ago can return one, with no error and plenty of rate limit left. Anything that disappears from search is now re-checked by exact ref — a lookup that doesn't touch the search index — and put back when it's still open. Genuinely closed or merged PRs drop as before.

### Stacks
- **Copy stack as Markdown is flat**, so it pastes cleanly into a comment or a message instead of carrying its indentation.
- **No CI icons in the copy.** A pasted list outlives the run it described, and a green dot that has since gone red is worse than no dot.
- New setting, Display → Popover → **Copy a stack starting from**: the bottom of the stack (the PR merging into trunk) or the top.
