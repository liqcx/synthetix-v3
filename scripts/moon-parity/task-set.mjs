import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Resolve every path from this file's own location, not from the caller's cwd —
// a relative path here would happily resolve from wherever `node` was invoked
// and quietly read nothing (or the wrong thing) the moment someone runs this
// from outside the repo root.
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

// `moon query projects`' JSON is 822,661 bytes today against Node's 1 MiB
// (1,048,576 byte) default `maxBuffer` for `execSync` — 78.5% of it, on a
// workspace that only grows moon tasks over time. Same ceiling, same fix, as
// `utils/deps/lib/moon-usage.js` (Task 4): 10 MiB is ~12.7x today's size,
// enough headroom that this workspace would have to grow an order of
// magnitude before it mattered again, without tolerating a truly runaway
// process silently.
const MOON_QUERY_MAX_BUFFER = 10 * 1024 * 1024;

const RENAME = {
	"build:ts": "build-ts",
	"build:contracts": "build-contracts",
	"storage:dump": "storage-dump",
	"storage:verify": "storage-verify",
	"check:storage": "check-storage",
	"subgraph:codegen": "subgraph-codegen",
	"subgraph:build": "subgraph-build",
};
const MIGRATED = [
	"build",
	"build:contracts",
	"build:ts",
	"compile-contracts",
	"storage:dump",
	"storage:verify",
	"check:storage",
	"size-contracts",
	"build-testable",
	"generate-testable",
	"test",
	"coverage",
	"clean",
	"docgen",
	"publish-contracts",
	"deploy",
	"forge-test",
	"subgraph:codegen",
	"subgraph:build",
];

const baselinePath = join(
	ROOT,
	"docs/superpowers/plans/2026-09-07-lerna-to-moon-baseline.txt",
);
const wantBySource = new Map();
for (const line of readFileSync(baselinePath, "utf8").trim().split("\n")) {
	const [dir, script] = line.split(" ");
	if (!MIGRATED.includes(script)) continue;
	if (!wantBySource.has(script)) wantBySource.set(script, new Set());
	wantBySource.get(script).add(dir);
}

const { projects } = JSON.parse(
	execSync("moon query projects", {
		cwd: ROOT,
		maxBuffer: MOON_QUERY_MAX_BUFFER,
	}).toString(),
);
const haveByTask = new Map();
for (const project of projects) {
	for (const taskId of Object.keys(project.tasks ?? {})) {
		if (!haveByTask.has(taskId)) haveByTask.set(taskId, new Set());
		haveByTask.get(taskId).add(project.source);
	}
}

let bad = 0;
for (const verb of MIGRATED) {
	const taskId = RENAME[verb] ?? verb;
	const want = wantBySource.get(verb) ?? new Set();
	const have = haveByTask.get(taskId) ?? new Set();
	const missing = [...want].filter((d) => !have.has(d)).sort();
	const extra = [...have].filter((d) => !want.has(d)).sort();
	if (missing.length || extra.length) {
		bad++;
		console.log(`${verb} -> ${taskId}`);
		if (missing.length) console.log(`  MISSING: ${missing.join(", ")}`);
		if (extra.length) console.log(`  EXTRA:   ${extra.join(", ")}`);
	}
}
console.log(bad === 0 ? "PARITY OK" : `PARITY BROKEN in ${bad} verb(s)`);
process.exit(bad === 0 ? 0 : 1);
