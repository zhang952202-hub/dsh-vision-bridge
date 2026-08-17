# dsh-vision-bridge

给 DeepSeek Harness（dsh）的纯文本 Agent 装上「眼睛」的完整方案：本地视觉模型（Ollama）做 Eyes，一个 shim 代理 + 一个 `analyze_image` 工具插件做 Bridge，模型选择器里出现 **Vision Bridge** 入口，聊天贴图和磁盘图片都能被「看见」。

> 本文档是完整的复现步骤总结，任何人按顺序操作即可得到相同环境。

## 快速开始（3 条命令）

前置：Node.js ≥ 22、pnpm、Python ≥ 3.8、dsh（`@deepseek-ai/dsh`）、Ollama（`ollama pull qwen2.5vl:3b`）。

```powershell
git clone https://github.com/zhang952202-hub/dsh-vision-bridge.git
cd dsh-vision-bridge
powershell -ExecutionPolicy Bypass -File install.ps1 -Upstream https://api.deepseek.com -TextModelId deepseek-v4-flash -ApiKeyEnv DEEPSEEK_API_KEY -Autostart
```

然后：把 `DEEPSEEK_API_KEY`（和可选的 `ZHIPU_API_KEY`）写进 `~/.dsh/.credentials.yaml` → 重启 `dsh web` → 模型选择器选 **Vision Bridge** 贴图测试 → 跑 `scripts\verify.ps1` 验收。

## 架构

```mermaid
flowchart LR
  U[用户] --> D[dsh web :3080]
  D -->|Door1 聊天贴图| P[vision_shim :8900 代理]
  P --> V[Ollama VLM :11434<br/>qwen2.5vl:3b]
  P -->|改写为 [Image: ...] 纯文本| B[文本大脑<br/>DeepSeek 等]
  D -->|Door2 磁盘文件| T[analyze_image 工具]
  T --> V
  B --> A[Agent 会话<br/>standard-vision 预设]
```

- **Eyes**：Ollama 本地 VLM（默认 `qwen2.5vl:3b`），OpenAI 兼容 `/v1/chat/completions`
- **Door 1（聊天贴图）**：`vision_shim.py` 代理拦截图片，先让本地 VLM 描述，再改写为 `[Image: ...]` 文本交给文本大脑
- **Door 2（磁盘文件）**：`analyze_image` 工具，Agent 拿到图片路径后主动调用，本地 VLM 返回文字描述
- **Adapter**：web profile 补丁注册插件 + `standard-vision` 预设 + `AGENTS.md` 告诉模型「你没有视觉」

## 目录结构

```text
dsh-vision-bridge/
├─ README.md                # 本文档
├─ install.ps1              # 一键安装
├─ uninstall.ps1            # 一键卸载
├─ plugin/vision/           # analyze_image 插件（index.js + package.json）
├─ shim/vision_shim.py      # 聊天贴图代理（纯 Python 标准库）
├─ autostart/               # Windows 开机自启模板
├─ scripts/                 # 真实 API 验收套件
└─ examples/                # settings.yaml / AGENTS.md 配置示例
```

## 前置条件

