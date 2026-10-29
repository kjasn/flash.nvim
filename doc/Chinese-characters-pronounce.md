# 中文拼音跳转

本文说明当前拼音功能的使用方式、匹配规则和实现边界。英文用户文档见
[README](../README.md#chinese-pinyin-jumps)，词典版本与生成细节见
[数据来源说明](../third-party/pinyin-data.md)。

## 安装与启用

在 **flash.nvim 插件目录**执行：

```sh
python3 scripts/generate_pinyin.py
```

然后在已有 Flash 配置中启用拼音，并重启 Neovim：

```lua
require("flash").setup({ search = { pinyin = true } })
```

这个流程不依赖特定插件管理器。生成需要 Python 3.9+，首次在线生成需要下载固定版本的词典。
离线生成可以使用 `--source /path/to/pinyin.txt`，但源文件必须符合固定版本及 SHA-256。
已有词典的生成器版本、来源版本和内容校验均通过时，会跳过下载。

如果使用 lazy.nvim，可以在已有插件 spec 中加入构建配置：

```lua
{
  "folke/flash.nvim",
  build = "python3 scripts/generate_pinyin.py",
  opts = { search = { pinyin = true } },
}
```

已有安装执行 `:Lazy build flash.nvim`，完成后重启 Neovim。其他插件管理器可以在构建钩子中运行
相同的生成命令，也可以手动执行；保留已有的仓库、分支和其他配置。

生成失败会保留旧文件。词典缺失或无法加载时，Flash 提示一次并继续普通文本搜索；修复后重新
生成并重启 Neovim。生成文件 `lua/flash/pinyin/data.lua` 不提交 Git，也不应手动修改。
未启用拼音的用户不需要 Python 或构建步骤。跳转过程中只使用本地数据，不联网或调用 Python。

## 匹配规则

功能默认关闭，只适用于普通 `exact` 跳转，不自动接入 `/`、`?`、字符运动、Treesitter、remote、
fuzzy 或自定义 matcher。原文字面匹配始终保留。

| 配置 | 拼音匹配示例 |
| --- | --- |
| 仅 `search.pinyin = true` | `h`、`ha`、`hao` 匹配 好；`ao` 不匹配 好 |
| `pinyin_options.cross_character = true` | `zhongwen`、`zhongw` 匹配 中文；`xian` 匹配 先或西安 |
| `pinyin_options.initials = true` | `zw` 匹配 中文；`zh` 匹配 最火，同时保留单字前缀候选 中 |
| `pinyin_options.mixed = true` | `zhongwhw` 匹配 中午好哇 |

这些扩展开关位于 `search.pinyin_options` 下，互不依赖、默认关闭，但都要求 `search.pinyin = true`。

- 拼音从音节开头匹配，不支持音节内部子串。单字前缀匹配在开启扩展后仍然保留。
- 不接受声调符号或声调数字；用 `v` 表示 `ü`，例如 `lv` 匹配 绿，不提供 `u:` 别名。
- 全拼允许最后一个字只输入前缀，并保留全部合法切分。
- 首字母匹配至少输入两个字母；`zh/ch/sh` 的首字母分别为 `z/c/s`。
- 混输先输入一个或多个完整音节，再输入一个或多个首字母；进入首字母阶段后不能返回全拼。
- 多字匹配只跨连续的词典收录字符；空格、标点、未收录字符和实际换行会打断匹配，视觉折行不会。
- 所有收录读音都参与匹配，不按语境消歧。例如 `jiao`、`jue` 都匹配 角。
- 简繁体按词典收录的码点匹配，不进行简繁转换；未收录字符仍可通过原文搜索。
- 拼音遵循 `ignorecase` 和 `smartcase`，不会无条件把大写查询当成小写。

## 标签与连续输入

标签保持 Flash 原有位置和配置，默认在匹配之后；跳转默认落在匹配起点。
能继续扩展查询的字母不会提前分配为标签，例如 `h → ha → hao` 不应误触跳转。
原文查询的标签避让仍由原有逻辑处理。

混输可能经过暂时没有完整匹配的状态：对于 中午好，输入 `zhongwu` 时可以继续等待 `h`，
完成 `zhongwuh`。只有缓冲区中存在实际续输路径时才保持输入，否则沿用原有退出行为。

`search.trigger` 仍控制何时允许按标签跳转，`search.max_length` 仍限制输入长度；
开启 `jump.autojump` 时，唯一匹配可能提前结束输入。标签不足时沿用原有分配规则。

## 原生搜索延续

开启 `search.pinyin_options.retain_search` 后，成功跳转会把完整词典展开的正则写入 `/` 寄存器，
替换之前的搜索，即使 `jump.register = false` 也会写入。原生 `n/N` 因而可以搜索新插入的汉字
或其他缓冲区中的同类目标；不需要重新映射这些按键。

跳转结束时清除当前搜索高亮，但不改变 `hlsearch` 选项；该选项开启时，之后的原生搜索仍可显示
高亮。`jump.history` 保留的是原始字面查询，从历史调出不会恢复展开正则。
未开启延续时，搜索寄存器与历史仍遵循原有配置。

## 实现与性能边界

词典首次使用时延迟加载。生成数据按音节组织字符，运行时建立字符到读音的反向索引。
交互搜索只使用缓冲区实际出现的字符生成正则，再交给原有 Search matcher；位置仍由 Neovim
返回原文 UTF-8 字节坐标，不建立虚拟拼音文本。

首次搜索读取整个缓冲区，之后通过 `nvim_buf_attach()` 更新改动行；撤销、重做也会更新索引，
文件重载会重新处理全文，卸载或删除缓冲区时释放缓存。多个窗口共享同一缓冲区索引。
插入或删除行还需要移动后续行的元数据，因此不保证所有编辑都只花费与改动行数成正比的时间。
用过拼音的缓冲区会持续接收编辑回调，直到卸载或删除。

标签避让批量计算合法续输字母，复用重复汉字段和查询结果，不为每个标签独立扫描全文。
首次索引和复杂查询仍有成本；缓存不是整个功能的固定内存上限。

正则拼接设置 256 KiB 长度预算，超过时提示一次并回退到字面匹配。
这个预算不保证搜索执行时间。超大文件、长行、大量不同汉字段、歧义查询，以及原生搜索高亮，
仍可能增加延迟，不能用重复文本的局部基准代表所有实际场景。

## 开发与验证

Lua 回归测试位于 `tests/search/pinyin_spec.lua`，使用小型固定词典测试真实匹配和交互逻辑，
无需先下载完整词典。覆盖单字和多字匹配、标签避让、mixed 连续输入、大小写、多窗口、方向、
索引更新、撤销重做、文件重载、缺词典降级和搜索延续。

```sh
./scripts/test
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_generate_pinyin.py'
```

Python 测试检查已有词典复用、版本变化、源校验失败和原子替换失败。
Lua fixture 测试不能替代完整词典、大文件、真实编辑交互和支持版本的运行验证。

README 的配置块由 `lua/flash/docs.lua` 生成，help 文档由上游 panvimdoc 流程从 README 生成；
应修改源文件并重新生成，不要独立维护生成产物。词典格式或规范化逻辑变化时，需要更新生成器的
`FORMAT_VERSION`；升级数据版本时同步修改固定提交和 SHA-256。
