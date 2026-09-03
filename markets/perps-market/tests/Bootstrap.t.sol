// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {Test} from "forge-std/Test.sol";

import {CannonDeploy} from "../script/Deploy.sol";
import {IPerpsMarketProxy} from "./interfaces/IPerpsMarketProxy.sol";
import {ICoreProxy} from "./interfaces/ICoreProxy.sol";
import {IOracleManagerProxy} from "./interfaces/IOracleManagerProxy.sol";
import {IBookOrderModule} from "../contracts/interfaces/IBookOrderModule.sol";
import {ISynthetixSystem} from "../contracts/interfaces/external/ISynthetixSystem.sol";
import {ISpotMarketSystem} from "../contracts/interfaces/external/ISpotMarketSystem.sol";
import {IPoolModule} from "@synthetixio/main/contracts/interfaces/IPoolModule.sol";
import {MarketConfiguration} from "@synthetixio/main/contracts/storage/MarketConfiguration.sol";
import {CollateralConfiguration} from "@synthetixio/main/contracts/storage/CollateralConfiguration.sol";
import {CollateralMock} from "@synthetixio/main/contracts/mocks/CollateralMock.sol";
import {MockV3Aggregator} from "@synthetixio/oracle-manager/contracts/mocks/MockV3Aggregator.sol";
import {NodeDefinition} from "@synthetixio/oracle-manager/contracts/storage/NodeDefinition.sol";
import {NodeOutput} from "@synthetixio/oracle-manager/contracts/storage/NodeOutput.sol";
import {IERC20} from "@synthetixio/core-contracts/contracts/interfaces/IERC20.sol";
import {IERC721} from "@synthetixio/core-contracts/contracts/interfaces/IERC721.sol";
import {IERC721Receiver} from "@synthetixio/core-contracts/contracts/interfaces/IERC721Receiver.sol";

/**
 * @title The perps market stand
 *
 * @notice Replays the testable protocol that `build-testable` wrote into `script/Deploy.sol` —
 *         the cannonfile the Hardhat suite runs, with the core cloned so the script is
 *         self-contained — and describes the scenario on top of it: one pool with one LP, two
 *         perps markets on mock Chainlink aggregators, snxUSD as the only margin collateral, two
 *         traders funded by one formula.
 *
 * @dev A trader is a staker. `fundStaker` stakes mock collateral in the pool and mints the
 *      snxUSD that stake supports, `stake * price / issuanceRatio`, into the owner's wallet;
 *      `bookTrader` deposits part of it into a perps account. Accounts are on the book by
 *      default (3b30b15e), so nothing here calls `setBookMode`.
 *
 *      The market caps, funding parameters and per-account caps are the defaults of the Hardhat
 *      adapter (`test/bootstrap/bootstrapPerpsMarkets.ts`, `bootstrap.ts`): a stand that sets
 *      none of them cannot open a position past the gate of PR #19.
 */
