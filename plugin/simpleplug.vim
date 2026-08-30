vim9script

if exists('g:loaded_simpleplug')
  finish
endif
g:loaded_simpleplug = 1

def Flag(value: any, fallback: number): number
  if type(value) == v:t_bool
    return value ? 1 : 0
  endif
  if type(value) == v:t_number
    return value == 0 ? 0 : 1
  endif
  return fallback
enddef

def Clamp(value: any, fallback: number, minimum: number, maximum: number): number
  return type(value) == v:t_number
    ? min([maximum, max([minimum, value])])
    : fallback
enddef

def Positive(value: any, fallback: number): number
  return type(value) == v:t_number && value > 0
    ? value : fallback
enddef

def AtLeast(value: any, fallback: number, minimum: number): number
  return type(value) == v:t_number && value > 0
    ? max([minimum, value]) : fallback
enddef

def NonNegative(value: any, fallback: float): float
  if type(value) == v:t_number || type(value) == v:t_float
    # max()/min() accept Numbers only, even though arithmetic and comparisons
    # support Float.  Normalise first, then clamp without passing a Float list
    # to max(); the old expression aborted the plugin during its default load.
    var numeric = 0.0 + value
    return numeric < 0.0 ? 0.0 : numeric
  endif
  return fallback
enddef

def Text(value: any, fallback: string): string
  return type(value) == v:t_string ? value : fallback
enddef

def Choice(value: any, fallback: string, allowed: list<string>): string
  return type(value) == v:t_string && index(allowed, value) >= 0
    ? value : fallback
enddef

# =============== 配置项 ===============
var default_dir = expand('~/.vim/plugged')
g:simpleplug_dir = Text(get(g:, 'simpleplug_dir', default_dir), default_dir)
if empty(g:simpleplug_dir)
  g:simpleplug_dir = default_dir
endif
g:simpleplug_daemon_path = Text(get(g:, 'simpleplug_daemon_path', ''), '')
g:simpleplug_debug = Flag(get(g:, 'simpleplug_debug', 0), 0)
g:simpleplug_window_width = Positive(get(g:, 'simpleplug_window_width', 88), 88)
g:simpleplug_auto_install = Flag(get(g:, 'simpleplug_auto_install', 1), 1)
# Rust daemon 的最大并行任务数（1..64）
g:simpleplug_jobs = Clamp(get(g:, 'simpleplug_jobs', 8), 8, 1, 64)
# 单个 git 操作 / post-hook 的超时秒数
g:simpleplug_git_timeout = Positive(get(g:, 'simpleplug_git_timeout', 300), 300)
g:simpleplug_hook_timeout = Positive(get(g:, 'simpleplug_hook_timeout', 600), 600)
# 装好的插件立刻在当前会话生效；置 0 则维持旧行为，等下次启动 Vim
g:simpleplug_activate_on_install = Flag(get(g:, 'simpleplug_activate_on_install', 1), 1)
# :PlugInstall! / :PlugUpdate! 最多阻塞多少秒
g:simpleplug_sync_timeout = Positive(
  get(g:, 'simpleplug_sync_timeout', 1800), 1800)
# 进度窗口 spinner 的刷新间隔（毫秒）
g:simpleplug_spinner_interval = AtLeast(
  get(g:, 'simpleplug_spinner_interval', 200), 200, 16)
# event 触发的插件加载完之后，叫醒它的那一次事件照样交给它，而且只交一次：这
# 一发只对 SimplePlug 自己的 autocmd 组发，该事件的其他监听者一个也不重跑。
# 置 0 则该插件从下一次事件开始生效。
g:simpleplug_lazy_event_refire = Flag(get(g:, 'simpleplug_lazy_event_refire', 1), 1)
# 新建快照文件的格式：'v1'（默认，带 url/branch）或 'legacy'（{名字: OID}）。
# 覆盖已有文件时永远保持该文件原来的格式，这个选项管不着。
g:simpleplug_snapshot_format = Choice(
  get(g:, 'simpleplug_snapshot_format', 'v1'), 'v1', ['v1', 'legacy'])
# :PlugProfile 里，多少毫秒起算"值得考虑改成延迟加载"
g:simpleplug_profile_threshold_ms = NonNegative(
  get(g:, 'simpleplug_profile_threshold_ms', 5), 5.0)

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
