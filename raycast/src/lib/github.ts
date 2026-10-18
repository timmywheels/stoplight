import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { promisify } from "node:util";
import {
  CheckResult,
  CheckState,
  MergeState,
  PRStatus,
  PullRequest,
  ReviewDecision,
  Snapshot,
  sortWorstFirst,
} from "./model";

const run = promisify(execFile);

const GH_CANDIDATES = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"];

export function findGh(preferred?: string, candidates: string[] = GH_CANDIDATES): string | undefined {
  return (preferred ? [preferred, ...candidates] : candidates).find((path) => existsSync(path));
}

const COMMIT_CHECKS = `
fragment CommitChecks on Commit {
  statusCheckRollup {
    contexts(last: 100) {
      nodes {
        __typename
        ... on CheckRun { name status conclusion detailsUrl startedAt completedAt checkSuite { workflowRun { workflow { name } } } }
        ... on StatusContext { context state targetUrl createdAt }
      }
    }
  }
}`;

const PR_FIELDS = `
fragment PRFields on PullRequest {
  id number title url isDraft state updatedAt headRefOid bodyText headRefName baseRefName mergedAt
  author { login }
  mergeQueueEntry { position state }
  mergeStateStatus reviewDecision
  repository { nameWithOwner }
  mergeCommit { ...CommitChecks }
  commits(last: 1) { nodes { commit { ...CommitChecks } } }
}`;

export function searchQuery(mergedSince: string): string {
  return `query {
  mine: search(query: "is:pr is:open archived:false author:@me", type: ISSUE, first: 50) { nodes { ... on PullRequest { ...PRFields } } }
  merged: search(query: "is:pr is:merged author:@me merged:>=${mergedSince} sort:updated-desc", type: ISSUE, first: 50) { nodes { ... on PullRequest { ...PRFields } } }
}
${PR_FIELDS}
${COMMIT_CHECKS}`;
}

interface Context {
  __typename: string;
  name?: string;
  status?: string;
  conclusion?: string | null;
  detailsUrl?: string | null;
  startedAt?: string | null;
  completedAt?: string | null;
  checkSuite?: { workflowRun?: { workflow?: { name?: string } | null } | null } | null;
  context?: string;
  state?: string;
  targetUrl?: string | null;
  createdAt?: string | null;
}

interface Commit {
  statusCheckRollup?: { contexts: { nodes: Context[] } } | null;
}

export interface PRNode {
  id?: string;
  number?: number;
  title?: string;
  url?: string;
  isDraft?: boolean;
  state?: string;
  updatedAt?: string;
  headRefOid?: string;
  bodyText?: string;
  headRefName?: string;
  baseRefName?: string;
  mergedAt?: string | null;
  author?: { login: string } | null;
  mergeQueueEntry?: { position?: number | null; state?: string | null } | null;
  mergeStateStatus?: string | null;
  reviewDecision?: string | null;
  repository?: { nameWithOwner: string };
  mergeCommit?: Commit | null;
  commits?: { nodes: { commit: Commit }[] };
}

export function checkRunState(status?: string, conclusion?: string | null): CheckState {
  if (status !== "COMPLETED") return "pending";
  switch (conclusion) {
    case "SUCCESS":
      return "success";
    case "NEUTRAL":
    case "SKIPPED":
      return "skipped";
    case "FAILURE":
    case "TIMED_OUT":
    case "CANCELLED":
    case "ACTION_REQUIRED":
    case "STARTUP_FAILURE":
    case "STALE":
      return "failure";
    default:
      return "pending";
  }
}

export function statusContextState(state?: string): CheckState {
  if (state === "SUCCESS") return "success";
  if (state === "FAILURE" || state === "ERROR") return "failure";
  return "pending";
}

/** A re-run leaves its failed predecessor on the commit: keep only the newest run per workflow and name. */
export function checksOf(commit?: Commit | null): CheckResult[] {
  const newest = new Map<string, { check: CheckResult; at: number }>();
  for (const c of commit?.statusCheckRollup?.contexts.nodes ?? []) {
    const check: CheckResult | undefined =
      c.__typename === "CheckRun" && c.name
        ? { name: c.name, state: checkRunState(c.status, c.conclusion), url: c.detailsUrl }
        : c.__typename === "StatusContext" && c.context
          ? { name: c.context, state: statusContextState(c.state), url: c.targetUrl }
          : undefined;
    if (!check) continue;
    const key = `${c.checkSuite?.workflowRun?.workflow?.name ?? ""}\u0001${check.name}`;
    const stamp = c.completedAt ?? c.startedAt ?? c.createdAt;
    const at = stamp ? Date.parse(stamp) : -Infinity;
    const current = newest.get(key);
    if (!current || at >= current.at) newest.set(key, { check, at });
  }
  return [...newest.values()].map((entry) => entry.check);
}

