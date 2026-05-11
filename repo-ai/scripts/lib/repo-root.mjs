import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

function gitTopLevel(startDir) {
  try {
    const out = execFileSync('git', ['rev-parse', '--show-toplevel'], {
      cwd: startDir,
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
      maxBuffer: 1024 * 1024,
    });
    const root = out.trim();
    if (root && fs.existsSync(root)) {
      return path.resolve(root);
    }
  } catch {
    /* not a git work tree or git not installed */
  }
  return null;
}

/**
 * Repository root for indexing/search outputs (`repo-ai/embeddings.jsonl`, etc.).
 *
 * Resolution order:
 * 1. Explicit `--root` / `REPO_AI_ROOT`
 * 2. Walk upward until `repo-ai/package.json` exists (vendored toolkit layout)
 * 3. `git rev-parse --show-toplevel` from `startDir` (works with globally installed CLI)
 */
export function resolveRepoRoot(startDir = process.cwd(), explicitRoot = null) {
  if (explicitRoot) {
    return path.resolve(explicitRoot);
  }
  if (process.env.REPO_AI_ROOT) {
    return path.resolve(process.env.REPO_AI_ROOT);
  }

  let dir = path.resolve(startDir);
  while (true) {
    const marker = path.join(dir, 'repo-ai', 'package.json');
    if (fs.existsSync(marker)) {
      return dir;
    }
    const parent = path.dirname(dir);
    if (parent === dir) {
      break;
    }
    dir = parent;
  }

  const gitRoot = gitTopLevel(startDir);
  if (gitRoot) {
    return gitRoot;
  }

  throw new Error(
    `Could not resolve repository root from ${startDir}. Options:\n` +
      `  • Run inside a git clone (discovery uses git rev-parse),\n` +
      `  • Add vendor toolkit at <repo>/repo-ai/package.json, or\n` +
      `  • Set REPO_AI_ROOT or pass --root <absolute-repo-root>`
  );
}
