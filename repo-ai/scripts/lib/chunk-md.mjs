/**
 * Split markdown on ## (H2). Returns sections with heading text and body.
 */
export function splitByH2(markdown) {
  const lines = markdown.split(/\r?\n/);
  const sections = [];
  let currentHeading = '_intro';
  let currentBody = [];

  function flush() {
    const body = currentBody.join('\n').trim();
    if (body.length > 0) {
      sections.push({ heading: currentHeading, body });
    }
    currentBody = [];
  }

  for (const line of lines) {
    const h2 = line.match(/^##\s+(.+)$/);
    if (h2) {
      flush();
      currentHeading = h2[1].trim();
      continue;
    }
    currentBody.push(line);
  }
  flush();

  return sections.filter((s) => s.body.length > 0 || s.heading !== '_intro');
}

export function slugifyHeading(heading) {
  if (heading === '_intro' || heading.trim() === '') return 'intro';
  return heading
    .toLowerCase()
    .replace(/[`"'’]/g, '')
    .replace(/[^\w\s-]/g, '')
    .trim()
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .slice(0, 120) || 'section';
}
