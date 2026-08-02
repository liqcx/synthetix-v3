// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {BootstrapTest} from "./Bootstrap.t.sol";
import {IBookOrderModule} from "../contracts/interfaces/IBookOrderModule.sol";
import {BookOrderModule} from "../contracts/modules/BookOrderModule.sol";
import {PerpsAccountModule} from "../contracts/modules/PerpsAccountModule.sol";
import {PerpsMarketFactoryModule} from "../contracts/modules/PerpsMarketFactoryModule.sol";
import {PerpsMarketModule} from "../contracts/modules/PerpsMarketModule.sol";
import {GlobalPerpsMarketModule} from "../contracts/modules/GlobalPerpsMarketModule.sol";
import {console} from "forge-std/console.sol";

/**
 * @title Phantom snxUSD escrow repro
 *
 * @notice Reproduces the production incident: `GlobalPerpsMarket.collateralAmounts[0]`
 *         (the snxUSD "escrow" that `PerpsMarketFactoryModule.minimumCredit` adds verbatim to
 *         the market's locked credit) grows without any snxUSD ever entering the system.
 *
 * @dev Two independent facts are asserted:
 *
 *      1. `test_freshPositionReportsPreExistingFunding` — the root cause. `BookOrderModule`
 *         never writes `Position.latestInteractionFunding` (it copies the old position out of
 *         storage and only touches marketId / size / latestInteractionPrice), so the funding
 *         anchor of a BOOK-native position stays at its storage default of 0 forever. A
 *         position opened *right now* therefore already reports the market's entire accumulated
 *         funding integral as `accruedFunding`.
 *
 *      2. `test_escrowGrowsWithoutAnySnxUsdEnteringTheSystem` — the consequence. An account that
 *         opens and closes a tiny position realizes that whole integral as profit on every close.
 *         `PerpsAccount.charge(amount > 0)` credits the excess straight into
 *         `collateralAmounts[0]` with no token movement, so escrow (and thus `minimumCredit`)
 *         ratchets up while `snxUSD.totalSupply()` and the market's net issuance are unchanged.
 *
 *      3. `test_phantomEscrowLocksLpWithdrawals` — the production symptom:
 *         `CoreProxy.isMarketCapacityLocked` flips to true, i.e. LPs can no longer withdraw.
 *
 *      The invariant asserted here is the one that is genuinely broken: realised funding may only
 *      ever reflect the time a position was actually held. There is exactly one defect — the
 *      frozen anchor. Crediting realised PnL into `collateralAmounts[0]` without moving a token is
 *      upstream's deliberate design (audit fix f557d648): the escrow is redeemable on demand
 *      through `PerpsAccountModule._withdrawMargin` -> `CoreProxy.withdrawMarketUsd`, paid by the
 *      pool, and its presence in `minimumCredit` is what stops LPs withdrawing the collateral
 *      backing traders' profits. So `escrow <= netDeposited` is NOT a real invariant and is
 *      deliberately not asserted — it would stay red against a fully fixed contract.
 *
 *      Measured counterfactual (candidate one-line patch — assigning
 *      `pos.latestInteractionFunding = market.lastFundingValue` right after `recomputeFunding` in
 *      `_applyAggregatedAccountPosition` — applied locally and then reverted): the escrow excess
 *      collapses from 810.037500572256943800 snxUSD to 0.007500156076388760 (~108 000x). That
 *      residual is genuine 60-second funding profit and is correct behaviour, which is why test 2
 *      bounds the growth by what the churner could have earned while actually holding rather than
 *      by deposits.
 */
