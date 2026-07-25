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

# =============== 命令 ===============
command! -nargs=* -complete=customlist,simpleplug#CompletePluginNames PlugInstall simpleplug#Install([<f-args>])
command! -nargs=* -complete=customlist,simpleplug#CompletePluginNames PlugUpdate simpleplug#Update([<f-args>])
command! -bang PlugClean simpleplug#Clean(<bang>0)
command! PlugStatus    simpleplug#Status()
command! PlugStop      simpleplug#Stop()
command! -nargs=? -complete=file PlugSnapshot simpleplug#Snapshot(<q-args>)
command! -nargs=? -complete=file PlugRestore simpleplug#Restore(<q-args>)
command! -nargs=1 -complete=customlist,simpleplug#CompletePluginNames PlugHook simpleplug#RunHook(<q-args>)

# =============== 自动命令 ===============
augroup SimplePlug
  autocmd!
  autocmd VimEnter * call simpleplug#AutoInstallMissing()
  autocmd VimLeavePre * try | simpleplug#Stop() | catch | endtry
augroup END
