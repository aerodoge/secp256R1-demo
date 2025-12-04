# Passkey Wallet - 基于 secp256r1 的智能合约钱包

## 1. 项目概述

### 1.1 项目目标

实现用户通过指纹/Face ID (Passkey) 直接签署并发送以太坊链上交易，无需管理助记词或私钥。

### 1.2 核心价值

- **用户友好**: 使用熟悉的生物识别方式，降低 Web3 入门门槛
- **安全可靠**: 私钥存储在设备安全芯片中，永不导出
- **标准兼容**: 基于 WebAuthn 标准和 EIP-7212/7951 预编译

### 1.3 技术基础

- **EIP-7212/7951**: Ethereum 支持 secp256r1 (P-256) 曲线签名验证的预编译合约
- **WebAuthn/Passkey**: W3C 标准，支持指纹/Face ID 等生物识别
- **智能合约钱包**: 用户资产存储在合约中，由 Passkey 签名授权操作

### 1.4 与传统 EOA 的区别

#### 传统 EOA 模式

```
用户私钥 (secp256k1)     →  签名交易  →  EOA 地址
    ↓
存储在钱包软件/硬件钱包中
需要用户自己保管（助记词、Keystore 等）
```

#### Passkey 智能钱包模式

```
设备私钥 (secp256r1)     →  签名授权  →  智能合约钱包
    ↓
存储在设备安全芯片中 (Secure Enclave/TPM)
永不导出，用指纹/Face ID 触发签名
```

#### 资金流向图

```
                    ┌─────────────────────┐
                    │  PasskeyWallet 合约  │  ← 用户资产存这里
                    │  (存储公钥 x, y)     │
                    └─────────────────────┘
                              ↑
                              │ 验证签名后执行转账
                              │
┌──────────────┐         ┌────────────┐
│ 设备安全芯片  │ ──签名──→ │ P256VERIFY │
│ (私钥永不导出) │         │  预编译合约  │
└──────────────┘         └────────────┘
```

#### 对比表

| 项目    | 传统 EOA    | Passkey 钱包        |
|-------|-----------|-------------------|
| 私钥位置  | 用户自己管理    | 设备安全芯片            |
| 私钥曲线  | secp256k1 | secp256r1 (P-256) |
| 资产位置  | EOA 地址    | 智能合约地址            |
| 签名方式  | 钱包软件签名    | 指纹/Face ID        |
| 私钥可导出 | 是         | 否                 |
| 助记词   | 需要备份      | 不需要               |

#### 后端 EOA 的作用

本项目后端有一个 EOA 私钥，但它 **只用于支付 Gas 费用**，不控制用户资产：

```
用户 Passkey 签名  →  后端 EOA 提交交易  →  合约验证签名  →  执行操作
                         ↓
                   只支付 Gas，不控制资产
```

> ⚠️ **重要**: 用户资产完全由 Passkey 签名控制，后端 EOA 无法转走用户资产。

---

## 2. 需求分析

### 2.1 核心需求

| 需求ID   | 描述                | 优先级 | 状态    |
|--------|-------------------|-----|-------|
| FR-001 | 用户通过 Passkey 创建钱包 | P0  | ✅ 已完成 |
| FR-002 | 系统自动部署智能合约钱包      | P0  | ✅ 已完成 |
| FR-003 | 支持 ERC-20 代币转账    | P0  | ✅ 已完成 |
| FR-004 | 支持 ETH 转账         | P0  | ✅ 已完成 |
| FR-005 | 支持任意合约调用          | P1  | ✅ 已完成 |
| FR-006 | 自动化领取测试币流程        | P1  | ✅ 已完成 |

### 2.2 非功能需求

| 需求ID    | 描述                | 指标                     | 状态   |
|---------|-------------------|------------------------|------|
| NFR-001 | 签名验证 Gas 消耗       | 6,900 gas (预编译)        | ✅ 达成 |
| NFR-002 | 支持主流浏览器           | Chrome, Safari         | ✅ 达成 |
| NFR-003 | 支持 macOS Touch ID | Platform Authenticator | ✅ 达成 |

---

## 3. 系统架构

