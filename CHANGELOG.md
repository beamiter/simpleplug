# Changelog

## Unreleased - 2026-08-08

### 延迟加载：autocmd 事件、按模式绑定的触发器、依赖顺序

- 新增 `event`：把插件推迟到某个 autocmd 事件，一条记录是事件名加零个或多个
  pattern（`'InsertEnter'`、`'BufReadPre *.md'`、`'BufReadPre *.md *.org'`）。此前
  延迟加载的词汇只有 `for` 和 `on`，也就是 vim-plug 在 2014 年的那一套：补全插件
  没法推迟到 `InsertEnter`，git 插件没法推迟到第一个读进来的 buffer。
- 事件名后面的多个 pattern 用 `,` 接起来交给 `:autocmd`——`:autocmd` 的 pattern 到
  第一个空白就结束，后面的一律当命令。用空格接的话 `'BufReadPre *.aaa *.bbb'` 装出
  来的是 pattern `*.aaa` 加命令 `*.bbb ++once ++nested call ...`：`++once` 被吞进命令
  里所以触发器永不退役，每一次匹配只报一个 E1050，插件一次也不会加载。反过来，
  空格真属于某一个 pattern 时按 `:autocmd` 自己的写法转义成 `\ ` 即可。
- 事件名当场用 `exists('##...')` 校验并拒绝。打错一个事件名的代价，本来是一个
  永远不加载、也永远不说为什么的插件。触发器全被拒绝的插件保持非延迟。
- 叫醒插件的那一次事件，插件的处理器是赶不上的——处理器正是这次事件引发的
  source 装上的，而 Vim 在一轮事件开始时就定下了"这一轮到哪条 autocmd 为止"。
  SimplePlug 不自己补发（`doautocmd` 会把事件送给**所有**监听者，而且外面那一轮
  回来之后还会再送一遍，插件的处理器跑两次、别人的也跑两次），而是只对自己的
  autocmd 组发一次——这一发什么也不做，只让 Vim 重新记一次"到哪为止"，于是正在
  进行的那一轮自然地走进插件刚挂上的处理器。插件对这次事件只看见一次，别人一个
  也不重跑。`g:simpleplug_lazy_event_refire = 0` 跳过这一步，插件从下一次事件生效。
- `on` 现在接受 `{keys: '<Plug>(x)', modes: 'i'}`，模式取 `n`/`x`/`o`/`i`/`c` 的任意
  组合，默认仍是 `nxo`。裸字符串形式一字未改。不认识的模式字母当场报错，而不是
  装上一个什么都不映射的触发器。stub 走 `<Cmd>`——它不改变当前模式，所以重放的
  按键落在触发时的那个模式里，解析到插件自己的映射；插入模式和命令行模式因此
  不需要任何额外的模式还原动作。
- 重放改为插到 typeahead 的**队首**。此前是追加到队尾：`i<Plug>(x)<Esc>` 这种一串
  按键里，`<Esc>` 会先跑，插入模式已经退掉，重放的键落在普通模式里，再也解析不到
  插件刚装上的插入模式映射。可视模式的 `gv` 仍排在重放之前。
- 新增 `dependencies`：写插件名，或者声明时用的那个仓库串（两种都是用户眼里
  "这个插件"的名字）。依赖可以声明在被依赖者前面，解析推迟到 `End()`。
- `'runtimepath'` 现在按依赖拓扑排：被依赖的排在前面，因为 Vim 启动扫描
  `plugin/` 的先后就是 rtp 的先后。没有任何插件声明 `dependencies` 时每个节点的
  入度都是 0，结果逐字等于声明顺序——多一个特性不该改变别人 rtp 里的先后。
- 被非延迟插件依赖的插件一律提升为非延迟。"先"是由启动扫描时的 rtp 顺序决定的，
  一个还没响的触发器根本轮不到；把它留在延迟状态等于承诺一件做不到的事。
- 延迟触发的插件先把自己的依赖加载完再 source 自己。依赖成环会报出环里的插件名
  并退回声明顺序（一个环不该让整个 vimrc 停摆），加载路径上另有一道递归护栏。
  依赖一个从未声明过的插件会被报出来，声明它的插件照常加载。
- `End()` 的加载循环从"声明顺序"改成 rtp 顺序（也就是声明顺序的倒序）。这两条
  路径本来就该给出同一个顺序：启动时 source 的先后是 Vim 按 rtp 扫出来的，而
  VimEnter 之后重新 source 一遍 vimrc 走的是 `End()` 自己的循环——原先两者相反，
  于是"谁覆盖谁"会因为你有没有重新 source 过 vimrc 而不同，`dependencies` 承诺的
  "先"也只在其中一条路径上成立。
- 新增 `tests/vim_lazy.vim`（`make vim-lazy`，已并入 `make check`）：事件触发与交付、
  关掉交付、带模式的事件、被拒的事件名、只在插入/命令行模式存在的触发器及其重放、
  已加载插件的 stub 不被留在册上、被拒的模式字母、延迟依赖的加载顺序、按仓库串解析
  依赖、非延迟插件把延迟依赖提升并排到自己前面、无依赖时 rtp 顺序不变、成环回退、
  依赖不存在时依赖方照常加载。
