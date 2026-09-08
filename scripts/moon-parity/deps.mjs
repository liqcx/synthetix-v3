// Third gate: the resolved graph — ordering and caching. Where the root script
// at 6835e6fa is `pnpm -r run X` the verb is topological, so every project that
// owns X must be ordered after every workspace dependency that also owns X;
// where it is `pnpm -r --parallel run X` (`clean` and `test`, and nothing else)
// no such ordering may exist.
//
// This reads what moon RESOLVES, not the YAML that authors it. `moon query
// projects` expands each `deps: ["^:X"]` into concrete `<dependency>:X`
// targets, so an edge a tag file supplies is checked on every project that
// inherits it — the previous version of this gate text-grepped each project's
// own moon.yml and skipped every task id a tag defined, which is where most of
// the graph lives. Same reason for the `cache: false` assertion below: caching
// is behaviour moon would be adding (`pnpm -r run X` never skipped a script),
// no task declares `outputs`, and a cache hit that restores nothing reports
// success having produced nothing.
import { execSync } from "node:child_process";
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

const { projects } = JSON.parse(
	execSync("moon query projects", {
		cwd: ROOT,
		maxBuffer: MOON_QUERY_MAX_BUFFER,
	}).toString(),
);
const byId = new Map(projects.map((p) => [p.id, p]));

let bad = 0;
let tasks = 0; // every resolved task, for the cache assertion
let edges = 0; // upstream orderings actually asserted
let vacuous = 0; // topological instances with no dependency that owns the verb
let noopBuilds = 0;
for (const p of projects) {
	for (const [id, task] of Object.entries(p.tasks ?? {})) {
		tasks++;
		if (task.options?.cache !== false) {
			bad++;
			console.log(
				`CACHE ENABLED   ${p.source} :: ${id}  (no task declares outputs; a hit would restore nothing)`,
			);
		}
		const deps = new Set((task.deps ?? []).map((d) => d.target));

		if (TOPOLOGICAL.has(id)) {
			// `build` is a noop whose real work — and therefore its ordering —
			// rides on the same-project `build-contracts`/`build-ts` edge, so it
			// carries no `^:build` of its own. Exempt it from the upstream rule,
			// but require the edge the exemption is justified by; the three real
			// `build` bodies (Faucet `forge build`, RewardsDistributor* `cannon
			// build`) stay under the rule.
			if (id === "build" && task.command === "noop") {
				noopBuilds++;
				if (![...deps].some((t) => t.startsWith(`${p.id}:`))) {
					bad++;
					console.log(
						`NOOP build      ${p.source} :: build  (noop with no same-project edge: nothing builds)`,
					);
				}
				continue;
			}
			let required = 0;
			for (const dep of p.dependencies ?? []) {
				if (!byId.get(dep.id)?.tasks?.[id]) continue;
				required++;
				edges++;
				if (!deps.has(`${dep.id}:${id}`)) {
					bad++;
					console.log(
						`MISSING edge    ${p.source} :: ${id}  (root runs it topologically; ${dep.id}:${id} must come first)`,
					);
				}
			}
			if (required === 0) vacuous++;
		}

		if (PARALLEL.has(id) || NO_ROOT_SCRIPT.has(id)) {
			for (const target of deps) {
				const [owner, verb] = target.split(":");
				if (verb === id && owner !== p.id) {
					bad++;
					console.log(
						`SPURIOUS edge   ${p.source} :: ${id}  (root does not order it; ${target})`,
					);
				}
			}
		}
	}
}
console.log(
	`checked ${tasks} resolved tasks, ${edges} upstream edges, ${noopBuilds} noop builds; ${vacuous} topological instance(s) had no dependency owning the verb (see README)`,
);
console.log(bad === 0 ? "DEPS PARITY OK" : `DEPS PARITY: ${bad} problem(s)`);
process.exit(bad === 0 ? 0 : 1);
