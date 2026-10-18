import { PRActivity } from "./activity";
import { CIGroup, CIJob, CIRun, FeedItem, PRDetail } from "./detail";
import { CIState, compactAgo, PullRequest } from "./model";

/** Markdown for a colored dot; images come from the extension so they can follow the theme. */
export type Dot = (state: CIState | "merged") => string;

const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"}`;

export function formatDuration(ms: number): string {
  const seconds = Math.max(0, Math.round(ms / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ${String(seconds % 60).padStart(2, "0")}s`;
  return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, "0")}m`;
}

export const ago = (iso: string, now: number) => {
  const short = compactAgo(iso, now);
  return short === "now" ? "just now" : `${short} ago`;
};

/** Seconds count up between refreshes, so a live view visibly ticks. */
const secondsAgo = (iso: string, now: number) => {
  const seconds = Math.max(0, Math.round((now - Date.parse(iso)) / 1000));
  return seconds < 60 ? `${seconds}s ago` : ago(iso, now);
};

/** Every line that stands for one thing reads the same way: a dot, the thing in bold, then details. */
export const row = (dot: string, subject: string, ...details: (string | false | undefined)[]) =>
  [`${dot} **${subject}**`, ...details.filter(Boolean)].join(" · ");

/** A collapsed or expanded section, toggled by a shortcut. */
const disclosure = (open: boolean, subject: string, shortcut: string) =>
  `${open ? "▾" : "▸"} **${subject}** · ${shortcut} to ${open ? "hide" : "show"}`;

/** Consecutive rows sit on their own lines inside one paragraph. */
const tight = (rows: string[]) => rows.map((r, i) => (i < rows.length - 1 ? `${r}  ` : r)).join("\n");

const HTML_TAGS =
  /<\/?(details|summary|p|div|span|sub|sup|a|b|i|em|strong|table|thead|tbody|tr|td|th|picture|source|kbd|code|pre|h[1-6]|ul|ol|li|hr|br|img|blockquote|g-emoji)\b[^>]*>/gi;

/** Comment markdown made safe for a quote: no HTML, no giant headings, no private images that won't load. */
export function cleanBody(body: string, max = 1500): string {
  const lines = body
    .replace(/\r\n/g, "\n")
    .replace(/<!--[\s\S]*?-->/g, "")
    .split("\n");
  let inFence = false;
  const out = lines.map((line) => {
    if (/^\s*(```|~~~)/.test(line)) {
      inFence = !inFence;
      return line;
    }
    if (inFence) return line;
    return line
      .replace(/<br\s*\/?>/gi, " ")
      .replace(HTML_TAGS, "")
      .replace(/!\[([^\]]*)\]\(([^)\s]+)[^)]*\)/g, (_, alt: string, url: string) => `[${alt || "image"}](${url})`)
      .replace(/^\s{0,3}#{1,6}\s+(.+?)\s*#*$/, "**$1**  ");
  });
  let text = out
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  if (text.length > max) {
    const cut = text.lastIndexOf("\n", max);
    text = `${text.slice(0, cut > max * 0.6 ? cut : max).trimEnd()} …`;
  }
  if ((text.match(/^\s*(```|~~~)/gm) ?? []).length % 2 === 1) text += "\n```";
  return text;
}

export const quote = (text: string) =>
  text
    .split("\n")
    .map((line) => (line.trim() ? `> ${line}` : ">"))
    .join("\n");

const fence = (text: string) => `\`\`\`\n${text.replace(/```/g, "ʼʼʼ")}\n\`\`\``;

