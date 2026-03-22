# SimplePlug

Vim9 插件管理器，使用 Rust 后端实现并行 git 操作。

## 特性

- **Vim9 Script** 前端，与 simpleclipboard / simpletree / simpletreesitter 同风格
- **Rust (tokio) 后端**：并行 git clone / pull / status 查询
- 支持 `branch`、`do`（post-install hook）、`frozen`（锁定不更新）
- 支持 `for`（按文件类型延迟加载）、`on`（按命令延迟加载）
- 内置 UI 进度窗口，彩色状态显示
- API 兼容 vim-plug 风格，迁移成本极低

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

# 延迟加载示例
simpleplug#Plug('neovimhaskell/haskell-vim', {for: 'haskell'})

# 完成：设置 runtimepath 并加载插件
simpleplug#End()
```

## 命令

| 命令 | 说明 |
|------|------|
| `:PlugInstall` | 安装未安装的插件（并行 git clone） |
| `:PlugUpdate` | 更新所有插件（并行 git pull） |
| `:PlugClean` | 清理未注册的插件目录 |
| `:PlugStatus` | 查看所有插件状态（分支、commit、是否有修改） |
| `:PlugHook {name}` | 对指定插件执行 post-install hook |

## 选项

```vim
g:simpleplug_dir          " 插件目录 (默认 ~/.vim/plugged)
g:simpleplug_daemon_path  " 手动指定 daemon 路径
g:simpleplug_debug        " 调试模式 (默认 0)
g:simpleplug_window_height " 进度窗口高度 (默认 15)
```

## Plug() 选项

| 选项 | 说明 |
|------|------|
| `branch` | 指定分支 |
| `do` | 安装/更新后执行的 shell 命令 |
| `frozen` | 设为 1 则 `:PlugUpdate` 跳过该插件 |
| `dir` | 自定义安装目录 |
| `for` | 按文件类型延迟加载（字符串或列表） |
| `on` | 按命令延迟加载（字符串或列表） |

## 架构

```
Vim9 (simpleplug.vim)
     │  stdio JSON-RPC
     ▼
simpleplug-daemon (Rust/tokio)
     │  并行 tokio::spawn
     ▼
git clone / pull / status
```

## License

MIT
