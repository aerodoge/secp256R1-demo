package main

import (
	"context"
	"crypto/ecdsa"
	"embed"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"os"
	"strings"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	"gopkg.in/yaml.v3"
)

//go:embed web/index.html
var webFS embed.FS

// Config 配置文件结构
type Config struct {
	RPC        string `yaml:"rpc"`
	ChainID    int64  `yaml:"chain_id"`
	Contract   string `yaml:"contract"`
	PrivateKey string `yaml:"private_key"`
	Port       int    `yaml:"port"`
}

// PasskeyData 前端导出的数据结构
type PasskeyData struct {
	PublicKey struct {
		X string `json:"x"`
		Y string `json:"y"`
	} `json:"publicKey"`
	Signature struct {
		R string `json:"r"`
		S string `json:"s"`
	} `json:"signature"`
	WebAuthn struct {
		AuthenticatorData string `json:"authenticatorData"`
		ClientDataJSON    string `json:"clientDataJSON"`
		MessageHash       string `json:"messageHash"`
	} `json:"webauthn"`
}

// ERC20TransferRequest ERC20 转账请求
type ERC20TransferRequest struct {
	PasskeyData
	Wallet string `json:"wallet"` // 用户的 PasskeyWallet 合约地址
	Token  string `json:"token"`  // ERC20 代币合约地址
	To     string `json:"to"`     // 接收地址
	Amount string `json:"amount"` // 转账金额 (wei 单位)
}

// CreateWalletRequest 创建钱包请求
type CreateWalletRequest struct {
	PublicKey struct {
		X string `json:"x"`
		Y string `json:"y"`
	} `json:"publicKey"`
}

// APIResponse API 响应结构
type APIResponse struct {
	Success bool   `json:"success"`
	Message string `json:"message"`
	TxHash  string `json:"txHash,omitempty"`
	Valid   *bool  `json:"valid,omitempty"`
}

// PasskeyWalletFactory ABI
const factoryABI = `[
	{
		"inputs": [
			{"name": "x", "type": "bytes32"},
			{"name": "y", "type": "bytes32"}
		],
		"name": "createWallet",
		"outputs": [{"name": "wallet", "type": "address"}],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [{"name": "", "type": "address"}],
		"name": "wallets",
		"outputs": [{"type": "address"}],
		"stateMutability": "view",
		"type": "function"
	}
]`

// PasskeyWallet ABI
const walletABI = `[
	{
		"inputs": [
			{"name": "token", "type": "address"},
			{"name": "to", "type": "address"},
			{"name": "amount", "type": "uint256"},
			{"name": "hash", "type": "bytes32"},
			{"name": "r", "type": "bytes32"},
			{"name": "s", "type": "bytes32"}
		],
		"name": "transferERC20",
		"outputs": [],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [
			{"name": "hash", "type": "bytes32"},
			{"name": "r", "type": "bytes32"},
			{"name": "s", "type": "bytes32"}
		],
		"name": "verifySignature",
		"outputs": [{"type": "bool"}],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "getPublicKey",
		"outputs": [
			{"name": "x", "type": "bytes32"},
			{"name": "y", "type": "bytes32"}
		],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "nonce",
		"outputs": [{"type": "uint256"}],
		"stateMutability": "view",
		"type": "function"
	}
]`

// ERC20 ABI (只需要 transfer 和 balanceOf)
const erc20ABI = `[
	{
		"inputs": [
			{"name": "to", "type": "address"},
			{"name": "amount", "type": "uint256"}
		],
		"name": "transfer",
		"outputs": [{"type": "bool"}],
		"stateMutability": "nonpayable",
		"type": "function"
	},
	{
		"inputs": [{"name": "account", "type": "address"}],
		"name": "balanceOf",
		"outputs": [{"type": "uint256"}],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "decimals",
		"outputs": [{"type": "uint8"}],
		"stateMutability": "view",
		"type": "function"
	},
	{
		"inputs": [],
		"name": "symbol",
		"outputs": [{"type": "string"}],
		"stateMutability": "view",
		"type": "function"
	}
]`

var (
	config     *Config
	ethClient  *ethclient.Client
	privateKey *ecdsa.PrivateKey
	chainID    *big.Int
)

func loadConfig(filename string) (*Config, error) {
	data, err := os.ReadFile(filename)
	if err != nil {
		return nil, err
	}

	var cfg Config
	err = yaml.Unmarshal(data, &cfg)
	if err != nil {
		return nil, err
	}

	return &cfg, nil
}

