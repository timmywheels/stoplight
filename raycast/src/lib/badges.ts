import { CIState, hasNonTrunkBase, PullRequest, Section, shortRef } from "./model";

export type Tint = CIState | "merged" | "secondary";
export type Glyph = "merge" | "branch" | "xmark" | "pin" | "stack";

/** One thing on a row after the title: a neutral capsule, optionally led by a small tinted glyph. */
export type RowBadge =
  | { kind: "tag"; text: string; glyph?: Glyph; tint: Tint; tooltip?: string }
  | { kind: "glyph"; glyph: Glyph; tint: Tint; tooltip: string };

/** Stoplight's row tags, minus what the status columns already say (merge state, review, queue). */
export function rowBadges(pr: PullRequest, sectionID: string, pinned: boolean): RowBadge[] {
  const badges: RowBadge[] = [];
  if (pr.isDraft) badges.push({ kind: "tag", text: "Draft", tint: "secondary" });
  if (pr.status === "merged" && sectionID !== "Merged") {
    badges.push({ kind: "tag", text: "Merged", glyph: "merge", tint: "merged" });
  }
  if (pr.status === "merged" && pr.baseState) {
    const health = { failure: "failing", pending: "running", success: "passing", none: "quiet" }[pr.baseState];
    badges.push({
      kind: "tag",
      text: pr.baseRefName,
      glyph: "branch",
      tint: pr.baseState,
      tooltip: `${pr.baseRefName} is ${health} right now`,
    });
  }
  if (pr.note) badges.push({ kind: "tag", text: pr.note, tint: "secondary" });
  if (pr.status === "closed") badges.push({ kind: "tag", text: "Closed", glyph: "xmark", tint: "failure" });
  if (hasNonTrunkBase(pr)) {
    badges.push({ kind: "glyph", glyph: "stack", tint: "secondary", tooltip: `Stacked on ${pr.baseRefName}` });
  }
  if (pinned) badges.push({ kind: "glyph", glyph: "pin", tint: "secondary", tooltip: "Pinned" });
  return badges;
}

/** The login behind "My PRs", so rows elsewhere can say whose PR it is. */
export function viewerLogin(prs: PullRequest[], sections: Section[]): string | undefined {
  const mine = sections.find((s) => s.id === "Mine");
  const first = mine?.prIDs.map((id) => prs.find((pr) => pr.id === id)).find(Boolean);
  return first?.author;
}

/** Stoplight's ref label: drops whatever the section header already says. */
export function refLabel(pr: PullRequest, section: Section): string {
  if (pr.number === 0) return shortRef(pr);
  const repo = pr.repo.toLowerCase();
  const title = section.title.toLowerCase();
  if (title === repo || title.startsWith("→")) return `#${pr.number}`;
  if (repo.startsWith(`${title}/`)) return `${pr.repo.slice(section.title.length + 1)} #${pr.number}`;
  return shortRef(pr);
}

export function showsAuthor(pr: PullRequest, section: Section, viewer?: string): boolean {
  if (pr.number === 0 || !pr.author) return false;
  if (viewer && pr.author.toLowerCase() === viewer.toLowerCase()) return false;
  if (section.id === "Mine" || section.id === "Merged") return false;
  return section.title.toLowerCase() !== `@${pr.author.toLowerCase()}`;
}

/** How deep each PR sits in a stack, like Stoplight's ↳: 1 when its base is another listed PR's branch in the same repo. */
export function stackDepths(prs: PullRequest[]): Map<string, number> {
  const byHead = new Map(prs.filter((p) => p.headRefName).map((p) => [`${p.repo.toLowerCase()}#${p.headRefName}`, p]));
  const depths = new Map<string, number>();
  const depth = (pr: PullRequest, seen: Set<string>): number => {
    const known = depths.get(pr.id);
    if (known !== undefined) return known;
    const parent = pr.baseRefName ? byHead.get(`${pr.repo.toLowerCase()}#${pr.baseRefName}`) : undefined;
    const d = parent && parent.id !== pr.id && !seen.has(parent.id) ? depth(parent, new Set(seen).add(pr.id)) + 1 : 0;
    depths.set(pr.id, d);
    return d;
  };
  for (const pr of prs) depth(pr, new Set());
  return depths;
}

/** Stoplight's stack layout: each stacked PR right after its parent, otherwise the list keeps its order. */
export function stackLayout<T extends { pr: PullRequest }>(rows: T[]): T[] {
  const key = (repo: string, branch: string) => `${repo.toLowerCase()}#${branch}`;
  const byHead = new Map(rows.filter((r) => r.pr.headRefName).map((r) => [key(r.pr.repo, r.pr.headRefName), r]));
  const parentOf = (r: T) => {
    const p = r.pr.baseRefName ? byHead.get(key(r.pr.repo, r.pr.baseRefName)) : undefined;
    return p && p !== r ? p : undefined;
  };
  const children = new Map<T, T[]>();
  for (const r of rows) {
    const p = parentOf(r);
    if (p) children.set(p, [...(children.get(p) ?? []), r]);
  }
  const out: T[] = [];
  const placed = new Set<T>();
  const place = (r: T) => {
    if (placed.has(r)) return;
    placed.add(r);
    out.push(r);
    for (const c of children.get(r) ?? []) place(c);
  };
  for (const r of rows) if (!parentOf(r)) place(r);
  for (const r of rows) place(r);
  return out;
}
