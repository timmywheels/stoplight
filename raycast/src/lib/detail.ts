import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { checkRunState, statusContextState } from "./github";
import { CheckResult, CheckState, PullRequest } from "./model";

const run = promisify(execFile);

export interface CIStep {
  number: number;
  name: string;
  state: CheckState;
  running: boolean;
  startedAt?: string;
  completedAt?: string;
}

export interface CIJob {
  /** GraphQL node ID, for the steps lookup. */
  id?: string;
  /** The Actions job ID, for its log. */
  jobID?: number;
  name: string;
  state: CheckState;
  /** Pending and actually started, as opposed to queued. */
  running: boolean;
  startedAt?: string;
  completedAt?: string;
  url?: string | null;
  description?: string;
  steps?: CIStep[];
  /** The output just before the job's first error, from its log. */
  failure?: string;
}

export interface CIGroup {
  name: string;
  event?: string;
  url?: string;
  runNumber?: number;
  jobs: CIJob[];
}

export type RunKind = "head" | "queue" | "merge";

export interface CIRun {
  kind: RunKind;
  sha: string;
  groups: CIGroup[];
}

export type FeedKind = "approved" | "changesRequested" | "reviewed" | "dismissed" | "comment" | "thread";

export interface FeedReply {
  author: string;
  isBot: boolean;
  body: string;
  at: string;
  url: string;
}

export interface FeedItem {
  id: string;
  kind: FeedKind;
  author: string;
  isBot: boolean;
  body: string;
  at: string;
  url: string;
  path?: string;
  line?: number;
  resolved?: boolean;
  outdated?: boolean;
  replies?: FeedReply[];
}

export type ReviewerState = "approved" | "changesRequested" | "commented" | "requested";

export interface Reviewer {
  login: string;
  state: ReviewerState;
}

export interface PRDetail {
  body: string;
  runs: CIRun[];
  feed: FeedItem[];
  reviewers: Reviewer[];
  fetchedAt: string;
  /** False when this came from Stoplight's snapshot: no timings, steps or threads. */
  live: boolean;
}

const CI_FRAGMENT = `
fragment CI on Commit {
  oid
  checkSuites(first: 30) { nodes {
    app { name }
    workflowRun { runNumber url event workflow { name } }
    checkRuns(first: 50, filterBy: { checkType: LATEST }) { nodes {
      id databaseId name status conclusion startedAt completedAt detailsUrl title
    } }
  } }
  status { contexts { context state description targetUrl createdAt } }
}`;

/** Costs one point. Steps would cost ~45 more inline, so they come from stepsQuery for the jobs that need them. */
export const DETAIL_QUERY = `query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      body state
      author { login }
      commits(last: 1) { nodes { commit { ...CI } } }
      mergeCommit { ...CI }
      mergeQueueEntry { headCommit { ...CI } }
      comments(last: 50) { nodes { id author { login __typename } body createdAt url } }
      reviews(last: 50) { nodes { id state author { login __typename } body submittedAt url } }
      reviewThreads(last: 50) { nodes {
        id isResolved isOutdated path line originalLine
        comments(first: 30) { nodes { id author { login __typename } body createdAt url } }
      } }
      latestOpinionatedReviews(first: 20) { nodes { state author { login __typename } } }
      reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } ... on Team { name } } } }
    }
  }
}
${CI_FRAGMENT}`;

export const STEPS_QUERY = `query($ids: [ID!]!) {
  nodes(ids: $ids) { ... on CheckRun { id steps(first: 60) { nodes { number name status conclusion startedAt completedAt } } } }
}`;

interface Actor {
  login: string;
  __typename?: string;
}

interface CheckRunNode {
  id?: string;
  databaseId?: number | null;
  name: string;
  status?: string;
  conclusion?: string | null;
  startedAt?: string | null;
  completedAt?: string | null;
  detailsUrl?: string | null;
  title?: string | null;
}

interface CommitNode {
  oid: string;
  checkSuites?: {
    nodes: {
      app?: { name: string } | null;
      workflowRun?: { runNumber: number; url: string; event: string; workflow?: { name: string } | null } | null;
      checkRuns?: { nodes: CheckRunNode[] };
    }[];
  };
  status?: {
    contexts: {
      context: string;
      state: string;
      description?: string | null;
      targetUrl?: string | null;
      createdAt?: string;
    }[];
  } | null;
}

interface CommentNode {
  id: string;
  author?: Actor | null;
  body: string;
  createdAt: string;
  url: string;
}

