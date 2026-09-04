// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable */

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {CannonDeploy} from "../script/Deploy.sol";
import {IPerpsMarketProxy} from "./interfaces/IPerpsMarketProxy.sol";
import {ICoreProxy} from "./interfaces/ICoreProxy.sol";
import {IOracleManagerProxy} from "./interfaces/IOracleManagerProxy.sol";
import {IBookOrderModule} from "../contracts/interfaces/IBookOrderModule.sol";
import {SettlementStrategy} from "../contracts/storage/SettlementStrategy.sol";
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
 *         self-contained — and executes the scenario `test/stand.json` describes: the
 *         collateral and its ratios, the perps pool with one LP, the traders' own pool, the
 *         markets on mock Chainlink aggregators, two traders funded by one formula, and the
 *         accounts on the book. The Hardhat adapter (`test/bootstrap/`) executes the same file.
 *
 * @dev Units of the file: integers in human units, ratios and fees in basis points (1 bps is
 *      1e14 in D18). A trader is a staker: `fundStaker` stakes in the traders' pool and mints
 *      the snxUSD that stake supports, `stake * price / issuanceRatio`, into the owner's
 *      wallet; `depositMargin` moves part of it into a perps account. Accounts are on the book
 *      by default; `onchainTrader` opts one out.
 */
