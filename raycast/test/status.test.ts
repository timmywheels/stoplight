import { describe, expect, it } from "vitest";
import {
  activityFromSnapshot,
  ActivityNode,
  activityQuery,
  mapActivity,
  nodeID,
  PRActivity,
} from "../src/lib/activity";
import { asFilter, columns, dimensions, statusMark, statusTooltip, verdict } from "../src/lib/status";
import { check, makePR } from "./fixtures";

const NOW = Date.parse("2026-09-25T12:00:00Z");

const quiet = (overrides: Partial<PRActivity> = {}): PRActivity => ({
  comments: 0,
  commenters: [],
  threads: 0,
  unresolvedThreads: 0,
  reviews: [],
  requested: [],
  autoMerge: false,
  ...overrides,
});

const cells = (pr = makePR(), activity?: PRActivity) =>
  Object.fromEntries(columns(pr, activity, NOW).map((c) => [c.slot, c.glyph ? `${c.glyph}:${c.tint}` : "-"]));

describe("verdict", () => {
  it("is ready when CI passed and nothing is waiting", () =>
    expect(verdict(makePR(), quiet())).toEqual({ light: "ready", reasons: ["CI passed"] }));

  it("needs you for anything someone is waiting on you for, and says what", () => {
    const pr = makePR({ checks: [check("t", "failure")], mergeState: "conflicting" });
    const v = verdict(
      pr,
      quiet({ unresolvedThreads: 2, dropped: { at: "2026-09-25T10:00:00Z", reason: "CI_FAILED" } }),
    );
    expect(v.light).toBe("needsYou");
    expect(v.reasons).toEqual(["CI failed", "conflicts", "dropped from the merge queue", "2 unresolved threads"]);
  });

  it("needs you when a reviewer asked for changes", () =>
    expect(verdict(makePR(), quiet({ reviews: [{ login: "alice", state: "CHANGES_REQUESTED" }] })).light).toBe(
      "needsYou",
    ));

  it("waits on CI, review and the queue", () => {
    const pr = makePR({ checks: [check("t", "pending")], review: "reviewRequired" });
    expect(verdict(pr, quiet({ queue: { position: 2, state: "QUEUED" } }))).toEqual({
      light: "waiting",
      reasons: ["CI running", "#2 in the merge queue", "waiting on review"],
    });
  });

  it("isn't waiting on review once someone approved", () =>
    expect(
      verdict(makePR({ review: "reviewRequired" }), quiet({ reviews: [{ login: "bob", state: "APPROVED" }] })).light,
    ).toBe("ready"));

  it("doesn't turn a draft red over conflicts or pending review, like Stoplight", () => {
    const draft = makePR({ isDraft: true, checks: [], mergeState: "conflicting", review: "reviewRequired" });
    expect(verdict(draft, quiet()).light).toBe("quiet");
    expect(cells(draft, quiet()).merge).toBe("warning:secondary");
    expect(verdict({ ...draft, checks: [check("t", "failure")] }, quiet()).light).toBe("needsYou");
  });

  it("is quiet with no checks and no reviews", () =>
    expect(verdict(makePR({ checks: [] }), quiet()).light).toBe("quiet"));

  it("keeps a merged PR red while its base branch is still failing", () => {
    expect(verdict(makePR({ status: "merged" })).light).toBe("merged");
    const broken = makePR({ status: "merged", checks: [check("t", "failure")], baseState: "failure" });
    expect(verdict(broken).light).toBe("needsYou");
    expect(statusMark(broken, verdict(broken))).toEqual({ kind: "merged", broken: true });
  });

  it("drives the leading dot, hollow for drafts", () => {
    const pr = makePR({ isDraft: true, checks: [check("t", "failure")] });
    const v = verdict(pr, quiet());
    expect(statusMark(pr, v)).toEqual({ kind: "dot", state: "failure", hollow: true });
    expect(statusTooltip(pr, v)).toBe("Draft · Needs you: CI failed");
  });
});

describe("columns", () => {
  it("always has the same five cells, empty when there's nothing to say", () => {
    expect(columns(makePR({ checks: [] }), quiet(), NOW).map((c) => c.slot)).toEqual([
      "comments",
      "review",
      "ci",
      "merge",
      "queue",
    ]);
    expect(cells(makePR({ checks: [] }), quiet())).toEqual({
      comments: "-",
      review: "-",
      ci: "-",
      merge: "-",
      queue: "-",
    });
  });

  it("colors each dimension on its own", () => {
    const pr = makePR({ checks: [check("t", "failure")], mergeState: "conflicting" });
    const activity = quiet({
      comments: 4,
      commenters: ["alice"],
      unresolvedThreads: 1,
      threads: 2,
      reviews: [{ login: "alice", state: "APPROVED" }],
      dropped: { at: "2026-09-25T10:00:00Z", reason: "MERGE_CONFLICT" },
    });
    expect(cells(pr, activity)).toEqual({
      comments: "comment:failure",
      review: "seal:success",
      ci: "ci-fail:failure",
      merge: "warning:failure",
      queue: "queue-dropped:failure",
    });
    const [comments, , , , queue] = columns(pr, activity, NOW);
    expect(comments).toMatchObject({ count: 4, tooltip: "1 unresolved thread · 4 comments · from alice" });
    expect(queue.tooltip).toBe("Dropped from the merge queue 2h ago: merge conflict");
  });

  it("shows queued PRs as waiting, and a blocked entry as red", () => {
    expect(cells(makePR(), quiet({ queue: { position: 3, state: "QUEUED" } })).queue).toBe("queue:pending");
    expect(cells(makePR(), quiet({ queue: { position: 1, state: "UNMERGEABLE" } })).queue).toBe("queue:failure");
    expect(cells(makePR({ mergeQueue: { position: 2, state: "QUEUED" } })).queue).toBe("queue:pending");
  });

  it("shows a pending review in yellow and plain comments in grey", () => {
    const c = cells(makePR(), quiet({ requested: ["bob"], comments: 2 }));
    expect(c.review).toBe("person:pending");
    expect(c.comments).toBe("comment:secondary");
  });

  it("spells the same cells out for the details pane", () => {
    const d = dimensions(makePR({ checks: [check("a", "failure"), check("b", "success")] }), quiet(), NOW);
    expect(d.map((x) => `${x.label}:${x.state}:${x.summary}`)).toEqual([
      "Comments:none:No comments",
      "Review:none:No reviews",
      "CI:failure:1 of 2 checks failed",
      "Merge:success:No conflicts with main",
      "Queue:none:Not in a merge queue",
    ]);
  });
});

