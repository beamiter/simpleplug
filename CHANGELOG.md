# Changelog

## Unreleased - 2026-08-05

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
