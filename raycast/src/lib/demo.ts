import { ActivityMap, PRActivity } from "./activity";
import { CIJob, CIRun, FeedItem, PRDetail, RunKind } from "./detail";
import { CheckResult, LoadedPRs, PullRequest } from "./model";

const ago = (minutes: number, now: number) => new Date(now - minutes * 60_000).toISOString();
const JOB_NAMES = [
  "build",
  "typecheck",
  "api contract",
  "migrations",
  "bundle size",
  "storybook",
  "docs",
  "license check",
  "security audit",
  "integration (postgres)",
  "integration (redis)",
  "coverage",
  "smoke / staging",
  "codegen drift",
  "i18n keys",
  "deps audit",
];
const passing = (n: number): CheckResult[] =>
  Array.from({ length: n }, (_, i) => ({ name: JOB_NAMES[i % JOB_NAMES.length], state: "success" }));

function pr(
  now: number,
  fields: Partial<PullRequest> & Pick<PullRequest, "id" | "repo" | "number" | "title">,
): PullRequest {
  return {
    url: `https://github.com/${fields.repo}/pull/${fields.number}`,
    isDraft: false,
    updatedAt: ago(60, now),
    headSha: "4f1c2a9d8e7b6c5a4f3e2d1c0b9a8f7e6d5c4b3a",
    checks: passing(12),
    author: "you",
    status: "open",
    summary: "",
    headRefName: `you/${fields.title
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .slice(0, 32)}`,
    baseRefName: "main",
    mergeState: "clean",
    review: "none",
    ...fields,
  };
}

/** Made-up PRs covering every state, for screenshots. Opened with launchContext {"demo": true}. */
export function demoPRs(now = Date.now()): LoadedPRs {
  const prs: PullRequest[] = [
    pr(now, {
      id: "PR_demo_1",
      repo: "acme/api",
      number: 412,
      title: "Retry webhooks with exponential backoff",
      updatedAt: ago(12, now),
      checks: [
        ...passing(16),
        { name: "test (ubuntu, node 22)", state: "failure", url: "https://github.com/acme/api/actions/runs/1/job/1" },
        { name: "e2e / checkout", state: "failure", url: "https://github.com/acme/api/actions/runs/1/job/2" },
      ],
      summary: "Webhook deliveries that time out are retried with backoff and jitter instead of being dropped.",
    }),
    pr(now, {
      id: "PR_demo_2",
      repo: "acme/web",
      number: 88,
      title: "Upgrade the dashboard to React 20",
      updatedAt: ago(25, now),
      review: "approved",
    }),
    pr(now, {
      id: "PR_demo_3",
      repo: "acme/api",
      number: 405,
      title: "Rate-limit the public search endpoint",
      updatedAt: ago(95, now),
      review: "changesRequested",
    }),
    pr(now, {
      id: "PR_demo_4",
      repo: "acme/api",
      number: 409,
      title: "Add idempotency keys to payments",
      updatedAt: ago(8, now),
      review: "approved",
      mergeQueue: { position: 2, state: "QUEUED" },
    }),
    pr(now, {
      id: "PR_demo_7",
      repo: "acme/api",
      number: 398,
      title: "Split the billing worker into its own service",
      updatedAt: ago(60 * 26, now),
      baseRefName: "you/add-idempotency-keys-to-payments",
      mergeState: "behind",
    }),
    pr(now, {
      id: "PR_demo_5",
      repo: "acme/web",
      number: 91,
      title: "Keyboard shortcuts for the inbox",
      updatedAt: ago(4, now),
      checks: [...passing(9), ...["lint", "unit", "e2e"].map((name) => ({ name, state: "pending" as const }))],
      review: "reviewRequired",
    }),
    pr(now, {
      id: "PR_demo_6",
      repo: "acme/cli",
      number: 33,
      title: "Ship shell completions for zsh and fish",
      updatedAt: ago(180, now),
      review: "approved",
    }),
    pr(now, {
      id: "PR_demo_8",
      repo: "acme/web",
      number: 95,
      title: "Spike: edge caching for marketing pages",
      updatedAt: ago(60 * 24 * 4, now),
      isDraft: true,
      checks: [],
    }),
    pr(now, {
      id: "PR_demo_9",
      repo: "acme/web",
      number: 86,
      title: "Move auth to the new session store",
      status: "merged",
      mergedAt: ago(300, now),
      checks: [...passing(10), { name: "deploy / production", state: "failure" }],
      baseState: "failure",
    }),
    pr(now, {
      id: "PR_demo_10",
      repo: "acme/api",
      number: 401,
      title: "Log slow queries over 200 ms",
      status: "merged",
      mergedAt: ago(200, now),
      baseState: "success",
    }),
  ];
  const open = prs.filter((p) => p.status === "open").map((p) => p.id);
  const merged = prs.filter((p) => p.status === "merged").map((p) => p.id);
  return {
    source: "stoplight",
    snapshot: {
      writtenAt: new Date(now).toISOString(),
      prs,
      pinnedIDs: [],
      sections: [
        { id: "Mine", title: "My PRs", prIDs: open },
        { id: "Merged", title: "Merged", prIDs: merged },
      ],
      colorProfile: "default",
    },
  };
}

