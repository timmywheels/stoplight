import { PRActivity } from "./activity";
import { Glyph, Tint } from "./badges";
import { PRDetail } from "./detail";
import { ago } from "./markdown";
import { ciState, PullRequest } from "./model";
import { ColumnGlyph } from "./status";

/** One line of the details sidebar: always its own glyph, tinted by state, with text short enough not to truncate. */
export interface SidebarRow {
  title: string;
  glyph: Glyph | ColumnGlyph;
  tint: Tint;
  text: string;
}

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;

const listed = (names: string[]) =>
  names.length > 2 ? `${names.slice(0, 2).join(", ")} +${names.length - 2}` : names.join(", ");

/** Worded like the CI section's summary row. */
function ciText(pr: PullRequest): string {
  const count = (state: string) => pr.checks.filter((c) => c.state === state).length;
  const [failed, pending, passed, skipped] = ["failure", "pending", "success", "skipped"].map(count);
  const total = pr.checks.length;
  if (!total) return "No checks";
  if (pending) return `${total - pending} of ${total} done`;
  if (failed) return passed ? `${failed} failed · ${passed} passed` : `${failed} failed`;
  if (passed === total) return `All ${total} passed`;
  return passed ? `${passed} passed · ${skipped} skipped` : `${skipped} skipped`;
}

function ciRow(pr: PullRequest): SidebarRow {
  const state = ciState(pr);
  const glyph = state === "failure" ? "ci-fail" : state === "pending" ? "ci-running" : "ci-pass";
  return { title: "CI", glyph, tint: state === "none" ? "secondary" : state, text: ciText(pr) };
}

function reviewRow(pr: PullRequest, detail: PRDetail, activity?: PRActivity): SidebarRow {
  const reviewers = detail.live
    ? detail.reviewers
    : [
        ...(activity?.reviews ?? []).map((r) => ({
          login: r.login,
          state:
            r.state === "APPROVED" ? "approved" : r.state === "CHANGES_REQUESTED" ? "changesRequested" : "commented",
        })),
        ...(activity?.requested ?? []).map((login) => ({ login, state: "requested" })),
      ];
  const who = (state: string) => reviewers.filter((r) => r.state === state).map((r) => r.login);
  const changes = who("changesRequested");
  const approved = who("approved");
  const requested = who("requested");
  if (changes.length)
    return { title: "Reviews", glyph: "bubble", tint: "failure", text: `Changes from ${listed(changes)}` };
  if (approved.length)
    return { title: "Reviews", glyph: "seal", tint: "success", text: `Approved by ${listed(approved)}` };
  if (requested.length)
    return { title: "Reviews", glyph: "person", tint: "pending", text: `Waiting on ${listed(requested)}` };
  if (pr.review === "changesRequested")
    return { title: "Reviews", glyph: "bubble", tint: "failure", text: "Changes requested" };
  if (pr.review === "approved") return { title: "Reviews", glyph: "seal", tint: "success", text: "Approved" };
  if (pr.review === "reviewRequired")
    return { title: "Reviews", glyph: "person", tint: "pending", text: "Review required" };
  return { title: "Reviews", glyph: "person", tint: "secondary", text: "None yet" };
}

function commentRow(detail: PRDetail, activity?: PRActivity): SidebarRow {
  const people = detail.feed.filter((item) => !item.isBot);
  const unresolved = detail.live
    ? people.filter((item) => item.kind === "thread" && !item.resolved).length
    : (activity?.unresolvedThreads ?? 0);
  const count = detail.live ? people.filter((item) => item.body.trim()).length : (activity?.comments ?? people.length);
  const parts = [unresolved ? `${unresolved} unresolved` : undefined, count ? plural(count, "comment") : undefined];
  return {
    title: "Comments",
    glyph: "comment",
    tint: unresolved ? "failure" : "secondary",
    text: parts.filter(Boolean).join(" · ") || "None yet",
  };
}

function mergeRow(pr: PullRequest): SidebarRow {
  const base = pr.baseRefName && pr.baseRefName.length <= 12 ? pr.baseRefName : "its base";
  if (pr.status === "merged") return { title: "Merge", glyph: "merge", tint: "merged", text: `Merged into ${base}` };
  if (pr.status === "closed") return { title: "Merge", glyph: "xmark", tint: "secondary", text: "Closed" };
  const tint = (t: Tint): Tint => (pr.isDraft ? "secondary" : t);
  switch (pr.mergeState) {
    case "conflicting":
      return { title: "Merge", glyph: "warning", tint: tint("failure"), text: `Conflicts with ${base}` };
    case "behind":
      return { title: "Merge", glyph: "behind", tint: tint("pending"), text: `Behind ${base}` };
    case "blocked":
      return { title: "Merge", glyph: "lock", tint: "secondary", text: "Blocked by rules" };
    default:
      return { title: "Merge", glyph: "merge", tint: tint("success"), text: "No conflicts" };
  }
}

function queueRow(pr: PullRequest, activity: PRActivity | undefined, now: number): SidebarRow | undefined {
  if (pr.status !== "open") return undefined;
  const entry = activity?.queue ?? pr.mergeQueue ?? undefined;
  if (entry) {
    const blocking = entry.state === "UNMERGEABLE";
    return {
      title: "Merge Queue",
      glyph: "queue",
      tint: blocking ? "failure" : "pending",
      text: blocking ? `#${entry.position} · blocking` : `#${entry.position} in line`,
    };
  }
  if (activity?.dropped) {
    return {
      title: "Merge Queue",
      glyph: "queue-dropped",
      tint: "failure",
      text: `Dropped ${ago(activity.dropped.at, now)}`,
    };
  }
  if (activity?.autoMerge)
    return { title: "Merge Queue", glyph: "auto-merge", tint: "secondary", text: "Auto-merge on" };
  return undefined;
}

export function sidebarRows(
  pr: PullRequest,
  detail: PRDetail,
  activity: PRActivity | undefined,
  now: number,
): SidebarRow[] {
  return [
    ciRow(pr),
    reviewRow(pr, detail, activity),
    commentRow(detail, activity),
    mergeRow(pr),
    queueRow(pr, activity, now),
  ].filter((r): r is SidebarRow => Boolean(r));
}
