# blink-copyq.nvim

从 [CopyQ](https://hluk.github.io/CopyQ/) 历史中读取文本，通过 [blink.cmp](https://github.com/Saghen/blink.cmp) 搜索并插入。参考 [blink-insert-yanky.nvim](blink-insert-yanky.nvim/README.md) 的 source 实现，不依赖 yanky.nvim。

输入 `!` 展示历史，继续输入如 `!hello` 由 blink 筛选，确认后把 `!hello` 替换成完整剪贴板文本。

## 特性

- 异步单进程读取，支持超时与取消，不阻塞编辑。
- 默认读取第一标签页，可指定已有标签页；保留 CopyQ 行序，原文去重。
- 完整保留缩进、首尾空格、换行和 Unicode；空字符串/纯空白及没有 text/plain 的记录不显示。
- label 为单行摘要，筛选与预览使用完整文本；`${1:...}` 等按普通文本插入，不作为 snippet。
- 只读历史，不修改系统剪贴板、不选择/移动/删除历史条目、不创建标签页、不写磁盘缓存。
- prompt、terminal、nofile buffer 禁用；无 `!` 的普通打字不请求历史。

## 依赖

- Neovim **0.10+**（本地验证版本 0.12.6）。
- blink.cmp（按 **v1.7.0 source API** 开发，同时兼容 main 的 `ctx.pos`）。
- 已运行且当前环境可访问的 CopyQ 服务，`copyq` 在 PATH 中。脚本 API 在 CopyQ **17.0.0** 上完成烟雾测试；未验证更早版本。

## 安装：lazy.nvim

**配置写在 blink.cmp 的 opts 中**，而不是本插件的 opts：

```lua
{
  'Saghen/blink.cmp',
  version = '1.*',
  dependencies = {
    'DaSea/blink-copyq.nvim',
  },
  opts = {
    sources = {
      default = { 'lsp', 'path', 'snippets', 'buffer', 'copyq' },
      providers = {
        copyq = {
          name = 'CopyQ',
          module = 'blink-copyq',
          async = true,
          opts = {
            -- tab = 'Clipboard', -- 可选：必须是已存在的 CopyQ 标签页
            max_items = 100,
            timeout_ms = 1000,
          },
        },
      },
    },
    keymap = {
      preset = 'default',
      ['<C-y>'] = {
        function(cmp)
          return cmp.show({ providers = { 'copyq' } })
        end,
      },
    },
  },
}
```

已有 blink 配置时，将 `copyq` 添加到你的 source 列表并合并 provider/keymap 即可，不必重复声明 blink。本地开发时也可以把依赖换成 `{ dir = '/path/to/blink-copyq.nvim', name = 'blink-copyq.nvim' }`。

本插件没有 `setup()`，不需要额外全局变量或 `vim.b` 手动标记。

## 使用

1. 启动 CopyQ，确保目标标签页已有复制的文本。
2. 在普通文件进入插入模式，输入 `!`。
3. 输入关键词，例如 `!hello`，按你在 blink 中配置的确认键插入候选。
4. `<C-y>` 只打开 CopyQ source。无触发片段时，接受候选在光标位置插入，不删除此前已输入的文字；有 `!query` 时仍替换该片段。

匹配由 blink 的 keyword/fuzzy 配置决定，**不保证包含标点的 query 被当作完整字符串搜索**；推荐使用 `!` 加单个关键词。触发片段遇到空白终止。自定义触发器建议选 `!`、`#` 等标点，而非字母。

历史在每次 source 请求时重新读取；blink 在同一轮补全中可能缓存候选。复制新内容后重新打开菜单获取新历史。

插件以 CopyQ 行序提供候选和 `sortText`，最终显示排序仍受 blink 的 fuzzy/sorts 配置控制。

## 配置

以下选项放在 `sources.providers.copyq.opts`：

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `trigger` | `"!"` | 单个非空白 ASCII 字符，支持 `%`、`]` 等模式特殊字符 |
| `manual_trigger` | `true` | 允许 blink 显式手动打开及同一轮后续输入；设为 false 则必须有触发片段 |
| `copyq_path` | `"copyq"` | 可执行文件名或完整路径，不是 shell 命令，不可附加参数 |
| `tab` | `nil` | 默认第一标签页；字符串指定已有标签。不存在时返回空候选，不创建标签 |
| `max_items` | `100` | 最多检查前 N 行历史，正整数；过滤/去重后可能不足 N 个候选 |
| `timeout_ms` | `1000` | 读取超时毫秒数，正整数 |
| `kind_name` | `"CopyQ"` | 自定义 completion kind 名称 |
| `kind_icon` | `"󰅍"` | kind 图标，可换成普通文本 |

## 错误处理与隐私

CopyQ 缺失、未运行、标签不存在、超时或返回异常时，返回空候选，不弹反复报错，不打印历史正文或子进程 stderr。故障时可先检查：

```vim
:echo executable('copyq')
```

再在同一桌面环境的终端执行 `copyq --version`、`copyq tab`，确认程序/服务可访问及标签名是否准确；远程或无图形会话需能连接同一 CopyQ 服务。

历史可能包含密码等敏感内容。请仅在需要时触发补全，或使用专用 CopyQ 标签页。该插件不会上传内容，但选择的文本将进入当前文件；预览也会显示原文。

## Spec 与测试

- [行为规格](spec/behavior_spec.md)
- [测试用例与执行记录](spec/test_cases.md)
- [测试入口](tests/run.lua)

无需安装 blink 或测试框架即可运行确定性测试：

```sh
NVIM_LOG_FILE=/dev/null nvim --headless -u NONE -l tests/run.lua
```

可选真实 CopyQ 脚本烟雾测试（需要运行中的 CopyQ）：

```sh
COPYQ_SMOKE=1 NVIM_LOG_FILE=/dev/null nvim --headless -u NONE -l tests/run.lua
```

普通测试使用进程替身和真实 Neovim 子进程 + 合成数据程序；CopyQ 烟雾测试通过局部 `tab/read/size` 替身执行生产脚本，**不会读取或改动用户历史**。这些测试不等同于真实 blink 菜单验收；真实用户历史、交互过滤和确认插入仍需手动验收。

## 实现参考

- [CopyQ Scripting API](https://copyq.readthedocs.io/en/latest/scripting-api.html)：`tab()`、`size()`、`read()`、JSON 和 CLI `--` 原样传参。
- [blink source API](https://github.com/Saghen/blink.cmp/blob/v1.7.0/lua/blink/cmp/sources/lib/types.lua)
- [blink text edits](https://github.com/Saghen/blink.cmp/blob/v1.7.0/lua/blink/cmp/lib/text_edits.lua)：非 LSP source 使用 UTF-8 字节列。
- [blink插入yank.nvim内容](https://github.com/qqliyunpeng/blink-insert-yanky.nvim )

## 许可证

[MIT](LICENSE)。保留参考实现的版权声明。
