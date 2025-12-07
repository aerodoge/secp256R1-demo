// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TouchIdWallet
 * @notice EIP-7702 compatible smart wallet with WebAuthn (Touch ID) authentication
 * @dev This contract is designed to be delegated to via EIP-7702
 *      Storage lives in the user's EOA address space
 */
contract TouchIdWallet {
    using SafeERC20 for IERC20;

    // EIP-7212 secp256r1 precompile address
    address constant P256_VERIFIER = 0x0000000000000000000000000000000000000100;

    // WebAuthn public key storage (stored in user's address space via EIP-7702)
    bytes32 public webauthnPubKeyX;
    bytes32 public webauthnPubKeyY;

    // Nonce for replay protection
    uint256 public nonce;

    // Events
    event WebAuthnKeySet(bytes32 indexed pubKeyX, bytes32 indexed pubKeyY);
    event ERC20Transferred(
        address indexed token,
        address indexed to,
        uint256 amount
    );

    /**
     * @notice Set the WebAuthn public key for this wallet
     * @dev Can only be called by the wallet itself (address(this))
     * @param pubKeyX The x-coordinate of the secp256r1 public key
     * @param pubKeyY The y-coordinate of the secp256r1 public key
     */
    function setWebauthn(bytes32 pubKeyX, bytes32 pubKeyY) external {
        require(msg.sender == address(this), "Only self can set webauthn key");

        webauthnPubKeyX = pubKeyX;
        webauthnPubKeyY = pubKeyY;

        emit WebAuthnKeySet(pubKeyX, pubKeyY);
    }

    /**
     * @notice Check if WebAuthn key is set
     * @return True if a WebAuthn key has been configured
     */
    function isWebauthnSet() external view returns (bool) {
        return webauthnPubKeyX != bytes32(0) || webauthnPubKeyY != bytes32(0);
    }

    /**
     * @notice Get the current WebAuthn public key
     * @return pubKeyX The x-coordinate
     * @return pubKeyY The y-coordinate
     */
    function getWebauthnKey() external view returns (bytes32 pubKeyX, bytes32 pubKeyY) {
        return (webauthnPubKeyX, webauthnPubKeyY);
    }

    /**
     * @notice Transfer ERC20 tokens using WebAuthn signature
     * @dev WebAuthn signs: SHA-256(authenticatorData || SHA-256(clientDataJSON))
     *      The challenge in clientDataJSON must be keccak256(token, to, amount, nonce)
     * @param token The ERC20 token address
     * @param to The recipient address
     * @param amount The amount to transfer
     * @param r The r component of the signature
     * @param s The s component of the signature
     * @param authenticatorData The authenticator data from WebAuthn
     * @param clientDataJSON The client data JSON from WebAuthn
     */
    function transferERC20(
        address token,
        address to,
        uint256 amount,
        bytes32 r,
        bytes32 s,
        bytes calldata authenticatorData,
        bytes calldata clientDataJSON
    ) external {
        // 1. Check WebAuthn key is set
        require(
            webauthnPubKeyX != bytes32(0) || webauthnPubKeyY != bytes32(0),
            "WebAuthn key not set"
        );

        // 2. Get and increment nonce
        uint256 currentNonce = nonce;
        nonce = currentNonce + 1;

        // 3. Construct the expected challenge
        bytes32 expectedChallenge = keccak256(
            abi.encodePacked(token, to, amount, currentNonce)
        );

        // 4. Verify the challenge is in clientDataJSON
        require(
            _verifyClientDataChallenge(clientDataJSON, expectedChallenge),
            "Invalid challenge"
        );

        // 5. Compute the message that was signed by WebAuthn
        // WebAuthn signs: SHA-256(authenticatorData || SHA-256(clientDataJSON))
        bytes32 clientDataHash = sha256(clientDataJSON);
        bytes32 messageHash = sha256(abi.encodePacked(authenticatorData, clientDataHash));

        // 6. Verify secp256r1 signature
        require(
            _verifyP256Signature(messageHash, r, s, webauthnPubKeyX, webauthnPubKeyY),
            "Invalid signature"
        );

        // 7. Transfer tokens
        IERC20(token).safeTransfer(to, amount);

        emit ERC20Transferred(token, to, amount);
    }

    /**
     * @notice Verify clientDataJSON contains the expected challenge
     * @dev Parses the JSON to find "challenge":"<base64url>" and compares
     * @param clientDataJSON The client data JSON bytes
     * @param expectedChallenge The expected challenge hash
     * @return True if challenge matches
     */
    function _verifyClientDataChallenge(
        bytes calldata clientDataJSON,
        bytes32 expectedChallenge
    ) internal pure returns (bool) {
        // Convert expected challenge to base64url encoding
        bytes memory expectedBase64 = _base64UrlEncode(abi.encodePacked(expectedChallenge));

        // Search for "challenge":" in the JSON
        bytes memory searchKey = bytes('"challenge":"');
        uint256 keyLen = searchKey.length;

        for (uint256 i = 0; i < clientDataJSON.length - keyLen; i++) {
            bool found = true;
            for (uint256 j = 0; j < keyLen; j++) {
                if (clientDataJSON[i + j] != searchKey[j]) {
                    found = false;
                    break;
                }
            }

            if (found) {
                // Found the key, extract value until closing quote
                uint256 valueStart = i + keyLen;
                uint256 valueEnd = valueStart;

                while (valueEnd < clientDataJSON.length && clientDataJSON[valueEnd] != '"') {
                    valueEnd++;
                }

                // Compare lengths first
                if (valueEnd - valueStart != expectedBase64.length) {
                    return false;
                }

                // Compare each character
                for (uint256 k = 0; k < expectedBase64.length; k++) {
                    if (clientDataJSON[valueStart + k] != expectedBase64[k]) {
                        return false;
                    }
                }

                return true;
            }
        }

        return false;
    }

    /**
     * @notice Encode bytes to base64url (no padding)
     * @param data The data to encode
     * @return The base64url encoded bytes
     */
    function _base64UrlEncode(bytes memory data) internal pure returns (bytes memory) {
        bytes memory base64Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

        uint256 resultLen = 4 * ((data.length + 2) / 3);
        bytes memory result = new bytes(resultLen);

        uint256 i = 0;
        uint256 j = 0;

        while (i < data.length) {
            uint256 a = i < data.length ? uint8(data[i++]) : 0;
            uint256 b = i < data.length ? uint8(data[i++]) : 0;
            uint256 c = i < data.length ? uint8(data[i++]) : 0;

            uint256 triple = (a << 16) | (b << 8) | c;

            result[j++] = base64Chars[(triple >> 18) & 0x3F];
            result[j++] = base64Chars[(triple >> 12) & 0x3F];
            result[j++] = base64Chars[(triple >> 6) & 0x3F];
            result[j++] = base64Chars[triple & 0x3F];
        }

        // Remove padding (base64url doesn't use padding)
        uint256 paddingLen = (3 - (data.length % 3)) % 3;
        assembly {
            mstore(result, sub(mload(result), paddingLen))
        }

        return result;
    }

    /**
     * @notice Verify secp256r1 signature using EIP-7212 precompile
     */
    function _verifyP256Signature(
        bytes32 messageHash,
        bytes32 r,
        bytes32 s,
        bytes32 pubKeyX,
        bytes32 pubKeyY
    ) internal view returns (bool) {
        bytes memory input = abi.encodePacked(messageHash, r, s, pubKeyX, pubKeyY);

        (bool success, bytes memory result) = P256_VERIFIER.staticcall(input);

        if (!success || result.length != 32) {
            return false;
        }

        return abi.decode(result, (uint256)) == 1;
    }

    /**
     * @notice Receive ETH
     */
    receive() external payable {}
}