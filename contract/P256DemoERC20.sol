// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title P256Demo - 支持 Passkey 签名的 ERC20 转账
/// @notice 用户通过指纹/Face ID 签名，合约验证后执行 ERC20 转账
contract P256DemoERC20 {
    /// @notice P256VERIFY 预编译合约地址 (EIP-7951)
    address constant P256VERIFY = 0x0000000000000000000000000000000000000100;

    /// @notice 已注册的公钥
    struct PublicKey {
        bytes32 x;
        bytes32 y;
    }

    /// @notice 用户地址 => 公钥
    mapping(address => PublicKey) public publicKeys;

    /// @notice 用户 nonce，防止重放攻击
    mapping(address => uint256) public nonces;

    /// @notice 公钥注册事件
    event PublicKeyRegistered(address indexed user, bytes32 x, bytes32 y);

    /// @notice 签名验证成功事件
    event SignatureVerified(address indexed user, bytes32 hash, uint256 nonce);

    /// @notice ERC20 转账执行事件
    event ERC20Transferred(
        address indexed user,
        address indexed token,
        address indexed to,
        uint256 amount,
        uint256 nonce
    );

    /// @notice 任意调用执行事件
    event Executed(address indexed user, address indexed to, uint256 value, bytes data);

    /// @notice 注册公钥
    function registerPublicKey(bytes32 x, bytes32 y) external {
        publicKeys[msg.sender] = PublicKey(x, y);
        emit PublicKeyRegistered(msg.sender, x, y);
    }

    /// @notice 为指定用户注册公钥（由中继调用）
    function registerPublicKeyFor(address user, bytes32 x, bytes32 y) external {
        require(publicKeys[user].x == bytes32(0), "Already registered");
        publicKeys[user] = PublicKey(x, y);
        emit PublicKeyRegistered(user, x, y);
    }

    /// @notice 验证 P256 签名
    function verifySignature(
        bytes32 hash,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) public view returns (bool) {
        (bool success, bytes memory result) = P256VERIFY.staticcall(
            abi.encodePacked(hash, r, s, x, y)
        );

        if (!success || result.length == 0) {
            return false;
        }

        return abi.decode(result, (uint256)) == 1;
    }

    /// @notice 验证签名并记录
    function verifyAndRecord(
        address user,
        bytes32 hash,
        bytes32 r,
        bytes32 s
    ) external {
        PublicKey memory pk = publicKeys[user];
        require(pk.x != bytes32(0), "Public key not registered");

        bool valid = verifySignature(hash, r, s, pk.x, pk.y);
        require(valid, "Invalid signature");

        emit SignatureVerified(user, hash, nonces[user]);
        nonces[user]++;
    }

    /// @notice 获取 ERC20 转账的签名消息哈希
    /// @param user 用户地址（签名者）
    /// @param token ERC20 代币合约地址
    /// @param to 接收地址
    /// @param amount 转账金额
    /// @return 待签名的哈希
    function getERC20TransferHash(
        address user,
        address token,
        address to,
        uint256 amount
    ) public view returns (bytes32) {
        return keccak256(abi.encodePacked(
            "ERC20Transfer",
            user,
            token,
            to,
            amount,
            nonces[user],
            block.chainid,
            address(this)
        ));
    }

    /// @notice 执行 ERC20 转账（通过 Passkey 签名授权）
    /// @param user 用户地址（签名者，代币持有者）
    /// @param token ERC20 代币合约地址
    /// @param to 接收地址
    /// @param amount 转账金额
    /// @param hash WebAuthn 签名消息哈希
    /// @param r 签名 r 值
    /// @param s 签名 s 值
    function executeERC20Transfer(
        address user,
        address token,
        address to,
        uint256 amount,
        bytes32 hash,
        bytes32 r,
        bytes32 s
    ) external {
        PublicKey memory pk = publicKeys[user];
        require(pk.x != bytes32(0), "Public key not registered");

        // 验证 P256 签名
        bool valid = verifySignature(hash, r, s, pk.x, pk.y);
        require(valid, "Invalid signature");

        uint256 currentNonce = nonces[user];
        nonces[user]++;

        // 执行 ERC20 transferFrom
        // 注意：用户需要先 approve 本合约
        (bool success, bytes memory result) = token.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                user,
                to,
                amount
            )
        );

        // 检查调用结果
        require(success, "Transfer call failed");

        // 处理返回值（某些代币不返回值）
        if (result.length > 0) {
            require(abi.decode(result, (bool)), "Transfer returned false");
        }

        emit ERC20Transferred(user, token, to, amount, currentNonce);
    }

    /// @notice 直接执行 ERC20 转账（简化版，合约持有代币时使用）
    /// @param token ERC20 代币合约地址
    /// @param to 接收地址
    /// @param amount 转账金额
    /// @param hash WebAuthn 签名消息哈希
    /// @param r 签名 r 值
    /// @param s 签名 s 值
    /// @param x 公钥 X 坐标
    /// @param y 公钥 Y 坐标
    function transferERC20WithSignature(
        address token,
        address to,
        uint256 amount,
        bytes32 hash,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) external {
        // 验证 P256 签名
        bool valid = verifySignature(hash, r, s, x, y);
        require(valid, "Invalid signature");

        // 执行 ERC20 transfer（从合约余额转出）
        (bool success, bytes memory result) = token.call(
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                to,
                amount
            )
        );

        require(success, "Transfer call failed");
        if (result.length > 0) {
            require(abi.decode(result, (bool)), "Transfer returned false");
        }

        emit Executed(msg.sender, token, 0, abi.encodeWithSignature("transfer(address,uint256)", to, amount));
    }

    /// @notice 通用执行函数（验证签名后执行任意调用）
    function execute(
        address user,
        address to,
        uint256 value,
        bytes calldata data,
        bytes32 r,
        bytes32 s
    ) external {
        PublicKey memory pk = publicKeys[user];
        require(pk.x != bytes32(0), "Public key not registered");

        bytes32 hash = keccak256(abi.encodePacked(
            user,
            to,
            value,
            keccak256(data),
            nonces[user],
            block.chainid
        ));

        bool valid = verifySignature(hash, r, s, pk.x, pk.y);
        require(valid, "Invalid signature");

        nonces[user]++;

        (bool success, ) = to.call{value: value}(data);
        require(success, "Execution failed");

        emit Executed(user, to, value, data);
    }

    /// @notice 获取用户当前 nonce
    function getNonce(address user) external view returns (uint256) {
        return nonces[user];
    }

    /// @notice 获取用户公钥
    function getPublicKey(address user) external view returns (bytes32 x, bytes32 y) {
        PublicKey memory pk = publicKeys[user];
        return (pk.x, pk.y);
    }

    /// @notice 执行 ERC20 转账（一步完成，无需预先注册公钥）
    /// @param user 用户地址（代币持有者）
    /// @param token ERC20 代币合约地址
    /// @param to 接收地址
    /// @param amount 转账金额
    /// @param hash WebAuthn 签名消息哈希
    /// @param r 签名 r 值
    /// @param s 签名 s 值
    /// @param x 公钥 X 坐标
    /// @param y 公钥 Y 坐标
    function executeERC20TransferWithPubKey(
        address user,
        address token,
        address to,
        uint256 amount,
        bytes32 hash,
        bytes32 r,
        bytes32 s,
        bytes32 x,
        bytes32 y
    ) external {
        // 验证 P256 签名
        bool valid = verifySignature(hash, r, s, x, y);
        require(valid, "Invalid signature");

        // 执行 ERC20 transferFrom
        // 注意：用户需要先 approve 本合约
        (bool success, bytes memory result) = token.call(
            abi.encodeWithSignature(
                "transferFrom(address,address,uint256)",
                user,
                to,
                amount
            )
        );

        // 检查调用结果
        require(success, "Transfer call failed");

        // 处理返回值（某些代币不返回值）
        if (result.length > 0) {
            require(abi.decode(result, (bool)), "Transfer returned false");
        }

        emit ERC20Transferred(user, token, to, amount, 0);
    }

    /// @notice 接收 ETH
    receive() external payable {}
}
