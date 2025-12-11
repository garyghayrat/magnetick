// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";

/// @title MagnetickHook
/// @notice A Uniswap V4 hook that automatically rebalances liquidity positions when price moves out of range.
/// @dev This hook monitors the current tick in afterSwap and triggers rebalancing when the position is out of range.
contract MagnetickHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for int256;
    using SafeCast for uint256;

    /// @notice Configuration for a pool's managed position.
    struct PoolConfig {
        int24 tickLower;
        int24 tickUpper;
        int24 tickWidth;
        uint128 liquidity;
        bool initialized;
    }

    /// @notice Emitted when a position is rebalanced to a new tick range.
    /// @param poolId The ID of the pool.
    /// @param oldTickLower The previous lower tick.
    /// @param oldTickUpper The previous upper tick.
    /// @param newTickLower The new lower tick.
    /// @param newTickUpper The new upper tick.
    event PositionRebalanced(
        PoolId indexed poolId, int24 oldTickLower, int24 oldTickUpper, int24 newTickLower, int24 newTickUpper
    );

    /// @notice Emitted when a pool is registered with this hook.
    /// @param poolId The ID of the pool.
    /// @param tickWidth The tick width for the position.
    event PoolRegistered(PoolId indexed poolId, int24 tickWidth);

    /// @notice Thrown when trying to operate on a pool that hasn't been registered.
    error PoolNotRegistered();

    /// @notice Thrown when the caller is not the vault.
    error OnlyVault();

    /// @notice Thrown when trying to register a pool that is already registered.
    error PoolAlreadyRegistered();

    /// @notice The default tick width for new positions (100 ticks on each side).
    int24 public constant DEFAULT_TICK_WIDTH = 100;

    /// @notice The vault contract that manages user deposits.
    address public vault;

    /// @notice Pool configuration mapping.
    mapping(PoolId => PoolConfig) public poolConfigs;

    /// @notice Salt for position identification.
    bytes32 public constant POSITION_SALT = bytes32(0);

    /// @notice Restricts function access to only the vault contract.
    modifier onlyVault() {
        _checkVault();
        _;
    }

    /// @notice Internal function to check vault access.
    function _checkVault() internal view {
        if (msg.sender != vault) revert OnlyVault();
    }

    /// @notice Initialize the hook with the pool manager.
    /// @param _poolManager The Uniswap V4 pool manager.
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /// @notice Set the vault address. Can only be set once.
    /// @param _vault The vault contract address.
    function setVault(address _vault) external {
        require(vault == address(0), "Vault already set");
        vault = _vault;
    }

    /// @notice Returns the hook permissions for this contract.
    /// @return Permissions struct indicating which hooks are implemented.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @notice Called after a pool is initialized. Registers the pool with default configuration.
    /// @param key The pool key.
    /// @param tick The initial tick of the pool.
    /// @return The function selector.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        internal
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();

        // Calculate initial tick range centered on the current tick.
        int24 tickSpacing = key.tickSpacing;
        (int24 tickLower, int24 tickUpper) = _calculateTickRange(tick, DEFAULT_TICK_WIDTH, tickSpacing);

        poolConfigs[poolId] = PoolConfig({
            tickLower: tickLower,
            tickUpper: tickUpper,
            tickWidth: DEFAULT_TICK_WIDTH,
            liquidity: 0,
            initialized: true
        });

        emit PoolRegistered(poolId, DEFAULT_TICK_WIDTH);

        return this.afterInitialize.selector;
    }

    /// @notice Called after a swap. Checks if rebalancing is needed and triggers it.
    /// @param key The pool key.
    /// @return The function selector and hook delta (0).
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];

        // Skip if pool not registered or no liquidity to manage.
        if (!config.initialized || config.liquidity == 0) {
            return (this.afterSwap.selector, 0);
        }

        // Get current tick from pool state.
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        // Check if current tick is outside the position range.
        if (currentTick < config.tickLower || currentTick >= config.tickUpper) {
            _rebalancePosition(key, config, currentTick);
        }

        return (this.afterSwap.selector, 0);
    }

    /// @notice Rebalances the position to center it on the current tick.
    /// @param key The pool key.
    /// @param config The pool configuration.
    /// @param currentTick The current tick of the pool.
    function _rebalancePosition(PoolKey calldata key, PoolConfig storage config, int24 currentTick) internal {
        int24 _oldTickLower = config.tickLower;
        int24 _oldTickUpper = config.tickUpper;

        // Remove liquidity from old position.
        if (config.liquidity > 0) {
            poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: _oldTickLower,
                    tickUpper: _oldTickUpper,
                    liquidityDelta: -int256(uint256(config.liquidity)),
                    salt: POSITION_SALT
                }),
                ""
            );
        }

        // Calculate new tick range centered on current tick.
        (int24 newTickLower, int24 newTickUpper) = _calculateTickRange(currentTick, config.tickWidth, key.tickSpacing);

        // Add liquidity to new position.
        if (config.liquidity > 0) {
            poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: newTickLower,
                    tickUpper: newTickUpper,
                    liquidityDelta: int256(uint256(config.liquidity)),
                    salt: POSITION_SALT
                }),
                ""
            );
        }

        // Update config with new range.
        config.tickLower = newTickLower;
        config.tickUpper = newTickUpper;

        emit PositionRebalanced(key.toId(), _oldTickLower, _oldTickUpper, newTickLower, newTickUpper);
    }

    /// @notice Calculates a tick range centered on the given tick, aligned to tick spacing.
    /// @param tick The center tick.
    /// @param tickWidth The number of ticks on each side of center.
    /// @param tickSpacing The pool's tick spacing.
    /// @return tickLower The lower tick of the range.
    /// @return tickUpper The upper tick of the range.
    function _calculateTickRange(int24 tick, int24 tickWidth, int24 tickSpacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        // Round tick down to nearest tick spacing.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 _tickAligned = (tick / tickSpacing) * tickSpacing;

        // Calculate raw tick bounds.
        int24 _rawLower = _tickAligned - (tickWidth * tickSpacing);
        int24 _rawUpper = _tickAligned + (tickWidth * tickSpacing);

        // Clamp to valid tick range.
        tickLower = _rawLower < TickMath.MIN_TICK ? TickMath.MIN_TICK : _rawLower;
        tickUpper = _rawUpper > TickMath.MAX_TICK ? TickMath.MAX_TICK : _rawUpper;

        // Ensure alignment to tick spacing after clamping.
        // forge-lint: disable-next-line(divide-before-multiply)
        tickLower = (tickLower / tickSpacing) * tickSpacing;
        // forge-lint: disable-next-line(divide-before-multiply)
        tickUpper = (tickUpper / tickSpacing) * tickSpacing;
    }

    /// @notice Updates the managed liquidity amount for a pool. Called by the vault.
    /// @param key The pool key.
    /// @param liquidityDelta The change in liquidity (positive to add, negative to remove).
    function updateLiquidity(PoolKey calldata key, int256 liquidityDelta) external onlyVault {
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];

        if (!config.initialized) revert PoolNotRegistered();

        // Modify liquidity in the pool.
        poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: config.tickLower,
                tickUpper: config.tickUpper,
                liquidityDelta: liquidityDelta,
                salt: POSITION_SALT
            }),
            ""
        );

        // Update tracked liquidity using safe casts.
        // Casting to uint256 is safe because we check the sign before casting.
        if (liquidityDelta > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            config.liquidity += uint256(liquidityDelta).toUint128();
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            config.liquidity -= uint256(-liquidityDelta).toUint128();
        }
    }

    /// @notice Updates the tick width for a pool. Called by the vault.
    /// @param key The pool key.
    /// @param newTickWidth The new tick width.
    function setTickWidth(PoolKey calldata key, int24 newTickWidth) external onlyVault {
        PoolId poolId = key.toId();
        PoolConfig storage config = poolConfigs[poolId];

        if (!config.initialized) revert PoolNotRegistered();

        config.tickWidth = newTickWidth;
    }

    /// @notice Gets the current position info for a pool.
    /// @param poolId The pool ID.
    /// @return tickLower The lower tick of the position.
    /// @return tickUpper The upper tick of the position.
    /// @return liquidity The amount of liquidity in the position.
    function getPositionInfo(PoolId poolId)
        external
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        PoolConfig storage config = poolConfigs[poolId];
        return (config.tickLower, config.tickUpper, config.liquidity);
    }

    /// @notice Checks if a pool is registered with this hook.
    /// @param poolId The pool ID.
    /// @return True if the pool is registered.
    function isPoolRegistered(PoolId poolId) external view returns (bool) {
        return poolConfigs[poolId].initialized;
    }
}

