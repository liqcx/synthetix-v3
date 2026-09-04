// Repo-local syncpack config — YOURS to edit (seeded once by
// liqcx-tooling-sync, never overwritten). Spreads the sync-managed org base
// (.syncpackrc.base.json — never edit that file) and appends repo-specific
// groups. NOTE: delete any legacy .syncpackrc.json first — cosmiconfig may
// resolve it ahead of this file.
const base = require('./.syncpackrc.base.json');

module.exports = {
	...base,
	versionGroups: [
		...(base.versionGroups ?? []),
		// Repo-local version groups go here, e.g.:
		// {
		// 	label: '@myrepo/* packages use the workspace: protocol',
		// 	dependencies: ['@myrepo/**'],
		// 	dependencyTypes: ['prod', 'dev', 'peer'],
		// 	pinVersion: 'workspace:*',
		// },
	],
};
