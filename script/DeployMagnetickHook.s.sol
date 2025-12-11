// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {MagnetickHook} from "../src/MagnetickHook.sol";

/// @title Deploy Magnetick Hook
/// @notice Script to deploy the MagnetickHook contract.
contract DeployMagnetickHook is Script {
    /// @notice The flags required for the MagnetickHook.
    uint160 public constant HOOK_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);

    function run() public {
        // Load configuration from environment.
        address poolManager = vm.envAddress("POOL_MANAGER");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("Deploying MagnetickHook...");
        console.log("Pool Manager:", poolManager);

        vm.startBroadcast(deployerPrivateKey);

        // Note: In production, you need to find a salt that creates an address with the correct hook flags.
        // For now, we deploy directly and the constructor will validate the address.
        // Use CREATE2 with a mining script to find the correct salt.

        // This deployment will fail if the address doesn't have correct flags.
        // Use HookMiner or similar to find the correct salt for CREATE2.
        MagnetickHook hook = new MagnetickHook(IPoolManager(poolManager));

        console.log("MagnetickHook deployed at:", address(hook));
        console.log("Hook flags:", uint160(address(hook)) & ((1 << 14) - 1));

        vm.stopBroadcast();
    }

    /// @notice Compute the expected hook address for a given salt.
    /// @param deployer The deployer address.
    /// @param poolManager The pool manager address.
    /// @param salt The CREATE2 salt.
    /// @return The expected hook address.
    function computeAddress(address deployer, address poolManager, bytes32 salt) public pure returns (address) {
        bytes memory bytecode = abi.encodePacked(type(MagnetickHook).creationCode, abi.encode(poolManager));
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(bytecode)));
        return address(uint160(uint256(hash)));
    }

    /// @notice Mine for a salt that produces an address with the correct hook flags.
    /// @dev This is a helper function to find the correct salt for deployment.
    /// @param deployer The deployer address.
    /// @param poolManager The pool manager address.
    /// @param startSalt The starting salt value.
    /// @param iterations The number of iterations to try.
    /// @return salt The salt that produces a valid address, or bytes32(0) if not found.
    /// @return hookAddress The address that would be created.
    function mineSalt(address deployer, address poolManager, uint256 startSalt, uint256 iterations)
        public
        pure
        returns (bytes32 salt, address hookAddress)
    {
        for (uint256 i = 0; i < iterations; i++) {
            salt = bytes32(startSalt + i);
            hookAddress = computeAddress(deployer, poolManager, salt);

            // Check if address has correct flags.
            uint160 flags = uint160(hookAddress) & ((1 << 14) - 1);
            if (flags == HOOK_FLAGS) {
                return (salt, hookAddress);
            }
        }

        return (bytes32(0), address(0));
    }
}

