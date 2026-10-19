import {
  Action,
  ActionPanel,
  Color,
  getApplications,
  getPreferenceValues,
  Icon,
  LaunchProps,
  List,
} from "@raycast/api";
import { useCachedPromise, useLocalStorage, usePromise } from "@raycast/utils";
import { existsSync } from "node:fs";
import { useMemo, useState } from "react";
import { PRActions } from "./actions";
import { PRDetailView, ViewRow } from "./detail";
import { SetupSection } from "./setup";
import { activityFromSnapshot, ActivityMap, fetchActivity, nodeID } from "./lib/activity";
import { refLabel, rowBadges, showsAuthor, stackDepths, stackLayout, viewerLogin } from "./lib/badges";
import { demoActivity, demoPRs } from "./lib/demo";
import { findGh } from "./lib/github";
import { STOPLIGHT_BUNDLE_ID } from "./lib/install";
import { GhSetup, ghSetup, setupSteps, StoplightSetup } from "./lib/setup";
import { ColorProfile, compactAgo, isBranch, isStale, orderedRows } from "./lib/model";
import { loadPRs, NoSourceError } from "./lib/source";
import { asFilter, columns, Filter, Light, lightLabel, LIGHTS, statusMark, statusTooltip, verdict } from "./lib/status";
import { badgeAccessory, columnAccessory, glyph, lightIcon, menuBarDots, statusImage } from "./style";

interface Preferences {
  ghPath?: string;
}

function accessories(row: ViewRow, pinned: boolean, profile: ColorProfile): List.Item.Accessory[] {
  const { pr } = row;
  const when = pr.mergedAt ?? pr.updatedAt;
  return [
    ...rowBadges(pr, row.section.id, pinned).map((badge) => badgeAccessory(badge, profile)),
    { text: compactAgo(when), tooltip: `${pr.mergedAt ? "Merged" : "Updated"} ${new Date(when).toLocaleString()}` },
    ...columns(pr, row.activity).map((column) => columnAccessory(column, profile)),
  ];
}

function FilterDropdown(props: {
  counts: Record<Light, number>;
  total: number;
  profile: ColorProfile;
  onChange: (f: Filter) => void;
}) {
  return (
    <List.Dropdown
      tooltip="Filter by where each PR stands"
      storeValue
      defaultValue="all"
      onChange={(value) => props.onChange(asFilter(value))}
    >
      <List.Dropdown.Item title={`All  ${props.total}`} value="all" icon={menuBarDots} />
      {LIGHTS.map((light) => (
        <List.Dropdown.Item
          key={light}
          title={`${lightLabel[light]}  ${props.counts[light]}`}
          value={light}
          icon={lightIcon(light, props.profile)}
        />
      ))}
    </List.Dropdown>
  );
}

/** Sections and rows in Stoplight's order, with each stacked PR under its parent the way Stoplight lays them out. */
function groupBySection(rows: ViewRow[]): { id: string; title: string; rows: ViewRow[] }[] {
  const groups: { id: string; title: string; rows: ViewRow[] }[] = [];
  for (const row of rows) {
    const last = groups[groups.length - 1];
    if (last?.id === row.section.id) last.rows.push(row);
    else groups.push({ id: row.section.id, title: row.section.title, rows: [row] });
  }
  return groups.map((group) => ({ ...group, rows: stackLayout(group.rows) }));
}

async function loadActivity(ids: string[], ghPath?: string, demo?: boolean): Promise<ActivityMap> {
  if (demo) return demoActivity();
  const gh = findGh(ghPath?.trim() || undefined);
  return gh ? fetchActivity(gh, ids) : {};
}

/** In demo mode, `setup` pretends Stoplight or the GitHub CLI is missing, for screenshots. */
type LaunchContext = {
  search?: string;
  demo?: boolean;
  pr?: number;
  setup?: { stoplight?: StoplightSetup; gh?: GhSetup };
};

const hasBrew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].some((path) => existsSync(path));

