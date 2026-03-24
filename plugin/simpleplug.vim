vim9script

if exists('g:loaded_simpleplug')
  finish
endif
g:loaded_simpleplug = 1

# =============== 配置项 ===============
g:simpleplug_dir = get(g:, 'simpleplug_dir', expand('~/.vim/plugged'))
g:simpleplug_daemon_path = get(g:, 'simpleplug_daemon_path', '')
g:simpleplug_debug = get(g:, 'simpleplug_debug', 0)
g:simpleplug_window_height = get(g:, 'simpleplug_window_height', 35)
g:simpleplug_auto_install = get(g:, 'simpleplug_auto_install', 1)
g:simpleplug_popup = get(g:, 'simpleplug_popup', 1)
# 并行数量（Rust daemon 端 tokio 自动管理，此处仅供将来扩展）
g:simpleplug_jobs = get(g:, 'simpleplug_jobs', 8)

# =============== 命令 ===============
command! PlugInstall   simpleplug#Install()
command! PlugUpdate    simpleplug#Update()
command! PlugClean     simpleplug#Clean()
command! PlugStatus    simpleplug#Status()
command! -nargs=1 -complete=customlist,simpleplug#CompletePluginNames PlugHook simpleplug#RunHook(<q-args>)

# =============== 自动命令 ===============
augroup SimplePlug
  autocmd!
  autocmd VimEnter * call simpleplug#AutoInstallMissing()
  autocmd VimLeavePre * try | simpleplug#Stop() | catch | endtry
augroup END
