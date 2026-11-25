// Checks that the reference pages cover everything in the Swift source, with matching values.
// Run with `npm run check`. It only reads ../Sources; it never writes outside docs/.
//
//   commands      Command.usage and Command.parse   -> reference/commands.mdx
//   reports       the --json examples               -> reference/commands.mdx
//   hooks         HookEnvironment's variables       -> reference/configuration.mdx
//   config keys   Config.defaultText and Config.load -> reference/configuration.mdx
//   [[display]]   DisplaySettings.parse              -> reference/configuration.mdx
//   shortcuts     the [bindings] of defaultText      -> reference/default-shortcuts.mdx
//   key names     Hotkeys.keyCodes, KeyCombo.parse   -> reference/key-names.mdx
//   schema        Config.jsonSchema                  -> public/schema/iguana.schema.json
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const source = (path) => readFileSync(resolve(here, '../../Sources', path), 'utf8');
const page = (path) => readFileSync(resolve(here, '../src/content/docs', path), 'utf8');

const commandSwift = source('IguanaCore/Command.swift');
const configSwift = source('IguanaCore/Config.swift');
const schemaSwift = source('IguanaCore/Schema.swift');
const hooksSwift = source('IguanaCore/Hooks.swift');
const displaySwift = source('IguanaCore/DisplaySettings.swift');
const hotkeysSwift = source('iguana/Hotkeys.swift');

const commandsPage = page('reference/commands.mdx');
const configPage = page('reference/configuration.mdx');
const shortcutsPage = page('reference/default-shortcuts.mdx');
const keysPage = page('reference/key-names.mdx');

const failures = [];
let checks = 0;
function expect(ok, message) {
	checks += 1;
	if (!ok) failures.push(message);
}

/** The text of a Swift multi-line string literal, with its indentation removed. */
function literal(swift, name) {
	const match = swift.match(new RegExp(`static let ${name} = """\\n([\\s\\S]*?)\\n\\s*"""`));
	if (!match) throw new Error(`no literal named ${name}`);
	const lines = match[1].split('\n');
	const indent = Math.min(...lines.filter((l) => l.trim()).map((l) => l.match(/^ */)[0].length));
	return lines.map((l) => l.slice(indent)).join('\n');
}

