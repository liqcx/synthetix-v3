#!/usr/bin/env node
// Storage-patch the 7 accounts on MegaETH testnet whose Position.marketId
// was written as 0 by the pre-fix BookOrderModule. Four signed txs:
//
//   1. deploy PositionMarketIdPatcher impl (contracts/generated/);
//   2. upgradeTo(patcher) on PerpsMarketProxy;
//   3. patcher.patchPositionMarketIds(200, [1,2,4,5,6,7,8]);
//   4. upgradeTo(ROUTER) to restore normal dispatch.
//
// Between 2 and 4 the proxy only exposes upgradeTo + patch. Stop the
// settler before running to avoid nonce races and keeper retries hitting
// a half-upgraded proxy.
//
// Usage:
//   PRIVATE_KEY=0x... node scripts/patch-stuck-accounts-megaeth-testnet.js

const fs = require('fs');
const path = require('path');
const { ethers } = require('ethers');

const PERPS_MARKET_DIR = path.resolve(__dirname, '..');
const RPC = 'https://carrot.megaeth.com/rpc';
const PROXY = '0x330E5A387DFD403a71A81A368eC649b7c1be3AC9';
const EXPECTED_OWNER = '0x8fF5bE45682f7136F8D8D80033b20330514CF80c';
const TARGET_MARKET_ID = 200;
const STUCK_ACCOUNTS = process.env.ACCOUNTS
  ? process.env.ACCOUNTS.split(',').map((s) => parseInt(s.trim(), 10))
  : [1, 2, 4, 5, 6, 7, 8];

function loadArtifact(rel) {
  return JSON.parse(fs.readFileSync(path.join(PERPS_MARKET_DIR, 'artifacts', rel), 'utf8'));
}

async function main() {
  const pk = process.env.PRIVATE_KEY;
  if (!pk) throw new Error('PRIVATE_KEY env required');

  const provider = new ethers.providers.JsonRpcProvider(RPC);
  const signer = new ethers.Wallet(pk, provider);
  console.log('signer:         ', signer.address);

  const proxy = new ethers.Contract(
    PROXY,
    [
      'function owner() view returns (address)',
      'function upgradeTo(address) external',
      'function getImplementation() view returns (address)',
    ],
    signer
  );
  const currentOwner = await proxy.owner();
  console.log('proxy owner:    ', currentOwner);
  if (currentOwner.toLowerCase() !== EXPECTED_OWNER.toLowerCase()) {
    throw new Error(`unexpected proxy owner: ${currentOwner}`);
  }
  if (signer.address.toLowerCase() !== currentOwner.toLowerCase()) {
    throw new Error('signer is not proxy owner — cannot upgradeTo');
  }

  const CURRENT_ROUTER = await proxy.getImplementation();
  console.log('current router: ', CURRENT_ROUTER);
  console.log(
    'signer balance: ',
    ethers.utils.formatEther(await provider.getBalance(signer.address)),
    'ETH'
  );

  // --- Step 1: deploy patcher ------------------------------------------
  const patcherArt = loadArtifact(
    'contracts/generated/PositionMarketIdPatcher.sol/PositionMarketIdPatcher.json'
  );
  console.log('\n[1/4] deploying PositionMarketIdPatcher...');
  const patcherFactory = new ethers.ContractFactory(patcherArt.abi, patcherArt.bytecode, signer);
  const patcherCtr = await patcherFactory.deploy();
  console.log('  tx:', patcherCtr.deployTransaction.hash);
  await patcherCtr.deployTransaction.wait(1);
  console.log('  patcher:', patcherCtr.address);

  // --- Step 2: upgradeTo(patcher) --------------------------------------
  console.log('\n[2/4] upgradeTo(patcher)...');
  let tx = await proxy.upgradeTo(patcherCtr.address);
  console.log('  tx:', tx.hash);
  await tx.wait(1);

  // --- Step 3: patchPositionMarketIds(200, [1,2,4,5,6,7,8]) -----------
  console.log(
    `\n[3/4] patchPositionMarketIds(${TARGET_MARKET_ID}, [${STUCK_ACCOUNTS.join(',')}])...`
  );
  const patcherViaProxy = new ethers.Contract(PROXY, patcherArt.abi, signer);
  tx = await patcherViaProxy.patchPositionMarketIds(TARGET_MARKET_ID, STUCK_ACCOUNTS);
  console.log('  tx:', tx.hash);
  const rcpt = await tx.wait(1);
  const patchedCount = rcpt.logs.filter(
    (l) => l.address.toLowerCase() === PROXY.toLowerCase()
  ).length;
  console.log(`  PositionMarketIdPatched events: ${patchedCount}`);

  // --- Step 4: upgradeTo(CURRENT_ROUTER) to restore --------------------
  console.log(`\n[4/4] upgradeTo(${CURRENT_ROUTER}) to restore...`);
  tx = await proxy.upgradeTo(CURRENT_ROUTER);
  console.log('  tx:', tx.hash);
  await tx.wait(1);

  const afterRouter = await proxy.getImplementation();
  if (afterRouter.toLowerCase() !== CURRENT_ROUTER.toLowerCase()) {
    throw new Error(`router restore mismatch: got ${afterRouter}, want ${CURRENT_ROUTER}`);
  }

  console.log('\nDONE.');
  console.log('  patcher:', patcherCtr.address);
  console.log('  restored router:', afterRouter, '(matches original — ok to start settler again)');
}

main().catch((e) => {
  console.error('\nFATAL:', e.message);
  if (e.stack) console.error(e.stack);
  process.exit(1);
});
