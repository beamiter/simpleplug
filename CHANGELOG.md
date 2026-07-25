# Changelog

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
