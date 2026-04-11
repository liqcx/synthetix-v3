// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Faucet} from "../src/Faucet.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";

contract FaucetTest is Test {
    Faucet internal faucet;
    MockMintableERC20 internal token;

    address internal owner = address(0xA11CE);
    address internal user = address(0xB0B);
    address internal tokenOwner = address(0xCAFE);

    uint128 internal constant CLAIM_AMOUNT = 400 * 10 ** 6; // 400 fUSDC (6 decimals)
    uint64 internal constant CLAIM_COOLDOWN = 1 days;
    uint256 internal constant INITIAL_POOL = 4_000_000 * 10 ** 6;

    function setUp() public {
        faucet = new Faucet(owner);
        token = new MockMintableERC20("Fake USD Coin", "fUSDC", 6, tokenOwner);

        vm.prank(tokenOwner);
        token.mint(INITIAL_POOL, address(faucet));

        vm.prank(owner);
        faucet.addToken(address(token), CLAIM_AMOUNT, CLAIM_COOLDOWN);
    }

    function test_claim_transfersAmountAndUpdatesLastClaimAt() public {
        uint256 faucetBalanceBefore = token.balanceOf(address(faucet));

        vm.prank(user);
        faucet.claim(address(token));

        assertEq(token.balanceOf(user), CLAIM_AMOUNT, "user received claimAmount");
        assertEq(
            token.balanceOf(address(faucet)),
            faucetBalanceBefore - CLAIM_AMOUNT,
            "faucet balance decreased by claimAmount"
        );
        assertEq(faucet.lastClaimAt(user, address(token)), block.timestamp, "lastClaimAt updated");
    }
}
