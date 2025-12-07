# Solidity 开发笔记

本文档记录 Solidity 智能合约开发中的常见问题、最佳实践和技术细节。

---

## 1. ERC20 代币转账的安全调用

### 1.1 问题背景

在 `PasskeyWallet.sol` 第 76 行，我们使用 `call` 而不是直接调用 `IERC20(token).transfer()`：

```solidity
// 我们的写法
(bool success, bytes memory result) = token.call(
abi.encodeWithSignature("transfer(address,uint256)", to, amount)
);
```

为什么不直接写：

```solidity
// 看起来更简洁的写法
IERC20(token).transfer(to, amount);
```

### 1.2 原因：非标准 ERC20 代币

**ERC20 标准定义**：

```solidity
// 标准 ERC20 - transfer 必须返回 bool
function transfer(address to, uint256 amount) external returns (bool);
```

**但有些代币不遵循标准**：

```solidity
// USDT (Tether) 的实现 - 不返回值！
function transfer(address _to, uint _value) public;

// BNB (旧版) 也有类似问题
```

### 1.3 直接调用的问题

```solidity
// 如果 token 是 USDT
IERC20(token).transfer(to, amount);

// Solidity 编译器会生成代码：
// 1. 调用 transfer
// 2. 期望返回 32 字节 (bool)
// 3. 解码返回值

// 但 USDT 不返回任何值！
// → returndatasize() == 0
// → 解码失败
// → 交易 revert！
```

### 1.4 安全的写法

```solidity
function safeTransferERC20(address token, address to, uint256 amount) internal {
    // 使用低级 call
    (bool success, bytes memory result) = token.call(
        abi.encodeWithSignature("transfer(address,uint256)", to, amount)
    );

    // 检查调用是否成功
    require(success, "Transfer call failed");

    // 兼容两种情况：
    // 1. 标准代币：result.length > 0，需要检查返回值
    // 2. 非标准代币 (USDT)：result.length == 0，success 即可
    if (result.length > 0) {
        require(abi.decode(result, (bool)), "Transfer returned false");
    }
}
```

### 1.5 对比表

| 调用方式                       | 标准 ERC20 | USDT 等非标准代币 |
|----------------------------|----------|-------------|
| `IERC20(token).transfer()` | ✅ 正常     | ❌ Revert    |
| `token.call(...)` + 检查     | ✅ 正常     | ✅ 正常        |
| `SafeERC20.safeTransfer()` | ✅ 正常     | ✅ 正常        |

### 1.6 OpenZeppelin SafeERC20

OpenZeppelin 提供了 `SafeERC20` 库，封装了上述逻辑：

```solidity
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MyContract {
    using SafeERC20 for IERC20;

    function transferToken(address token, address to, uint256 amount) external {
        // 内部实现与我们的 call 方式类似
        IERC20(token).safeTransfer(to, amount);
    }
}
```

**SafeERC20 源码核心逻辑**：

```solidity
function safeTransfer(IERC20 token, address to, uint256 value) internal {
    _callOptionalReturn(token, abi.encodeCall(token.transfer, (to, value)));
}

function _callOptionalReturn(IERC20 token, bytes memory data) private {
    bytes memory returndata = address(token).functionCall(data);
    // 允许返回空数据 (非标准代币) 或返回 true (标准代币)
    if (returndata.length > 0) {
        require(abi.decode(returndata, (bool)), "SafeERC20: operation failed");
    }
}
```

### 1.7 哪些代币有这个问题

| 代币            | 问题            | 市值排名  |
|---------------|---------------|-------|
| USDT (Tether) | transfer 不返回值 | Top 3 |
| BNB (旧版)      | transfer 不返回值 | Top 5 |
| OMG           | transfer 不返回值 | -     |

> ⚠️ **重要**：由于 USDT 是交易量最大的稳定币，几乎所有 DeFi 项目都必须处理这个兼容性问题。