func main() {
	configFile := flag.String("config", "config.yaml", "配置文件路径")
	action := flag.String("action", "server", "操作: server, call, verify")
	flag.Parse()

	var err error
	config, err = loadConfig(*configFile)
	if err != nil {
		log.Fatalf("加载配置文件失败: %v", err)
	}

	if config.RPC == "" {
		config.RPC = "https://ethereum-sepolia-rpc.publicnode.com"
	}
	if config.Port == 0 {
		config.Port = 8080
	}

	ethClient, err = ethclient.Dial(config.RPC)
	if err != nil {
		log.Fatalf("连接节点失败: %v", err)
	}
	defer ethClient.Close()

	chainID, err = ethClient.NetworkID(context.Background())
	if err != nil {
		log.Fatalf("获取链 ID 失败: %v", err)
	}

	if config.PrivateKey != "" {
		privateKey, err = crypto.HexToECDSA(strings.TrimPrefix(config.PrivateKey, "0x"))
		if err != nil {
			log.Fatalf("私钥格式错误: %v", err)
		}
	}

	fmt.Printf("链 ID: %s\n", chainID.String())
	fmt.Printf("合约地址: %s\n", config.Contract)
	if privateKey != nil {
		fromAddress := crypto.PubkeyToAddress(privateKey.PublicKey)
		fmt.Printf("中继账户: %s\n", fromAddress.Hex())
	}

	switch *action {
	case "server":
		startServer()
	case "call":
		runCall()
	case "verify":
		runVerify()
	default:
		log.Fatalf("未知操作: %s", *action)
	}
}

func startServer() {
	http.HandleFunc("/", handleIndex)
	http.HandleFunc("/api/verify", handleVerify)
	http.HandleFunc("/api/send", handleSend)
	http.HandleFunc("/api/transfer", handleTransfer)
	http.HandleFunc("/api/balance", handleBalance)
	http.HandleFunc("/api/config", handleConfig)
	http.HandleFunc("/api/create-wallet", handleCreateWallet)

	addr := fmt.Sprintf(":%d", config.Port)
	fmt.Printf("\n服务器启动: http://localhost%s\n", addr)
	fmt.Println("打开浏览器访问上述地址，使用指纹/Face ID 进行签名测试")

	log.Fatal(http.ListenAndServe(addr, nil))
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	data, err := webFS.ReadFile("web/index.html")
	if err != nil {
		http.Error(w, "页面加载失败", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write(data)
}

func handleConfig(w http.ResponseWriter, r *http.Request) {
	setCORSHeaders(w)
	w.Header().Set("Content-Type", "application/json")

	json.NewEncoder(w).Encode(map[string]interface{}{
		"contract": config.Contract,
		"chainId":  chainID.String(),
		"rpc":      config.RPC,
	})
}

func handleVerify(w http.ResponseWriter, r *http.Request) {
	setCORSHeaders(w)
	w.Header().Set("Content-Type", "application/json")

	if r.Method == "OPTIONS" {
		return
	}
	if r.Method != "POST" {
		sendError(w, "只支持 POST 请求")
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		sendError(w, "读取请求失败")
		return
	}

	var data PasskeyData
	if err := json.Unmarshal(body, &data); err != nil {
		sendError(w, "JSON 解析失败: "+err.Error())
		return
	}

	// PasskeyWallet 模式下，验证需要通过钱包合约
	sendError(w, "请使用 /api/transfer 接口，验证集成在转账流程中")
}

func handleSend(w http.ResponseWriter, r *http.Request) {
	setCORSHeaders(w)
	w.Header().Set("Content-Type", "application/json")

	if r.Method == "OPTIONS" {
		return
	}
	if r.Method != "POST" {
		sendError(w, "只支持 POST 请求")
		return
	}
	if privateKey == nil {
		sendError(w, "未配置私钥，无法发送交易")
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		sendError(w, "读取请求失败")
		return
	}

	var data PasskeyData
	if err := json.Unmarshal(body, &data); err != nil {
		sendError(w, "JSON 解析失败: "+err.Error())
		return
	}

	// PasskeyWallet 模式下，请使用 /api/transfer
	sendError(w, "请使用 /api/transfer 接口")
}

// handleTransfer 处理 ERC20 转账请求
func handleTransfer(w http.ResponseWriter, r *http.Request) {
	setCORSHeaders(w)
	w.Header().Set("Content-Type", "application/json")

	if r.Method == "OPTIONS" {
		return
	}
	if r.Method != "POST" {
		sendError(w, "只支持 POST 请求")
		return
	}
	if privateKey == nil {
		sendError(w, "未配置私钥，无法发送交易")
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		sendError(w, "读取请求失败")
		return
	}

	var req ERC20TransferRequest
	if err := json.Unmarshal(body, &req); err != nil {
		sendError(w, "JSON 解析失败: "+err.Error())
		return
	}

	// 验证参数
	if req.Wallet == "" || req.Token == "" || req.To == "" || req.Amount == "" {
		sendError(w, "缺少必要参数: wallet, token, to, amount")
		return
	}

	// 发送 ERC20 转账交易
	txHash, err := sendERC20Transfer(&req)
	if err != nil {
		sendError(w, "ERC20 转账失败: "+err.Error())
		return
	}

	json.NewEncoder(w).Encode(APIResponse{
		Success: true,
		Message: "ERC20 转账交易已发送",
		TxHash:  txHash.Hex(),
	})
}

// handleBalance 查询 ERC20 余额
func handleBalance(w http.ResponseWriter, r *http.Request) {
	setCORSHeaders(w)
	w.Header().Set("Content-Type", "application/json")

	if r.Method == "OPTIONS" {
		return
	}

	token := r.URL.Query().Get("token")
	address := r.URL.Query().Get("address")

	if token == "" || address == "" {
		sendError(w, "缺少参数: token, address")
		return
	}

	balance, symbol, decimals, err := getERC20Balance(token, address)
	if err != nil {
		sendError(w, "查询余额失败: "+err.Error())
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"success":  true,
		"balance":  balance.String(),
		"symbol":   symbol,
		"decimals": decimals,
	})
}

func setCORSHeaders(w http.ResponseWriter) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
}

