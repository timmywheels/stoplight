import { describe, expect, it } from "vitest";
import { PRActivity } from "../src/lib/activity";
import { demoActivity, demoDetail, demoPRs } from "../src/lib/demo";
import { CIJob, FeedItem, PRDetail } from "../src/lib/detail";
import {
  ciMarkdown,
  ciSummaryRow,
  cleanBody,
  conversationSummaryRow,
  descriptionMarkdown,
  feedMarkdown,
  formatDuration,
  pageMarkdown,
  queueRow,
} from "../src/lib/markdown";
import { makePR } from "./fixtures";

const NOW = Date.parse("2026-09-25T12:00:00Z");
const at = (minutesAgo: number) => new Date(NOW - minutesAgo * 60_000).toISOString();
const dot = (state: string) => `(${state})`;

const job = (name: string, state: CIJob["state"], extra: Partial<CIJob> = {}): CIJob => ({
  name,
  state,
  running: false,
  startedAt: at(10),
  completedAt: state === "pending" ? undefined : at(7),
  ...extra,
});

const detailWith = (jobs: CIJob[], extra: Partial<PRDetail> = {}): PRDetail => ({
  body: "",
  runs: [{ kind: "head", sha: "abc1234", groups: [{ name: "CI", runNumber: 7, jobs }] }],
  feed: [],
  reviewers: [],
  fetchedAt: at(0),
  live: true,
  ...extra,
});

const feedItem = (id: string, kind: FeedItem["kind"], minutesAgo: number, extra: Partial<FeedItem> = {}): FeedItem => ({
  id,
  kind,
  author: "alice",
  isBot: false,
  body: `${id} body`,
  at: at(minutesAgo),
  url: "u",
  ...extra,
});

describe("formatDuration", () => {
  it("reads like a stopwatch", () => {
    expect(formatDuration(42_000)).toBe("42s");
    expect(formatDuration(154_000)).toBe("2m 34s");
    expect(formatDuration(3_780_000)).toBe("1h 03m");
  });
});

describe("cleanBody", () => {
  it("drops HTML and hidden comments, and turns headings and images into plain markdown", () => {
    const body = [
      "<!-- linear-linkback -->",
      "## Summary",
      "<details><summary>More</summary>Hidden text</details>",
      "![screenshot](https://github.com/user-attachments/1 'x')",
    ].join("\n");
    expect(cleanBody(body)).toBe("**Summary**  \nMoreHidden text\n[screenshot](https://github.com/user-attachments/1)");
  });

  it("leaves code blocks alone and closes one a cut leaves open", () => {
    expect(cleanBody("```sh\n# not a heading\n```")).toBe("```sh\n# not a heading\n```");
    const long = `\`\`\`\n${"x\n".repeat(100)}\`\`\``;
    const cut = cleanBody(long, 50);
    expect(cut.endsWith("…\n```")).toBe(true);
  });
});

