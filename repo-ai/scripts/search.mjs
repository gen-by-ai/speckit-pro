import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { pipeline } from '@xenova/transformers';
import { MODEL_ID } from './lib/constants.mjs';
import { resolveRepoRoot } from './lib/repo-root.mjs';

function dot(a, b) {
  let s = 0;
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) s += a[i] * b[i];
  return s;
}

function parseArgs(argv) {
  const out = { query: '', topK: 8, indexPath: '' };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--query' || a === '-q') {
      out.query = argv[++i] ?? '';
    } else if (a === '--top-k' || a === '-k') {
      out.topK = Math.max(1, parseInt(argv[++i] ?? '8', 10));
    } else if (a === '--index') {
      out.indexPath = argv[++i] ?? '';
    } else if (!a.startsWith('-') && !out.query) {
      out.query = a;
    }
  }
  return out;
}

/**
 * @param {{ repoRoot: string, query: string, topK?: number, indexPath?: string }} opts
 */
export async function runSearch(opts) {
  const { repoRoot, query } = opts;
  const topK = opts.topK ?? 8;
  const indexPath =
    opts.indexPath ||
    path.join(repoRoot, 'repo-ai', 'vectordb', 'index.json');

  let raw;
  try {
    raw = await fs.readFile(indexPath, 'utf8');
  } catch {
    console.error(
      `No index at ${indexPath}. Run: repo-ai build (from repo root after npm install in repo-ai/)`
    );
    process.exit(1);
  }

  const index = JSON.parse(raw);
  const extractor = await pipeline('feature-extraction', MODEL_ID, {
    revision: 'main',
  });
  const output = await extractor(query, { pooling: 'mean', normalize: true });
  const tensor = output?.data ?? output;
  const queryVec = Array.from(tensor);

  const scored = index.chunks.map((c) => ({
    score: dot(queryVec, c.embedding),
    id: c.id,
    path: c.path,
    type: c.type,
    heading: c.heading,
    text: c.text,
    tokens: c.tokens,
  }));

  scored.sort((a, b) => b.score - a.score);
  const top = scored.slice(0, topK);

  const payload = {
    query,
    model: index.model,
    topK,
    results: top,
  };

  console.log(JSON.stringify(payload, null, 2));
}

function isExecutedDirectly() {
  const arg = process.argv[1];
  if (!arg) return false;
  try {
    return import.meta.url === pathToFileURL(path.resolve(arg)).href;
  } catch {
    return false;
  }
}

async function cliMain() {
  const parsed = parseArgs(process.argv.slice(2));
  const q = (parsed.query || process.env.REPO_AI_QUERY || '').trim();
  if (!q) {
    console.error(
      'Usage: node scripts/search.mjs --query "your question" [--top-k 8]'
    );
    process.exit(2);
  }
  const repoRoot = resolveRepoRoot();
  await runSearch({
    repoRoot,
    query: q,
    topK: parsed.topK,
    indexPath: parsed.indexPath || undefined,
  });
}

if (isExecutedDirectly()) {
  cliMain().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
