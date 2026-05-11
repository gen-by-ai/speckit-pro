import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import fg from 'fast-glob';
import { AutoTokenizer, pipeline } from '@xenova/transformers';
import { slugifyHeading, splitByH2 } from './lib/chunk-md.mjs';
import { MODEL_ID } from './lib/constants.mjs';
import { resolveRepoRoot } from './lib/repo-root.mjs';

const MIN_TOKENS = 30;
const MAX_TOKENS = 512;

const DEFAULT_GLOBS = [
  '.agents/**/*.md',
  '.cursor/rules/**/*.{md,mdc}',
  '.specify/**/*.md',
  '.github/agents/**/*.md',
  'REQUEST.md',
  'README.md',
  'extension.yml',
];

const IGNORE = [
  '**/node_modules/**',
  '**/repo-ai/embeddings.jsonl',
  '**/repo-ai/vectordb/**',
];

function classifyType(relPath) {
  const p = relPath.replace(/\\/g, '/');
  if (p.startsWith('.agents/')) return 'agent';
  if (p.startsWith('.cursor/rules/')) return 'rule';
  if (p.startsWith('.specify/')) return 'spec';
  if (p.startsWith('.github/agents/')) return 'agent';
  if (p.startsWith('commands/')) return 'command';
  return 'instruction';
}

function makeChunkId(type, relPath, slug) {
  const norm = relPath.replace(/\\/g, '/');
  return `(${type}/${norm})#${slug}`;
}

async function countTokens(tokenizer, text) {
  const enc = await tokenizer(text);
  const ids = enc.input_ids;
  const len = ids instanceof Array ? ids.length : ids?.data?.length ?? 0;
  return Math.max(1, len - 2);
}

async function splitToTokenBudget(tokenizer, text, maxTokens) {
  const pieces = [];
  const paras = text.split(/\n{2,}/);
  let buf = '';
  for (const para of paras) {
    const trial = buf ? `${buf}\n\n${para}` : para;
    const n = await countTokens(tokenizer, trial);
    if (n <= maxTokens) {
      buf = trial;
      continue;
    }
    if (buf) {
      pieces.push(buf);
      buf = para;
      const pn = await countTokens(tokenizer, buf);
      if (pn > maxTokens) {
        const words = para.split(/\s+/);
        let wbuf = '';
        for (const w of words) {
          const t2 = wbuf ? `${wbuf} ${w}` : w;
          const tn = await countTokens(tokenizer, t2);
          if (tn > maxTokens && wbuf) {
            pieces.push(wbuf);
            wbuf = w;
          } else {
            wbuf = t2;
          }
        }
        if (wbuf) buf = wbuf;
        else buf = '';
      }
    } else {
      const words = para.split(/\s+/);
      let wbuf = '';
      for (const w of words) {
        const t2 = wbuf ? `${wbuf} ${w}` : w;
        const tn = await countTokens(tokenizer, t2);
        if (tn > maxTokens && wbuf) {
          pieces.push(wbuf);
          wbuf = w;
        } else {
          wbuf = t2;
        }
      }
      buf = wbuf;
    }
  }
  if (buf) pieces.push(buf);
  return pieces.length ? pieces : [text.slice(0, 4000)];
}