### 1.8 最佳实践

1. **永远不要直接调用** `IERC20(token).transfer()`
2. **使用 SafeERC20** 或手动实现 call + 返回值检查
3. **测试非标准代币**：部署前用 USDT 测试

---

## 2. ETH 转账：call 空参数

### 2.1 问题背景

在 `PasskeyWallet.sol` 第 109 行：

```solidity
(bool success, ) = to.call{value : amount}("");
```

为什么 `call` 的参数是空字符串 `""`？

### 2.2 语法解析

```solidity
to.call{value: amount}("")
│         │        │
│         │        └── "" 空字符串 = 无调用数据 (不调用任何函数)
│         └── {value : amount} 发送 amount wei 的 ETH
└── to 目标地址
```

**这是纯 ETH 转账**，不调用目标地址的任何函数。

### 2.3 有参数 vs 无参数对比

```solidity
// 1. 纯 ETH 转账 (不调用函数)
to.call{value: amount}("");
// → 只转 ETH，不执行任何函数
// → 如果 to 是合约，会触发其 receive() 或 fallback()

// 2. 调用函数 + 转 ETH
to.call{value : amount}(abi.encodeWithSignature("deposit()"));
// → 转 ETH 并调用 deposit() 函数

// 3. 只调用函数，不转 ETH
to.call(abi.encodeWithSignature("transfer(address,uint256)", recipient, 100));
// → 只调用 transfer 函数，不转 ETH
```

### 2.4 为什么用 call 而不是 transfer/send

```solidity
// ❌ 旧写法 (不推荐)
payable(to).transfer(amount);  // 只给 2300 gas
payable(to).send(amount);      // 只给 2300 gas

// ✅ 新写法 (推荐)
(bool success,) = to.call{value : amount}("");  // 转发所有剩余 gas
require(success, "ETH transfer failed");
```

| 方式                 | Gas 限制     | 失败处理      | 推荐    |
|--------------------|------------|-----------|-------|
| `transfer()`       | 2300 gas   | 自动 revert | ❌ 已过时 |
| `send()`           | 2300 gas   | 返回 false  | ❌ 已过时 |
| `call{value:}("")` | 无限制 (转发所有) | 返回 false  | ✅ 推荐  |

**为什么 2300 gas 不够？**

Istanbul 硬分叉 (2019) 后，SLOAD 操作的 gas 从 200 涨到 800。很多合约的 `receive()` 函数需要读取存储变量，2300 gas 不够用了。

### 2.5 目标是合约地址时的行为

当 `to` 是合约地址，`call{value:}("")` 会按以下顺序查找：

```
to.call{value: amount}("")
         │
         ▼
┌─────────────────────────────────────┐
│ 1. 合约有 receive() 函数？           │
│    receive() external payable { }   │
│         │                           │
│         ├── 有 → 调用 receive()     │
│         │                           │
│         ▼                           │
│ 2. 合约有 fallback() 函数？          │
│    fallback() external payable { }  │
│         │                           │
│         ├── 有 → 调用 fallback()    │
│         │                           │
│         ▼                           │
│ 3. 都没有 → 交易失败 (revert)        │
└─────────────────────────────────────┘
```

### 2.6 receive 和 fallback 的区别

```solidity
contract Receiver {
    // receive: 专门接收纯 ETH 转账 (msg.data 为空)
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    // fallback: 处理所有未匹配的调用
    // 1. 调用了不存在的函数
    // 2. 没有 receive() 时接收 ETH
    fallback() external payable {
        emit Fallback(msg.sender, msg.value, msg.data);
    }
}
```

**调用路由**：

```
msg.data 是否为空？
    │
    ├── 空 ("")
    │      │
    │      ├── 有 receive() → 调用 receive()
    │      └── 无 receive() → 调用 fallback() (如果有)
    │
    └── 非空 (有函数调用数据)
           │
           ├── 函数存在 → 调用对应函数
           └── 函数不存在 → 调用 fallback() (如果有)
```

