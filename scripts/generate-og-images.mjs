#!/usr/bin/env node
// Extract every post-cover SVG from the rendered Jekyll _site/, rasterize to
// PNG via sharp/resvg, and write under _site/assets/og/<slug>.png.
//
// Single source of truth: docs/site/_includes/post-cover.svg (Liquid template).
// Jekyll renders it inline into each blog page; this script never re-renders
// Liquid — it just extracts the already-rendered SVG and converts it.
//
// Usage:
//   node scripts/generate-og-images.mjs [site_dir]
//   site_dir defaults to "_site"

import { readFile, writeFile, mkdir, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import sharp from 'sharp';

const SITE_DIR = path.resolve(process.argv[2] ?? '_site');
const OG_DIR = path.join(SITE_DIR, 'assets', 'og');
const SVG_RE = /<svg\b[^>]*class="[^"]*\bpost-cover\b[^"]*"[^>]*data-post-slug="([^"]+)"[^>]*>[\s\S]*?<\/svg>/g;

async function* walk(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      yield* walk(full);
    } else if (entry.isFile() && full.endsWith('.html')) {
      yield full;
    }
  }
}

async function main() {
  try {
    await stat(SITE_DIR);
  } catch {
    console.error(`✘ ${SITE_DIR} not found — run after Jekyll build`);
    process.exit(1);
  }

  await mkdir(OG_DIR, { recursive: true });

  const seen = new Set();
  let written = 0;
  let skipped = 0;
  let failed = 0;

  for await (const htmlFile of walk(SITE_DIR)) {
    let html;
    try {
      html = await readFile(htmlFile, 'utf-8');
    } catch {
      continue;
    }

    // A page may embed many post-cover SVGs (e.g. the blog index lists every post).
    for (const match of html.matchAll(SVG_RE)) {
      const slug = match[1].trim();
      if (!slug || seen.has(slug)) {
        skipped++;
        continue;
      }
      seen.add(slug);

      const svgString = match[0];
      const out = path.join(OG_DIR, `${slug}.png`);

      try {
        // resvg honours the SVG's viewBox; we rasterize at 1200x630 (OG standard).
        const buf = await sharp(Buffer.from(svgString), { density: 96 })
          .resize(1200, 630, { fit: 'fill' })
          .png({ compressionLevel: 9, effort: 6 })
          .toBuffer();
        await writeFile(out, buf);
        written++;
        console.log(`OK ${slug}.png  (from ${path.relative(SITE_DIR, htmlFile)})`);
      } catch (err) {
        failed++;
        console.error(`FAIL ${slug}.png - ${err.message}`);
      }
    }
  }

  console.log(`\nOG image generation: ${written} written, ${skipped} duplicate, ${failed} failed`);
  if (failed > 0) process.exit(1);
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
