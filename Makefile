# Passkey Wallet - Makefile

# 变量定义
APP_NAME := p256demo
BUILD_DIR := build
GO := go
GOFLAGS := -ldflags="-s -w"

# 版本信息
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
BUILD_TIME := $(shell date -u '+%Y-%m-%d_%H:%M:%S')
LDFLAGS := -ldflags="-s -w -X main.Version=$(VERSION) -X main.BuildTime=$(BUILD_TIME)"

# 默认目标
.PHONY: all
all: build

# 编译
.PHONY: build
build:
	@mkdir -p $(BUILD_DIR)
	$(GO) build $(LDFLAGS) -o $(BUILD_DIR)/$(APP_NAME) .

# 开发模式运行
.PHONY: run
run:
	$(GO) run .

# 清理
.PHONY: clean
clean:
	rm -rf $(BUILD_DIR)
	$(GO) clean

# 安装依赖
.PHONY: deps
deps:
	$(GO) mod tidy
	$(GO) mod download

# 更新依赖
.PHONY: update
update:
	$(GO) get -u ./...
	$(GO) mod tidy

# 格式化代码
.PHONY: fmt
fmt:
	$(GO) fmt ./...

# 代码检查
.PHONY: lint
lint:
	@if command -v golangci-lint >/dev/null 2>&1; then \
		golangci-lint run; \
	else \
		echo "golangci-lint not installed, skipping..."; \
	fi

# 运行测试
.PHONY: test
test:
	$(GO) test -v ./...

# 交叉编译 - Linux
.PHONY: build-linux
build-linux:
	@mkdir -p $(BUILD_DIR)
	GOOS=linux GOARCH=amd64 $(GO) build $(LDFLAGS) -o $(BUILD_DIR)/$(APP_NAME)-linux-amd64 .
	GOOS=linux GOARCH=arm64 $(GO) build $(LDFLAGS) -o $(BUILD_DIR)/$(APP_NAME)-linux-arm64 .

# 交叉编译 - Windows
.PHONY: build-windows
build-windows:
	@mkdir -p $(BUILD_DIR)
	GOOS=windows GOARCH=amd64 $(GO) build $(LDFLAGS) -o $(BUILD_DIR)/$(APP_NAME)-windows-amd64.exe .

# 交叉编译 - macOS
.PHONY: build-darwin
build-darwin:
	@mkdir -p $(BUILD_DIR)
	GOOS=darwin GOARCH=amd64 $(GO) build $(LDFLAGS) -o $(BUILD_DIR)/$(APP_NAME)-darwin-amd64 .
	GOOS=darwin GOARCH=arm64 $(GO) build $(LDFLAGS) -o $(BUILD_DIR)/$(APP_NAME)-darwin-arm64 .

# 编译所有平台
.PHONY: build-all
build-all: build-linux build-windows build-darwin

# Docker 构建
.PHONY: docker-build
docker-build:
	docker build -t $(APP_NAME):$(VERSION) .

# 帮助
.PHONY: help
help:
	@echo "Passkey Wallet - Makefile 命令"
	@echo ""
	@echo "用法: make [target]"
	@echo ""
	@echo "目标:"
	@echo "  build         编译项目 (输出到 build/)"
	@echo "  run           开发模式运行"
	@echo "  clean         清理构建产物"
	@echo "  deps          安装/整理依赖"
	@echo "  update        更新依赖"
	@echo "  fmt           格式化代码"
	@echo "  lint          代码检查 (需要 golangci-lint)"
	@echo "  test          运行测试"
	@echo ""
	@echo "交叉编译:"
	@echo "  build-linux   编译 Linux 版本 (amd64, arm64)"
	@echo "  build-windows 编译 Windows 版本 (amd64)"
	@echo "  build-darwin  编译 macOS 版本 (amd64, arm64)"
	@echo "  build-all     编译所有平台"
	@echo ""
	@echo "Docker:"
	@echo "  docker-build  构建 Docker 镜像"
	@echo ""
	@echo "变量:"
	@echo "  VERSION=$(VERSION)"
	@echo "  BUILD_TIME=$(BUILD_TIME)"
