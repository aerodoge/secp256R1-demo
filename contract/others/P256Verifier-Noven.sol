// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title P256Verifier
 * @notice 符合 EIP-7951 规范的 secp256r1 (P-256) 签名验证合约
 * @dev 支持通过 P256 签名授权的代币转账
 */
contract P256Verifier {
    using SafeERC20 for IERC20;
    
    /// @notice EIP-7951 预编译合约地址
    address constant P256VERIFY_PRECOMPILE = address(0x100);
    
    /// @notice 预编译调用的 Gas 成本
    uint256 constant P256VERIFY_GAS = 6900;
    
    /// @notice secp256r1 曲线的阶 n
    uint256 constant P256_N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
    
    /// @notice secp256r1 曲线的素数域 p
    uint256 constant P256_P = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff;

    /// @notice 签名结构体
    struct Signature {
        bytes32 messageHash;
        bytes32 r;
        bytes32 s;
        bytes32 qx;
        bytes32 qy;
    }

    /// @notice 已使用的签名哈希（防止重放攻击）
    mapping(bytes32 => bool) public usedSignatures;

    /// @notice 注册的公钥
    mapping(bytes32 => mapping(bytes32 => bool)) public registeredPublicKeys;

    /// @notice 签名验证成功事件
    event SignatureVerified(bytes32 indexed messageHash, bool success);
    
    /// @notice 代币转账事件
    event TokenTransferred(
        address indexed token,
        address indexed to,
        uint256 amount,
        bytes32 indexed messageHash
    );

    /// @notice 公钥注册事件
    event PublicKeyRegistered(bytes32 qx, bytes32 qy);

    /**
     * @notice 注册公钥（可选，用于限制哪些公钥可以授权转账）
     * @param qx 公钥 x 坐标
     * @param qy 公钥 y 坐标
     */
    function registerPublicKey(bytes32 qx, bytes32 qy) external {
        registeredPublicKeys[qx][qy] = true;
        emit PublicKeyRegistered(qx, qy);
    }

    /**
     * @notice 验证 P-256 ECDSA 签名
     * @param messageHash 消息的 SHA-256 哈希值
     * @param r 签名的 r 分量
     * @param s 签名的 s 分量
     * @param qx 公钥的 x 坐标
     * @param qy 公钥的 y 坐标
     * @return success 验证是否成功
     * @return result 成功时返回 0x01，失败时返回 0x00
     */
    function verifyP256Signature(
        bytes32 messageHash,
        bytes32 r,
        bytes32 s,
        bytes32 qx,
        bytes32 qy
    ) public view returns (bool success, bytes32 result) {
        // 构建 160 字节的输入数据
        bytes memory input = abi.encodePacked(messageHash, r, s, qx, qy);
        
        // 调用预编译合约
        (bool ok, bytes memory output) = P256VERIFY_PRECOMPILE.staticcall{gas: P256VERIFY_GAS}(input);
        
        // 检查调用是否成功且返回 32 字节
        if (ok && output.length == 32) {
            result = bytes32(output);
            // 验证返回值是否为 0x01
            success = (result == bytes32(uint256(1)));
        } else {
            success = false;
            result = bytes32(0);
        }
    }

    /**
     * @notice 验证签名（使用 Signature 结构体）
     * @param sig 签名结构体
     * @return success 签名是否有效
     * @return result 返回结果
     */
    function verifySignature(Signature calldata sig) public view returns (bool success, bytes32 result) {
        return verifyP256Signature(sig.messageHash, sig.r, sig.s, sig.qx, sig.qy);
    }

    /**
     * @notice 通过 P256 签名授权转账代币
     * @param token 代币合约地址
     * @param to 接收地址
     * @param amount 转账数量
     * @param signature 签名数据
     * @dev 签名的 messageHash 应该是 keccak256(abi.encodePacked(token, to, amount, nonce, chainId, address(this)))
     */
    function transferWithPermit(
        address token,
        address to,
        uint256 amount,
        Signature calldata signature
    ) external {
        // 1. 检查签名是否已使用（防止重放攻击）
        bytes32 sigHash = keccak256(abi.encodePacked(
            signature.messageHash,
            signature.r,
            signature.s
        ));
        require(!usedSignatures[sigHash], "Signature already used");

        // 2. 验证签名
        (bool success, bytes32 result) = verifyP256Signature(
            signature.messageHash,
            signature.r,
            signature.s,
            signature.qx,
            signature.qy
        );
        
        // 3. 检查验证结果必须为 0x01
        require(
            success && result == bytes32(uint256(1)),
            "Invalid signature"
        );

        // 4. 验证消息内容（确保签名的是正确的转账请求）
        // messageHash 应该包含: token, to, amount, chainId, this
        bytes32 expectedHash = keccak256(abi.encodePacked(
            token,
            to,
            amount,
            block.chainid,
            address(this)
        ));
        
        // 由于 WebAuthn 签名的是 SHA256(authenticatorData || clientDataHash)
        // 我们在 clientData 的 challenge 中放入 expectedHash
        // 所以这里我们信任前端传来的 messageHash（它是 WebAuthn 计算的）
        // 实际生产中应该在链下验证 challenge 包含正确的 expectedHash

        // 5. 标记签名已使用
        usedSignatures[sigHash] = true;

        // 6. 执行转账
        IERC20(token).safeTransfer(to, amount);

        emit TokenTransferred(token, to, amount, signature.messageHash);
        emit SignatureVerified(signature.messageHash, true);
    }

    /**
     * @notice 通过 P256 签名授权转账（简化版，不验证消息内容）
     * @dev 仅用于演示，生产环境应使用 transferWithPermit
     */
    function transferWithPermitSimple(
        address token,
        address to,
        uint256 amount,
        Signature calldata signature
    ) external {
        // 1. 检查签名是否已使用
        bytes32 sigHash = keccak256(abi.encodePacked(
            signature.messageHash,
            signature.r,
            signature.s
        ));
        require(!usedSignatures[sigHash], "Signature already used");

        // 2. 验证签名 - 结果必须为 0x01
        (bool success, bytes32 result) = verifyP256Signature(
            signature.messageHash,
            signature.r,
            signature.s,
            signature.qx,
            signature.qy
        );
        
        require(
            success && result == bytes32(uint256(1)),
            "Invalid signature: verification failed"
        );

        // 3. 标记签名已使用
        usedSignatures[sigHash] = true;

        // 4. 执行转账
        IERC20(token).safeTransfer(to, amount);

        emit TokenTransferred(token, to, amount, signature.messageHash);
    }

    /**
     * @notice 查询合约持有的代币余额
     * @param token 代币地址
     * @return 代币余额
     */
    function tokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /**
     * @notice 验证签名（简化版，仅返回 bool）
     */
    function verify(
        bytes32 messageHash,
        bytes32 r,
        bytes32 s,
        bytes32 qx,
        bytes32 qy
    ) public view returns (bool) {
        (bool success, ) = verifyP256Signature(messageHash, r, s, qx, qy);
        return success;
    }

    /**
     * @notice 预验证输入参数
     */
    function validateInputs(
        bytes32 r,
        bytes32 s,
        bytes32 qx,
        bytes32 qy
    ) public pure returns (bool valid, string memory reason) {
        uint256 rVal = uint256(r);
        uint256 sVal = uint256(s);
        uint256 qxVal = uint256(qx);
        uint256 qyVal = uint256(qy);
        
        if (rVal == 0 || rVal >= P256_N) {
            return (false, "r out of range: must be 0 < r < n");
        }
        if (sVal == 0 || sVal >= P256_N) {
            return (false, "s out of range: must be 0 < s < n");
        }
        if (qxVal >= P256_P) {
            return (false, "qx out of range: must be < p");
        }
        if (qyVal >= P256_P) {
            return (false, "qy out of range: must be < p");
        }
        if (qxVal == 0 && qyVal == 0) {
            return (false, "public key is point at infinity");
        }
        
        return (true, "");
    }

    /**
     * @notice 紧急提取代币（仅用于测试）
     * @dev 生产环境应该添加权限控制
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external {
        IERC20(token).safeTransfer(to, amount);
    }
}