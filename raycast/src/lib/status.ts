import { PRActivity } from "./activity";
import { ciState, CIState, compactAgo, isUnresolvedMerge, PullRequest } from "./model";

/** The PR's own light: does it need you, is it waiting on someone else, or is it good to go. */
export type Light = "needsYou" | "waiting" | "ready" | "merged" | "quiet";

export const LIGHTS: Light[] = ["needsYou", "waiting", "ready", "quiet", "merged"];

export type Filter = "all" | Light;

/** A fresh install has no stored filter, and the dropdown can report an empty value before it has one. */
export const asFilter = (value: string | undefined): Filter =>
  LIGHTS.includes(value as Light) ? (value as Light) : "all";

export interface Verdict {
  light: Light;
  reasons: string[];
}

export const lightLabel: Record<Light, string> = {
  needsYou: "Needs you",
  waiting: "Waiting",
  ready: "Ready",
  merged: "Merged",
  quiet: "Nothing yet",
};

export const lightState: Record<Light, CIState | "merged"> = {
  needsYou: "failure",
  waiting: "pending",
  ready: "success",
  merged: "merged",
  quiet: "none",
};

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;

export function ciSummary(pr: PullRequest): string {
  const n = pr.checks.length;
  if (n === 0) return "No checks";
  const failed = pr.checks.filter((c) => c.state === "failure").length;
  const running = pr.checks.filter((c) => c.state === "pending").length;
  if (failed > 0) return `${failed} of ${plural(n, "check")} failed`;
  if (running > 0) return `${running} of ${plural(n, "check")} running`;
  return `${plural(n, "check")} passed`;
}

export function reviewSummary(pr: PullRequest, activity?: PRActivity): string {
  const approved = activity?.reviews.filter((r) => r.state === "APPROVED").map((r) => r.login) ?? [];
  const changes = activity?.reviews.filter((r) => r.state === "CHANGES_REQUESTED").map((r) => r.login) ?? [];
  const parts: string[] = [];
  if (changes.length) parts.push(`Changes requested by ${changes.join(", ")}`);
  if (approved.length) parts.push(`Approved by ${approved.join(", ")}`);
  if (activity?.requested.length) parts.push(`Waiting on ${activity.requested.join(", ")}`);
  if (parts.length) return parts.join(" · ");
  switch (pr.review) {
    case "approved":
      return "Approved";
    case "changesRequested":
      return "Changes requested";
    case "reviewRequired":
      return "Review required";
    default:
      return "No reviews";
  }
}

export function commentSummary(activity?: PRActivity): string {
  if (!activity) return "Comments unavailable";
  if (activity.comments === 0 && activity.threads === 0) return "No comments";
  const parts = [plural(activity.comments, "comment")];
  if (activity.unresolvedThreads > 0) parts.unshift(`${plural(activity.unresolvedThreads, "unresolved thread")}`);
  if (activity.commenters.length) parts.push(`from ${activity.commenters.join(", ")}`);
  return parts.join(" · ");
}

export function queueSummary(pr: PullRequest, activity?: PRActivity, now = Date.now()): string | undefined {
  const entry = activity?.queue ?? pr.mergeQueue ?? undefined;
  if (entry) {
    const blocked = entry.state === "UNMERGEABLE" ? " · blocked, everything behind it waits" : "";
    return `Position ${entry.position} in the merge queue${blocked}`;
  }
  if (activity?.dropped) {
    const why = activity.dropped.reason ? `: ${humanize(activity.dropped.reason)}` : "";
    return `Dropped from the merge queue ${compactAgo(activity.dropped.at, now)} ago${why}`;
  }
  if (activity?.autoMerge) return "Auto-merge on: merges when ready";
  return undefined;
}

export function mergeSummary(pr: PullRequest): string | undefined {
  if (pr.status !== "open") return undefined;
  switch (pr.mergeState) {
    case "conflicting":
      return `Conflicts with ${pr.baseRefName || "its base"}`;
    case "behind":
      return `Behind ${pr.baseRefName || "its base"}`;
    case "blocked":
      return "Blocked by branch protection";
    default:
      return undefined;
  }
}

export const humanize = (reason: string) => reason.toLowerCase().replace(/_/g, " ");

