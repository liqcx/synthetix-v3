//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {ERC2771Context} from "@synthetixio/core-contracts/contracts/utils/ERC2771Context.sol";
import {SetUtil} from "@synthetixio/core-contracts/contracts/utils/SetUtil.sol";
import {SafeCastU256, SafeCastI256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {ITokenModule} from "@synthetixio/core-modules/contracts/interfaces/ITokenModule.sol";
import {IPerpsAccountModule} from "../interfaces/IPerpsAccountModule.sol";
import {IGlobalPerpsMarketModule} from "../interfaces/IGlobalPerpsMarketModule.sol";
import {MathUtil} from "../utils/MathUtil.sol";
import {AsyncOrder} from "./AsyncOrder.sol";
import {GlobalPerpsMarket} from "./GlobalPerpsMarket.sol";
import {GlobalPerpsMarketConfiguration} from "./GlobalPerpsMarketConfiguration.sol";
import {InterestRate} from "./InterestRate.sol";
import {LiquidationFlag} from "./LiquidationFlag.sol";
import {PerpsAccount, SNX_USD_MARKET_ID} from "./PerpsAccount.sol";
import {PerpsCollateralConfiguration} from "./PerpsCollateralConfiguration.sol";
import {PerpsMarketFactory} from "./PerpsMarketFactory.sol";
import {PerpsPrice} from "./PerpsPrice.sol";

/**
 * @title The trader's changes of an account's collateral — a deposit or withdrawal, and a debt
 * payment: whether the account may make one, and what follows it.
 * @dev Owns no storage: the ledger stays with `PerpsAccount` and `GlobalPerpsMarket`. This is
 * the one place the rules of the two doors are written, as `Settlement` is for a settled change.
 * The doors keep who knocks — the feature flag, the account's existence, the permission.
 */
library CollateralChange {
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SetUtil for SetUtil.UintSet;
    using PerpsAccount for PerpsAccount.Data;
    using PerpsMarketFactory for PerpsMarketFactory.Data;
    using PerpsCollateralConfiguration for PerpsCollateralConfiguration.Data;

    /**
     * @notice Thrown when depositing a collateral the market has not enabled.
     */
    error SynthNotEnabledForCollateral(uint128 collateralId);

    /**
     * @notice Thrown when a deposit would take the market past the collateral's cap.
     */
    error MaxCollateralExceeded(
        uint128 collateralId,
        uint256 maxAmount,
        uint256 collateralAmount,
        uint256 depositAmount
    );

    /**
     * @notice Thrown when a withdrawal asks more of a collateral than the market holds.
     */
    error InsufficientCollateral(
        uint128 collateralId,
        uint256 collateralAmount,
        uint256 withdrawAmount
    );

    /**
     * @notice Thrown when a new collateral would take the account past its limit of kinds.
     */
    error MaxCollateralsPerAccountReached(uint128 maxCollateralsPerAccount);

    /**
     * @notice Thrown when a withdrawal asks more of a collateral than the account holds.
     */
    error InsufficientSynthCollateral(
        uint128 collateralId,
        uint256 collateralAmount,
        uint256 withdrawAmount
    );

    /**
     * @notice Thrown when a withdrawal would leave the account below its initial margin plus
     * the liquidation reward.
     */
    error InsufficientCollateralAvailableForWithdraw(
        int256 withdrawableMarginUsd,
        uint256 requestedMarginUsd
    );

    /**
     * @notice Thrown when there is no debt to pay.
     */
    error NonexistentDebt(uint128 accountId);

    /**
     * @notice Reverts, in order, unless `accountId` may change `collateralId` by `amountDelta`:
     * the collateral is one the market knows; the delta is not zero; a deposit fits the
     * collateral's cap, a withdrawal the market's balance of it; the account is not flagged; a
     * new collateral fits the account's limit; no async order is pending; and a withdrawal fits
     * what the account holds and leaves it, valued strictly, above its initial margin plus the
     * liquidation reward. A view: the hook a quote would ask.
     */
    function validate(uint128 accountId, uint128 collateralId, int256 amountDelta) internal view {
        if (!PerpsCollateralConfiguration.validDistributorExists(collateralId)) {
            revert IPerpsAccountModule.InvalidDistributor(collateralId);
        }
        if (amountDelta == 0) {
            revert IPerpsAccountModule.InvalidAmountDelta(amountDelta);
        }
        _admitByTheMarket(collateralId, amountDelta);
        LiquidationFlag.admit(accountId);
        _admitByTheAccountsLimit(accountId, collateralId);
        AsyncOrder.checkPendingOrder(accountId);
        if (amountDelta < 0) {
            _admitWithdrawal(accountId, collateralId, MathUtil.abs(amountDelta));
        }
    }

    /**
     * @notice Makes the change: `validate`; the funds moved with the core — snxUSD deposited to
     * or withdrawn from the market, a synth taken from or returned to the caller; the account's
     * ledger; `CollateralModified`.
     * @dev The rate is not updated here on purpose. A deposit or withdrawal moves the market's
     * credit and the trader's collateral together — exactly for snxUSD, and for a synth up to
     * the agreement of the core's and the spot market's price of it — so the delegated
     * collateral, and with it the utilization, do not move: the rate has nothing to follow.
     */
    function make(uint128 accountId, uint128 collateralId, int256 amountDelta) internal {
        validate(accountId, collateralId, amountDelta);
        if (amountDelta > 0) {
            _deposit(collateralId, amountDelta.toUint());
        } else {
            _withdraw(collateralId, MathUtil.abs(amountDelta));
        }
        PerpsAccount.create(accountId).updateCollateralAmount(collateralId, amountDelta);
        emit IPerpsAccountModule.CollateralModified(
            accountId,
            collateralId,
            amountDelta,
            ERC2771Context._msgSender()
        );
    }

    /**
     * @notice Pays up to `amount` of the account's debt with the caller's snxUSD: no async order
     * may be pending; nothing to pay reverts `NonexistentDebt`; the excess is ignored.
     * `DebtPaid`, then the rate follows: the paid USD joins the pool's credit and no trader
     * collateral rises with it — `InterestRate.update`, `InterestRateUpdated`.
     * @return debtPaid what was paid: the debt or `amount`, whichever is less.
     */
    function payDebt(uint128 accountId, uint256 amount) internal returns (uint256 debtPaid) {
        AsyncOrder.checkPendingOrder(accountId);
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        if (account.debt == 0) {
            revert NonexistentDebt(accountId);
        }
        debtPaid = MathUtil.min(account.debt, amount);
        account.updateAccountDebt(-debtPaid.toInt());

        PerpsMarketFactory.Data storage factory = PerpsMarketFactory.load();
        factory.synthetix.depositMarketUsd(
            factory.perpsMarketId,
            ERC2771Context._msgSender(),
            debtPaid
        );
        emit IPerpsAccountModule.DebtPaid(accountId, debtPaid, ERC2771Context._msgSender());

        (uint128 interestRate, ) = InterestRate.update(PerpsPrice.Tolerance.DEFAULT);
        emit IGlobalPerpsMarketModule.InterestRateUpdated(factory.perpsMarketId, interestRate);
    }

    // ------------------------------------------------------------------ the rules, as they were

    /**
     * @dev `GlobalPerpsMarket.validateCollateralAmount` as it was: enabled, the cap, the
     * market's balance of the collateral.
     */
    function _admitByTheMarket(uint128 collateralId, int256 amountDelta) private view {
        uint256 collateralAmount = GlobalPerpsMarket.load().collateralAmounts[collateralId];
        if (amountDelta > 0) {
            uint256 maxAmount = PerpsCollateralConfiguration.load(collateralId).maxAmount;
            if (maxAmount == 0) {
                revert SynthNotEnabledForCollateral(collateralId);
            }
            uint256 newCollateralAmount = collateralAmount + amountDelta.toUint();
            if (newCollateralAmount > maxAmount) {
                revert MaxCollateralExceeded(
                    collateralId,
                    maxAmount,
                    collateralAmount,
                    amountDelta.toUint()
                );
            }
        } else {
            uint256 amountAbs = MathUtil.abs(amountDelta);
            if (collateralAmount < amountAbs) {
                revert InsufficientCollateral(collateralId, collateralAmount, amountAbs);
            }
        }
    }

    /**
     * @dev `PerpsAccount.validateMaxCollaterals` as it was.
     */
    function _admitByTheAccountsLimit(uint128 accountId, uint128 collateralId) private view {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        if (account.collateralAmounts[collateralId] == 0) {
            uint128 maxCollateralsPerAccount = GlobalPerpsMarketConfiguration
                .load()
                .maxCollateralsPerAccount;
            if (maxCollateralsPerAccount <= account.activeCollateralTypes.length()) {
                revert MaxCollateralsPerAccountReached(maxCollateralsPerAccount);
            }
        }
    }

    /**
     * @dev `PerpsAccount.validateWithdrawableAmount` as it was: the account's balance of the
     * collateral, then the account valued strictly — a withdrawal is judged at fresh prices, as
     * a liquidation is — against what it may withdraw.
     */
    function _admitWithdrawal(
        uint128 accountId,
        uint128 collateralId,
        uint256 amount
    ) private view {
        PerpsAccount.Data storage account = PerpsAccount.load(accountId);
        uint256 collateralAmount = account.collateralAmounts[collateralId];
        if (collateralAmount < amount) {
            revert InsufficientSynthCollateral(collateralId, collateralAmount, amount);
        }

        PerpsAccount.Valuation memory v = account.valuation(PerpsPrice.Tolerance.STRICT);
        int256 withdrawableMarginUsd = PerpsAccount.getWithdrawableMargin(v);
        if (withdrawableMarginUsd < 0) {
            revert PerpsAccount.AccountLiquidatable(accountId);
        }

        uint256 amountUsd = amount;
        if (collateralId != SNX_USD_MARKET_ID) {
            (amountUsd, ) = PerpsCollateralConfiguration.load(collateralId).valueInUsd(
                amount,
                PerpsMarketFactory.load().spotMarket,
                PerpsPrice.Tolerance.STRICT
            );
        }
        if (amountUsd.toInt() > withdrawableMarginUsd) {
            revert InsufficientCollateralAvailableForWithdraw(withdrawableMarginUsd, amountUsd);
        }
    }

    /**
     * @dev `_depositMargin` as it was: snxUSD from the caller into the market's credit; a synth
     * from the caller into the market's collateral.
     */
    function _deposit(uint128 collateralId, uint256 amount) private {
        PerpsMarketFactory.Data storage factory = PerpsMarketFactory.load();
        if (collateralId == SNX_USD_MARKET_ID) {
            factory.synthetix.depositMarketUsd(
                factory.perpsMarketId,
                ERC2771Context._msgSender(),
                amount
            );
        } else {
            ITokenModule synth = ITokenModule(factory.spotMarket.getSynth(collateralId));
            synth.transferFrom(ERC2771Context._msgSender(), address(this), amount);
            factory.depositMarketCollateral(synth, amount);
        }
    }

    /**
     * @dev `_withdrawMargin` as it was: snxUSD out of the market's credit to the caller; a synth
     * out of the market's collateral, then to the caller.
     */
    function _withdraw(uint128 collateralId, uint256 amount) private {
        PerpsMarketFactory.Data storage factory = PerpsMarketFactory.load();
        if (collateralId == SNX_USD_MARKET_ID) {
            factory.synthetix.withdrawMarketUsd(
                factory.perpsMarketId,
                ERC2771Context._msgSender(),
                amount
            );
        } else {
            ITokenModule synth = ITokenModule(factory.spotMarket.getSynth(collateralId));
            factory.synthetix.withdrawMarketCollateral(
                factory.perpsMarketId,
                address(synth),
                amount
            );
            synth.transfer(ERC2771Context._msgSender(), amount);
        }
    }
}
