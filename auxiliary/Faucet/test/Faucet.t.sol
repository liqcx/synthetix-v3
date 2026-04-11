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

    function test_claim_beforeCooldown_reverts() public {
        vm.prank(user);
        faucet.claim(address(token));

        uint256 expectedNextAt = block.timestamp + CLAIM_COOLDOWN;
        vm.expectRevert(abi.encodeWithSelector(Faucet.CooldownNotElapsed.selector, expectedNextAt));
        vm.prank(user);
        faucet.claim(address(token));
    }

    function test_claim_afterCooldown_succeeds() public {
        vm.prank(user);
        faucet.claim(address(token));

        vm.warp(block.timestamp + CLAIM_COOLDOWN);

        vm.prank(user);
        faucet.claim(address(token));

        assertEq(token.balanceOf(user), CLAIM_AMOUNT * 2, "user got two claims after cooldown");
    }

    function test_claim_unregisteredToken_reverts() public {
        MockMintableERC20 strayToken = new MockMintableERC20("Stray", "STR", 18, tokenOwner);

        vm.expectRevert(
            abi.encodeWithSelector(Faucet.TokenNotEnabled.selector, address(strayToken))
        );
        vm.prank(user);
        faucet.claim(address(strayToken));
    }

    function test_claim_insufficientBalance_reverts() public {
        // Deploy a fresh faucet + token pair where the faucet has a tiny pool.
        Faucet smallFaucet = new Faucet(owner);
        MockMintableERC20 smallPoolToken = new MockMintableERC20("Small", "SML", 6, tokenOwner);

        uint256 required = CLAIM_AMOUNT;
        uint256 tinyPool = required - 1; // one wei short
        vm.prank(tokenOwner);
        smallPoolToken.mint(tinyPool, address(smallFaucet));

        vm.prank(owner);
        smallFaucet.addToken(address(smallPoolToken), CLAIM_AMOUNT, CLAIM_COOLDOWN);

        vm.expectRevert(
            abi.encodeWithSelector(
                Faucet.InsufficientFaucetBalance.selector,
                address(smallPoolToken),
                tinyPool,
                required
            )
        );
        vm.prank(user);
        smallFaucet.claim(address(smallPoolToken));
    }
}