export function verdict(pr: PullRequest, activity?: PRActivity): Verdict {
  if (pr.status === "merged") {
    return isUnresolvedMerge(pr)
      ? { light: "needsYou", reasons: [`Merged, and ${pr.baseRefName} is still failing`] }
      : { light: "merged", reasons: ["Merged"] };
  }
  if (pr.status === "closed") return { light: "quiet", reasons: ["Closed"] };
  const ci = ciState(pr);
  const queue = activity?.queue ?? pr.mergeQueue ?? undefined;
  const changesRequested =
    pr.review === "changesRequested" || activity?.reviews.some((r) => r.state === "CHANGES_REQUESTED");
  const approved =
    pr.review === "approved" || (activity?.reviews.some((r) => r.state === "APPROVED") && !changesRequested);

  const needs: string[] = [];
  if (ci === "failure") needs.push("CI failed");
  if (changesRequested) needs.push("changes requested");
  if (pr.mergeState === "conflicting" && !pr.isDraft) needs.push("conflicts");
  if (activity?.dropped) needs.push("dropped from the merge queue");
  if (queue?.state === "UNMERGEABLE") needs.push("blocking the merge queue");
  if (activity && activity.unresolvedThreads > 0) needs.push(plural(activity.unresolvedThreads, "unresolved thread"));
  if (needs.length) return { light: "needsYou", reasons: needs };

  const waits: string[] = [];
  if (ci === "pending") waits.push("CI running");
  if (queue) waits.push(`#${queue.position} in the merge queue`);
  if (!pr.isDraft) {
    if (!approved && (pr.review === "reviewRequired" || (activity?.requested.length ?? 0) > 0)) {
      waits.push("waiting on review");
    }
    if (pr.mergeState === "behind") waits.push("behind its base");
    if (pr.mergeState === "blocked") waits.push("blocked by branch protection");
  }
  if (waits.length) return { light: "waiting", reasons: waits };

  if (ci === "success" || approved) {
    const why = [ci === "success" ? "CI passed" : "", approved ? "approved" : ""].filter(Boolean);
    return { light: "ready", reasons: why };
  }
  return { light: "quiet", reasons: ["No checks or reviews yet"] };
}

export type StatusMark = { kind: "merged"; broken: boolean } | { kind: "dot"; state: CIState; hollow: boolean };

/** The row's leading dot is the PR's own light; drafts are hollow, merged PRs get Stoplight's purple check. */
export function statusMark(pr: PullRequest, v: Verdict): StatusMark {
  if (pr.status === "merged") return { kind: "merged", broken: v.light === "needsYou" };
  return { kind: "dot", state: lightState[v.light] as CIState, hollow: pr.isDraft };
}

export function statusTooltip(pr: PullRequest, v: Verdict): string {
  const why = v.reasons.length ? `: ${v.reasons.join(", ")}` : "";
  return `${pr.isDraft ? "Draft · " : ""}${lightLabel[v.light]}${why}`;
}

export type Slot = "comments" | "review" | "ci" | "merge" | "queue";
export type ColumnGlyph =
  | "comment"
  | "seal"
  | "bubble"
  | "person"
  | "ci-pass"
  | "ci-fail"
  | "ci-running"
  | "warning"
  | "behind"
  | "lock"
  | "queue"
  | "queue-dropped"
  | "auto-merge";
export type ColumnTint = CIState | "secondary";

/** One cell in the row's status strip. No glyph means an empty cell, kept so the columns line up. */
export interface Column {
  slot: Slot;
  glyph?: ColumnGlyph;
  tint: ColumnTint;
  count?: number;
  tooltip?: string;
}

