import { describe, expect, it } from "vitest";
import {
  actionsRunURL,
  checksURL,
  compactAgo,
  countByState,
  effectiveState,
  hasNonTrunkBase,
  isStale,
  reviewURL,
  orderedRows,
  queueURL,
  rollup,
  shareLink,
} from "../src/lib/model";
import { check, makePR, makeSnapshot } from "./fixtures";

describe("rollup", () => {
  it("is none with no checks", () => expect(rollup([])).toBe("none"));
  it("lets a failure win over everything", () =>
    expect(rollup([check("a", "success"), check("b", "pending"), check("c", "failure")])).toBe("failure"));
  it("is pending while anything runs", () =>
    expect(rollup([check("a", "success"), check("b", "pending")])).toBe("pending"));
  it("needs a real pass to be green", () => expect(rollup([check("a", "skipped")])).toBe("none"));
  it("treats skipped as passing alongside a success", () =>
    expect(rollup([check("a", "skipped"), check("b", "success")])).toBe("success"));
});

describe("effectiveState", () => {
  it("reads an open PR with conflicts as red even when CI is green", () =>
    expect(effectiveState(makePR({ mergeState: "conflicting" }))).toBe("failure"));
  it("uses the merge commit when there is no base branch info", () =>
    expect(effectiveState(makePR({ status: "merged", checks: [check("a", "failure")] }))).toBe("failure"));
  it("keeps a merged PR red only while its base branch is still red", () => {
    const red = [check("a", "failure")];
    expect(effectiveState(makePR({ status: "merged", checks: red, baseState: "failure" }))).toBe("failure");
    expect(effectiveState(makePR({ status: "merged", checks: red, baseState: "success" }))).toBe("none");
  });
});

describe("links", () => {
  it("builds Stoplight's review link from the PR's node id", () =>
    expect(reviewURL(makePR({ id: "PR_kwDO123" }))).toBe("stoplight://pr/PR_kwDO123"));

  it("carries the node id as the path through URL parsing", () => {
    const url = new URL(reviewURL(makePR({ id: "PR_kwDO_node-id" })));
    expect(url.protocol).toBe("stoplight:");
    expect(url.host).toBe("pr");
    expect(decodeURIComponent(url.pathname.replace(/^\//, ""))).toBe("PR_kwDO_node-id");
  });

  it("points at the failing check's Actions run first", () => {
    const pr = makePR({
      checks: [
        check("lint", "success", "https://github.com/acme/app/actions/runs/111/job/1"),
        check("test", "failure", "https://github.com/acme/app/actions/runs/222/job/9"),
      ],
    });
    expect(actionsRunURL(pr)).toBe("https://github.com/acme/app/actions/runs/222");
  });

  it("has no Actions run for non-Actions checks", () =>
    expect(actionsRunURL(makePR({ checks: [check("vercel", "success", "https://vercel.com/x")] }))).toBeUndefined());

  it("builds checks and queue URLs", () => {
    expect(checksURL(makePR())).toBe("https://github.com/acme/app/pull/1/checks");
    expect(queueURL(makePR())).toBeUndefined();
    expect(queueURL(makePR({ mergeQueue: { position: 2, state: "QUEUED" } }))).toBe(
      "https://github.com/acme/app/queue/main",
    );
  });

  it("escapes HTML in a shared link and keeps a Markdown fallback", () =>
    expect(shareLink(makePR({ title: "Fix <b> & co" }))).toEqual({
      html: '<a href="https://github.com/acme/app/pull/1">Fix &lt;b&gt; &amp; co</a>',
      text: "[Fix <b> & co](https://github.com/acme/app/pull/1)",
    }));
});

describe("orderedRows", () => {
  const red = makePR({ id: "red", checks: [check("a", "failure")], updatedAt: "2026-09-20T00:00:00Z" });
  const green = makePR({ id: "green", updatedAt: "2026-09-25T00:00:00Z" });
  const yellow = makePR({ id: "yellow", checks: [check("a", "pending")] });

  it("follows Stoplight's sections in order and drops ids it can't find", () => {
    const rows = orderedRows(
      makeSnapshot({
        prs: [red, green, yellow],
        sections: [
          { id: "Mine", title: "My PRs", prIDs: ["green", "missing", "red"] },
          { id: "acme/app", title: "acme/app", prIDs: ["yellow", "green"] },
        ],
      }),
    );
    expect(rows.map((r) => r.key)).toEqual(["Mine:green", "Mine:red", "acme/app:yellow", "acme/app:green"]);
    expect(new Set(rows.map((r) => r.key)).size).toBe(rows.length);
  });

  it("falls back to pinned first, then worst first, when there are no sections", () => {
    const rows = orderedRows(makeSnapshot({ prs: [green, yellow, red], pinnedIDs: ["green"] }));
    expect(rows.map((r) => r.pr.id)).toEqual(["green", "red", "yellow"]);
  });
});

describe("counts and formatting", () => {
  it("counts each PR once even when it sits in two sections", () => {
    const pr = makePR({ checks: [check("a", "failure")] });
    expect(countByState([pr, pr, makePR({ id: "b" })])).toEqual({ failure: 1, pending: 0, success: 1, none: 0 });
  });

  it("formats ages compactly", () => {
    const now = Date.parse("2026-09-25T12:00:00Z");
    expect(compactAgo("2026-09-25T11:59:30Z", now)).toBe("now");
    expect(compactAgo("2026-09-25T11:15:00Z", now)).toBe("45m");
    expect(compactAgo("2026-09-25T02:00:00Z", now)).toBe("10h");
    expect(compactAgo("2026-09-22T12:00:00Z", now)).toBe("3d");
    expect(compactAgo("2026-09-04T12:00:00Z", now)).toBe("3w");
  });

  it("flags a snapshot older than five minutes as stale", () => {
    const now = Date.parse("2026-09-25T12:06:00Z");
    expect(isStale(makeSnapshot(), now)).toBe(true);
    expect(isStale(makeSnapshot({ writtenAt: "2026-09-25T12:02:00Z" }), now)).toBe(false);
  });

  it("only calls feature-branch bases stacked", () => {
    expect(hasNonTrunkBase(makePR({ baseRefName: "main" }))).toBe(false);
    expect(hasNonTrunkBase(makePR({ baseRefName: "dholliday/part-1" }))).toBe(true);
  });
});