### 3.1 架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                         前端 (Web)                               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │   WebAuthn   │  │   MetaMask   │  │  HTTP API    │          │
│  │  (Passkey)   │  │  (Faucet/    │  │   Client     │          │
│  │              │  │   Deposit)   │  │              │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                       后端 (Go HTTP Server)                      │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │ /api/create  │  │ /api/transfer│  │ /api/balance │          │
│  │   -wallet    │  │              │  │              │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Ethereum (Sepolia)                            │
│  ┌──────────────────────┐  ┌──────────────────────┐            │
│  │ PasskeyWalletFactory │  │    PasskeyWallet     │            │
│  │  (创建用户钱包)        │  │   (用户智能钱包)      │            │
│  └──────────────────────┘  └──────────────────────┘            │
│                                       │                         │
│                              ┌────────┴────────┐                │
│                              ▼                 ▼                │
│                    ┌──────────────┐   ┌──────────────┐          │
│                    │  P256VERIFY  │   │   ERC20      │          │
│                    │  预编译合约   │   │   Token      │          │
│                    │  (0x100)     │   │              │          │
│                    └──────────────┘   └──────────────┘          │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 核心流程

#### 3.2.1 创建钱包流程

```
1. 用户点击"注册 Passkey 并创建钱包"
2. 浏览器调用 WebAuthn API，用户验证指纹/Face ID
3. 生成 secp256r1 密钥对，公钥 (x, y) 返回给前端
4. 前端调用后端 /api/create-wallet
5. 后端调用 Factory.createWallet(x, y)
6. Factory 部署新的 PasskeyWallet 合约，存储公钥
7. 返回钱包合约地址给用户 (通过 WalletCreated 事件)
```

#### 3.2.2 转账流程

```
1. 用户填写接收地址和金额
2. 用户点击"签名转账"
3. 浏览器调用 WebAuthn API，用户验证指纹/Face ID
4. 生成签名 (r, s) 和消息哈希
5. 前端调用后端 /api/transfer
6. 后端调用 Wallet.transferERC20(token, to, amount, hash, r, s)
7. 钱包合约调用 P256VERIFY 预编译验证签名
8. 签名有效则执行 ERC20 transfer
```

---

## 4. 智能合约设计

### 4.1 PasskeyWallet (用户钱包)

```solidity
contract PasskeyWallet {
    // P256VERIFY 预编译地址 (EIP-7212)
    address constant P256VERIFY = 0x0000000000000000000000000000000000000100;

    // 用户公钥 (创建时设置，不可更改)
    bytes32 public publicKeyX;
    bytes32 public publicKeyY;

    // 防重放 nonce
    uint256 public nonce;

    // 验证签名 - 调用预编译合约
    function verifySignature(bytes32 hash, bytes32 r, bytes32 s) public view returns (bool) {
        (bool success, bytes memory result) = P256VERIFY.staticcall(
            abi.encodePacked(hash, r, s, publicKeyX, publicKeyY)
        );
        if (!success || result.length == 0) return false;
        return abi.decode(result, (uint256)) == 1;
    }

    // ERC20 转账 - 验证签名后执行
    function transferERC20(
        address token, address to, uint256 amount,
        bytes32 hash, bytes32 r, bytes32 s
    ) external {
        require(verifySignature(hash, r, s), "Invalid signature");
        nonce++;
        // 执行 ERC20 transfer
        IERC20(token).transfer(to, amount);
    }

    // ETH 转账
    function transferETH(address payable to, uint256 amount, ...) external;

// 通用执行
function execute(address to, uint256 value, bytes calldata data, ...) external;
}
```

### 4.2 PasskeyWalletFactory (工厂合约)

```solidity
contract PasskeyWalletFactory {
    event WalletCreated(address indexed wallet, bytes32 x, bytes32 y);

    // 创建钱包 - 部署新的 PasskeyWallet 实例
    function createWallet(bytes32 x, bytes32 y) external returns (address wallet) {
        wallet = address(new PasskeyWallet(x, y));
        emit WalletCreated(wallet, x, y);
    }

    // CREATE2 创建 - 可预测钱包地址
    function createWalletDeterministic(bytes32 x, bytes32 y, bytes32 salt) external returns (address);
}
```

### 4.3 EIP-7212/7951 P256VERIFY 预编译

| 属性     | 值                                                |
|--------|--------------------------------------------------|
| 地址     | `0x0000000000000000000000000000000000000100`     |
| Gas 消耗 | 6,900                                            |
| 输入格式   | 160 字节: hash(32) + r(32) + s(32) + x(32) + y(32) |
| 输出格式   | 有效: 32字节值为1，无效: 空字节                              |

---

## 5. WebAuthn/Passkey 集成

### 5.1 注册 Passkey