export function firstLine(text: string, max = 140): string {
  const line =
    cleanBody(text, 10_000)
      .split("\n")
      .find((l) => l.trim() && !/^\s*(```|~~~)/.test(l)) ?? "";
  return line.length > max ? `${line.slice(0, max).trimEnd()}…` : line;
}

const elapsed = (job: { startedAt?: string; completedAt?: string }, now: number): number | undefined => {
  if (!job.startedAt) return undefined;
  const end = job.completedAt ? Date.parse(job.completedAt) : now;
  return end - Date.parse(job.startedAt);
};

const took = (job: CIJob, now: number) => {
  const ms = elapsed(job, now);
  return ms === undefined ? undefined : formatDuration(ms);
};

const jobOrder = (j: CIJob) =>
  j.state === "failure" ? 0 : j.running ? 1 : j.state === "pending" ? 2 : j.state === "success" ? 3 : 4;

function currentStep(job: CIJob): string | undefined {
  if (!job.steps?.length) return undefined;
  const step = job.steps.find((s) => s.running) ?? job.steps.find((s) => s.state === "pending");
  return step ? `step ${step.number} of ${job.steps.length}: ${step.name}` : undefined;
}

const failedStep = (job: CIJob) => job.steps?.find((s) => s.state === "failure")?.name;

export function names(jobs: CIJob[], max = 3): string {
  const shown = jobs.slice(0, max).map((j) => j.name);
  return jobs.length > max ? `${shown.join(", ")} and ${jobs.length - max} more` : shown.join(", ");
}

function span(jobs: CIJob[], now: number): number | undefined {
  const starts = jobs.flatMap((j) => (j.startedAt ? [Date.parse(j.startedAt)] : []));
  if (!starts.length) return undefined;
  const ends = jobs.flatMap((j) => (j.completedAt ? [Date.parse(j.completedAt)] : []));
  const end = jobs.some((j) => j.state === "pending") || !ends.length ? now : Math.max(...ends);
  return end - Math.min(...starts);
}

const runLabel: Record<CIRun["kind"], string | undefined> = {
  queue: "in the merge queue",
  merge: "after merge",
  head: undefined,
};

/** Which workflow run this is and how long it took: "Deploy · after merge · run #1519 · 18m 38s". */
function groupContext(group: CIGroup, kind: CIRun["kind"], now: number): string[] {
  const time = span(group.jobs, now);
  return [
    group.name,
    runLabel[kind],
    group.runNumber ? `run #${group.runNumber}` : undefined,
    time !== undefined ? formatDuration(time) : undefined,
  ].filter((part): part is string => Boolean(part));
}

function groupMarkdown(group: CIGroup, kind: CIRun["kind"], now: number, dot: Dot): string[] {
  const total = group.jobs.length;
  const heading = `#### ${groupContext(group, kind, now).join(" · ")}`;

  const sorted = [...group.jobs].sort((a, b) => jobOrder(a) - jobOrder(b) || a.name.localeCompare(b.name));
  const passed = sorted.filter((j) => j.state === "success");
  const skipped = sorted.filter((j) => j.state === "skipped");
  const queued = sorted.filter((j) => j.state === "pending" && !j.running);

  const out = [heading, ""];
  let rows: string[] = [];
  const flush = () => {
    if (rows.length) out.push(tight(rows), "");
    rows = [];
  };
  for (const job of sorted) {
    if (job.state === "failure") {
      const step = failedStep(job);
      rows.push(
        row(dot("failure"), job.name, step ? `failed at ${step}` : (job.description ?? "failed"), took(job, now)),
      );
      if (job.failure) {
        flush();
        out.push(fence(job.failure), "");
      }
    } else if (job.state === "pending" && job.running) {
      rows.push(row(dot("pending"), job.name, currentStep(job) ?? job.description ?? "running", took(job, now)));
    }
  }
  if (queued.length) rows.push(row(dot("none"), `${queued.length} queued`, names(queued)));
  if (passed.length === total) rows.push(row(dot("success"), total === 1 ? "Passed" : `All ${total} passed`));
  else if (passed.length) rows.push(row(dot("success"), `${passed.length} passed`, names(passed)));
  if (skipped.length) rows.push(row(dot("none"), `${skipped.length} skipped`, names(skipped)));
  flush();
  return out;
}

export function ciSummaryRow(detail: PRDetail, now: number, dot: Dot, context: string[] = []): string {
  const all = detail.runs.flatMap((r) => r.groups.flatMap((g) => g.jobs));
  const pending = all.filter((j) => j.state === "pending").length;
  const failed = all.filter((j) => j.state === "failure").length;
  const passed = all.filter((j) => j.state === "success").length;
  const skipped = all.filter((j) => j.state === "skipped").length;
  const freshness = !detail.live
    ? "from Stoplight's snapshot"
    : pending
      ? `live · updated ${secondsAgo(detail.fetchedAt, now)}`
      : `updated ${ago(detail.fetchedAt, now)}`;
  if (!all.length) return row(dot("none"), "No checks", "on the latest commit", detail.live && freshness);
  const withContext = (...details: (string | false | undefined)[]) => [...details, ...context, freshness];
  if (pending) {
    const done = all.length - pending;
    return row(dot("pending"), "Running", ...withContext(`${done} of ${all.length} done`));
  }
  const counts = (...parts: [number, string][]) => parts.filter(([n]) => n > 0).map(([n, word]) => `${n} ${word}`);
  if (failed)
    return row(dot("failure"), `${failed} failed`, ...counts([passed, "passed"], [skipped, "skipped"]), freshness);
  if (passed) {
    const subject = passed === all.length ? `All ${passed} passed` : `${passed} passed`;
    return row(dot("success"), subject, ...withContext(...counts([skipped, "skipped"])));
  }
  return row(dot("none"), `${skipped} skipped`, ...withContext("nothing ran"));
}

const humanize = (reason: string) => reason.toLowerCase().replace(/_/g, " ");

/** Where the PR stands in the merge queue, when it's in one or just fell out of one. */
export function queueRow(pr: PullRequest, activity: PRActivity | undefined, now: number, dot: Dot): string | undefined {
  if (pr.status !== "open") return undefined;
  const entry = activity?.queue ?? pr.mergeQueue ?? undefined;
  if (entry) {
    const blocking = entry.state === "UNMERGEABLE";
    const since = activity?.queue?.enqueuedAt;
    return row(
      dot(blocking ? "failure" : "pending"),
      `#${entry.position} in the merge queue`,
      blocking && "blocking everything behind it",
      since && `queued ${ago(since, now)}`,
    );
  }
  if (activity?.dropped) {
    const { reason, at } = activity.dropped;
    return row(dot("failure"), "Dropped from the merge queue", reason && humanize(reason), ago(at, now));
  }
  return undefined;
}

/** One workflow that passed is a single line; anything else gets a block per workflow. */
export function ciMarkdown(detail: PRDetail, now: number, dot: Dot, queue?: string): string[] {
  const groups = detail.runs.flatMap((run) => run.groups.map((group) => ({ group, kind: run.kind })));
  const settled = (g: CIGroup) => g.jobs.every((j) => j.state === "success" || j.state === "skipped");
  const only = groups.length === 1 && settled(groups[0].group) ? groups[0] : undefined;
  const context = only ? groupContext(only.group, only.kind, now) : [];
  const lines = [
    "### CI",
    "",
    tight([ciSummaryRow(detail, now, dot, context), queue].filter((r): r is string => Boolean(r))),
    "",
  ];
  if (only) return lines;
  for (const { group, kind } of groups) lines.push(...groupMarkdown(group, kind, now, dot));
  return lines;
}

const kindText: Record<FeedItem["kind"], string> = {
  approved: "approved",
  changesRequested: "requested changes",
  reviewed: "reviewed",
  dismissed: "review dismissed",
  comment: "commented",
  thread: "commented",
};

const kindDot = (item: FeedItem): CIState => {
  if (item.kind === "approved") return "success";
  if (item.kind === "changesRequested") return "failure";
  if (item.kind === "thread" && !item.resolved) return "failure";
  return "none";
};

function itemHeader(item: FeedItem, now: number, dot: Dot): string {
  if (item.kind !== "thread") {
    return row(dot(kindDot(item)), `@${item.author}`, kindText[item.kind], item.isBot && "bot", ago(item.at, now));
  }
  const where = item.path ? `\`${item.line ? `${item.path}:${item.line}` : item.path}\`` : "review thread";
  const replies = item.replies?.length ? plural(item.replies.length, "reply") : undefined;
  return row(
    dot(kindDot(item)),
    `@${item.author}`,
    where,
    item.resolved ? "resolved" : "unresolved",
    item.outdated && "outdated",
    item.resolved && replies,
    ago(item.at, now),
  );
}

/** Open threads and comments in full with their replies; a resolved thread is only its opening line. */
export function itemMarkdown(item: FeedItem, now: number, dot: Dot): string {
  const header = itemHeader(item, now, dot);
  if (item.kind === "thread" && item.resolved) {
    const opening = firstLine(item.body);
    return opening ? `${header}\n${quote(opening)}` : header;
  }
  const quoted: string[] = [];
  const body = cleanBody(item.body);
  if (body) quoted.push(body);
  const replies = item.replies ?? [];
  if (replies.length > 5) quoted.push(`_${plural(replies.length - 5, "earlier reply")}_`);
  for (const reply of replies.slice(-5)) {
    quoted.push(`**@${reply.author}** · ${ago(reply.at, now)}  \n${cleanBody(reply.body, 600)}`);
  }
  return quoted.length ? `${header}\n${quote(quoted.join("\n\n"))}` : header;
}

/** Each reviewer's latest say, oldest to newest, so a later approval replaces an earlier change request. */
function latestVerdicts(items: FeedItem[]): Set<FeedItem["kind"]> {
  const latest = new Map<string, FeedItem["kind"]>();
  for (const item of [...items].sort((a, b) => Date.parse(a.at) - Date.parse(b.at))) {
    if (item.kind === "approved" || item.kind === "changesRequested" || item.kind === "dismissed") {
      latest.set(item.author, item.kind);
    }
  }
  return new Set(latest.values());
}

export function conversationSummaryRow(items: FeedItem[], dot: Dot): string {
  if (!items.length) return row(dot("none"), "No comments yet");
  const authors = [...new Set(items.map((i) => `@${i.author}`))];
  const from = `from ${authors.slice(0, 3).join(", ")}${authors.length > 3 ? " and others" : ""}`;
  const unresolved = items.filter((i) => i.kind === "thread" && !i.resolved).length;
  const comments = items.filter((i) => i.body.trim()).length;
  const threads = unresolved > 0 ? plural(unresolved, "unresolved thread") : undefined;
  const talk = comments > 0 ? plural(comments, "comment") : undefined;
  const verdicts = latestVerdicts(items);
  if (verdicts.has("changesRequested")) return row(dot("failure"), "Changes requested", threads, talk, from);
  if (threads) return row(dot("failure"), threads, talk, from);
  if (verdicts.has("approved")) return row(dot("success"), "Approved", talk, from);
  return row(dot("none"), talk ?? "No comments yet", from);
}

export interface FeedOptions {
  showBots: boolean;
  botShortcut: string;
}

/** Unresolved threads first since they're what needs an answer, then everything else newest first. */
export function feedMarkdown(detail: PRDetail, now: number, dot: Dot, options: FeedOptions): string[] {
  const people = detail.feed.filter((item) => !item.isBot);
  const bots = detail.feed.filter((item) => item.isBot);
  const unresolved = people.filter((item) => item.kind === "thread" && !item.resolved);
  const rest = people.filter((item) => !unresolved.includes(item));
  const lines = ["### Conversation", "", conversationSummaryRow(people, dot)];
  for (const item of [...unresolved, ...rest]) lines.push("", itemMarkdown(item, now, dot));
  if (bots.length) {
    lines.push("", disclosure(options.showBots, plural(bots.length, "bot comment"), options.botShortcut));
    if (options.showBots) for (const item of bots) lines.push("", itemMarkdown(item, now, dot));
  }
  if (!detail.live) {
    lines.push(
      "",
      "_Stoplight's snapshot keeps the last 10 comments. With the GitHub CLI you also get threads and live CI._",
    );
  }
  return lines;
}

export function descriptionMarkdown(body: string, expanded: boolean, shortcut: string): string[] {
  const text = cleanBody(body, 8000);
  if (!text) return [];
  const toggle = disclosure(expanded, "Description", shortcut);
  return expanded ? [toggle, quote(text)] : [toggle];
}

export interface PageInput {
  pr: PullRequest;
  activity?: PRActivity;
  light: CIState | "merged";
  lightLabel: string;
  reasons: string[];
  detail: PRDetail;
  now: number;
  showDescription: boolean;
  showBots: boolean;
}

export function pageMarkdown(input: PageInput, dot: Dot): string {
  const { detail, now } = input;
  return [
    `## ${input.pr.title}`,
    "",
    row(
      dot(input.light),
      input.lightLabel,
      ...input.reasons.filter((r) => r.toLowerCase() !== input.lightLabel.toLowerCase()),
    ),
    "",
    ...descriptionMarkdown(detail.body, input.showDescription, "⌘D"),
    "",
    ...ciMarkdown(detail, now, dot, queueRow(input.pr, input.activity, now, dot)),
    "",
    ...feedMarkdown(detail, now, dot, { showBots: input.showBots, botShortcut: "⌥⌘B" }),
  ].join("\n");
}