describe("CI", () => {
  it("summarizes a run in progress and counts seconds since the last refresh", () =>
    expect(ciSummaryRow(detailWith([job("a", "success"), job("b", "pending", { running: true })]), NOW, dot)).toBe(
      "(pending) **Running** · 1 of 2 done · live · updated 0s ago",
    ));

  it("summarizes a finished run by what failed", () => {
    const failed = detailWith([job("a", "failure"), job("b", "success"), job("c", "skipped")]);
    expect(ciSummaryRow(failed, NOW, dot)).toBe("(failure) **1 failed** · 1 passed · 1 skipped · updated just now");
    expect(ciSummaryRow(detailWith([job("a", "success")]), NOW, dot)).toBe(
      "(success) **All 1 passed** · updated just now",
    );
    expect(ciSummaryRow(detailWith([], { runs: [] }), NOW, dot)).toBe(
      "(none) **No checks** · on the latest commit · updated just now",
    );
    expect(ciSummaryRow(detailWith([job("a", "success")], { live: false }), NOW, dot)).toContain(
      "from Stoplight's snapshot",
    );
  });

  it("spells out failures with their step and log, running jobs with their step, and folds the rest", () => {
    const md = ciMarkdown(
      detailWith([
        job("lint", "success"),
        job("unit", "failure", {
          steps: [
            { number: 1, name: "Install", state: "success", running: false },
            { number: 2, name: "Run tests", state: "failure", running: false },
          ],
          failure: "FAIL a.test.ts",
        }),
        job("e2e", "pending", {
          running: true,
          steps: [
            { number: 1, name: "Install", state: "success", running: false },
            { number: 2, name: "Run Playwright", state: "pending", running: true },
            { number: 3, name: "Upload", state: "pending", running: false },
          ],
        }),
        job("deploy", "pending", { startedAt: undefined }),
      ]),
      NOW,
      dot,
    ).join("\n");
    expect(md).toContain("#### CI · run #7 · 10m 00s");
    expect(md).toContain("(failure) **unit** · failed at Run tests · 3m 00s\n\n```\nFAIL a.test.ts\n```");
    expect(md).toContain("(pending) **e2e** · step 2 of 3: Run Playwright · 10m 00s");
    expect(md).toContain("(none) **1 queued** · deploy");
    expect(md).toContain("(success) **1 passed** · lint");
  });

  it("folds a single passing workflow into the summary, naming which run it was", () => {
    const detail = detailWith([job("gate", "success")]);
    detail.runs[0].kind = "queue";
    expect(ciMarkdown(detail, NOW, dot)).toEqual([
      "### CI",
      "",
      "(success) **All 1 passed** · CI · in the merge queue · run #7 · 3m 00s · updated just now",
      "",
    ]);
  });

  it("gives each workflow its own block once there's more than one", () => {
    const detail = detailWith([job("gate", "success")]);
    detail.runs.push({
      kind: "merge",
      sha: "m1",
      groups: [{ name: "Deploy", runNumber: 9, jobs: [job("ship", "success")] }],
    });
    const md = ciMarkdown(detail, NOW, dot).join("\n");
    expect(md).toContain("#### CI · run #7 · 3m 00s");
    expect(md).toContain("#### Deploy · after merge · run #9 · 3m 00s");
  });
});

describe("queueRow", () => {
  const quiet: PRActivity = {
    comments: 0,
    commenters: [],
    threads: 0,
    unresolvedThreads: 0,
    reviews: [],
    requested: [],
    autoMerge: false,
  };

  it("says why a PR fell out of the queue", () =>
    expect(
      queueRow(makePR(), { ...quiet, dropped: { at: at(25), reason: "MERGE_GROUP_FAILED_CHECKS" } }, NOW, dot),
    ).toBe("(failure) **Dropped from the merge queue** · merge group failed checks · 25m ago"));

  it("shows the position and whether it's holding up the queue", () => {
    expect(queueRow(makePR({ mergeQueue: { position: 2, state: "QUEUED" } }), undefined, NOW, dot)).toBe(
      "(pending) **#2 in the merge queue**",
    );
    const blocking = { ...quiet, queue: { position: 1, state: "UNMERGEABLE", enqueuedAt: at(8) } };
    expect(queueRow(makePR(), blocking, NOW, dot)).toBe(
      "(failure) **#1 in the merge queue** · blocking everything behind it · queued 8m ago",
    );
    expect(queueRow(makePR({ status: "merged" }), blocking, NOW, dot)).toBeUndefined();
  });
});