export interface DetailNode {
  body?: string;
  state?: string;
  author?: Actor | null;
  commits?: { nodes: { commit: CommitNode }[] };
  mergeCommit?: CommitNode | null;
  mergeQueueEntry?: { headCommit?: CommitNode | null } | null;
  comments?: { nodes: CommentNode[] };
  reviews?: {
    nodes: {
      id: string;
      state: string;
      author?: Actor | null;
      body: string;
      submittedAt?: string | null;
      url: string;
    }[];
  };
  reviewThreads?: {
    nodes: {
      id: string;
      isResolved: boolean;
      isOutdated: boolean;
      path: string;
      line?: number | null;
      originalLine?: number | null;
      comments: { nodes: CommentNode[] };
    }[];
  };
  latestOpinionatedReviews?: { nodes: { state: string; author?: Actor | null }[] };
  reviewRequests?: { nodes: { requestedReviewer?: { login?: string; name?: string } | null }[] };
}

const isBotActor = (a?: Actor | null) => !a || a.__typename === "Bot" || a.login.endsWith("[bot]");
const login = (a?: Actor | null) => a?.login ?? "ghost";

function jobOf(node: CheckRunNode): CIJob {
  return {
    id: node.id,
    jobID: node.databaseId ?? undefined,
    name: node.name,
    state: checkRunState(node.status, node.conclusion),
    running: node.status === "IN_PROGRESS",
    startedAt: node.startedAt ?? undefined,
    completedAt: node.status === "COMPLETED" ? (node.completedAt ?? undefined) : undefined,
    url: node.detailsUrl,
    description: node.title ?? undefined,
  };
}

/** One group per workflow run or app. Suites apps register but never run are dropped. */
export function runOf(kind: RunKind, commit?: CommitNode | null): CIRun | undefined {
  if (!commit) return undefined;
  const groups: CIGroup[] = [];
  for (const suite of commit.checkSuites?.nodes ?? []) {
    const jobs = (suite.checkRuns?.nodes ?? []).map(jobOf);
    if (jobs.length === 0) continue;
    const wr = suite.workflowRun;
    groups.push({
      name: wr?.workflow?.name ?? suite.app?.name ?? "Checks",
      event: wr?.event,
      url: wr?.url,
      runNumber: wr?.runNumber,
      jobs,
    });
  }
  const contexts = commit.status?.contexts ?? [];
  if (contexts.length) {
    groups.push({
      name: "Statuses",
      jobs: contexts.map((c) => ({
        name: c.context,
        state: statusContextState(c.state),
        running: c.state === "PENDING",
        startedAt: c.createdAt,
        url: c.targetUrl,
        description: c.description ?? undefined,
      })),
    });
  }
  return groups.length ? { kind, sha: commit.oid, groups } : undefined;
}

const REVIEW_KINDS: Record<string, FeedKind> = {
  APPROVED: "approved",
  CHANGES_REQUESTED: "changesRequested",
  COMMENTED: "reviewed",
  DISMISSED: "dismissed",
};

const REVIEWER_STATES: Record<string, ReviewerState> = {
  APPROVED: "approved",
  CHANGES_REQUESTED: "changesRequested",
  COMMENTED: "commented",
};

/** Newest first. A review that's only a wrapper for inline comments is left to its threads. */
export function feedOf(node: DetailNode): FeedItem[] {
  const items: FeedItem[] = [];
  for (const c of node.comments?.nodes ?? []) {
    items.push({
      id: c.id,
      kind: "comment",
      author: login(c.author),
      isBot: isBotActor(c.author),
      body: c.body,
      at: c.createdAt,
      url: c.url,
    });
  }
  for (const r of node.reviews?.nodes ?? []) {
    const kind = REVIEW_KINDS[r.state];
    if (!kind || !r.submittedAt) continue;
    if (kind === "reviewed" && !r.body.trim()) continue;
    items.push({
      id: r.id,
      kind,
      author: login(r.author),
      isBot: isBotActor(r.author),
      body: r.body,
      at: r.submittedAt,
      url: r.url,
    });
  }
  for (const t of node.reviewThreads?.nodes ?? []) {
    const [first, ...rest] = t.comments.nodes;
    if (!first) continue;
    const last = rest[rest.length - 1] ?? first;
    items.push({
      id: t.id,
      kind: "thread",
      author: login(first.author),
      isBot: isBotActor(first.author),
      body: first.body,
      at: last.createdAt,
      url: first.url,
      path: t.path,
      line: t.line ?? t.originalLine ?? undefined,
      resolved: t.isResolved,
      outdated: t.isOutdated,
      replies: rest.map((c) => ({
        author: login(c.author),
        isBot: isBotActor(c.author),
        body: c.body,
        at: c.createdAt,
        url: c.url,
      })),
    });
  }
  return items.sort((a, b) => Date.parse(b.at) - Date.parse(a.at));
}

