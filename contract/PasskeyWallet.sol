// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PasskeyWallet - 基于 Passkey (secp256r1) 的智能合约钱包
/// @notice 每个用户部署自己的钱包，用指纹/Face ID 签名授权转账
contract PasskeyWallet {
    /// @notice P256VERIFY 预编译合约地址 (EIP-7212)
    address constant P256VERIFY = 0x0000000000000000000000000000000000000100;

    /// @notice 钱包所有者的 Passkey 公钥
    bytes32 public publicKeyX;
    bytes32 public publicKeyY;

    /// @notice 防重放攻击的 nonce
    uint256 public nonce;

    /// @notice 转账事件
    event ERC20Transferred(
        address indexed token,
        address indexed to,
        uint256 amount,
        uint256 nonce
    );

    /// @notice 公钥更新事件
    event PublicKeyUpdated(bytes32 x, bytes32 y);

    /// @notice 初始化钱包，设置 Passkey 公钥
    /// @param x 公钥 X 坐标
    /// @param y 公钥 Y 坐标
    constructor(bytes32 x, bytes32 y) {
        publicKeyX = x;
        publicKeyY = y;
        emit PublicKeyUpdated(x, y);
    }

    /// @notice 验证 P256 签名
    function verifySignature(
        bytes32 hash,
        bytes32 r,
        bytes32 s
    ) public view returns (bool) {
        (bool success, bytes memory result) = P256VERIFY.staticcall(
            abi.encodePacked(hash, r, s, publicKeyX, publicKeyY)
        );

        if (!success || result.length == 0) {
            return false;
        }

        return abi.decode(result, (uint256)) == 1;
    }

    /// @notice 执行 ERC20 转账（需要 Passkey 签名授权）
    /// @param token ERC20 代币合约地址
    /// @param to 接收地址
    /// @param amount 转账金额
    /// @param hash WebAuthn 签名消息哈希
    /// @param r 签名 r 值
    /// @param s 签名 s 值
    function transferERC20(
        address token,
        address to,
        uint256 amount,
        bytes32 hash,
        bytes32 r,
        bytes32 s
    ) external {
        // 验证 P256 签名
        require(verifySignature(hash, r, s), "Invalid signature");

        uint256 currentNonce = nonce;
        nonce++;

        // 执行 ERC20 transfer（从钱包余额转出）
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

        emit ERC20Transferred(token, to, amount, currentNonce);
    }

    /// @notice 执行 ETH 转账（需要 Passkey 签名授权）
    /// @param to 接收地址
    /// @param amount 转账金额 (wei)
    /// @param hash WebAuthn 签名消息哈希
    /// @param r 签名 r 值
    /// @param s 签名 s 值
    function transferETH(
        address payable to,
        uint256 amount,
        bytes32 hash,
        bytes32 r,
        bytes32 s
    ) external {
        require(verifySignature(hash, r, s), "Invalid signature");

        nonce++;

        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    /// @notice 通用执行函数（需要 Passkey 签名授权）
    /// @param to 目标合约地址
    /// @param value ETH 数量
    /// @param data 调用数据
    /// @param hash WebAuthn 签名消息哈希
    /// @param r 签名 r 值
    /// @param s 签名 s 值
    function execute(
        address to,
        uint256 value,
        bytes calldata data,
        bytes32 hash,
        bytes32 r,
        bytes32 s
    ) external returns (bytes memory) {
        require(verifySignature(hash, r, s), "Invalid signature");

        nonce++;

        (bool success, bytes memory result) = to.call{value: value}(data);
        require(success, "Execution failed");

        return result;
    }

    /// @notice 更新公钥（需要当前 Passkey 签名授权）
    /// @param newX 新公钥 X 坐标
    /// @param newY 新公钥 Y 坐标
    /// @param hash WebAuthn 签名消息哈希
    /// @param r 签名 r 值
    /// @param s 签名 s 值
    function updatePublicKey(
        bytes32 newX,
        bytes32 newY,
        bytes32 hash,
        bytes32 r,
        bytes32 s
    ) external {
        require(verifySignature(hash, r, s), "Invalid signature");

        publicKeyX = newX;
        publicKeyY = newY;
        nonce++;

        emit PublicKeyUpdated(newX, newY);
    }

    /// @notice 获取钱包公钥
    function getPublicKey() external view returns (bytes32 x, bytes32 y) {
        return (publicKeyX, publicKeyY);
    }

    /// @notice 接收 ETH
    receive() external payable {}
}

/// @title PasskeyWalletFactory - 钱包工厂合约
/// @notice 用于部署用户的 PasskeyWallet
contract PasskeyWalletFactory {
    /// @notice 钱包创建事件
    event WalletCreated(address indexed wallet, bytes32 x, bytes32 y);

    /// @notice 用户地址 => 钱包地址（可选，用于查询）
    mapping(address => address) public wallets;

    /// @notice 创建新钱包
    /// @param x 公钥 X 坐标
    /// @param y 公钥 Y 坐标
    /// @return wallet 新钱包地址
    function createWallet(bytes32 x, bytes32 y) external returns (address wallet) {
        PasskeyWallet newWallet = new PasskeyWallet(x, y);
        wallet = address(newWallet);
        wallets[msg.sender] = wallet;
        emit WalletCreated(wallet, x, y);
    }

    /// @notice 使用 CREATE2 创建钱包（可预测地址）
    /// @param x 公钥 X 坐标
    /// @param y 公钥 Y 坐标
    /// @param salt 盐值
    /// @return wallet 新钱包地址
    function createWalletDeterministic(
        bytes32 x,
        bytes32 y,
        bytes32 salt
    ) external returns (address wallet) {
        PasskeyWallet newWallet = new PasskeyWallet{salt: salt}(x, y);
        wallet = address(newWallet);
        wallets[msg.sender] = wallet;
        emit WalletCreated(wallet, x, y);
    }

    /// @notice 计算 CREATE2 钱包地址
    /// @param x 公钥 X 坐标
    /// @param y 公钥 Y 坐标
    /// @param salt 盐值
    /// @return 预测的钱包地址
    function computeWalletAddress(
        bytes32 x,
        bytes32 y,
        bytes32 salt
    ) external view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(abi.encodePacked(
                    type(PasskeyWallet).creationCode,
                    abi.encode(x, y)
                ))
            )
        );
        return address(uint160(uint256(hash)));
    }
}