contract PhantomEscrowTest is BootstrapTest {
    uint128 marketIdUnderTest;

    uint128 skewMaker; // holds a one-sided position so the market accrues funding
    uint128 churner; // opens/closes a tiny position repeatedly

    uint256 constant DEPOSIT_PER_ACCOUNT = 100_000e18;
    uint256 constant ETH_PRICE = 2400e18;

    uint256 constant CHURN_ROUND_TRIPS = 5;
    uint256 constant CHURN_HOLD_SECONDS = 12;
    uint256 constant CHURN_SIZE = 0.01e18;
    /// @dev Absorbs funding-rate drift over the churn window; the defect overshoots by ~1e5, so
    ///      the exact factor is not load-bearing.
    uint256 constant GENUINE_FUNDING_SAFETY_FACTOR = 10;

    function setUp() public override {
        super.setUp();
        marketIdUnderTest = ethMarketId;

        _refreshPerpsModulesFromSource();

        vm.startPrank(perps.owner());
        // Funding on, fees off — so every dollar that shows up in escrow is unambiguously funding.
        perps.setFundingParameters(marketIdUnderTest, 1_000e18, 3e18);
        perps.setOrderFees(marketIdUnderTest, 0, 0);
        perps.setMaxMarketSize(marketIdUnderTest, type(uint256).max);
        perps.setMaxMarketValue(marketIdUnderTest, type(uint256).max);
        // Zero locked-OI ratio so the OI component of minimumCredit stays 0 and the escrow
        // component is the only thing that can move it.
        perps.setLockedOiRatio(marketIdUnderTest, 0);
        vm.stopPrank();

        skewMaker = _newFundedBookAccount(trader1, DEPOSIT_PER_ACCOUNT);
        churner = _newFundedBookAccount(trader2, DEPOSIT_PER_ACCOUNT);
    }

    // ---------------------------------------------------------------- helpers

    /**
     * @dev `script/Deploy.sol` is a Cannon-generated script that replays **frozen runtime
     *      bytecode** captured at some earlier build. It therefore does NOT contain the current
     *      `contracts/` sources — in particular it predates f06b2c3b ("persist Position.marketId
     *      in settleBookOrders"), so positions written by the deployed BookOrderModule keep
     *      `marketId == 0` and `Position.getPnl` silently resolves funding against the
     *      uninitialised market 0 (skewScale 0 -> funding always 0). That masks the bug entirely.
     *
     *      Synthetix router modules are stateless (all state lives in namespaced storage slots on
     *      the proxy) and have no constructors, so swapping the runtime code of the module
     *      addresses in place is a faithful way to run the *current* sources against the deployed
     *      system. Only perps-market modules are swapped; core/oracle-manager stay as deployed.
     */
    function _refreshPerpsModulesFromSource() internal {
        vm.etch(deployer.getAddress("BookOrderModule"), address(new BookOrderModule()).code);
        vm.etch(deployer.getAddress("PerpsAccountModule"), address(new PerpsAccountModule()).code);
        vm.etch(
            deployer.getAddress("PerpsMarketFactoryModule"),
            address(new PerpsMarketFactoryModule()).code
        );
        vm.etch(deployer.getAddress("PerpsMarketModule"), address(new PerpsMarketModule()).code);
        vm.etch(
            deployer.getAddress("GlobalPerpsMarketModule"),
            address(new GlobalPerpsMarketModule()).code
        );
    }

    function _newFundedBookAccount(
        address owner,
        uint256 amount
    ) internal returns (uint128 accountId) {
        vm.startPrank(owner);
        accountId = perps.createAccount();
        perps.setBookMode(accountId, true);
        usdToken.approve(address(perps), amount);
        perps.modifyCollateral(accountId, collateralId, int256(amount));
        vm.stopPrank();
    }

    /// @dev Settles a single-account book order. BookOrderModule performs no margin / capacity
    ///      checks, so one leg is enough — the pool is the counterparty.
    function _settleOne(uint128 accountId, int128 sizeDelta) internal {
        IBookOrderModule.BookOrder[] memory orders = new IBookOrderModule.BookOrder[](1);
        orders[0] = IBookOrderModule.BookOrder({
            accountId: accountId,
            sizeDelta: sizeDelta,
            orderPrice: ETH_PRICE,
            signedPriceData: "",
            trackingCode: bytes32(0)
        });
        perps.settleBookOrders(marketIdUnderTest, orders);
    }

    /// @dev Advances time while keeping the oracle price pinned, so no price PnL is generated.
    function _warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        ethMockAggregator.mockSetCurrentPrice(ETH_PRICE, 18);
        superMockAggregator.mockSetCurrentPrice(1e18, 18);
        secondSuperAggregator.mockSetCurrentPrice(1e18, 18);
        mockAggregator.mockSetCurrentPrice(1e18, 18);
    }

    /// @dev Reads PerpsMarket.Data storage directly (no getter exists for the funding accumulator).
    ///      Slot layout: 0 name, 1 symbol, 2 id, 3 skew, 4 size, 5 lastFundingRate,
    ///      6 lastFundingValue, 7 lastFundingTime.
    function _marketSlot(uint256 offset) internal view returns (int256) {
        bytes32 base = keccak256(
            abi.encode("io.synthetix.perps-market.PerpsMarket", marketIdUnderTest)
        );
        return int256(uint256(vm.load(address(perps), bytes32(uint256(base) + offset))));
    }

    function _lastFundingValue() internal view returns (int256) {
        return _marketSlot(6);
    }

    function _lastFundingTime() internal view returns (int256) {
        return _marketSlot(7);
    }

    /// @dev positions mapping lives at struct slot 11; Position.Data packs
    ///      slot0 = marketId(uint128) | size(int128),
    ///      slot1 = latestInteractionPrice(uint128) | latestInteractionFunding(int128).
    function _dumpPosition(string memory label, uint128 accountId) internal {
        bytes32 base = keccak256(
            abi.encode("io.synthetix.perps-market.PerpsMarket", marketIdUnderTest)
        );
        bytes32 posSlot = keccak256(abi.encode(uint256(accountId), uint256(base) + 11));
        uint256 w0 = uint256(vm.load(address(perps), posSlot));
        uint256 w1 = uint256(vm.load(address(perps), bytes32(uint256(posSlot) + 1)));
        emit log(label);
        emit log_named_uint("  position.marketId", uint128(w0));
        emit log_named_int("  position.size", int256(int128(uint128(w0 >> 128))));
        emit log_named_uint("  position.latestInteractionPrice", uint128(w1));
        emit log_named_int(
            "  position.latestInteractionFunding",
            int256(int128(uint128(w1 >> 128)))
        );
    }

    /// @dev snxUSD actually absorbed by the perps super market: deposits minus withdrawals.
    ///      `depositMarketUsd` does `netIssuanceD18 -= amount`, `withdrawMarketUsd` does `+=`.
    function _netDepositedSnxUsd() internal view returns (int256) {
        return -int256(core.getMarketNetIssuance(superMarketId));
    }

    // ---------------------------------------------------------------- tests

    /**
     * Root cause: a position opened *now* must have zero accrued funding. It does not, because
     * BookOrderModule leaves `Position.latestInteractionFunding` at 0.
     */
    function test_freshPositionReportsPreExistingFunding() public {
        // Let the market accrue funding for 30 days with a one-sided skew.
        _settleOne(skewMaker, 5e18);
        _warp(30 days);

        // Brand-new position for the churner, opened at this instant.
        _settleOne(churner, -0.01e18);

        (, int256 accruedFunding, int128 positionSize, ) = perps.getOpenPosition(
            churner,
            marketIdUnderTest
        );

        (int256 smPnl, int256 smFunding, int128 smSize, ) = perps.getOpenPosition(
            skewMaker,
            marketIdUnderTest
        );
        _dumpPosition("skewMaker position storage", skewMaker);
        _dumpPosition("churner position storage", churner);
        emit log_named_int("lastFundingValue", _lastFundingValue());
        emit log_named_int("lastFundingTime", _lastFundingTime());
        emit log_named_uint("block.timestamp", block.timestamp);
        emit log_named_int("skewMaker size", smSize);
        emit log_named_int("skewMaker accruedFunding", smFunding);
        emit log_named_int("skewMaker totalPnl", smPnl);
        emit log_named_int("market skew", perps.skew(marketIdUnderTest));
        emit log_named_int(
            "market currentFundingRate",
            perps.currentFundingRate(marketIdUnderTest)
        );
        emit log_named_int("churner position size", positionSize);
        emit log_named_int("accruedFunding on a position opened 0 seconds ago", accruedFunding);

        assertEq(positionSize, -0.01e18, "unexpected position size");
        assertEq(accruedFunding, 0, "a position opened this instant cannot have accrued funding");
    }

    /**
     * Consequence: escrow (and therefore minimumCredit) grows while snxUSD.totalSupply() and the
     * market's net snxUSD intake are flat.
     */
    function test_escrowGrowsWithoutAnySnxUsdEnteringTheSystem() public {
        // Build up a funding integral: one-sided skew held for 30 days.
        _settleOne(skewMaker, 5e18);
        _warp(30 days);

        uint256 supplyBefore = usdToken.totalSupply();
        uint256 escrowBefore = perps.globalCollateralValue(collateralId);
        uint256 minCreditBefore = perps.minimumCredit(superMarketId);
        int256 netDepositedBefore = _netDepositedSnxUsd();

        emit log("--- before churn ---");
        emit log_named_uint("snxUSD.totalSupply()", supplyBefore);
        emit log_named_uint("escrow collateralAmounts[0]", escrowBefore);
        emit log_named_uint("minimumCredit(superMarket)", minCreditBefore);
        emit log_named_int("net snxUSD deposited into market", netDepositedBefore);

        // Short round trips. Each close realizes the FULL 30-day funding integral again, because
        // the position's funding anchor was never advanced.
        for (uint256 i = 0; i < CHURN_ROUND_TRIPS; i++) {
            _settleOne(churner, -int128(uint128(CHURN_SIZE))); // open short
            _warp(CHURN_HOLD_SECONDS);
            _settleOne(churner, int128(uint128(CHURN_SIZE))); // close
            _warp(CHURN_HOLD_SECONDS);
        }

        uint256 supplyAfter = usdToken.totalSupply();
        uint256 escrowAfter = perps.globalCollateralValue(collateralId);
        uint256 minCreditAfter = perps.minimumCredit(superMarketId);
        int256 netDepositedAfter = _netDepositedSnxUsd();

        emit log("--- after 5 x 12s round trips ---");
        emit log_named_uint("snxUSD.totalSupply()", supplyAfter);
        emit log_named_uint("escrow collateralAmounts[0]", escrowAfter);
        emit log_named_uint("minimumCredit(superMarket)", minCreditAfter);
        emit log_named_int("net snxUSD deposited into market", netDepositedAfter);
        emit log_named_uint(
            "churner snxUSD collateral",
            perps.getCollateralAmount(churner, collateralId)
        );
        emit log_named_uint(
            "getWithdrawableMarketUsd",
            core.getWithdrawableMarketUsd(superMarketId)
        );
        emit log_named_uint(
            "market capacity locked (1=yes)",
            core.isMarketCapacityLocked(superMarketId) ? 1 : 0
        );

        // No snxUSD was created or moved: total supply and the market's net intake are unchanged.
        assertEq(supplyAfter, supplyBefore, "snxUSD totalSupply must not change");
        assertEq(netDepositedAfter, netDepositedBefore, "no snxUSD entered or left the market");

        // ... yet the escrow ledger grew.
        emit log_named_int(
            "escrow delta with zero snxUSD movement",
            int256(escrowAfter) - int256(escrowBefore)
        );

        // The broken invariant: realised funding may only ever reflect the time a position was
        // actually held. The churner held 0.01 for CHURN_ROUND_TRIPS * CHURN_HOLD_SECONDS in
        // total, so that is the ceiling on what it can legitimately have earned — regardless of
        // how large the market's accumulated funding integral happens to be.
        //
        // Deliberately NOT asserted: `escrow <= netDeposited`. Crediting realised PnL into
        // collateralAmounts[0] with no token movement is upstream's intended design (the escrow is
        // redeemable on demand via _withdrawMargin -> withdrawMarketUsd, paid by the pool), so that
        // assertion would stay red even against a fully fixed contract.
        uint256 genuineFundingCeiling = _genuineFundingCeiling();
        emit log_named_uint(
            "genuine funding ceiling for the time actually held",
            genuineFundingCeiling
        );

        assertLe(
            escrowAfter - escrowBefore,
            genuineFundingCeiling,
            "escrow grew by more funding than the position could have accrued while held"
        );
    }

    /**
     * @dev Upper bound on the funding a CHURN_SIZE position can legitimately accrue over the
     *      CHURN_ROUND_TRIPS * CHURN_HOLD_SECONDS it was actually open, at the market's current
     *      rate, times a generous safety factor to absorb rate drift during the churn.
     *
     *      Against the current sources the loop realises the market's whole 30-day integral on
     *      every close, so the measured delta overshoots this ceiling by ~5 orders of magnitude.
     */
    function _genuineFundingCeiling() internal view returns (uint256) {
        int256 rate = perps.currentFundingRate(marketIdUnderTest);
        uint256 absRatePerDay = rate < 0 ? uint256(-rate) : uint256(rate);
        uint256 notional = (perps.indexPrice(marketIdUnderTest) * CHURN_SIZE) / 1e18;
        uint256 heldSeconds = CHURN_ROUND_TRIPS * CHURN_HOLD_SECONDS;

        return
            (((absRatePerDay * notional) / 1e18) * heldSeconds * GENUINE_FUNDING_SAFETY_FACTOR) /
            1 days;
    }

    /**
     * The production symptom: phantom escrow inflates `minimumCredit` past the market's real
     * credit capacity, so `CoreProxy.isMarketCapacityLocked` flips to true and LPs can no longer
     * withdraw — purely from churn, with no snxUSD ever entering or leaving the system.
     */
    function test_phantomEscrowLocksLpWithdrawals() public {
        _settleOne(skewMaker, 5e18);
        _warp(30 days);

        uint256 supplyBefore = usdToken.totalSupply();
        int256 netDepositedBefore = _netDepositedSnxUsd();

        emit log_named_uint("escrow before", perps.globalCollateralValue(collateralId));
        emit log_named_uint("minimumCredit before", perps.minimumCredit(superMarketId));
        emit log_named_uint("withdrawable before", core.getWithdrawableMarketUsd(superMarketId));
        emit log_named_uint(
            "capacity locked before (1=yes)",
            core.isMarketCapacityLocked(superMarketId) ? 1 : 0
        );

        for (uint256 i = 0; i < 8; i++) {
            _settleOne(churner, -500e18);
            _warp(12);
            _settleOne(churner, 500e18);
            _warp(12);
        }

        emit log_named_uint("escrow after", perps.globalCollateralValue(collateralId));
        emit log_named_uint("minimumCredit after", perps.minimumCredit(superMarketId));
        emit log_named_uint("withdrawable after", core.getWithdrawableMarketUsd(superMarketId));
        emit log_named_uint(
            "capacity locked after (1=yes)",
            core.isMarketCapacityLocked(superMarketId) ? 1 : 0
        );
        emit log_named_uint(
            "churner snxUSD collateral",
            perps.getCollateralAmount(churner, collateralId)
        );

        assertEq(usdToken.totalSupply(), supplyBefore, "snxUSD totalSupply must not change");
        assertEq(_netDepositedSnxUsd(), netDepositedBefore, "no snxUSD entered or left the market");
        assertFalse(
            core.isMarketCapacityLocked(superMarketId),
            "LP withdrawals locked without any snxUSD entering the market"
        );
    }
}