describe("activity from GitHub", () => {
  const node = (overrides: Partial<ActivityNode> = {}): ActivityNode => ({
    id: "PR_1",
    state: "OPEN",
    author: { login: "me", __typename: "User" },
    comments: {
      nodes: [
        { author: { login: "deploy-bot", __typename: "Bot" } },
        { author: { login: "me", __typename: "User" } },
        { author: { login: "timmywheels", __typename: "User" } },
      ],
    },
    reviews: {
      nodes: [
        { state: "COMMENTED", author: { login: "alice", __typename: "User" }, comments: { totalCount: 3 } },
        { state: "APPROVED", author: { login: "bob", __typename: "User" }, comments: { totalCount: 0 } },
      ],
    },
    reviewThreads: { nodes: [{ isResolved: true }, { isResolved: false }] },
    latestOpinionatedReviews: {
      nodes: [{ state: "APPROVED", submittedAt: "2026-09-25T09:00:00Z", author: { login: "bob", __typename: "User" } }],
    },
    reviewRequests: { nodes: [{ requestedReviewer: { login: "carol" } }, { requestedReviewer: { name: "platform" } }] },
    autoMergeRequest: null,
    mergeQueueEntry: null,
    timelineItems: { nodes: [] },
    ...overrides,
  });

  it("counts only other people's comments, not bots or the author", () =>
    expect(mapActivity(node())).toMatchObject({
      comments: 4,
      commenters: ["timmywheels", "alice"],
      threads: 2,
      unresolvedThreads: 1,
      reviews: [{ login: "bob", state: "APPROVED", at: "2026-09-25T09:00:00Z" }],
      requested: ["carol", "platform"],
    }));

  it("spots a PR the merge queue dropped", () => {
    const dropped = node({
      timelineItems: {
        nodes: [
          { __typename: "AddedToMergeQueueEvent", createdAt: "2026-09-25T09:00:00Z" },
          { __typename: "RemovedFromMergeQueueEvent", createdAt: "2026-09-25T10:00:00Z", reason: "CI_FAILED" },
        ],
      },
    });
    expect(mapActivity(dropped).dropped).toEqual({ at: "2026-09-25T10:00:00Z", reason: "CI_FAILED" });
  });

  it("doesn't call it dropped once it's back in the queue or merged", () => {
    const events = {
      nodes: [{ __typename: "RemovedFromMergeQueueEvent", createdAt: "2026-09-25T10:00:00Z", reason: "CI_FAILED" }],
    };
    expect(
      mapActivity(node({ timelineItems: events, mergeQueueEntry: { position: 1, state: "QUEUED" } })).dropped,
    ).toBeUndefined();
    expect(mapActivity(node({ timelineItems: events, state: "MERGED" })).dropped).toBeUndefined();
    const requeued = {
      nodes: [...events.nodes, { __typename: "AddedToMergeQueueEvent", createdAt: "2026-09-25T11:00:00Z" }],
    };
    expect(mapActivity(node({ timelineItems: requeued })).dropped).toBeUndefined();
  });

  it("queries only real PR node ids", () => {
    expect(nodeID("queue:PR_abc")).toBe("PR_abc");
    const q = activityQuery(["PR_abc", 'PR_x"){evil}', "branch:acme/app#main"]);
    expect(q).toContain('nodes(ids: ["PR_abc"])');
  });
});

describe("activity from Stoplight's snapshot", () => {
  const item = (kind: string, author: string, body = "", isBot = false) => ({
    id: `${kind}:${author}`,
    kind: kind as "comment",
    author,
    isBot,
    body,
    at: "2026-09-29T00:00:00Z",
    url: "https://github.com/acme/app/pull/1",
  });

  it("is absent when the snapshot came from gh", () => expect(activityFromSnapshot(makePR())).toBeUndefined());

  it("counts other people's comments and keeps each reviewer's latest verdict", () => {
    const pr = makePR({
      author: "me",
      activity: [
        item("comment", "alice", "why?"),
        item("comment", "me", "because"),
        item("comment", "coderabbitai", "summary", true),
        item("reviewed", "bob", "a few nits"),
        item("changesRequested", "bob"),
        item("approved", "bob"),
        item("approved", "carol"),
      ],
    });
    expect(activityFromSnapshot(pr)).toMatchObject({
      comments: 2,
      commenters: ["alice", "bob"],
      reviews: [
        { login: "bob", state: "APPROVED" },
        { login: "carol", state: "APPROVED" },
      ],
    });
  });
});

describe("asFilter", () => {
  it("falls back to All for anything that isn't a light", () => {
    expect(asFilter("needsYou")).toBe("needsYou");
    expect(asFilter("all")).toBe("all");
    expect(asFilter("")).toBe("all");
    expect(asFilter(undefined)).toBe("all");
  });
});