const MERGE_STATES: Record<string, MergeState> = {
  CLEAN: "clean",
  DIRTY: "conflicting",
  BEHIND: "behind",
  BLOCKED: "blocked",
  UNSTABLE: "unstable",
  HAS_HOOKS: "unstable",
  DRAFT: "draft",
};

const REVIEWS: Record<string, ReviewDecision> = {
  APPROVED: "approved",
  CHANGES_REQUESTED: "changesRequested",
  REVIEW_REQUIRED: "reviewRequired",
};

export function summarize(body?: string): string {
  if (!body) return "";
  const collapsed = body
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .join("\n");
  return collapsed.length > 300 ? `${collapsed.slice(0, 300).trim()}…` : collapsed;
}

export function mapNode(node: PRNode): PullRequest | undefined {
  if (!node.id || !node.number || !node.title || !node.url || !node.repository || !node.headRefOid) return undefined;
  const status: PRStatus = node.state === "MERGED" ? "merged" : node.state === "CLOSED" ? "closed" : "open";
  const commit = status === "merged" ? node.mergeCommit : node.commits?.nodes[0]?.commit;
  return {
    id: node.id,
    repo: node.repository.nameWithOwner,
    number: node.number,
    title: node.title,
    url: node.url,
    isDraft: node.isDraft ?? false,
    updatedAt: node.updatedAt ?? new Date(0).toISOString(),
    headSha: node.headRefOid,
    checks: checksOf(commit),
    author: node.author?.login ?? "ghost",
    status,
    summary: summarize(node.bodyText),
    headRefName: node.headRefName ?? "",
    baseRefName: node.baseRefName ?? "",
    mergeQueue: node.mergeQueueEntry
      ? { position: node.mergeQueueEntry.position ?? 0, state: node.mergeQueueEntry.state ?? "QUEUED" }
      : null,
    mergeState: MERGE_STATES[node.mergeStateStatus ?? ""] ?? "unknown",
    mergedAt: node.mergedAt ?? null,
    review: REVIEWS[node.reviewDecision ?? ""] ?? "none",
  };
}

interface SearchResponse {
  data?: { mine?: { nodes: PRNode[] }; merged?: { nodes: PRNode[] } };
  errors?: { message: string }[];
}

/** The same two searches Stoplight runs by default, shaped like its snapshot. */
export function snapshotFromResponse(response: SearchResponse, now: Date = new Date()): Snapshot {
  if (!response.data) throw new Error(response.errors?.[0]?.message ?? "GitHub returned no data");
  const mine = sortWorstFirst((response.data.mine?.nodes ?? []).flatMap((n) => mapNode(n) ?? []));
  const merged = (response.data.merged?.nodes ?? []).flatMap((n) => mapNode(n) ?? []);
  const sections = [
    { id: "Mine", title: "My PRs", prIDs: mine.map((pr) => pr.id) },
    { id: "Merged", title: "Merged", prIDs: merged.map((pr) => pr.id) },
  ].filter((section) => section.prIDs.length > 0);
  return { writtenAt: now.toISOString(), prs: [...mine, ...merged], pinnedIDs: [], sections };
}

export function utcDay(daysAgo: number, now: Date = new Date()): string {
  return new Date(now.getTime() - daysAgo * 86_400_000).toISOString().slice(0, 10);
}

export async function fetchViaGh(gh: string): Promise<Snapshot> {
  const args = ["api", "graphql", "-f", `query=${searchQuery(utcDay(1))}`];
  let stdout: string;
  try {
    ({ stdout } = await run(gh, args, { maxBuffer: 32 * 1024 * 1024, timeout: 20_000 }));
  } catch (error) {
    // gh exits non-zero on partial GraphQL errors (an SSO-protected org) but still prints the data it got.
    const partial = (error as { stdout?: string }).stdout;
    if (!partial?.includes('"data"')) throw error;
    stdout = partial;
  }
  return snapshotFromResponse(JSON.parse(stdout) as SearchResponse);
}
