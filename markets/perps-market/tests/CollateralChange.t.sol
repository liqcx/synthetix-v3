// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {Vm} from "forge-std/Vm.sol";
import {FeatureFlag} from "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";
// Aliased: `Test` -> `StdCheats` -> `StdCheatsSafe` already declares a struct named `Account`
// (the `makeAccount`/`makeAddrAndKey` return type), which shadows a bare `Account` import inside
// a contract that inherits `BootstrapTest` -> `Test`. `CoreAccount` is the storage library's
// errors (`PermissionDenied`, `AccountNotFound`), not the cheatcode struct.
import {Account as CoreAccount} from "@synthetixio/main/contracts/storage/Account.sol";
import {AccountRBAC} from "@synthetixio/main/contracts/storage/AccountRBAC.sol";
import {IERC20} from "@synthetixio/core-contracts/contracts/interfaces/IERC20.sol";
import {BootstrapTest} from "./Bootstrap.t.sol";
import {IPerpsAccountModule} from "../contracts/interfaces/IPerpsAccountModule.sol";
import {IGlobalPerpsMarketModule} from "../contracts/interfaces/IGlobalPerpsMarketModule.sol";
import {AsyncOrder} from "../contracts/storage/AsyncOrder.sol";
import {PerpsAccount} from "../contracts/storage/PerpsAccount.sol";
import {CollateralChange} from "../contracts/storage/CollateralChange.sol";
import {PerpsCollateralConfiguration} from "../contracts/storage/PerpsCollateralConfiguration.sol";

/**
 * @title The door table of the trader's collateral change, on the Foundry stand
 * @notice The twin of `test/integration/Account/CollateralChange.door.test.ts`, by selector. The
 *         stand holds snxUSD alone and cannot create a debt (with one collateral a loss past the
 *         collateral makes the account liquidatable, the gate refuses the close that would leave
 *         debt, and the flag forgives it), so `payDebt` is pinned on its refusals only, and the
 *         rate rule on the deposit's side: no `InterestRateUpdated` follows a deposit.
 *
 *           defect                                    modifyCollateral                            payDebt
 *           the feature is off                        FeatureUnavailable                          FeatureUnavailable
 *           an unknown collateral                     InvalidId                                   —
 *           an unknown account                        AccountNotFound                             AccountNotFound
 *           someone else's account                    PermissionDenied                            —
 *           a zero delta                              InvalidAmountDelta                          —
 *           a collateral the market has not enabled   SynthNotEnabledForCollateral                —
 *           past the collateral's cap                 MaxCollateralExceeded                       —
 *           more than the market holds of it          InsufficientCollateral                      —
 *           past the account's limit of kinds         MaxCollateralsPerAccountReached             —
 *           a pending async order                     PendingOrderExists                          PendingOrderExists
 *           more than the account holds               InsufficientSynthCollateral                 —
 *           into the initial margin                   InsufficientCollateralAvailableForWithdraw  —
 *           below the initial margin                  AccountLiquidatable                         —
 *           no allowance                              InsufficientAllowance                       —
 *           no debt                                   —                                           NonexistentDebt(the account asked about)
 *           two defects                               who knocks is asked first
 */