async function finalizeSections(tokenizer, rawSections) {
  const merged = [];
  let pending = [];

  for (const sec of rawSections) {
    const block =
      sec.heading === '_intro'
        ? sec.body
        : `## ${sec.heading}\n\n${sec.body}`;
    const t = await countTokens(tokenizer, block);
    if (t < MIN_TOKENS) {
      pending.push(sec);
      const combinedText = pending
        .map((p) =>
          p.heading === '_intro'
            ? p.body
            : `## ${p.heading}\n\n${p.body}`
        )
        .join('\n\n');
      const ct = await countTokens(tokenizer, combinedText);
      if (ct >= MIN_TOKENS) {
        merged.push({
          heading: pending
            .map((p) => (p.heading === '_intro' ? '_intro' : p.heading))
            .join(' / '),
          body: pending
            .map((p) =>
              p.heading === '_intro' ? p.body : `## ${p.heading}\n\n${p.body}`
            )
            .join('\n\n'),
        });
        pending = [];
      }
      continue;
    }
    if (pending.length) {
      const combinedText = pending
        .map((p) =>
          p.heading === '_intro' ? p.body : `## ${p.heading}\n\n${p.body}`
        )
        .join('\n\n');
      merged.push({
        heading: pending
          .map((p) => (p.heading === '_intro' ? '_intro' : p.heading))
          .join(' / '),
        body: combinedText,
      });
      pending = [];
    }
    merged.push(sec);
  }
  if (pending.length) {
    const combinedText = pending
      .map((p) =>
        p.heading === '_intro' ? p.body : `## ${p.heading}\n\n${p.body}`
      )
      .join('\n\n');
    merged.push({
      heading: pending
        .map((p) => (p.heading === '_intro' ? '_intro' : p.heading))
        .join(' / '),
      body: combinedText,
    });
  }

  const normalized = [];
  for (const sec of merged) {
    const block =
      sec.heading.includes(' / ') || sec.heading === '_intro'
        ? sec.body
        : `## ${sec.heading}\n\n${sec.body}`;
    const t = await countTokens(tokenizer, block);
    if (t > MAX_TOKENS) {
      const parts = await splitToTokenBudget(tokenizer, block, MAX_TOKENS);
      const baseSlug = slugifyHeading(sec.heading.split(' / ')[0] || 'section');
      parts.forEach((p, idx) => {
        normalized.push({
          heading: sec.heading,
          body: p,
          partIndex: parts.length > 1 ? idx + 1 : 0,
          partTotal: parts.length,
          baseSlug,
        });
      });
    } else {
      const bodyText =
        sec.heading === '_intro'
          ? sec.body
          : block.includes('##')
            ? block
            : `## ${sec.heading}\n\n${sec.body}`;
      normalized.push({
        heading: sec.heading,
        body: bodyText,
        partIndex: 0,
        partTotal: 1,
        baseSlug: slugifyHeading(sec.heading.split(' / ')[0] || 'section'),
      });
    }
  }
  return normalized;
}

async function loadFile(repoRoot, relPath) {
  const abs = path.join(repoRoot, relPath);
  const raw = await fs.readFile(abs, 'utf8');
  return raw;
}

export async function runBuild(repoRoot) {
  const patterns =
    process.env.REPO_AI_GLOBS?.split(',').map((s) => s.trim()) ?? DEFAULT_GLOBS;

  const files = await fg(patterns, {
    cwd: repoRoot,
    ignore: IGNORE,
    onlyFiles: true,
    dot: true,
  });

  const tokenizer = await AutoTokenizer.from_pretrained(MODEL_ID);
  const extractor = await pipeline('feature-extraction', MODEL_ID, {
    revision: 'main',
  });

  const vectordbDir = path.join(repoRoot, 'repo-ai', 'vectordb');
  await fs.mkdir(vectordbDir, { recursive: true });
  const jsonlPath = path.join(repoRoot, 'repo-ai', 'embeddings.jsonl');
  const indexPath = path.join(vectordbDir, 'index.json');

  await fs.writeFile(jsonlPath, '', 'utf8');

  const chunks = [];

  for (const rel of files.sort()) {
    let text;
    try {
      text = await loadFile(repoRoot, rel);
    } catch {
      continue;
    }
    if (!text.trim()) continue;

    const type = classifyType(rel);
    const rawSections = splitByH2(text);
    if (!rawSections.length) continue;

    const sections = await finalizeSections(tokenizer, rawSections);

    for (const sec of sections) {
      const headingPart = sec.heading
        .replace(/_intro/g, 'intro')
        .replace(/\s*\/\s*/g, '__');
      let slug = sec.baseSlug || slugifyHeading(headingPart);
      if (sec.partTotal > 1) {
        slug = `${slug}__p${sec.partIndex}`;
      }

      const chunkId = makeChunkId(type, rel, slug);
      const bodyText = sec.body;
      const output = await extractor(bodyText, {
        pooling: 'mean',
        normalize: true,
      });
      const tensor = output?.data ?? output;
      const embedding = Array.from(tensor);

      const record = {
        id: chunkId,
        path: rel.replace(/\\/g, '/'),
        type,
        heading: sec.heading,
        text: bodyText,
        tokens: await countTokens(tokenizer, bodyText),
        embedding,
      };

      chunks.push(record);
      await fs.appendFile(jsonlPath, `${JSON.stringify(record)}\n`, 'utf8');
    }
  }

  const index = {
    version: 1,
    model: MODEL_ID,
    dimensions: 384,
    createdAt: new Date().toISOString(),
    chunks,
  };

  await fs.writeFile(indexPath, JSON.stringify(index), 'utf8');

  console.error(
    `Indexed ${chunks.length} chunks from ${files.length} files → ${path.relative(repoRoot, indexPath)}`
  );
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
  const repoRoot = resolveRepoRoot();
  await runBuild(repoRoot);
}

if (isExecutedDirectly()) {
  cliMain().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