export default function Command(props: LaunchProps<{ launchContext?: LaunchContext }>) {
  const { ghPath } = getPreferenceValues<Preferences>();
  const demo = props.launchContext?.demo === true;
  const [filter, setFilter] = useState<Filter>("all");
  const [searchText, setSearchText] = useState(props.launchContext?.search ?? "");

  const { data, isLoading, error, revalidate } = useCachedPromise(
    async (path?: string, demo?: boolean) => (demo ? demoPRs() : loadPRs({ ghPath: path })),
    [ghPath, demo],
    { keepPreviousData: true },
  );
  const prIDs = useMemo(
    () => [...new Set((data?.snapshot.prs ?? []).filter((pr) => !isBranch(pr)).map((pr) => nodeID(pr.id)))].sort(),
    [data],
  );
  const {
    data: activity,
    isLoading: activityLoading,
    revalidate: revalidateActivity,
  } = useCachedPromise(loadActivity, [prIDs, ghPath, demo], { execute: prIDs.length > 0, keepPreviousData: true });
  const { data: apps } = usePromise(getApplications);
  const stoplight = apps?.find((app) => app.bundleId === STOPLIGHT_BUNDLE_ID);
  const ghFound = useMemo(() => (demo ? undefined : findGh(ghPath?.trim() || undefined)), [ghPath, demo]);
  const { data: ghState, revalidate: revalidateGh } = usePromise(ghSetup, [ghFound], { execute: !demo });
  const { value: dismissed = [], setValue: setDismissed } = useLocalStorage<string[]>("dismissed-setup", []);

  const profile = data?.snapshot.colorProfile ?? "default";
  const rows = useMemo<ViewRow[]>(() => {
    if (!data) return [];
    const depths = stackDepths(data.snapshot.prs);
    return orderedRows(data.snapshot).map((row) => {
      const a = activity?.[nodeID(row.pr.id)] ?? activityFromSnapshot(row.pr);
      return { ...row, activity: a, verdict: verdict(row.pr, a), depth: depths.get(row.pr.id) ?? 0 };
    });
  }, [data, activity]);
  const counts = useMemo(() => {
    const out = Object.fromEntries(LIGHTS.map((l) => [l, 0])) as Record<Light, number>;
    const seen = new Set<string>();
    for (const row of rows) {
      if (seen.has(row.pr.id)) continue;
      seen.add(row.pr.id);
      out[row.verdict.light] += 1;
    }
    return out;
  }, [rows]);
  const pinned = useMemo(() => new Set(data?.snapshot.pinnedIDs ?? []), [data]);
  const viewer = useMemo(() => (data ? viewerLogin(data.snapshot.prs, data.snapshot.sections) : undefined), [data]);
  const visible = filter === "all" ? rows : rows.filter((row) => row.verdict.light === filter);
  const total = new Set(rows.map((row) => row.pr.id)).size;
  const refresh = () => {
    revalidate();
    revalidateActivity();
    if (!demo) revalidateGh();
  };

  const override = demo ? props.launchContext?.setup : undefined;
  const stoplightState: StoplightSetup | undefined =
    override?.stoplight ??
    (demo || data?.source === "stoplight"
      ? "running"
      : apps && (data || error)
        ? stoplight
          ? "installed"
          : "missing"
        : undefined);
  const ghStateShown: GhSetup | undefined = override?.gh ?? (demo ? "ready" : ghState);
  const steps = stoplightState && ghStateShown ? setupSteps(stoplightState, ghStateShown, dismissed) : [];

  const linked = props.launchContext?.pr;
  const linkedRow = linked ? rows.find((row) => row.pr.number === linked) : undefined;
  const detailView = (row: ViewRow) => (
    <PRDetailView
      row={row}
      stoplight={stoplight}
      refresh={refresh}
      ghPath={ghPath}
      demo={demo}
      showAuthor={showsAuthor(row.pr, row.section, viewer)}
      viewer={viewer}
      profile={profile}
    />
  );
  if (linkedRow) return detailView(linkedRow);

  const navigationTitle =
    data?.source === "gh"
      ? "Stoplight · via GitHub CLI (Stoplight isn't running)"
      : data && isStale(data.snapshot)
        ? `Stoplight · last updated ${compactAgo(data.snapshot.writtenAt)} ago`
        : "Stoplight";

  return (
    <List
      isLoading={isLoading || activityLoading}
      filtering
      searchText={searchText}
      onSearchTextChange={setSearchText}
      navigationTitle={navigationTitle}
      searchBarPlaceholder={total ? `Search ${total} pull requests…` : "Search pull requests…"}
      searchBarAccessory={<FilterDropdown counts={counts} total={total} profile={profile} onChange={setFilter} />}
    >
      <SetupSection
        steps={steps}
        stoplight={stoplight}
        hasBrew={hasBrew}
        refresh={refresh}
        dismiss={(id) => setDismissed([...new Set([...dismissed, id])])}
      />
      {error && !data && !(error instanceof NoSourceError) ? (
        <List.EmptyView
          icon={glyph("warning", Color.SecondaryText)}
          title={error instanceof NoSourceError ? "Nothing to read from" : "Couldn't load pull requests"}
          description={error.message}
          actions={
            <ActionPanel>
              {stoplight && <Action.Open title="Open Stoplight" target={stoplight.path} />}
              <Action title="Try Again" icon={Icon.ArrowClockwise} onAction={refresh} />
            </ActionPanel>
          }
        />
      ) : (
        <List.EmptyView
          icon={filter === "all" ? menuBarDots : lightIcon(filter, profile)}
          title={filter === "all" ? "No open PRs" : `Nothing marked ${lightLabel[filter].toLowerCase()}`}
          description={filter === "all" ? undefined : "Pick another filter to see the rest."}
        />
      )}
      {groupBySection(visible).map((group) => (
        <List.Section key={group.id} title={group.title.toUpperCase()} subtitle={String(group.rows.length)}>
          {group.rows.map((row) => {
            const { key, pr, section } = row;
            const ref = refLabel(pr, section);
            const indent = row.depth > 0 ? `${"   ".repeat(row.depth - 1)}↳ ` : "";
            return (
              <List.Item
                key={key}
                id={key}
                icon={{
                  value: statusImage(statusMark(pr, row.verdict), profile),
                  tooltip: statusTooltip(pr, row.verdict),
                }}
                title={`${indent}${pr.title}`}
                subtitle={showsAuthor(pr, section, viewer) ? `${ref} · @${pr.author}` : ref}
                keywords={[pr.repo, String(pr.number), pr.headRefName, pr.author].filter(Boolean)}
                accessories={accessories(row, pinned.has(pr.id), profile)}
                actions={
                  <PRActions
                    pr={pr}
                    stoplight={stoplight}
                    refresh={refresh}
                    details={detailView(row)}
                    viewer={viewer}
                    gh={ghFound}
                  />
                }
              />
            );
          })}
        </List.Section>
      ))}
    </List>
  );
}