export function reviewersOf(node: DetailNode): Reviewer[] {
  const author = node.author?.login.toLowerCase();
  const out = new Map<string, Reviewer>();
  for (const r of node.latestOpinionatedReviews?.nodes ?? []) {
    const state = REVIEWER_STATES[r.state];
    if (!state || isBotActor(r.author) || r.author!.login.toLowerCase() === author) continue;
    out.set(r.author!.login, { login: r.author!.login, state });
  }
  for (const r of node.reviewRequests?.nodes ?? []) {
    const name = r.requestedReviewer?.login ?? r.requestedReviewer?.name;
    if (name && !out.has(name)) out.set(name, { login: name, state: "requested" });
  }
  return [...out.values()];
}

/** In the queue, its run decides the merge; once merged, only the run on the merge commit is still news. */
export function mapDetail(node: DetailNode, now: Date = new Date()): PRDetail {
  const head = runOf("head", node.commits?.nodes[0]?.commit);
  const runs =
    node.state === "MERGED"
      ? [runOf("merge", node.mergeCommit) ?? head]
      : [runOf("queue", node.mergeQueueEntry?.headCommit), head];
  return {
    body: node.body ?? "",
    runs: runs.filter((r): r is CIRun => Boolean(r)),
    feed: feedOf(node),
    reviewers: reviewersOf(node),
    fetchedAt: now.toISOString(),
    live: true,
  };
}

export const jobs = (detail: PRDetail): CIJob[] => detail.runs.flatMap((r) => r.groups.flatMap((g) => g.jobs));

export const isRunning = (detail: PRDetail): boolean => jobs(detail).some((j) => j.state === "pending");

/** The run that decides the PR's CI light, flattened the way the snapshot's checks are. */
export function liveChecks(detail: PRDetail): CheckResult[] | undefined {
  const primary = detail.runs.find((r) => r.kind !== "queue") ?? detail.runs[0];
  if (!primary) return undefined;
  return primary.groups.flatMap((g) => g.jobs.map((j) => ({ name: j.name, state: j.state, url: j.url })));
}

/** Snapshot data when there's no GitHub CLI: no timings, steps or threads, and the last 10 comments at most. */
export function detailFromSnapshot(pr: PullRequest, now: Date = new Date()): PRDetail {
  const kind: RunKind = pr.status === "merged" ? "merge" : "head";
  const jobsFromChecks: CIJob[] = pr.checks.map((c) => ({ name: c.name, state: c.state, running: false, url: c.url }));
  const feed: FeedItem[] = (pr.activity ?? [])
    .map((a) => ({
      id: a.id,
      kind: a.kind === "comment" ? ("comment" as const) : a.kind,
      author: a.author,
      isBot: a.isBot,
      body: a.body,
      at: a.at,
      url: a.url,
    }))
    .sort((a, b) => Date.parse(b.at) - Date.parse(a.at));
  return {
    body: pr.summary,
    runs: jobsFromChecks.length ? [{ kind, sha: pr.headSha, groups: [{ name: "Checks", jobs: jobsFromChecks }] }] : [],
    feed,
    reviewers: [],
    fetchedAt: now.toISOString(),
    live: false,
  };
}

async function gh(path: string, args: string[]): Promise<string> {
  try {
    const { stdout } = await run(path, args, { maxBuffer: 64 * 1024 * 1024, timeout: 20_000 });
    return stdout;
  } catch (error) {
    const partial = (error as { stdout?: string }).stdout;
    if (partial?.includes('"data"')) return partial;
    throw error;
  }
}

const REPO = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;

export async function fetchDetail(ghPath: string, pr: PullRequest): Promise<PRDetail> {
  if (!REPO.test(pr.repo)) throw new Error(`Not a repository: ${pr.repo}`);
  const [owner, name] = pr.repo.split("/");
  const stdout = await gh(ghPath, [
    "api",
    "graphql",
    "-f",
    `query=${DETAIL_QUERY}`,
    "-f",
    `owner=${owner}`,
    "-f",
    `name=${name}`,
    "-F",
    `number=${pr.number}`,
  ]);
  const response = JSON.parse(stdout) as {
    data?: { repository?: { pullRequest?: DetailNode | null } | null };
    errors?: { message: string }[];
  };
  const node = response.data?.repository?.pullRequest;
  if (!node) throw new Error(response.errors?.[0]?.message ?? "GitHub returned no pull request");
  const detail = mapDetail(node);
  await Promise.all([addSteps(ghPath, detail), addFailures(ghPath, pr.repo, detail)]);
  return detail;
}

const STEP_LIMIT = 20;