func sendError(w http.ResponseWriter, msg string) {
	json.NewEncoder(w).Encode(APIResponse{
		Success: false,
		Message: msg,
	})
}

func verifySignatureCall(data *PasskeyData, walletAddr string) (bool, error) {
	hash := hexToBytes32(data.WebAuthn.MessageHash)
	r := hexToBytes32(data.Signature.R)
	s := hexToBytes32(data.Signature.S)

	parsedABI, _ := abi.JSON(strings.NewReader(walletABI))
	callData, err := parsedABI.Pack("verifySignature", hash, r, s)
	if err != nil {
		return false, fmt.Errorf("编码调用数据失败: %v", err)
	}

	wallet := common.HexToAddress(walletAddr)
	result, err := ethClient.CallContract(context.Background(), ethereum.CallMsg{
		To:   &wallet,
		Data: callData,
	}, nil)
	if err != nil {
		return false, fmt.Errorf("调用合约失败: %v", err)
	}

	var valid bool
	err = parsedABI.UnpackIntoInterface(&valid, "verifySignature", result)
	if err != nil {
		return false, fmt.Errorf("解析结果失败: %v", err)
	}

	return valid, nil
}

func sendVerifyTransaction(data *PasskeyData, walletAddr string) (common.Hash, error) {
	hash := hexToBytes32(data.WebAuthn.MessageHash)
	r := hexToBytes32(data.Signature.R)
	s := hexToBytes32(data.Signature.S)

	parsedABI, _ := abi.JSON(strings.NewReader(walletABI))
	callData, err := parsedABI.Pack("verifySignature", hash, r, s)
	if err != nil {
		return common.Hash{}, fmt.Errorf("编码调用数据失败: %v", err)
	}

	return sendTransaction(common.HexToAddress(walletAddr), big.NewInt(0), callData)
}

// handleCreateWallet 创建 PasskeyWallet
func handleCreateWallet(w http.ResponseWriter, r *http.Request) {
	setCORSHeaders(w)
	w.Header().Set("Content-Type", "application/json")

	if r.Method == "OPTIONS" {
		return
	}
	if r.Method != "POST" {
		sendError(w, "只支持 POST 请求")
		return
	}
	if privateKey == nil {
		sendError(w, "未配置私钥，无法发送交易")
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		sendError(w, "读取请求失败")
		return
	}

	var req CreateWalletRequest
	if err := json.Unmarshal(body, &req); err != nil {
		sendError(w, "JSON 解析失败: "+err.Error())
		return
	}

	x := hexToBytes32(req.PublicKey.X)
	y := hexToBytes32(req.PublicKey.Y)

	// 调用 Factory.createWallet(x, y)
	parsedABI, _ := abi.JSON(strings.NewReader(factoryABI))
	callData, err := parsedABI.Pack("createWallet", x, y)
	if err != nil {
		sendError(w, "编码调用数据失败: "+err.Error())
		return
	}

	txHash, err := sendTransaction(common.HexToAddress(config.Contract), big.NewInt(0), callData)
	if err != nil {
		sendError(w, "创建钱包失败: "+err.Error())
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"success": true,
		"message": "钱包创建交易已发送，请等待确认后查询钱包地址",
		"txHash":  txHash.Hex(),
	})
}

