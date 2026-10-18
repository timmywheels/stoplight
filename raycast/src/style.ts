import { Color, environment, Icon, Image, List } from "@raycast/api";
import { Glyph, RowBadge, Tint } from "./lib/badges";
import { CIState, ColorProfile } from "./lib/model";
import { Column, ColumnGlyph, Light, lightState, StatusMark } from "./lib/status";

const exact = (light: string, dark: string): Color.Dynamic => ({ light, dark, adjustContrast: false });

/** macOS system colors, which is what Stoplight paints with, plus GitHub's merged purple. */
const palette = {
  failure: exact("#FF3B30", "#FF453A"),
  pending: exact("#FFCC00", "#FFD60A"),
  success: exact("#28CD41", "#32D74B"),
  successDeuteranopia: exact("#007AFF", "#0A84FF"),
  merged: exact("#8250DF", "#A371F7"),
};

export function stateColor(state: CIState, profile: ColorProfile = "default"): Color.ColorLike {
  if (state === "none") return Color.SecondaryText;
  if (state === "success" && profile === "deuteranopia") return palette.successDeuteranopia;
  return palette[state];
}

export function tintColor(tint: Tint, profile: ColorProfile): Color.ColorLike {
  if (tint === "secondary") return Color.SecondaryText;
  if (tint === "merged") return palette.merged;
  return stateColor(tint, profile);
}

const glyphFiles: Record<Exclude<Glyph | ColumnGlyph, "pin" | "stack">, string> = {
  merge: "merge.svg",
  "auto-merge": "merge.svg",
  branch: "branch.svg",
  xmark: "xmark.svg",
  warning: "warning.svg",
  queue: "queue.svg",
  "queue-dropped": "queue-dropped.svg",
  seal: "seal-check.svg",
  bubble: "bubble-exclaim.svg",
  person: "person-dashed.svg",
  comment: "comment.svg",
  "ci-pass": "ci-pass.svg",
  "ci-fail": "ci-fail.svg",
  "ci-running": "ci-running.svg",
  behind: "behind.svg",
  lock: "lock.svg",
};

export function glyph(name: Glyph | ColumnGlyph, color: Color.ColorLike = Color.PrimaryText): Image.ImageLike {
  const source = name === "pin" ? Icon.Pin : name === "stack" ? Icon.Layers : glyphFiles[name];
  return { source, tintColor: color };
}

export function dot(state: CIState, profile: ColorProfile, hollow = false): Image.ImageLike {
  return { source: hollow ? "dot-hollow.svg" : "dot.svg", tintColor: stateColor(state, profile) };
}

export function lightIcon(light: Light, profile: ColorProfile): Image.ImageLike {
  const state = lightState[light];
  return state === "merged" ? { source: "merged.svg", tintColor: palette.merged } : dot(state, profile);
}

export function statusImage(mark: StatusMark, profile: ColorProfile): Image.ImageLike {
  if (mark.kind === "merged")
    return { source: "merged.svg", tintColor: mark.broken ? palette.failure : palette.merged };
  return dot(mark.state, profile, mark.hollow);
}

export function badgeAccessory(badge: RowBadge, profile: ColorProfile): List.Item.Accessory {
  if (badge.kind === "glyph") {
    return { icon: glyph(badge.glyph, tintColor(badge.tint, profile)), tooltip: badge.tooltip };
  }
  return {
    icon: badge.glyph ? glyph(badge.glyph, tintColor(badge.tint, profile)) : undefined,
    tag: { value: badge.text, color: Color.SecondaryText },
    tooltip: badge.tooltip,
  };
}

/** Icon-only cells line up down the list; an empty cell keeps its width so the next column stays put. */
export function columnAccessory(column: Column, profile: ColorProfile): List.Item.Accessory {
  if (!column.glyph) return { icon: "blank.svg" };
  const icon = glyph(column.glyph, tintColor(column.tint, profile));
  if (column.count !== undefined) return { icon, text: String(column.count), tooltip: column.tooltip };
  return { icon, tooltip: column.tooltip };
}

const appearance = () => (environment.appearance === "dark" ? "dark" : "light");

/** Markdown images can't follow the theme, so these come pre-colored per appearance. */
export const markdownDot = (state: CIState | "merged") =>
  `![](dot-${state}-${appearance()}.svg?raycast-width=11&raycast-height=11)`;

/** Stoplight's menu bar glyph: all three lights on. */
export const menuBarDots: Image.ImageLike = {
  source: { light: "menubar-dots-light.svg", dark: "menubar-dots-dark.svg" },
};