### 2.7 完整的安全 ETH 转账模式

```solidity
function safeTransferETH(address to, uint256 amount) internal {
    (bool success,) = to.call{value: amount}("");
    require(success, "ETH transfer failed");
}
```

---

## 3. call vs staticcall vs delegatecall

### 3.1 三种调用方式对比

| 调用方式           | 修改状态  | 发送 ETH | msg.sender | 存储上下文    | 典型用途    |
|----------------|-------|--------|------------|----------|---------|
| `call`         | ✅ 可以  | ✅ 可以   | 调用者        | 被调用合约    | 通用调用    |
| `staticcall`   | ❌ 不可以 | ❌ 不可以  | 调用者        | 被调用合约    | view 函数 |
| `delegatecall` | ✅ 可以  | ❌ 不可以  | 原始调用者      | **当前合约** | 代理模式    |

### 3.2 call - 通用调用

```solidity
// 调用其他合约的函数
(bool success, bytes memory data) = target.call(
abi.encodeWithSignature("transfer(address,uint256)", to, amount)
);

// 发送 ETH
(bool success,) = recipient.call{value : 1 ether}("");
```

### 3.3 staticcall - 只读调用

```solidity
// 调用 view/pure 函数，禁止修改状态
(bool success, bytes memory data) = target.staticcall(
abi.encodeWithSignature("balanceOf(address)", account)
);

// 如果被调用函数尝试修改状态 → revert
```

**用途**：

- 调用预编译合约 (如 P256VERIFY)
- 安全地调用不信任的合约的 view 函数

### 3.4 delegatecall - 代理调用

```solidity
// 在当前合约的存储上下文中执行目标合约的代码
(bool success, bytes memory data) = implementation.delegatecall(
abi.encodeWithSignature("initialize(uint256)", value)
);
```

**特点**：

- `msg.sender` 保持不变（原始调用者）
- `msg.value` 保持不变
- 修改的是**当前合约**的存储，不是目标合约

**用途**：

- 可升级代理合约 (Proxy Pattern)
- 库合约调用

### 3.5 图解存储上下文

```
call:
┌──────────────┐         ┌──────────────┐
│ 合约 A        │  call   │ 合约 B        │
│ storage A    │ ──────→ │ storage B    │  ← 修改 B 的存储
│ msg.sender=X │         │ msg.sender=A │
└──────────────┘         └──────────────┘

delegatecall:
┌──────────────┐              ┌──────────────┐
│ 合约 A        │ delegatecall │ 合约 B (代码)  │
│ storage A    │ ───────────→ │              │
│ msg.sender=X │              │              │
└──────────────┘              └──────────────┘
       ↑
       └── 执行 B 的代码，但修改 A 的存储！
```

---

## 4. abi.encode vs abi.encodePacked

### 4.1 区别

| 方法                 | 填充            | 长度 | 用途          |
|--------------------|---------------|----|-------------|
| `abi.encode`       | 每个参数填充到 32 字节 | 较长 | 函数调用、标准 ABI |
| `abi.encodePacked` | 紧凑编码，无填充      | 较短 | 哈希计算、签名     |

### 4.2 示例

```solidity
address addr = 0x1234567890123456789012345678901234567890;
uint256 num = 1;

// abi.encode: 64 字节
// 0x0000000000000000000000001234567890123456789012345678901234567890
// 0x0000000000000000000000000000000000000000000000000000000000000001
bytes memory encoded = abi.encode(addr, num);

// abi.encodePacked: 52 字节 (20 + 32)
// 0x12345678901234567890123456789012345678900000000000000000000000000000000000000000000000000000000000000001
bytes memory packed = abi.encodePacked(addr, num);
```

### 4.3 使用场景