- `g:simpleplug_lazy_event_refire` 与 `g:simpleplug_debug` 现在也认 `v:false` /
  `v:true`。此前这两个值是拿 `== 0` 读的，而 Vim9 里 bool 撞上数字就是 E1138：把
  refire 关成 `v:false` 的人，按下第一个 `i` 收到的是一个从我们自己的 autocmd 里
  抛出来的错误；`g:simpleplug_debug = v:true` 更糟，Log() 大半是在 `catch` 里被调
  的。两处都改成 `!get(...)`，跟本文件里其余布尔选项的读法一致。

### :PlugProfile 修正：eager 真的被量到了，ftdetect 不再被抹掉

- `:PlugProfile` 之前永远量不到 eager 插件，而"哪几个值得改成 `for` / `on`"正是它
  存在的理由。`End()` 是 vimrc 调的，跑在 Vim 扫 `runtimepath` 加载 `plugin/` 之前，
  所以 eager 插件的 `source` 从来不经过 SimplePlug：报告里那一行 eager 在真实会话中
  一次都不会出现，`(x of it at startup)` 里也只剩 ftdetect。现在 `End()` 会挂上
  `SourcePre` / `SourcePost`，量 Vim 自己那次扫描花在每个插件目录上的时间，并在
  `VimEnter` 立刻摘掉——之后按需 source 的 ftplugin / syntax 不该算进启动。
- 加载顺序一点没动：仍旧是 Vim 自己 source 的，SimplePlug 只在旁边看表。没有
  `SourcePre` / `SourcePost` 的 Vim 就老实不报 eager，而不是报个假数字。
- 一个 `for` / `on` 插件被触发之后，它的 ftdetect 开销会被改写成 `lazy`，从启动合计里
  整个消失——恰好和帮助里写的相反，而"跑过一阵子之后"正是大多数人打开这份报告的
  时刻。现在 ftdetect 和插件本体分开记账，触发之后它照样自己占一行。
- 回归：新增 `tests/vim_profile.vim`（`make vim-profile`）。eager 那一半没法在测试脚本
  里复现——`-S` 同样跑在扫描之后——所以它拉起一个带真 vimrc 的子 Vim，把报告读回来
  断言；另一半断言 ftdetect 那一行在触发前后都在，且启动合计不会因此变小。

### :PlugProfile：启动时间到底花在谁身上

- 新增 `:PlugProfile[!]`：按插件报出加载耗时（墙钟毫秒，大的在前）、加载方式
  （eager / lazy / install / ftdetect）以及延迟插件是被哪个触发器叫起来的；`!` 展开到
  每个被 source 的文件。`for` / `on` 的全部理由是启动时间，而在此之前这个数字从来
  没人看见过，于是每一条延迟加载标注都是猜的。
- lazy 与装完即用两条路径的 `source` 是 SimplePlug 自己调的，`SourcePluginScripts()`
  是它们共同的收口；eager 由 Vim 自己 source，靠 `SourcePre` / `SourcePost` 计时。
- `for` 插件的 `ftdetect/` 是被急切 source 的（否则它自带的文件类型永远认不出来，
  触发器也就永远不会响），这笔开销照样算在启动上，并且单独列出来——它常常正是
  "延迟加载"底下藏着的真实成本。
- 报告末尾直接给出超过 `g:simpleplug_profile_threshold_ms`（默认 5ms）的 eager 插件，
  建议改成 `{for: ...}` 或 `{on: ...}`。
- 列头写的是 `wall ms` 不是 CPU：`reltime()` 量的是墙钟，插件加载时做的 I/O 都算在
  里面。那通常正是你想知道的，但不能被读成 CPU 时间。
- 回归：smoke 里延迟加载一个 fixture 后 `:PlugProfile`，断言它被归因到了自己名下、
  标着 lazy、记下了触发器、并且带着一个真实的毫秒数。

### :PlugCheck：只问"有没有更新"，不真的更新

- 新增 `:PlugCheck [name ...]`：只读的更新检查。唯一写盘的是 `git fetch` 往 `.git` 里
  放的对象和远端引用——不 checkout、不 merge、不跑 `do` hook。在此之前想知道
  "有没有东西要更新"的唯一办法是真的更新一遍：作者自己的配置里那意味着二十多个
  checkout 被改写、每个 `do: './install.sh'` 重新 cargo build 一次，几分钟 CPU 换来
  一句"其实没变"。
- 有更新的插件排在最前面，报出新提交条数与最新的几条主题；行内按 `u` 只更新这一个
  ——检查的全部意义就在于之后不必全量更新。`:PlugHealth` 会带上最近一次检查的结果。
- `frozen` 与 tag/commit 锁定的插件直接报出来，不联网：`:PlugUpdate` 本来也不会把
  它们挪到别处去，问上游没有意义。
