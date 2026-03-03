// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {SafeCastU256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {ForkDetector} from "@synthetixio/core-contracts/contracts/utils/ForkDetector.sol";
import {IExternalNode, NodeOutput, NodeDefinition} from "@synthetixio/oracle-manager/contracts/interfaces/external/IExternalNode.sol";

contract MegaEthGasPriceOracle is IExternalNode {
    using SafeCastU256 for uint256;

    uint256 public constant KIND_SETTLEMENT = 0;
    uint256 public constant KIND_FLAG = 1;
    uint256 public constant KIND_LIQUIDATE = 2;

    struct RuntimeParams {
        // Order execution
        uint256 settleGasUnits;
        // Flag
        uint256 flagGasUnits;
        // Liquidate (Rate limited)
        uint256 liquidateGasUnits;
        // Call params
        uint256 numberOfUpdatedFeeds;
        uint256 executionKind;
    }

    error MegaEthGasPriceOracleInvalidExecutionKind();

    function process(
        NodeOutput.Data[] memory,
        bytes memory parameters,
        bytes32[] memory runtimeKeys,
        bytes32[] memory runtimeValues
    ) external view returns (NodeOutput.Data memory nodeOutput) {
        RuntimeParams memory runtimeParams;
        (
            ,
            runtimeParams.settleGasUnits,
            runtimeParams.flagGasUnits,
            runtimeParams.liquidateGasUnits
        ) = abi.decode(parameters, (address, uint256, uint256, uint256));

        for (uint256 i = 0; i < runtimeKeys.length; i++) {
            if (runtimeKeys[i] == "executionKind") {
                // solhint-disable-next-line numcast/safe-cast
                runtimeParams.executionKind = uint256(runtimeValues[i]);
                continue;
            }
            if (runtimeKeys[i] == "numberOfUpdatedFeeds") {
                // solhint-disable-next-line numcast/safe-cast
                runtimeParams.numberOfUpdatedFeeds = uint256(runtimeValues[i]);
                continue;
            }
        }

        uint256 costOfExecutionEth = getCostOfExecutionEth(runtimeParams);

        return NodeOutput.Data(costOfExecutionEth.toInt(), block.timestamp, 0, 0);
    }

    function getCostOfExecutionEth(
        RuntimeParams memory runtimeParams
    ) internal view returns (uint256 costOfExecutionGrossEth) {
        if (ForkDetector.isDevFork()) {
            return 0.001 ether;
        }

        uint256 gasUnits = getGasUnits(runtimeParams);
        costOfExecutionGrossEth = gasUnits * block.basefee;
    }

    function getGasUnits(
        RuntimeParams memory runtimeParams
    ) internal pure returns (uint256 gasUnits) {
        if (runtimeParams.executionKind == KIND_SETTLEMENT) {
            gasUnits = runtimeParams.settleGasUnits;
        } else if (runtimeParams.executionKind == KIND_FLAG) {
            gasUnits = runtimeParams.numberOfUpdatedFeeds * runtimeParams.flagGasUnits;
        } else if (runtimeParams.executionKind == KIND_LIQUIDATE) {
            gasUnits = runtimeParams.liquidateGasUnits;
        } else {
            revert MegaEthGasPriceOracleInvalidExecutionKind();
        }
    }

    function isValid(NodeDefinition.Data memory nodeDefinition) external view returns (bool valid) {
        // Must have no parents
        if (nodeDefinition.parents.length > 0) {
            return false;
        }

        // must be able to decode parameters
        RuntimeParams memory runtimeParams;
        (
            ,
            runtimeParams.settleGasUnits,
            runtimeParams.flagGasUnits,
            runtimeParams.liquidateGasUnits
        ) = abi.decode(nodeDefinition.parameters, (address, uint256, uint256, uint256));

        return true;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IExternalNode).interfaceId ||
            interfaceId == this.supportsInterface.selector;
    }
}
