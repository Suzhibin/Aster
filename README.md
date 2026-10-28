# Aster

> 一个 AI 聊天客户端，主打**多模型接入、流式对话、本地知识库（项目）与长期记忆**，业务层在两端共享。

<p align="center">
  <img src="Screenshots/Result%20Mac.png" alt="Aster 在 Mac 与 iPhone 上的界面：会话列表、Markdown 与公式渲染、语音通话" width="860">
</p>

Aster 以「一个 Xcode 工程、两个 App Target」的形态同时覆盖 iPhone / iPad 与 Mac：iOS 端沿用成熟的 UIKit，macOS 端用 SwiftUI 重写界面，而**会话管理、Provider、Markdown 渲染、附件、长期记忆、联网检索等业务逻辑全部抽进本地 SwiftPM 包 `AsterCore`，两端共用同一份代码**。

---

## 功能特性

- **流式对话（SSE）**：基于自研 SSE 客户端逐字输出，支持思考过程（reasoning）增量与代码块高亮。
- **多模型接入**：内置 DeepSeek、智谱 GLM、Kimi、豆包、MiniMax 等 OpenAI 兼容平台，并支持**自定义 OpenAI 兼容端点**。
- **模型与配置**：模型管理、切换、自定义模型（API Key / 地址 / 模型名），配置隔离在沙盒内。
- **项目（本地知识库）**：L1 分组 / L2 资料 / L3 指令三级结构，可在对话中通过 `@` 引用项目资料参与检索。
- **联网检索（RAG）**：发送前检索（非 function calling），默认关闭，可在输入栏开关。
- **长期记忆**：自动抽取对话要点存入本地，按需注入系统提示，开关独立（抽取 / 注入可分别控制）。
- **语音**：语音输入（录音 + 波形 + 本地识别）、沉浸式通话页、TTS 朗读。
- **文件与网页**：文件预览（图片 / 视频 / 文档 / 代码）、应用内网页浏览（链接自动识别、Mac 右侧面板 / iOS Push 打开）。
- **国际化与外观**：多语言切换、浅色 / 深色 / 跟随系统三档外观。
- **通知与隐私**：本地通知偏好、API Key 仅存于沙盒 `Documents/models.json`，不上传、不入仓库。

---

## 系统要求

| 平台 | 最低版本 |
| --- | --- |
| iOS / iPadOS | 15.0+ |
| macOS | 14.0+ |
构建工具：Xcode27.0（Swift 5.9+，SwiftPM 管理远程依赖）。

---

## 快速开始

```bash
# 1. 克隆仓库
git clone https://github.com/Suzhibin/Aster
cd Aster

# 2. 打开工程（首次会联网解析 SwiftPM 依赖，网络慢时请耐心等待）
open Aster.xcodeproj
```

在 Xcode 中：

1. 选择 Scheme：**`Aster`**（iOS 模拟器 / 真机）或 **`AsterMac`**（My Mac）。
2. `⌘R` 构建运行。
3. 首次启动需在 App 内 **模型配置 → 添加模型** 填写 API Key 与端点（沙盒隔离，存于 `Documents/models.json`，不随仓库分发）。

> ⚠️ SPM 依赖为远程库，首次解析需联网克隆（个别库在弱网下可能较慢）。若 Xcode 报「解析失败」，可执行 `File → Packages → Reset Package Caches` 后重试。

---

## 许可证

本项目基于 **MIT License** 开源。详情见 [LICENSE](./LICENSE)。

---

<p align="center">Built with Swift · iOS 15+ / macOS 14+</p>
