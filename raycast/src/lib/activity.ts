import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { PullRequest } from "./model";

const run = promisify(execFile);

export type ReviewState = "APPROVED" | "CHANGES_REQUESTED" | "COMMENTED" | "DISMISSED" | "PENDING";

/** What Stoplight's snapshot doesn't carry: unresolved threads, requested reviewers and the merge queue's history. */
export interface PRActivity {
  /** Comments and review comments from people other than the author. Bots don't count. */
  comments: number;
  commenters: string[];
  threads: number;
  unresolvedThreads: number;
  reviews: { login: string; state: ReviewState; at?: string }[];
  requested: string[];
  autoMerge: boolean;
  queue?: { position: number; state: string; enqueuedAt?: string };
  dropped?: { at: string; reason?: string };
}

export type ActivityMap = Record<string, PRActivity>;

interface Actor {
  login: string;
  __typename?: string;
}

interface QueueEvent {
  __typename: string;
  createdAt: string;
  reason?: string | null;
}

export interface ActivityNode {
  id: string;
  state?: string;
  author?: Actor | null;
  comments?: { nodes: { author?: Actor | null }[] };
  reviews?: { nodes: { state: ReviewState; author?: Actor | null; comments?: { totalCount: number } }[] };
  reviewThreads?: { nodes: { isResolved: boolean }[] };
  latestOpinionatedReviews?: { nodes: { state: ReviewState; submittedAt?: string | null; author?: Actor | null }[] };
  reviewRequests?: { nodes: { requestedReviewer?: { login?: string; name?: string } | null }[] };
  autoMergeRequest?: { enabledAt: string } | null;
  mergeQueueEntry?: { position?: number | null; state?: string | null; enqueuedAt?: string | null } | null;
  timelineItems?: { nodes: QueueEvent[] };
}

const PR_ID = /^PR_[A-Za-z0-9_-]+$/;

export function activityQuery(ids: string[]): string {
  const valid = ids.filter((id) => PR_ID.test(id));
  return `query {
  nodes(ids: ${JSON.stringify(valid)}) {
    ... on PullRequest {
      id state
      author { login __typename }
      comments(last: 50) { nodes { author { login __typename } } }
      reviews(last: 50) { nodes { state author { login __typename } comments { totalCount } } }
      reviewThreads(first: 100) { nodes { isResolved } }
      latestOpinionatedReviews(first: 20) { nodes { state submittedAt author { login __typename } } }
      reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } ... on Team { name } } } }
      autoMergeRequest { enabledAt }
      mergeQueueEntry { position state enqueuedAt }
      timelineItems(last: 10, itemTypes: [ADDED_TO_MERGE_QUEUE_EVENT, REMOVED_FROM_MERGE_QUEUE_EVENT]) {
        nodes { __typename ... on AddedToMergeQueueEvent { createdAt } ... on RemovedFromMergeQueueEvent { createdAt reason } }
      }
    }
  }
}`;
}

const isBot = (a?: Actor | null) => !a || a.__typename === "Bot" || a.login.endsWith("[bot]");

/** The PR is open, out of the queue, and the queue's last word on it was a removal. */
function droppedFromQueue(node: ActivityNode): PRActivity["dropped"] {
  if (node.state !== "OPEN" || node.mergeQueueEntry) return undefined;
  const events = node.timelineItems?.nodes ?? [];
  const last = events[events.length - 1];
  if (last?.__typename !== "RemovedFromMergeQueueEvent") return undefined;
  return { at: last.createdAt, reason: last.reason ?? undefined };
}

