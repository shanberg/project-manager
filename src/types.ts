export interface PmConfig {
  /** @deprecated Use activePath and archivePath instead */
  paraPath?: string;
  activePath: string;
  archivePath: string;
  domains: Record<string, string>;
  subfolders: string[];
}

export const DEFAULT_DOMAINS: Record<string, string> = {
  W: "Work",
  P: "Personal",
  L: "Learning",
  O: "Other",
};

export const DEFAULT_SUBFOLDERS = [
  "deliverables",
  "docs",
  "resources",
  "previews",
  "working files",
];
