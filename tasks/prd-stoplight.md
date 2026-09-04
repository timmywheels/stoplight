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
- [ ] Implemented with SwiftUI `MenuBarExtra` (macOS 14+), `.menuBarExtraStyle(.window)`
- [ ] Icon is three horizontal 6pt dots (red, yellow, green). Each is lit when at least one non-draft PR is in that state, dim gray otherwise. All dim when signed out or no PRs
- [ ] When the list transitions into all-green, the green dot pops once (~0.4s), then holds still. No looping animation in the menu bar
- [ ] Icon respects the menu bar's light/dark appearance (template image for gray state, tinted for others)
- [ ] Optional count badge next to icon: number of non-green PRs (off by default, toggle in Settings)
- [ ] Draft PRs are shown in the list but excluded from the icon's aggregate
- [ ] Verified visually in both light and dark menu bars

### US-005: Dropdown list
**Description:** As a user, I want to click the icon and see every PR with its status, and jump to any one of them.

**Acceptance Criteria:**
- [ ] Popover width 360pt, max height 480pt, scrolls beyond that
- [ ] Each row: 8pt status dot, `owner/repo #123` in secondary color, title on one line truncated with ellipsis, relative time ("4m ago") right-aligned
- [ ] Rows sorted: `failure` first, then `pending`, then `success`, then `none`; within a group, most recently updated first
- [ ] Draft PRs show a "Draft" tag and a hollow dot
- [ ] Clicking a row opens the PR URL in the default browser and closes the popover
- [ ] Rows in `failure` state have a disclosure chevron; expanding lists each failing check by name, clicking one opens its `detailsUrl`
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
- [ ] **Medium widget:** up to 4 PR rows in the same style as the dropdown (dot, repo #num, title). Tapping a row deep-links to that PR URL
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
- [ ] Right-click any PR row → "Hide owner/repo"
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
- [ ] Popover sections, in order: Pinned, Mine, Watching, then one section per followed item titled with the user's GitHub display name (fallback `@username`), `owner/repo`, or `org`. A PR appears once, in the first section that claims it
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

- Popover sections, top to bottom: Pinned, Mine, Watching, then followed sources. Headers are 11pt small-caps secondary text, only render when the section has rows, and are omitted entirely when Mine is the only section
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
- **Persistence:** `prs.json` written by the unsandboxed app directly into the widget's sandbox container (`~/Library/Containers/<widget id>/Data/Library/Application Support/Stoplight/`). App Groups need the group in the provisioning profile, which Personal teams and ad-hoc builds can't get, and macOS 15 denies the sandboxed widget otherwise. The App Group path is kept as a secondary location. No Core Data, no SwiftData
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
