# SimplePlug

轻量、安全的 Vim9 插件管理器，使用 Rust/Tokio 后端执行可控并行 Git 操作。

## 特性

- **Vim9 Script** 前端，与 simpleclipboard / simpletree / simpletreesitter 同风格
- **Rust (Tokio) 后端**：并行 clone / pull / status，并由 `g:simpleplug_jobs` 限流
- 支持 `branch`、`tag`、`commit`（版本锁定）、`do`（post-install hook）、`frozen`（锁定不更新）
- 支持 `for`（按文件类型）、`on`（按命令或按键，可指定模式）、`event`（按 autocmd 事件）三种延迟加载
- `dependencies` 声明依赖：被依赖的插件保证先 source，`'runtimepath'` 顺序也随之排好
- 快照与恢复：`:PlugSnapshot` 记录全部插件的精确 commit，`:PlugRestore` 一键回滚
- `:PlugCheck` 只读地问"有没有更新"：只 fetch，不动工作区、不跑 hook
- `:PlugProfile` 按插件报出启动开销，直接告诉你哪几个值得改成 `for` / `on`
- `:PlugDiff` 审阅一次更新带进来的每条提交，`X` 单独把某个插件退回更新前的 commit
- 快照漂移审计：`:PlugSnapshotDiff` 只读检查 checkout 与锁文件是否一致
- `:PlugInstall` / `:PlugUpdate` 可指定插件名（带补全），只操作选中的插件
- 装好的插件当场生效：新安装的插件直接进 `runtimepath` 并被 source，不必重启 Vim
- 可编程：`:PlugInstall!` 同步等待，`User SimplePlugComplete` 事件 + `g:simpleplug_last_result` 给出结构化结果
- 内置 UI 进度窗口，彩色状态显示
- API 兼容 vim-plug 风格，迁移成本极低
- 安全更新：工作区有改动时跳过，分支分叉时报错，不重写本地历史
- 安全清理：确认后仅删除插件根目录下未注册的 Git 目录，保留普通目录和符号链接
- 健壮性：git 操作超时保护、禁用交互式凭据提示、clone 失败自动清理并重试、子模块自动同步
- 安装/更新后自动生成 helptags

## 安装

```bash
cd ~/.vim/plugged/simpleplug
./install.sh
```

需要 Rust 工具链（`cargo`）。

## 使用

在 `~/.vimrc` 中：

```vim
vim9script

# 初始化
simpleplug#Begin('~/.vim/plugged')

# 注册插件（兼容 vim-plug 语法风格）
simpleplug#Plug('tpope/vim-fugitive')
simpleplug#Plug('neoclide/coc.nvim', {branch: 'release'})
simpleplug#Plug('beamiter/simpletree', {do: './install.sh'})
simpleplug#Plug('junegunn/fzf', {dir: '~/.fzf', do: './install --all'})
simpleplug#Plug('example/shared-name', {as: 'shared-name-alt'})
# 仓库里的 Vim runtime 位于子目录（monorepo / 多编辑器插件）
simpleplug#Plug('example/editor-tools', {rtp: 'editors/vim'})

# 版本锁定
simpleplug#Plug('preservim/nerdtree', {tag: '7.1.2'})
simpleplug#Plug('tpope/vim-surround', {commit: '3d188ed'})

# 延迟加载示例
simpleplug#Plug('neovimhaskell/haskell-vim', {for: 'haskell'})
simpleplug#Plug('junegunn/vim-easy-align', {on: '<Plug>(EasyAlign)'})

# 完成：设置 runtimepath 并加载插件
simpleplug#End()
```

## 命令

