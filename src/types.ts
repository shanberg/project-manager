export interface PmConfig {
  /** @deprecated Use activePath and archivePath instead */
  paraPath?: string;
  activePath: string;
  archivePath: string;
  domains: Record<string, string>;
  subfolders: string[];
}

export const DEFAULT_DOMAINS: Record<string, string> = {
  M: "Marketing",
  DE: "Design Engineering",
  P: "Product Design",
  I: "Internal",
};

export const DEFAULT_SUBFOLDERS = [
  "deliverables",
  "docs",
  "resources",
  "previews",
  "working files",
];
