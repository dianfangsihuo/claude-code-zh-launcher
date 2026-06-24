Claude Code 常见英文提示对照

底部状态栏：
- accept edits on：自动接受 Claude 对文件的修改已开启
- accept edits off：自动接受编辑未开启，修改前会询问
- 1 shell / 2 shells：有 1 个 / 2 个命令行任务正在运行
- esc to interrupt：按 Esc 中断当前运行
- ctrl+t to hide tasks：按 Ctrl+T 隐藏任务列表
- ctrl+t to show tasks：按 Ctrl+T 显示任务列表
- down to manage：按方向键下，管理正在运行的任务
- ? for shortcuts：输入 ? 查看快捷键
- left for agents：按左方向键查看 agents

常见模式：
- plan mode：计划模式，只规划，不直接改文件
- acceptEdits：自动接受编辑
- bypassPermissions：跳过权限确认，风险更高
- default：默认确认模式
- auto：自动模式

常见操作：
- /help：查看帮助
- /theme：切换主题
- /model：切换模型和思考程度
- /effort：调整思考程度
- /plugin：管理插件
- /init：生成 CLAUDE.md 项目说明文件

桌宠：
- 启动器里的 `桌宠 / Pet` 默认开启，会显示 Codex-chan 桌宠。
- 启动器里的 `Motion` 默认关闭，桌宠默认静止/低动效；需要持续动画时再勾选。
- 桌宠会读取 Claude Code 最新会话，提示最近回复、工具输出和任务活跃状态。
- 桌宠可以拖动；右键可以打开最新会话、暂停/恢复动画、变大、变小、挥手、跳一下或关闭。
- 在 Claude Code 里可以用 `/pet off` 关闭桌宠，`/pet on` 打开桌宠，`/pet size 0.6` 调整启动尺寸；也保留 `/pet-off`、`/pet-on`、`/pet-size`。
- 新增命令后需要重开 Claude Code 会话，当前已经打开的会话不会立刻刷新斜杠命令列表。
- 不需要桌宠时，在启动器取消 `桌宠 / Pet`，或用 `start-claude.ps1 -NoPet`。

看不懂时可以直接问：
“把当前屏幕上的英文提示解释成中文”