const none: PRActivity = {
  comments: 0,
  commenters: [],
  threads: 0,
  unresolvedThreads: 0,
  reviews: [],
  requested: [],
  autoMerge: false,
};

export function demoActivity(now = Date.now()): ActivityMap {
  return {
    PR_demo_1: { ...none, comments: 5, commenters: ["alice"], threads: 3, unresolvedThreads: 2 },
    PR_demo_2: {
      ...none,
      comments: 1,
      commenters: ["bob"],
      reviews: [{ login: "bob", state: "APPROVED", at: ago(90, now) }],
      dropped: { at: ago(25, now), reason: "MERGE_GROUP_FAILED_CHECKS" },
    },
    PR_demo_3: {
      ...none,
      comments: 3,
      commenters: ["carol"],
      threads: 2,
      reviews: [{ login: "carol", state: "CHANGES_REQUESTED", at: ago(95, now) }],
    },
    PR_demo_4: {
      ...none,
      reviews: [{ login: "alice", state: "APPROVED", at: ago(40, now) }],
      queue: { position: 2, state: "QUEUED", enqueuedAt: ago(8, now) },
    },
    PR_demo_5: { ...none, requested: ["dana"] },
    PR_demo_6: { ...none, comments: 2, commenters: ["erin"], reviews: [{ login: "erin", state: "APPROVED" }] },
    PR_demo_7: none,
    PR_demo_8: none,
    PR_demo_9: none,
    PR_demo_10: none,
  };
}

interface DemoJob {
  running?: boolean;
  queued?: boolean;
  steps?: string[];
  failedStep?: number;
  currentStep?: number;
  failure?: string;
}

const demoJobs: Record<string, DemoJob> = {
  "test (ubuntu, node 22)": {
    steps: ["Set up job", "Checkout", "Setup Node", "Install", "Run tests", "Upload coverage"],
    failedStep: 5,
    failure: [
      " FAIL  src/webhooks/retry.test.ts > retries > gives up after the last attempt",
      "AssertionError: expected 6 to be 5 // Object.is equality",
      "",
      "- Expected",
      "+ Received",
      "",
      "- 5",
      "+ 6",
      "",
      " ❯ src/webhooks/retry.test.ts:88:31",
      "",
      " Test Files  1 failed | 41 passed (42)",
      "      Tests  1 failed | 318 passed (319)",
    ].join("\n"),
  },
  "e2e / checkout": {
    steps: ["Set up job", "Checkout", "Install", "Start API", "Run Playwright", "Upload traces"],
    failedStep: 5,
    failure: [
      "  1) [chromium] › checkout.spec.ts:42:7 › pays with a saved card",
      "",
      "    Error: Timed out 5000ms waiting for expect(locator).toBeVisible()",
      "    Locator: getByRole('heading', { name: 'Payment received' })",
      "",
      "  1 failed",
      "  23 passed (1.4m)",
    ].join("\n"),
  },
  "deploy / production": {
    steps: ["Set up job", "Checkout", "Build image", "Push image", "Deploy to production", "Smoke test"],
    failedStep: 5,
    failure: [
      "Rolling out session-store v2 to 6 instances…",
      "instance api-3: health check failed (GET /healthz → 503)",
      "Error: rollout halted, 1 of 6 instances unhealthy after 120s",
    ].join("\n"),
  },
  lint: {
    running: true,
    steps: ["Set up job", "Checkout", "Install", "Run eslint", "Post Checkout"],
    currentStep: 4,
  },
  unit: {
    running: true,
    steps: ["Set up job", "Checkout", "Setup Node", "Install", "Run vitest", "Upload coverage", "Post Checkout"],
    currentStep: 5,
  },
  e2e: { queued: true },
};