contract BootstrapTest is Test, IERC721Receiver {
    using stdJson for string;

    address trader1 = makeAddr("trader1");
    address trader2 = makeAddr("trader2");
    address lp = makeAddr("lp");
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

    // ---- test/stand.json
    string stand;
    uint256 collateralPrice; // D18
    uint128 poolId;
    uint256 lpStake;
    uint256 maxMarketSize;
    uint256 strictPriceTolerance;
    uint128[] marketIds;
    uint256[] marketPrices; // D18
    MockV3Aggregator[] aggregators;
    uint128 traderPool;
    uint256 traderStake;
    uint128[] bookAccounts;
    // ---- test/stand.json -> marketDefaults.settlementStrategy: the async door's strategy
    uint256 settlementDelay;
    uint256 settlementWindowDuration;
    uint256 commitmentPriceDelay;
    uint256 settlementReward; // D18
    /// @dev The stand's MockPyth wrapper, the strategy's price verification contract.
    address pythWrapper;

    /// @dev The first market of the description, for tests that trade one market.
    uint128 ethMarketId;
    uint256 ETH_PRICE;

    MockV3Aggregator collateralAggregator;
    CollateralConfiguration.Data collateralConfig;
    uint128 constant collateralId = 0; // snxUSD
    uint128 superMarketId; // the perps market as the core sees it

    function setUp() public virtual {
        _readStand();

        deployer = new CannonDeploy();
        deployer.run();

        perps = IPerpsMarketProxy(deployer.getAddress("PerpsMarketProxy"));
        core = ICoreProxy(deployer.getAddress("synthetix.CoreProxy"));
        accountNft = IERC721(deployer.getAddress("synthetix.AccountProxy"));
        oracleManager = IOracleManagerProxy(deployer.getAddress("synthetix.oracle_manager.Proxy"));
        usdToken = IERC20(deployer.getAddress("synthetix.USDProxy"));
        collateralToken = CollateralMock(deployer.getAddress("synthetix.CollateralMock"));
        pythWrapper = deployer.getAddress("MockPythERC7412Wrapper");
        vm.label(address(perps), "PerpsMarketProxy");
        vm.label(address(core), "CoreProxy");
        vm.label(address(accountNft), "AccountProxy");
        vm.label(address(oracleManager), "OracleManagerProxy");
        vm.label(address(usdToken), "snxUSD");
        vm.label(address(collateralToken), "CollateralMock");
        vm.label(pythWrapper, "MockPythERC7412Wrapper");

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
            weightD18: 1e18,
            maxDebtShareValueD18: 1e18
        });
        vm.prank(core.owner());
        IPoolModule(address(core)).setPoolConfiguration(poolId, pool);

        _configurePerps();

        for (uint256 i = 0; i < marketIds.length; i++) {
            string memory m = string.concat(".markets[", vm.toString(i), "]");
            aggregators.push(
                createPerpsMarket(
                    marketIds[i],
                    stand.readString(string.concat(m, ".name")),
                    stand.readString(string.concat(m, ".symbol")),
                    marketPrices[i],
                    stand.readUint(string.concat(m, ".skewScale")) * 1e18,
                    stand.readUint(string.concat(m, ".maxFundingVelocity")) * 1e18,
                    stand.readUint(string.concat(m, ".makerFeeBps")) * 1e14,
                    stand.readUint(string.concat(m, ".takerFeeBps")) * 1e14
                )
            );
        }
        ethMarketId = marketIds[0];
        ETH_PRICE = marketPrices[0];

        stake(lp, poolId, lpStake);
        fundStaker(trader1, traderStake);
        fundStaker(trader2, traderStake);

        // As the Hardhat adapter does: account i belongs to trader i + 1, and stays on the book.
        for (uint256 i = 0; i < bookAccounts.length; i++) {
            openBookAccount(i % 2 == 0 ? trader1 : trader2, bookAccounts[i]);
        }
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------------ the description

    function _readStand() internal {
        stand = vm.readFile(string.concat(vm.projectRoot(), "/test/stand.json"));
        collateralPrice = stand.readUint(".collateral.price") * 1e18;
        poolId = uint128(stand.readUint(".pool.id"));
        lpStake = stand.readUint(".pool.lpStake") * 1e18;
        maxMarketSize = stand.readUint(".marketDefaults.maxMarketSize") * 1e18;
        strictPriceTolerance = stand.readUint(".marketDefaults.strictPriceTolerance");
        settlementDelay = stand.readUint(".marketDefaults.settlementStrategy.settlementDelay");
        settlementWindowDuration = stand.readUint(
            ".marketDefaults.settlementStrategy.settlementWindowDuration"
        );
        commitmentPriceDelay = stand.readUint(
            ".marketDefaults.settlementStrategy.commitmentPriceDelay"
        );
        settlementReward =
            stand.readUint(".marketDefaults.settlementStrategy.settlementReward") *
            1e18;
        for (
            uint256 i = 0;
            vm.keyExistsJson(stand, string.concat(".markets[", vm.toString(i), "].id"));
            i++
        ) {
            string memory m = string.concat(".markets[", vm.toString(i), "]");
            marketIds.push(uint128(stand.readUint(string.concat(m, ".id"))));
            marketPrices.push(stand.readUint(string.concat(m, ".price")) * 1e18);
        }
        traderStake = stand.readUint(".trader.stake") * 1e18;
        traderPool = uint128(stand.readUint(".trader.pool"));
        uint256[] memory accounts = stand.readUintArray(".bookAccounts");
        for (uint256 i = 0; i < accounts.length; i++) {
            bookAccounts.push(uint128(accounts[i]));
        }
    }

    // ------------------------------------------------------------------ the deployed protocol

    /// @dev The perps pool and the traders' pool, and the mock token as the only collateral,
    ///      configured as the description says and priced by a Chainlink node.
    function _configureCore() internal {
        collateralAggregator = new MockV3Aggregator();
        collateralAggregator.mockSetCurrentPrice(collateralPrice, 18);

        vm.startPrank(core.owner());
        IPoolModule(address(core)).createPool(poolId, core.owner());
        IPoolModule(address(core)).createPool(traderPool, core.owner());
        core.configureCollateral(
            CollateralConfiguration.Data({
                depositingEnabled: true,
                issuanceRatioD18: stand.readUint(".collateral.issuanceRatioBps") * 1e14,
                liquidationRatioD18: stand.readUint(".collateral.liquidationRatioBps") * 1e14,
                liquidationRewardD18: stand.readUint(".collateral.liquidationReward") * 1e18,
                oracleNodeId: chainlinkNode(collateralAggregator),
                tokenAddress: address(collateralToken),
                minDelegationD18: stand.readUint(".collateral.minDelegation") * 1e18
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
        // The test contract is the stand's settler: the one address that may settle the book.
        perps.addToFeatureFlagAllowlist("settleBookOrders", address(this));
        vm.stopPrank();
    }

    /// @dev A perps market on a fresh Chainlink aggregator, with the parameters the description
    ///      gives it and the defaults it gives every market.
    function createPerpsMarket(
        uint128 marketId,
        string memory name,
        string memory symbol,
        uint256 price,
        uint256 skewScale,
        uint256 maxFundingVelocity,
        uint256 makerFee,
        uint256 takerFee
    ) internal returns (MockV3Aggregator aggregator) {
        aggregator = new MockV3Aggregator();
        aggregator.mockSetCurrentPrice(price, 18);

        vm.startPrank(perps.owner());
        perps.createMarket(marketId, name, symbol);
        perps.updatePriceData(marketId, chainlinkNode(aggregator), strictPriceTolerance);
        perps.setFundingParameters(marketId, skewScale, maxFundingVelocity);
        perps.setOrderFees(marketId, makerFee, takerFee);
        perps.setMaxMarketSize(marketId, maxMarketSize);
        perps.setMaxMarketValue(marketId, 0); // zero is no bound
        // The async door's strategy, as the Hardhat adapter adds one to every market: the
        // description's delays, verified by the stand's MockPyth wrapper. Strategy id 0.
        perps.addSettlementStrategy(
            marketId,
            SettlementStrategy.Data({
                strategyType: SettlementStrategy.Type.PYTH,
                settlementDelay: settlementDelay,
                settlementWindowDuration: settlementWindowDuration,
                priceVerificationContract: pythWrapper,
                feedId: bytes32("ETH/USD"),
                settlementReward: settlementReward,
                disabled: false,
                commitmentPriceDelay: commitmentPriceDelay
            })
        );
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

    /// @dev Stakes `collateral` of the mock token for `owner` in `pool`: a fresh core account,
    ///      deposited and delegated. Returns the core account id.
    function stake(
        address owner,
        uint128 pool,
        uint256 collateral
    ) internal returns (uint128 accountId) {
        vm.startPrank(owner);
        accountId = core.createAccount();
        collateralToken.mint(owner, collateral);
        collateralToken.approve(address(core), collateral);
        core.deposit(accountId, address(collateralToken), collateral);
        core.delegateCollateral(accountId, pool, address(collateralToken), collateral, 1e18);
        vm.stopPrank();
    }

    /// @dev A trader is a staker: stakes `collateral` in the traders' pool and mints the snxUSD
    ///      that stake supports, `collateral * price / issuanceRatio`, into the owner's wallet.
    ///      The one funding formula of the stand (`snxUsdFor` in the Hardhat adapter).
    function fundStaker(
        address owner,
        uint256 collateral
    ) internal returns (uint128 accountId, uint256 snxUsd) {
        accountId = stake(owner, traderPool, collateral);
        NodeOutput.Data memory price = oracleManager.process(collateralConfig.oracleNodeId);
        snxUsd = (collateral * uint256(price.price)) / collateralConfig.issuanceRatioD18;

        vm.startPrank(owner);
        core.mintUsd(accountId, traderPool, address(collateralToken), snxUsd);
        core.withdraw(accountId, address(usdToken), snxUsd);
        vm.stopPrank();
    }

    /// @dev A perps account with the requested id. BOOK is the protocol default, so the account
    ///      is on the book without a setBookMode.
    function openBookAccount(address owner, uint128 accountId) internal {
        vm.prank(owner);
        perps.createAccount(accountId);
    }

    /// @dev snxUSD from the owner's wallet into the account's margin.
    function depositMargin(address owner, uint128 accountId, uint256 snxUsd) internal {
        vm.startPrank(owner);
        usdToken.approve(address(perps), snxUsd);
        perps.modifyCollateral(accountId, collateralId, int256(snxUsd));
        vm.stopPrank();
    }

    /// @dev A funded book account with the requested id.
    function bookTrader(address owner, uint128 accountId, uint256 snxUsd) internal {
        openBookAccount(owner, accountId);
        depositMargin(owner, accountId, snxUsd);
    }

    /// @dev The same, with an id the protocol picks.
    function bookTrader(address owner, uint256 snxUsd) internal returns (uint128 accountId) {
        vm.prank(owner);
        accountId = perps.createAccount();
        depositMargin(owner, accountId, snxUsd);
    }

    /// @dev A funded account off the book, on the async path: opted out with `setBookMode(false)`
    ///      (the first set from the default takes effect at once). `openOnchainAccount` in the
    ///      Hardhat adapter.
    function onchainTrader(address owner, uint128 accountId, uint256 snxUsd) internal {
        openBookAccount(owner, accountId);
        vm.prank(owner);
        perps.setBookMode(accountId, false);
        depositMargin(owner, accountId, snxUsd);
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
    ///      Chainlink node goes stale past the strict tolerance.
    function warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        collateralAggregator.mockSetCurrentPrice(collateralPrice, 18);
        for (uint256 i = 0; i < aggregators.length; i++) {
            aggregators[i].mockSetCurrentPrice(marketPrices[i], 18);
        }
    }
}