- fetch **不带** `--depth`：在完整克隆上加 `--depth` 会把取回来的引用变成浅的，
  一次只读的提问没有任何理由去改仓库的形状。浅克隆自己的 fetch 默认沿用原来的深度
  边界，两边都不用特别处理。
- daemon 新增 `check` 请求与 `check_result` 事件（capability `check`）。daemon 不宣告
  这个能力时 `:PlugCheck` 明说"太旧了，跑 ./install.sh 再 :PlugRestart"，而不是发一个
  它答不上来的请求。能力协商是异步的，所以这个判断会先等握手回来——不然 daemon 刚
  被拉起来的那一次会把一个完全正常的 daemon 误判成旧的。
- 回归：Rust 端断言检查报出 behind 数与主题、不移动 checkout、**检查之后的真实
  update 仍然能 fast-forward**（浅克隆被 `--depth` 弄坏的正是这一条），以及 pinned /
  frozen / 未安装三种收尾。Vim 端断言检查全程没发出任何会改动 checkout 的请求、
  有更新的行排在最前、`u` 只更新光标那一个，以及缺 capability 时的降级。

### 快照变成一个能 review 的锁文件

- 修复：`:PlugSnapshot` 之前是 `json_encode(snap)`，一行到底、键序取决于 Vim 字典的
  内部顺序。把它提交进 dotfiles 仓库的结果是每次重新生成都得到一份整行重排的 diff，
  "这次到底哪几个插件动了"根本看不出来。现在按插件名排序、一个插件一行手写输出，
  checkout 没变时重新生成得到逐字节相同的文件。
- 新增 v1 形状：`{"version": 1, "plugins": {名字: {"commit": OID, "url": …, "branch": …}}}`。
  只有 commit 的锁文件说不出这个 commit 是从哪个仓库、哪条分支来的，也就回答不了
  "锁文件这次变动改了什么"。旧的 `{名字: OID}` 永远读得动——磁盘上的旧锁文件不该
  因为升级插件而作废。
- 新文件按 `g:simpleplug_snapshot_format`（默认 `v1`）；**覆盖已有文件时保持它原来的
  形状**，版本控制里的锁文件不该因为跑了一次 `:PlugSnapshot` 就被换成另一种格式。
- `:PlugSnapshotDiff` 新增 `respecced` 一类：commit 还停在锁定的那个，但 url 或 branch
  的声明已经变了。只比 commit 的报告会把它算成 matched，而声明其实已经不是一回事。
  legacy 快照没记这两个字段，那里永远不会出现这一类。汇总行也报出文件是按哪种形状读的。
- 两条读取路径共用同一个 `IsFullGitOid` 闸门与同一套校验：commit 是要作为 revision
  原样交给 git 的，"启动 daemon 之前先校验整个文件"这条安全性质只证明一次。
- 回归：断言锁文件排序、逐字节可重现、v1 记下了来源 url；已有 legacy 文件不被就地
  升级；`g:simpleplug_snapshot_format = 'legacy'` 生效；v1 里的短 commit 与未知
  version 都在启动 daemon 之前被拒；以及 `respecced` 行的判定。

### :PlugDiff：一次更新到底带进来了什么，以及把它退回去

- 新增 `:PlugDiff [name ...]`：按插件列出上一次更新从哪个 commit 走到哪个 commit、
  中间是哪些提交（最新在前，最多 50 条，不含 merge）。在插件那一行按 `X` 把它退回
  更新前的 commit；`q` 关窗。进度窗口新增 `D`，直接跳到光标所在插件的那一段。
- 新增 `:PlugRollback[!] {name}`：同一件事的命令形式，`!` 跳过确认。回滚**不是**新的
  daemon 请求，就是一次带 commit pin 的普通 update——浅克隆的 deepen/unshallow 升级、
  脏工作区拒绝、submodule 同步全都已经在那条路径上，而且都有回归测试。
- daemon 新增 `update_detail` 事件（capability `update_detail`）：`name`、完整的
  `from`/`to` OID、以及 `from..to` 的提交主题。刻意不往 `progress` 上加字段——
  它有三十来个构造点，其中绝大多数永远没有 diff 可报。
- 记录并入 `g:simpleplug_dir/.simpleplug-lastupdate.json`，重启 Vim 之后 `:PlugDiff`
  仍然能用。**并入而不是覆盖**：回滚本身也是一次 update，覆盖的话，回滚三个插件里的
  第一个就会把另外两个的 `from` 抹掉，剩下两个再也回不去。已经不再注册的插件会被清掉。
- `from` 会作为 commit pin 原样发回 daemon，所以它跨的是和快照文件同一条边界：
  只接受完整 40/64 位十六进制 OID，记录损坏就整条丢弃，不"尽力而为"。
- 回归：Rust 端断言一次真实 update 报出正确的 from/to 与主题顺序、up-to-date 时
  不报、回滚报空主题列表且 HEAD 真的回去了；Vim 端（脚本化 daemon）断言记录文件
  的版本与内容、`:PlugDiff` 的渲染、`X` 的绑定，以及回滚请求的线格式——插件名唯一、
  commit 等于记录里的 `from`、`frozen` 被清掉。