export function mapActivity(node: ActivityNode): PRActivity {
  const author = node.author?.login.toLowerCase();
  const fromOthers = (a?: Actor | null): a is Actor => !isBot(a) && a!.login.toLowerCase() !== author;
  const commenters = new Set<string>();
  let comments = 0;
  for (const c of node.comments?.nodes ?? []) {
    if (!fromOthers(c.author)) continue;
    comments += 1;
    commenters.add(c.author.login);
  }
  for (const r of node.reviews?.nodes ?? []) {
    if (!fromOthers(r.author)) continue;
    const count = Math.max(r.comments?.totalCount ?? 0, r.state === "COMMENTED" ? 1 : 0);
    comments += count;
    if (count > 0) commenters.add(r.author.login);
  }
  const threads = node.reviewThreads?.nodes ?? [];
  const entry = node.mergeQueueEntry;
  return {
    comments,
    commenters: [...commenters],
    threads: threads.length,
    unresolvedThreads: threads.filter((t) => !t.isResolved).length,
    reviews: (node.latestOpinionatedReviews?.nodes ?? [])
      .filter((r) => fromOthers(r.author))
      .map((r) => ({ login: r.author!.login, state: r.state, at: r.submittedAt ?? undefined })),
    requested: (node.reviewRequests?.nodes ?? []).flatMap(
      (r) => r.requestedReviewer?.login ?? r.requestedReviewer?.name ?? [],
    ),
    autoMerge: Boolean(node.autoMergeRequest),
    queue: entry
      ? { position: entry.position ?? 0, state: entry.state ?? "QUEUED", enqueuedAt: entry.enqueuedAt ?? undefined }
      : undefined,
    dropped: droppedFromQueue(node),
  };
}

/** Snapshot rows carry a "queue:" prefix for merge-queue copies of the same PR. */
export const nodeID = (rowID: string) => rowID.replace(/^queue:/, "");

export async function fetchActivity(gh: string, ids: string[]): Promise<ActivityMap> {
  const unique = [...new Set(ids.map(nodeID))].filter((id) => PR_ID.test(id));
  const out: ActivityMap = {};
  for (let i = 0; i < unique.length; i += 50) {
    const batch = unique.slice(i, i + 50);
    let stdout: string;
    try {
      ({ stdout } = await run(gh, ["api", "graphql", "-f", `query=${activityQuery(batch)}`], {
        maxBuffer: 32 * 1024 * 1024,
        timeout: 20_000,
      }));
    } catch (error) {
      const partial = (error as { stdout?: string }).stdout;
      if (!partial?.includes('"data"')) throw error;
      stdout = partial;
    }
    const nodes = (JSON.parse(stdout) as { data?: { nodes?: (ActivityNode | null)[] } }).data?.nodes ?? [];
    for (const node of nodes) if (node?.id) out[node.id] = mapActivity(node);
  }
  return out;
}

/**
 * Stoplight's snapshot carries each PR's last 10 reviews and comments, enough for the Comments and Review cells
 * without the GitHub CLI. It has no threads, requested reviewers or queue history, so those stay empty.
 */
export function activityFromSnapshot(pr: PullRequest): PRActivity | undefined {
  if (!pr.activity) return undefined;
  const author = pr.author.toLowerCase();
  const fromOthers = pr.activity.filter(
    (a) => !a.isBot && !a.author.endsWith("[bot]") && a.author.toLowerCase() !== author,
  );
  const talk = fromOthers.filter((a) => a.kind === "comment" || (a.kind === "reviewed" && a.body.trim()));
  const latest = new Map<string, { login: string; state: ReviewState; at?: string }>();
  for (const a of fromOthers) {
    if (a.kind === "approved") latest.set(a.author, { login: a.author, state: "APPROVED", at: a.at });
    if (a.kind === "changesRequested") latest.set(a.author, { login: a.author, state: "CHANGES_REQUESTED", at: a.at });
  }
  return {
    comments: talk.length,
    commenters: [...new Set(talk.map((a) => a.author))],
    threads: 0,
    unresolvedThreads: 0,
    reviews: [...latest.values()],
    requested: [],
    autoMerge: false,
    queue: pr.mergeQueue ?? undefined,
  };
}
