import { describe, expect, it } from "vitest";
import { demoActivity, demoDetail, demoPRs } from "../src/lib/demo";
import { detailFromSnapshot, PRDetail } from "../src/lib/detail";
import { sidebarRows } from "../src/lib/sidebar";
import { check, makePR } from "./fixtures";

const NOW = Date.parse("2026-09-25T12:00:00Z");

const live = (extra: Partial<PRDetail> = {}): PRDetail => ({
  body: "",
  runs: [],
  feed: [],
  reviewers: [],
  fetchedAt: new Date(NOW).toISOString(),
  live: true,
  ...extra,
});

const byTitle = (rows: ReturnType<typeof sidebarRows>) =>
  Object.fromEntries(rows.map((r) => [r.title, `${r.glyph}:${r.tint} ${r.text}`]));

describe("sidebarRows", () => {
  it("gives every row its own glyph, tinted by state", () =>
    expect(byTitle(sidebarRows(makePR(), live(), undefined, NOW))).toEqual({
      CI: "ci-pass:success All 1 passed",
      Reviews: "person:secondary None yet",
      Comments: "comment:secondary None yet",
      Merge: "merge:success No conflicts",
    }));

  it("leads reviews with changes requested, then approvals, then who's still asked", () => {
    const reviewers = [
      { login: "bob", state: "approved" as const },
      { login: "carol", state: "changesRequested" as const },
      { login: "dana", state: "requested" as const },
    ];
    expect(byTitle(sidebarRows(makePR(), live({ reviewers }), undefined, NOW)).Reviews).toBe(
      "bubble:failure Changes from carol",
    );
    expect(byTitle(sidebarRows(makePR(), live({ reviewers: reviewers.slice(0, 1) }), undefined, NOW)).Reviews).toBe(
      "seal:success Approved by bob",
    );
    expect(byTitle(sidebarRows(makePR(), live({ reviewers: reviewers.slice(2) }), undefined, NOW)).Reviews).toBe(
      "person:pending Waiting on dana",
    );
  });

  it("counts unresolved threads and comments from the live conversation", () => {
    const feed = [
      { id: "t", kind: "thread" as const, author: "a", isBot: false, body: "?", at: "", url: "", resolved: false },
      { id: "c", kind: "comment" as const, author: "a", isBot: false, body: "hi", at: "", url: "" },
      { id: "b", kind: "comment" as const, author: "bot", isBot: true, body: "hi", at: "", url: "" },
    ];
    expect(byTitle(sidebarRows(makePR(), live({ feed }), undefined, NOW)).Comments).toBe(
      "comment:failure 1 unresolved · 2 comments",
    );
  });

  it("shows merge trouble and the queue only when there is some", () => {
    const rows = byTitle(
      sidebarRows(
        makePR({ mergeState: "conflicting", checks: [check("a", "failure")] }),
        live(),
        {
          comments: 0,
          commenters: [],
          threads: 0,
          unresolvedThreads: 0,
          reviews: [],
          requested: [],
          autoMerge: false,
          dropped: { at: "2026-09-25T11:35:00Z" },
        },
        NOW,
      ),
    );
    expect(rows.CI).toBe("ci-fail:failure 1 failed");
    expect(rows.Merge).toBe("warning:failure Conflicts with main");
    expect(rows["Merge Queue"]).toBe("queue-dropped:failure Dropped 25m ago");
    expect(byTitle(sidebarRows(makePR({ status: "merged" }), live(), undefined, NOW)).Merge).toBe(
      "merge:merged Merged into main",
    );
  });

  it("falls back to the list's activity when the details come from Stoplight's snapshot", () => {
    const pr = makePR({ review: "reviewRequired" });
    const rows = byTitle(
      sidebarRows(
        pr,
        detailFromSnapshot(pr),
        {
          comments: 3,
          commenters: ["a"],
          threads: 2,
          unresolvedThreads: 1,
          reviews: [],
          requested: ["dana"],
          autoMerge: false,
        },
        NOW,
      ),
    );
    expect(rows.Reviews).toBe("person:pending Waiting on dana");
    expect(rows.Comments).toBe("comment:failure 1 unresolved · 3 comments");
  });

  it("keeps every value short enough for the sidebar on every demo PR", () => {
    const { snapshot } = demoPRs(NOW);
    const activity = demoActivity(NOW);
    for (const pr of snapshot.prs) {
      for (const row of sidebarRows(pr, demoDetail(pr, NOW), activity[pr.id], NOW)) {
        expect(row.text.length, `${pr.number} ${row.title}: ${row.text}`).toBeLessThanOrEqual(26);
      }
    }
  });
});
