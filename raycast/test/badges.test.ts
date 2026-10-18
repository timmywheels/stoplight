import { describe, expect, it } from "vitest";
import { refLabel, rowBadges, showsAuthor, stackDepths, stackLayout, viewerLogin } from "../src/lib/badges";
import { makePR } from "./fixtures";

const texts = (badges: ReturnType<typeof rowBadges>) => badges.map((b) => (b.kind === "tag" ? b.text : `(${b.glyph})`));

describe("rowBadges", () => {
  it("leaves merge state, review and queue to the status columns", () =>
    expect(
      rowBadges(
        makePR({ mergeState: "conflicting", review: "approved", mergeQueue: { position: 1, state: "QUEUED" } }),
        "Mine",
        false,
      ),
    ).toEqual([]));

  it("keeps Stoplight's context tags in order", () => {
    const pr = makePR({ isDraft: true, baseRefName: "dholliday/some-very-long-stacked-branch-name" });
    expect(texts(rowBadges(pr, "Mine", true))).toEqual(["Draft", "(stack)", "(pin)"]);
  });

  it("shows base branch health on merged PRs, and Merged outside the Merged section", () => {
    const merged = makePR({ status: "merged", baseState: "failure" });
    expect(texts(rowBadges(merged, "Merged", false))).toEqual(["main"]);
    expect(rowBadges(merged, "Mine", false)).toEqual([
      { kind: "tag", text: "Merged", glyph: "merge", tint: "merged" },
      { kind: "tag", text: "main", glyph: "branch", tint: "failure", tooltip: "main is failing right now" },
    ]);
  });

  it("marks closed PRs", () =>
    expect(rowBadges(makePR({ status: "closed" }), "Watching", false)).toEqual([
      { kind: "tag", text: "Closed", glyph: "xmark", tint: "failure" },
    ]));
});

describe("ref labels and authors", () => {
  const mine = { id: "Mine", title: "My PRs", prIDs: ["PR_1"] };
  const repo = { id: "r", title: "acme/app", prIDs: [] };
  const org = { id: "o", title: "acme", prIDs: [] };

  it("drops what the section header already says", () => {
    expect(refLabel(makePR(), mine)).toBe("acme/app #1");
    expect(refLabel(makePR(), repo)).toBe("#1");
    expect(refLabel(makePR(), org)).toBe("app #1");
  });

  it("finds the viewer from My PRs", () =>
    expect(viewerLogin([makePR({ author: "dholliday3" })], [mine])).toBe("dholliday3"));

  it("names other people's PRs outside My PRs", () => {
    expect(showsAuthor(makePR({ author: "me" }), repo, "me")).toBe(false);
    expect(showsAuthor(makePR({ author: "alex" }), repo, "me")).toBe(true);
    expect(showsAuthor(makePR({ author: "alex" }), { id: "a", title: "@alex", prIDs: [] }, "me")).toBe(false);
  });
});

describe("stackDepths", () => {
  it("indents PRs stacked on another listed PR, and survives cycles", () => {
    const base = makePR({ id: "a", headRefName: "part-1", baseRefName: "main" });
    const child = makePR({ id: "b", headRefName: "part-2", baseRefName: "part-1" });
    const grandchild = makePR({ id: "c", headRefName: "part-3", baseRefName: "part-2" });
    const otherRepo = makePR({ id: "d", repo: "acme/other", headRefName: "x", baseRefName: "part-1" });
    const loopA = makePR({ id: "e", headRefName: "loop-a", baseRefName: "loop-b" });
    const loopB = makePR({ id: "f", headRefName: "loop-b", baseRefName: "loop-a" });
    const depths = stackDepths([base, child, grandchild, otherRepo, loopA, loopB]);
    expect(["a", "b", "c", "d"].map((id) => depths.get(id))).toEqual([0, 1, 2, 0]);
    expect(depths.get("e")).toBeLessThan(3);
  });
});

describe("stackLayout", () => {
  it("puts each stacked PR right after its parent and keeps everything else in order", () => {
    const rows = [
      makePR({ id: "child", headRefName: "part-2", baseRefName: "part-1" }),
      makePR({ id: "solo", headRefName: "solo", baseRefName: "main" }),
      makePR({ id: "parent", headRefName: "part-1", baseRefName: "main" }),
      makePR({ id: "grandchild", headRefName: "part-3", baseRefName: "part-2" }),
      makePR({ id: "loop-a", headRefName: "a", baseRefName: "b" }),
      makePR({ id: "loop-b", headRefName: "b", baseRefName: "a" }),
    ].map((pr) => ({ pr }));
    const order = stackLayout(rows).map((r) => r.pr.id);
    expect(order.slice(0, 4)).toEqual(["solo", "parent", "child", "grandchild"]);
    expect(order).toHaveLength(6);
  });
});
