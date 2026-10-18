import { describe, expect, it } from "vitest";
import { demoActivity, demoPRs } from "../src/lib/demo";
import { columns, verdict } from "../src/lib/status";

describe("demo data", () => {
  const { snapshot } = demoPRs();
  const activity = demoActivity();

  it("has activity for every PR", () =>
    expect(Object.keys(activity).sort()).toEqual(snapshot.prs.map((p) => p.id).sort()));

  it("covers every light and every column glyph the screenshots should show", () => {
    const lights = new Set(snapshot.prs.map((pr) => verdict(pr, activity[pr.id]).light));
    expect([...lights].sort()).toEqual(["merged", "needsYou", "quiet", "ready", "waiting"]);
    const glyphs = new Set(snapshot.prs.flatMap((pr) => columns(pr, activity[pr.id]).map((c) => c.glyph)));
    for (const g of [
      "comment",
      "seal",
      "bubble",
      "person",
      "ci-pass",
      "ci-fail",
      "ci-running",
      "behind",
      "queue",
      "queue-dropped",
    ]) {
      expect(glyphs).toContain(g);
    }
  });
});
