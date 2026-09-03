// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

/* solhint-disable no-empty-blocks */

import {INodeModule} from "@synthetixio/oracle-manager/contracts/interfaces/INodeModule.sol";
import {IOwnable} from "@synthetixio/core-contracts/contracts/interfaces/IOwnable.sol";
import {IUUPSImplementation} from "@synthetixio/core-contracts/contracts/interfaces/IUUPSImplementation.sol";

/**
 * @title IOracleManagerProxy
 * @notice The oracle manager router: NodeModule behind the CoreModule (owner + upgrade).
 */
interface IOracleManagerProxy is INodeModule, IOwnable, IUUPSImplementation {}