contract CollateralChangeTest is BootstrapTest {
    uint256 constant MARGIN = 1_000e18;
    uint128 constant FUNDED = 40; // trader1, book: 1,000 snxUSD
    uint128 constant HOLDER = 41; // trader2, book: 1,000 snxUSD, long 10 ETH
    uint128 constant EMPTY = 42; // trader1, book: created, never funded
    uint128 constant PENDING = 43; // trader1, off the book: commits an order in its test
    uint128 constant UNDERWATER = 44; // trader2, book: like HOLDER; the price falls in its test
    uint128 constant NOBODY = 42069; // no such account, no such collateral

    function setUp() public override {
        super.setUp();
        bookTrader(trader1, FUNDED, MARGIN);
        bookTrader(trader2, HOLDER, MARGIN);
        openBookPosition(HOLDER, ethMarketId, 10e18, ETH_PRICE);
        openBookAccount(trader1, EMPTY);
        onchainTrader(trader1, PENDING, MARGIN);
        bookTrader(trader2, UNDERWATER, MARGIN);
        openBookPosition(UNDERWATER, ethMarketId, 10e18, ETH_PRICE);
    }

    // ------------------------------------------------------------------------------ the words

    function modify(address who, uint128 accountId, uint128 collateral, int256 delta) internal {
        vm.prank(who);
        perps.modifyCollateral(accountId, collateral, delta);
    }

    function pay(address who, uint128 accountId, uint256 amount) internal {
        vm.prank(who);
        perps.payDebt(accountId, amount);
    }

    /// @dev The next call is refused with exactly this error.
    function refused(bytes memory error) internal {
        vm.expectRevert(error);
    }

    function denied(uint128 accountId, address who) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                CoreAccount.PermissionDenied.selector,
                accountId,
                AccountRBAC._PERPS_MODIFY_COLLATERAL_PERMISSION,
                who
            );
    }

    function notFound(uint128 accountId) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CoreAccount.AccountNotFound.selector, accountId);
    }

    /// @dev One async order of 1 ETH through the account's owner, on strategy 0.
    function commit(uint128 accountId) internal {
        vm.prank(trader1);
        perps.commitOrder(
            AsyncOrder.OrderCommitmentRequest({
                marketId: ethMarketId,
                accountId: accountId,
                sizeDelta: 1e18,
                settlementStrategyId: 0,
                acceptablePrice: ETH_PRICE * 2,
                trackingCode: bytes32(0),
                referrer: address(0)
            })
        );
    }

    // ------------------------------------------------------------------------------ the table

    function test_theFeatureIsOff_bothDoorsAreShut() public {
        vm.prank(perps.owner());
        perps.setFeatureFlagDenyAll("perpsSystem", true);
        bytes memory unavailable = abi.encodeWithSelector(
            FeatureFlag.FeatureUnavailable.selector,
            bytes32("perpsSystem")
        );
        refused(unavailable);
        modify(trader1, FUNDED, collateralId, 1e18);
        refused(unavailable);
        pay(trader1, FUNDED, 1e18);
    }

    function test_anUnknownCollateral() public {
        refused(abi.encodeWithSelector(PerpsCollateralConfiguration.InvalidId.selector, NOBODY));
        modify(trader1, FUNDED, NOBODY, 1e18);
    }

    function test_anUnknownAccount() public {
        refused(notFound(NOBODY));
        modify(trader1, NOBODY, collateralId, 1e18);
    }

    function test_someoneElsesAccount() public {
        refused(denied(FUNDED, trader2));
        modify(trader2, FUNDED, collateralId, 1e18);
    }

    function test_aZeroDelta() public {
        refused(abi.encodeWithSelector(IPerpsAccountModule.InvalidAmountDelta.selector, int256(0)));
        modify(trader1, FUNDED, collateralId, 0);
    }

    function test_aCollateralTheMarketHasNotEnabled() public {
        vm.prank(perps.owner());
        perps.setCollateralConfiguration(collateralId, 0, 0, 0, 0);
        refused(
            abi.encodeWithSelector(
                CollateralChange.SynthNotEnabledForCollateral.selector,
                collateralId
            )
        );
        modify(trader1, FUNDED, collateralId, 1e18);
    }

    function test_pastTheCollateralsCap() public {
        uint256 held = perps.globalCollateralValue(collateralId);
        vm.prank(perps.owner());
        perps.setCollateralConfiguration(collateralId, held + 1e18, 0, 0, 0);
        refused(
            abi.encodeWithSelector(
                CollateralChange.MaxCollateralExceeded.selector,
                collateralId,
                held + 1e18,
                held,
                uint256(2e18)
            )
        );
        modify(trader1, FUNDED, collateralId, 2e18);
    }

    /// @dev The market's balance of the collateral is asked before the account's.
    function test_moreThanTheMarketHolds() public {
        uint256 held = perps.globalCollateralValue(collateralId);
        refused(
            abi.encodeWithSelector(
                CollateralChange.InsufficientCollateral.selector,
                collateralId,
                held,
                held + 1
            )
        );
        modify(trader1, FUNDED, collateralId, -int256(held + 1));
    }

    function test_pastTheAccountsLimitOfKinds() public {
        vm.prank(perps.owner());
        perps.setPerAccountCaps(100_000, 0);
        refused(
            abi.encodeWithSelector(
                CollateralChange.MaxCollateralsPerAccountReached.selector,
                uint128(0)
            )
        );
        modify(trader1, EMPTY, collateralId, 1e18);
    }

    function test_aPendingAsyncOrder_bothDoorsAreShut() public {
        commit(PENDING);
        refused(abi.encodeWithSelector(AsyncOrder.PendingOrderExists.selector));
        modify(trader1, PENDING, collateralId, 1e18);
        refused(abi.encodeWithSelector(AsyncOrder.PendingOrderExists.selector));
        pay(trader1, PENDING, 1e18);
    }

    function test_moreThanTheAccountHolds_lessThanTheMarket() public {
        refused(
            abi.encodeWithSelector(
                CollateralChange.InsufficientSynthCollateral.selector,
                collateralId,
                MARGIN,
                MARGIN + 1
            )
        );
        modify(trader1, FUNDED, collateralId, -int256(MARGIN + 1));
    }

    /// @dev HOLDER's stored snxUSD (992e18, after the book trade's fee) is more than the
    ///      915e18 this withdraws, so `InsufficientSynthCollateral` (held < requested) does not
    ///      fire first; 915e18 is still past the ~102e18 the open 10 ETH position requires, so
    ///      the withdraw-time initial-margin check is the one that does.
    function test_intoTheInitialMargin() public {
        int256 withdrawable = perps.getWithdrawableMargin(HOLDER);
        refused(
            abi.encodeWithSelector(
                CollateralChange.InsufficientCollateralAvailableForWithdraw.selector,
                withdrawable,
                uint256(915e18)
            )
        );
        modify(trader2, HOLDER, collateralId, -915e18);
    }

    /// @dev 10 ETH bought at 1,000 on 1,000 snxUSD: at 850 the loss of 1,500 exceeds the
    ///      collateral. Nobody has called liquidate, so the flag is down: the refusal is the
    ///      withdrawal rule's, not the flag's.
    function test_belowTheInitialMargin() public {
        crash(ethMarketId, 850e18);
        assertEq(perps.flaggedAccounts().length, 0);
        refused(abi.encodeWithSelector(PerpsAccount.AccountLiquidatable.selector, UNDERWATER));
        modify(trader2, UNDERWATER, collateralId, -1e18);
    }

    /// @dev `depositMargin` approves exactly what it deposits, so nothing is left over.
    function test_noAllowance() public {
        refused(
            abi.encodeWithSelector(IERC20.InsufficientAllowance.selector, uint256(1e18), uint256(0))
        );
        modify(trader1, FUNDED, collateralId, 1e18);
    }

    function test_twoDefects_whoKnocksIsAskedFirst() public {
        refused(denied(FUNDED, trader2));
        modify(trader2, FUNDED, NOBODY, 1e18);
        refused(notFound(NOBODY));
        modify(trader1, NOBODY, NOBODY, 1e18);
    }

    function test_payDebt_noAccount() public {
        refused(notFound(NOBODY));
        pay(trader1, NOBODY, 1e18);
    }

    function test_payDebt_noDebt_namesTheAccountAskedAbout() public {
        refused(abi.encodeWithSelector(CollateralChange.NonexistentDebt.selector, FUNDED));
        pay(trader1, FUNDED, 1e18);
        refused(abi.encodeWithSelector(CollateralChange.NonexistentDebt.selector, EMPTY));
        pay(trader1, EMPTY, 1e18);
    }

    // ------------------------------------------------------------------------------ the events

    function test_aDeposit_emitsCollateralModified_andNoInterestRateUpdated() public {
        vm.startPrank(trader1);
        usdToken.approve(address(perps), 100e18);
        vm.expectEmit(true, true, true, true, address(perps));
        emit IPerpsAccountModule.CollateralModified(FUNDED, collateralId, 100e18, trader1);
        vm.recordLogs();
        perps.modifyCollateral(FUNDED, collateralId, 100e18);
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != IGlobalPerpsMarketModule.InterestRateUpdated.selector,
                "the rate followed a deposit"
            );
        }
        assertEq(perps.getCollateralAmount(FUNDED, collateralId), MARGIN + 100e18);
    }

    function test_aWithdrawal_emitsCollateralModified() public {
        vm.expectEmit(true, true, true, true, address(perps));
        emit IPerpsAccountModule.CollateralModified(FUNDED, collateralId, -100e18, trader1);
        modify(trader1, FUNDED, collateralId, -100e18);
        assertEq(perps.getCollateralAmount(FUNDED, collateralId), MARGIN - 100e18);
    }
}
