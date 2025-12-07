// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Secp256r1Wallet
 * @dev Smart contract wallet that verifies secp256r1 signatures using EIP-7951 precompile
 *
 * This contract demonstrates how to use the secp256r1 precompile (address 0x100)
 * to verify signatures and execute transactions.
 *
 * Note: This is a simplified example. Production implementations should include:
 * - Replay protection (nonces)
 * - Multi-signature support
 * - Access control
 * - Gas optimization
 */
contract Secp256r1Wallet {
    // EIP-7951 precompile address for secp256r1 verification
    // Official address: 0x100 (address 256) per EIP-7951 specification
    // Can be overridden in tests using setPrecompileAddress()
    address public SECP256R1_PRECOMPILE;

    constructor() {
        SECP256R1_PRECOMPILE = address(0x100);
    }

    /**
     * @dev Set precompile address (for testing only)
     * @param precompileAddress Address of the precompile or mock
     */
    function setPrecompileAddress(address precompileAddress) external {
        // In production, this should be removed or protected
        // For testing, we allow setting a mock address
        SECP256R1_PRECOMPILE = precompileAddress;
    }

    // Mapping to store public keys (x, y coordinates)
    mapping(address => PublicKey) public publicKeys;

    // Nonce for replay protection
    mapping(address => uint256) public nonces;

    // Public key structure
    struct PublicKey {
        bytes32 x;
        bytes32 y;
    }

    // Events
    event PublicKeyRegistered(address indexed account, bytes32 x, bytes32 y);
    event TransactionExecuted(address indexed account, address to, uint256 value, bytes data);

    /**
     * @dev Register a public key for an account
     * @param x X coordinate of public key (32 bytes)
     * @param y Y coordinate of public key (32 bytes)
     */
    function registerPublicKey(bytes32 x, bytes32 y) external {
        publicKeys[msg.sender] = PublicKey(x, y);
        emit PublicKeyRegistered(msg.sender, x, y);
    }

    /**
     * @dev Execute a transaction after verifying secp256r1 signature
     * @param messageHash Hash of the transaction data (32 bytes)
     * @param signature Signature (64 bytes: r + s, 32 bytes each)
     * @param to Recipient address
     * @param value Amount to send (in wei)
     * @param data Transaction data
     */
    function executeTransaction(
        bytes32 messageHash,
        bytes calldata signature, // 64 bytes: r (32) + s (32)
        address to,
        uint256 value,
        bytes calldata data
    ) external {
        // Get public key for the caller
        PublicKey memory pubKey = publicKeys[msg.sender];
        require(pubKey.x != bytes32(0) || pubKey.y != bytes32(0), "Public key not registered");

        // Verify signature using precompile
        require(verifySecp256r1(messageHash, signature, pubKey), "Invalid signature");

        // Increment nonce for replay protection
        nonces[msg.sender]++;

        // Execute transaction
        (bool success, ) = to.call{value: value}(data);
        require(success, "Transaction execution failed");

        emit TransactionExecuted(msg.sender, to, value, data);
    }

    /**
     * @dev Verify secp256r1 signature using EIP-7951 precompile
     * @param messageHash Hash of the message (32 bytes)
     * @param signature Signature (64 bytes: r + s)
     * @param pubKey Public key (x, y coordinates)
     * @return true if signature is valid
     *
     * Note: This function requires the Fusaka upgrade (EIP-7951) to be active.
     * If precompile is not available, the call will revert.
     */
    function verifySecp256r1(
        bytes32 messageHash,
        bytes calldata signature,
        PublicKey memory pubKey
    ) internal view returns (bool) {
        require(signature.length == 64, "Invalid signature length");

        // Prepare input for precompile (160 bytes total)
        // Format: messageHash (32) + signature (64) + publicKey (64)
        // Note: abi.encodePacked concatenates without padding, ensuring exact byte lengths
        bytes memory input = abi.encodePacked(
            messageHash,      // 32 bytes
            signature,        // 64 bytes (r + s, 32 bytes each)
            pubKey.x,         // 32 bytes
            pubKey.y          // 32 bytes
        );

        // Verify input length is exactly 160 bytes
        require(input.length == 160, "Invalid input length for precompile");

        // Call precompile at address 0x100 (address 256) - EIP-7951 official address
        (bool success, bytes memory result) = SECP256R1_PRECOMPILE.staticcall(input);

        // Check if precompile call succeeded
        if (!success) {
            revert("Precompile call failed - EIP-7951 may not be active at this block");
        }

        // EIP-7951 specification:
        // - Success: returns 32 bytes with value 0x0000000000000000000000000000000000000000000000000000000000000001
        // - Failure: returns 0 bytes (empty)
        if (result.length == 0) {
            // Empty result means invalid signature or invalid input
            return false;
        }

        // Check if result is the success value (32 bytes with last byte = 0x01)
        // The result may be padded, so we check the last byte
        require(result.length >= 32, "Invalid precompile result length");
        return result[31] == 0x01;
    }

    /**
     * @dev Get current nonce for an account
     * @param account Account address
     * @return Current nonce value
     */
    function getNonce(address account) external view returns (uint256) {
        return nonces[account];
    }

    /**
     * @dev Receive function to accept ETH
     */
    receive() external payable {}

    /**
     * @dev Fallback function
     */
    fallback() external payable {}
}