| 命令 | 说明 |
|------|------|
| `:PlugInstall[!] [name ...]` | 安装未安装的插件（并行 git clone）；可指定插件名；`!` 同步等待完成 |
| `:PlugUpdate[!] [name ...]` | 安全更新插件；同时补装缺失插件；可指定插件名；`!` 同步等待完成 |
| `:PlugClean` | 确认后清理未注册的 Git 插件目录 |
| `:PlugClean!` | 跳过确认并执行安全清理 |
| `:PlugStatus` | 查看所有插件状态（分支、commit、最近提交、是否有修改） |
| `:PlugCheck [name ...]` | 只读地检查哪些插件有更新（只 fetch，不改工作区、不跑 hook）；行内 `u` 只更新这一个 |
| `:PlugDiff [name ...]` | 查看上一次更新带进来的提交，`X` 把光标所在插件回滚到更新前的 commit |
| `:PlugRollback[!] {name}` | 直接把某个插件回滚到上一次更新前的 commit；`!` 跳过确认 |
| `:PlugSnapshot [file]` | 把所有插件的精确 commit 写入快照文件 |
| `:PlugSnapshotDiff [file]` | 只读比较当前 checkout 与快照，报告漂移及缺失项 |
| `:PlugRestore [file]` | 将插件恢复到快照中记录的 commit |
| `:PlugProfile[!]` | 按插件归因启动开销（墙钟毫秒、加载方式、触发器）；`!` 展开到每个文件 |
| `:PlugHook {name}` | 对指定插件执行 post-install hook |
| `:PlugStop` | 停止当前后端任务 |

默认情况下，Vim 启动时会自动检查已注册插件里是否有尚未安装的新插件；如果有，则自动触发一次 `:PlugInstall`。
安装完成后这些插件会直接在当前会话生效（加入 `runtimepath`、source `plugin/` 与 `ftdetect/`），
不需要重启 Vim；`for` / `on` 插件只装上触发器，仍旧按需加载。
把 `g:simpleplug_activate_on_install` 设为 0 可以退回“重启后生效”的旧行为。

`.git` 目录本身不算装好：clone 被中途杀掉（安装途中退出 Vim 就会）留下的半成品
会被识别出来并重新 clone，而不是永远报告 "already installed"。

重新 clone 会删目录，所以只在三个条件同时成立时才做：git 真的跑起来并给出了结论
（git 不在 `PATH` 上、超时、或拒绝读这个 checkout —— 目录属于别的用户、`.git`
不可读或指向已经不存在的 gitdir —— 都只报错，目录原封不动）；git 确认 `.git` 是仓库
且 HEAD 不指向任何提交；`git status` 报告工作区是空的。半成品 clone 还没来得及 checkout
任何文件，所以里面要是有东西那就是你的，这时报 `dirty` 并跳过。上游本身还没有提交的
仓库同样是 unborn HEAD，但那是一次完成了的 clone，会被当作装好，不会每次都重新 clone；
下次 `:PlugUpdate` 时上游有了第一个提交就直接采用。

脚本化用法：`:PlugInstall!` 会阻塞到操作结束（上限 `g:simpleplug_sync_timeout` 秒，
CTRL-C 可中断），所以标准的无头引导可以直接写成

```bash
vim -es -u vimrc +'PlugInstall!' +qall
```

每次操作结束都会写入 `g:simpleplug_last_result`（`mode` / `installed` / `updated` /
`ok` / `frozen` / `errors` / `failed` / `elapsed`）并触发 `User SimplePlugComplete`，
`simpleplug#Await()` 与 `simpleplug#LastResult()` 提供同样的结果，不必再去正则解析进度窗口。

`:PlugDiff` 展示上一次更新每个插件从哪个 commit 走到哪个 commit、中间带进来了哪些提交
（最新的在前，最多 50 条，不含 merge）；在插件那一行按 `X` 就把它退回更新前的 commit，
`:PlugRollback[!] {name}` 是同一件事的命令形式。回滚走的是普通的 commit pin 更新，
因此浅克隆会自动加深、submodule 会重新同步、工作区脏的插件仍旧报 `dirty` 并跳过。
记录写在 `g:simpleplug_dir .. '/.simpleplug-lastupdate.json'`，下次启动 Vim 仍然可用；
每次更新是并入而不是覆盖，所以回滚了一个插件不会弄丢其他插件的上一版 commit。
文件损坏、或者某条记录里的 commit 不是完整 OID 时整条丢弃——那些 commit 是要交回给 git 的。

快照默认路径为 `g:simpleplug_dir .. '/simpleplug.snapshot.json'`。锁文件是拿去提交、
拿去 review 的，所以不用 `json_encode` 直接倒——Vim 的字典顺序是实现细节，一行到底、
每次重新生成键序都不一样的文件没人能审。现在按插件名排序、一个插件一行手写输出，
checkout 没变时重新生成得到逐字节相同的文件。

两种形状都读，写的时候二选一：新文件按 `g:simpleplug_snapshot_format`
（默认 `v1`：`{"version": 1, "plugins": {名字: {"commit": OID, "url": …, "branch": …}}}`），
覆盖已有文件时保持它原来的形状——版本控制里的锁文件不该因为跑了一次
`:PlugSnapshot` 就被改写成另一种格式。旧的 `{插件名: 完整 Git OID}` 永远读得动。

