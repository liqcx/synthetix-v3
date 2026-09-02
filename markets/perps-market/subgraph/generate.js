#!/usr/bin/env node

/**
 * Renders one manifest per network from `subgraph.template.yaml` and
 * `networks.json`, then runs `graph codegen` once.
 *
 * Codegen is network-independent by construction — one schema, one ABI — so a
 * single run serves every network. Adding a network, or moving a contour, is an
 * edit to `networks.json` and nothing else.
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = __dirname;
const networks = JSON.parse(fs.readFileSync(path.join(ROOT, 'networks.json'), 'utf8'));
const template = fs.readFileSync(path.join(ROOT, 'subgraph.template.yaml'), 'utf8');

function render(name, net) {
  for (const field of ['network', 'address', 'startBlock']) {
    if (net[field] === undefined || net[field] === null) {
      throw new Error(`networks.json: ${name} is missing ${field}`);
    }
  }
  const out = template
    .replace('__NETWORK__', net.network)
    .replace('__ADDRESS__', net.address)
    .replace('__START_BLOCK__', String(net.startBlock));
  const unfilled = out.match(/__[A-Z_]+__/g);
  if (unfilled) {
    throw new Error(`${name}: template placeholders left unfilled: ${unfilled.join(', ')}`);
  }
  const file = path.join(ROOT, `subgraph.${name}.yaml`);
  fs.writeFileSync(file, out);
  return path.basename(file);
}

const written = Object.entries(networks).map(([name, net]) => render(name, net));
console.log(`manifests written: ${written.join(', ')}`);

const codegen = spawnSync(
  'pnpm',
  ['exec', 'graph', 'codegen', written[0], '--output-dir', 'src/generated'],
  { cwd: ROOT, stdio: 'inherit' }
);
if (codegen.status !== 0) {
  process.exit(codegen.status ?? 1);
}

const prettier = spawnSync('pnpm', ['exec', 'prettier', '--write', 'src/generated'], {
  cwd: ROOT,
  stdio: 'inherit',
});
if (prettier.status !== 0) {
  process.exit(prettier.status ?? 1);
}

// `--build` continues into `graph build` for every network, so the two package.json
// scripts differ by one flag instead of one of them carrying a shell loop.
if (process.argv.includes('--build')) {
  for (const name of Object.keys(networks)) {
    const built = spawnSync(
      'pnpm',
      ['exec', 'graph', 'build', `subgraph.${name}.yaml`, '--output-dir', `./build/${name}`],
      { cwd: ROOT, stdio: 'inherit' }
    );
    if (built.status !== 0) {
      process.exit(built.status ?? 1);
    }
  }
}
