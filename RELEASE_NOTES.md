# Claude Code 中文启动器 v1.0.0

这是面向普通用户的首个公开版本：下载压缩包、解压、双击 `一键启动DeepSeek.cmd`，填入自己的 API Key 后即可启动 Claude Code 编程。

## 亮点

- 中文图形启动器，内置 DeepSeek、OpenRouter、硅基流动、智谱/Z.AI、BigModel、DashScope、Moonshot/Kimi、OpenAI、Gemini OpenAI-compatible、Groq、xAI 等常见预设。
- 自动安装/更新依赖，自动创建桌面快捷方式。
- 支持 Anthropic-compatible direct 和 OpenAI-compatible 本地代理两种路径。
- 默认保留 DeepSeek V4、SiliconFlow、OpenRouter 的 thinking/reasoning 能力；需要省成本或规避兼容问题时可以手动选择 `off`。
- 本地代理会保存并回放 reasoning 内容，改善 thinking 模型配合工具调用时的多轮兼容性。
- 附带中文界面提示对照、中文友好提示词和可选桌宠。

## 安全

- Release 包不包含 `.env.local`、真实 API Key、日志、旧压缩包、`node_modules`、`dist` 或本地副本目录。
- `.env.example` 只包含占位符，用户需要填入自己的 key。

## 下载后怎么用

1. 下载 `ClaudeCode-ZH-Launcher-v1.0.0.zip`。
2. 解压。
3. 双击 `一键启动DeepSeek.cmd`。
4. 在启动器中填入 API Key、URL 和模型。
5. 点击启动 Claude Code。
