# SimplePlug

轻量、安全的 Vim9 插件管理器，使用 Rust/Tokio 后端执行可控并行 Git 操作。

## 特性

- **Vim9 Script** 前端，与 simpleclipboard / simpletree / simpletreesitter 同风格
- **Rust (Tokio) 后端**：并行 clone / pull / status，并由 `g:simpleplug_jobs` 限流
- 支持 `branch`、`tag`、`commit`（版本锁定）、`do`（post-install hook）、`frozen`（锁定不更新）
- 支持 `for`（按文件类型延迟加载）、`on`（按命令或 `<Plug>` 映射延迟加载）
- 快照与恢复：`:PlugSnapshot` 记录全部插件的精确 commit，`:PlugRestore` 一键回滚
- `:PlugInstall` / `:PlugUpdate` 可指定插件名（带补全），只操作选中的插件
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
| `:PlugInstall [name ...]` | 安装未安装的插件（并行 git clone）；可指定插件名 |
| `:PlugUpdate [name ...]` | 安全更新插件；同时补装缺失插件；可指定插件名 |
| `:PlugClean` | 确认后清理未注册的 Git 插件目录 |
| `:PlugClean!` | 跳过确认并执行安全清理 |
| `:PlugStatus` | 查看所有插件状态（分支、commit、最近提交、是否有修改） |
| `:PlugSnapshot [file]` | 把所有插件的精确 commit 写入快照文件 |
| `:PlugRestore [file]` | 将插件恢复到快照中记录的 commit |
| `:PlugHook {name}` | 对指定插件执行 post-install hook |
| `:PlugStop` | 停止当前后端任务 |

默认情况下，Vim 启动时会自动检查已注册插件里是否有尚未安装的新插件；如果有，则自动触发一次 `:PlugInstall`。

快照默认路径为 `g:simpleplug_dir .. '/simpleplug.snapshot.json'`。
文件继续采用兼容旧版本的 `{插件名: 完整 Git OID}` JSON 对象；写入先在目标旁
原子创建同文件系统的 0700 私有 staging 目录，在其中写完文件后再原子替换
旧快照；写入或重命名失败不会破坏上一版，预置的同名目录/符号链接也不会被跟随。
为避免锁文件被当作 Git 参数注入，恢复会在启动后台前校验整个对象：每个值必须
是 40 位 SHA-1 或 64 位 SHA-256 十六进制 OID。快照目标本身若是符号链接会被拒绝。

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
```

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
| `on` | 按命令或 `<Plug>` 映射延迟加载（字符串或列表） |

版本锁定优先级：`commit` > `tag` > `branch`。

`rtp` 只改变加入 `'runtimepath'`、延迟加载和生成 helptags 时使用的目录；
clone、update、snapshot、hook 与 clean 仍以完整仓库目录为单位。为避免插件逃出
自己的 checkout，`rtp` 必须是相对路径，不能包含 `..` 或逗号；目录存在时还会
在每次实际加载前解析符号链接，确认最终路径仍位于 checkout 内。`after/` 会独立
加入 `'runtimepath'`，即使主 runtime 已由其他配置预先加入也不会漏掉。

若 `on` / `for` 延迟加载触发时 `rtp` 目录暂时不存在（例如刚切换到目录结构不同
的分支），SimplePlug 会给出明确错误并保留命令或映射 stub 及未加载状态；目录恢复
后再次触发即可重试，不需要重启 Vim。

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

测试包含 Rust 协议/并发/安全清理/脏工作区/版本锁定/浅克隆分支切换回归，以及 Vim9 延迟加载（filetype、命令、`<Plug>` 映射、ftdetect）smoke test。

## License

MIT