### 同时声明 for 和 on 的插件也能挺过重新 source

- 修复：上一轮"重新 source vimrc 不再拆掉已加载的延迟插件"只挡住了看得见的那一半。
  `SetupLazyLoad()` 逐个触发器地判断"真实定义已经在了就别装 stub"，却照旧把
  `for` 的 FileType autocmd 重新挂上，`LoadPlugin()` 也照旧把
  `s_loaded_plugins[name]` 重置成 false。于是 `{for: 'rust', on: ['T1Cmd',
  '<Plug>(T1Map)']}` 这样的插件在重新 source 之后一切看起来正常——直到会话里
  某个时刻第一次进 rust 文件：FileType 触发 `LazyLoad()` →
  `RemoveLazyStubs()` 把插件自己定义的**真实**命令和映射删掉 → 重新 source 一个
  被 reload guard 拦下的脚本。`:T1Cmd` 从此报 E492，本次会话再也回不来。
- 现在规则只有一条，也只有一处：本会话已经 source 过这个 runtime，就说明插件已经
  加载，需要重新挂上的触发器数量是零——命令 stub、映射 stub、`for` autocmd 一个
  都不挂，`runtimepath` 保持 `End()` 刚设好的样子。逐触发器的三处半吊子判断
  （`SetupLazyLoad` 的 `sourced &&`、`SetupLazyMap` 的 `maparg` 检查、
  `RemoveRuntimePath` 的条件）随之删掉。
- 回归：Vim smoke 新增同时带 `for` 与 `on`、并且带 reload guard 的 fixture：
  加载 → 重新 `Begin()`/`End()` → `doautocmd FileType` → 断言真实命令还在、映射
  没被 stub 顶掉、runtime 还在 rtp、插件没有被二次 source。修复前必然失败。

### 重新 clone 不再吃掉未提交的工作

- 修复（数据丢失）：`git_checkout_is_valid()` 把"git 说这不是个能用的 checkout"和
  "git 根本没跑起来"折叠成同一个 `false`，而 `handle_update` 把它当成
  `remove_dir_all` 的许可，并且这一步排在既有的 dirty 检查之前。于是一个
  `PATH` 里没有 git 的 GUI Vim（或 git 装坏了、容器里没装 git、git 超时）
  执行 `:PlugUpdate`，会先把插件目录连同里面未提交的改动一起删掉，再报
  "exec git clone: No such file or directory"。`:PlugInstall` 走同一个判断，
  同样会删。
- 现在 `run_git` 之下分出 `GitOutcome::{Ok,Failed,Unavailable}`，checkout 的判定
  也从一个 bool 变成 `CheckoutState::{Missing,Valid,Interrupted,EmptyUpstream,
  Undetermined}`。只有 `Interrupted`——git 确认 `.git` 是仓库、且 HEAD 不指向任何
  提交——才允许删除；git 给不出结论（不在 PATH 上、超时、dubious ownership、
  `.git` 不可读或指向已不存在的 gitdir）一律报错并原样保留目录。
- 删除之前先跑 dirty 检查，不是之后：半成品 clone 还没 checkout 过任何文件，
  工作区里但凡有东西就是用户的，这时报 `dirty` 并跳过。`git status` 本身失败
  也算脏——给不出的答案不是删除的许可。
- 修复：上游还没有任何提交的仓库 clone 出来同样是 unborn HEAD，之前被当成半成品，
  于是每次 `:PlugInstall` 都"重新 clone → installed"，永远收敛不了。现在按
  `branch.<name>.remote` 是否已写入区分"clone 跑完了"和"clone 被杀在半路"，前者
  报 already；`:PlugUpdate` 则在上游出现第一个提交时直接采用它。
- 回归：git 跑不起来时的分类、update/install 都不删 git 读不了的 checkout、
  半成品 clone 里的用户文件在 update 与 install 之后都还在、空上游装两次都是
  already 且上游长出提交后 update 会跟上。

### :PlugStop 之后紧接着的请求不再丢

- 修复：`job_stop()` 只发 SIGTERM，进程被回收之前 `job_status()` 一直答 `run`，
  于是 `core#Ensure()` 把正在退出的那个 job 原样交回来，请求写进一条马上要关的
  channel。`:PlugStop`（或 `:PlugRestart`）之后立刻 `:PlugInstall`，要么报
  "daemon is not running"，要么眼看着 daemon 中途退出——`make check` 里
  `tests/vim_batch.vim` 大约每十次就红一次，就是这个。
- `Stop()` 现在记下"停止还在进行中"，`EnsureBackend()` 会先等旧进程真正退出
  （`sleep` 正是让 Vim 跑那个回收它的 exit 回调的东西，上限 5 秒）再启动新的；
  `Send()` 万一还是失败，会重新 Ensure 并重发一次才认输。
