# Claude Code 中文启动器 v1.0.3

这是一个模型检测修复版本，重点改善本地 OpenAI-compatible 中转的兼容性。

## 修复

- “检测模型”不再只依赖 `/models` 返回列表。
- 当 `/models` 超时、404、空列表或不兼容时，会用当前填写的模型发起一个很小的 `/chat/completions` 探针。
- 像 `http://localhost:52030/v1` 这类能聊天但不暴露模型列表的本地中转，现在可以通过检测。
- 检测失败时会显示最后一个 `/models` 错误和 chat 探针错误，不再只给模糊的 `No models returned.`。

## 下载后怎么用

1. 下载 `ClaudeCode-ZH-Launcher-v1.0.3.zip`。
2. 解压。
3. 双击 `一键启动.cmd`。
4. 在启动器中填入 API Key、URL 和模型。
5. 点击启动 Claude Code。

## 安全

Release 包不包含 `.env.local`、真实 API Key、日志、旧压缩包、`node_modules`、`dist` 或本地副本目录。