写入先在目标旁原子创建同文件系统的 0700 私有 staging 目录，在其中写完文件后再原子
替换旧快照；写入或重命名失败不会破坏上一版，预置的同名目录/符号链接也不会被跟随。
为避免锁文件被当作 Git 参数注入，恢复会在启动后台前校验整个文件：每个 commit 必须
是 40 位 SHA-1 或 64 位 SHA-256 十六进制 OID。快照目标本身若是符号链接会被拒绝。

`:PlugSnapshotDiff` 使用同一套完整校验，但只读取本地 Git HEAD，不启动后台、
不访问网络也不改动快照。结果按插件名排序并严格区分：已匹配、commit 漂移、
commit 没动但声明变了（respecced，只有 v1 快照记了 url/branch 才判得出来）、
已锁定但 checkout 缺失、目录非 Git、HEAD 不可读、已注册但未锁定，以及快照中
已不再注册的孤儿项；matched 项也会逐项输出，结果可直接保存作审计记录。

## 选项

```vim
g:simpleplug_dir           " 插件目录 (默认 ~/.vim/plugged)
g:simpleplug_daemon_path   " 手动指定 daemon 路径
g:simpleplug_debug         " 调试模式 (默认 0)
g:simpleplug_auto_install  " 启动时自动安装新增插件 (默认 1)
g:simpleplug_window_width  " 右侧 UI 窗口宽度 (默认 88)
g:simpleplug_jobs          " 最大并行任务数 (默认 8，范围 1..64)
g:simpleplug_git_timeout   " 单个 git 操作超时秒数 (默认 300)
g:simpleplug_hook_timeout  " post-hook 超时秒数 (默认 600)
g:simpleplug_activate_on_install  " 安装后立即在当前会话生效 (默认 1)
g:simpleplug_sync_timeout  " :PlugInstall! / :PlugUpdate! 最长等待秒数 (默认 1800)
g:simpleplug_spinner_interval     " 进度窗口刷新间隔毫秒 (默认 200)
g:simpleplug_snapshot_format      " 新建快照的格式: 'v1' (默认) 或 'legacy'
g:simpleplug_profile_threshold_ms " :PlugProfile 里多少毫秒起算延迟加载候选 (默认 5)
g:simpleplug_lazy_event_refire    " 叫醒 event 插件的那次事件是否交付给它 (默认 1)
```

写 0 / 1 的选项同样认 `v:false` / `v:true`。

## Plug() 选项

| 选项 | 说明 |
|------|------|
| `branch` | 指定分支 |
| `tag` | 锁定到指定标签（`:PlugUpdate` 只会对齐到该标签） |
| `commit` | 锁定到精确提交（优先级最高） |
| `do` | 安装/更新后执行的 shell 命令 |
| `frozen` | 设为 1 则 `:PlugUpdate` 跳过该插件 |
| `dir` | 自定义安装目录 |
| `rtp` | 相对仓库根目录的 Vim runtime 子目录，例如 `vim` 或 `editors/vim` |
| `as` | 自定义插件名，用于解决同名仓库冲突 |
| `for` | 按文件类型延迟加载（字符串或列表；插件自带 ftdetect 会预先生效） |
| `on` | 按命令或按键延迟加载（字符串、列表，或 `{keys, modes}` 指定模式） |
| `event` | 按 autocmd 事件延迟加载，如 `'InsertEnter'`、`'BufReadPre *.md *.org'`（字符串或列表） |
| `dependencies` | 必须先 source 的插件名（或声明时的仓库串）列表 |

版本锁定优先级：`commit` > `tag` > `branch`。

`rtp` 只改变加入 `'runtimepath'`、延迟加载和生成 helptags 时使用的目录；
clone、update、snapshot、hook 与 clean 仍以完整仓库目录为单位。为避免插件逃出
自己的 checkout，`rtp` 必须是相对路径，不能包含 `..` 或逗号；目录存在时还会
在每次实际加载前解析符号链接，确认最终路径仍位于 checkout 内。`after/` 会独立
加入 `'runtimepath'`，即使主 runtime 已由其他配置预先加入也不会漏掉。

