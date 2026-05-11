---
name: repo-ai-cli
description: >-
  Runs the repo-ai local vector index CLI to build or search embeddings over
  instructions, skills, and spec-kit markdown. Use when the user needs semantic
  search over repo context, wants to refresh the knowledge index, or mentions
  repo-ai, embeddings.jsonl, vectordb, or local MiniLM search. Works when the
  CLI is vendored (npm install in repo-ai/) or installed globally (npm install -g).
---

# repo-ai CLI

The **`repo-ai`** command indexes markdown instructions (H2-chunked, MiniLM embeddings) and answers natural-language queries with **JSON on stdout** (scores, paths, chunk text). All inference is local; nothing is sent to an external API.

## Prerequisites

| Requirement | Notes |
|-------------|--------|
| **Node.js ≥ 20** | Required everywhere. |
| **Git** (optional) | If the CLI is **globally** installed, repository root is usually discovered with **`git rev-parse --show-toplevel`**. Not required when you pass **`--root`** / **`REPO_AI_ROOT`**, or when the repo vendors **`repo-ai/package.json`** (walk-up discovery). |
| **Dependencies for the CLI** | Install **once** either globally or inside this repo’s **`repo-ai/`** folder — not per consumed repository. |

### Two ways to install the CLI package

**A — Global binary (use in any git clone or pass `--root`)**

From the directory that contains this package (e.g. speckit-pro root):

```bash
npm install -g ./repo-ai
```

After that, **`repo-ai`** is on your **`PATH`**. Xenova/transformers live in the global package’s **`node_modules`**; **you do not** run `npm install` inside each downstream project.

**B — Vendored in this repo (typical for contributors)**

```bash
cd repo-ai && npm install
```

Then invoke **`./repo-ai/bin/repo-ai.mjs`** or **`npm run build-index`** / **`npm run search`** from **`repo-ai/`**.

### Other repositories

- **With global install:** `cd` anywhere under the target repo and run **`repo-ai build`** / **`repo-ai search "..."`**. Outputs go to **`<repo-root>/repo-ai/embeddings.jsonl`** and **`<repo-root>/repo-ai/vectordb/index.json`** (created if missing).
- **Without git** (e.g. tarball): set **`REPO_AI_ROOT`** or **`repo-ai --root /absolute/path/to/repo`**.
- **Publishing:** this package is **`"private": true`** in npm terms (no registry publish unless you change that). Global install from a **path** (`npm install -g ./repo-ai`) is the usual way to make it “everywhere” without npmjs.org.

## How to invoke

```bash
repo-ai help
repo-ai build
repo-ai search "your question here"
repo-ai search -q "your question" -k 8
```

From a clone **without** global install:

```bash
./repo-ai/bin/repo-ai.mjs help
./repo-ai/bin/repo-ai.mjs build
```

From **`repo-ai/`** after vendored **`npm install`**:

```bash
node bin/repo-ai.mjs build
npm run build-index
npm run search -- "your question"
```

### Repository root discovery

Order:

1. **`--root`** / **`-R`** or **`REPO_AI_ROOT`**
2. Walk upward until **`repo-ai/package.json`** exists (parent directory = repo root)
3. **`git rev-parse --show-toplevel`** from the current working directory

If none apply (no git, no marker), set **`REPO_AI_ROOT`** or **`--root`** explicitly.

## Commands

| Command | Purpose |
|--------|---------|
| **`repo-ai build`** (alias **`index`**) | Regenerate **`repo-ai/embeddings.jsonl`** and **`repo-ai/vectordb/index.json`**. First run downloads the Xenova model (cached under the usual Hugging Face cache dir). |
| **`repo-ai search "<query>"`** | Prints one JSON document: `query`, `model`, `topK`, `results[]` with `score`, `id`, `path`, `heading`, `text`. |

### Search flags

- **`-k` / `--top-k`**: number of hits (default **8**).
- **`-q` / `--query`**: query string (optional if the query is the first positional argument).
- **`--index`**: path to a custom **`index.json`** (rare).

### Build environment

- **`REPO_AI_GLOBS`**: comma-separated glob list (relative to repo root) to override which files are indexed.

## Agent workflow

1. If the index may be stale or missing, run **`repo-ai build`** (expect minutes on first build due to model download).
2. After **`/speckit.implement`**, if **`pro-drift.md`** is missing and drift matters for your answer, suggest **`/speckit.pro.reconcile`** (or run it) before relying on **`/speckit.pro.evaluate`** alone.
3. Run **`repo-ai search "<concise question>"`** and parse **stdout JSON**.
4. Use **`results[].path`** and **`results[].text`** as citations for answers or next steps.

Do not assume **`vectordb/`** is committed; it is normally gitignored—rebuild when needed.