// sendERC20Transfer 发送 ERC20 转账交易 (调用 PasskeyWallet.transferERC20)
func sendERC20Transfer(req *ERC20TransferRequest) (common.Hash, error) {
	// 解析参数
	wallet := common.HexToAddress(req.Wallet)
	token := common.HexToAddress(req.Token)
	to := common.HexToAddress(req.To)
	amount, ok := new(big.Int).SetString(req.Amount, 10)
	if !ok {
		return common.Hash{}, fmt.Errorf("金额格式错误")
	}

	hash := hexToBytes32(req.WebAuthn.MessageHash)
	r := hexToBytes32(req.Signature.R)
	s := hexToBytes32(req.Signature.S)

	// 调用 PasskeyWallet.transferERC20(token, to, amount, hash, r, s)
	parsedABI, _ := abi.JSON(strings.NewReader(walletABI))
	callData, err := parsedABI.Pack("transferERC20",
		token, to, amount, hash, r, s)
	if err != nil {
		return common.Hash{}, fmt.Errorf("编码调用数据失败: %v", err)
	}

	// 发送到用户的钱包合约地址
	return sendTransaction(wallet, big.NewInt(0), callData)
}

// getERC20Balance 查询 ERC20 余额
func getERC20Balance(tokenAddr, userAddr string) (*big.Int, string, uint8, error) {
	token := common.HexToAddress(tokenAddr)
	user := common.HexToAddress(userAddr)

	parsedABI, _ := abi.JSON(strings.NewReader(erc20ABI))

	// 查询余额
	balanceData, _ := parsedABI.Pack("balanceOf", user)
	balanceResult, err := ethClient.CallContract(context.Background(), ethereum.CallMsg{
		To:   &token,
		Data: balanceData,
	}, nil)
	if err != nil {
		return nil, "", 0, err
	}

	var balance *big.Int
	parsedABI.UnpackIntoInterface(&balance, "balanceOf", balanceResult)

	// 查询符号
	symbolData, _ := parsedABI.Pack("symbol")
	symbolResult, _ := ethClient.CallContract(context.Background(), ethereum.CallMsg{
		To:   &token,
		Data: symbolData,
	}, nil)
	var symbol string
	parsedABI.UnpackIntoInterface(&symbol, "symbol", symbolResult)

	// 查询精度
	decimalsData, _ := parsedABI.Pack("decimals")
	decimalsResult, _ := ethClient.CallContract(context.Background(), ethereum.CallMsg{
		To:   &token,
		Data: decimalsData,
	}, nil)
	var decimals uint8
	parsedABI.UnpackIntoInterface(&decimals, "decimals", decimalsResult)

	return balance, symbol, decimals, nil
}

func sendTransaction(to common.Address, value *big.Int, data []byte) (common.Hash, error) {
	fromAddress := crypto.PubkeyToAddress(privateKey.PublicKey)

	nonce, err := ethClient.PendingNonceAt(context.Background(), fromAddress)
	if err != nil {
		return common.Hash{}, fmt.Errorf("获取 nonce 失败: %v", err)
	}

	gasPrice, err := ethClient.SuggestGasPrice(context.Background())
	if err != nil {
		return common.Hash{}, fmt.Errorf("获取 gas price 失败: %v", err)
	}

	gasLimit, err := ethClient.EstimateGas(context.Background(), ethereum.CallMsg{
		From:  fromAddress,
		To:    &to,
		Value: value,
		Data:  data,
	})
	if err != nil {
		gasLimit = 300000 // ERC20 转账可能需要更多 gas
	}

	tx := types.NewTransaction(nonce, to, value, gasLimit, gasPrice, data)
	signedTx, err := types.SignTx(tx, types.NewEIP155Signer(chainID), privateKey)
	if err != nil {
		return common.Hash{}, fmt.Errorf("签名交易失败: %v", err)
	}

	err = ethClient.SendTransaction(context.Background(), signedTx)
	if err != nil {
		return common.Hash{}, fmt.Errorf("发送交易失败: %v", err)
	}

	return signedTx.Hash(), nil
}

func runCall() {
	fmt.Println("PasskeyWallet 模式下，请使用 Web 界面进行操作")
	fmt.Println("启动服务: go run main.go")
	fmt.Println("访问: http://localhost:8080")
}

func runVerify() {
	fmt.Println("PasskeyWallet 模式下，请使用 Web 界面进行操作")
	fmt.Println("启动服务: go run main.go")
	fmt.Println("访问: http://localhost:8080")
}

func loadPasskeyData(filename string) (*PasskeyData, error) {
	file, err := os.ReadFile(filename)
	if err != nil {
		return nil, err
	}

	var data PasskeyData
	err = json.Unmarshal(file, &data)
	if err != nil {
		return nil, err
	}

	return &data, nil
}

func hexToBytes32(s string) [32]byte {
	s = strings.TrimPrefix(s, "0x")
	b, _ := hex.DecodeString(s)
	var result [32]byte
	copy(result[32-len(b):], b)
	return result
}
