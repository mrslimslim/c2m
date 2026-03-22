import type { DiffFile, DiffHunk, DiffLine, FileChange } from "@codepilot/protocol";

export interface ParsedDiffFile extends Omit<DiffFile, "loadedHunks" | "nextHunkIndex"> {
  hunks: DiffHunk[];
}

const HUNK_HEADER = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/;

export function parseUnifiedDiff(
  diffText: string,
  changeHints: FileChange[] = [],
): ParsedDiffFile[] {
  if (!diffText.trim()) {
    return [];
  }

  const lines = diffText.split("\n");
  const files: ParsedDiffFile[] = [];
  let index = 0;

  while (index < lines.length) {
    const line = lines[index] ?? "";
    if (!line.startsWith("diff --git ")) {
      index += 1;
      continue;
    }

    const hint = files.length < changeHints.length ? changeHints[files.length] : undefined;
    const diffGitMatch = /^diff --git a\/(.+?) b\/(.+)$/.exec(line);
    let path = hint?.path ?? diffGitMatch?.[2] ?? diffGitMatch?.[1] ?? "";
    let kind = hint?.kind ?? "update";
    const hunks: DiffHunk[] = [];
    let addedLines = 0;
    let deletedLines = 0;

    index += 1;
    while (index < lines.length) {
      const current = lines[index] ?? "";
      if (current.startsWith("diff --git ")) {
        break;
      }
      if (current.startsWith("new file mode ")) {
        kind = "add";
        index += 1;
        continue;
      }
      if (current.startsWith("deleted file mode ")) {
        kind = "delete";
        index += 1;
        continue;
      }
      if (current.startsWith("+++ ")) {
        if (!hint?.path) {
          path = normalizeDiffPath(current.slice(4)) || path;
        }
        index += 1;
        continue;
      }
      if (current.startsWith("--- ")) {
        index += 1;
        continue;
      }

      const hunkMatch = HUNK_HEADER.exec(current);
      if (!hunkMatch) {
        index += 1;
        continue;
      }

      const oldStart = Number.parseInt(hunkMatch[1] ?? "0", 10);
      const oldLineCount = Number.parseInt(hunkMatch[2] ?? "1", 10);
      const newStart = Number.parseInt(hunkMatch[3] ?? "0", 10);
      const newLineCount = Number.parseInt(hunkMatch[4] ?? "1", 10);
      const hunkLines: DiffLine[] = [];

      index += 1;
      while (index < lines.length) {
        const hunkLine = lines[index] ?? "";
        if (hunkLine.startsWith("diff --git ") || hunkLine.startsWith("@@ ")) {
          break;
        }
        if (hunkLine === "\\ No newline at end of file") {
          index += 1;
          continue;
        }

        const prefix = hunkLine[0] ?? " ";
        const text = hunkLine.length > 0 ? hunkLine : " ";
        if (prefix === "+") {
          hunkLines.push({ kind: "add", text });
          addedLines += 1;
        } else if (prefix === "-") {
          hunkLines.push({ kind: "delete", text });
          deletedLines += 1;
        } else {
          hunkLines.push({ kind: "context", text });
        }
        index += 1;
      }

      hunks.push({
        oldStart,
        oldLineCount,
        newStart,
        newLineCount,
        lines: hunkLines,
      });
    }

    files.push({
      path,
      kind,
      addedLines,
      deletedLines,
      isTruncated: false,
      truncationReason: undefined,
      totalHunkCount: hunks.length,
      hunks,
    });
  }

  return files;
}

function normalizeDiffPath(rawPath: string): string {
  if (rawPath === "/dev/null") {
    return "";
  }
  if (rawPath.startsWith("a/") || rawPath.startsWith("b/")) {
    return rawPath.slice(2);
  }
  return rawPath;
}