```javascript
const credential = await navigator.credentials.create({
    publicKey: {
        challenge: randomBytes(32),
        rp: {name: "Passkey Wallet", id: window.location.hostname},
        user: {id: userId, name: username, displayName: username},
        pubKeyCredParams: [{type: "public-key", alg: -7}], // ES256 = secp256r1
        authenticatorSelection: {
            authenticatorAttachment: "platform",  // 使用设备内置认证器
            userVerification: "required",         // 必须验证用户
            residentKey: "preferred"              // 可发现凭证
        },
        attestation: "none"
    }
});
```

### 5.2 签名

```javascript
const assertion = await navigator.credentials.get({
    publicKey: {
        challenge: messageHash,
        rpId: window.location.hostname,
        userVerification: "required",
        allowCredentials: [{type: "public-key", id: credentialId}]
    }
});

// WebAuthn 签名的消息是: SHA256(authenticatorData + SHA256(clientDataJSON))
const clientDataHash = SHA256(clientDataJSON);
const signedData = authenticatorData + clientDataHash;
const finalHash = SHA256(signedData);  // 这个 hash 用于合约验证
```

### 5.3 公钥格式转换 (COSE → x, y)

```javascript
function parseCOSEPublicKey(coseKey) {
    // COSE 格式中 x 在 key -2 (0x21) 后面，y 在 key -3 (0x22) 后面
    const bytes = new Uint8Array(coseKey);
    const xIndex = bytes.indexOf(0x21);
    const yIndex = bytes.indexOf(0x22);
    const x = bytes.slice(xIndex + 3, xIndex + 35);  // 32 bytes
    const y = bytes.slice(yIndex + 3, yIndex + 35);  // 32 bytes
    return {x, y};
}
```

### 5.4 签名格式转换 (DER → r, s)

```javascript
function parseDERSignature(derBuffer) {
    // DER 格式: 0x30 [len] 0x02 [rLen] [r] 0x02 [sLen] [s]
    const bytes = new Uint8Array(derBuffer);
    let offset = 2;
    const rLen = bytes[offset + 1];
    const r = bytes.slice(offset + 2, offset + 2 + rLen);
    offset += 2 + rLen;
    const sLen = bytes[offset + 1];
    const s = bytes.slice(offset + 2, offset + 2 + sLen);
    // 确保 r, s 都是 32 字节
    return {r: padTo32Bytes(r), s: padTo32Bytes(s)};
}
```

---

## 6. 重要注意事项

### 6.1 Passkey 与钱包绑定

| 问题             | 说明                          | 解决方案                              |
|----------------|-----------------------------|-----------------------------------|
| **公钥匹配**       | 每个钱包存储特定公钥，只有对应 Passkey 能签名 | 确保使用创建钱包时的同一个 Passkey             |
| **无法更换**       | 如果用不同 Passkey 签名，验证会失败      | "Invalid signature" 错误时检查 Passkey |
| **丢失 Passkey** | 钱包资产无法取出                    | 需要实现恢复机制 (未实现)                    |

### 6.2 页面刷新问题

| 问题                | 说明                                      | 解决方案                           |
|-------------------|-----------------------------------------|--------------------------------|
| **credential 丢失** | 刷新页面后 credential 对象丢失                   | 保存 credentialId 到 localStorage |
| **公钥丢失**          | publicKeyData 需要持久化                     | 保存到 localStorage               |
| **可发现凭证**         | 如果 credentialId 丢失，可用空 allowCredentials | 浏览器会列出所有可用 Passkey             |

### 6.3 签名验证失败排查

```
"Invalid signature" 错误可能原因:

1. Passkey 不匹配
   - 用了不同的 Passkey 签名
   - 解决: 清除 localStorage，重新创建钱包

2. 消息哈希不正确
   - WebAuthn 签名的是 SHA256(authData + SHA256(clientDataJSON))
   - 不是直接签名 challenge

3. 公钥格式错误
   - COSE 公钥解析错误
   - r, s 没有 padding 到 32 字节
```

### 6.4 Gas 费用

| 操作                          | 预估 Gas   |
|-----------------------------|----------|
| 创建钱包 (Factory.createWallet) | ~200,000 |
| ERC20 转账 (transferERC20)    | ~50,000  |
| P256VERIFY 预编译调用            | 6,900    |

### 6.5 安全考虑

| 风险    | 缓解措施                     |
|-------|--------------------------|
| 签名重放  | 消息中包含 timestamp 和 random |
| 私钥泄露  | 私钥永不离开设备安全芯片             |
| 中继者私钥 | 仅用于支付 gas，不控制用户资产        |
| 钓鱼攻击  | WebAuthn rpId 绑定域名       |