- 回归：fake daemon 新增 `FAKE_PLUG_TERM_DELAY_MS`，收到 SIGTERM 后故意赖着不
  退也不读，把那个窗口稳定地撑开；测试在 `simpleplug#Stop()` 之后立刻
  `:PlugInstall!`，断言结果里没有错误。修复前必然失败。

### 完成事件不再被激活时的异常带走

- 修复：`ActivateInstalled()` 里只有 source 插件脚本那一步有 try/catch，
  `SetupLazyLoad()` 没有——`{on: 'fzf'}` 这类小写触发器（不是合法命令名）会让
  `:command!` 抛 E183，异常一路冲出 `ActivateInstalled()`，被 `OnDaemonEvent`
  里那个空 catch 吞掉，`GenerateHelptags()` 和 `PublishResult()` 全都没跑：
  `User SimplePlugComplete` 不触发，`g:simpleplug_last_result` 停在上一次的值，
  `:PlugInstall!` 悄无声息地返回一份过期字典。
- 现在整个 per-plugin 循环体都在 try 里，失败记在那个插件自己的行上；
  `OnDone` 里的激活与 helptags 另加一层 try/finally，`PublishResult()` 放在
  finally 里，文档承诺的"操作结束——包括失败——都会触发 SimplePlugComplete"
  不会被第三方代码或用户配置里的一个笔误作废。
- `OnDaemonEvent` 的两个空 catch 现在会 `Log()` 吞掉的是什么。
- 回归：注册一个 `on: 'fzf'` 的插件后 `:PlugInstall!`，断言事件照常触发一次、
  结果字典是这一次的、并且失败写在该插件自己的进度行上。

### 进度窗口的选择模型

- 修复：光标所在行是拿每个已注册插件名去子串匹配行文本解析的，于是前缀名会盖住
  长名——作者自己的配置先注册 `simpletree` 再注册 `simpletreesitter`，在
  simpletreesitter 那一行按 `<CR>` 或 `d` 打开的是 simpletree，而且悄无声息。
  现在渲染时顺手建好"缓冲区行号 → 插件名"的映射，按行号取。
- 修复：每次渲染都把光标强行拉回选中行，而 spinner 每 200ms 渲染一次，于是滚到
  出错的那个插件根本做不到。只有选择本身变化时才动光标。
- 修复：footer、`?` 帮助和文档都写着 `j/k` 移动，但它从来没有被映射过，
  唯一会写 `s_ui_cursor_line` 的 `ScrollUp`/`ScrollDown` 是不可达的死代码。
  现在 `j`/`k` 真的映射了，选中项按插件名跟踪（不是行号），排序变化也不会跑偏；
  用户一旦选中某行，运行中的排序就冻住。另补上帮助里一直宣称的 `<Esc>` 关闭。
- 修复：`R` 会重跑整批，而文档写的是"重试失败的插件"。现在只重试 error/missing/
  dirty 的那些，没有失败项就直接说没有。
- 回归覆盖前缀对解析、`j`/`k` 移动与标记跟随、spinner tick 不抢光标，以及 `R`
  实际发出去的请求里只有失败的插件。

### :PlugRestore 不再对 frozen 插件装死

- 修复：`Restore()` 构造的 spec 原样带着 `frozen: true`，而 daemon 在看 commit pin
  之前就先判 frozen，于是回复 skipped、checkout 一动没动，UI 上却只是一行普通的
  `frozen`，看起来像成功了。冻结的含义是"更新不碰它"，不是"显式恢复悄悄失效"。
- 回归断言实际发出去的 update 请求：commit 是快照里的 OID，frozen 为假。fake
  daemon 新增 `FAKE_PLUG_DUMP`，把收到的每个请求原样落盘供测试检查。

### CI 重新变绿

- 修复：workflow 把 MSRV job 钉在 `dtolnay/rust-toolchain@1.85.0`，而 Cargo.toml
  早已声明 `rust-version = "1.88"`。cargo 把更高的 rust-version 当硬错误，于是
  这个 job 在编译任何东西之前就失败——每一次 push 都是红的。改钉 1.88.0，并加一步
  从 Cargo.toml 读出 `rust-version` 与实际 `rustc --version` 比对，两者再分家会
  直接报错，不会又悄悄躺红。
- handshake 检查不再硬编码 `"protocol_version":2`，改为从
  `src/simpleplug/simpleplug_daemon.rs` 的 `PROTOCOL_VERSION` 推导，协议号改动时
  不用记得同步改 CI（隔壁 simplemarkdown 正是死在这条上）。
- 删掉 CI 里重复列出的 `make defcompile` / `make vim-core`：门禁是什么由 Makefile
  一处说了算，`make check` 已经包含它们，也顺带把新的 `make vim-batch` 带进 CI。

### 装好的插件当场生效