/** Steps only for the jobs whose steps say something: the running ones and the failed ones. */
async function addSteps(ghPath: string, detail: PRDetail): Promise<void> {
  const wanted = jobs(detail)
    .filter((j) => j.id && (j.running || j.state === "failure"))
    .slice(0, STEP_LIMIT);
  if (!wanted.length) return;
  const args = ["api", "graphql", "-f", `query=${STEPS_QUERY}`];
  for (const job of wanted) args.push("-f", `ids[]=${job.id}`);
  try {
    const response = JSON.parse(await gh(ghPath, args)) as {
      data?: { nodes?: ({ id: string; steps?: { nodes: StepNode[] } } | null)[] };
    };
    const byID = new Map((response.data?.nodes ?? []).flatMap((n) => (n?.steps ? [[n.id, n.steps.nodes]] : [])));
    for (const job of wanted) {
      const steps = byID.get(job.id!);
      if (steps) job.steps = steps.map(stepOf);
    }
  } catch {
    // Steps are extra detail; the jobs still show without them.
  }
}

interface StepNode {
  number: number;
  name: string;
  status: string;
  conclusion?: string | null;
  startedAt?: string | null;
  completedAt?: string | null;
}

export function stepOf(node: StepNode): CIStep {
  return {
    number: node.number,
    name: node.name,
    state: checkRunState(node.status, node.conclusion),
    running: node.status === "IN_PROGRESS",
    startedAt: node.startedAt ?? undefined,
    completedAt: node.completedAt ?? undefined,
  };
}

const FAILURE_LIMIT = 3;
const failureCache = new Map<number, string>();

/** A finished job's log never changes, so each one is read once per session. */
async function addFailures(ghPath: string, repo: string, detail: PRDetail): Promise<void> {
  const failed = jobs(detail)
    .filter((j) => j.jobID && j.state === "failure" && j.completedAt && j.url?.includes("/actions/runs/"))
    .slice(0, FAILURE_LIMIT);
  await Promise.all(
    failed.map(async (job) => {
      const cached = failureCache.get(job.jobID!);
      if (cached !== undefined) {
        job.failure = cached || undefined;
        return;
      }
      try {
        const log = await gh(ghPath, [
          "api",
          "--allow-escape-sequences",
          `repos/${repo}/actions/jobs/${job.jobID}/logs`,
        ]);
        const excerpt = failureExcerpt(log);
        failureCache.set(job.jobID!, excerpt ?? "");
        job.failure = excerpt;
      } catch {
        // Expired or inaccessible logs just mean no excerpt.
      }
    }),
  );
}

const TIMESTAMP = /^\d{4}-\d\d-\d\dT[\d:.]+Z ?/;
// eslint-disable-next-line no-control-regex
const ANSI = /\u001b\[[0-9;]*[A-Za-z]/g;
const EXIT_CODE = /^Process completed with exit code \d+\.?$/;

/** Lines test runners, compilers and linters open their failure reports with. */
const REPORT_MARKERS = [
  /^\s*(FAIL|FAILED)\b/,
  /^\s*-+ FAIL:/,
  /^\s*[⎯─-]+ Failed Tests/,
  /^\s*❌/,
  /^\s*(\w+)?Error:/,
  /^\s*error(\[E\d+\])?:/,
  /\berror TS\d+:/,
  /^\s*\d+:\d+\s+error\b/,
  /^\s*npm ERR!/,
  /^\s*Traceback \(most recent call last\)/,
  /panicked at/,
];

/** Per-test marks, which also show up in progress output, so they only count when there's no report. */
const TEST_MARKERS = [/^\s*[✗×✖●]\s/];

const MARKER_WINDOW = 300;

/**
 * The failing step's own report: from the first line that looks like a failure to the log's first ##[error],
 * or the step's last lines when nothing does.
 */
export function failureExcerpt(log: string, maxLines = 15): string | undefined {
  const lines = log.split(/\r?\n/).map((line) => line.replace(TIMESTAMP, "").replace(ANSI, ""));
  const first = lines.findIndex((line) => line.startsWith("##[error]"));
  if (first < 0) return undefined;
  let start = first;
  while (start > 0 && !/^##\[(end)?group\]/.test(lines[start - 1])) start -= 1;
  const output = lines.slice(Math.max(start, first - MARKER_WINDOW), first).filter((line) => !line.startsWith("##["));
  const find = (patterns: RegExp[]) => output.findIndex((line) => patterns.some((pattern) => pattern.test(line)));
  const report = find(REPORT_MARKERS);
  const marker = report >= 0 ? report : find(TEST_MARKERS);
  const excerpt = marker >= 0 ? output.slice(marker, marker + maxLines) : output.slice(-maxLines);
  const shown = new Set(excerpt.map((line) => line.trim()));
  const errors = lines
    .filter((line) => line.startsWith("##[error]"))
    .map((line) => line.slice("##[error]".length).trim())
    .filter((message) => !EXIT_CODE.test(message) && !shown.has(message));
  const body = [...excerpt, ...errors.slice(0, 5)];
  while (body.length && !body[0].trim()) body.shift();
  while (body.length && !body[body.length - 1].trim()) body.pop();
  return body.length ? body.join("\n").replace(/\n{3,}/g, "\n\n") : undefined;
}