```solidity
// 函数调用 - 用 abi.encode
token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));

// 计算哈希 - 用 abi.encodePacked (节省 gas)
bytes32 hash = keccak256(abi.encodePacked(a, b, c));

// 预编译合约 - 用 abi.encodePacked (紧凑格式)
P256VERIFY.staticcall(abi.encodePacked(hash, r, s, x, y));
```

### 4.4 注意：encodePacked 的哈希碰撞风险

```solidity
// 危险！可能产生碰撞
abi.encodePacked("ab", "c") == abi.encodePacked("a", "bc")  // 都是 "abc"

// 安全做法：加分隔符或用 abi.encode
abi.encode("ab", "c") != abi.encode("a", "bc")  // 不同
```

---

## 5. CREATE vs CREATE2 合约部署

### 5.1 问题背景

在 `PasskeyWallet.sol` 第 199 行：

```solidity
PasskeyWallet newWallet = new PasskeyWallet{salt: salt}(x, y);
```

`{salt: salt}` 是什么？`PasskeyWallet` 构造函数并没有接收这个参数。

### 5.2 语法解析

```solidity
new PasskeyWallet{salt: salt}(x, y)
//                │           │
//                │           └── 构造函数参数 (传给 PasskeyWallet)
//                └── CREATE2 选项 (传给 EVM 操作码，不是构造函数)
```

`{salt: salt}` 是 **Solidity 的 CREATE2 部署语法**，告诉 EVM 使用 CREATE2 操作码而不是 CREATE。

### 5.3 CREATE vs CREATE2 对比

| 特性 | CREATE | CREATE2 |
|-----|--------|---------|
| EVM 操作码 | 0xF0 | 0xF5 |
| 地址计算 | `keccak256(deployer, nonce)` | `keccak256(0xff, deployer, salt, bytecodeHash)` |
| 地址可预测 | ❌ 依赖 nonce | ✅ 完全确定 |
| Solidity 语法 | `new Contract()` | `new Contract{salt: ...}()` |

### 5.4 地址计算公式

**CREATE:**
```
address = keccak256(rlp([deployer, nonce]))[12:32]
```
- `nonce` 每次部署递增，无法预测

**CREATE2:**
```
address = keccak256(
    0xff,                    // 固定前缀 (区分 CREATE)
    deployerAddress,         // 工厂合约地址
    salt,                    // 用户提供的盐值
    keccak256(bytecode)      // 合约初始化代码哈希
)[12:32]
```
- 所有参数都是已知的，地址完全可预测

### 5.5 代码示例

```solidity
contract PasskeyWalletFactory {
    // 普通部署 (CREATE) - 地址不可预测
    function createWallet(bytes32 x, bytes32 y) external returns (address) {
        PasskeyWallet newWallet = new PasskeyWallet(x, y);
        return address(newWallet);
    }

    // 确定性部署 (CREATE2) - 地址可预测
    function createWalletDeterministic(
        bytes32 x,
        bytes32 y,
        bytes32 salt
    ) external returns (address) {
        PasskeyWallet newWallet = new PasskeyWallet{salt: salt}(x, y);
        return address(newWallet);
    }

    // 提前计算地址 (部署前就能知道)
    function computeWalletAddress(
        bytes32 x,
        bytes32 y,
        bytes32 salt
    ) external view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),              // 工厂地址
                salt,                       // 盐值
                keccak256(abi.encodePacked(
                    type(PasskeyWallet).creationCode,
                    abi.encode(x, y)        // 构造函数参数
                ))
            )
        );
        return address(uint160(uint256(hash)));
    }
}
```

### 5.6 CREATE2 的用途

#### 1. 地址预测
```solidity
// 部署前就知道合约地址
address predicted = factory.computeWalletAddress(x, y, salt);
// 可以显示给用户，让用户提前保存
```

#### 2. 反事实部署 (Counterfactual Deployment)
```solidity
// 1. 先计算地址
address wallet = factory.computeWalletAddress(x, y, salt);

// 2. 往这个地址转账 (合约还不存在！)
payable(wallet).transfer(1 ether);

// 3. 以后再部署合约，资金已经在那里了
factory.createWalletDeterministic(x, y, salt);
```

