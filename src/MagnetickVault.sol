// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

import {MagnetickHook} from "./MagnetickHook.sol";

/// @title MagnetickVault
/// @notice A vault that manages liquidity positions in Uniswap V4 pools with auto-rebalancing via MagnetickHook.
/// @dev Users deposit token pairs and receive vault shares. The vault manages concentrated liquidity positions.
contract MagnetickVault is ERC20, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using SafeTransferLib for ERC20;

    /// @notice The Uniswap V4 pool manager.
    IPoolManager public immutable poolManager;

    /// @notice The Magnetick hook contract.
    MagnetickHook public immutable hook;

    /// @notice The pool key for this vault's managed pool.
    PoolKey public poolKey;

    /// @notice The pool ID derived from the pool key.
    PoolId public poolId;

    /// @notice Total liquidity managed by this vault.
    uint128 public totalLiquidity;

    /// @notice Callback action types.
    enum CallbackAction {
        AddLiquidity,
        RemoveLiquidity
    }

    /// @notice Data passed to unlock callback.
    struct CallbackData {
        CallbackAction action;
        address sender;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint128 liquidityDelta;
    }

    /// @notice Emitted when liquidity is deposited.
    /// @param depositor The address that deposited.
    /// @param shares The number of shares minted.
    /// @param amount0 The amount of token0 deposited.
    /// @param amount1 The amount of token1 deposited.
    event Deposit(address indexed depositor, uint256 shares, uint256 amount0, uint256 amount1);

    /// @notice Emitted when liquidity is withdrawn.
    /// @param withdrawer The address that withdrew.
    /// @param shares The number of shares burned.
    /// @param amount0 The amount of token0 withdrawn.
    /// @param amount1 The amount of token1 withdrawn.
    event Withdraw(address indexed withdrawer, uint256 shares, uint256 amount0, uint256 amount1);

    /// @notice Thrown when caller is not the pool manager.
    error NotPoolManager();

    /// @notice Thrown when trying to deposit zero amounts.
    error ZeroDeposit();

    /// @notice Thrown when trying to withdraw more shares than owned.
    error InsufficientShares();

    /// @notice Thrown when slippage check fails.
    error SlippageExceeded();

    /// @notice Modifier to restrict function access to only the pool manager.
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @notice Creates a new MagnetickVault.
    /// @param _poolManager The Uniswap V4 pool manager.
    /// @param _hook The Magnetick hook contract.
    /// @param _poolKey The pool key for the managed pool.
    constructor(IPoolManager _poolManager, MagnetickHook _hook, PoolKey memory _poolKey)
        ERC20("Magnetick LP Token", "mLP", 18)
    {
        poolManager = _poolManager;
        hook = _hook;
        poolKey = _poolKey;
        poolId = _poolKey.toId();

        // Approve hook to manage our position.
        hook.setVault(address(this));
    }

    /// @notice Deposits tokens into the vault and receives shares.
    /// @param amount0Desired The desired amount of token0 to deposit.
    /// @param amount1Desired The desired amount of token1 to deposit.
    /// @param amount0Min Minimum amount of token0 (slippage protection).
    /// @param amount1Min Minimum amount of token1 (slippage protection).
    /// @return shares The number of shares minted.
    /// @return amount0 The actual amount of token0 deposited.
    /// @return amount1 The actual amount of token1 deposited.
    function deposit(uint256 amount0Desired, uint256 amount1Desired, uint256 amount0Min, uint256 amount1Min)
        external
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        if (amount0Desired == 0 && amount1Desired == 0) revert ZeroDeposit();

        // Get current tick range from hook.
        (int24 tickLower, int24 tickUpper,) = hook.getPositionInfo(poolId);

        // Get current sqrt price.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        // Calculate liquidity from desired amounts.
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );

        // Execute deposit via unlock callback.
        bytes memory result = poolManager.unlock(
            abi.encode(
                CallbackData({
                    action: CallbackAction.AddLiquidity,
                    sender: msg.sender,
                    amount0Desired: amount0Desired,
                    amount1Desired: amount1Desired,
                    liquidityDelta: liquidityDelta
                })
            )
        );

        (amount0, amount1) = abi.decode(result, (uint256, uint256));

        // Slippage check.
        if (amount0 < amount0Min || amount1 < amount1Min) revert SlippageExceeded();

        // Calculate shares to mint.
        if (totalSupply == 0) {
            shares = liquidityDelta;
        } else {
            shares = (uint256(liquidityDelta) * totalSupply) / totalLiquidity;
        }

        // Update state.
        totalLiquidity += liquidityDelta;

        // Mint shares to depositor.
        _mint(msg.sender, shares);

        emit Deposit(msg.sender, shares, amount0, amount1);
    }

    /// @notice Withdraws tokens from the vault by burning shares.
    /// @param shares The number of shares to burn.
    /// @param amount0Min Minimum amount of token0 to receive (slippage protection).
    /// @param amount1Min Minimum amount of token1 to receive (slippage protection).
    /// @return amount0 The amount of token0 received.
    /// @return amount1 The amount of token1 received.
    function withdraw(uint256 shares, uint256 amount0Min, uint256 amount1Min)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares > balanceOf[msg.sender]) revert InsufficientShares();

        // Calculate liquidity to remove.
        uint128 liquidityDelta = uint128((shares * totalLiquidity) / totalSupply);

        // Execute withdrawal via unlock callback.
        bytes memory result = poolManager.unlock(
            abi.encode(
                CallbackData({
                    action: CallbackAction.RemoveLiquidity,
                    sender: msg.sender,
                    amount0Desired: 0,
                    amount1Desired: 0,
                    liquidityDelta: liquidityDelta
                })
            )
        );

        (amount0, amount1) = abi.decode(result, (uint256, uint256));

        // Slippage check.
        if (amount0 < amount0Min || amount1 < amount1Min) revert SlippageExceeded();

        // Update state.
        totalLiquidity -= liquidityDelta;

        // Burn shares.
        _burn(msg.sender, shares);

        emit Withdraw(msg.sender, shares, amount0, amount1);
    }

    /// @notice Callback from PoolManager.unlock().
    /// @param data Encoded CallbackData.
    /// @return Encoded result (amount0, amount1).
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        CallbackData memory cbData = abi.decode(data, (CallbackData));

        if (cbData.action == CallbackAction.AddLiquidity) {
            return _addLiquidity(cbData);
        } else {
            return _removeLiquidity(cbData);
        }
    }

    /// @notice Internal function to add liquidity.
    /// @param cbData The callback data.
    /// @return Encoded (amount0, amount1).
    function _addLiquidity(CallbackData memory cbData) internal returns (bytes memory) {
        // Get current tick range from hook.
        (int24 tickLower, int24 tickUpper) = hook.getTickRange(poolId);

        // Add liquidity directly to the pool.
        poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(cbData.liquidityDelta)),
                salt: bytes32(0)
            }),
            ""
        );

        // Update hook's tracked liquidity.
        hook.updateTrackedLiquidity(poolId, int256(uint256(cbData.liquidityDelta)));

        // Get deltas.
        int256 delta0 = poolManager.currencyDelta(address(this), poolKey.currency0);
        int256 delta1 = poolManager.currencyDelta(address(this), poolKey.currency1);

        // Settle debts (negative deltas mean we owe tokens).
        uint256 amount0 = 0;
        uint256 amount1 = 0;

        if (delta0 < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            amount0 = uint256(-delta0);
            _settle(poolKey.currency0, cbData.sender, amount0);
        }
        if (delta1 < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            amount1 = uint256(-delta1);
            _settle(poolKey.currency1, cbData.sender, amount1);
        }

        return abi.encode(amount0, amount1);
    }

    /// @notice Internal function to remove liquidity.
    /// @param cbData The callback data.
    /// @return Encoded (amount0, amount1).
    function _removeLiquidity(CallbackData memory cbData) internal returns (bytes memory) {
        // Get current tick range from hook.
        (int24 tickLower, int24 tickUpper) = hook.getTickRange(poolId);

        // Remove liquidity directly from the pool.
        poolManager.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(cbData.liquidityDelta)),
                salt: bytes32(0)
            }),
            ""
        );

        // Update hook's tracked liquidity.
        hook.updateTrackedLiquidity(poolId, -int256(uint256(cbData.liquidityDelta)));

        // Get deltas.
        int256 delta0 = poolManager.currencyDelta(address(this), poolKey.currency0);
        int256 delta1 = poolManager.currencyDelta(address(this), poolKey.currency1);

        // Take credits (positive deltas mean we receive tokens).
        uint256 amount0 = 0;
        uint256 amount1 = 0;

        if (delta0 > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            amount0 = uint256(delta0);
            _take(poolKey.currency0, cbData.sender, amount0);
        }
        if (delta1 > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            amount1 = uint256(delta1);
            _take(poolKey.currency1, cbData.sender, amount1);
        }

        return abi.encode(amount0, amount1);
    }

    /// @notice Settle a currency debt to the pool manager.
    /// @param currency The currency to settle.
    /// @param payer The address paying the debt.
    /// @param amount The amount to settle.
    function _settle(Currency currency, address payer, uint256 amount) internal {
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            ERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(poolManager), amount);
            poolManager.settle();
        }
    }

    /// @notice Take a currency credit from the pool manager.
    /// @param currency The currency to take.
    /// @param recipient The address receiving the credit.
    /// @param amount The amount to take.
    function _take(Currency currency, address recipient, uint256 amount) internal {
        poolManager.take(currency, recipient, amount);
    }

    /// @notice Get the current position information.
    /// @return tickLower The lower tick of the position.
    /// @return tickUpper The upper tick of the position.
    /// @return liquidity The current liquidity.
    function getPositionInfo() external view returns (int24 tickLower, int24 tickUpper, uint128 liquidity) {
        return hook.getPositionInfo(poolId);
    }

    /// @notice Calculate shares for a given deposit.
    /// @param amount0 The amount of token0.
    /// @param amount1 The amount of token1.
    /// @return shares The estimated shares.
    function previewDeposit(uint256 amount0, uint256 amount1) external view returns (uint256 shares) {
        (int24 tickLower, int24 tickUpper,) = hook.getPositionInfo(poolId);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);

        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        if (totalSupply == 0) {
            shares = liquidityDelta;
        } else {
            shares = (uint256(liquidityDelta) * totalSupply) / totalLiquidity;
        }
    }

    /// @notice Get token0 address.
    /// @return The token0 address.
    function token0() external view returns (address) {
        return Currency.unwrap(poolKey.currency0);
    }

    /// @notice Get token1 address.
    /// @return The token1 address.
    function token1() external view returns (address) {
        return Currency.unwrap(poolKey.currency1);
    }
}

