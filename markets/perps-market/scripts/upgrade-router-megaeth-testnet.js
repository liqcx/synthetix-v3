#!/usr/bin/env node
// Upgrade PerpsMarketProxy on MegaETH testnet to a new Router that
// swaps in the fixed BookOrderModule. Three onchain txs signed by PRIVATE_KEY
// (must be the current proxy owner 0x8fF5bE45682f7136F8D8D80033b20330514CF80c):
//
//   1. deploy new BookOrderModule (from this fork's compiled artifact)
//   2. deploy new PerpsMarketRouter (generated with new BookOrderModule +
//      14 existing module addresses read from cannon1.json state dump)
//   3. upgradeTo(newRouter) on PerpsMarketProxy
//
// Usage:
//   PRIVATE_KEY=0x... node scripts/upgrade-router-megaeth-testnet.js

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { ethers } = require('ethers');
const { generateRouter } = require('@usecannon/router');

const PERPS_MARKET_DIR = path.resolve(__dirname, '..');
const CANNON_STATE =
  '/Users/alex/Work/perps/synthetix-deployments/e2e/deployments.megaeth.testnet/cannon1.json';
const RPC = 'https://carrot.megaeth.com/rpc';
const PROXY = '0x330E5A387DFD403a71A81A368eC649b7c1be3AC9';
const EXPECTED_OWNER = '0x8fF5bE45682f7136F8D8D80033b20330514CF80c';

function loadArtifact(rel) {
  return JSON.parse(fs.readFileSync(path.join(PERPS_MARKET_DIR, 'artifacts', rel), 'utf8'));
}

function readState() {
  const s = JSON.parse(fs.readFileSync(CANNON_STATE, 'utf8'));
  const root = s.state['provision.perpsFactory'].artifacts.imports.perpsFactory;
  return { perps: root.contracts, synth: root.imports.synthetix.contracts };
}

function entry(name, info, overrideAddr) {
  return {
    contractName: name,
    sourceName: info.sourceName,
    contractFullyQualifiedName: `${info.sourceName}:${name}`,
    abi: info.abi,
    deployedAddress: overrideAddr || info.address,
    deployTxnHash: '0x0000000000000000000000000000000000000000000000000000000000000000',
    constructorArgs: [],
  };
}

async function main() {
  const pk = process.env.PRIVATE_KEY;
  if (!pk) throw new Error('PRIVATE_KEY env required');

  const provider = new ethers.providers.JsonRpcProvider(RPC);
  const signer = new ethers.Wallet(pk, provider);
  console.log('signer:         ', signer.address);

  const proxy = new ethers.Contract(
    PROXY,
    ['function owner() view returns (address)', 'function upgradeTo(address) external'],
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

  console.log(
    'signer balance: ',
    ethers.utils.formatEther(await provider.getBalance(signer.address)),
    'ETH'
  );

  // --- Step 1: deploy new BookOrderModule -------------------------------
  const bookArt = loadArtifact('contracts/modules/BookOrderModule.sol/BookOrderModule.json');
  console.log('\n[1/3] deploying BookOrderModule (with marketId fix)...');
  const bookFactory = new ethers.ContractFactory(bookArt.abi, bookArt.bytecode, signer);
  const bookCtr = await bookFactory.deploy();
  console.log('  tx:', bookCtr.deployTransaction.hash);
  await bookCtr.deployTransaction.wait(1);
  const BOOK_NEW = bookCtr.address;
  console.log('  new BookOrderModule:', BOOK_NEW);

  // --- Step 2a: generate router source ---------------------------------
  const { perps, synth } = readState();
  const contracts = [
    entry('AccountModule', synth.AccountModule),
    entry('AssociatedSystemsModule', synth.AssociatedSystemsModule),
    entry('CoreModule', perps.CoreModule),
    entry('PerpsMarketFactoryModule', perps.PerpsMarketFactoryModule),
    entry('PerpsAccountModule', perps.PerpsAccountModule),
    entry('PerpsMarketModule', perps.PerpsMarketModule),
    entry('AsyncOrderModule', perps.AsyncOrderModule),
    entry('BookOrderModule', perps.BookOrderModule, BOOK_NEW),
    entry('AsyncOrderSettlementPythModule', perps.AsyncOrderSettlementPythModule),
    entry('AsyncOrderCancelModule', perps.AsyncOrderCancelModule),
    entry('FeatureFlagModule', perps.FeatureFlagModule),
    entry('LiquidationModule', perps.LiquidationModule),
    entry('MarketConfigurationModule', perps.MarketConfigurationModule),
    entry('CollateralConfigurationModule', perps.CollateralConfigurationModule),
    entry('GlobalPerpsMarketModule', perps.GlobalPerpsMarketModule),
  ];

  console.log('\n[2/3] generating + compiling PerpsMarketRouter.sol...');
  const routerSource = generateRouter({ contractName: 'PerpsMarketRouter', contracts });
  const genDir = path.join(PERPS_MARKET_DIR, 'contracts/generated');
  fs.mkdirSync(genDir, { recursive: true });
  const routerPath = path.join(genDir, 'PerpsMarketRouter.sol');
  fs.writeFileSync(routerPath, routerSource);
  console.log('  wrote:', routerPath, `(${routerSource.length} bytes)`);

  // --- Step 2b: compile via hardhat ------------------------------------
  const hh = spawnSync('bun', ['x', 'hardhat', 'compile'], {
    cwd: PERPS_MARKET_DIR,
    stdio: 'inherit',
  });
  if (hh.status !== 0) throw new Error('hardhat compile failed');

  const routerArt = loadArtifact(
    'contracts/generated/PerpsMarketRouter.sol/PerpsMarketRouter.json'
  );

  // --- Step 2c: deploy router ------------------------------------------
  console.log('\n[2/3] deploying PerpsMarketRouter...');
  const routerFactory = new ethers.ContractFactory(routerArt.abi, routerArt.bytecode, signer);
  const routerCtr = await routerFactory.deploy();
  console.log('  tx:', routerCtr.deployTransaction.hash);
  await routerCtr.deployTransaction.wait(1);
  const ROUTER_NEW = routerCtr.address;
  console.log('  new Router:', ROUTER_NEW);

  // --- Step 3: upgradeTo -----------------------------------------------
  console.log('\n[3/3] calling upgradeTo on PerpsMarketProxy...');
  const tx = await proxy.upgradeTo(ROUTER_NEW);
  console.log('  tx:', tx.hash);
  await tx.wait(1);

  console.log('\nDONE.');
  console.log('  BookOrderModule:', BOOK_NEW);
  console.log('  PerpsMarketRouter:', ROUTER_NEW);
  console.log('  PerpsMarketProxy now delegates to the new router.');
}

main().catch((e) => {
  console.error('\nFATAL:', e.message);
  if (e.stack) console.error(e.stack);
  process.exit(1);
});
