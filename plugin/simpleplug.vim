vim9script

if exists('g:loaded_simpleplug')
  finish
endif
g:loaded_simpleplug = 1

# =============== 配置项 ===============
g:simpleplug_dir = get(g:, 'simpleplug_dir', expand('~/.vim/plugged'))
g:simpleplug_daemon_path = get(g:, 'simpleplug_daemon_path', '')
g:simpleplug_debug = get(g:, 'simpleplug_debug', 0)
g:simpleplug_window_width = get(g:, 'simpleplug_window_width', 88)
g:simpleplug_auto_install = get(g:, 'simpleplug_auto_install', 1)
# Rust daemon 的最大并行任务数（1..64）
g:simpleplug_jobs = get(g:, 'simpleplug_jobs', 8)
# 单个 git 操作 / post-hook 的超时秒数
g:simpleplug_git_timeout = get(g:, 'simpleplug_git_timeout', 300)
g:simpleplug_hook_timeout = get(g:, 'simpleplug_hook_timeout', 600)
# 装好的插件立刻在当前会话生效；置 0 则维持旧行为，等下次启动 Vim
g:simpleplug_activate_on_install = get(g:, 'simpleplug_activate_on_install', 1)
# :PlugInstall! / :PlugUpdate! 最多阻塞多少秒
g:simpleplug_sync_timeout = get(g:, 'simpleplug_sync_timeout', 1800)
# 进度窗口 spinner 的刷新间隔（毫秒）
g:simpleplug_spinner_interval = get(g:, 'simpleplug_spinner_interval', 200)
# event 触发的插件加载完之后，把叫醒它的那次事件补发给它；代价是这个事件的其
# 他监听者会看见它两次。置 0 则该插件从下一次事件开始生效。
g:simpleplug_lazy_event_refire = get(g:, 'simpleplug_lazy_event_refire', 1)
# 新建快照文件的格式：'v1'（默认，带 url/branch）或 'legacy'（{名字: OID}）。
# 覆盖已有文件时永远保持该文件原来的格式，这个选项管不着。
g:simpleplug_snapshot_format = get(g:, 'simpleplug_snapshot_format', 'v1')
# :PlugProfile 里，多少毫秒起算"值得考虑改成延迟加载"
g:simpleplug_profile_threshold_ms = get(g:, 'simpleplug_profile_threshold_ms', 5)

# =============== 命令 ===============
command! -bang -nargs=* -complete=customlist,simpleplug#CompletePluginNames PlugInstall simpleplug#Install([<f-args>], <bang>0)
command! -bang -nargs=* -complete=customlist,simpleplug#CompletePluginNames PlugUpdate simpleplug#Update([<f-args>], <bang>0)
command! -bang PlugClean simpleplug#Clean(<bang>0)
command! PlugStatus    simpleplug#Status()
command! -nargs=* -complete=customlist,simpleplug#CompletePluginNames PlugCheck simpleplug#Check([<f-args>])
command! PlugStop      simpleplug#Stop()
command! -nargs=* -complete=customlist,simpleplug#CompletePluginNames PlugDiff simpleplug#Diff([<f-args>])
command! -bang -nargs=1 -complete=customlist,simpleplug#CompletePluginNames PlugRollback simpleplug#Rollback(<q-args>, <bang>0)
command! -nargs=? -complete=file PlugSnapshot simpleplug#Snapshot(<q-args>)
command! -nargs=? -complete=file PlugSnapshotDiff simpleplug#SnapshotDiff(<q-args>)
command! -nargs=? -complete=file PlugRestore simpleplug#Restore(<q-args>)
command! -nargs=1 -complete=customlist,simpleplug#CompletePluginNames PlugHook simpleplug#RunHook(<q-args>)
command! -bang PlugProfile simpleplug#Profile(<bang>0)
command! PlugHealth   simpleplug#Health()
command! PlugRestart  simpleplug#Restart()
command! PlugLog      simpleplug#ShowLog()

# =============== 自动命令 ===============
augroup SimplePlug
  autocmd!
  autocmd VimEnter * call simpleplug#AutoInstallMissing()
  autocmd VimLeavePre * try | simpleplug#Stop() | catch | endtry
augroup END
