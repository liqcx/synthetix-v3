// SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Faucet} from "../src/Faucet.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";

contract FaucetTest is Test {
    event TokenAdded(address indexed token, uint128 claimAmount, uint64 claimCooldown);
    event TokenEnabledSet(address indexed token, bool enabled);
    event ClaimAmountUpdated(address indexed token, uint128 oldAmount, uint128 newAmount);
    event ClaimCooldownUpdated(address indexed token, uint64 oldCooldown, uint64 newCooldown);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

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

    function test_addToken_twice_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(Faucet.TokenAlreadyRegistered.selector, address(token))
        );
        vm.prank(owner);
        faucet.addToken(address(token), CLAIM_AMOUNT, CLAIM_COOLDOWN);
    }

    function test_addToken_emitsTokenAdded() public {
        MockMintableERC20 newToken = new MockMintableERC20("New", "NEW", 18, tokenOwner);

        vm.expectEmit(true, false, false, true);
        emit TokenAdded(address(newToken), 123, 456);

        vm.prank(owner);
        faucet.addToken(address(newToken), 123, 456);
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

    function test_setEnabled_togglesClaimAvailability() public {
        vm.prank(owner);
        faucet.setEnabled(address(token), false);

        vm.expectRevert(abi.encodeWithSelector(Faucet.TokenNotEnabled.selector, address(token)));
        vm.prank(user);
        faucet.claim(address(token));

        vm.prank(owner);
        faucet.setEnabled(address(token), true);

        vm.prank(user);
        faucet.claim(address(token));
        assertEq(token.balanceOf(user), CLAIM_AMOUNT);
    }

    function test_setEnabled_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit TokenEnabledSet(address(token), false);

        vm.prank(owner);
        faucet.setEnabled(address(token), false);
    }

    function test_setEnabled_onlyOwner() public {
        vm.expectRevert();
        vm.prank(user);
        faucet.setEnabled(address(token), false);
    }

    function test_setClaimAmount_takesEffectOnNextClaim() public {
        uint128 newAmount = 999 * 10 ** 6;

        vm.expectEmit(true, false, false, true);
        emit ClaimAmountUpdated(address(token), CLAIM_AMOUNT, newAmount);

        vm.prank(owner);
        faucet.setClaimAmount(address(token), newAmount);

        vm.prank(user);
        faucet.claim(address(token));

        assertEq(token.balanceOf(user), newAmount);
    }

    function test_setClaimCooldown_takesEffectOnNextClaim() public {
        uint64 newCooldown = 12 hours;

        vm.expectEmit(true, false, false, true);
        emit ClaimCooldownUpdated(address(token), CLAIM_COOLDOWN, newCooldown);

        vm.prank(owner);
        faucet.setClaimCooldown(address(token), newCooldown);

        vm.prank(user);
        faucet.claim(address(token));

        // 12 hours later, the second claim should work.
        vm.warp(block.timestamp + newCooldown);
        vm.prank(user);
        faucet.claim(address(token));
        assertEq(token.balanceOf(user), CLAIM_AMOUNT * 2);
    }

    function test_setClaimAmount_onlyOwner() public {
        vm.expectRevert();
        vm.prank(user);
        faucet.setClaimAmount(address(token), 1);
    }

    function test_setClaimCooldown_onlyOwner() public {
        vm.expectRevert();
        vm.prank(user);
        faucet.setClaimCooldown(address(token), 1);
    }

    function test_withdraw_transfersBalanceToRecipient() public {
        address recipient = address(0xDEAD);
        uint256 amount = 1_000 * 10 ** 6;
        uint256 recipientBefore = token.balanceOf(recipient);
        uint256 faucetBefore = token.balanceOf(address(faucet));

        vm.expectEmit(true, true, false, true);
        emit Withdrawn(address(token), recipient, amount);

        vm.prank(owner);
        faucet.withdraw(address(token), recipient, amount);

        assertEq(token.balanceOf(recipient), recipientBefore + amount);
        assertEq(token.balanceOf(address(faucet)), faucetBefore - amount);
    }

    function test_withdraw_onlyOwner() public {
        vm.expectRevert();
        vm.prank(user);
        faucet.withdraw(address(token), user, 1);
    }
}
