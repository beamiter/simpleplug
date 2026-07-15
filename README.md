# SimplePlug 0.2

轻量、安全的 Vim9 插件管理器，使用 Rust/Tokio 后端执行可控并行 Git 操作。

## 特性

- **Vim9 Script** 前端，与 simpleclipboard / simpletree / simpletreesitter 同风格
- **Rust (Tokio) 后端**：并行 clone / pull / status，并由 `g:simpleplug_jobs` 限流
- 支持 `branch`、`do`（post-install hook）、`frozen`（锁定不更新）
- 支持 `for`（按文件类型延迟加载）、`on`（按命令延迟加载）
- 内置 UI 进度窗口，彩色状态显示
- API 兼容 vim-plug 风格，迁移成本极低
- 安全更新：工作区有改动时跳过，分支分叉时报错，不重写本地历史
- 安全清理：确认后仅删除插件根目录下未注册的 Git 目录，保留普通目录和符号链接
- 失败的 clone 会清理自身产生的残留目录，失败的 hook 会正确上报

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

# 延迟加载示例
simpleplug#Plug('neovimhaskell/haskell-vim', {for: 'haskell'})

# 完成：设置 runtimepath 并加载插件
simpleplug#End()
```

## 命令

| 命令 | 说明 |
|------|------|
| `:PlugInstall` | 安装未安装的插件（并行 git clone） |
| `:PlugUpdate` | 安全更新所有插件；同时补装缺失插件 |
| `:PlugClean` | 确认后清理未注册的 Git 插件目录 |
| `:PlugClean!` | 跳过确认并执行安全清理 |
| `:PlugStatus` | 查看所有插件状态（分支、commit、是否有修改） |
| `:PlugHook {name}` | 对指定插件执行 post-install hook |
| `:PlugStop` | 停止当前后端任务 |

默认情况下，Vim 启动时会自动检查已注册插件里是否有尚未安装的新插件；如果有，则自动触发一次 `:PlugInstall`。

## 选项

```vim
g:simpleplug_dir          " 插件目录 (默认 ~/.vim/plugged)
g:simpleplug_daemon_path  " 手动指定 daemon 路径
g:simpleplug_debug        " 调试模式 (默认 0)
g:simpleplug_auto_install " 启动时自动安装新增插件 (默认 1)
g:simpleplug_window_width  " 右侧 UI 窗口宽度 (默认 88)
g:simpleplug_jobs          " 最大并行任务数 (默认 8，范围 1..64)
```

## Plug() 选项

| 选项 | 说明 |
|------|------|
| `branch` | 指定分支 |
| `do` | 安装/更新后执行的 shell 命令 |
| `frozen` | 设为 1 则 `:PlugUpdate` 跳过该插件 |
| `dir` | 自定义安装目录 |
| `as` | 自定义插件名，用于解决同名仓库冲突 |
| `for` | 按文件类型延迟加载（字符串或列表） |
| `on` | 按命令延迟加载（字符串或列表） |

## 更新与清理安全

- `:PlugUpdate` 只接受 fast-forward 更新；检测到未提交改动或分叉历史时会停止该插件的更新并在 UI 中报告原因。
- `:PlugClean` 不会删除普通数据目录或符号链接，只处理 `g:simpleplug_dir` 的直接子目录中带 `.git` 的未注册目录。
- SimplePlug 自身位于插件根目录时会自动加入清理保护列表。
- `do` 使用 shell 执行，等同于执行本地代码；只为可信插件配置 hook。

## 架构

```
Vim9 (simpleplug.vim)
     │  stdio JSON-RPC
     ▼
simpleplug-daemon (Rust/tokio)
     │  Semaphore 限流 + 每目录互斥锁
     ▼
git clone / pull / status
```

## 开发与验证

```bash
./tests/run.sh
```

测试包含 Rust 协议/并发/安全清理/脏工作区回归，以及 Vim9 延迟加载 smoke test。

## License

MIT
