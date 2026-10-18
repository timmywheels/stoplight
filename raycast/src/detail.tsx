import { Action, Application, Color, Detail, Icon } from "@raycast/api";
import { useCachedPromise } from "@raycast/utils";
import { useEffect, useMemo, useState } from "react";
import { PRActions } from "./actions";
import { PRActivity } from "./lib/activity";
import { demoDetail } from "./lib/demo";
import { detailFromSnapshot, fetchDetail, isRunning, jobs, liveChecks, PRDetail } from "./lib/detail";
import { findGh } from "./lib/github";
import { ago, pageMarkdown } from "./lib/markdown";
import { ColorProfile, isBranch, PullRequest, Row, shortRef } from "./lib/model";
import { sidebarRows } from "./lib/sidebar";
import { lightLabel, statusMark, verdict, Verdict } from "./lib/status";
import { glyph, markdownDot, stateColor, tintColor } from "./style";

export interface ViewRow extends Row {
  activity?: PRActivity;
  verdict: Verdict;
  depth: number;
}

const POLL_SECONDS = 10;

async function loadDetail(pr: PullRequest, demo: boolean, gh?: string): Promise<PRDetail> {
  if (demo) return demoDetail(pr);
  if (!gh || isBranch(pr)) return detailFromSnapshot(pr);
  return fetchDetail(gh, pr);
}

function markdown(
  pr: PullRequest,
  activity: PRActivity | undefined,
  v: Verdict,
  detail: PRDetail,
  now: number,
  view: { description: boolean; bots: boolean },
) {
  const mark = statusMark(pr, v);
  return pageMarkdown(
    {
      pr,
      activity,
      light: mark.kind === "dot" ? mark.state : mark.broken ? "failure" : "merged",
      lightLabel: lightLabel[v.light],
      reasons: v.reasons,
      detail,
      now,
      showDescription: view.description,
      showBots: view.bots,
    },
    markdownDot,
  );
}

export function PRDetailView(props: {
  row: ViewRow;
  stoplight?: Application;
  refresh: () => void;
  ghPath?: string;
  demo: boolean;
  showAuthor: boolean;
  profile: ColorProfile;
}) {
  const { pr, activity } = props.row;
  const { profile } = props;
  const gh = useMemo(() => (props.demo ? undefined : findGh(props.ghPath?.trim() || undefined)), [props.ghPath]);
  const [showDescription, setShowDescription] = useState(false);
  const [showBots, setShowBots] = useState(false);

  const { data, isLoading, revalidate } = useCachedPromise(
    (repo: string, number: number, demo: boolean, path?: string) => loadDetail({ ...pr, repo, number }, demo, path),
    [pr.repo, pr.number, props.demo, gh],
    { keepPreviousData: true, failureToastOptions: { title: "Couldn't load live details" } },
  );
  const detail = data ?? detailFromSnapshot(pr);
  const running = detail.live && isRunning(detail);

  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (!running) return;
    const tick = setInterval(() => setNow(Date.now()), 1000);
    const poll = setInterval(revalidate, POLL_SECONDS * 1000);
    return () => {
      clearInterval(tick);
      clearInterval(poll);
    };
  }, [running, revalidate]);
  const clock = running ? now : Date.now();

  const checks = detail.live ? liveChecks(detail) : undefined;
  const livePR = checks ? { ...pr, checks } : pr;
  const v = verdict(livePR, activity);
  const rows = sidebarRows(livePR, detail, activity, clock);
  const when = pr.mergedAt ?? pr.updatedAt;
  const refresh = () => {
    revalidate();
    props.refresh();
  };

  return (
    <Detail
      isLoading={isLoading}
      navigationTitle={shortRef(pr)}
      markdown={markdown(livePR, activity, v, detail, clock, { description: showDescription, bots: showBots })}
      metadata={
        <Detail.Metadata>
          {!isBranch(pr) && (
            <Detail.Metadata.Link title="Pull Request" text={`${pr.repo}#${pr.number}`} target={pr.url} />
          )}
          {rows.map((r) => (
            <Detail.Metadata.Label
              key={r.title}
              title={r.title}
              icon={glyph(r.glyph, tintColor(r.tint, profile))}
              text={r.text}
            />
          ))}
          <Detail.Metadata.Separator />
          <Detail.Metadata.Label
            title="Branch"
            icon={glyph("branch", Color.SecondaryText)}
            text={pr.baseRefName ? `${pr.headRefName} → ${pr.baseRefName}` : pr.headRefName}
          />
          {props.showAuthor && <Detail.Metadata.Label title="Author" text={`@${pr.author}`} />}
          <Detail.Metadata.Label title={pr.mergedAt ? "Merged" : "Updated"} text={ago(when, clock)} />
        </Detail.Metadata>
      }
      actions={
        <PRActions
          pr={pr}
          stoplight={props.stoplight}
          refresh={refresh}
          jobs={jobs(detail)
            .filter((job) => job.url && (job.state === "failure" || job.running))
            .slice(0, 5)
            .map((job, i) => (
              <Action.OpenInBrowser
                key={`${job.name}:${i}`}
                title={`${job.state === "failure" ? "Open Failed Job" : "Watch Job"}: ${job.name}`}
                icon={glyph(
                  job.state === "failure" ? "ci-fail" : "ci-running",
                  stateColor(job.state === "failure" ? "failure" : "pending"),
                )}
                url={job.url!}
                shortcut={i === 0 ? { modifiers: ["cmd", "shift"], key: "j" } : undefined}
              />
            ))}
          view={
            <>
              {detail.body.trim() && (
                <Action
                  title={showDescription ? "Hide Description" : "Show Description"}
                  icon={Icon.Paragraph}
                  onAction={() => setShowDescription((shown) => !shown)}
                  shortcut={{ modifiers: ["cmd"], key: "d" }}
                />
              )}
              {detail.feed.some((item) => item.isBot) && (
                <Action
                  title={showBots ? "Hide Bot Comments" : "Show Bot Comments"}
                  icon={Icon.Bubble}
                  onAction={() => setShowBots((shown) => !shown)}
                  shortcut={{ modifiers: ["cmd", "opt"], key: "b" }}
                />
              )}
            </>
          }
        />
      }
    />
  );
}