/** The part of a page from a heading up to the next heading of the same or a higher level. */
function section(text, heading) {
	const lines = text.split('\n');
	const start = lines.indexOf(heading);
	if (start < 0) return null;
	const level = heading.match(/^#+/)[0].length;
	const body = [];
	let fenced = false;
	for (const line of lines.slice(start + 1)) {
		if (line.trimStart().startsWith('```')) fenced = !fenced;
		// A line starting with # inside a code block is a comment, not a heading.
		const hashes = fenced ? null : line.match(/^(#+) /);
		if (hashes && hashes[1].length <= level) break;
		body.push(line);
	}
	return body.join('\n');
}

// ---- Commands -----------------------------------------------------------------------------

const usage = literal(commandSwift, 'usage');
const usageCommands = new Set();
const usageWords = new Set();
for (const line of usage.split('\n')) {
	const grammar = line.split(/\s{2,}/)[0];
	if (grammar.includes(' | ')) {
		for (const name of grammar.split(' | ')) usageCommands.add(name.trim());
		continue;
	}
	// Commands joined with `;` are not a command of their own; that line is checked below.
	if (grammar.includes(';')) continue;
	const [name, ...args] = grammar.split(' ');
	usageCommands.add(name);
	for (const arg of args) for (const word of arg.replace(/[\[\]]/g, '').split('|')) usageWords.add(word);
}
usageWords.delete('N');

const parseBody = commandSwift.slice(commandSwift.indexOf('switch name {'), commandSwift.indexOf('public enum Modifier'));
const parsedCommands = new Set([...parseBody.matchAll(/case "([a-z-]+)": return/g)].map((m) => m[1]));
parsedCommands.add('resize'); // its case spans several lines

for (const name of parsedCommands) expect(usageCommands.has(name), `Command.parse accepts '${name}' but Command.usage does not list it`);
for (const name of new Set([...usageCommands, ...parsedCommands])) {
	const body = section(commandsPage, `### \`${name}\``);
	expect(body !== null, `commands.mdx has no "### \`${name}\`" section`);
	expect(commandsPage.includes(`[\`${name}\`](#${name})`), `commands.mdx: '${name}' is missing from the At a glance table`);
}
for (const word of usageWords) expect(commandsPage.includes(word), `commands.mdx never mentions the argument '${word}'`);
// Every usage line is quoted as a grammar line under its command.
for (const line of usage.split('\n')) {
	const grammar = line.split(/\s{2,}/)[0];
	if (grammar.includes(' | ')) continue;
	expect(commandsPage.includes(`\n${grammar}\n`), `commands.mdx does not show the grammar line "${grammar}"`);
}
// Chains have a section of their own, which shows their grammar line.
const chainLine = usage.split('\n').map((line) => line.split(/\s{2,}/)[0]).find((grammar) => grammar.includes(';'));
expect(chainLine !== undefined, 'Command.usage has no line for commands joined with ;');
expect((section(commandsPage, '### Chains') ?? '').includes(`\n${chainLine}\n`), 'commands.mdx: the "### Chains" section does not show the grammar line for chains');
// The range of desktop numbers.
const range = commandSwift.match(/n >= (\d+), n <= (\d+)/);
expect(range && commandsPage.includes(`from ${range[1]} to ${range[2]}`), 'commands.mdx: the Space number range does not match Command.parse');

// The four reports show a JSON document each, and every one of them is JSON.
const jsonExamples = [...commandsPage.matchAll(/```json\n([\s\S]*?)\n```/g)].map((m) => m[1]);
expect(jsonExamples.length === 4, `commands.mdx should show 4 JSON documents, one for each report; it shows ${jsonExamples.length}`);
for (const example of jsonExamples) {
	let ok = true;
	try {
		JSON.parse(example);
	} catch {
		ok = false;
	}
	expect(ok, `commands.mdx: a JSON example does not parse: ${example.slice(0, 60)}…`);
}
for (const name of ['list-windows', 'list-spaces', 'tree', 'status']) {
	expect(commandsPage.includes(`\n${name} --json\n`), `commands.mdx does not show the grammar line "${name} --json"`);
}

// ---- Config keys --------------------------------------------------------------------------

const defaults = literal(configSwift, 'defaultText');
expect(configPage.includes('```toml title="~/.config/iguana/iguana.toml"\n' + defaults + '\n```'),
	'configuration.mdx: the default file block is not identical to Config.defaultText');

let current = null;
const bindings = [];
const settings = [];
for (const raw of defaults.split('\n')) {
	const line = raw.trim();
	const table = line.match(/^\[\[?([a-z-]+)\]?\]$/);
	if (table) {
		current = table[1];
		const heading = current === 'rule' ? '## `[[rule]]`' : `## \`[${current}]\``;
		expect(section(configPage, heading) !== null, `configuration.mdx has no "${heading}" section`);
		continue;
	}
	const pair = line.match(/^([a-z0-9-]+) = ("[^"]*"|[^\s#]+)/);
	if (!pair || !current) continue;
	if (current === 'bindings') bindings.push([pair[1], JSON.parse(pair[2])]);
	else settings.push([current, pair[1], pair[2]]);
}

for (const [table, key, value] of settings) {
	const heading = table === 'rule' ? '## `[[rule]]`' : `## \`[${table}]\``;
	const body = section(section(configPage, heading) ?? '', `### \`${key}\``);
	expect(body !== null, `configuration.mdx: no "### \`${key}\`" under ${heading}`);
	if (body === null || table === 'rule') continue;
	expect(body.includes(`| Default | \`${value}\` |`), `configuration.mdx: ${table}.${key} should show the default ${value}`);
}
expect(settings.length >= 10, 'expected at least ten settings in Config.defaultText');

// Every key Config.load accepts is documented.
for (const [, list] of configSwift.matchAll(/checkKeys\(\w+, \[([^\]]+)\]/g)) {
	for (const [, key] of list.matchAll(/"([a-z-]+)"/g)) {
		expect(configPage.includes(`\`${key}\``) || configPage.includes(`\`[${key}]\``) || configPage.includes(`\`[[${key}]]\``),
			`configuration.mdx never mentions the key '${key}'`);
	}
}

// Ranges checked by the `number` helper.
for (const [, name, min, max] of configSwift.matchAll(/number\([^,]+, "([a-z.-]+)", min: ([\d.]+), max: ([\d.]+)\)/g)) {
	const [table, key] = name.split('.');
	const body = section(section(configPage, `## \`[${table}]\``) ?? '', `### \`${key}\``) ?? '';
	expect(body.includes(`${min} to ${max}`), `configuration.mdx: ${name} should give the range ${min} to ${max}`);
}
// Ranges written out by hand in Config.load.
const manual = [
	['layout', 'resize-step', /d > 0, d <= 0\.5/, 'greater than 0, up to 0.5'],
	['animation', 'duration', /d >= 0\.05, d <= 1/, '0.05 to 1'],
	['stage-manager', 'reserve-strip', /d >= 0, d <= 600/, '0 to 600'],
];
for (const [table, key, pattern, text] of manual) {
	expect(pattern.test(configSwift), `Config.load no longer checks ${table}.${key} the way this script expects`);
	const body = section(section(configPage, `## \`[${table}]\``) ?? '', `### \`${key}\``) ?? '';
	expect(body.includes(text), `configuration.mdx: ${table}.${key} should say "${text}"`);
}
// A [[display]] is read in DisplaySettings.swift, and documented under its own heading.
const displayPage = section(configPage, '## `[[display]]`') ?? '';
expect(displayPage !== '', 'configuration.mdx has no "## `[[display]]`" section');
for (const [, table, list] of displaySwift.matchAll(/checkKeys\((\w+), \[([^\]]+)\]/g)) {
	for (const [, key] of list.matchAll(/"([a-z-]+)"/g)) {
		// The keys of the table each have a heading; the sides of `outer` are named under it.
		const ok = table === 't' ? section(displayPage, `### \`${key}\``) !== null : displayPage.includes(`\`${key}\``);
		expect(ok, `configuration.mdx: [[display]] does not document the key '${key}'`);
	}
}
for (const [, name, min, max] of displaySwift.matchAll(/number\([^,]+, "([a-z.-]+)", min: ([\d.]+), max: ([\d.]+)\)/g)) {
	const body = section(displayPage, `### \`${name.split('.')[0]}\``) ?? '';
	expect(body.includes(`${min} to ${max}`), `configuration.mdx: display ${name} should give the range ${min} to ${max}`);
}
const displayNumbers = displaySwift.match(/numbers = (\d+)\.\.\.(\d+)/);
expect(displayNumbers && (section(displayPage, '### `number`') ?? '').includes(`${displayNumbers[1]} to ${displayNumbers[2]}`),
	'configuration.mdx: the range of display numbers does not match DisplaySettings.numbers');

for (const value of ['linear', 'ease-out', 'ease-in-out']) {
	expect(configSwift.includes(value) && (section(configPage, '### `easing`') ?? '').includes(`"${value}"`),
		`configuration.mdx: easing should list "${value}"`);
}

// Every variable a hook's command is given.
const hookVariables = new Set([...hooksSwift.matchAll(/"(IGUANA_[A-Z_]+)"/g)].map((m) => m[1]));
expect(hookVariables.size >= 6, 'could not read the hook variables from IguanaCore/Hooks.swift');
for (const name of hookVariables) {
	expect((section(configPage, '## `[hooks]`') ?? '').includes(`\`${name}\``), `configuration.mdx: [hooks] never mentions ${name}`);
}

// ---- Default shortcuts --------------------------------------------------------------------

for (const [keys, command] of bindings) {
	expect(new RegExp(`\\| \`${keys}\` \\| \`${command}\` \\|`).test(shortcutsPage),
		`default-shortcuts.mdx: missing or wrong row for ${keys} = "${command}"`);
}
const documentedRows = [...shortcutsPage.matchAll(/\| `((?:option|cmd|ctrl|shift)-[a-z0-9-]+)` \| `([^`]+)` \|/g)];
expect(documentedRows.length === bindings.length,
	`default-shortcuts.mdx lists ${documentedRows.length} shortcuts, Config.defaultText has ${bindings.length}`);
expect(configPage.includes(`The ${bindings.length} [default shortcuts]`), `configuration.mdx should say there are ${bindings.length} default shortcuts`);

// ---- Key names ----------------------------------------------------------------------------

const keyTable = hotkeysSwift.slice(hotkeysSwift.indexOf('keyCodes: [String: Int] = ['), hotkeysSwift.indexOf('init()'));
const keyNames = [...keyTable.matchAll(/"([a-z0-9]+)": \d+/g)].map((m) => m[1]);
expect(keyNames.length > 60, 'could not read Hotkeys.keyCodes');
const letters = keyNames.filter((k) => /^[a-z]$/.test(k));
const digits = keyNames.filter((k) => /^[0-9]$/.test(k));
const functionKeys = keyNames.filter((k) => /^f\d+$/.test(k)).map((k) => Number(k.slice(1)));
expect(letters.length === 26 && keysPage.includes('`a` to `z`'), 'key-names.mdx: letters a to z');
expect(digits.length === 10 && keysPage.includes('`0` to `9`'), 'key-names.mdx: digits 0 to 9');
expect(keysPage.includes(`\`f1\` to \`f${Math.max(...functionKeys)}\``) && functionKeys.length === Math.max(...functionKeys),
	'key-names.mdx: the function key range does not match Hotkeys.keyCodes');
for (const name of keyNames.filter((k) => k.length > 1 && !/^f\d+$/.test(k))) {
	expect(keysPage.includes(`\`${name}\``), `key-names.mdx never mentions the key '${name}'`);
}
const comboBody = commandSwift.slice(commandSwift.indexOf('for p in modParts'));
for (const [, list] of comboBody.matchAll(/case ((?:"[a-z]+",? ?)+): mods\.insert/g)) {
	for (const [, modifier] of list.matchAll(/"([a-z]+)"/g)) {
		// Read for configs brought over from other window managers, and deliberately not documented.
		if (modifier === 'alt') continue;
		expect(keysPage.includes(`\`${modifier}\``), `key-names.mdx never mentions the modifier '${modifier}'`);
	}
}

// ---- Schema -------------------------------------------------------------------------------

const schema = literal(schemaSwift, 'jsonSchema').replaceAll('\\\\', '\\');
const published = readFileSync(resolve(here, '../public/schema/iguana.schema.json'), 'utf8');
expect(published.trim() === schema.trim(), 'public/schema/iguana.schema.json differs from Config.jsonSchema (run `npm run schema`)');

// ---- Result -------------------------------------------------------------------------------

if (failures.length > 0) {
	console.error(`check-coverage: ${failures.length} of ${checks} checks failed`);
	for (const f of failures) console.error('  ' + f);
	process.exit(1);
}
console.log(
	`check-coverage: ${checks} checks passed ` +
		`(${usageCommands.size} commands, ${settings.length} settings, ${bindings.length} default shortcuts, ${keyNames.length} key names, schema)`
);
