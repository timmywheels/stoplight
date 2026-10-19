import { Action, ActionPanel, Alert, Application, confirmAlert, Icon, Keyboard, showToast, Toast } from "@raycast/api";
import { ReactNode } from "react";
import { actionsRunURL, checksURL, isBranch, PullRequest, queueURL, shareLink, shortRef } from "./lib/model";
import { mergePullRequest } from "./lib/github";
import { STOPLIGHT_RELEASES } from "./lib/install";
import { glyph, stateColor } from "./style";

/** Ask, then merge the PR with its repo's default method, narrating the one step through a toast. */
async function merge(pr: PullRequest, gh: string, refresh: () => void) {
  const confirmed = await confirmAlert({
    title: `Merge ${shortRef(pr)}?`,
    message: pr.title,
    icon: glyph("merge", stateColor("success")),
    primaryAction: { title: "Merge", style: Alert.ActionStyle.Default },
  });
  if (!confirmed) return;
  const toast = await showToast({ style: Toast.Style.Animated, title: "Merging…" });
  try {
    await mergePullRequest(gh, pr);
    toast.style = Toast.Style.Success;
    toast.title = "Merged";
    refresh();
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = "Couldn't merge";
    toast.message = error instanceof Error ? error.message : String(error);
  }
}

/**
 * ↵ opens the PR on GitHub (also ⌘O). In the list ⌘↵ shows the details page; on the details page it copies the link.
 */
export function PRActions(props: {
  pr: PullRequest;
  stoplight?: Application;
  refresh: () => void;
  details?: ReactNode;
  view?: ReactNode;
  jobs?: ReactNode;
  viewer?: string;
  gh?: string;
}) {
  const { pr, stoplight, viewer, gh } = props;
  const run = actionsRunURL(pr);
  const queue = queueURL(pr);
  const onDetails = !props.details;
  // Your own open PR, and in a state GitHub would merge: the only time the button appears.
  const canMerge =
    gh &&
    viewer &&
    pr.author.toLowerCase() === viewer.toLowerCase() &&
    pr.status === "open" &&
    ["clean", "unstable"].includes(pr.mergeState);

  const copyURL = (
    <Action.CopyToClipboard
      title="Copy URL"
      icon={Icon.Link}
      content={pr.url}
      shortcut={Keyboard.Shortcut.Common.Copy}
    />
  );

  return (
    <ActionPanel title={shortRef(pr)}>
      <ActionPanel.Section>
        <Action.OpenInBrowser
          title={isBranch(pr) ? "Open Commit on GitHub" : "Open on GitHub"}
          icon={Icon.ArrowNe}
          url={pr.url}
          shortcut={Keyboard.Shortcut.Common.Open}
        />
        {props.details && <Action.Push title="Show Details" icon={Icon.Sidebar} target={props.details} />}
        {onDetails && copyURL}
      </ActionPanel.Section>
      {canMerge && (
        <ActionPanel.Section>
          <Action
            title="Merge Pull Request"
            icon={glyph("merge", stateColor("success"))}
            onAction={() => merge(pr, gh!, props.refresh)}
          />
        </ActionPanel.Section>
      )}
      {props.view && <ActionPanel.Section title="View">{props.view}</ActionPanel.Section>}
      <ActionPanel.Section title="Dig Deeper">
        {props.jobs}
        {!isBranch(pr) && (
          <Action.OpenInBrowser
            title="Open Files Changed"
            icon={Icon.Document}
            url={`${pr.url}/files`}
            shortcut={{ modifiers: ["cmd", "shift"], key: "f" }}
          />
        )}
        {run && (
          <Action.OpenInBrowser
            title="Open Actions Run"
            icon={Icon.BulletPoints}
            url={run}
            shortcut={{ modifiers: ["cmd", "shift"], key: "a" }}
          />
        )}
        {pr.checks.length > 0 && (
          <Action.OpenInBrowser
            title="Open Checks Tab"
            icon={Icon.CheckList}
            url={checksURL(pr)}
            shortcut={{ modifiers: ["cmd", "shift"], key: "k" }}
          />
        )}
        {queue && (
          <Action.OpenInBrowser
            title="Open Merge Queue"
            icon={glyph("queue")}
            url={queue}
            shortcut={{ modifiers: ["cmd", "shift"], key: "m" }}
          />
        )}
      </ActionPanel.Section>
      <ActionPanel.Section title="Copy">
        {!onDetails && copyURL}
        <Action.CopyToClipboard
          title="Share (Title as a Link)"
          icon={Icon.Upload}
          content={shareLink(pr)}
          shortcut={{ modifiers: ["cmd", "shift"], key: "l" }}
        />
        {pr.headRefName && (
          <Action.CopyToClipboard
            title="Copy Branch Name"
            icon={glyph("branch")}
            content={pr.headRefName}
            shortcut={{ modifiers: ["cmd"], key: "b" }}
          />
        )}
        {pr.headSha && (
          <Action.CopyToClipboard
            title={`Copy Commit Hash (${pr.headSha.slice(0, 7)})`}
            icon={Icon.Hashtag}
            content={pr.headSha}
            shortcut={{ modifiers: ["cmd", "shift"], key: "b" }}
          />
        )}
      </ActionPanel.Section>
      <ActionPanel.Section>
        <Action
          title="Refresh"
          icon={Icon.ArrowClockwise}
          onAction={props.refresh}
          shortcut={Keyboard.Shortcut.Common.Refresh}
        />
        {stoplight ? (
          <Action.Open
            title="Open Stoplight"
            icon={{ fileIcon: stoplight.path }}
            target={stoplight.path}
            shortcut={{ modifiers: ["cmd", "opt"], key: "o" }}
          />
        ) : (
          <Action.OpenInBrowser title="Get Stoplight" icon={Icon.Download} url={STOPLIGHT_RELEASES} />
        )}
      </ActionPanel.Section>
    </ActionPanel>
  );
}