---

## 7. 合约清单

### 7.1 必需合约 ✅

| 合约                     | 文件                  | 用途                        |
|------------------------|---------------------|---------------------------|
| `PasskeyWallet`        | `PasskeyWallet.sol` | 用户的智能合约钱包，存储公钥和资产         |
| `PasskeyWalletFactory` | `PasskeyWallet.sol` | 工厂合约，用于创建用户钱包             |
| `TestToken`            | `TestToken.sol`     | 测试用 ERC20 代币（含 faucet 功能） |

### 7.2 废弃合约 ❌

| 合约              | 文件                  | 说明                                                                            |
|-----------------|---------------------|-------------------------------------------------------------------------------|
| `P256DemoERC20` | `P256DemoERC20.sol` | **已废弃，不再使用**。这是旧方案 A 的合约，直接在合约内验签并转账，资产来源是调用者 EOA。现已被 PasskeyWallet 智能钱包方案替代。 |

> ⚠️ **注意**: 只需部署 `PasskeyWalletFactory` 和 `TestToken`，无需部署 `P256DemoERC20`。

---

## 8. 文件结构

```
secp256R1-demo/
├── config.yaml                  # 配置文件 (RPC, 合约地址, 私钥)
├── main.go                      # Go 后端服务
├── go.mod                       # Go 依赖
├── contract/
│   ├── PasskeyWallet.sol        # ✅ 智能钱包 + 工厂合约 (必需)
│   ├── TestToken.sol            # ✅ 测试代币 (必需)
│   └── P256DemoERC20.sol        # ❌ 旧版合约 (废弃，可删除)
├── web/
│   └── index.html               # 前端页面 (嵌入 Go 服务)
└── docs/
    └── DESIGN.md                # 本文档
```

---

## 9. 配置说明

```yaml
# config.yaml
rpc: "https://ethereum-sepolia-rpc.publicnode.com"  # RPC 节点
chain_id: 11155111                                   # Sepolia 链 ID
contract: "0x..."                                    # Factory 合约地址
private_key: "..."                                   # 中继账户私钥 (支付 gas)
port: 8080                                           # HTTP 服务端口
test_token: "0x..."                                  # 测试代币地址 (可选)
```

---

## 10. 部署与使用

### 10.1 部署步骤

1. **部署合约** (Remix)
    - 部署 `PasskeyWalletFactory` (无构造参数)
    - 部署 `TestToken` (初始供应量，如 1000000)

2. **配置**
   ```yaml
   contract: "Factory合约地址"
   test_token: "TestToken合约地址"
   ```

3. **启动服务**
   ```bash
   go run main.go
   ```

### 10.2 使用流程

1. 访问 http://localhost:8080
2. 点击"注册 Passkey 并创建钱包" → 用指纹/Face ID 验证
3. 从 Etherscan 事件日志 (WalletCreated) 获取钱包地址
4. 连接 MetaMask → 领取测试币 → 转入钱包
5. 填写接收地址和金额 → 用指纹签名转账

### 10.3 获取钱包地址

从 Etherscan 交易详情:

1. 打开创建钱包的交易
2. 点击 "Logs" 标签
3. 找到 `WalletCreated` 事件
4. `topic1` = 钱包地址 (去掉前导零)

---

## 11. 后续优化方向

| 优化项      | 描述                             | 优先级 |
|----------|--------------------------------|-----|
| 社交恢复     | 添加 guardian 机制，丢失 Passkey 后可恢复 | P1  |
| 多签支持     | 支持多个 Passkey 共同管理一个钱包          | P1  |
| Gas 代付   | 实现 ERC-4337 兼容，用户无需 ETH        | P1  |
| 自动获取地址   | 监听 WalletCreated 事件自动获取钱包地址    | P2  |
| 批量操作     | 支持一次签名执行多个操作                   | P2  |
| Nonce 强制 | 在签名消息中强制包含链上 nonce             | P2  |

---

## 12. 参考资料

- [EIP-7212: Precompile for secp256r1](https://eips.ethereum.org/EIPS/eip-7212)
- [EIP-7951: Precompile for secp256r1 Curve Support](https://eips.ethereum.org/EIPS/eip-7951)
- [WebAuthn 规范](https://www.w3.org/TR/webauthn-2/)
- [Passkey 开发文档](https://passkeys.dev/)
