// Checks every internal link and anchor in the built site. Runs as part of `npm run build`.
// Exits non-zero and lists each broken link if any are found.
import { readFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const dist = resolve(dirname(fileURLToPath(import.meta.url)), '../dist');
if (!existsSync(dist)) {
	console.error('check-links: no dist/ folder. Run `astro build` first.');
	process.exit(1);
}

function walk(dir) {
	return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
		const path = join(dir, entry.name);
		return entry.isDirectory() ? walk(path) : [path];
	});
}

const pages = walk(dist).filter((file) => file.endsWith('.html'));
const idCache = new Map();

function idsOf(file) {
	if (!idCache.has(file)) {
		const html = readFileSync(file, 'utf8');
		idCache.set(file, new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1])));
	}
	return idCache.get(file);
}

/** The file a site path such as `/guides/animation/` is served from, or null. */
function fileFor(path) {
	const target = join(dist, decodeURIComponent(path));
	if (existsSync(target) && statSync(target).isFile()) return target;
	const index = join(target, 'index.html');
	return existsSync(index) ? index : null;
}

const problems = [];
let checked = 0;

for (const page of pages) {
	const html = readFileSync(page, 'utf8');
	const pagePath = '/' + page.slice(dist.length + 1).replace(/index\.html$/, '');
	for (const [, , url] of html.matchAll(/\s(href|src)="([^"]+)"/g)) {
		if (/^([a-z][a-z0-9+.-]*:|\/\/)/i.test(url)) continue; // external, mailto:, data:
		const [pathPart, hash] = url.replace(/&amp;/g, '&').split('#');
		const path = pathPart.split('?')[0];
		checked += 1;
		const file = path === '' ? page : fileFor(path.startsWith('/') ? path : join(pagePath, path));
		if (!file) {
			problems.push(`${pagePath}: ${url} (no such page or file)`);
			continue;
		}
		if (hash && file.endsWith('.html') && !idsOf(file).has(decodeURIComponent(hash))) {
			problems.push(`${pagePath}: ${url} (no element with id "${hash}")`);
		}
	}
}

if (problems.length > 0) {
	console.error(`check-links: ${problems.length} broken link(s)`);
	for (const p of [...new Set(problems)]) console.error('  ' + p);
	process.exit(1);
}
console.log(`check-links: ${checked} internal links on ${pages.length} pages, none broken`);
