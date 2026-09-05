# PRD: Stoplight

macOS menu bar app + widget that shows CI status for your open pull requests. Nothing else.

## Introduction

Checking whether CI passed means opening a browser tab, finding the PR, scrolling to the checks box, and repeating every few minutes. Stoplight puts that answer in the menu bar and on the desktop. One glance: green, yellow, or red.

**v1 scope:** GitHub only. PRs you authored. Read-only. Native Swift.

## Goals

- Answer "is my CI green?" in under one second, without opening a browser
- Zero-config sign-in for anyone who already uses the `gh` CLI
- Notify on the two state changes that matter: a PR turns red, or a PR turns fully green
- Stay under 30 MB RAM and invisible in Activity Monitor CPU
- Ship a provider abstraction so GitLab or review-requested PRs can be added without a rewrite

## Naming

App name: **Stoplight**. The menu bar glyph is three horizontal dots, red / yellow / green. A dot is lit when at least one PR is in that state, dim otherwise. Bundle id: `com.timwheeler.stoplight`.

## User Stories

### US-001: Sign in via `gh` token
**Description:** As a dev who already uses `gh`, I want Stoplight to work the moment I launch it.

**Acceptance Criteria:**
- [ ] On launch, app runs `gh auth token` (searching `/opt/homebrew/bin`, `/usr/local/bin`, `$PATH`) and uses the output as a bearer token held in memory only
- [ ] Token is never written to disk, UserDefaults, or the widget's shared container
- [ ] If `gh` is missing or not logged in, the dropdown shows "Sign in" with two options: "Run `gh auth login`" (copies command) and "Paste a token"
- [ ] Pasted token is stored in Keychain (`kSecClassGenericPassword`, service `com.timwheeler.stoplight`), never logged
- [ ] Token validity confirmed with a `viewer { login }` GraphQL call; failure shows a red "Auth failed" row, not a crash
- [ ] Build passes, no warnings

### US-002: Fetch authored PRs and their check status
**Description:** As a user, I want an accurate list of my open PRs with a single rolled-up CI status each.

**Acceptance Criteria:**
- [ ] One GraphQL query: `search(query: "is:pr is:open author:@me", type: ISSUE, first: 50)` returning repo name, number, title, url, `isDraft`, `updatedAt`, `headRefOid`, and `commits(last:1) { nodes { commit { statusCheckRollup { state, contexts(first:100) { ... on CheckRun { name conclusion status detailsUrl } ... on StatusContext { context state targetUrl } } } } } }`
- [ ] Rollup mapped to exactly four states: `failure` (any check FAILURE/ERROR/TIMED_OUT/CANCELLED/ACTION_REQUIRED), `pending` (any check queued or in progress), `success` (all completed and none failed), `none` (no checks configured)
- [ ] `SKIPPED` and `NEUTRAL` conclusions count as success
- [ ] Failing checks are extracted into a list of (name, url) for display
- [ ] Rate limit headers are read; if remaining < 100, polling backs off to 5 minutes
- [ ] Network errors keep the last good data on screen and show a small "stale, retrying" label with the age
- [ ] Unit tests cover the rollup mapping for all four states plus the SKIPPED/NEUTRAL case

### US-003: Polling
**Description:** As a user, I want status to be fresh without hammering the API.

**Acceptance Criteria:**
- [ ] Poll every 60 seconds by default
- [ ] Poll every 20 seconds while any PR is `pending`
- [ ] Poll every 5 minutes when there are zero open PRs
- [ ] Manual refresh via dropdown item and ⌘R while dropdown is open
- [ ] Polling pauses when the Mac sleeps and fires immediately on wake
- [ ] Fetch runs off the main thread; UI never blocks

### US-004: Menu bar icon
**Description:** As a user, I want the icon alone to tell me the worst state across all my PRs.

