# Claude Code 中文启动器 v1.0.2

这是一个安装修复版本，重点解决入口文件改名后旧逻辑仍寻找 `一键启动DeepSeek.cmd` 的问题。

## 修复

- 桌面快捷方式创建现在优先使用通用入口 `一键启动.cmd`。
- 如果安装目录里缺少 `一键启动.cmd`，安装脚本会自动重新生成，不再因为入口文件丢失而中断。
- 仍兼容旧的 `一键启动DeepSeek.cmd`：检测到旧入口时会补写新的通用入口。
- 一键安装脚本的标题和日志文案从 DeepSeek 专属描述改为更通用的 Claude Code 启动器描述。

## 下载后怎么用

1. 下载 `ClaudeCode-ZH-Launcher-v1.0.2.zip`。
2. 解压。
3. 双击 `一键启动.cmd`。
4. 在启动器中填入 API Key、URL 和模型。
5. 点击启动 Claude Code。

## 安全

Release 包不包含 `.env.local`、真实 API Key、日志、旧压缩包、`node_modules`、`dist` 或本地副本目录。
