import { Color, Icon } from "@raycast/api";
import type { Image } from "@raycast/api";

/** Nearest built-in progress-circle icon for a 0..1 fraction. */
function progressIconSource(progress: number): Icon {
  if (progress >= 1) return Icon.CircleProgress100;
  if (progress >= 0.75) return Icon.CircleProgress75;
  if (progress >= 0.5) return Icon.CircleProgress50;
  if (progress >= 0.25) return Icon.CircleProgress25;
  if (progress > 0) return Icon.CircleProgress25;
  return Icon.Circle;
}

/**
 * Theme-adaptive progress ring from Raycast's built-in CircleProgress icons.
 *
 * Tinted with `Color.PrimaryText` (the adaptive foreground) so the ring is
 * visible in both light and dark — untinted, these icons render in a fixed dark
 * tone that disappears on a dark background. `tintColor` resolves `Color` enums
 * correctly (the standard pattern), unlike `getProgressIcon`'s baked-in SVG.
 */
export function progressRingIcon(progress: number): Image.ImageLike {
  return { source: progressIconSource(progress), tintColor: Color.PrimaryText };
}