#### 3. 跨链相同地址
```solidity
// 相同的 factory、salt、bytecode
// → 在 Ethereum、Polygon、Arbitrum 上部署到相同地址
```

#### 4. 合约升级/重部署
```solidity
// 销毁旧合约后，可以用相同 salt 在相同地址重新部署
// (需要 selfdestruct，现已不推荐)
```

### 5.7 注意事项

```solidity
// ⚠️ bytecode 包含构造函数参数！
// 不同的 x, y 会导致不同的地址
new PasskeyWallet{salt: salt}(x1, y1)  // 地址 A
new PasskeyWallet{salt: salt}(x2, y2)  // 地址 B (不同！)

// ⚠️ 相同参数只能部署一次
// 第二次部署会失败 (地址已被占用)
```

### 5.8 Solidity 语法与 EVM 操作码的对应

很多人会问：代码里没有调用 `create2`，怎么就用了 CREATE2？

**答案：`{salt: ...}` 是 Solidity 的语法糖，编译器会自动生成对应的 EVM 操作码。**

```solidity
// Solidity 代码
new PasskeyWallet{salt: salt}(x, y)

// ↓ 编译后生成 CREATE2 操作码 (0xF5)
// 开发者不需要手动调用任何 create2 函数
```

| Solidity 语法 | 编译后的 EVM 操作码 |
|--------------|-----------------|
| `new Contract(args)` | CREATE (0xF0) |
| `new Contract{salt: ...}(args)` | CREATE2 (0xF5) |
| `new Contract{value: ...}(args)` | CREATE (0xF0) + 转 ETH |
| `new Contract{value: ..., salt: ...}(args)` | CREATE2 (0xF5) + 转 ETH |

编译器看到 `{salt: ...}` 就知道要生成 CREATE2 指令。这种设计让开发者不需要关心底层操作码，只需要使用高级语法即可。

### 5.9 EVM 层面的实现

```go
// go-ethereum 中 CREATE2 的地址计算
func CreateAddress2(deployer common.Address, salt [32]byte, inithash []byte) common.Address {
    return common.BytesToAddress(
        crypto.Keccak256(
            []byte{0xff},
            deployer.Bytes(),
            salt[:],
            inithash,  // keccak256(initCode)
        )[12:],
    )
}
```

---

## 6. require vs revert vs assert

### 6.1 对比

| 语句                          | 用途         | Gas 退还     | 错误类型           |
|-----------------------------|------------|------------|----------------|
| `require(condition, "msg")` | 输入验证、前置条件  | ✅ 退还剩余 gas | Error(string)  |
| `revert("msg")`             | 复杂条件下的回滚   | ✅ 退还剩余 gas | Error(string)  |
| `assert(condition)`         | 内部错误、不变量检查 | ❌ 消耗所有 gas | Panic(uint256) |

### 6.2 使用场景

```solidity
function withdraw(uint256 amount) external {
    // require: 验证外部输入
    require(amount > 0, "Amount must be positive");
    require(balances[msg.sender] >= amount, "Insufficient balance");

    // 业务逻辑
    balances[msg.sender] -= amount;

    // assert: 检查不变量 (理论上永远不应该失败)
    assert(totalSupply >= balances[msg.sender]);

    // 复杂条件用 revert
    if (amount > maxWithdraw && !isWhitelisted[msg.sender]) {
        revert("Exceeds limit for non-whitelisted users");
    }
}
```

### 6.3 自定义错误 (Solidity 0.8.4+)

```solidity
// 定义自定义错误 (更省 gas)
error InsufficientBalance(address account, uint256 requested, uint256 available);

function withdraw(uint256 amount) external {
    if (balances[msg.sender] < amount) {
        revert InsufficientBalance(msg.sender, amount, balances[msg.sender]);
    }
    // ...
}
```