contract BootstrapTest is Test, IERC721Receiver {
    address trader1 = makeAddr("trader1");
    address trader2 = makeAddr("trader2");
    address whale = makeAddr("whale");
    /// @dev Spot is imported by the cannonfile, not cloned, so the script carries no spot
    ///      deployment. The factory only stores the address, and no Foundry test uses synth
    ///      collateral.
    address spotMarket = makeAddr("SpotMarketProxy");

    CannonDeploy deployer;
    IPerpsMarketProxy perps;
    ICoreProxy core;
    IOracleManagerProxy oracleManager;
    IERC20 usdToken;
    IERC721 accountNft;
    CollateralMock collateralToken;

    MockV3Aggregator collateralAggregator;
    MockV3Aggregator ethAggregator;
    MockV3Aggregator btcAggregator;
    CollateralConfiguration.Data collateralConfig;

    uint128 constant poolId = 1;
    uint128 constant ethMarketId = 2;
    uint128 constant btcMarketId = 3;
    uint128 constant collateralId = 0; // snxUSD
    uint128 superMarketId; // the perps market as the core sees it

    uint256 constant COLLATERAL_PRICE = 1e18;
    uint256 constant ETH_PRICE = 2400e18;
    uint256 constant BTC_PRICE = 60_000e18;

    /// @dev At price 1 and issuance ratio 5 a stake supports a fifth of itself in snxUSD.
    uint256 constant WHALE_STAKE = 50_000_000e18;
    uint256 constant TRADER_STAKE = 50_000_000e18; // 10M snxUSD per trader

    function setUp() public virtual {
        deployer = new CannonDeploy();
        deployer.run();

        perps = IPerpsMarketProxy(deployer.getAddress("PerpsMarketProxy"));
        core = ICoreProxy(deployer.getAddress("synthetix.CoreProxy"));
        accountNft = IERC721(deployer.getAddress("synthetix.AccountProxy"));
        oracleManager = IOracleManagerProxy(deployer.getAddress("synthetix.oracle_manager.Proxy"));
        usdToken = IERC20(deployer.getAddress("synthetix.USDProxy"));
        collateralToken = CollateralMock(deployer.getAddress("synthetix.CollateralMock"));
        vm.label(address(perps), "PerpsMarketProxy");
        vm.label(address(core), "CoreProxy");
        vm.label(address(accountNft), "AccountProxy");
        vm.label(address(oracleManager), "OracleManagerProxy");
        vm.label(address(usdToken), "snxUSD");
        vm.label(address(collateralToken), "CollateralMock");

        _configureCore();

        // The perps market registers itself with the core as one market; the Hardhat adapter
        // does the same in bootstrapPerpsMarkets.
        vm.prank(perps.owner());
        superMarketId = perps.initializeFactory(
            ISynthetixSystem(address(core)),
            ISpotMarketSystem(spotMarket)
        );

        MarketConfiguration.Data[] memory pool = new MarketConfiguration.Data[](1);
        pool[0] = MarketConfiguration.Data({
            marketId: superMarketId,
            weightD18: 1,
            maxDebtShareValueD18: type(int128).max
        });
        vm.prank(core.owner());
        IPoolModule(address(core)).setPoolConfiguration(poolId, pool);

        _configurePerps();

        ethAggregator = createPerpsMarket(ethMarketId, "Ether", "ETHPERP", ETH_PRICE);
        btcAggregator = createPerpsMarket(btcMarketId, "Bitcoin", "BTCPERP", BTC_PRICE);

        stake(whale, WHALE_STAKE);
        fundStaker(trader1, TRADER_STAKE);
        fundStaker(trader2, TRADER_STAKE);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ the deployed protocol

    /// @dev A pool, and the mock token as its only collateral, priced by a Chainlink node.
    function _configureCore() internal {
        collateralAggregator = new MockV3Aggregator();
        collateralAggregator.mockSetCurrentPrice(COLLATERAL_PRICE, 18);

        vm.startPrank(core.owner());
        IPoolModule(address(core)).createPool(poolId, core.owner());
        core.configureCollateral(
            CollateralConfiguration.Data({
                depositingEnabled: true,
                issuanceRatioD18: 5e18,
                liquidationRatioD18: 1.01e18,
                liquidationRewardD18: 0,
                oracleNodeId: chainlinkNode(collateralAggregator),
                tokenAddress: address(collateralToken),
                minDelegationD18: 0
            })
        );
        vm.stopPrank();
        collateralConfig = core.getCollateralConfiguration(address(collateralToken));
    }

    /// @dev snxUSD as margin without a cap, no keeper cost, accounts creatable by anyone.
    function _configurePerps() internal {
        bytes32[] memory noParents = new bytes32[](0);
        bytes32 zeroCostNode = oracleManager.registerNode(
            NodeDefinition.NodeType.CONSTANT,
            abi.encode(0),
            noParents
        );

        vm.startPrank(perps.owner());
        perps.setCollateralConfiguration(collateralId, type(uint256).max, 0, 0, 0);
        perps.setPerAccountCaps(100_000, 100_000);
        perps.updateKeeperCostNodeId(zeroCostNode);
        perps.setFeatureFlagAllowAll("createAccount", true);
        vm.stopPrank();
    }

    /// @dev A perps market on a fresh Chainlink aggregator at `price`, with the caps and funding
    ///      parameters the Hardhat adapter uses by default.
    function createPerpsMarket(
        uint128 marketId,
        string memory name,
        string memory symbol,
        uint256 price
    ) internal returns (MockV3Aggregator aggregator) {
        aggregator = new MockV3Aggregator();
        aggregator.mockSetCurrentPrice(price, 18);

        vm.startPrank(perps.owner());
        perps.createMarket(marketId, name, symbol);
        perps.updatePriceData(marketId, chainlinkNode(aggregator), 0);
        perps.setFundingParameters(marketId, 1_000_000e18, 0);
        perps.setMaxMarketSize(marketId, 10_000_000e18);
        perps.setMaxMarketValue(marketId, 0); // zero is no bound
        vm.stopPrank();
    }

    function chainlinkNode(MockV3Aggregator aggregator) internal returns (bytes32 nodeId) {
        bytes32[] memory noParents = new bytes32[](0);
        return
            oracleManager.registerNode(
                NodeDefinition.NodeType.CHAINLINK,
                abi.encode(address(aggregator), uint256(0), uint8(18)),
                noParents
            );
    }

    // ------------------------------------------------------------------------------ funding

    /// @dev Stakes `collateral` of the mock token for `owner`: a fresh core account, deposited
    ///      and delegated to the pool. Returns the core account id.
    function stake(address owner, uint256 collateral) internal returns (uint128 accountId) {
        vm.startPrank(owner);
        accountId = core.createAccount();
        collateralToken.mint(owner, collateral);
        collateralToken.approve(address(core), collateral);
        core.deposit(accountId, address(collateralToken), collateral);
        core.delegateCollateral(accountId, poolId, address(collateralToken), collateral, 1e18);
        vm.stopPrank();
    }

    /// @dev A trader is a staker: stakes `collateral` and mints the snxUSD that stake supports,
    ///      `collateral * price / issuanceRatio`, into the owner's wallet. The one funding
    ///      formula of the stand.
    function fundStaker(
        address owner,
        uint256 collateral
    ) internal returns (uint128 accountId, uint256 snxUsd) {
        accountId = stake(owner, collateral);
        NodeOutput.Data memory collateralPrice = oracleManager.process(
            collateralConfig.oracleNodeId
        );
        snxUsd = (collateral * uint256(collateralPrice.price)) / collateralConfig.issuanceRatioD18;

        vm.startPrank(owner);
        core.mintUsd(accountId, poolId, address(collateralToken), snxUsd);
        core.withdraw(accountId, address(usdToken), snxUsd);
        vm.stopPrank();
    }

    /// @dev A perps account with the requested id, funded with `snxUsd` from the owner's wallet.
    ///      BOOK is the protocol default, so the account is on the book without a setBookMode.
    function bookTrader(address owner, uint128 accountId, uint256 snxUsd) internal {
        vm.startPrank(owner);
        perps.createAccount(accountId);
        usdToken.approve(address(perps), snxUsd);
        perps.modifyCollateral(accountId, collateralId, int256(snxUsd));
        vm.stopPrank();
    }

    /// @dev The same, with an id the protocol picks.
    function bookTrader(address owner, uint256 snxUsd) internal returns (uint128 accountId) {
        vm.startPrank(owner);
        accountId = perps.createAccount();
        usdToken.approve(address(perps), snxUsd);
        perps.modifyCollateral(accountId, collateralId, int256(snxUsd));
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------------- the book

    function bookOrder(
        uint128 accountId,
        int128 sizeDelta,
        uint256 price
    ) internal pure returns (IBookOrderModule.BookOrder memory) {
        return
            IBookOrderModule.BookOrder({
                accountId: accountId,
                sizeDelta: sizeDelta,
                orderPrice: price,
                signedPriceData: "",
                trackingCode: bytes32(0)
            });
    }

    /// @dev `settleBookOrders` wants the batch ascending by account id, as the settler sends it.
    function sortByAccountId(
        IBookOrderModule.BookOrder[] memory orders
    ) internal pure returns (IBookOrderModule.BookOrder[] memory sorted) {
        sorted = new IBookOrderModule.BookOrder[](orders.length);
        for (uint256 i = 0; i < orders.length; i++) {
            sorted[i] = orders[i];
        }
        for (uint256 i = 1; i < sorted.length; i++) {
            IBookOrderModule.BookOrder memory key = sorted[i];
            uint256 j = i;
            while (j > 0 && sorted[j - 1].accountId > key.accountId) {
                sorted[j] = sorted[j - 1];
                j--;
            }
            sorted[j] = key;
        }
    }

    /// @dev Settles a batch as the orderbook would: sorted, in one call.
    function settleBook(uint128 marketId, IBookOrderModule.BookOrder[] memory orders) internal {
        perps.settleBookOrders(marketId, sortByAccountId(orders));
    }

    /// @dev One account's position change on the book. The pool is the counterparty, so one leg
    ///      is a complete order.
    function openBookPosition(
        uint128 accountId,
        uint128 marketId,
        int128 sizeDelta,
        uint256 price
    ) internal {
        IBookOrderModule.BookOrder[] memory orders = new IBookOrderModule.BookOrder[](1);
        orders[0] = bookOrder(accountId, sizeDelta, price);
        perps.settleBookOrders(marketId, orders);
    }

    /// @dev Advances time with every oracle price pinned, so no price pnl is generated and no
    ///      Chainlink node goes stale.
    function warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        collateralAggregator.mockSetCurrentPrice(COLLATERAL_PRICE, 18);
        ethAggregator.mockSetCurrentPrice(ETH_PRICE, 18);
        btcAggregator.mockSetCurrentPrice(BTC_PRICE, 18);
    }
}