- `g:simpleplug_auto_install` 默认开着，可首次启动的实际体验是：Vim 起来，克隆
  21 个插件，然后一个都不能用——`End()` 只对目录已存在的插件动 `runtimepath`，
  安装完成路径压根不碰 rtp。现在批处理结束时把每个 `installed` 的插件加进
  `runtimepath`、source 它的 `plugin/`、`after/plugin/` 与 `ftdetect/`，并对已打开的
  buffer 重跑一次 filetype 检测；`for`/`on` 插件只装触发器，仍旧按需加载。
- 目录实际没落地的插件会被报出来并保持未加载；某个脚本抛异常只记在它自己那一行
  上，不影响这一批里的其他插件。新增 `g:simpleplug_activate_on_install`（默认 1），
  置 0 即回到"重启 Vim 才生效"。

### 完成事件与同步模式

- 新增 `User SimplePlugComplete` 自动命令与 `g:simpleplug_last_result`
  （`mode`/`total`/`installed`/`updated`/`ok`/`frozen`/`removed`/`errors`/`failed`/
  `elapsed`），install、update、status、clean、hook 以及失败和 daemon 中途退出都会
  写入并触发。此前想知道结果只能盯着进度窗口，或者像作者的 vimrc 那样每 200ms
  轮询、正则抓取 UI buffer 第二行的错误数。
- `:PlugInstall!` / `:PlugUpdate!` 同步等待到操作结束，于是标准的无头引导
  `vim -es -u vimrc +'PlugInstall!' +qall` 第一次真正可用；上限
  `g:simpleplug_sync_timeout`（默认 1800 秒），CTRL-C 中断等待并停止操作。
  另导出 `simpleplug#Await([timeout])` 与 `simpleplug#LastResult()`。
- 等待用 `sleep` 而不是轮询 `getchar()`：Ex 模式下 `getchar()` 会去读脚本自己的
  输入，读到 EOF 就直接退出 Vim——正好把它要服务的无头引导静默截断。
- 新增 `make vim-batch`：用脚本化的 fake daemon 端到端驱动一整批 install/update，
  断言完成事件、结果字典、同步等待（含静默 daemon 的超时）与安装后激活。测试自带
  完成哨兵，因为 `-es` 会把好几种中途夭折变成静默的 exit 0。
- 补齐文档缺口：`g:simpleplug_spinner_interval` 一直被读取却从未声明或记录。

### 中断的 clone 能被识别并修复

- 修复：`git clone` 先建好目标目录和 `.git`，对象才慢慢传输；而 `clone_plugin`
  的残留清理只在 Err 分支上跑，进程被杀时根本不会执行。`:PlugStop` 和
  VimLeavePre 都是 SIGTERM，所以安装途中退出 Vim 会留下一个永远被当成
  "already installed" 的目录，`:PlugUpdate` 则报一句看不懂的 git 错误。
- daemon 现在要求 `git rev-parse --verify HEAD` 解析得出来才算装好；先用
  `--resolve-git-dir` 钉住这个 `.git` 确实属于本 checkout，免得损坏时 git 的
  发现逻辑往上走、拿外层 dotfiles 仓库的 HEAD 冒充健康。识别出来后删掉重
  clone，install 和 update 两条路径都走这个修复。
- Vim 侧的 `MissingPluginCount` 同步：`.git/index` 只在 checkout 完成时才写出，
  一次 stat 就能让 auto-install 重新把半成品当作缺失，而不是永远跳过。
- 新增 Rust 回归：install/update 各修一次中断的 clone；健康的 checkout（包括
  嵌套在另一个仓库里的）不被重新 clone。Vim smoke 覆盖三种 checkout 计数。

### 重新 source vimrc 不再拆掉已加载的延迟插件

- 修复：`Begin()` 会 `delcommand` 掉 `s_lazy_commands` 里的每个名字，但延迟加载
  成功后这个名字指向的已经是插件自己定义的真实命令，不再是 stub。插件加载时
  一并把触发器从 stub 列表里移除，`Begin()` 只删自己还欠着的那些。
- 修复：`End()` 会给已经加载过的延迟插件重新装回 stub，并把它的 runtime 从
  `runtimepath` 里摘掉。再次触发只会 source 一个被 reload guard 拦下的脚本，
  命令、映射和 autoload/ftplugin/syntax 就此在本次会话中消失。现在记录本会话
  真正 source 过的插件与目录：真实命令/映射已在时不再覆盖，runtime 也不再摘除。
- Vim smoke 新增带 reload guard 的 fixture：加载 → 重新 `Begin()`/`End()` →
  命令仍可用、映射未被 stub 顶掉、runtime 仍在 rtp、插件没有被二次 source。

## Unreleased - 2026-08-05

### 快照漂移审计

- 新增只读 `:PlugSnapshotDiff [file]`：按插件名逐项稳定报告 matched、commit drift、
  checkout 缺失、非 Git 目录、HEAD 不可读、已注册但未锁定，以及快照孤儿项；
  不启动 daemon、不访问网络，也不会改动快照。
- diff 与 restore 共用完整 JSON/OID 校验。无效或不可读文件在检查任何 checkout、
  输出任何部分结果前即失败；回归同时钉住确定性排序与零写入行为。

