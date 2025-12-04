# Passkey Wallet

基于指纹/Face ID (Passkey) 的以太坊智能合约钱包。

## 项目结构

```
secp256R1-demo/
├── contract/
│   ├── PasskeyWallet.sol     # 智能钱包 + 工厂合约 (必需)
│   └── TestToken.sol         # 测试代币 (必需)
├── web/
│   └── index.html            # 前端页面
├── main.go                   # Go 后端服务
├── config.yaml               # 配置文件
├── go.mod
├── docs/
│   └── DESIGN.md             # 详细设计文档
└── README.md
```

## 快速开始

### 1. 部署合约

使用 Remix IDE 部署到 Sepolia:

1. 打开 https://remix.ethereum.org
2. 部署 `PasskeyWalletFactory` (无构造参数)
3. 部署 `TestToken` (初始供应量，如 1000000)

### 2. 配置

编辑 `config.yaml`:

```yaml
rpc: "https://ethereum-sepolia-rpc.publicnode.com"
chain_id: 11155111
contract: "Factory合约地址"
private_key: "中继账户私钥"
port: 8080
test_token: "TestToken合约地址"
```

### 3. 启动服务

```bash
go mod tidy
go run main.go
```

访问 http://localhost:8080

### 4. 使用流程

1. **注册 Passkey** - 点击"注册 Passkey 并创建钱包"，用指纹/Face ID 验证
2. **获取钱包地址** - 从 Etherscan 交易日志的 WalletCreated 事件中获取
3. **充值代币** - 连接 MetaMask，领取测试币并转入钱包
4. **转账** - 填写接收地址和金额，用指纹签名

## 技术架构

```
用户 (指纹/Face ID)
        ↓
   Passkey 签名 (secp256r1)
        ↓
   后端中继 (支付 Gas)
        ↓
   PasskeyWallet 合约 → P256VERIFY 预编译 (0x100)
        ↓
   验证通过 → 执行转账
```

## 与传统 EOA 的区别

| 项目 | 传统 EOA | Passkey 钱包 |
|------|----------|--------------|
| 私钥位置 | 用户管理 | 设备安全芯片 |
| 私钥曲线 | secp256k1 | secp256r1 |
| 资产位置 | EOA 地址 | 智能合约 |
| 签名方式 | 钱包软件 | 指纹/Face ID |
| 助记词 | 需要备份 | 不需要 |

## 注意事项

1. **Passkey 绑定**: 每个钱包绑定一个 Passkey，用其他 Passkey 签名会失败
2. **页面刷新**: Passkey 数据保存在 localStorage，刷新后仍可使用
3. **签名失败**: 如遇 "Invalid signature"，清除 localStorage 后重新创建钱包

## 相关资源

- [EIP-7212/7951: P256VERIFY](https://eips.ethereum.org/EIPS/eip-7212)
- [WebAuthn 规范](https://www.w3.org/TR/webauthn-2/)
- [详细设计文档](docs/DESIGN.md)