| 项 | 要求 |
|---|---|
| Windows | 10/11（本方案按 Windows + PowerShell 编写） |
| Node.js | ≥ 22 |
| pnpm | 可用（`corepack enable` 或独立安装） |
| Python | ≥ 3.8（shim 只用标准库） |
| dsh | `npm i -g @deepseek-ai/dsh`（本方案验证版本 0.1.0-rc.6） |
| Ollama | [ollama.com/download](https://ollama.com/download) 安装后 `ollama pull qwen2.5vl:3b` |
| 文本模型 API Key | DeepSeek 官方或任意 OpenAI 兼容端点 |
| 智谱 Key（可选） | open.bigmodel.cn 免费档 `glm-4.6v-flash`（模型选择器里的「智谱视觉」入口） |

## 安装

### 方式一：一键安装（推荐）

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 `
  -Upstream https://api.deepseek.com `
  -TextModelId deepseek-v4-flash `
  -ApiKeyEnv DEEPSEEK_API_KEY `
  -Autostart
```

参数说明：

| 参数 | 默认值 | 含义 |
|---|---|---|
| `-Upstream` | `https://api.deepseek.com` | 文本大脑的 OpenAI 兼容端点（**不带 /v1**，shim 自己拼） |
| `-TextModelId` | `deepseek-v4-flash` | 模型选择器里 Vision Bridge 对应的模型 id |
| `-ApiKeyEnv` | `DEEPSEEK_API_KEY` | 该端点的 key 环境变量名 |
| `-VisionUrl` | Ollama 端点 | 视觉模型的 `/v1/chat/completions` |
| `-VisionModel` | `qwen2.5vl:3b` | 视觉模型名 |
| `-Autostart` | 关 | 同时安装 Windows 登录自启 |
| `-DryRun` | 关 | 只预览将要执行的操作，不写入 |

脚本会自动完成：复制插件到 `~/.dsh/plugins/dsh-vision-bridge` → 修复 dsh-tools 链接 → `pnpm install` → 写入 web profile 依赖与补丁 → 创建 `standard-vision` 预设并设为默认 → 追加模型选择器条目 → 生成 `AGENTS.md` → 可选自启。

### 方式二：手动分步（便于理解每一步）

**1. 复制插件并修复 dsh-tools 链接**

```powershell
Copy-Item -Recurse plugin\vision "$env:USERPROFILE\.dsh\plugins\dsh-vision-bridge"
cd "$env:USERPROFILE\.dsh\plugins\dsh-vision-bridge"
pnpm install
```

> `package.json` 里 `@deepseek-ai/dsh-tools` 必须 `link:` 指向 dsh 自带副本，不要用 npm 上的旧版：
> `C:\Users\<你>\AppData\Roaming\npm\node_modules\@deepseek-ai\dsh\node_modules\@deepseek-ai\dsh-tools`

**2. 写入 web profile**

编辑 `~/.dsh/profiles/web/package.json`，dependencies 加：

```json
"dsh-vision-bridge": "link:C:/Users/<你>/.dsh/plugins/dsh-vision-bridge"
```

在 `~/.dsh/profiles/web/cordis.patch.yml` 末尾追加：

```yaml
- insert:
    - id: dsh-vision-bridge
      name: 'dsh-vision-bridge'
```

然后：

```powershell
cd "$env:USERPROFILE\.dsh\profiles\web"
pnpm install
```

**3. 创建 standard-vision 预设**

```powershell
Copy-Item -Recurse "C:\Users\<你>\AppData\Roaming\npm\node_modules\@deepseek-ai\dsh\config\agent-presets\standard" "$env:USERPROFILE\.dsh\.agent-presets\standard-vision"
Add-Content "$env:USERPROFILE\.dsh\.agent-presets\standard-vision\agent.cordis.yml" "`n- id: dsh-vision-bridge`n  name: 'dsh-vision-bridge'`n"
```

**4. 设为默认预设 + 模型选择器条目**

`~/.dsh/settings.yaml` 末尾追加（内容见 `examples/settings.yaml.snippet`）：

```yaml
agent-presets:
  default: standard-vision

llm-pi-ai:
  providers:
    vision-bridge:
      displayName: Vision Bridge
      apiKeyEnv: DEEPSEEK_API_KEY
      api: openai-completions
      baseURL: http://127.0.0.1:8900/v1
      models:
        - id: deepseek-v4-flash
          displayName: DeepSeek V4 Flash + Vision
          contextWindow: 262144
          maxTokens: 32768
          input: [text, image]
```

**5. AGENTS.md**

新建 `~/.dsh/AGENTS.md`，内容见 `examples/AGENTS.md.snippet`（告诉模型：图是代理/工具转成的文字，你不是多模态模型）。

## 配置密钥

编辑 `~/.dsh/.credentials.yaml`（**不要用 `Set-Content -Encoding UTF8` 写 JSON/YAML，会加 BOM**，用无 BOM UTF-8）：

```yaml
DEEPSEEK_API_KEY: sk-你的DeepSeekkey
ZHIPU_API_KEY: id.密钥   # 可选，智谱免费视觉档
```

## 启动与自启

启动 shim（**`--upstream` 不带 /v1**）：

```powershell
python shim\vision_shim.py --port 8900 --upstream https://api.deepseek.com --vision-url http://127.0.0.1:11434/v1/chat/completions --vision-model qwen2.5vl:3b
```

自检：浏览器打开 `http://127.0.0.1:8900/health`，`vision_ok: true` 即可；`upstream_ok` 对需要鉴权的官方 API 可能为 false（探测不带 key），属正常。

开机自启：`install.ps1 -Autostart` 会往启动文件夹放 `vision-proxy.vbs`，每次登录自动拉起 shim（Ollama 安装时已自带自启）。

然后**重启 `dsh web`**，模型选择器选 **Vision Bridge** 贴图测试；或选 **智谱视觉** 直接多模态对话。

## 验收（真实 API）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\verify.ps1
```

| 测试 | 验证内容 | 通过标准 |
|---|---|---|
| T1 Eyes | 直连本地 VLM 识别纯色 PNG | 200 + 非空描述 |
| T2 Proxy | 图片块经 shim 改写后转发 | 上游只收到 `[Image: ...]` 文本，无 `image_url` |
| T3 Tool | 挂载插件并真实调用 `analyze_image` | 返回非空描述 |

最后一项人工 E2E：dsh 会话里说 `用 analyze_image 看一下 <图片路径>`，确认模型主动调用工具并复述本地描述。

## 常见坑（实战总结）

1. **`Set-Content -Encoding UTF8`（PowerShell 5.1）会给文件加 BOM**：JSON 解析直接报 `Unexpected token '\uFEFF'`。写配置一律用
   `[System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($false)))`。
2. **`--upstream` 不要带 `/v1`**：shim 内部自己拼 `/v1/chat/completions`，填了会变成 `/v1/v1/...`，DeepSeek 返回诡异的鉴权错误。
3. **凭据文件别写重复行**：两个 `DEEPSEEK_API_KEY` 会让 PowerShell 数组拼接成 `Bearer key1 key2`，报 key 无效。
4. **插件 `inject` 必须声明用到的服务**：访问 `ctx.fs` 必须 `export const inject = ["tools", "fs"]`，否则 Cordis 抛 `cannot get property "fs" without inject`（`ctx && ctx.fs` 的兜底对代理对象无效）。
5. **插件不要 `export default`**：dsh 加载器优先取 default 导出，会把命名导出的 `inject` 丢掉。
6. **`defineTool` 参数格式随 dsh-tools 版本变**：0.1.0-rc.6 需要 `parameters` 属性映射格式 + `output.schema/render`。
7. **`output.render` 必须返回内容块数组**：dsh 硬性要求 `return [{ type: "text", text: ... }]`，返回纯字符串会在工具结果显示时抛 `content.some is not a function`（`execute` 的返回值同理，用 `[{type:"text",text}]` 最稳）。参考官方 `see_image` 的写法。
8. **插件代码改动要重启 dsh 进程**，settings.yaml 模型路由热加载；同一时间只开一个 dsh 实例（桌面版或 CLI 二选一），否则端口冲突、会话缓存混乱。
9. **会话损坏隔离**：工具结果格式错误期间产生的会话可能无法加载（`session event ... must contain one tool-result block`），把 `~/.dsh/sessions/<workspace>/<session-id>/` 整个目录移出即可恢复，文件留着可后续修复。

## 冻结版本清单

| 项 | 值 |
|---|---|
| dsh | `@deepseek-ai/dsh@0.1.0-rc.6` |
| dsh-tools | harness 自带副本（link 指向全局安装内） |
| Eyes | Ollama `qwen2.5vl:3b`（tag 固定） |
| 端口 | Ollama 11434 / shim 8900 / dsh web 3080 |
| 准入 | `verify.ps1` 全绿 + 人工 E2E 一项 |

版本规则：换 Eyes 模型/参数 → 重跑验收，升 v1.x；升级 dsh/dsh-tools → 先重跑验收再评估插件适配；破坏 T1/T2/T3 的改动视为 breaking。

## 卸载

```powershell
powershell -ExecutionPolicy Bypass -File uninstall.ps1 -KillShim
```
