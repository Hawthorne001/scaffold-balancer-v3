// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {
    LiquidityManagement,
    PoolRoleAccounts,
    TokenConfig
} from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IVaultAdmin } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultAdmin.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ArrayHelpers.sol";
import { InputHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/InputHelpers.sol";
import { BaseVaultTest } from "@test/vault/test/foundry/utils/BaseVaultTest.sol";

import { ConstantSumPool } from "../contracts/pools/ConstantSumPool.sol";
import { ConstantSumFactory } from "../contracts/pools/ConstantSumFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @dev This test roughly mirrors how weighted pools are tested within BalancerV3 monorepo
 */
contract ConstantSumPoolTest is BaseVaultTest {
    using ArrayHelpers for *;

    uint256 constant DEFAULT_SWAP_FEE = 1e16; // 1%

    ConstantSumFactory factory;
    ConstantSumPool internal constantSumPool;

    uint256 constant USDC_AMOUNT = 1e3 * 1e18;
    uint256 constant DAI_AMOUNT = 1e3 * 1e18;

    uint256 constant DAI_AMOUNT_IN = 1 * 1e18;
    uint256 constant USDC_AMOUNT_OUT = 1 * 1e18;

    uint256 constant DELTA = 1e9;

    uint256 internal bptAmountOut;

    function setUp() public virtual override {
        BaseVaultTest.setUp();
        constantSumPool = ConstantSumPool(pool);
    }

    function _createPool(address[] memory tokens, string memory label) internal override returns (address) {
        factory = new ConstantSumFactory(IVault(address(vault)), 365 days);
        bool protocolFeeExempt = false;
        PoolRoleAccounts memory roleAccounts;
        address poolHooksContract = address(0);
        LiquidityManagement memory liquidityManagement;

        ConstantSumPool newPool = ConstantSumPool(
            factory.create(
                "Constant Sum Pool", // name
                "CSP", // symbol
                ZERO_BYTES32, // salt
                vault.buildTokenConfig(tokens.asIERC20()), // TokenConfig[]
                DEFAULT_SWAP_FEE, // swapFeePercentage
                protocolFeeExempt,
                roleAccounts,
                poolHooksContract,
                liquidityManagement
            )
        );
        return address(newPool);
    }

    function initPool() internal override {
        vm.startPrank(lp);
        bptAmountOut = _initPool(
            pool,
            [uint256(DAI_AMOUNT), uint256(USDC_AMOUNT)].toMemoryArray(),
            // Account for the precision loss
            DAI_AMOUNT - DELTA
        );
        vm.stopPrank();
    }

    function testPoolAddress() public view {
        address calculatedPoolAddress = factory.getDeploymentAddress(ZERO_BYTES32);
        assertEq(address(constantSumPool), calculatedPoolAddress);
    }

    function testPoolPausedState() public view {
        (bool paused, uint256 pauseWindow, uint256 bufferPeriod, address pauseManager) = vault.getPoolPausedState(
            address(pool)
        );

        assertFalse(paused, "Vault should not be paused initially");
        assertApproxEqAbs(pauseWindow, START_TIMESTAMP + 365 days, 1, "Pause window period mismatch");
        assertApproxEqAbs(bufferPeriod, START_TIMESTAMP + 365 days + 30 days, 1, "Pause buffer period mismatch");
        assertEq(pauseManager, address(0), "Pause manager should be 0");
    }

    function testInitialize() public view {
        // Tokens are transferred from lp
        assertEq(defaultBalance - usdc.balanceOf(lp), USDC_AMOUNT, "LP: Wrong USDC balance");
        assertEq(defaultBalance - dai.balanceOf(lp), DAI_AMOUNT, "LP: Wrong DAI balance");

        // Tokens are stored in the Vault
        assertEq(usdc.balanceOf(address(vault)), USDC_AMOUNT, "Vault: Wrong USDC balance");
        assertEq(dai.balanceOf(address(vault)), DAI_AMOUNT, "Vault: Wrong DAI balance");

        // Tokens are deposited to the pool
        (, , uint256[] memory balances, ) = vault.getPoolTokenInfo(address(pool));
        assertEq(balances[0], DAI_AMOUNT, "Pool: Wrong DAI balance");
        assertEq(balances[1], USDC_AMOUNT, "Pool: Wrong USDC balance");

        // should mint correct amount of BPT tokens
        // Account for the precision loss
        assertApproxEqAbs(constantSumPool.balanceOf(lp), bptAmountOut, DELTA, "LP: Wrong bptAmountOut");
        assertApproxEqAbs(bptAmountOut, 2 * DAI_AMOUNT, DELTA, "Wrong bptAmountOut");
    }

    function testAddLiquidity() public {
        uint256[] memory amountsIn = [uint256(DAI_AMOUNT), uint256(USDC_AMOUNT)].toMemoryArray();
        vm.prank(bob);
        bptAmountOut = router.addLiquidityUnbalanced(address(pool), amountsIn, DAI_AMOUNT - DELTA, false, bytes(""));

        // Tokens are transferred from Bob
        assertEq(defaultBalance - usdc.balanceOf(bob), USDC_AMOUNT, "LP: Wrong USDC balance");
        assertEq(defaultBalance - dai.balanceOf(bob), DAI_AMOUNT, "LP: Wrong DAI balance");

        // Tokens are stored in the Vault
        assertEq(usdc.balanceOf(address(vault)), USDC_AMOUNT * 2, "Vault: Wrong USDC balance");
        assertEq(dai.balanceOf(address(vault)), DAI_AMOUNT * 2, "Vault: Wrong DAI balance");

        // Tokens are deposited to the pool
        (, , uint256[] memory balances, ) = vault.getPoolTokenInfo(address(pool));
        assertEq(balances[0], DAI_AMOUNT * 2, "Pool: Wrong DAI balance");
        assertEq(balances[1], USDC_AMOUNT * 2, "Pool: Wrong USDC balance");

        // should mint correct amount of BPT tokens
        assertApproxEqAbs(constantSumPool.balanceOf(bob), bptAmountOut, DELTA, "LP: Wrong bptAmountOut");
        assertApproxEqAbs(bptAmountOut, 2 * DAI_AMOUNT, DELTA, "Wrong bptAmountOut");
    }

    function testRemoveLiquidity() public {
        vm.startPrank(bob);
        router.addLiquidityUnbalanced(
            address(pool),
            [uint256(DAI_AMOUNT), uint256(USDC_AMOUNT)].toMemoryArray(),
            DAI_AMOUNT - DELTA,
            false,
            bytes("")
        );

        constantSumPool.approve(address(vault), type(uint256).max);

        uint256 bobBptBalance = constantSumPool.balanceOf(bob);
        uint256 bptAmountIn = bobBptBalance;

        uint256[] memory amountsOut = router.removeLiquidityProportional(
            address(pool),
            bptAmountIn,
            [uint256(less(DAI_AMOUNT, 1e4)), uint256(less(USDC_AMOUNT, 1e4))].toMemoryArray(),
            false,
            bytes("")
        );

        vm.stopPrank();

        // Tokens are transferred to Bob
        assertApproxEqAbs(usdc.balanceOf(bob), defaultBalance, DELTA, "LP: Wrong USDC balance");
        assertApproxEqAbs(dai.balanceOf(bob), defaultBalance, DELTA, "LP: Wrong DAI balance");

        // Tokens are stored in the Vault
        assertApproxEqAbs(usdc.balanceOf(address(vault)), USDC_AMOUNT, DELTA, "Vault: Wrong USDC balance");
        assertApproxEqAbs(dai.balanceOf(address(vault)), DAI_AMOUNT, DELTA, "Vault: Wrong DAI balance");

        // Tokens are deposited to the pool
        (, , uint256[] memory balances, ) = vault.getPoolTokenInfo(address(pool));
        assertApproxEqAbs(balances[0], DAI_AMOUNT, DELTA, "Pool: Wrong DAI balance");
        assertApproxEqAbs(balances[1], USDC_AMOUNT, DELTA, "Pool: Wrong USDC balance");

        // amountsOut are correct
        assertApproxEqAbs(amountsOut[0], DAI_AMOUNT, DELTA, "Wrong DAI AmountOut");
        assertApproxEqAbs(amountsOut[1], USDC_AMOUNT, DELTA, "Wrong USDC AmountOut");

        // should mint correct amount of BPT tokens
        assertEq(constantSumPool.balanceOf(bob), 0, "LP: Wrong BPT balance");
        assertEq(bobBptBalance, bptAmountIn, "LP: Wrong bptAmountIn");
    }

    function testSwap() public {
        // Set swap fee to zero for this test.
        vault.manuallySetSwapFee(pool, 0);

        vm.prank(bob);
        uint256 amountCalculated = router.swapSingleTokenExactIn(
            address(pool),
            dai,
            usdc,
            DAI_AMOUNT_IN,
            less(USDC_AMOUNT_OUT, 1e3),
            type(uint256).max,
            false,
            bytes("")
        );

        // Tokens are transferred from Bob
        assertEq(usdc.balanceOf(bob), defaultBalance + amountCalculated, "LP: Wrong USDC balance");
        assertEq(dai.balanceOf(bob), defaultBalance - DAI_AMOUNT_IN, "LP: Wrong DAI balance");

        // Tokens are stored in the Vault
        assertEq(usdc.balanceOf(address(vault)), USDC_AMOUNT - amountCalculated, "Vault: Wrong USDC balance");
        assertEq(dai.balanceOf(address(vault)), DAI_AMOUNT + DAI_AMOUNT_IN, "Vault: Wrong DAI balance");

        (, , uint256[] memory balances, ) = vault.getPoolTokenInfo(address(pool));

        (uint256 daiIdx, uint256 usdcIdx) = getSortedIndexes(address(dai), address(usdc));

        assertEq(balances[daiIdx], DAI_AMOUNT + DAI_AMOUNT_IN, "Pool: Wrong DAI balance");
        assertEq(balances[usdcIdx], USDC_AMOUNT - amountCalculated, "Pool: Wrong USDC balance");
    }

    function testAddLiquidityUnbalanced() public {
        authorizer.grantRole(vault.getActionId(IVaultAdmin.setStaticSwapFeePercentage.selector), alice);
        vm.prank(alice);
        vault.setStaticSwapFeePercentage(address(pool), 10e16);

        uint256[] memory amountsIn = [uint256(1e2 * 1e18), uint256(USDC_AMOUNT)].toMemoryArray();
        vm.prank(bob);

        router.addLiquidityUnbalanced(address(pool), amountsIn, 0, false, bytes(""));
    }

    function testMinimumSwapFee() public view {
        assertEq(constantSumPool.getMinimumSwapFeePercentage(), MIN_SWAP_FEE, "Minimum swap fee mismatch");
    }

    function testMaximumSwapFee() public view {
        assertEq(constantSumPool.getMaximumSwapFeePercentage(), MAX_SWAP_FEE, "Maximum swap fee mismatch");
    }

    function testFailSwapFeeTooLow() public {
        TokenConfig[] memory tokens = new TokenConfig[](2);
        PoolRoleAccounts memory roleAccounts;
        LiquidityManagement memory liquidityManagement;
        tokens[0].token = IERC20(dai);
        tokens[1].token = IERC20(usdc);

        address lowFeeWeightedPool = factory.create(
            "Constant Sum Pool",
            "CSP",
            ZERO_BYTES32,
            tokens,
            MIN_SWAP_FEE - 1, // Swap fee too low
            false, // protocolFeeExempt
            roleAccounts,
            address(0), // poolHooksContract
            liquidityManagement
        );

        factoryMock.registerTestPool(lowFeeWeightedPool, tokens);
    }

    function testSetSwapFeeTooLow() public {
        authorizer.grantRole(vault.getActionId(IVaultAdmin.setStaticSwapFeePercentage.selector), alice);
        vm.prank(alice);

        vm.expectRevert(IVaultErrors.SwapFeePercentageTooLow.selector);
        vault.setStaticSwapFeePercentage(address(pool), MIN_SWAP_FEE - 1);
    }

    function testSetSwapFeeTooHigh() public {
        authorizer.grantRole(vault.getActionId(IVaultAdmin.setStaticSwapFeePercentage.selector), alice);
        vm.prank(alice);

        vm.expectRevert(IVaultErrors.SwapFeePercentageTooHigh.selector);
        vault.setStaticSwapFeePercentage(address(pool), MAX_SWAP_FEE + 1);
    }

    // Helper Functions
    function less(uint256 amount, uint256 base) internal pure returns (uint256) {
        return (amount * (base - 1)) / base;
    }
}