若 `on` / `for` 延迟加载触发时 `rtp` 目录暂时不存在（例如刚切换到目录结构不同
的分支），SimplePlug 会给出明确错误并保留命令或映射 stub 及未加载状态；目录恢复
后再次触发即可重试，不需要重启 Vim。`event` 触发器只响一次，目录不在也照样算用掉。

`on` 里裸字符串以 `<` 开头的是按键（默认映射到 `nxo` 三种模式），否则是命令名；
写成 `{keys: '<Plug>(x)', modes: 'i'}` 可以指定模式（`n`/`x`/`o`/`i`/`c`）。stub 走
`<Cmd>`，不改变当前模式，所以重放出去的按键会解析到插件自己在该模式下的映射。
模式字母不认识时当场报错，而不是装上一个什么都不映射的触发器；一个插件的触发器
全被拒绝，它就保持非延迟。

`event` 的一条记录是事件名加零个或多个 pattern（默认 `*`），例如 `'InsertEnter'`、
`'BufReadPre *.md'` 或 `'BufReadPre *.md *.org'`。事件名后面用空格分开的每个 pattern
都能叫醒插件——它们是用 `,` 接起来交给 `:autocmd` 的，`:autocmd` 自己就是这么写一串
pattern 的；真要让空格属于某一个 pattern，就按 `:autocmd` 的写法转义成 `\ `，例如
`'BufReadPre /srv/my\ notes/*'`。事件名打错会当场被拒——否则代价是一个永远不加载
也永远不出声的插件。叫醒插件的那次事件到达时插件还没有任何处理器（处理器正是这次事件引发的
source 装上的，而 Vim 不会把执行途中新挂上的 autocmd 算进这一轮），SimplePlug 让
正在进行的这一轮继续走进那些新挂的处理器：插件对这次事件**只看见一次**，就像它本
来就加载好了一样，这个事件的其他监听者一个也不会重跑。
`g:simpleplug_lazy_event_refire = 0` 则跳过这一步，插件从下一次事件开始生效。

`dependencies` 里写插件名或声明时用的仓库串，依赖可以声明在被依赖者前面。
`'runtimepath'` 会排成"被依赖的在前"，延迟触发的插件也会先把依赖加载完再 source
自己。被非延迟插件依赖的插件一律提升为非延迟：先后是由启动扫描时的
`'runtimepath'` 顺序决定的，一个还没响的触发器根本轮不到。没有依赖关系约束的插件
保持声明顺序不变。依赖成环会报出环里的插件名并退回声明顺序；依赖一个从未声明过的
插件会被报出来，声明它的插件照常加载。

## 更新与清理安全

- `:PlugUpdate` 只接受 fast-forward 更新；检测到未提交改动或分叉历史时会停止该插件的更新并在 UI 中报告原因。
- tag/commit 锁定的插件更新时只对齐到锁定版本，不做 pull。
- `:PlugClean` 不会删除普通数据目录或符号链接，只处理 `g:simpleplug_dir` 的直接子目录中带 `.git` 的未注册目录。
- SimplePlug 自身位于插件根目录时会自动加入清理保护列表。
- `do` 使用 shell 执行，等同于执行本地代码；只为可信插件配置 hook。
- 所有 git 操作禁用交互式凭据提示并有超时保护，不会因网络问题永久挂起。

## 架构

```
Vim9 (simpleplug.vim)
     │  stdio JSON-RPC
     ▼
simpleplug-daemon (Rust/tokio)
     │  Semaphore 限流 + 每目录互斥锁 + 超时/重试
     ▼
git clone / pull / status
```

## 开发与验证

```bash
./tests/run.sh
```

完整门禁是 `make check`（fmt、clippy、cargo test、`:defcompile`、simplecore supervisor
回归、Vim smoke，以及跑在脚本化 daemon 上的 install/update 批处理端到端测试）。

测试包含 Rust 协议/并发/安全清理/脏工作区/版本锁定/浅克隆分支切换/中断 clone 修复回归，
Vim9 延迟加载（filetype、命令、`<Plug>` 映射、ftdetect、重新 source vimrc——包括同时
声明 `for` 与 `on` 的插件）smoke test，
autocmd 事件触发与交付、关掉交付、带模式的事件、被拒的事件名、只在插入/命令行模式
存在的触发器及其重放、依赖顺序与成环回退的专项测试，
以及完成事件、同步等待、安装后激活、`:PlugDiff` 渲染与回滚线格式的端到端断言。

## License

MIT
