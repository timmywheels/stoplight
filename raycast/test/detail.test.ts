import { describe, expect, it } from "vitest";
import {
  DetailNode,
  detailFromSnapshot,
  failureExcerpt,
  isRunning,
  liveChecks,
  mapDetail,
  PRDetail,
  stepOf,
} from "../src/lib/detail";
import { check, makePR } from "./fixtures";

const actor = (login: string, bot = false) => ({ login, __typename: bot ? "Bot" : "User" });

const run = (name: string, status: string, conclusion: string | null, extra: Record<string, unknown> = {}) => ({
  id: `CR_${name}`,
  databaseId: name.length,
  name,
  status,
  conclusion,
  startedAt: "2026-09-25T11:50:00Z",
  completedAt: status === "COMPLETED" ? "2026-09-25T11:55:00Z" : null,
  detailsUrl: `https://github.com/acme/app/actions/runs/9/job/${name.length}`,
  ...extra,
});

function commit(oid: string, suites: { workflow?: string; app?: string; runs: ReturnType<typeof run>[] }[]) {
  return {
    oid,
    checkSuites: {
      nodes: suites.map((s) => ({
        app: { name: s.app ?? "GitHub Actions" },
        workflowRun: s.workflow
          ? {
              runNumber: 42,
              url: "https://github.com/acme/app/actions/runs/9",
              event: "pull_request",
              workflow: { name: s.workflow },
            }
          : null,
        checkRuns: { nodes: s.runs },
      })),
    },
    status: null,
  };
}

const node = (overrides: Partial<DetailNode> = {}): DetailNode => ({
  body: "Adds a thing.",
  state: "OPEN",
  author: actor("me"),
  commits: {
    nodes: [
      {
        commit: commit("abc1234def", [
          { workflow: "CI", runs: [run("build", "COMPLETED", "SUCCESS"), run("test", "IN_PROGRESS", null)] },
          { app: "Vercel", runs: [] },
        ]),
      },
    ],
  },
  comments: { nodes: [] },
  reviews: { nodes: [] },
  reviewThreads: { nodes: [] },
  latestOpinionatedReviews: { nodes: [] },
  reviewRequests: { nodes: [] },
  ...overrides,
});

describe("mapDetail", () => {
  it("groups jobs by workflow and drops suites that never ran", () => {
    const detail = mapDetail(node());
    expect(detail.runs).toHaveLength(1);
    expect(detail.runs[0].kind).toBe("head");
    expect(
      detail.runs[0].groups.map((g) => [g.name, g.runNumber, g.jobs.map((j) => [j.name, j.state, j.running])]),
    ).toEqual([
      [
        "CI",
        42,
        [
          ["build", "success", false],
          ["test", "pending", true],
        ],
      ],
    ]);
    expect(isRunning(detail)).toBe(true);
  });

  it("puts the merge queue's run first and keeps only the merge commit's run once merged", () => {
    const queued = mapDetail(
      node({
        mergeQueueEntry: { headCommit: commit("q1", [{ workflow: "CI", runs: [run("gate", "QUEUED", null)] }]) },
      }),
    );
    expect(queued.runs.map((r) => r.kind)).toEqual(["queue", "head"]);
    expect(queued.runs[0].groups[0].jobs[0]).toMatchObject({ state: "pending", running: false });

    const merged = mapDetail(
      node({
        state: "MERGED",
        mergeCommit: commit("m1", [{ workflow: "Deploy", runs: [run("ship", "COMPLETED", "FAILURE")] }]),
      }),
    );
    expect(merged.runs.map((r) => [r.kind, r.sha])).toEqual([["merge", "m1"]]);
    expect(liveChecks(merged)).toEqual([{ name: "ship", state: "failure", url: expect.any(String) }]);
  });

  it("reads commit statuses as their own group", () => {
    const withStatus = node({
      commits: {
        nodes: [
          {
            commit: {
              oid: "s1",
              status: {
                contexts: [{ context: "ci/circle", state: "PENDING", description: "Running", targetUrl: null }],
              },
            },
          },
        ],
      },
    });
    const group = mapDetail(withStatus).runs[0].groups[0];
    expect(group.name).toBe("Statuses");
    expect(group.jobs[0]).toMatchObject({ name: "ci/circle", state: "pending", running: true, description: "Running" });
  });

  it("builds the conversation newest first, leaving empty review wrappers to their threads", () => {
    const detail = mapDetail(
      node({
        comments: {
          nodes: [{ id: "c1", author: actor("alice"), body: "Hi", createdAt: "2026-09-25T10:00:00Z", url: "u1" }],
        },
        reviews: {
          nodes: [
            {
              id: "r1",
              state: "COMMENTED",
              author: actor("bob"),
              body: "",
              submittedAt: "2026-09-25T10:30:00Z",
              url: "u2",
            },
            {
              id: "r2",
              state: "APPROVED",
              author: actor("bob"),
              body: "Ship it",
              submittedAt: "2026-09-25T11:30:00Z",
              url: "u3",
            },
          ],
        },
        reviewThreads: {
          nodes: [
            {
              id: "t1",
              isResolved: false,
              isOutdated: false,
              path: "src/a.ts",
              line: 12,
              comments: {
                nodes: [
                  { id: "tc1", author: actor("bob"), body: "Why?", createdAt: "2026-09-25T10:31:00Z", url: "u4" },
                  { id: "tc2", author: actor("me"), body: "Because.", createdAt: "2026-09-25T11:00:00Z", url: "u5" },
                ],
              },
            },
          ],
        },
      }),
    );
    expect(detail.feed.map((i) => [i.id, i.kind])).toEqual([
      ["r2", "approved"],
      ["t1", "thread"],
      ["c1", "comment"],
    ]);
    const thread = detail.feed[1];
    expect(thread).toMatchObject({ path: "src/a.ts", line: 12, resolved: false, at: "2026-09-25T11:00:00Z" });
    expect(thread.replies?.map((r) => r.author)).toEqual(["me"]);
  });

  it("lists reviewers by their latest say, then who's still requested, without the author or bots", () => {
    const detail = mapDetail(
      node({
        latestOpinionatedReviews: {
          nodes: [
            { state: "APPROVED", author: actor("bob") },
            { state: "CHANGES_REQUESTED", author: actor("me") },
            { state: "APPROVED", author: actor("renovate[bot]", true) },
          ],
        },
        reviewRequests: {
          nodes: [{ requestedReviewer: { login: "carol" } }, { requestedReviewer: { name: "platform" } }],
        },
      }),
    );
    expect(detail.reviewers).toEqual([
      { login: "bob", state: "approved" },
      { login: "carol", state: "requested" },
      { login: "platform", state: "requested" },
    ]);
  });
});

