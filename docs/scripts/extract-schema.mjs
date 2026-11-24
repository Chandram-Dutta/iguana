// Copies the JSON Schema out of the Swift source into public/schema/iguana.schema.json.
// Run with `npm run schema` after Sources/IguanaCore/Schema.swift changes.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const source = resolve(here, '../../Sources/IguanaCore/Schema.swift');
const target = resolve(here, '../public/schema/iguana.schema.json');

const swift = readFileSync(source, 'utf8');
const match = swift.match(/static let jsonSchema = """\n([\s\S]*?)\n\s*"""/);
if (!match) throw new Error(`no jsonSchema literal found in ${source}`);

const lines = match[1].split('\n');
const indent = Math.min(...lines.filter((l) => l.trim()).map((l) => l.match(/^ */)[0].length));
// In a Swift string literal `\\` is one backslash.
const json = lines.map((l) => l.slice(indent)).join('\n').replaceAll('\\\\', '\\');

JSON.parse(json); // fail loudly if the result is not valid JSON
mkdirSync(dirname(target), { recursive: true });
writeFileSync(target, json + '\n');
console.log(`wrote ${target}`);