**Acceptance Criteria:**
- [ ] Status item is an `NSStatusItem`; the drop-down is a non-activating, resizable `NSPanel` hosting the SwiftUI view. `MenuBarExtra` was dropped: its window can't resize and sizes to the view's ideal height
- [ ] Icon is three horizontal 6pt dots (red, yellow, green). Each is lit when at least one non-draft PR is in that state, dim gray otherwise. All dim when signed out or no PRs
- [ ] When the list transitions into all-green, the green dot pops once (~0.4s), then holds still. No looping animation in the menu bar
- [ ] Icon respects the menu bar's light/dark appearance (template image for gray state, tinted for others)
- [ ] Optional count badge next to icon: number of non-green PRs (off by default, toggle in Settings)
- [ ] Draft PRs are shown in the list but excluded from the icon's aggregate
- [ ] Verified visually in both light and dark menu bars

### US-005: Dropdown list
**Description:** As a user, I want to click the icon and see every PR with its status, and jump to any one of them.

**Acceptance Criteria:**
- [ ] Panel opens under the dots, right edges aligned, default 380×520, resizable by dragging any edge or corner (min 320×240), size remembered across launches; list scrolls to fill
- [ ] Panel closes on click outside, Escape, or clicking the dots again
- [ ] Each row: 8pt status dot, `owner/repo #123` in secondary color, title on one line truncated with ellipsis, relative time ("4m ago") right-aligned
- [ ] Rows sorted: `failure` first, then `pending`, then `success`, then `none`; within a group, most recently updated first
- [ ] Draft PRs show a "Draft" tag and a hollow dot
- [ ] Clicking a row opens the PR URL in the default browser and closes the popover
- [ ] Expanding a `failure` row (US-021) lists each failing check by name; clicking one opens its `detailsUrl`
- [ ] Empty state: "No open PRs" centered, gray
- [ ] Footer: last-refreshed time, Refresh (⌘R), Settings (⌘,), Quit (⌘Q)
- [ ] Entire UI uses system fonts and semantic colors, no custom typography
- [ ] Verified visually in light and dark mode

### US-006: Notifications
**Description:** As a user, I want to be told when a PR flips to red or to fully green, and nothing else.

**Acceptance Criteria:**
- [ ] Request `UNUserNotificationCenter` authorization on first launch, after the first successful fetch, not before
- [ ] Notify when a PR's rolled-up state transitions to `failure` from any other state. Title: repo #number. Body: PR title plus first failing check name
- [ ] Notify when a PR transitions to `success` from `pending`. Title: repo #number. Body: "All checks passed"
- [ ] No notification for `pending`, `none`, new PRs discovered already-green, or draft PRs
- [ ] One notification per (PR, headRefOid, state). A new push resets dedupe
- [ ] Clicking a notification opens the PR URL
- [ ] Notifications can be disabled entirely or set to "fail only" in Settings
- [ ] Unit test covers the transition table

### US-007: Desktop widget
**Description:** As a user, I want the same status on my desktop or Notification Center without clicking anything.

