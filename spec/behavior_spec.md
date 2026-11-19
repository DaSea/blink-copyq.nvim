# blink-copyq.nvim 行为规格

## 目标与依据

- 已确认：参考 `blink-insert-yanky.nvim`，在根目录实现从 CopyQ 获取文本的 blink.cmp 补全源；按 Spec → Test Case → TDD 推进。
- 本轮设计选择：读取 CopyQ 历史（不是仅当前系统剪贴板），沿用 `!query` 和手动打开交互。默认第一标签页，可指定已有标签页。
- 与参考实现的有意区别：不 trim 插入文本；仅空字符串/纯空白不作为候选，按完整原文去重。使用异步子进程而非阻塞读取。
- 不包含：写入/删除历史、设置系统剪贴板、图片或 HTML 转换、跨标签聚合、持久缓存。

## 连续使用流程

用户启动 CopyQ 并复制文本 → 在普通 Neovim buffer 中输入 `!` → blink.cmp 展示历史文本 → 输入 query 由 blink 筛选 → 确认后以完整原文替换 `!query`。也可用 blink 的手动 show 打开，在没有触发片段时仅在光标处插入，不删除前文。

## 行为规则

| ID | 输入与前置条件 | 可观察结果与副作用 |
| --- | --- | --- |
| B01 | 普通 buffer，光标前以 `<trigger><无空白 query>` 结尾 | 触发字符默认 `!`；替换范围包含触发字符和 query，不影响前文/光标后内容；行号转为 0-based，列遵循 blink 的字节偏移约定 |
| B02 | 无触发片段 | 仅 `manual_trigger=true` 且 ctx.trigger.kind 或 initial_kind 为 `manual` 时允许请求，并在光标处插入；其他情况空结果且不启动进程。接口核对后修正参考实现的过宽门控，防止普通打字意外展示历史；手动请求后继续输入仍沿用本轮手动状态 |
| B03 | prompt/terminal/nofile buffer | enabled=false，直接请求也不读取 CopyQ |
| B04 | 请求历史 | 用 argv 数组调用可配置 CopyQ 可执行文件，通过单次 eval 返回 JSON 字符串数组；默认第一标签页；显式标签不存在时失败且不创建标签；最多读取前 max_items 行（默认 100），保持 CopyQ 行序 |
| B05 | 空、重复、多行、Unicode、带首尾空白文本 | 跳过空字符串/纯空白；按原文去重；完整保留有效文本；label 是单行 UTF-8 安全摘要，filterText 含完整文本，textEdit 为纯文本而非 snippet；纯文本文档不解释历史中的 Markdown |
| B06 | 可执行文件缺失、启动异常、非零退出、超时、无效 JSON 或非字符串数组 | 主线程不阻塞；主循环回调一次空候选；不抛异步错误，不输出剪贴板正文或 stderr |
| B07 | 请求被取消 | 终止该请求子进程；不再调用 completion callback；取消幂等，完成后取消不误杀进程；不同请求互不取消 |
| B08 | 构造 source | 支持 trigger、manual_trigger、kind_name、kind_icon、copyq_path、tab、max_items、timeout_ms；错误配置立即报错；同名 kind 不重复注册 |
| B09 | 多次请求 | 不持久保存剪贴板；每次重新读取，历史变化能反映到下一次请求 |

## 配置与实现约束

- 模块名 `blink-copyq`，provider 建议命名 `copyq`；Neovim 0.10+（`vim.system`、`vim.json`）。
- trigger 为单个非空白 ASCII 字符（避免多字节触发器和 Lua 模式字符歧义）；允许 `%`、`]` 等 ASCII 标点。
- `max_items=100`、`timeout_ms=1000`，均为正整数。`tab=nil` 选择第一标签页；字符串 tab 不得为空。
- `copyq_path="copyq"` 为单个可执行文件路径，不是 shell 命令字符串。
- `manual_trigger=true`、`kind_name="CopyQ"`、`kind_icon="󰅍"`。
- CopyQ CLI 会解释反斜杠转义，因此 eval 后使用 `--` 原样传参；标签作为独立参数，不拼接到脚本。
- 文本只在内存中用于补全，可能包含敏感内容；不自动启动 CopyQ、不变更其设置。

## 验收

先建立可运行测试入口并观察行为断言红灯，再补实现至绿灯。自动化覆盖 B01–B09，区分进程替身、真实 Neovim 子进程与 CopyQ 脚本烟雾验证。真实 CopyQ 用户历史与 blink 菜单操作未运行时明确标注，不读取用户历史来制造测试数据。

## 参考

- 本地参考：`blink-insert-yanky.nvim/lua/blink-insert-yanky/init.lua`。
- CopyQ API：https://copyq.readthedocs.io/en/latest/scripting-api.html
- blink source API：https://github.com/Saghen/blink.cmp/blob/main/lua/blink/cmp/sources/lib/types.lua