function demoRun(pr: PullRequest, kind: RunKind): CIRun | undefined {
  if (!pr.checks.length) return undefined;
  const finished = Date.parse(pr.mergedAt ?? pr.updatedAt);
  const jobs: CIJob[] = pr.checks.map((check, i) => {
    const demo = demoJobs[check.name] ?? {};
    const took = (45 + ((i * 37) % 260)) * 1000;
    const url = `https://github.com/${pr.repo}/actions/runs/1/job/${i + 1}`;
    if (check.state === "pending") {
      const started = Date.parse(pr.updatedAt) - (70 + i * 13) * 1000;
      return {
        name: check.name,
        state: "pending",
        running: Boolean(demo.running),
        startedAt: demo.queued ? undefined : new Date(started).toISOString(),
        url,
        steps: demo.steps?.map((name, s) => ({
          number: s + 1,
          name,
          state: s + 1 < (demo.currentStep ?? 0) ? "success" : "pending",
          running: s + 1 === demo.currentStep,
        })),
      };
    }
    const completed = finished - ((i * 11) % 90) * 1000;
    return {
      name: check.name,
      state: check.state,
      running: false,
      startedAt: new Date(completed - took).toISOString(),
      completedAt: new Date(completed).toISOString(),
      url,
      steps: demo.steps?.map((name, s) => ({
        number: s + 1,
        name,
        state: s + 1 === demo.failedStep ? "failure" : s + 1 < (demo.failedStep ?? 99) ? "success" : "skipped",
        running: false,
      })),
      failure: demo.failure,
    };
  });
  const workflow = kind === "merge" ? "Deploy" : "CI";
  const event = kind === "merge" ? "push" : kind === "queue" ? "merge_group" : "pull_request";
  return {
    kind,
    sha: pr.headSha,
    groups: [
      { name: workflow, event, runNumber: 1800 + pr.number, url: `https://github.com/${pr.repo}/actions/runs/1`, jobs },
    ],
  };
}

type DemoFeed = Omit<FeedItem, "at" | "url" | "replies"> & {
  minutes: number;
  replies?: { author: string; body: string; minutes: number }[];
};

