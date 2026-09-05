# 2026-04-19 — Position.marketId written as 0 by the pre-fix BookOrderModule

Record of a one-shot storage patch on the MegaETH testnet production contour
(`PerpsMarketProxy` `0x330E5A387DFD403a71A81A368eC649b7c1be3AC9`). The script and the patcher
contract lived outside git (the contract under the gitignored `contracts/generated/`, the script
in `scripts/`) until 2026-09-05, when both were retired: the contour they patched is being
redeployed on fresh contracts, and router upgrades now go through Cannon in
`synthetix-deployments`. This file is the only copy.

## What happened

The first `BookOrderModule` settled book orders without writing `Position.marketId`, so seven
accounts (`1, 2, 4, 5, 6, 7, 8`) on the BTC market (`200`) held positions whose `marketId` read
as `0`, and a ghost market `0` sat in their `openPositionMarketIds`. The fix
(`curPosition.marketId = marketId` in the module) shipped in the next router, but storage
already written stayed wrong, and every margin read over those accounts walked the ghost market.

## What was done

Four owner-signed transactions, settler stopped for the duration:

1. deploy `PositionMarketIdPatcher` (source below);
2. `PerpsMarketProxy.upgradeTo(patcher)` — between this step and step 4 the proxy exposed only
   `upgradeTo` and `patchPositionMarketIds`; every other selector reverted `UnknownSelector`;
3. `patchPositionMarketIds(200, [1, 2, 4, 5, 6, 7, 8])` through the proxy;
4. `PerpsMarketProxy.upgradeTo(router)` with the router read from `getImplementation()` before
   step 2, then re-read and compared.

## The patcher

```solidity
//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {CoreModule} from "@synthetixio/core-modules/contracts/modules/CoreModule.sol";
import {OwnableStorage} from "@synthetixio/core-contracts/contracts/ownership/OwnableStorage.sol";
import {SetUtil} from "@synthetixio/core-contracts/contracts/utils/SetUtil.sol";
import {PerpsMarket} from "../storage/PerpsMarket.sol";
import {PerpsAccount} from "../storage/PerpsAccount.sol";
import {Position} from "../storage/Position.sol";

/**
 * @title One-shot admin impl to repair Position rows written by the old
 * BookOrderModule before the curPosition.marketId=marketId fix shipped.
 *
 * Extends CoreModule so `upgradeTo(address)` is still available from the
 * owner: swap Router → this patcher → run `patchPositionMarketIds` → swap
 * back to Router. During the window between the two upgrades, all other
 * selectors revert with UnknownSelector (no-op for non-owner traffic).
 */
contract PositionMarketIdPatcher is CoreModule {
    using SetUtil for SetUtil.UintSet;

    event PositionMarketIdPatched(uint128 indexed accountId, uint128 indexed marketId);

    /**
     * @notice For each accountId, set `positions[accountId].marketId = marketId`
     * in storage of PerpsMarket.load(marketId), and remove the ghost
     * market 0 from `openPositionMarketIds` if present.
     */
    function patchPositionMarketIds(
        uint128 marketId,
        uint128[] calldata accountIds
    ) external {
        OwnableStorage.onlyOwner();
        PerpsMarket.Data storage m = PerpsMarket.load(marketId);
        for (uint256 i = 0; i < accountIds.length; i++) {
            uint128 acct = accountIds[i];
            Position.Data storage p = m.positions[acct];
            p.marketId = marketId;

            SetUtil.UintSet storage open = PerpsAccount.load(acct).openPositionMarketIds;
            if (open.contains(0)) {
                open.remove(0);
            }

            emit PositionMarketIdPatched(acct, marketId);
        }
    }
}
```

## Why the scripts are gone

`scripts/patch-stuck-accounts-megaeth-testnet.js` hardcoded the production proxy, the owner and
the seven account ids, and read the patcher from a gitignored directory — a record of one
afternoon, not a tool. `scripts/upgrade-router-megaeth-testnet.js` redeployed a fixed list of
modules from one machine's absolute path and ran `main()` on `require()`; the router of every
contour is upgraded by `cannon build` from the omnibus in `synthetix-deployments`, which diffs
the bytecode of every module against the contour's state and regenerates the router itself.