### 事务型安全快照

- `:PlugSnapshot` 保持原有 `name -> SHA` JSON 格式，但改为在目标旁原子创建
  同文件系统的 0700 私有 staging 目录，完整写入其中文件后原子替换；
  写入或 rename 失败不会截断上一版锁文件，也不会遗留插件创建的 staging 目录。
  预置的 staging 目录/符号链接只会促使重试，快照目标本身是符号链接时也拒绝跟随。
- `:PlugRestore` 在启动 daemon 前严格验证 JSON 根与每个条目类型，OID 仅接受完整
  40 位 SHA-1 或 64 位 SHA-256 十六进制值；旧版生成的有效快照无需迁移，同时
  无效 revision/选项字符串不会进入 Git 参数。
- Vim smoke 覆盖旧格式、40/64 位 OID、错误根/值、私有 staging 权限与清理、
  目录/符号链接名冲突重试、rename 失败保留旧目标，以及快照符号链接目标不被覆盖。

### Runtime 子目录

- `Plug()` 新增向后兼容的 `rtp` 选项，可把仓库内的 `vim`、`editors/vim`
  等相对子目录作为真正的 Vim runtime。普通加载、`for`/`on` 延迟加载、
  `ftdetect`、`after/` 和 helptags 全部遵循该目录；Git 更新、hook、快照和清理
  仍作用于完整 checkout。绝对路径及包含 `..` 或逗号的路径会在注册时被拒绝；
  实际加载前还会解析符号链接并复查 containment，避免 runtimepath 分隔符注入和
  checkout 外跳转。
- `after/` 不再依赖主 runtime 是否由 SimplePlug 本次加入；lazy runtime 暂时缺失
  时也不会提前标记 loaded 或永久删除 command/mapping stub，报错后可原地重试。
- 新增 nested runtime fixture，覆盖 eager、command/`for` lazy、ftdetect、after、
  help tags、缺目录重试、逗号与符号链接逃逸回归。

### 全套统一

- `.simplecore/` 回来了。10 个仓库里的 supervisor(`autoload/<plugin>/core.vim`
  与三个测试文件)本来就是一套 vendored bundle,但源头目录早已丢失,而每个
  Makefile 都还在引用 `../.simplecore/vendor.sh`。现在 bundle 有了源头,而且
  每个仓库带一份 `.simplecore.manifest` 记录各文件的 sha256,`make core-verify`
  会校验它,`check` 依赖它——手改 vendored 文件会在改它的那个仓库里直接失败,
  不需要 `.simplecore/` 在场。
- 安装器抽成共享的 `install-common.sh`,各仓库的 `install.sh` 只剩配置。
  由此补齐的能力:构建前检查 cargo/rustc 与 MSRV(此前 3 个仓库缺,用户看到的
  是一屏 trait 解析错误);原子替换(此前 2 个仓库是就地覆写,Vim 还开着旧 daemon
  时会 ETXTBSY);Windows 的 `.exe` 后缀;安装前用 `--self-test` 验证刚构建的
  二进制;以及生成 helptags。
- `make check` 现在是每个仓库统一的完整门禁。simplemarkdown 与 simpleminimap
  此前叫 `make test`,旧名字保留为别名。
- daemon 的命令行统一为 `--version` / `--help` / `--self-test`。

### 工具链

- `rust-version` 统一到 1.88(此前 1.85 与 1.88 各半)。实测:1.88 能构建全部
  10 个仓库,1.85 只能构建 5 个。
- `cargo update`:全部为补丁级更新。

  注意:这次更新让 `ignore` 从 0.4.27 升到 0.4.30+,而后者用了 let-chains。
  simplefinder 与 simpletree 此前声明的 1.85 在更新前是真实可用的,更新后不再成立
  ——这是这次依赖刷新付出的代价,不是发现了旧的错误声明。
- MSRV 提到 1.88 后,clippy 的 `collapsible_if` 开始建议用 let-chains 合并
  (该 lint 受 MSRV 门控)。已按建议合并,语义不变。

### 本插件

- `--version`/`--help`/`--self-test`:此前 daemon 完全忽略命令行参数。

### 构建与 CI 修复

- 新增 CI 的 MSRV 作业,按 `rust-version` 声明的最低版本构建。

### 修复

- `EnsureBackend()` 用 `s_job != v:null` 判定启动成功,而 `job_start()` 在 exec
  失败时同样返回 job 对象:daemon 起不来时插件整个会话都认为它在运行。
- `IsRunning()` 只读缓存标志、从不复查 `job_status()`,daemon 死掉后 `:PlugInstall`
  会静默地把请求写进死管道。
- 没有代际守卫:停止后紧接着启动时,旧 job 的 `exit_cb` 会清空新 job 的状态。

### 新增

