# Stoplight Changelog

## [Initial Version] - {PR_MERGE_DATE}

- Show Pull Requests: every PR's own light (needs you, waiting, ready, merged) plus Comments, Review, CI, Merge and Queue columns
- Reads the running Stoplight app's snapshot; falls back to the GitHub CLI
- Enter opens a details page per PR: live CI with each job's step and the log lines behind a failure, the merge queue, and the conversation with unresolved threads first
- Cmd+Enter reviews it in Stoplight
- Set-up rows install or start Stoplight, and help install and sign in to the GitHub CLI
- Stacked PRs sit under their parent, like Stoplight's panel
