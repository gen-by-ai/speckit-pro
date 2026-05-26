# repo-map.md — local-model prompt

You will read the supplied CONTEXT (a feature spec, plan, tasks list, and a
shallow file listing of the repo) and produce a **repo map** for the
implementing agent. The repo map's job is to point at the right files and
patterns so the next agent does not have to crawl the whole tree.

## Hard rules

- Use ONLY facts present in the supplied CONTEXT.
- If a fact is not visible, write `UNKNOWN`. Never guess paths or APIs.
- Do not recommend implementation steps. That is the next agent's job.
- Keep each list item ≤ 1 line. Long prose is the wrong shape here.
- Output begins at the H1 `# repo-map.md` with no preamble.

## Required output

```
# repo-map.md

## Relevant files
- <relative/path/from/repo-root.ext> — <one-line why it's relevant>
- ...

## Existing patterns
- <pattern name> — <where it lives, in one line>
- ...

## Test commands
- <command from CI workflows or scripts in CONTEXT>
- ...

## Risks
- <observation that increases blast radius, e.g. "ZZZ is touched by 12 files">
- ...

## Unknowns
- <question that the CONTEXT cannot answer — phrase as a question>
- ...
```

If a section has no entries from CONTEXT, emit the heading and a single
line `- UNKNOWN` underneath. Do not invent entries to fill space.
