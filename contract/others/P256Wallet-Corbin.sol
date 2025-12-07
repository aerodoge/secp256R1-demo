// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title P256Wallet
 * @notice EIP-7951 Demo: 使用 WebAuthn + secp256r1 签名验证的简易钱包
 * @dev 使用 Daimo P256Verifier 合约（已部署在多链）
 */
contract P256Wallet {
    // Daimo P256Verifier 地址 (CREATE2 确定性地址，所有 EVM 链通用)
    address constant P256_VERIFIER = 0xc2b78104907F722DABAc4C69f826a522B2754De4;

    // 钱包所有者的 P-256 公钥
    uint256 public ownerX;
    uint256 public ownerY;

    // 防重放攻击的 nonce
    uint256 public nonce;

    // 事件
    event WalletCreated(uint256 indexed pubKeyX, uint256 indexed pubKeyY);
    event TransferExecuted(address indexed to, uint256 amount, uint256 nonce);

    /**
     * @notice 创建钱包并设置 P-256 公钥
     */
    constructor(uint256 _ownerX, uint256 _ownerY) {
        ownerX = _ownerX;
        ownerY = _ownerY;
        emit WalletCreated(_ownerX, _ownerY);
    }

    /**
     * @notice 使用 WebAuthn P-256 签名执行 ETH 转账
     * @param to 接收地址
     * @param amount 转账金额
     * @param r 签名 r 值
     * @param s 签名 s 值
     * @param authenticatorData WebAuthn authenticatorData
     * @param clientDataJSON WebAuthn clientDataJSON (包含 challenge)
     */
    function transfer(
        address to,
        uint256 amount,
        uint256 r,
        uint256 s,
        bytes calldata authenticatorData,
        string calldata clientDataJSON
    ) external {
        // 1. 验证 clientDataJSON 中的 challenge 是否匹配预期的交易哈希
        bytes32 expectedChallenge = keccak256(abi.encodePacked(
            address(this),
            to,
            amount,
            nonce
        ));

        require(
            _verifyChallenge(clientDataJSON, expectedChallenge),
            "Challenge mismatch"
        );

        // 2. 计算 WebAuthn 签名的实际消息: SHA256(authenticatorData || SHA256(clientDataJSON))
        bytes32 clientDataHash = sha256(bytes(clientDataJSON));
        bytes32 message = sha256(abi.encodePacked(authenticatorData, clientDataHash));

        // 3. 调用 EIP-7951 预编译合约验证 P-256 签名
        require(_verifyP256Signature(message, r, s, ownerX, ownerY), "Invalid signature");

        // 4. 更新 nonce 防止重放
        nonce++;

        // 5. 执行转账
        (bool success, ) = to.call{value: amount}("");
        require(success, "Transfer failed");

        emit TransferExecuted(to, amount, nonce - 1);
    }

    /**
     * @notice 验证 clientDataJSON 中的 challenge
     * @dev challenge 是 base64url 编码的哈希值
     */
    function _verifyChallenge(
        string calldata clientDataJSON,
        bytes32 expectedChallenge
    ) internal pure returns (bool) {
        // 将 expectedChallenge 转换为 base64url 字符串
        string memory expectedChallengeB64 = _bytesToBase64URL(abi.encodePacked(expectedChallenge));

        // 检查 clientDataJSON 是否包含正确的 challenge
        // clientDataJSON 格式: {"type":"webauthn.get","challenge":"<base64url>","origin":"..."}
        return _containsChallenge(clientDataJSON, expectedChallengeB64);
    }

    /**
     * @notice 检查 JSON 字符串是否包含指定的 challenge
     */
    function _containsChallenge(
        string calldata json,
        string memory challenge
    ) internal pure returns (bool) {
        bytes memory jsonBytes = bytes(json);
        bytes memory searchPattern = abi.encodePacked('"challenge":"', challenge, '"');

        if (jsonBytes.length < searchPattern.length) return false;

        for (uint i = 0; i <= jsonBytes.length - searchPattern.length; i++) {
            bool found = true;
            for (uint j = 0; j < searchPattern.length; j++) {
                if (jsonBytes[i + j] != searchPattern[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }

    /**
     * @notice 将字节数组转换为 base64url 字符串
     */
    function _bytesToBase64URL(bytes memory data) internal pure returns (string memory) {
        bytes memory TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

        uint256 len = data.length;
        if (len == 0) return "";

        uint256 encodedLen = 4 * ((len + 2) / 3);
        bytes memory result = new bytes(encodedLen);

        uint256 i = 0;
        uint256 j = 0;

        while (i < len) {
            uint256 a = i < len ? uint8(data[i++]) : 0;
            uint256 b = i < len ? uint8(data[i++]) : 0;
            uint256 c = i < len ? uint8(data[i++]) : 0;

            uint256 triple = (a << 16) | (b << 8) | c;

            result[j++] = TABLE[(triple >> 18) & 0x3F];
            result[j++] = TABLE[(triple >> 12) & 0x3F];
            result[j++] = TABLE[(triple >> 6) & 0x3F];
            result[j++] = TABLE[triple & 0x3F];
        }

        // 移除 padding（base64url 不需要 =）
        uint256 paddingLen = (3 - (len % 3)) % 3;

        bytes memory trimmed = new bytes(encodedLen - paddingLen);
        for (uint256 k = 0; k < trimmed.length; k++) {
            trimmed[k] = result[k];
        }

        return string(trimmed);
    }

    /**
     * @notice 使用 Daimo P256Verifier 验证签名
     * @dev Daimo P256Verifier 使用 fallback 函数，直接发送 160 字节数据
     *      格式: hash (32) + r (32) + s (32) + x (32) + y (32)
     */
    function _verifyP256Signature(
        bytes32 hash,
        uint256 r,
        uint256 s,
        uint256 qx,
        uint256 qy
    ) internal view returns (bool) {
        // 构造 160 字节输入 (与 EIP-7212/7951 预编译格式相同)
        bytes memory input = abi.encodePacked(hash, r, s, qx, qy);

        (bool success, bytes memory result) = P256_VERIFIER.staticcall(input);

        if (!success || result.length < 32) {
            return false;
        }

        // 返回值是 32 字节，1 表示验证成功，0 表示失败
        return abi.decode(result, (uint256)) == 1;
    }

    /**
     * @notice 获取待签名的 challenge（供前端使用）
     */
    function getTransferChallenge(address to, uint256 amount) external view returns (bytes32) {
        return keccak256(abi.encodePacked(
            address(this),
            to,
            amount,
            nonce
        ));
    }

    receive() external payable {}
}
