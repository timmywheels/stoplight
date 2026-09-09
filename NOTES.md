Signed and notarized by Apple. The **Update** button in the popover footer does the rest.

## Install or update

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/timmywheels/stoplight/main/install.sh)"
```

**Heads up:** this release is stricter about what counts as green, so expect fewer green dots and some new red ones. Both changes are things Stoplight was previously getting wrong.

## What's new

- **Merge state is accounted for.** Rows now tag **Conflicts**, **Behind**, or **Blocked**, and an open PR with conflicts counts as red whatever CI says, since nothing else can happen until it's fixed. This was invisible before.
- **A skipped check no longer counts as a pass on its own.** If every check on a PR was skipped, nothing actually ran, so it shows gray instead of green. Skipped still counts toward green alongside a real pass.
- Tidier GitHub CLI row in Settings → General → Account: the resolved path with a Choose… button, instead of a field, a button and a duplicate line.