const demoFeeds: Record<string, DemoFeed[]> = {
  PR_demo_1: [
    {
      id: "t1",
      kind: "thread",
      author: "alice",
      isBot: false,
      minutes: 50,
      path: "src/webhooks/retry.ts",
      line: 88,
      resolved: false,
      body: "Should the backoff have a ceiling? With 8 attempts the last wait is over 4 minutes, and the receiver's own timeout is 60s.",
      replies: [
        { author: "you", minutes: 35, body: "Good call. Capped at 30s in the next push." },
        {
          author: "alice",
          minutes: 20,
          body: "Thanks. Is the jitter applied before or after the cap? After is what we want.",
        },
      ],
    },
    {
      id: "t2",
      kind: "thread",
      author: "alice",
      isBot: false,
      minutes: 45,
      path: "src/webhooks/queue.ts",
      line: 41,
      resolved: false,
      body: "This drops the delivery when the queue is full. Can we park it in the dead-letter table instead so support can replay it?",
    },
    {
      id: "t3",
      kind: "thread",
      author: "alice",
      isBot: false,
      minutes: 55,
      path: "src/webhooks/retry.ts",
      line: 12,
      resolved: true,
      body: "Nit: `MAX_ATTEMPTS` reads better than `LIMIT` here.",
      replies: [{ author: "you", minutes: 40, body: "Renamed." }],
    },
    {
      id: "c1",
      kind: "comment",
      author: "alice",
      isBot: false,
      minutes: 48,
      body: "Close. Two things before I approve:\n\n1. The ceiling on the backoff.\n2. Full queue should dead-letter, not drop.\n\nThe unit test failure looks like the off-by-one I mentioned on line 88.",
    },
    {
      id: "b1",
      kind: "comment",
      author: "codecov[bot]",
      isBot: true,
      minutes: 30,
      body: "## Codecov Report\nPatch coverage is **94.1%** with 2 lines missing.",
    },
  ],
  PR_demo_2: [
    {
      id: "r1",
      kind: "approved",
      author: "bob",
      isBot: false,
      minutes: 90,
      body: "Nice cleanup. Ship it once the queue is green.",
    },
  ],
  PR_demo_3: [
    {
      id: "r2",
      kind: "changesRequested",
      author: "carol",
      isBot: false,
      minutes: 95,
      body: "The limiter keys on IP only, which throttles everyone behind the same office NAT. Key on the API token when there is one and fall back to IP.",
    },
    {
      id: "t4",
      kind: "thread",
      author: "carol",
      isBot: false,
      minutes: 100,
      path: "src/search/limits.ts",
      line: 22,
      resolved: true,
      body: "60/min feels low for the dashboard's typeahead.",
      replies: [{ author: "you", minutes: 97, body: "Raised to 120 and debounced the typeahead." }],
    },
  ],
  PR_demo_4: [{ id: "r3", kind: "approved", author: "alice", isBot: false, minutes: 40, body: "" }],
  PR_demo_6: [
    {
      id: "r4",
      kind: "approved",
      author: "erin",
      isBot: false,
      minutes: 200,
      body: "Tried both shells locally, works.",
    },
    {
      id: "c2",
      kind: "comment",
      author: "erin",
      isBot: false,
      minutes: 210,
      body: "Could we also add bash while we're here?",
    },
  ],
};

const demoBodies: Record<string, string> = {
  PR_demo_1:
    "## Why\nWebhook deliveries that time out are dropped today, so customers miss events.\n\n## What\n- Retry up to 8 times with exponential backoff and jitter\n- Park deliveries in the dead-letter table after the last attempt\n- Metrics for attempts and give-ups",
};

/** A made-up detail page for each demo PR: live-looking CI, a conversation, reviewers. */
export function demoDetail(pr: PullRequest, now = Date.now()): PRDetail {
  const at = (minutes: number) => ago(minutes, now);
  const url = (id: string) => `${pr.url}#${id}`;
  const runs = [
    pr.mergeQueue ? demoRun({ ...pr, checks: queueChecks }, "queue") : undefined,
    demoRun(pr, pr.status === "merged" ? "merge" : "head"),
  ].filter((r): r is CIRun => Boolean(r));
  const feed: FeedItem[] = (demoFeeds[pr.id] ?? []).map(({ minutes, replies, ...item }) => ({
    ...item,
    at: at(replies?.length ? Math.min(minutes, ...replies.map((r) => r.minutes)) : minutes),
    url: url(item.id),
    replies: replies?.map((r) => ({
      author: r.author,
      isBot: false,
      body: r.body,
      at: at(r.minutes),
      url: url(item.id),
    })),
  }));
  const activity = demoActivity(now)[pr.id];
  const reviewers = [
    ...(activity?.reviews ?? []).map((r) => ({
      login: r.login,
      state: r.state === "APPROVED" ? ("approved" as const) : ("changesRequested" as const),
    })),
    ...(activity?.requested ?? []).map((login) => ({ login, state: "requested" as const })),
  ];
  return {
    body: demoBodies[pr.id] ?? pr.summary,
    runs,
    feed: feed.sort((a, b) => Date.parse(b.at) - Date.parse(a.at)),
    reviewers,
    fetchedAt: new Date(now).toISOString(),
    live: true,
  };
}

const queueChecks: CheckResult[] = [
  ...passing(8),
  { name: "lint", state: "pending" },
  { name: "unit", state: "pending" },
  { name: "e2e", state: "pending" },
];