- 协议握手(协议版本 2):daemon 新增 `ping`/`pong`,带版本号与能力集合。
- `:PlugHealth`、`:PlugRestart`、`:PlugLog`。
- 首个 GitHub Actions 工作流(此前全套九个插件里只有 simpleplug 没有 CI)。
- `g:simpleplug_git_timeout` / `g:simpleplug_hook_timeout` 现在每次启动 daemon
  时重新读取,改完不必重启 Vim。

### 可靠性:统一 daemon 监督层 (simplecore)

- 进程生命周期改由 vendored `simplecore` 监督层接管(`autoload/simpleplug/core.vim`,
  从 `.simplecore/` 同步,请勿直接编辑)。九个插件共用同一份实现:
  - 存活判定一律走 `job_status()`。`job_start()` 即使 exec 失败也会返回 job
    对象,所以 `job != null` 并不能说明进程还活着。
  - 代际守卫:被替换掉的旧 daemon 的 `exit_cb` 迟到时,不会再清掉接替它的新
    进程的状态。
  - 停止栅栏:显式停止后仍在管道里的事件会被丢弃,不会把刚拆掉的状态又写回去。
  - 指数退避自动重启;同一时间窗内反复崩溃则熔断,只报错一次而不是无限重启。
    手动 `:PlugRestart` 会重新合闸。
  - 请求按 id 关联并支持超时,卡死的 daemon 不会让回调永远悬着。
- 新增 `:PlugHealth`、`:PlugRestart`、`:PlugLog`,全套插件命名一致。

### 测试

- 新增 `tests/vim_core.vim`:监督层回归套件(存活判定、代际守卫、停止栅栏、
  退避重启、崩溃熔断、请求超时、协议握手、raw/json 两种编解码),由
  `tests/fake_daemon.py` 驱动——一个可以按需应答/静默/乱码/崩溃/忽略 SIGTERM
  的假 daemon。
- 新增 `make defcompile`:强制编译所有 Vim9 `def`。Vim9 惰性编译会把冷分支里的
  语法/类型错误一直藏到用户真正踩中为止。
- `make check` 现在包含以上两项。

## 0.4.0 - 2026-07-25

- 迁移到 Rust edition 2024，最低 Rust 版本提升到 1.85。
- 刷新依赖 lockfile；内部小幅整理，行为无变化。更新后请重新运行 `./install.sh`。
- 修复冒烟测试 fixture：`<Cmd>` 映射在 vim9script 上下文中不能使用 `:let`（新版 Vim 报 E1126）。

## 0.3.0 - 2026-07-25

- 新增 `tag` 与 `commit` 选项，可将插件锁定在指定标签或精确提交（浅克隆下自动做定向 fetch，必要时回退到完整历史）。
- 新增 `:PlugSnapshot [file]` / `:PlugRestore [file]`：把所有插件的精确 commit 写入快照文件，并可一键恢复到快照版本。
- `:PlugInstall` / `:PlugUpdate` 支持指定插件名（带补全），只操作选中的插件。
- `on` 选项支持 `<Plug>` 映射：按键首次触发时加载插件并重放按键。
- `for` 延迟加载现在会预先 source 插件的 `ftdetect`，插件自带的文件类型可以正常触发加载。
- 安装/更新完成后自动为各插件的 `doc/` 生成 helptags。
- 所有 git 操作增加超时（`g:simpleplug_git_timeout`，默认 300s）并禁用交互式凭据提示，网络卡死不再挂住任务；hook 超时独立配置（`g:simpleplug_hook_timeout`，默认 600s）。
- clone 失败自动清理残留并重试一次，缓解瞬时网络故障。
- 支持子模块：克隆使用 `--recurse-submodules --shallow-submodules`，更新后自动同步子模块。
- 修复浅克隆中 `branch` 切换失败的问题（fetch refspec 只跟踪初始分支导致 checkout 报错）。
- 修复 daemon 在 stdin 关闭时立即退出、丢弃进行中任务与未刷出事件的问题。
- `:PlugStatus` 显示每个插件最近一次提交的日期与标题；tag/commit 锁定的插件以 `pinned` 状态展示。
- 新增 Rust 回归测试（tag/commit 锁定、浅克隆分支切换、协议默认值）与 Vim9 smoke 测试（`<Plug>` 延迟加载、ftdetect 预加载）。

## 0.2.0 - 2026-07-15

- 修复文件类型和命令延迟加载被“已加载”标记短路的问题。
- 删除分叉更新时的强制 `reset --hard`，保护本地提交和未提交改动。
- 让 `g:simpleplug_jobs` 真正控制安装、更新和状态查询的并发量。
- 更新时自动补装缺失插件；clone 失败时清理本次产生的残留目录。
- hook 失败现在会传播到插件状态和批次汇总。
- 清理增加确认、根路径保护、自身保护，并仅删除未注册 Git 目录。
- 增加同名仓库检测、`as` 别名、本地/SSH/Git URL 支持和 `:PlugStop`。
- 增加 Rust 回归测试、Vim9 延迟加载 smoke test 和一键测试脚本。
- 安装脚本支持从任意工作目录调用，并使用锁文件进行可复现构建。
