import { Action, ActionPanel, Application, Icon, Keyboard } from "@raycast/api";
import { ReactNode } from "react";
import { actionsRunURL, checksURL, isBranch, PullRequest, queueURL, reviewURL, shareLink, shortRef } from "./lib/model";
import { STOPLIGHT_RELEASES } from "./lib/install";
import { glyph } from "./style";

/**
 * ↵ is the first action, ⌘↵ the second. In the list, ↵ opens the details page and ⌘↵ reviews in Stoplight;
 * on the details page, ↵ reviews in Stoplight and ⌘↵ copies the link to share.
 */
export function PRActions(props: {
  pr: PullRequest;
  stoplight?: Application;
  refresh: () => void;
  details?: ReactNode;
  view?: ReactNode;
  jobs?: ReactNode;
}) {
  const { pr, stoplight } = props;
  const run = actionsRunURL(pr);
  const queue = queueURL(pr);
  const onDetails = !props.details;

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
        {props.details && <Action.Push title="Show Details" icon={Icon.Sidebar} target={props.details} />}
        {stoplight && !isBranch(pr) && (
          <Action.Open
            title="Review in Stoplight"
            icon={{ fileIcon: stoplight.path }}
            target={reviewURL(pr)}
            application={stoplight}
          />
        )}
        {onDetails && copyURL}
        <Action.OpenInBrowser
          title={isBranch(pr) ? "Open Commit on GitHub" : "Open on GitHub"}
          icon={Icon.ArrowNe}
          url={pr.url}
          shortcut={Keyboard.Shortcut.Common.Open}
        />
      </ActionPanel.Section>
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
