// Third gate: the `^:` edge rule. Where the root script at 6835e6fa is
// `pnpm -r run X` (topological) the task must carry `deps: ['^:X']`; where it is
// `pnpm -r --parallel run X` it must not. Tasks defined in a project's own
// moon.yml inherit no deps unless one of its tags defines the SAME task id, so
// those are the sites where the edge is silently absent. Neither the set gate
// nor the body gate looks at deps.
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Resolve every path from this file's own location, not from the caller's cwd —
// see task-set.mjs for why.
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

// `moon query projects`' JSON is 822,661 bytes today against Node's 1 MiB
// (1,048,576 byte) default `maxBuffer` for `execSync` — 78.5% of it. Same
// ceiling, same fix, as `utils/deps/lib/moon-usage.js` (Task 4) and
// task-set.mjs in this directory: 10 MiB is ~12.7x today's size.
const MOON_QUERY_MAX_BUFFER = 10 * 1024 * 1024;

// Read verbatim from `git show 6835e6fa:package.json`.
const TOPOLOGICAL = new Set([
	"build",
	"build-contracts",
	"build-ts",
	"compile-contracts",
	"storage-dump",
	"storage-verify",
	"check-storage",
	"size-contracts",
	"build-testable",
	"generate-testable",
	"coverage",
	"docgen",
	"publish-contracts",
	"subgraph-codegen",
	"subgraph-build",
]);
const PARALLEL = new Set(["clean", "test"]); // root uses `pnpm -r --parallel run X`
const NO_ROOT_SCRIPT = new Set(["deploy", "forge-test"]);

const taskIds = (text) =>
	[...text.matchAll(/^ {2}([a-z][a-z0-9-]*):$/gm)].map((m) => m[1]);
const tagTasks = new Map(); // tag -> Set(task id)
for (const f of ["contracts", "ts-lib", "foundry", "subgraph"]) {
	const t = readFileSync(join(ROOT, `.moon/tasks/tag-${f}.yml`), "utf8");
	tagTasks.set(f, new Set(taskIds(t.slice(t.indexOf("\ntasks:")))));
}

const { projects } = JSON.parse(
	execSync("moon query projects", {
		cwd: ROOT,
		maxBuffer: MOON_QUERY_MAX_BUFFER,
	}).toString(),
);
let bad = 0;
for (const p of projects) {
	const text = readFileSync(join(ROOT, `${p.source}/moon.yml`), "utf8");
	const tags = [
		...(text.match(/^tags: \[(.*)\]$/m)?.[1] ?? "").matchAll(/"([^"]+)"/g),
	].map((m) => m[1]);
	const idx = text.indexOf("\ntasks:");
	if (idx === -1) continue;
	const body = text.slice(idx);
	for (const id of taskIds(body)) {
		// A task id the tag also defines inherits that tag's deps (mergeDeps: append).
		if (tags.some((t) => tagTasks.get(t)?.has(id))) continue;
		// +1 skips the leading newline; without it split() returns '' as [0] and
		// every declared edge reads as missing (caught by the publish-contracts control).
		const block = body
			.slice(body.indexOf(`\n  ${id}:`) + 1)
			.split(/\n {2}(?=[a-z])/)[0];
		const hasEdge = block.includes(`"^:${id}"`) || block.includes(`'^:${id}'`);
		if (TOPOLOGICAL.has(id) && !hasEdge) {
			bad++;
			console.log(
				`MISSING ^: edge  ${p.source} :: ${id}  (root runs it topologically)`,
			);
		}
		if ((PARALLEL.has(id) || NO_ROOT_SCRIPT.has(id)) && hasEdge) {
			bad++;
			console.log(
				`SPURIOUS ^: edge ${p.source} :: ${id}  (root does not order it)`,
			);
		}
	}
}
console.log(bad === 0 ? "DEPS PARITY OK" : `DEPS PARITY: ${bad} problem(s)`);
process.exit(bad === 0 ? 0 : 1);