**Acceptance Criteria:**
- [ ] WidgetKit extension in the same Xcode project, sharing an App Group (`group.com.timwheeler.stoplight`)
- [ ] Main app writes `prs.json` (list of PRs with state, no token) to the App Group container after every fetch, then calls `WidgetCenter.shared.reloadAllTimelines()`
- [ ] Widget reads `prs.json` only; it never makes network calls
- [ ] **Small widget:** three stacked counts with colored dots: red count, yellow count, green count. Tapping opens the app's popover
- [ ] **Medium widget:** up to 4 PR rows mirroring the popover (sections, order, dot, repo #num, title). **Large:** 12 rows. Tapping a row deep-links to that PR URL
- [ ] Both sizes show "Open Stoplight to sign in" when `prs.json` is absent
- [ ] Small widget shows the stoplight silhouette in the aggregate color above the three counts
- [ ] Both sizes show data age in the corner if older than 5 minutes
- [ ] Widget renders correctly in light, dark, and tinted/vibrant modes (macOS 14 desktop widgets)
- [ ] Verified visually by adding both sizes to the desktop

### US-008: Settings
**Description:** As a user, I want a tiny settings window with only what matters.

**Acceptance Criteria:**
- [ ] Standard macOS `Settings` scene, one pane, fixed width 400pt
- [ ] Controls, in order: Account (shows `@username`, source "gh CLI" or "Token", Sign out button), Notifications (All / Fail only / Off), Show count in menu bar (toggle), Launch at login (toggle, via `SMAppService`)
- [ ] No other settings in v1
- [ ] Sign out clears Keychain token if present and shows the Sign in state

### US-009: Provider abstraction
**Description:** As the developer, I want GitLab or review-requested PRs to be an additive change later.

**Acceptance Criteria:**
- [ ] `protocol CIProvider { func fetchPullRequests() async throws -> [PullRequest] }`
- [ ] `GitHubProvider` is the only implementation
- [ ] `PullRequest` and `CheckResult` models are provider-neutral (no GitHub-specific field names leak into the UI layer)
- [ ] `PRQuery` enum with a single case `.authored` in v1; the GitHub search string is derived from it, so adding `.reviewRequested` is a one-line change plus a UI section

### US-010: Hide repos and bots
**Description:** As a user, I want to silence the two things that pollute a broad list, a noisy repo and bot PRs, without a second config system.

**Acceptance Criteria:**
- [ ] Settings → Sources → Hide has a Users table (pre-filled with dependabot[bot], renovate[bot], github-actions[bot]) and a Repos table
- [ ] All Sources tables use the System Settings pattern: bordered list, + adds an editable row committed on Return, − removes the selection, Delete key also removes
- [ ] Right-click any PR row → "Hide this PR". Hiding a whole repo is deliberately Settings-only
- [ ] Settings → Sources → Hide lists hidden PRs (`owner/repo#123 title`) with a remove button; a hidden PR is dropped from the list automatically once it merges or closes
- [ ] Hidden users and repos are excluded from the list, the dots, the widget, and notifications
- [ ] Matching is case-insensitive
- [ ] Persisted inside the `sources` JSON blob; the old `hiddenRepos` list migrates once
- [ ] Filtering happens in one place (`Filters.visible(_:ignore:)`) so all four surfaces agree
- [ ] No Ignore lists for users or orgs: everything beyond Mine is opt-in, so there is nothing to opt out of

### US-011: Watch someone else's PR
**Description:** As a user, I want to watch a teammate's PR (or any PR by URL) so I know when its CI settles.

**Acceptance Criteria:**
- [ ] Popover footer gains a "+" button (⌘N) that reveals a one-line field: paste a GitHub PR URL, press Return
- [ ] URL is parsed to owner/repo/number; anything else shows inline "Not a PR URL" and keeps the field open
- [ ] Watched PRs are fetched by `repository(owner:name:) { pullRequest(number:) }` in the same poll cycle, one batched GraphQL request using aliases
- [ ] Watched PRs appear in a "Watching" section below your own PRs, same row style, with the author's login in the secondary line (`owner/repo #123 · @author`)
- [ ] Watched PRs count toward the menu bar aggregate and fire notifications like your own
- [ ] Right-click a watched row → "Stop watching". A watched PR that is merged or closed shows a "Merged"/"Closed" tag for one poll cycle, then is auto-removed
- [ ] Watched list persists in UserDefaults as `[owner/repo#number]`
- [ ] `CIProvider` gains `fetchPullRequests(refs: [PRRef])`; `PRQuery` is unchanged

### US-012: Pin PRs
**Description:** As a user, I want to pin the two or three PRs I actually care about today so they sit at the top.

**Acceptance Criteria:**
- [ ] Right-click any row → "Pin" / "Unpin". Hovering a row also reveals a small pin glyph on the right that toggles pin state
- [ ] Pinned PRs render in a "Pinned" section at the very top, above "Mine" and "Watching", sorted worst-first within the section
- [ ] Pinned rows show a filled pin glyph; the section header is small-caps secondary text
- [ ] Pins persist in UserDefaults as `[PR id]`; a pin on a PR that disappears (merged/closed) is dropped silently
- [ ] Medium widget lists pinned PRs first, then the rest, still capped at 4
- [ ] No drag-and-drop. Right-click and the hover glyph are the only affordances (drag in a menu bar popover is fiddly and dismisses easily)
- [ ] Section headers only appear when the section is non-empty; with nothing pinned or watched the list looks exactly like v1

### US-013: Follow users, repos, orgs
**Description:** As a user, I want to follow teammates, key repos, or a whole org from Settings, so their open PRs show up grouped, without typing commands.

**Acceptance Criteria:**
- [ ] Settings → Sources → Follow has a list for each of Users, Repos, Orgs, same editor
- [ ] Each followed item adds one aliased `search` to the single poll request: `author:USER`, `repo:OWNER/NAME`, or `org:ORG` (50 PRs cap each)
- [ ] Popover sections, in order: Pinned, My PRs, Watching, then one section per followed item titled with the user's GitHub display name (fallback `@username`), `owner/repo`, or `org`. A PR appears once, in the first section that claims it
- [ ] Display names come from one `user(login:) { name }` request, fetched only when the followed-user set changes
- [ ] Settings → Follow → Users has a per-row Label field; a label overrides the GitHub name in the section header. Placeholder shows the GitHub name
- [ ] Followed PRs count toward the dots and fire notifications like your own
- [ ] Right-click a row by someone else → "Follow @username" shortcut; hidden repos, bot hiding, and pins apply to followed PRs too
- [ ] Rows by other people show `· @author` in the secondary line
- [ ] Editing Sources triggers an immediate refresh
- [ ] v1.1: "Add teammate" picker listing members of orgs you belong to (`viewer.organizations` → `membersWithRole`), requires `read:org`

### US-014: Menu bar housing
**Description:** As a user, I want an optional dark pill behind the dots so they read on any wallpaper.

**Acceptance Criteria:**
- [ ] Settings toggle "Dark housing behind the dots", off by default
- [ ] Housing is a 14pt-tall pill, dark gray, 4pt padding around the dots; unlit dots become white at 28% so they show on the pill
- [ ] Toggle takes effect immediately without restart

### US-015: Stacks
**Description:** As a user, I want stacked PRs shown as a stack, and a one-click way to share the whole stack.

**Acceptance Criteria:**
- [ ] A PR whose base branch equals another visible PR's head branch, in the same repo, is rendered directly under it, indented 14pt per level with a ↳ connector
- [ ] Stacks render bottom-up (closest to trunk first); a stack sorts by its worst state, so a red anywhere in it lifts the whole stack
- [ ] Right-click any PR in a stack → "Copy stack (N PRs) as Markdown": one line per PR, bottom-up, status emoji, link, title, branch
- [ ] A PR based on a non-trunk branch whose parent isn't visible shows an "on branch" tag
- [ ] Cycles or missing parents never drop a PR from the list
- [ ] Unit tests: three-level stack order and depth, cross-repo non-linking, red stack sorts first, cycle safety, markdown output

### US-016: Merge queue
**Description:** As a user, I want to see when a PR is in the merge queue and be told if it gets kicked out.

**Acceptance Criteria:**
- [ ] Rows show a "Queue #n" tag while `mergeQueueEntry` exists; "Queue: blocked" in red when its state is UNMERGEABLE
- [ ] Right-click a queued PR → "Open merge queue" (`github.com/owner/repo/queue/<base branch>`)
- [ ] Transition from in-queue to not-in-queue while still open posts a notification "Removed from the merge queue", time-sensitive with sound, in both non-off notification modes
- [ ] Entering the queue posts nothing
- [ ] Unit test covers the dequeued transition table

### US-017: One-click copy
**Description:** As a user, I want the PR link and branch name one click away.

**Acceptance Criteria:**
- [ ] Superseded by US-021: actions live in the expanded row
- [ ] The shared link carries two flavors on the pasteboard: HTML `<a>` (Slack, Notion, Docs paste a hyperlink) and Markdown `[title](url)` as plain text (GitHub, Linear). Link text is the PR title only
- [ ] The copy glyph turns into a green checkmark for one second
- [ ] Right-click menu has Share (rich link), Copy URL, Copy branch name, Copy stack as Markdown
- [ ] Description and real title (when nicknamed) are the title's tooltip

### US-018: Status filter and legend
**Description:** As a user, I want to narrow the list to red, yellow, or green, and a place that explains every symbol.

**Acceptance Criteria:**
- [ ] Footer, left side: three dots (red, yellow, green) each with its count across everything visible
- [ ] Click a dot to show only that state; click more to combine; click again to remove. No filter = show all
- [ ] Non-selected dots dim to 40% while a filter is active; selected dots get a capsule background
- [ ] Filter is session-only and applies to the popover list only, never to the menu bar dots, widget, or notifications
- [ ] Empty result shows "No PRs match the filter"
- [ ] Settings → General → Legend explains: four dot colors, hollow draft dot, stack connector, Queue tag, "on branch" tag, hover glyphs, footer filters

### US-019: Nicknames
**Description:** As a user, I want to give a PR a short name I recognize without touching the PR itself.

**Acceptance Criteria:**
- [ ] Right-click → "Show description" expands the row with the PR body (and the real title when nicknamed); "Nickname…" turns the title into an inline field; Return saves, Escape cancels, empty clears
- [ ] The nickname replaces the title in the row; the real title appears at the top of the ⓘ tooltip
- [ ] "Clear nickname" in the context menu when one is set
- [ ] Nicknames are keyed by PR id, stored in Sources, and dropped when the PR leaves the list
- [ ] Hover glyphs float over the trailing edge in a material capsule while hovering, so the title keeps the full row width when not hovered

### US-020: Built-in updates
**Description:** As a user, I want to update with one click instead of remembering a command.

**Acceptance Criteria:**
- [ ] The app checks GitHub Releases at launch and every 6 hours
- [ ] When a newer version exists: "Update to X" appears in the popover footer and in Settings → General
- [ ] Update: download the release zip, expand, `spctl --assess` it, confirm the bundle id matches, move the current bundle to Trash, move the new one into place, relaunch
- [ ] Any failed step aborts before touching the installed app and shows the reason in Settings
- [ ] Settings shows Up to date / Check Again / Retry states
- [ ] No third-party framework; loopback-free, no server beyond GitHub

### US-021: Expanding rows
**Description:** As a user, I want every action on a PR discoverable with one click, without a wall of buttons on every row.

**Acceptance Criteria:**
- [ ] Single click on a row expands it; one row is expanded at a time (accordion); clicking again collapses
- [ ] Double-click or ⌘-click opens the PR directly
- [ ] Settings → Popover → "Clicking a PR": Expands it (default) or Opens it; the other action moves to double-click / ⌘-click
- [ ] In Opens-it mode, hovering a row shows a floating toolbar: Copy URL, Share, and a chevron that expands the row
- [ ] Expansion shows, top to bottom: real title (if nicknamed), description (2 lines), failing checks as links, then four 32pt circular buttons: Open, Copy URL, Share, Pin
- [ ] Copy and Share flash a checkmark for one second
- [ ] Motion: a single 200ms snappy curve with no bounce; content fades and slides 8pt from under the header; nothing but row height moves
- [ ] Hovered or expanded rows get a faint background
- [ ] The hover toolbar and the failing-checks chevron are removed; rarer actions stay on right-click

### US-022: Recently merged
**Description:** As a user, I want to see what I shipped recently, and when checks run on the merge commit (CD on main), whether the deploy is green.

**Acceptance Criteria:**
- [ ] One extra aliased search per poll: `is:pr is:merged author:@me merged:>=<day>`; window is Off / 24h / 7d in Settings → Popover, default 24h
- [ ] "Merged" section at the bottom, collapsed by default; rows sorted red first then newest merge
- [ ] A merged PR's `checks` are the merge commit's checks, not the branch's
- [ ] Rows with no merge-commit checks show a purple checkmark instead of a dot and never count toward the dots, widget, or notifications
- [ ] Merged PRs with checks join `all`, so a red merge commit lights the red dot
- [ ] Notifications: merge commit turns red → "… failed after merge" (time-sensitive); pending → green → "Merged and green" in all-mode only; the open → merged transition itself never fires
- [ ] Hidden PRs stay hidden in the Merged section for the window's duration
- [ ] Unit tests cover the merged transition table and the query string format

### US-023: Section order and widget parity
**Description:** As a user, I want to arrange sections my way, and see the same list in the widget.

**Acceptance Criteria:**
- [ ] Drag a section header onto another to reorder; a 2pt accent line marks the drop target; order persists
- [ ] Snapshot carries the popover's sections (id, title, PR ids) in order; medium (4 rows) and large (12 rows) widgets render them with the same headers, dots, purple merged checkmark, and pins
- [ ] Small widget counts match the footer: merged rows without checks are excluded

## Functional Requirements

- FR-1: The app runs as a menu bar accessory only (`LSUIElement = true`), no Dock icon, no main window
- FR-2: The app authenticates with a GitHub token obtained from `gh auth token` or a user-pasted PAT stored in Keychain
- FR-3: The app fetches open PRs authored by the signed-in user via a single GitHub GraphQL query
- FR-4: Each PR is assigned exactly one state: `failure`, `pending`, `success`, or `none`
- FR-5: The menu bar icon color reflects the worst state across non-draft PRs
- FR-6: Clicking the icon shows a popover listing all PRs, sorted worst-first
- FR-7: Clicking a PR row opens it in the default browser
- FR-8: Failing PRs can be expanded to show individual failing checks, each clickable
- FR-9: The app polls at 60s, 20s when anything is pending, 5min when there are no PRs
- FR-10: The app posts a macOS notification when a PR transitions to `failure` or from `pending` to `success`
- FR-11: The app writes PR data to an App Group container and reloads widget timelines after each fetch
- FR-12: A WidgetKit extension provides small and medium widgets rendered from the shared data
- FR-13: Settings exposes account, notification mode, count badge, and launch at login only
- FR-14: All network and provider logic sits behind a `CIProvider` protocol
- FR-15: Users can hide users and repos; hidden PRs are excluded from every surface (list, dots, widget, notifications)
- FR-16: Users can watch any PR by URL; watched PRs are polled, listed under "Watching", and count toward the aggregate
- FR-16a: Users can follow users, repos, and orgs from Settings; their open PRs are polled in the same request and listed in their own sections
- FR-17: Users can pin PRs; pinned PRs are listed first under "Pinned" in the popover and the medium widget
- FR-18: Sources (follow/ignore lists), watched refs, and pins persist in UserDefaults and survive relaunch
- FR-19: PRs based on another visible PR's branch render as a stack; any stack can be copied as Markdown
- FR-20: Merge queue membership is shown per PR; leaving the queue while open triggers a notification

## Non-Goals

- No actions on PRs: no re-run, approve, merge, or comment
- No automatic review-requested PRs in v1 (watch them manually via US-011; auto-query planned for v1.1 behind `PRQuery`)
- No GitLab, Bitbucket, or non-GitHub CI providers in v1
- No multiple GitHub accounts or Enterprise Server hosts
- No drag-and-drop reordering
- No commit-level or branch-level status, PRs only
- No iOS, iPadOS, or Windows
- No analytics, telemetry, or crash reporting
- No custom themes, fonts, or icon packs
- No App Store distribution in v1 (Developer ID signed + notarized DMG only)

## Design Considerations

- Popover sections, top to bottom: Pinned, My PRs, Watching, then followed sources. Headers are 11pt small-caps secondary text, only render when the section has rows, and are omitted entirely when My PRs is the only section
- Naming: "Pin" not "Favorite". macOS uses Pin for Notes, Messages, and Safari tabs; Favorites is a Finder sidebar term
- Not "Traffic Light": on macOS that already means the window close/minimize/zoom buttons
- Not "Traffic Light": on macOS that already means the window close/minimize/zoom buttons

- Everything is system-native: SF Symbols, `.secondary` text color, system semantic colors for red/yellow/green (`.red`, `.yellow`, `.green`), default macOS spacing, system accent color (no custom accent)
- Status color is always paired with a shape cue (filled dot vs hollow dot for draft, chevron for expandable) so it works for colorblind users
- Popover has no title bar, no toolbar, no tabs. List plus footer
- Two animations only: the pending dot pulses gently, and the menu bar stoplight bobs once when everything turns green
- Menu bar glyph is 18×18pt, visually balanced against Wi-Fi and battery icons. Stoplight silhouette must read as a bird at that size, so no beak detail, no eye, just the head-crest-body outline

## Technical Considerations

- **Stack:** Swift 5.10+, SwiftUI, macOS 14 Sonoma minimum (needed for `MenuBarExtra` window style and desktop widgets)
- **Project layout:** one Xcode project, two targets: `Stoplight` (app) and `StoplightWidget` (widget extension), plus `StoplightCore` (Swift package with models, provider, rollup logic, so it's unit-testable and shared by both targets)
- **Networking:** `URLSession` + hand-written GraphQL string. No Apollo, no codegen. One query, one `Codable` response struct
- **App → widget channel:** the app serves the snapshot JSON on `127.0.0.1:47391`; the widget fetches it (sandbox `network.client`, no profile needed) and falls back to the App Group file. App Groups need the group in the provisioning profile, which Personal teams and ad-hoc builds can't get; writing into the widget's container trips the "access data from other apps" prompt. No Core Data, no SwiftData
- **Secrets:** token held in memory when from `gh`; Keychain when pasted. Never in the shared container
- **Sandbox:** app is sandboxed with `com.apple.security.network.client`. Running `gh` requires a `Process` call, which the sandbox blocks. Decision: ship v1 **unsandboxed** with hardened runtime and notarization. Revisit if App Store distribution becomes a goal, in which case the `gh` path is dropped
- **Login item:** `SMAppService.mainApp.register()`
- **Rate limit:** GraphQL costs roughly 1 point per query with 50 PRs and 100 checks each. 60s polling is 60 points/hour against a 5000 limit
- **Distribution:** `xcodebuild archive`, `notarytool`, `create-dmg`. Homebrew cask as a follow-up

## Success Metrics

- Cold launch to first status shown: under 2 seconds on a `gh`-authenticated machine
- Zero clicks from "is it green?" to answer (menu bar icon or widget)
- One click from "what failed?" to the failing check's log
- Idle memory under 30 MB, idle CPU under 0.1%
- No missed transitions: every red or green flip produces exactly one notification

## Open Questions

- Should the count badge default to on? Leaning off to keep the menu bar clean
- When a PR has checks from multiple workflows and one is still running while another failed, should the icon go red immediately? Spec says yes (failure wins). Confirm
- Does any target org use GitHub Enterprise Server? If so, host becomes a setting in v1.1
- Should merged or closed PRs linger in the list for a few minutes with a "Merged" tag, so you see the final state? Leaning no for v1