describe("conversation", () => {
  it("puts unresolved threads first, then everything else newest first", () => {
    const detail = detailWith([], {
      feed: [
        feedItem("new", "comment", 1),
        feedItem("open", "thread", 30, { path: "src/a.ts", line: 3, resolved: false }),
        feedItem("done", "thread", 5, {
          path: "src/b.ts",
          resolved: true,
          replies: [{ author: "me", isBot: false, body: "Fixed", at: at(4), url: "u" }],
        }),
        feedItem("bot", "comment", 2, { author: "codecov[bot]", isBot: true }),
      ],
    });
    const md = feedMarkdown(detail, NOW, dot, { showBots: false, botShortcut: "⌥⌘B" }).join("\n");
    const order = ["open body", "new body", "done body"].map((text) => md.indexOf(text));
    expect(order).toEqual([...order].sort((a, b) => a - b));
    expect(md).toContain("(failure) **@alice** · `src/a.ts:3` · unresolved · 30m ago\n> open body");
    expect(md).toContain("(none) **@alice** · `src/b.ts` · resolved · 1 reply · 5m ago\n> done body");
    expect(md).not.toContain("Fixed");
    expect(md).not.toContain("bot body");
    expect(md).toContain("▸ **1 bot comment** · ⌥⌘B to show");

    const shown = feedMarkdown(detail, NOW, dot, { showBots: true, botShortcut: "⌥⌘B" }).join("\n");
    expect(shown).toContain("▾ **1 bot comment** · ⌥⌘B to hide");
    expect(shown).toContain("(none) **@codecov[bot]** · commented · bot · 2m ago");
  });

  it("quotes replies under the comment they answer", () => {
    const item = feedItem("q", "thread", 10, {
      path: "a.ts",
      resolved: false,
      replies: [{ author: "me", isBot: false, body: "Done", at: at(5), url: "u" }],
    });
    const md = feedMarkdown(detailWith([], { feed: [item] }), NOW, dot, { showBots: false, botShortcut: "" }).join(
      "\n",
    );
    expect(md).toContain("> q body\n>\n> **@me** · 5m ago  \n> Done");
  });

  it("sums up by each reviewer's latest say", () => {
    expect(conversationSummaryRow([], dot)).toBe("(none) **No comments yet**");
    const flipped = [feedItem("r1", "changesRequested", 60), feedItem("r2", "approved", 10)];
    expect(conversationSummaryRow(flipped, dot)).toBe("(success) **Approved** · 2 comments · from @alice");
    const blocked = [
      feedItem("r1", "changesRequested", 5, { author: "carol" }),
      feedItem("t", "thread", 9, { resolved: false }),
    ];
    expect(conversationSummaryRow(blocked, dot)).toBe(
      "(failure) **Changes requested** · 1 unresolved thread · 2 comments · from @carol, @alice",
    );
  });
});

describe("description", () => {
  it("is one line until it's opened", () => {
    expect(descriptionMarkdown("## Why\nBecause", false, "⌘D")).toEqual(["▸ **Description** · ⌘D to show"]);
    expect(descriptionMarkdown("## Why\nBecause", true, "⌘D")).toEqual([
      "▾ **Description** · ⌘D to hide",
      "> **Why**  \n> Because",
    ]);
    expect(descriptionMarkdown("  ", false, "⌘D")).toEqual([]);
  });
});

describe("the whole page", () => {
  it("doesn't repeat the light as its own reason", () => {
    const pr = makePR({ status: "merged" });
    const md = pageMarkdown(
      {
        pr,
        light: "merged",
        lightLabel: "Merged",
        reasons: ["Merged"],
        detail: detailWith([]),
        now: NOW,
        showDescription: false,
        showBots: false,
      },
      dot,
    );
    expect(md.split("\n")[2]).toBe("(merged) **Merged**");
  });

  it("writes every status line the same way: a dot, a bold subject, then details", () => {
    const { snapshot } = demoPRs(NOW);
    const activity = demoActivity(NOW);
    for (const pr of snapshot.prs) {
      const md = pageMarkdown(
        {
          pr,
          activity: activity[pr.id],
          light: "none",
          lightLabel: "Light",
          reasons: ["why"],
          detail: demoDetail(pr, NOW),
          now: NOW,
          showDescription: true,
          showBots: true,
        },
        dot,
      );
      const rows = md.split("\n").filter((line) => line.startsWith("("));
      expect(rows.length).toBeGreaterThan(2);
      for (const line of rows)
        expect(line).toMatch(/^\((failure|pending|success|none|merged)\) \*\*[^*]+\*\*( · \S.*)?( {2})?$/);
    }
  });
});
