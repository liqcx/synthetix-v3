// Second gate, beyond the set-parity one: compares each moon task's RESOLVED body
// against the package.json script body at 6835e6fa. The set gate cannot see body
// drift, which is how a `clean` missing its `rm -rf contracts/generated` hid.
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

const RENAME = {
	"build:ts": "build-ts",
	"build:contracts": "build-contracts",
	"storage:dump": "storage-dump",
	"storage:verify": "storage-verify",
	"check:storage": "check-storage",
	"subgraph:codegen": "subgraph-codegen",
	"subgraph:build": "subgraph-build",
};
const MIGRATED = new Set([
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
]);

// Documented, intentional rewrites (design "package.json cleanup"): each maps a
// baseline body to the body the moon task is expected to carry.
const REWRITE = new Map(
	Object.entries({
		// `build` aliases become a noop + deps edge
		"yarn build:contracts": "noop",
		"yarn build:ts": "noop",
		// `deploy` keeps its ordering as a script over moon targets
		"yarn build && yarn publish-contracts":
			"moon run $project:build && moon run $project:publish-contracts",
		// yarn -> pnpm run for scripts that survive in package.json
		"CANNON_REGISTRY_PRIORITY=local bun x hardhat test; yarn anvil-clean":
			"CANNON_REGISTRY_PRIORITY=local bun x hardhat test; pnpm run anvil-clean",
		// `yarn <script>` inlined because Task 4 deletes the callee
		"nyc yarn test": "nyc bun x mocha --require ts-node/register",
		"yarn test --coverage": "jest --coverage",
		"yarn deployments:optimism-mainnet && yarn codegen:optimism-mainnet && git diff --exit-code && yarn test --coverage":
			"pnpm run deployments:optimism-mainnet && pnpm run codegen:optimism-mainnet && git diff --exit-code && graph test --coverage",
		"yarn deployments:mainnet && yarn codegen:mainnet && git diff --exit-code && yarn test --coverage":
			"pnpm run deployments:mainnet && pnpm run codegen:mainnet && git diff --exit-code && graph test --coverage",
		// build:contracts inlines the storage:dump it used to call
		"bun x hardhat compile --force && yarn storage:dump && CANNON_REGISTRY_PRIORITY=local bun x hardhat cannon:build":
			"bun x hardhat compile --force && bun x hardhat storage:dump --output storage.new.dump.json && CANNON_REGISTRY_PRIORITY=local bun x hardhat cannon:build",
	}),
);

// Default baseline is the "dir | verb | body" dump of every migrated package's
// scripts at 6835e6fa (see bodies-baseline.txt in this directory for how it was
// produced); an explicit argv[2] overrides it for a re-derivation against a
// different sha.
const baselinePath =
	process.argv[2] ?? join(ROOT, "scripts/moon-parity/bodies-baseline.txt");
const baseline = new Map(); // "dir\0verb" -> body
for (const line of readFileSync(baselinePath, "utf8").trim().split("\n")) {
	const [dir, verb, ...rest] = line.split(" | ");
	if (verb.startsWith("SKIP.") || !MIGRATED.has(verb)) continue;
	baseline.set(`${dir}\0${verb}`, rest.join(" | ").trim());
}

const { projects } = JSON.parse(
	execSync("moon query projects", {
		cwd: ROOT,
		maxBuffer: MOON_QUERY_MAX_BUFFER,
	}).toString(),
);
const got = new Map(); // "dir\0taskId" -> {body, env}
const projectIdBySource = new Map(projects.map((p) => [p.source, p.id]));
for (const p of projects)
	for (const [id, t] of Object.entries(p.tasks ?? {}))
		got.set(`${p.source}\0${id}`, {
			body: t.script ?? [t.command, ...(t.args ?? [])].join(" "),
			env: t.env ?? {},
		});

let mismatches = 0;
for (const [key, want0] of [...baseline].sort()) {
	const [dir, verb] = key.split("\0");
	const taskId = RENAME[verb] ?? verb;
	const g = got.get(`${dir}\0${taskId}`);
	if (!g) {
		console.log(`NO TASK  ${dir} ${verb}`);
		mismatches++;
		continue;
	}
	let want = REWRITE.get(want0) ?? want0;
	let have = g.body;
	// CANNON_REGISTRY_PRIORITY=local moved from an inline prefix onto task env
	// (design: "becomes task env wherever the root script or the package script
	// sets it today"). Strip the prefix on the baseline side when the task has it.
	if (g.env.CANNON_REGISTRY_PRIORITY === "local") {
		want = want.replace(/^CANNON_REGISTRY_PRIORITY=local /, "");
		// An override may also keep the prefix inline; that is redundant, not a diff.
		have = have.replace(/^CANNON_REGISTRY_PRIORITY=local /, "");
	}
	// moon expands the `$project` token in a script to the project id.
	want = want.replaceAll("$project", projectIdBySource.get(dir));
	if (want !== have) {
		mismatches++;
		console.log(`BODY DIFF  ${dir} :: ${verb} -> ${taskId}`);
		console.log(`  script: ${want}`);
		console.log(`  task:   ${have}`);
	}
}
console.log(
	mismatches === 0
		? `BODY PARITY OK (${baseline.size} pairs)`
		: `BODY PARITY: ${mismatches} mismatch(es)`,
);
process.exit(mismatches === 0 ? 0 : 1);
