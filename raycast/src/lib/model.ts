export type CIState = "failure" | "pending" | "success" | "none";
export type CheckState = "success" | "failure" | "pending" | "skipped";
export type PRStatus = "open" | "merged" | "closed";
export type MergeState = "clean" | "conflicting" | "behind" | "blocked" | "unstable" | "draft" | "unknown";
export type ReviewDecision = "approved" | "changesRequested" | "reviewRequired" | "none";

export interface CheckResult {
  name: string;
  state: CheckState;
  url?: string | null;
}

export interface MergeQueueInfo {
  position: number;
  state: string;
}

export interface PullRequest {
  id: string;
  repo: string;
  number: number;
  title: string;
  url: string;
  isDraft: boolean;
  updatedAt: string;
  headSha: string;
  checks: CheckResult[];
  author: string;
  status: PRStatus;
  summary: string;
  headRefName: string;
  baseRefName: string;
  mergeQueue?: MergeQueueInfo | null;
  mergeState: MergeState;
  mergedAt?: string | null;
  note?: string | null;
  baseState?: CIState | null;
  review: ReviewDecision;
  /** Stoplight only: the latest reviews and comments, newest last. */
  activity?: SnapshotActivity[];
}

export interface SnapshotActivity {
  id: string;
  kind: "approved" | "changesRequested" | "reviewed" | "comment";
  author: string;
  isBot: boolean;
  body: string;
  at: string;
  url: string;
}

export interface Section {
  id: string;
  title: string;
  prIDs: string[];
}

export type ColorProfile = "default" | "deuteranopia";

export interface Snapshot {
  writtenAt: string;
  prs: PullRequest[];
  pinnedIDs: string[];
  sections: Section[];
  colorProfile?: ColorProfile;
}

export type Source = "stoplight" | "gh";

export interface LoadedPRs {
  snapshot: Snapshot;
  source: Source;
}

export interface Row {
  key: string;
  section: Section;
  pr: PullRequest;
}

const rank: Record<CIState, number> = { failure: 0, pending: 1, success: 2, none: 3 };

export function rollup(checks: CheckResult[]): CIState {
  if (checks.length === 0) return "none";
  if (checks.some((c) => c.state === "failure")) return "failure";
  if (checks.some((c) => c.state === "pending")) return "pending";
  return checks.some((c) => c.state === "success") ? "success" : "none";
}

export const ciState = (pr: PullRequest): CIState => rollup(pr.checks);

export const isUnresolvedMerge = (pr: PullRequest): boolean =>
  pr.status === "merged" && ciState(pr) === "failure" && pr.baseState === "failure";

/** Same rule as Stoplight: conflicts count as red, merged PRs are red only while the base branch still is. */
export function effectiveState(pr: PullRequest): CIState {
  if (pr.status === "open" && pr.mergeState === "conflicting") return "failure";
  if (pr.status !== "merged") return ciState(pr);
  if (pr.baseState == null) return ciState(pr);
  return isUnresolvedMerge(pr) ? "failure" : "none";
}

export const isBranch = (pr: PullRequest): boolean => pr.number === 0;

export const shortRef = (pr: PullRequest): string =>
  isBranch(pr) ? `${pr.repo} @ ${pr.headRefName}` : `${pr.repo} #${pr.number}`;

export const checksURL = (pr: PullRequest): string => `${pr.url.replace(/\/$/, "")}/checks`;

export function queueURL(pr: PullRequest): string | undefined {
  if (!pr.mergeQueue || !pr.baseRefName) return undefined;
  return `https://github.com/${pr.repo}/queue/${pr.baseRefName}`;
}

/** The Actions run behind the first failing check, else the first check that has one. */
export function actionsRunURL(pr: PullRequest): string | undefined {
  const failing = pr.checks.filter((c) => c.state === "failure");
  for (const check of [...failing, ...pr.checks]) {
    const match = check.url?.match(/^(.*\/actions\/runs\/\d+)/);
    if (match) return match[1];
  }
  return undefined;
}

const trunks = new Set(["main", "master", "develop", "dev", "trunk", "release"]);

export const hasNonTrunkBase = (pr: PullRequest): boolean =>
  pr.baseRefName !== "" && !trunks.has(pr.baseRefName.toLowerCase());

/** stoplight://pr/<node id> opens the PR in Stoplight's review window. */
export function reviewURL(pr: PullRequest): string {
  return `stoplight://pr/${encodeURIComponent(pr.id)}`;
}

/** HTML link for Slack/Notion plus Markdown as the plain-text fallback, like Stoplight's Share. */
export function shareLink(pr: PullRequest): { html: string; text: string } {
  const escaped = pr.title.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return { html: `<a href="${pr.url}">${escaped}</a>`, text: `[${pr.title}](${pr.url})` };
}

/** Worst state first, then most recently updated. */
export function sortWorstFirst(prs: PullRequest[]): PullRequest[] {
  return [...prs].sort((a, b) => {
    const byState = rank[ciState(a)] - rank[ciState(b)];
    return byState !== 0 ? byState : Date.parse(b.updatedAt) - Date.parse(a.updatedAt);
  });
}

/** Rows in Stoplight's panel order: its sections as written, or worst-first when it wrote none. */
export function orderedRows(snapshot: Snapshot): Row[] {
  const byID = new Map(snapshot.prs.map((pr) => [pr.id, pr]));
  if (snapshot.sections.length === 0) {
    const all: Section = { id: "All", title: "Pull Requests", prIDs: [] };
    const pinned = new Set(snapshot.pinnedIDs);
    const sorted = [
      ...sortWorstFirst(snapshot.prs.filter((pr) => pinned.has(pr.id))),
      ...sortWorstFirst(snapshot.prs.filter((pr) => !pinned.has(pr.id))),
    ];
    return sorted.map((pr) => ({ key: `${all.id}:${pr.id}`, section: all, pr }));
  }
  return snapshot.sections.flatMap((section) =>
    section.prIDs.flatMap((id) => {
      const pr = byID.get(id);
      return pr ? [{ key: `${section.id}:${pr.id}`, section, pr }] : [];
    }),
  );
}

export type Filter = "all" | CIState;

export function countByState(prs: PullRequest[]): Record<CIState, number> {
  const counts: Record<CIState, number> = { failure: 0, pending: 0, success: 0, none: 0 };
  const seen = new Set<string>();
  for (const pr of prs) {
    if (seen.has(pr.id)) continue;
    seen.add(pr.id);
    counts[effectiveState(pr)] += 1;
  }
  return counts;
}

export function compactAgo(iso: string, now: number = Date.now()): string {
  const seconds = Math.max(0, Math.round((now - Date.parse(iso)) / 1000));
  if (seconds < 60) return "now";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days}d`;
  return `${Math.floor(days / 7)}w`;
}

export const isStale = (snapshot: Snapshot, now: number = Date.now()): boolean =>
  now - Date.parse(snapshot.writtenAt) > 5 * 60 * 1000;