describe("stepOf", () => {
  it("marks the step in progress", () =>
    expect(stepOf({ number: 3, name: "Run tests", status: "IN_PROGRESS", conclusion: null })).toMatchObject({
      state: "pending",
      running: true,
    }));
});

const stamp = (lines: string[]) =>
  lines.map((line, i) => `2026-09-29T02:40:${String(i % 60).padStart(2, "0")}.0000000Z ${line}`).join("\n");

describe("failureExcerpt", () => {
  it("starts at the test runner's failure report, not its progress marks", () => {
    const log = stamp([
      "##[group]Run pnpm test",
      "pnpm test",
      "##[endgroup]",
      "     × lists every direct send 76ms",
      " ✓ src/other.test.ts (3 tests)",
      "⎯⎯⎯⎯ Failed Tests 1 ⎯⎯⎯⎯",
      " FAIL  src/a.test.ts > lists every direct send",
      "AssertionError: expected [ Array(1) ] to deeply equal []",
      " Test Files  1 failed | 139 passed (140)",
      "##[error]AssertionError: expected [ Array(1) ] to deeply equal []",
      "##[error]Process completed with exit code 1.",
    ]);
    expect(failureExcerpt(log)).toBe(
      [
        "⎯⎯⎯⎯ Failed Tests 1 ⎯⎯⎯⎯",
        " FAIL  src/a.test.ts > lists every direct send",
        "AssertionError: expected [ Array(1) ] to deeply equal []",
        " Test Files  1 failed | 139 passed (140)",
      ].join("\n"),
    );
  });

  it("keeps a script's own ❌ headline and strips colors", () => {
    const log = stamp([
      "##[endgroup]",
      "\u001b[31m❌ Sends grew: 5 (baseline 4).\u001b[0m",
      "",
      "Move it to the funnel.",
      "##[error]Process completed with exit code 1.",
    ]);
    expect(failureExcerpt(log)).toBe("❌ Sends grew: 5 (baseline 4).\n\nMove it to the funnel.");
  });

  it("falls back to the step's last lines and adds errors it didn't already show", () => {
    const lines = ["##[endgroup]", ...Array.from({ length: 20 }, (_, i) => `line ${i}`), "##[error]Deploy timed out"];
    const excerpt = failureExcerpt(stamp(lines), 5)!;
    expect(excerpt.split("\n")).toEqual(["line 15", "line 16", "line 17", "line 18", "line 19", "Deploy timed out"]);
  });

  it("returns nothing when the log has no error", () => expect(failureExcerpt(stamp(["all good"]))).toBeUndefined());
});

describe("detailFromSnapshot", () => {
  it("shows the snapshot's checks and activity when there's no GitHub CLI", () => {
    const pr = makePR({
      checks: [check("build", "failure")],
      summary: "Short summary",
      activity: [
        { id: "a", kind: "comment", author: "alice", isBot: false, body: "Old", at: "2026-09-25T09:00:00Z", url: "u" },
        { id: "b", kind: "approved", author: "bob", isBot: false, body: "", at: "2026-09-25T10:00:00Z", url: "u" },
      ],
    });
    const detail: PRDetail = detailFromSnapshot(pr);
    expect(detail.live).toBe(false);
    expect(detail.body).toBe("Short summary");
    expect(detail.runs[0].groups[0].jobs).toEqual([
      { name: "build", state: "failure", running: false, url: undefined },
    ]);
    expect(detail.feed.map((i) => i.id)).toEqual(["b", "a"]);
  });
});