---

## 7. 函数可见性

### 7.1 四种可见性

| 可见性        | 外部调用 | 内部调用           | 继承合约 | Gas 成本 |
|------------|------|----------------|------|--------|
| `external` | ✅    | ❌ (需 this.f()) | ❌    | 最低     |
| `public`   | ✅    | ✅              | ✅    | 较高     |
| `internal` | ❌    | ✅              | ✅    | 低      |
| `private`  | ❌    | ✅              | ❌    | 低      |

### 7.2 最佳实践

```solidity
contract MyContract {
    // 只被外部调用 → external (参数直接从 calldata 读取，省 gas)
    function deposit() external payable {}

    // 需要内部和外部都能调用 → public
    function getBalance() public view returns (uint256) {}

    // 只在内部使用 → internal
    function _validateInput(uint256 x) internal pure {}

    // 不想被继承合约访问 → private
    function _secretLogic() private {}
}
```

---

## 8. 常见安全漏洞

### 8.1 重入攻击 (Reentrancy)

```solidity
// ❌ 危险写法
function withdraw() external {
    uint256 amount = balances[msg.sender];
    (bool success,) = msg.sender.call{value: amount}("");  // 攻击者可重入
    require(success);
    balances[msg.sender] = 0;  // 太晚了！
}

// ✅ 安全写法 (Checks-Effects-Interactions)
function withdraw() external {
    uint256 amount = balances[msg.sender];
    balances[msg.sender] = 0;  // 先修改状态
    (bool success,) = msg.sender.call{value: amount}("");  // 再转账
    require(success);
}

// ✅ 或使用 ReentrancyGuard
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

function withdraw() external nonReentrant {
    // ...
}
```

### 8.2 整数溢出 (Solidity < 0.8.0)

```solidity
// Solidity 0.8.0 之前需要 SafeMath
// 0.8.0+ 默认检查溢出

// 如果确定不会溢出，可用 unchecked 节省 gas
unchecked {
counter++;  // 不检查溢出
}
```

### 8.3 tx.origin 钓鱼

```solidity
// ❌ 危险
require(tx.origin == owner);  // 攻击者可通过中间合约绕过

// ✅ 安全
require(msg.sender == owner);
```

---

## 9. Gas 优化技巧

### 9.1 存储优化

```solidity
// ❌ 每个变量占用一个 slot (32 字节)
uint256 a;  // slot 0
uint256 b;  // slot 1
uint8 c;    // slot 2

// ✅ 打包变量 (一个 slot 放多个小变量)
uint128 a;  // slot 0 (前 16 字节)
uint128 b;  // slot 0 (后 16 字节)
uint8 c;    // slot 1
```

### 9.2 使用 calldata

```solidity
// ❌ memory: 复制参数到内存
function process(bytes memory data) external {}

// ✅ calldata: 直接读取，不复制 (只能用于 external)
function process(bytes calldata data) external {}
```

### 9.3 短路求值

```solidity
// 如果 a 为 false，不会计算 expensiveCheck()
if (a && expensiveCheck()) {}

// 把便宜的检查放前面
require(amount > 0 && balances[msg.sender] >= amount);
```

### 9.4 避免重复读取存储

```solidity
// ❌ 多次读取存储 (每次 2100 gas)
function bad() external {
    if (balances[msg.sender] > 0) {
        uint256 amount = balances[msg.sender];
        // ...
    }
}

// ✅ 缓存到内存
function good() external {
    uint256 balance = balances[msg.sender];  // 读一次
    if (balance > 0) {
        // 使用 balance
    }
}
```

---

## 附录：参考资料

- [Solidity 官方文档](https://docs.soliditylang.org/)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [ERC20 标准 (EIP-20)](https://eips.ethereum.org/EIPS/eip-20)
- [Solidity 安全最佳实践](https://consensys.github.io/smart-contract-best-practices/)
