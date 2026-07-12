# openBuilder

> 面向所有 builder（而非仅 coder）的开源友好 AI Agent 手机客户端。
> An open-source-friendly mobile client for **all builders** (not just coders) — your AI agent, in your pocket.

[English](#english) · [中文](#中文)

---

## 中文

### 项目目标

openBuilder 的目标是创造一个**面向所有 builder（而非仅 coder）** 的开源友好的 AI Agent 手机客户端。

我们希望把 AI Agent 的能力从桌面带到手机：无论是写代码、整理资料、跑自动化任务，还是查看 Agent 的工作进度，你都可以在手机上随时随地进行，而不必绑定到某一家闭源的商业服务。

当前版本仅对接 **opencode** 这一开源个人 Agent；未来会逐步接入更多优秀的开源个人 Agent，让同一个客户端成为你与各类 Agent 协作的统一入口。

### 功能简介

openBuilder 是 opencode 远程服务器的**瘦客户端**（以只读 + 轻交互为主），通过局域网 mDNS / Tailscale 连接你自己的 opencode 服务。主要功能包括：

- **会话管理**：跨项目/工作区的全局会话列表，实时查看 Agent 的状态（idle / busy / retry）与消息流。
- **流式对话**：基于 SSE 实时接收 Agent 回复，支持打字机式流式渲染、任务进度（todo）与权限卡片。
- **项目与 Worktree**：浏览项目（仓库）、按 git worktree 分段查看会话，支持并行任务的工作区切换。
- **Diff 查看**：只读查看 Agent 改动的代码 diff，行级增删高亮，按文件切换。
- **文件浏览**：查看文件树与文件内容、搜索文件与符号。
- **下指令**：在会话中发送消息、斜杠命令与 shell 指令。
- **连接与发现**：自动通过 mDNS 发现局域网内的 opencode 服务，也支持手动填写 Tailscale / IP 连接，连接配置安全存储于本地。
- **设置**：服务端状态、服务器管理、主题（Material 3 深浅色跟随系统）。

平台：Android + iOS（Flutter 单代码库）。

### 使用方法（构建）

#### 环境要求

- [Flutter](https://docs.flutter.dev/) **3.44.x**（本项目 Dart SDK 约束为 `^3.12.2`；CI 使用 `3.44.6`）
- 一台已运行 `opencode serve` 的远程服务器（通过局域网或 Tailscale 可达）

#### 安装依赖与运行

```bash
# 拉取依赖
flutter pub get

# 启动调试应用（连接真机 / 模拟器 / 桌面）
flutter run
```

首次启动会进入欢迎页，按提示「添加服务器」——可自动发现局域网内的 opencode 服务，或手动填写主机、端口、用户名/密码与默认工作目录。连接测试会返回服务端版本，确认后即可进入主界面。

#### 构建安装包

```bash
# Android 调试包
flutter build apk --debug

# Android 发布包
flutter build apk --release

# iOS（需 macOS + Xcode）
flutter build ios --release
```

#### 代码质量

```bash
# 静态分析（CI 以 --fatal-infos 严格门禁）
flutter analyze --fatal-infos

# 运行测试
flutter test
```

#### API 客户端说明

本项目不依赖官方 JS SDK，而是基于 opencode 的 OpenAPI 3.1 spec **手写 Dart 客户端**（`lib/data/api/opencode_client.dart`）。如需刷新对齐的 spec 参考实现：

```bash
bash tool/gen_client.sh
```

生成结果仅作为一致性参考，不接入 App。

---

## English

### Project Goal

openBuilder aims to create an **open-source-friendly mobile client for all builders — not just coders**.

We want to bring AI agent capabilities from the desktop to your phone. Whether you're writing code, organizing information, running automation, or simply checking on an agent's progress, you should be able to do it anywhere, without being locked into a closed commercial service.

The current version only supports **opencode**, an open-source personal agent. In the future we plan to integrate more great open-source personal agents, turning this single client into a unified entry point for collaborating with all kinds of agents.

### Features

openBuilder is a **thin client** for the remote opencode server (read-mostly, with light interaction), connecting to your own opencode instance over LAN mDNS / Tailscale. Key features:

- **Session management**: a global session list spanning projects/workspaces, with real-time agent status (idle / busy / retry) and message streams.
- **Streaming conversation**: real-time agent replies over SSE, with typewriter-style streaming, todo progress, and permission cards.
- **Projects & Worktrees**: browse projects (repositories), view sessions segmented by git worktree, and switch workspaces for parallel tasks.
- **Diff viewer**: read-only code diffs with line-level add/delete highlighting and per-file switching.
- **File browser**: browse the file tree and file contents, search files and symbols.
- **Send instructions**: post messages, slash commands, and shell commands in a session.
- **Connection & discovery**: auto-discover opencode over mDNS on the LAN, or manually enter Tailscale / IP connections; connection config is stored securely on device.
- **Settings**: server status, server management, theme (Material 3 light/dark, follows system).

Platforms: Android + iOS (single Flutter codebase).

### How to Build & Use

#### Requirements

- [Flutter](https://docs.flutter.dev/) **3.44.x** (this project pins Dart SDK `^3.12.2`; CI uses `3.44.6`)
- A remote server running `opencode serve`, reachable over LAN or Tailscale

#### Install dependencies & run

```bash
# Get dependencies
flutter pub get

# Launch the debug app (physical device / emulator / desktop)
flutter run
```

On first launch you'll see a welcome screen. Tap "Add server" to auto-discover an opencode instance on your LAN via mDNS, or manually enter host, port, username/password, and a default working directory. A connection test returns the server version — once confirmed, you'll enter the main interface.

#### Build a release package

```bash
# Android debug build
flutter build apk --debug

# Android release build
flutter build apk --release

# iOS (requires macOS + Xcode)
flutter build ios --release
```

#### Code quality

```bash
# Static analysis (CI gate is strict with --fatal-infos)
flutter analyze --fatal-infos

# Run tests
flutter test
```

#### API client note

This project does not depend on the official JS SDK. Instead it uses a **hand-written Dart client** (`lib/data/api/opencode_client.dart`) aligned with opencode's OpenAPI 3.1 spec. To refresh the reference spec implementation:

```bash
bash tool/gen_client.sh
```

The generated output is only for consistency comparison and is not wired into the app.
