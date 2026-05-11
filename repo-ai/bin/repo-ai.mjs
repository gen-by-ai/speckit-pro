#!/usr/bin/env node
/**
 * repo-ai — local vector index CLI (build + search).
 */
import path from 'node:path';
import process from 'node:process';
import { resolveRepoRoot } from '../scripts/lib/repo-root.mjs';
import { runBuild } from '../scripts/build-index.mjs';
import { runSearch } from '../scripts/search.mjs';

function usage() {
  console.log(`repo-ai — local embeddings index for repo instructions

Usage:
  repo-ai [options] build | index     Rebuild embeddings + vectordb index
  repo-ai [options] search <query>    Semantic search (JSON on stdout)
  repo-ai help                        Show this message

Options:
  -R, --root <dir>   Repository root (default: nearest repo-ai/package.json,
                       else git rev-parse --show-toplevel)

Search options:
  -q, --query <text>   Search query (alternative: positional argument)
  -k, --top-k <n>      Number of results (default: 8)
      --index <file>   Override path to index.json

Environment:
  REPO_AI_ROOT       Same as --root
  REPO_AI_GLOBS      Comma-separated globs for build (see build-index defaults)
  REPO_AI_QUERY      Default query for search if omitted

Examples:
  repo-ai build
  repo-ai search "how does pro.go work"
  repo-ai search -q "pipeline" -k 5
`);
}

function stripGlobalOptions(argv) {
  let explicitRoot = null;
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--root' || a === '-R') {
      explicitRoot = argv[++i];
      if (!explicitRoot) {
        console.error('repo-ai: missing value for --root');
        process.exit(2);
      }
      continue;
    }
    rest.push(a);
  }
  return { explicitRoot, rest };
}

function parseSearchArgs(argv) {
  const out = { query: '', topK: 8, indexPath: '' };
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--query' || a === '-q') {
      out.query = argv[++i] ?? '';
    } else if (a === '--top-k' || a === '-k') {
      out.topK = Math.max(1, parseInt(argv[++i] ?? '8', 10));
    } else if (a === '--index') {
      out.indexPath = argv[++i] ?? '';
    } else if (!a.startsWith('-')) {
      positional.push(a);
    }
  }
  if (!out.query && positional.length > 0) {
    out.query = positional.join(' ');
  }
  return out;
}

async function main() {
  const argv = process.argv.slice(2);
  if (argv.length === 0 || argv[0] === 'help' || argv[0] === '--help' || argv[0] === '-h') {
    usage();
    process.exit(argv.length === 0 ? 2 : 0);
  }

  const { explicitRoot, rest } = stripGlobalOptions(argv);
  const cmd = rest[0];
  const args = rest.slice(1);

  const repoRoot = resolveRepoRoot(process.cwd(), explicitRoot);

  if (cmd === 'build' || cmd === 'index') {
    await runBuild(repoRoot);
    return;
  }

  if (cmd === 'search') {
    const { query, topK, indexPath } = parseSearchArgs(args);
    const q = (query || process.env.REPO_AI_QUERY || '').trim();
    if (!q) {
      console.error('repo-ai search: provide a query (-q or positional)');
      process.exit(2);
    }
    await runSearch({ repoRoot, query: q, topK, indexPath });
    return;
  }

  console.error(`repo-ai: unknown command "${cmd}". Try: repo-ai help`);
  process.exit(2);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