/** Comments · Review · CI · Merge · Queue, left to right, on every row. */
export function columns(pr: PullRequest, activity?: PRActivity, now = Date.now()): Column[] {
  const open = pr.status === "open";
  const cells: Column[] = [];

  if (activity && activity.comments + activity.unresolvedThreads > 0) {
    cells.push({
      slot: "comments",
      glyph: "comment",
      tint: activity.unresolvedThreads > 0 ? "failure" : "secondary",
      count: activity.comments,
      tooltip: commentSummary(activity),
    });
  } else cells.push({ slot: "comments", tint: "secondary" });

  const review = reviewSummary(pr, activity);
  const changes = pr.review === "changesRequested" || activity?.reviews.some((r) => r.state === "CHANGES_REQUESTED");
  const approved = pr.review === "approved" || activity?.reviews.some((r) => r.state === "APPROVED");
  const waiting = pr.review === "reviewRequired" || (activity?.requested.length ?? 0) > 0;
  if (!open) cells.push({ slot: "review", tint: "secondary" });
  else if (changes) cells.push({ slot: "review", glyph: "bubble", tint: "failure", tooltip: review });
  else if (approved) cells.push({ slot: "review", glyph: "seal", tint: "success", tooltip: review });
  else if (waiting) cells.push({ slot: "review", glyph: "person", tint: "pending", tooltip: review });
  else cells.push({ slot: "review", tint: "secondary" });

  const ci = ciState(pr);
  const ciGlyph = { failure: "ci-fail", pending: "ci-running", success: "ci-pass", none: undefined } as const;
  cells.push({ slot: "ci", glyph: ciGlyph[ci], tint: ci, tooltip: ci === "none" ? undefined : `CI: ${ciSummary(pr)}` });

  const merge = mergeSummary(pr);
  const mergeGlyph = { conflicting: "warning", behind: "behind", blocked: "lock" } as const;
  const mergeTint = { conflicting: "failure", behind: "pending", blocked: "secondary" } as const;
  if (merge && pr.mergeState in mergeGlyph) {
    const state = pr.mergeState as keyof typeof mergeGlyph;
    const tint = pr.isDraft ? "secondary" : mergeTint[state];
    cells.push({ slot: "merge", glyph: mergeGlyph[state], tint, tooltip: pr.isDraft ? `${merge} (draft)` : merge });
  } else cells.push({ slot: "merge", tint: "secondary" });

  const queue = queueSummary(pr, activity, now);
  const entry = activity?.queue ?? pr.mergeQueue ?? undefined;
  if (!open || !queue) cells.push({ slot: "queue", tint: "secondary" });
  else if (entry) {
    const blocked = entry.state === "UNMERGEABLE";
    cells.push({ slot: "queue", glyph: "queue", tint: blocked ? "failure" : "pending", tooltip: queue });
  } else if (activity?.dropped) cells.push({ slot: "queue", glyph: "queue-dropped", tint: "failure", tooltip: queue });
  else cells.push({ slot: "queue", glyph: "auto-merge", tint: "secondary", tooltip: queue });

  return cells;
}

export interface Dimension {
  slot: Slot;
  label: string;
  state: CIState;
  summary: string;
}

const cellState = (tint: ColumnTint, hasGlyph: boolean): CIState => (!hasGlyph || tint === "secondary" ? "none" : tint);

/** The same five cells as the row, spelled out for the details pane. */
export function dimensions(pr: PullRequest, activity?: PRActivity, now = Date.now()): Dimension[] {
  const cells = columns(pr, activity, now);
  const cell = (slot: Slot) => cells.find((c) => c.slot === slot)!;
  const state = (slot: Slot) => cellState(cell(slot).tint, Boolean(cell(slot).glyph));
  const open = pr.status === "open";
  const mergeable = open && ["clean", "unstable", "draft"].includes(pr.mergeState);
  return [
    { slot: "comments", label: "Comments", state: state("comments"), summary: commentSummary(activity) },
    { slot: "review", label: "Review", state: state("review"), summary: reviewSummary(pr, activity) },
    { slot: "ci", label: "CI", state: ciState(pr), summary: ciSummary(pr) },
    {
      slot: "merge",
      label: "Merge",
      state: mergeable ? "success" : state("merge"),
      summary:
        mergeSummary(pr) ??
        (pr.status === "merged"
          ? `Merged into ${pr.baseRefName || "its base"}`
          : mergeable
            ? `No conflicts with ${pr.baseRefName || "its base"}`
            : "Closed without merging"),
    },
    {
      slot: "queue",
      label: "Queue",
      state: state("queue"),
      summary: queueSummary(pr, activity, now) ?? "Not in a merge queue",
    },
  ];
}
