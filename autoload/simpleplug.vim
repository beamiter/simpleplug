vim9script

# =============================================================
# SimplePlug — Vim9 包管理器 (Rust 后端)
# =============================================================


const s_plugin_root = fnamemodify(expand('<sfile>'), ':p:h:h')

# ─────────────────── 插件注册表 ───────────────────

var s_plugins: list<dict<any>> = []
# {name, repo, url, dir, rtp, branch, tag, commit, do, frozen, on_ft, on_cmd}

var s_loaded_plugins: dict<bool> = {}
var s_lazy_commands: list<string> = []
var s_lazy_maps: list<string> = []

# name -> the runtime directory whose plugin scripts were actually sourced.
# Deliberately NOT cleared by Begin(): re-sourcing a vimrc resets SimplePlug's
# own bookkeeping, but it does not reset the `if exists('g:loaded_x') | finish`
# guard inside a plugin that already ran.  Anything we tear down here can
# therefore never be rebuilt by sourcing that plugin a second time.
var s_sourced_runtime: dict<string> = {}

def AlreadySourced(name: string, runtime_dir: string): bool
  return get(s_sourced_runtime, name, '') ==# runtime_dir
enddef

# ─────────────────── 后端状态 ───────────────────

var s_next_id: number = 0
var s_cbs: dict<any> = {}   # id -> callback dict
var s_active_id: number = 0
# Set by Stop(): job_stop() only sends SIGTERM, so the process is still alive
# when Stop() returns.  See EnsureBackend().
var s_stop_pending: bool = false

# ─────────────────── UI 状态 ───────────────────

var s_ui_bufnr: number = -1
var s_ui_winid: number = 0
var s_ui_lines: list<string> = []

# 每个插件的实时状态追踪
var s_ui_plug_state: dict<dict<any>> = {}
# name -> {status: 'waiting'|'working'|'done'|'error'|'skipped', msg: '', icon: ''}
var s_ui_mode: string = ''        # 'install' | 'update' | 'status' | 'clean' | 'hook'
var s_ui_start_time: list<any> = []
var s_ui_total: number = 0
var s_ui_finished: number = 0
var s_ui_spinner_idx: number = 0
var s_ui_spinner_timer: number = 0
var s_auto_install_checked: bool = false
const s_spinners = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']


# A repository may keep its Vim runtime in a subdirectory (common in
# monorepos).  Git operations always use plug.dir; loading and helptags use
# this derived path.
def RuntimeDir(plug: dict<any>): string
  var rtp = get(plug, 'rtp', '')
  return empty(rtp) ? plug.dir : plug.dir .. '/' .. rtp
enddef


def CanonicalPath(path: string): string
  var canonical = substitute(simplify(resolve(fnamemodify(path, ':p'))), '\\', '/', 'g')
  if canonical !=# '/' && canonical !~? '^\a:/$'
    canonical = substitute(canonical, '/\+$', '', '')
  endif
  return canonical
enddef


# Lexical checks at registration catch malformed paths even before a plugin is
# installed.  This canonical check is repeated immediately before every load,
# so a runtime subdirectory replaced by an escaping symlink cannot be sourced.
def IsInsideCheckout(path: string, checkout: string): bool
  var candidate = CanonicalPath(path)
  var root = CanonicalPath(checkout)
  if has('win32') || has('win64')
    candidate = tolower(candidate)
    root = tolower(root)
  endif
  var prefix = root[-1 :] ==# '/' ? root : root .. '/'
  return candidate ==# root || stridx(candidate, prefix) == 0
enddef


def RuntimeIssue(plug: dict<any>, message: string, warning: bool = false)
  echohl {warning ? 'WarningMsg' : 'ErrorMsg'}
  echom printf('[SimplePlug] %s %s', plug.name, message)
  echohl None
enddef


def CheckedRuntimeDir(plug: dict<any>, missing_is_error: bool = false): string
  var runtime_dir = RuntimeDir(plug)
  if !isdirectory(runtime_dir)
    RuntimeIssue(plug, 'runtime directory is missing: ' .. runtime_dir, !missing_is_error)
    return ''
  endif
  if !IsInsideCheckout(runtime_dir, plug.dir)
    RuntimeIssue(plug, printf('runtime directory escapes plugin directory: %s -> %s',
      runtime_dir, CanonicalPath(runtime_dir)))
    return ''
  endif
  return runtime_dir
enddef


def AddRuntimePath(runtime_dir: string)
  if index(split(&runtimepath, ','), runtime_dir) < 0
    &runtimepath = runtime_dir .. ',' .. &runtimepath
  endif
  # The after/ entry is independent: users may already have inserted the main
  # runtime directory without its override directory.
  var afterdir = runtime_dir .. '/after'
  if isdirectory(afterdir) && index(split(&runtimepath, ','), afterdir) < 0
    &runtimepath = &runtimepath .. ',' .. afterdir
  endif
enddef


def RemoveRuntimePath(runtime_dir: string)
  var kept: list<string> = []
  for entry in split(&runtimepath, ',')
    if entry !=# runtime_dir && entry !=# runtime_dir .. '/after'
      add(kept, entry)
    endif
  endfor
  &runtimepath = join(kept, ',')
enddef

# ─────────────────── UI 交互状态 ───────────────────

# The selected plugin is tracked by name, not by row index: the list re-sorts
# while an operation runs, and an index would silently point at a different
# plugin after every 200ms spinner tick.
var s_ui_cursor_name: string = ''
# Rendered buffer line (as a string key) -> plugin name.  Built while
# rendering, so resolving the row under the cursor is exact.
var s_ui_line_map: dict<string> = {}
var s_ui_show_help: bool = false
var s_ui_filter_text: string = ''
var s_ui_filter_active: bool = false
var s_ui_plug_timings: dict<float> = {}
var s_ui_plug_start_times: dict<list<any>> = {}
var s_ui_sorted_names: list<string> = []
var s_ui_cursor_buf_line: number = 0  # 光标对应的缓冲区行号(1-based)
var s_ui_targets: list<string> = []   # 本次操作涉及的插件名(注册顺序)

# ─────────────────── 日志 ───────────────────

def Log(msg: string, hl: string = 'None')
  if get(g:, 'simpleplug_debug', 0) == 0
    return
  endif
  echohl {hl}
  echom '[SimplePlug] ' .. msg
  echohl None
enddef

# =============================================================
# 公共 API: 注册插件
# =============================================================

# ----------- simpleplug#begin / simpleplug#end ----------

export def Begin(dir: string = '')
  for cmd in s_lazy_commands
    if exists(':' .. cmd) == 2
      execute 'silent! delcommand ' .. cmd
    endif
  endfor
  s_lazy_commands = []
  for keys in s_lazy_maps
    for md in ['n', 'x', 'o']
      execute 'silent! ' .. md .. 'unmap ' .. keys
    endfor
  endfor
  s_lazy_maps = []
  augroup SimplePlugLazy
    autocmd!
  augroup END
  s_plugins = []
  s_loaded_plugins = {}
  s_auto_install_checked = false
  if dir !=# ''
    g:simpleplug_dir = fnamemodify(dir, ':p')
    # 去掉末尾斜杠
    if g:simpleplug_dir[-1 :] ==# '/'
      g:simpleplug_dir = g:simpleplug_dir[: -2]
    endif
  endif
enddef

export def End()
  # 将所有已注册插件加入 runtimepath
  for plug in s_plugins
    if isdirectory(plug.dir)
      var runtime_dir = CheckedRuntimeDir(plug)
      if empty(runtime_dir)
        continue
      endif
      AddRuntimePath(runtime_dir)
      # 加载插件
      LoadPlugin(plug, runtime_dir)
    endif
  endfor
  filetype plugin indent on
  syntax enable
enddef

def LoadPlugin(plug: dict<any>, runtime_dir: string)
  if has_key(s_loaded_plugins, plug.name)
    return
  endif
  # 延迟插件必须保持未加载状态，直到对应事件真正触发。
  if !empty(get(plug, 'on_ft', '')) || !empty(get(plug, 'on_cmd', ''))
    s_loaded_plugins[plug.name] = false
    SetupLazyLoad(plug, runtime_dir)
    return
  endif
  s_loaded_plugins[plug.name] = true
  # End() 也可能由用户在 VimEnter 之后调用，此时 Vim 不会再自动扫描 plugin/。
  if v:vim_did_enter
    SourcePluginScripts(plug.name, runtime_dir)
  endif
enddef

def LazyTriggers(plug: dict<any>): list<string>
  var result: list<string> = []
  var configured = get(plug, 'on_cmd', '')
  if type(configured) == v:t_string && configured !=# ''
    add(result, configured)
  elseif type(configured) == v:t_list
    for trigger in configured
      if type(trigger) == v:t_string && trigger !=# ''
        add(result, trigger)
      endif
    endfor
  endif
  return result
enddef


def DefineLazyCommand(pname: string, command: string)
  execute printf(
    'command! -nargs=* -range -bang %s call simpleplug#LazyLoadCommand(%s, %s, <bang>0, <line1>, <line2>, <range>, <q-args>)',
    command, string(pname), string(command))
enddef


def SetupLazyLoad(plug: dict<any>, pdir: string)
  var pname = plug.name
  # A vimrc re-source runs Begin()/End() again over a plugin that has already
  # been lazy-loaded.  Not one of its triggers may be re-armed: whichever one
  # fires first calls LazyLoad, which removes the "stub" — by then the real
  # command and mapping the plugin installed — and re-sources a script that
  # its own reload guard finishes immediately.  The command and the mapping
  # are then gone for the rest of the session.
  #
  # Skipping only the triggers whose real definition is already visible is not
  # enough, and that is what this used to do: a plugin declared with both
  # `for` and `on` still had its FileType autocmd re-armed, so everything
  # looked correct until the first matching FileType event — arbitrarily later
  # in the session — took the command and the mapping down.  The plugin is
  # loaded; the only correct number of triggers to arm is zero.
  #
  # 'runtimepath' is deliberately left as End() just set it: the plugin's
  # autoload/ftplugin/syntax directories are in use, and re-sourcing its
  # plugin/ scripts can never put back what removing them would break.
  if AlreadySourced(pname, pdir)
    s_loaded_plugins[pname] = true
    return
  endif

  # on_ft 延迟加载
  var ft = get(plug, 'on_ft', '')
  if type(ft) == v:t_string && ft !=# ''
    execute printf('autocmd SimplePlugLazy FileType %s call simpleplug#LazyLoad(%s)', ft, string(pname))
  elseif type(ft) == v:t_list
    for f in ft
      execute printf('autocmd SimplePlugLazy FileType %s call simpleplug#LazyLoad(%s)', f, string(pname))
    endfor
  endif

  # on_cmd 延迟加载：普通命令走 command stub，<Plug>/按键序列走 mapping stub
  for c in LazyTriggers(plug)
    if c =~# '^<'
      SetupLazyMap(pname, c)
    else
      add(s_lazy_commands, c)
      DefineLazyCommand(pname, c)
    endif
  endfor

  # ftdetect 必须立即生效，否则插件自带的文件类型永远不会被识别，
  # for 延迟加载也就永远不会触发。
  SourceFtdetect(pdir)

  # 从 rtp 里暂时移除，触发时再加回来。
  RemoveRuntimePath(pdir)
enddef

# <Plug> 映射延迟加载：先注册 stub，触发时卸载 stub、加载插件、重放按键。
def SetupLazyMap(pname: string, keys: string)
  add(s_lazy_maps, keys)
  # <lt> 转义参数里的 '<'，避免映射定义时被翻译成键码。
  var keys_arg = substitute(string(keys), '<', '<lt>', 'g')
  for md in ['n', 'x', 'o']
    execute printf('%snoremap <silent> %s <Cmd>call simpleplug#LazyLoadMap(%s, %s, "%s")<CR>',
      md, keys, string(pname), keys_arg, md)
  endfor
enddef

export def LazyLoadMap(name: string, keys: string, mode: string)
  if !LazyLoad(name)
    return
  endif
  if mode ==# 'x'
    feedkeys('gv', 'n')
  endif
  feedkeys(substitute(keys, '\c^<Plug>', "\<Plug>", ''))
enddef


export def LazyLoadCommand(
    name: string,
    command: string,
    bang: number,
    line1: number,
    line2: number,
    range_count: number,
    args: string)
  if !LazyLoad(name)
    return
  endif
  if exists(':' .. command) != 2
    echohl ErrorMsg
    echom printf('[SimplePlug] %s loaded but did not define :%s', name, command)
    echohl None
    return
  endif
  var replay = range_count > 0 ? printf('%d,%d%s', line1, line2, command) : command
  replay ..= bang ? '!' : ''
  if args !=# ''
    replay ..= ' ' .. args
  endif
  execute replay
enddef


# Forget the trigger as well as unhooking it.  Once the real plugin has
# replaced a stub, the name in s_lazy_commands/s_lazy_maps no longer refers to
# anything of ours — and Begin() deletes everything those lists name.
def RemoveLazyStubs(plug: dict<any>)
  for trigger in LazyTriggers(plug)
    if trigger =~# '^<'
      for md in ['n', 'x', 'o']
        execute 'silent! ' .. md .. 'unmap ' .. trigger
      endfor
      filter(s_lazy_maps, (_, keys) => keys !=# trigger)
    else
      if exists(':' .. trigger) == 2
        execute 'silent! delcommand ' .. trigger
      endif
      filter(s_lazy_commands, (_, cmd) => cmd !=# trigger)
    endif
  endfor
enddef


export def LazyLoad(name: string): bool
  var plug = FindPlugin(name)
  if plug == {}
    echohl ErrorMsg
    echom '[SimplePlug] cannot lazy-load unknown plugin: ' .. name
    echohl None
    return false
  endif
  if get(s_loaded_plugins, name, false)
    return true
  endif

  # Validate before removing a command/mapping stub or changing loaded state.
  # A missing runtime may appear after an update; leaving the stub intact makes
  # the next invocation a real retry instead of a permanently dead command.
  var dir = CheckedRuntimeDir(plug, true)
  if empty(dir)
    return false
  endif
  s_loaded_plugins[name] = true
  RemoveLazyStubs(plug)

  # 重新加入 runtimepath
  AddRuntimePath(dir)

  SourcePluginScripts(name, dir)
  return true
enddef

# Returns one message per file that threw.  Sourcing third-party code is
# best-effort by design — one broken script must not stop the rest of a plugin
# from loading — but the caller may still want to say so.
def SourcePluginScripts(name: string, dir: string): list<string>
  s_sourced_runtime[name] = dir
  var failures: list<string> = []
  for pattern in ['plugin/**/*.vim', 'after/plugin/**/*.vim']
    for f in globpath(dir, pattern, 0, 1)
      try
        execute 'source ' .. fnameescape(f)
      catch
        Log('source error: ' .. v:exception, 'ErrorMsg')
        add(failures, fnamemodify(f, ':t') .. ': ' .. v:exception)
      endtry
    endfor
  endfor
  return failures
enddef

# ftdetect must be sourced by hand whenever a runtime directory appears after
# Vim's own startup scan: 'runtimepath' is only walked for it at startup.
def SourceFtdetect(dir: string)
  augroup filetypedetect
  for f in globpath(dir, 'ftdetect/*.vim', 0, 1)
    try
      execute 'source ' .. fnameescape(f)
    catch
      Log('ftdetect source error: ' .. v:exception, 'ErrorMsg')
    endtry
  endfor
  augroup END
enddef

def FindPlugin(name: string): dict<any>
  for plug in s_plugins
    if plug.name ==# name
      return plug
    endif
  endfor
  return {}
enddef

# =============================================================
# Plug() — 注册单个插件
# =============================================================

export def Plug(repo: string, opts: dict<any> = {})
  var name: string
  var url: string

  # 支持 'user/repo' 格式或完整 URL
  if repo =~# '^\(\a\+://\|[^/]\+@[^:]\+:\|[/~.]\)'
    url = repo
    name = fnamemodify(substitute(repo, '\.git$', '', ''), ':t')
  else
    url = 'https://github.com/' .. repo .. '.git'
    name = fnamemodify(repo, ':t')
  endif

  var alias = get(opts, 'as', '')
  if type(alias) == v:t_string && alias !=# ''
    name = alias
  endif
  if name !~# '^[A-Za-z0-9._-]\+$'
    echohl ErrorMsg
    echom '[SimplePlug] invalid plugin name: ' .. name
    echohl None
    return
  endif
  if FindPlugin(name) != {}
    echohl ErrorMsg
    echom '[SimplePlug] duplicate plugin name: ' .. name .. ' (use {as: ...} to disambiguate)'
    echohl None
    return
  endif

  var dir_override = get(opts, 'dir', '')
  var dir: string
  if dir_override !=# ''
    dir = fnamemodify(dir_override, ':p')
    if dir[-1 :] ==# '/'
      dir = dir[: -2]
    endif
  else
    dir = g:simpleplug_dir .. '/' .. name
  endif

  var rtp_value = get(opts, 'rtp', '')
  if type(rtp_value) != v:t_string
    echohl ErrorMsg
    echom '[SimplePlug] rtp must be a relative directory for: ' .. name
    echohl None
    return
  endif
  if stridx(rtp_value, ',') >= 0
    echohl ErrorMsg
    echom '[SimplePlug] rtp must not contain a comma for: ' .. name
    echohl None
    return
  endif
  var rtp = substitute(rtp_value, '\\', '/', 'g')
  if rtp =~# '^/' || rtp =~# '^\a:/'
    echohl ErrorMsg
    echom '[SimplePlug] rtp must stay inside the plugin directory: ' .. rtp_value
    echohl None
    return
  endif
  var rtp_parts = filter(split(rtp, '/'), (_, part) => part !=# '' && part !=# '.')
  if index(rtp_parts, '..') >= 0
    echohl ErrorMsg
    echom '[SimplePlug] rtp must not contain ..: ' .. rtp_value
    echohl None
    return
  endif
  rtp = join(rtp_parts, '/')

  # Existing local checkouts can be validated immediately.  Missing plugins
  # are checked again by End()/LazyLoad() after installation.
  var configured_runtime = empty(rtp) ? dir : dir .. '/' .. rtp
  if isdirectory(dir) && isdirectory(configured_runtime)
      && !IsInsideCheckout(configured_runtime, dir)
    echohl ErrorMsg
    echom printf('[SimplePlug] %s runtime directory escapes plugin directory: %s -> %s',
      name, configured_runtime, CanonicalPath(configured_runtime))
    echohl None
    return
  endif

  var branch = get(opts, 'branch', '')
  var tag = get(opts, 'tag', '')
  var commit = get(opts, 'commit', '')
  var do_cmd = get(opts, 'do', '')
  var frozen_val = get(opts, 'frozen', 0)
  var frozen: bool = false
  if type(frozen_val) == v:t_number
    frozen = frozen_val != 0
  elseif type(frozen_val) == v:t_bool
    frozen = frozen_val
  endif
  var on_ft = get(opts, 'for', '')
  var on_cmd = get(opts, 'on', '')

  add(s_plugins, {
    name: name,
    repo: repo,
    url: url,
    dir: dir,
    rtp: rtp,
    branch: branch,
    tag: tag,
    commit: commit,
    do: do_cmd,
    frozen: frozen,
    on_ft: on_ft,
    on_cmd: on_cmd,
  })
enddef

# =============================================================
# 后端通信
# =============================================================

def NextId(): number
  s_next_id += 1
  return s_next_id
enddef

# Process lifecycle belongs to the vendored simplecore supervisor: liveness
# by job_status (not a cached flag), generation-guarded callbacks, backoff
# restarts and a crash-loop breaker.
var s_core_ready: bool = false

def SetupCore()
  if s_core_ready
    return
  endif
  s_core_ready = true
  simpleplug#core#Setup({
    name: 'SimplePlug',
    exe: 'simpleplug-daemon',
    path_var: 'simpleplug_daemon_path',
    debug_var: 'simpleplug_debug',
    handshake: {request: {type: 'ping'}, reply_type: 'pong'},
    OnEvent: OnDaemonEvent,
    OnExit: OnDaemonExit,
  })
enddef

def IsRunning(): bool
  return simpleplug#core#IsRunning()
enddef

def EnsureBackend(): bool
  SetupCore()
  # Timeouts are read fresh on every start so :PlugInstall picks up a change
  # to g:simpleplug_git_timeout without a Vim restart.
  simpleplug#core#Configure('env', {
    SIMPLEPLUG_GIT_TIMEOUT: string(get(g:, 'simpleplug_git_timeout', 300)),
    SIMPLEPLUG_HOOK_TIMEOUT: string(get(g:, 'simpleplug_hook_timeout', 600)),
  })
  # :PlugStop only sends SIGTERM, and job_status() keeps answering 'run' until
  # the process is actually reaped — so core#Ensure() would hand back the
  # daemon we just killed and the request would go into a channel that is
  # closing. :PlugStop immediately followed by :PlugInstall then either lost
  # the request ("daemon is not running") or had it die mid-flight ("daemon
  # exited unexpectedly"). Wait for the old process to go first; `sleep` is
  # what lets Vim run the exit callback that reaps it.
  if s_stop_pending
    var since = reltime()
    while simpleplug#core#IsRunning() && reltimefloat(reltime(since)) < 5.0
      sleep 10m
    endwhile
    s_stop_pending = false
  endif
  return simpleplug#core#Ensure()
enddef

# Mid-flight installs must be reported as failed, not left spinning.
def OnDaemonExit(code: number, restarting: bool)
  s_cbs = {}
  if s_active_id <= 0
    return
  endif
  s_active_id = 0
  StopSpinner()
  var reason = restarting
    ? printf('daemon exited (%d); restarting…', code)
    : printf('daemon exited unexpectedly (%d)', code)
  for [name, st] in items(s_ui_plug_state)
    if !IsFinishedStatus(get(st, 'status', ''))
      st.status = 'error'
      st.action = 'error'
      st.icon = '✘'
      st.msg = reason
      s_ui_plug_state[name] = st
    endif
  endfor
  s_ui_mode ..= s_ui_mode =~# '_done$' ? '' : '_done'
  PublishResult()
  UIBuildAndRender()
enddef

export def Stop()
  SetupCore()
  simpleplug#core#Stop()
  s_stop_pending = true
  s_cbs = {}
  s_active_id = 0
enddef

export def Restart()
  SetupCore()
  s_cbs = {}
  s_active_id = 0
  if simpleplug#core#Restart()
    echom '[SimplePlug] daemon restarted'
  endif
enddef

export def ShowLog()
  simpleplug#core#ShowLog()
enddef

export def Health()
  SetupCore()
  var lines = ['SimplePlug health', repeat('─', 40)]
  extend(lines, simpleplug#core#HealthLines())
  add(lines, printf('[%s] git: %s',
    executable('git') ? 'OK' : 'ERROR',
    executable('git') ? exepath('git') : 'not found in $PATH'))
  add(lines, printf('[INFO] plugin directory: %s', get(g:, 'simpleplug_dir', '(unset)')))
  add(lines, printf('[INFO] registered plugins: %d', len(s_plugins)))
  add(lines, printf('[INFO] git timeout: %ds, hook timeout: %ds',
    get(g:, 'simpleplug_git_timeout', 300), get(g:, 'simpleplug_hook_timeout', 600)))
  for line in lines
    echom line
  endfor
enddef

def Send(req: dict<any>)
  if simpleplug#core#Send(req)
    return
  endif
  # The daemon can disappear between EnsureBackend() and here. job_stop() only
  # sends SIGTERM, so job_status() still answers 'run' for a moment afterwards
  # and core#Ensure() hands back the dying job instead of starting a new one —
  # :PlugStop or :PlugRestart followed promptly by :PlugInstall then loses the
  # request and reports "daemon is not running". Start a fresh one and send
  # again before giving up on it.
  if EnsureBackend() && simpleplug#core#Send(req)
    return
  endif
  s_active_id = 0
  OnError({message: 'daemon is not running'})
enddef

def OnDaemonEvent(ev: dict<any>)
  if !has_key(ev, 'type') || ev.type ==# 'pong'
    return
  endif

  var id = get(ev, 'id', 0)

  if id != 0 && s_active_id != 0 && id != s_active_id
    Log('Ignoring stale event for request ' .. id)
    return
  endif

  if ev.type ==# 'progress'
    OnProgress(ev)
  elseif ev.type ==# 'done'
    OnDone(ev)
    if has_key(s_cbs, id)
      try
        s_cbs[id].OnDone(ev)
      catch
        # 一个静默的 catch 曾经把整条完成路径的失败藏了起来；至少留个痕迹。
        Log('done callback for request ' .. id .. ' threw: ' .. v:exception, 'WarningMsg')
      endtry
      remove(s_cbs, id)
    endif
  elseif ev.type ==# 'error'
    OnError(ev)
    if has_key(s_cbs, id)
      try
        s_cbs[id].OnError(ev)
      catch
        Log('error callback for request ' .. id .. ' threw: ' .. v:exception, 'WarningMsg')
      endtry
      remove(s_cbs, id)
    endif
  elseif ev.type ==# 'status_result'
    OnStatusResult(ev)
    if has_key(s_cbs, id)
      remove(s_cbs, id)
    endif
  elseif ev.type ==# 'hook_done'
    OnHookDone(ev)
    if has_key(s_cbs, id)
      remove(s_cbs, id)
    endif
  elseif ev.type ==# 'clean_done'
    OnCleanDone(ev)
    if has_key(s_cbs, id)
      remove(s_cbs, id)
    endif
  endif

  if ev.type ==# 'done' || ev.type ==# 'error' || ev.type ==# 'status_result'
      || ev.type ==# 'hook_done' || ev.type ==# 'clean_done'
    s_active_id = 0
  endif
enddef

# =============================================================
# Install / Update / Clean / Status
# =============================================================

def PluginSpecs(plugs: list<dict<any>>): list<dict<any>>
  var specs: list<dict<any>> = []
  for p in plugs
    add(specs, {
      name: p.name,
      url: p.url,
      dir: p.dir,
      branch: p.branch,
      tag: get(p, 'tag', ''),
      commit: get(p, 'commit', ''),
      do_cmd: p.do,
      frozen: p.frozen,
    })
  endfor
  return specs
enddef

# 支持 :PlugInstall/:PlugUpdate 后接插件名，只操作指定插件。
def SelectPlugins(names: list<string>): list<dict<any>>
  if empty(names)
    return copy(s_plugins)
  endif
  var out: list<dict<any>> = []
  for n in names
    var p = FindPlugin(n)
    if p == {}
      echohl WarningMsg
      echom '[SimplePlug] unknown plugin: ' .. n
      echohl None
    else
      add(out, p)
    endif
  endfor
  return out
enddef

# `.git` on its own does not mean installed: a clone killed mid-transfer (which
# quitting Vim during the first auto-install does, via VimLeavePre → SIGTERM)
# leaves the directory and its .git behind.  The index is written only once the
# checkout completes, so it is the cheapest local proof that the clone finished
# — one stat() per plugin on every startup.  The daemon repeats the
# authoritative `git rev-parse --verify HEAD` check before it re-clones.
def IsInstalledCheckout(dir: string): bool
  var gitpath = dir .. '/.git'
  var ftype = getftype(gitpath)
  if ftype ==# ''
    return false
  endif
  if ftype !=# 'dir'
    # A .git file (worktree or submodule) points elsewhere; only the daemon can
    # resolve it, so do not claim it is broken on this evidence.
    return true
  endif
  return filereadable(gitpath .. '/index')
enddef

def MissingPluginCount(): number
  var missing = 0
  for p in s_plugins
    if !IsInstalledCheckout(p.dir)
      missing += 1
    endif
  endfor
  return missing
enddef

def StartRequest(mode: string): number
  if s_active_id > 0
    echohl WarningMsg
    echom '[SimplePlug] another operation is still running; use :PlugStop to cancel it.'
    echohl None
    return 0
  endif
  var id = NextId()
  s_active_id = id
  s_ui_mode = mode
  return id
enddef

def JobCount(): number
  var jobs = get(g:, 'simpleplug_jobs', 8)
  return type(jobs) == v:t_number ? max([1, min([jobs, 64])]) : 8
enddef

def NormalDir(path: string): string
  return substitute(fnamemodify(path, ':p'), '/\+$', '', '')
enddef

# install/update 共用的批处理入口。specs 允许与 plugs 不同（如 Restore 注入 commit）。
def RunBatch(mode: string, plugs: list<dict<any>>, specs: list<dict<any>>)
  var id = StartRequest(mode)
  if id == 0
    return
  endif
  s_ui_total = len(plugs)
  s_ui_finished = 0
  s_ui_start_time = reltime()
  InitPlugStates(plugs, 'waiting', '·')
  UIOpen()
  s_cbs[id] = {
    OnDone: (ev) => {
      StopSpinner()
      s_ui_mode = mode .. '_done'
      RecountFinished()
      # 激活和 helptags 都在跑别人的代码。:help simpleplug 承诺“操作结束——
      # 包括失败——都会设好 g:simpleplug_last_result 并触发
      # User SimplePlugComplete”，这个承诺不能被第三方插件或用户配置里的一个
      # 异常作废，否则 :PlugInstall! 会悄悄返回一份上一次的结果字典。
      try
        ActivateInstalled()
        GenerateHelptags()
      catch
        Log('post-batch activation failed: ' .. v:exception, 'WarningMsg')
      finally
        PublishResult()
        UIBuildAndRender()
      endtry
    },
    OnError: (ev) => {
      StopSpinner()
      UIBuildAndRender()
    },
  }
  Send({type: mode, id: id, plugins: specs, jobs: JobCount()})
enddef

# 刚装好的插件在当前会话里直接可用，不必重启 Vim。
#
# End() 只对目录已存在的插件动 'runtimepath'，所以首次启动自动安装完之后，
# 21 个插件全都躺在磁盘上却一个都没生效——作者自己的配置为此在 timer 里整个
# 重新 source .vimrc，那会把每个 mapping、autocmd、option 都重跑一遍。
def ActivateInstalled()
  if !get(g:, 'simpleplug_activate_on_install', 1)
    return
  endif
  var activated = 0
  for name in s_ui_targets
    var st = get(s_ui_plug_state, name, {})
    if get(st, 'action', '') !=# 'installed' || get(s_loaded_plugins, name, false)
      continue
    endif
    var plug = FindPlugin(name)
    if plug == {}
      continue
    endif
    # 第三方代码在一个不寻常的时刻运行：单个插件失败只记在它自己那一行上，
    # 不影响这一批里的其他插件。
    #
    # 整个循环体都在 try 里，不只是 source 插件脚本那一步。SetupLazyLoad 对一个
    # 不是合法命令名的触发器（{on: 'fzf'} 这类笔误）会抛 E183，AddRuntimePath
    # 和 for-pattern autocmd 也各有抛法；这些异常会被 OnDaemonEvent 的 catch
    # 吞掉，顺带把 GenerateHelptags() 和 PublishResult() 一起带走——
    # User SimplePlugComplete 不再触发，g:simpleplug_last_result 停在上一次的值。
    try
      var dir = CheckedRuntimeDir(plug, true)
      if empty(dir)
        st.msg = get(st, 'msg', '') .. ' | not activated'
        s_ui_plug_state[name] = st
        continue
      endif
      if !empty(get(plug, 'on_ft', '')) || !empty(get(plug, 'on_cmd', ''))
        # End() 当时整个跳过了这个插件（目录还不存在），触发器是第一次装上。
        s_loaded_plugins[name] = false
        SetupLazyLoad(plug, dir)
      else
        s_loaded_plugins[name] = true
        AddRuntimePath(dir)
        var failures = SourcePluginScripts(name, dir)
        SourceFtdetect(dir)
        if !empty(failures)
          st.msg = get(st, 'msg', '') .. ' | activate: ' .. failures[0]
          s_ui_plug_state[name] = st
        endif
      endif
      activated += 1
    catch
      st.msg = get(st, 'msg', '') .. ' | activate: ' .. v:exception
      s_ui_plug_state[name] = st
      Log('activation of ' .. name .. ' failed: ' .. v:exception, 'WarningMsg')
    endtry
  endfor
  if activated > 0
    # 已经打开的 buffer 也该认出新插件带来的 filetype。
    silent! doautoall filetypedetect BufRead
  endif
enddef

def GenerateHelptags()
  for p in s_plugins
    var runtime_dir = RuntimeDir(p)
    if !isdirectory(runtime_dir) || !IsInsideCheckout(runtime_dir, p.dir)
      continue
    endif
    var doc = runtime_dir .. '/doc'
    if isdirectory(doc)
      execute 'silent! helptags ' .. fnameescape(doc)
    endif
  endfor
enddef

# ─────────────────── 完成事件与同步等待 ───────────────────

# The machine-readable record of what an operation did.  Without it the only
# way to learn the outcome is to look at the window — or, as scripts actually
# did, poll on a timer and regex-scrape line 2 of the progress buffer.
def PublishResult()
  var counts = SummaryCounts()
  var failed: list<dict<string>> = []
  for name in sort(keys(s_ui_plug_state))
    var st = s_ui_plug_state[name]
    var action = UiAction(st)
    if action ==# 'error' || action ==# 'missing' || action ==# 'dirty'
      add(failed, {name: name, message: get(st, 'msg', '')})
    endif
  endfor
  g:simpleplug_last_result = {
    mode: substitute(s_ui_mode, '_done$', '', ''),
    total: s_ui_total,
    installed: counts.installed,
    updated: counts.updated,
    ok: counts.ok,
    frozen: counts.frozen,
    removed: counts.removed,
    errors: len(failed),
    failed: failed,
    elapsed: empty(s_ui_start_time) ? 0.0 : reltimefloat(reltime(s_ui_start_time)),
  }
  if exists('#User#SimplePlugComplete')
    silent doautocmd <nomodeline> User SimplePlugComplete
  endif
enddef

export def LastResult(): dict<any>
  return get(g:, 'simpleplug_last_result', {})
enddef

def SyncTimeout(): number
  var limit = get(g:, 'simpleplug_sync_timeout', 1800)
  return type(limit) == v:t_number && limit > 0 ? limit : 1800
enddef

# Block until the running operation finishes, then return its result.
#
# `sleep` does two jobs here.  Vim services channel and timer callbacks during
# it — including under -es — which is the only reason the daemon's events are
# delivered while we are parked; and CTRL-C interrupts it and surfaces as a
# catchable Vim:Interrupt, so the wait can always be abandoned.  Polling
# getchar() for CTRL-C instead is not an option: in Ex mode that reads the
# script's own input and quits Vim at EOF, silently truncating exactly the
# headless bootstrap this exists for.
export def Await(timeout: number = -1): dict<any>
  var limit = timeout >= 0 ? timeout : SyncTimeout()
  var start = reltime()
  while s_active_id > 0
    if reltimefloat(reltime(start)) >= limit
      echohl WarningMsg
      echom printf('[SimplePlug] stopped waiting after %ds; the operation is still running', limit)
      echohl None
      break
    endif
    try
      sleep 50m
    catch /^Vim:Interrupt$/
      echom '[SimplePlug] interrupted; stopping the operation'
      Stop()
      break
    endtry
  endwhile
  return LastResult()
enddef

export def Install(names: list<string> = [], sync: bool = false)
  if !EnsureBackend()
    return
  endif
  var plugs = SelectPlugins(names)
  if empty(plugs)
    return
  endif
  RunBatch('install', plugs, PluginSpecs(plugs))
  if sync
    Await()
  endif
enddef

export def AutoInstallMissing()
  if s_auto_install_checked
    return
  endif
  s_auto_install_checked = true

  if !get(g:, 'simpleplug_auto_install', 1)
    return
  endif

  if empty(s_plugins) || MissingPluginCount() == 0
    return
  endif

  Install()
enddef

export def Update(names: list<string> = [], sync: bool = false)
  if !EnsureBackend()
    return
  endif
  var plugs = SelectPlugins(names)
  if empty(plugs)
    return
  endif
  RunBatch('update', plugs, PluginSpecs(plugs))
  if sync
    Await()
  endif
enddef

# =============================================================
# Snapshot / Restore — 记录并恢复所有插件的精确 commit
# =============================================================

var s_snapshot_nonce: number = 0

def SnapshotPath(file: string): string
  return file ==# '' ? g:simpleplug_dir .. '/simpleplug.snapshot.json' : fnamemodify(file, ':p')
enddef


def IsFullGitOid(value: any): bool
  return type(value) == v:t_string && value =~? '^\x\{40}\%([0-9a-f]\{24}\)\?$'
enddef


# Snapshot files deliberately keep the original {name: oid} shape. Strictly
# validating that small format before starting the daemon both preserves old
# lockfiles and prevents arbitrary revision/option strings from reaching Git.
def ReadSnapshot(path: string): dict<string>
  var decoded: any = json_decode(join(readfile(path), "\n"))
  if type(decoded) != v:t_dict
    throw 'snapshot root must be a JSON object'
  endif
  var result: dict<string> = {}
  for [name, oid] in items(decoded)
    if name !~# '^[A-Za-z0-9._-]\+$'
      throw 'invalid plugin name: ' .. string(name)
    endif
    if !IsFullGitOid(oid)
      throw printf('%s must map to a full 40- or 64-digit hexadecimal Git OID', name)
    endif
    result[name] = tolower(oid)
  endfor
  return result
enddef


def CreateSnapshotStageDir(path: string): string
  var parent = fnamemodify(path, ':h')
  var leaf = fnamemodify(path, ':t')
  # mkdir() without "p" is the atomic claim: a pre-existing file, directory or
  # symlink makes the attempt fail, so we never trust an attacker-created path.
  # Once claimed, 0700 protects the fixed child filename from other users.
  for _ in range(128)
    s_snapshot_nonce += 1
    var candidate = printf('%s/.%s.stage.%d.%d', parent, leaf, getpid(), s_snapshot_nonce)
    try
      if mkdir(candidate, '', 0o700)
        return candidate
      endif
    catch
      # An existing directory or symlink raises E739 instead of returning
      # zero. It is only a name collision: never inspect/follow it, just try
      # the next nonce inside the bounded search.
      continue
    endtry
  endfor
  throw 'could not claim a private staging directory'
enddef


# Atomically claim a private directory beside the destination, write a fixed
# child inside that 0700 boundary, then rename the completed file. Unlike a
# getftype()->writefile() sequence, a planted symlink can only make mkdir fail;
# it is never opened. Failed write/rename leaves the existing lockfile intact.
def WriteSnapshotAtomic(path: string, encoded: string): bool
  var parent = fnamemodify(path, ':h')
  try
    if !isdirectory(parent) && mkdir(parent, 'p') == 0 && !isdirectory(parent)
      throw 'cannot create parent directory'
    endif
  catch
    echohl ErrorMsg
    echom printf('[SimplePlug] failed to prepare snapshot directory %s: %s', parent, v:exception)
    echohl None
    return false
  endtry
  if getftype(path) ==# 'link'
    echohl ErrorMsg
    echom '[SimplePlug] refusing to replace snapshot symlink: ' .. path
    echohl None
    return false
  endif

  var stage_dir = ''
  var temporary = ''
  var ok = false
  try
    stage_dir = CreateSnapshotStageDir(path)
    temporary = stage_dir .. '/snapshot'
    if writefile([encoded], temporary) != 0
      throw 'temporary write failed'
    endif
    if rename(temporary, path) != 0
      throw 'atomic rename failed'
    endif
    ok = true
  catch
    echohl ErrorMsg
    echom printf('[SimplePlug] failed to write snapshot %s: %s', path, v:exception)
    echohl None
  finally
    if temporary !=# '' && getftype(temporary) ==# 'file'
      delete(temporary)
    endif
    # Non-recursive removal is intentional: the directory was private and may
    # contain only our fixed file. If that invariant is somehow violated, leave
    # evidence behind instead of recursively deleting an unexpected subtree.
    if stage_dir !=# '' && getftype(stage_dir) ==# 'dir'
      delete(stage_dir, 'd')
    endif
  endtry
  return ok
enddef


def PluginCheckoutState(plugin: dict<any>): dict<string>
  if !isdirectory(plugin.dir)
    return {status: 'missing', oid: ''}
  endif
  if getftype(plugin.dir .. '/.git') ==# ''
    return {status: 'not-git', oid: ''}
  endif
  var commit = trim(system('git -C ' .. shellescape(plugin.dir) .. ' rev-parse HEAD'))
  return v:shell_error == 0 && IsFullGitOid(commit)
    ? {status: 'ok', oid: tolower(commit)}
    : {status: 'unreadable', oid: ''}
enddef


export def Snapshot(file: string = '')
  var path = SnapshotPath(file)
  var snap: dict<string> = {}
  for p in s_plugins
    var checkout = PluginCheckoutState(p)
    if checkout.status ==# 'ok'
      snap[p.name] = checkout.oid
    endif
  endfor
  if !WriteSnapshotAtomic(path, json_encode(snap))
    return
  endif
  echom printf('[SimplePlug] snapshot of %d plugins written to %s', len(snap), path)
enddef


export def SnapshotDiff(file: string = '')
  var path = SnapshotPath(file)
  if !filereadable(path)
    echohl ErrorMsg
    echom '[SimplePlug] snapshot not found: ' .. path
    echohl None
    return
  endif

  # Parse and validate the complete file before reading a checkout or printing
  # a partial report. This shares Restore's strict legacy-format boundary and
  # keeps a malformed lockfile completely side-effect free.
  var snap: dict<string>
  try
    snap = ReadSnapshot(path)
  catch
    echohl ErrorMsg
    echom printf('[SimplePlug] invalid snapshot file %s: %s', path, v:exception)
    echohl None
    return
  endtry

  var registered: dict<bool> = {}
  var rows: list<dict<string>> = []
  var matched = 0
  var drifted = 0
  var missing = 0
  var non_git = 0
  var unreadable = 0
  var unlocked = 0
  var orphaned = 0
  for plugin in s_plugins
    registered[plugin.name] = true
    var checkout = PluginCheckoutState(plugin)
    var actual = checkout.oid
    if !has_key(snap, plugin.name)
      unlocked += 1
      rows->add({name: plugin.name, status: 'unlocked', expected: '', actual: actual,
        reason: checkout.status})
    elseif checkout.status ==# 'missing'
      missing += 1
      rows->add({name: plugin.name, status: 'missing', expected: snap[plugin.name], actual: '', reason: ''})
    elseif checkout.status ==# 'not-git'
      non_git += 1
      rows->add({name: plugin.name, status: 'not-git', expected: snap[plugin.name], actual: '', reason: ''})
    elseif checkout.status ==# 'unreadable'
      unreadable += 1
      rows->add({name: plugin.name, status: 'unreadable', expected: snap[plugin.name], actual: '', reason: ''})
    elseif actual ==# snap[plugin.name]
      matched += 1
      rows->add({name: plugin.name, status: 'matched', expected: snap[plugin.name], actual: actual, reason: ''})
    else
      drifted += 1
      rows->add({name: plugin.name, status: 'drifted', expected: snap[plugin.name], actual: actual, reason: ''})
    endif
  endfor
  for name in keys(snap)
    if !has_key(registered, name)
      orphaned += 1
      rows->add({name: name, status: 'orphaned', expected: snap[name], actual: '', reason: ''})
    endif
  endfor
  rows->sort((left, right) => left.name ==# right.name ? 0 : (left.name <# right.name ? -1 : 1))

  echom printf('[SimplePlug] snapshot diff: matched=%d drifted=%d missing=%d non-git=%d unreadable=%d unlocked=%d orphaned=%d',
    matched, drifted, missing, non_git, unreadable, unlocked, orphaned)
  for row in rows
    if row.status ==# 'matched'
      echom printf('  [matched] %s current=%s', row.name, row.actual)
    elseif row.status ==# 'drifted'
      echom printf('  [drifted] %s expected=%s current=%s', row.name, row.expected, row.actual)
    elseif row.status ==# 'missing'
      echom printf('  [missing] %s expected=%s (checkout directory absent)', row.name, row.expected)
    elseif row.status ==# 'not-git'
      echom printf('  [not-git] %s expected=%s (.git metadata absent)', row.name, row.expected)
    elseif row.status ==# 'unreadable'
      echom printf('  [unreadable] %s expected=%s (HEAD is not a full Git OID)', row.name, row.expected)
    elseif row.status ==# 'unlocked'
      echom printf('  [unlocked] %s%s', row.name,
        row.actual !=# '' ? ' current=' .. row.actual : ' (' .. row.reason .. ')')
    else
      echom printf('  [orphaned] %s expected=%s (not registered)', row.name, row.expected)
    endif
  endfor
enddef

export def Restore(file: string = '')
  var path = SnapshotPath(file)
  if !filereadable(path)
    echohl ErrorMsg
    echom '[SimplePlug] snapshot not found: ' .. path
    echohl None
    return
  endif
  var snap: dict<string>
  try
    snap = ReadSnapshot(path)
  catch
    echohl ErrorMsg
    echom printf('[SimplePlug] invalid snapshot file %s: %s', path, v:exception)
    echohl None
    return
  endtry
  var plugs: list<dict<any>> = []
  for p in s_plugins
    if has_key(snap, p.name)
      add(plugs, p)
    endif
  endfor
  if empty(plugs)
    echom '[SimplePlug] snapshot matches no registered plugins'
    return
  endif
  if !EnsureBackend()
    return
  endif
  var specs = PluginSpecs(plugs)
  for spec in specs
    spec.commit = snap[spec.name]
    # Restoring a lockfile is an explicit instruction to move this checkout, so
    # `frozen` must not veto it. The daemon tests frozen before it looks at the
    # commit pin, and would report the plugin as skipped while leaving it where
    # it was — rendered as a plain `frozen` row, which reads as success.
    # Freezing means "an update does not touch this", not "a restore silently
    # does nothing".
    spec.frozen = false
  endfor
  RunBatch('update', plugs, specs)
enddef

export def Clean(force: bool = false)
  if !EnsureBackend()
    return
  endif
  if !force && confirm('[SimplePlug] Remove unregistered Git plugin directories?', "&Yes\n&No", 2) != 1
    return
  endif
  var id = StartRequest('clean')
  if id == 0
    return
  endif
  var keep: list<string> = []
  for p in s_plugins
    if NormalDir(fnamemodify(p.dir, ':h')) ==# NormalDir(g:simpleplug_dir)
      add(keep, fnamemodify(p.dir, ':t'))
    endif
  endfor
  # Never let SimplePlug clean its own checkout when it lives in plugdir.
  var manager_dir = s_plugin_root
  if NormalDir(fnamemodify(manager_dir, ':h')) ==# NormalDir(g:simpleplug_dir)
    add(keep, fnamemodify(manager_dir, ':t'))
  endif
  s_ui_total = 0
  s_ui_finished = 0
  s_ui_start_time = reltime()
  s_ui_plug_state = {}
  s_ui_targets = []
  UIOpen()
  Send({type: 'clean', id: id, plugdir: g:simpleplug_dir, keep: keep})
enddef

export def Status()
  if !EnsureBackend()
    return
  endif
  var id = StartRequest('status')
  if id == 0
    return
  endif
  s_ui_total = len(s_plugins)
  s_ui_finished = 0
  s_ui_start_time = reltime()
  InitPlugStates(s_plugins, 'waiting', '·')
  UIOpen()
  Send({type: 'status', id: id, plugins: PluginSpecs(s_plugins), jobs: JobCount()})
enddef

export def RunHook(name: string)
  if !EnsureBackend()
    return
  endif
  var plug = FindPlugin(name)
  if plug == {}
    echohl ErrorMsg
    echom '[SimplePlug] plugin not found: ' .. name
    echohl None
    return
  endif
  var do_cmd = get(plug, 'do', '')
  if do_cmd ==# ''
    echom '[SimplePlug] no hook for: ' .. name
    return
  endif
  var id = StartRequest('hook')
  if id == 0
    return
  endif
  s_ui_total = 1
  s_ui_finished = 0
  s_ui_start_time = reltime()
  s_ui_plug_state = {}
  s_ui_plug_state[name] = {status: 'waiting', msg: '', icon: '·', branch: '', commit: '', dirty: false}
  s_ui_targets = [name]
  UIOpen()
  Send({type: 'post_hook', id: id, name: name, dir: plug.dir, cmd: do_cmd})
enddef

export def CompletePluginNames(arglead: string, cmdline: string, cursorpos: number): list<string>
  var names: list<string> = []
  for p in s_plugins
    if stridx(tolower(p.name), tolower(arglead)) == 0
      add(names, p.name)
    endif
  endfor
  return names
enddef

# =============================================================
# 事件处理
# =============================================================

def InitPlugStates(plugs: list<dict<any>>, status: string, icon: string)
  s_ui_plug_state = {}
  s_ui_plug_timings = {}
  s_ui_plug_start_times = {}
  s_ui_cursor_name = ''
  s_ui_filter_text = ''
  s_ui_filter_active = false
  s_ui_targets = mapnew(plugs, (_, p) => p.name)
  for p in plugs
    s_ui_plug_state[p.name] = {status: status, msg: '', icon: icon, action: '', branch: '', commit: '', dirty: false}
  endfor
enddef

def OnProgress(ev: dict<any>)
  var name = get(ev, 'name', '')
  var status = get(ev, 'status', '')
  var msg = get(ev, 'message', '')

  if !has_key(s_ui_plug_state, name)
    s_ui_plug_state[name] = {status: '', msg: '', icon: '', action: '', branch: '', commit: '', dirty: false}
  endif
  var st = s_ui_plug_state[name]

  # 记录插件开始时间
  if !has_key(s_ui_plug_start_times, name) && status !=# 'hook'
    s_ui_plug_start_times[name] = reltime()
  endif

  if status ==# 'working'
    st.status = 'working'
    st.icon = '·'
    st.action = 'working'
    st.msg = msg
  elseif status ==# 'installed'
    st.status = 'done'
    st.icon = '+'
    st.action = 'installed'
    st.msg = msg
    if has_key(s_ui_plug_start_times, name)
      s_ui_plug_timings[name] = reltimefloat(reltime(s_ui_plug_start_times[name]))
    endif
  elseif status ==# 'updated'
    st.status = 'done'
    st.icon = '*'
    st.action = 'updated'
    st.msg = msg
    if has_key(s_ui_plug_start_times, name)
      s_ui_plug_timings[name] = reltimefloat(reltime(s_ui_plug_start_times[name]))
    endif
  elseif status ==# 'already'
    st.status = 'done'
    st.icon = '●'
    st.action = 'ok'
    st.msg = msg
    if has_key(s_ui_plug_start_times, name)
      s_ui_plug_timings[name] = reltimefloat(reltime(s_ui_plug_start_times[name]))
    endif
  elseif status ==# 'skipped'
    st.status = 'skipped'
    st.icon = '○'
    st.action = 'frozen'
    st.msg = msg
    if has_key(s_ui_plug_start_times, name)
      s_ui_plug_timings[name] = reltimefloat(reltime(s_ui_plug_start_times[name]))
    endif
  elseif status ==# 'dirty'
    st.status = 'error'
    st.icon = '!'
    st.action = 'dirty'
    st.msg = msg
    if has_key(s_ui_plug_start_times, name)
      s_ui_plug_timings[name] = reltimefloat(reltime(s_ui_plug_start_times[name]))
    endif
  elseif status ==# 'hook'
    if get(st, 'action', '') ==# '' || st.action ==# 'waiting' || st.action ==# 'working'
      st.action = 'hook'
    endif
    st.msg ..= (st.msg ==# '' ? '' : ' | ') .. msg
  elseif status ==# 'error'
    st.status = 'error'
    st.icon = '✘'
    st.action = 'error'
    st.msg = msg
    if has_key(s_ui_plug_start_times, name)
      s_ui_plug_timings[name] = reltimefloat(reltime(s_ui_plug_start_times[name]))
    endif
  endif

  s_ui_plug_state[name] = st
  RecountFinished()
  UIBuildAndRender()
enddef

def OnDone(ev: dict<any>)
  # 由回调处理
enddef

def OnError(ev: dict<any>)
  var msg = get(ev, 'message', '')
  Log('Error: ' .. msg, 'ErrorMsg')
  StopSpinner()
  var marked = false
  for [name, st] in items(s_ui_plug_state)
    if !IsFinishedStatus(get(st, 'status', ''))
      st.status = 'error'
      st.action = 'error'
      st.icon = '✘'
      st.msg = msg
      s_ui_plug_state[name] = st
      marked = true
    endif
  endfor
  if !marked && empty(s_ui_plug_state)
    s_ui_plug_state['SimplePlug'] = {status: 'error', msg: msg, icon: '✘', action: 'error', branch: '', commit: '', dirty: false}
    s_ui_total = 1
  endif
  RecountFinished()
  s_ui_mode ..= s_ui_mode =~# '_done$' ? '' : '_done'
  PublishResult()
  UIBuildAndRender()
enddef

def OnStatusResult(ev: dict<any>)
  StopSpinner()
  var items = get(ev, 'items', [])
  for item in items
    var name = item.name
    if !has_key(s_ui_plug_state, name)
      s_ui_plug_state[name] = {status: '', msg: '', icon: '', action: '', branch: '', commit: '', dirty: false, size_kb: 0}
    endif
    var st = s_ui_plug_state[name]
    if item.installed
      st.status = 'done'
      st.icon = '●'
      st.action = 'ok'
      var plug = FindPlugin(name)
      if plug != {} && (get(plug, 'tag', '') !=# '' || get(plug, 'commit', '') !=# '')
        st.action = 'pinned'
        st.icon = '◆'
      endif
      st.branch = item.branch
      st.commit = item.commit
      st.dirty = item.dirty
      st.size_kb = get(item, 'size_kb', 0)
      st.last_commit = get(item, 'last_commit', '')
      st.msg = ''
    else
      st.status = 'error'
      st.icon = '✘'
      st.action = 'missing'
      st.msg = 'not installed'
    endif
    s_ui_plug_state[name] = st
  endfor
  s_ui_finished = len(items)
  s_ui_mode = 'status_done'
  PublishResult()
  UIBuildAndRender()
enddef

def OnHookDone(ev: dict<any>)
  StopSpinner()
  var name = get(ev, 'name', '')
  var ok = get(ev, 'ok', false)
  var output = get(ev, 'output', '')
  if !has_key(s_ui_plug_state, name)
    s_ui_plug_state[name] = {status: '', msg: '', icon: '', action: '', branch: '', commit: '', dirty: false}
  endif
  var st = s_ui_plug_state[name]
  st.status = ok ? 'done' : 'error'
  st.icon = ok ? '●' : '✘'
  st.action = ok ? 'hook' : 'error'
  st.msg = output
  s_ui_plug_state[name] = st
  s_ui_mode = 'hook_done'
  PublishResult()
  UIBuildAndRender()
enddef

def OnCleanDone(ev: dict<any>)
  StopSpinner()
  var removed = get(ev, 'removed', [])
  for r in removed
    s_ui_plug_state[r] = {status: 'removed', msg: 'removed', icon: '-', action: 'removed', branch: '', commit: '', dirty: false}
  endfor
  s_ui_finished = len(removed)
  s_ui_mode = 'clean_done'
  PublishResult()
  UIBuildAndRender()
enddef

# =============================================================
# UI — 插件状态面板 (右侧 split + 交互 + 视觉)
# =============================================================

def Elapsed(): string
  if empty(s_ui_start_time)
    return '0.0s'
  endif
  var ms = reltimefloat(reltime(s_ui_start_time))
  return printf('%.1fs', ms)
enddef

def ProgressBar(done: number, total: number, width: number): string
  if total <= 0
    return repeat('─', width)
  endif
  var filled = done * width / total
  if filled > width
    filled = width
  endif
  var bar = repeat('█', filled) .. repeat('░', width - filled)
  return bar
enddef

def SpinnerTick(timer: number)
  s_ui_spinner_idx = (s_ui_spinner_idx + 1) % len(s_spinners)
  UIBuildAndRender()
enddef

def StartSpinner()
  StopSpinner()
  var interval = get(g:, 'simpleplug_spinner_interval', 200)
  s_ui_spinner_timer = timer_start(interval, function('SpinnerTick'), {repeat: -1})
enddef

def StopSpinner()
  if s_ui_spinner_timer > 0
    timer_stop(s_ui_spinner_timer)
    s_ui_spinner_timer = 0
  endif
enddef

def ModeTitle(): string
  if s_ui_mode ==# 'install'
    return 'Installing Plugins'
  elseif s_ui_mode ==# 'install_done'
    return 'Install Complete'
  elseif s_ui_mode ==# 'update'
    return 'Updating Plugins'
  elseif s_ui_mode ==# 'update_done'
    return 'Update Complete'
  elseif s_ui_mode ==# 'status' || s_ui_mode ==# 'status_done'
    return 'Plugin Status'
  elseif s_ui_mode ==# 'clean' || s_ui_mode ==# 'clean_done'
    return 'Clean Plugins'
  elseif s_ui_mode ==# 'hook' || s_ui_mode ==# 'hook_done'
    return 'Post-Install Hook'
  endif
  return 'SimplePlug'
enddef

def IsDone(): bool
  return s_ui_mode =~# '_done$'
enddef

def IsInstallUpdateRunning(): bool
  return s_ui_mode ==# 'install' || s_ui_mode ==# 'update'
enddef

def IsInstallUpdateMode(): bool
  return s_ui_mode ==# 'install'
    || s_ui_mode ==# 'update'
    || s_ui_mode ==# 'install_done'
    || s_ui_mode ==# 'update_done'
enddef

def IsFinishedStatus(status: string): bool
  return status ==# 'done' || status ==# 'error' || status ==# 'skipped'
enddef

def RecountFinished()
  var finished = 0
  for [_, st] in items(s_ui_plug_state)
    if IsFinishedStatus(get(st, 'status', ''))
      finished += 1
    endif
  endfor
  s_ui_finished = finished > s_ui_total ? s_ui_total : finished
enddef

# ─────────────────── 排序插件列表 ───────────────────

def FormatSize(kb: number): string
  if kb <= 0
    return '—'
  elseif kb < 1024
    return printf('%dK', kb)
  else
    return printf('%.1fM', kb / 1024.0)
  endif
enddef

def SortedPluginNames(): list<string>
  # install/update 进行中: working > done/error > waiting
  #
  # 但只在用户还没选中任何一行之前。一旦选了，顺序就冻住：否则他刚翻到的
  # 那一行会在下一次 spinner tick 里被重新排走。
  if IsInstallUpdateRunning() && s_ui_cursor_name ==# ''
    var working: list<string> = []
    var finished: list<string> = []
    var waiting: list<string> = []
    for name in s_ui_targets
      var st = get(s_ui_plug_state, name, {})
      var status = get(st, 'status', 'waiting')
      if status ==# 'waiting'
        add(waiting, name)
      elseif status ==# 'done' || status ==# 'error' || status ==# 'skipped'
        add(finished, name)
      else
        add(working, name)
      endif
    endfor
    return working + finished + waiting
  endif
  # 其他模式保持注册顺序
  return copy(s_ui_targets)
enddef

def GetDisplayPlugins(): list<dict<any>>
  var plugs: list<dict<any>> = []
  for n in s_ui_targets
    var p = FindPlugin(n)
    if p != {}
      add(plugs, p)
    endif
  endfor
  # 应用过滤
  if s_ui_filter_text !=# ''
    var needle = tolower(s_ui_filter_text)
    return filter(plugs, (_, p) => stridx(tolower(p.name), needle) >= 0)
  endif
  return plugs
enddef

# ─────────────────── 内容构建 ───────────────────

const s_default_width = 88

def UiWidth(): number
  return get(g:, 'simpleplug_window_width', s_default_width)
enddef

def ShortLine(content: string, width: number): string
  var text = content
  if width <= 0
    return ''
  endif
  while strdisplaywidth(text) > width && strchars(text) > 0
    text = strcharpart(text, 0, strchars(text) - 1)
  endwhile
  return text
enddef

def AlignLine(left: string, right: string, width: number): string
  var gap = width - strdisplaywidth(left) - strdisplaywidth(right)
  if gap < 1
    return ShortLine(left .. ' ' .. right, width)
  endif
  return left .. repeat(' ', gap) .. right
enddef

# 行尾不补空格：补齐出来的尾随空白会被用户配置里常见的
# trailing-whitespace 高亮染成红色背景
def AddUiLine(lines: list<string>, content: string, width: number)
  add(lines, substitute(ShortLine(content, width), '\s\+$', '', ''))
enddef

def DividerLine(width: number): string
  return repeat('─', width)
enddef

def UiAction(st: dict<any>): string
  var action = get(st, 'action', '')
  if action !=# ''
    return action
  endif
  var status = get(st, 'status', 'waiting')
  if status ==# 'done'
    return 'ok'
  elseif status ==# 'error'
    return 'error'
  elseif status ==# 'skipped'
    return 'frozen'
  elseif status ==# 'removed'
    return 'removed'
  elseif status ==# 'working'
    return 'working'
  endif
  return 'waiting'
enddef

def UiIcon(st: dict<any>, is_done: bool): string
  var icon = get(st, 'icon', '')
  if icon !=# '' && icon !=# '·'
    return icon
  endif
  var action = UiAction(st)
  if action ==# 'installed'
    return '+'
  elseif action ==# 'updated'
    return '*'
  elseif action ==# 'ok' || action ==# 'hook'
    return '●'
  elseif action ==# 'pinned'
    return '◆'
  elseif action ==# 'error' || action ==# 'missing'
    return '✘'
  elseif action ==# 'frozen'
    return '○'
  elseif action ==# 'dirty'
    return '!'
  elseif action ==# 'removed'
    return '-'
  endif
  return is_done ? '○' : s_spinners[s_ui_spinner_idx]
enddef

def SummaryCounts(): dict<number>
  var counts = {installed: 0, updated: 0, ok: 0, frozen: 0, dirty: 0, errors: 0, removed: 0, missing: 0}
  for [_, st] in items(s_ui_plug_state)
    var action = UiAction(st)
    if action ==# 'installed'
      counts.installed += 1
    elseif action ==# 'updated'
      counts.updated += 1
    elseif action ==# 'ok' || action ==# 'hook' || action ==# 'pinned'
      counts.ok += 1
    elseif action ==# 'frozen'
      counts.frozen += 1
    elseif action ==# 'dirty'
      counts.dirty += 1
    elseif action ==# 'removed'
      counts.removed += 1
    elseif action ==# 'missing'
      counts.missing += 1
    elseif action ==# 'error'
      counts.errors += 1
    endif
  endfor
  return counts
enddef

def SetUiBufferLines()
  if s_ui_bufnr < 0 || !bufexists(s_ui_bufnr)
    return
  endif

  var old_last = 1
  var info = getbufinfo(s_ui_bufnr)
  if !empty(info)
    old_last = info[0].linecount
  endif

  var new_lines = empty(s_ui_lines) ? [''] : s_ui_lines
  setbufvar(s_ui_bufnr, '&modifiable', 1)
  setbufline(s_ui_bufnr, 1, new_lines)
  if old_last > len(new_lines)
    deletebufline(s_ui_bufnr, len(new_lines) + 1, old_last)
  endif
  setbufvar(s_ui_bufnr, '&modifiable', 0)
enddef

def UIBuildAndRender(move_cursor: bool = false)
  var lines: list<string> = []
  var title = ModeTitle()
  var is_done = IsDone()
  var spinner = is_done ? '✓' : s_spinners[s_ui_spinner_idx]
  var W = UiWidth()

  s_ui_sorted_names = SortedPluginNames()
  s_ui_cursor_buf_line = 0
  s_ui_line_map = {}
  var display_plugins = GetDisplayPlugins()

  var shown_finished = s_ui_finished > s_ui_total ? s_ui_total : s_ui_finished
  var pct = s_ui_total > 0 ? (shown_finished * 100 / s_ui_total) : 0
  var header_left = '  SimplePlug'
  var header_right = spinner .. '  ' .. title .. '  ' .. Elapsed()
  AddUiLine(lines, AlignLine(header_left, header_right, W), W)

  var counts = SummaryCounts()
  var stats = printf('  total %d  installed %d  updated %d  ok %d  frozen %d  errors %d',
    s_ui_total, counts.installed, counts.updated, counts.ok, counts.frozen, counts.errors + counts.missing + counts.dirty)
  if counts.removed > 0
    stats ..= printf('  removed %d', counts.removed)
  endif
  AddUiLine(lines, stats, W)

  if IsInstallUpdateMode()
    var bar = ProgressBar(shown_finished, s_ui_total, W - 22)
    AddUiLine(lines, printf('  %s  %3d%%  %d/%d', bar, pct, shown_finished, s_ui_total), W)
  endif

  add(lines, DividerLine(W))

  AddUiLine(lines, printf('  %-2s %-30s %-12s %-10s %s', '', 'Plugin', 'State', 'Time', 'Details'), W)
  add(lines, DividerLine(W))

  var sorted = s_ui_sorted_names
  if s_ui_filter_text !=# ''
    var filter_names = mapnew(display_plugins, (_, p) => p.name)
    sorted = filter(copy(sorted), (_, n) => index(filter_names, n) >= 0)
  endif
  if s_ui_mode =~# 'clean'
    sorted = []
  endif
  if index(sorted, s_ui_cursor_name) < 0
    # 选中的插件被过滤掉或已经不在这一批里了。
    s_ui_cursor_name = ''
  endif

  for pname in sorted
    var p = FindPlugin(pname)
    if p == {}
      continue
    endif
    var name = p.name
    var st = get(s_ui_plug_state, name, {status: 'waiting', msg: '', icon: '·', action: '', branch: '', commit: '', dirty: false})
    var icon = UiIcon(st, is_done)
    var msg = get(st, 'msg', '')
    var action = UiAction(st)

    var is_cursor = (name ==# s_ui_cursor_name)
    var cursor_mark = is_cursor ? '▸' : ' '
    s_ui_line_map[string(len(lines) + 1)] = name
    if is_cursor
      s_ui_cursor_buf_line = len(lines) + 1
    endif

    var display_name = ShortLine(name, 30)
    var version = ''
    if s_ui_mode ==# 'status_done'
      var branch = get(st, 'branch', '')
      var commit = get(st, 'commit', '')
      var dirty = get(st, 'dirty', false)
      var size_str = FormatSize(get(st, 'size_kb', 0))
      version = branch !=# '' ? ShortLine(branch, 10) : '—'
      msg = (commit !=# '' ? commit[: 7] : '—') .. (dirty ? ' dirty' : '') .. '  ' .. size_str
      var last_commit = get(st, 'last_commit', '')
      if last_commit !=# ''
        msg ..= '  ' .. last_commit
      endif
    else
      version = has_key(s_ui_plug_timings, name) ? printf('%.1fs', s_ui_plug_timings[name]) : '—'
      if action ==# 'waiting' && !is_done
        msg = 'waiting'
      elseif action ==# 'frozen'
        msg = 'locked'
      endif
    endif
    var details_width = W - 62
    var content = printf('%s %s %-30s %-12s %-10s %s',
      cursor_mark, icon, display_name, action, version, ShortLine(msg, details_width))
    AddUiLine(lines, content, W)
  endfor

  if s_ui_mode =~# 'clean'
    if empty(s_ui_plug_state)
      AddUiLine(lines, '  Nothing to clean.', W)
    else
      for [cname, cst] in items(s_ui_plug_state)
        var c = printf('  %s %-30s removed      —          removed', UiIcon(cst, true), ShortLine(cname, 30))
        AddUiLine(lines, c, W)
      endfor
    endif
  endif

  if s_ui_filter_active
    var filter_line = '  / ' .. s_ui_filter_text .. '▏'
    add(lines, DividerLine(W))
    AddUiLine(lines, filter_line, W)
  endif

  add(lines, DividerLine(W))
  AddUiLine(lines, '  ' .. SummaryLine(), W)
  AddUiLine(lines, '  q close   j/k move   <CR> open   d log   / filter   ? help   R retry failed   S status', W)

  s_ui_lines = lines
  UIRender(move_cursor)
enddef

def SummaryLine(): string
  var counts = SummaryCounts()
  var parts: list<string> = []
  if counts.installed > 0
    add(parts, printf('%d installed', counts.installed))
  endif
  if counts.updated > 0
    add(parts, printf('%d updated', counts.updated))
  endif
  if counts.ok > 0
    add(parts, printf('%d ok', counts.ok))
  endif
  if counts.frozen > 0
    add(parts, printf('%d frozen', counts.frozen))
  endif
  if counts.dirty > 0
    add(parts, printf('%d dirty', counts.dirty))
  endif
  if counts.removed > 0
    add(parts, printf('%d removed', counts.removed))
  endif
  var errors = counts.errors + counts.missing
  if errors > 0
    add(parts, printf('%d errors', errors))
  endif
  if empty(parts)
    return 'Waiting for plugins  (' .. Elapsed() .. ')'
  endif
  return join(parts, '  ') .. '  (' .. Elapsed() .. ')'
enddef

# ─────────────────── 窗口管理 ───────────────────

def UIOpen()
  # 如果已有窗口，复用
  if s_ui_bufnr > 0 && bufexists(s_ui_bufnr)
    var wins = win_findbuf(s_ui_bufnr)
    if !empty(wins)
      win_gotoid(wins[0])
      s_ui_winid = wins[0]
      UIBuildAndRender(true)
      StartSpinner()
      return
    endif
  endif

  # 新建右侧分屏
  botright vertical new
  execute ':vertical resize ' .. UiWidth()
  s_ui_winid = win_getid()
  s_ui_bufnr = bufnr()
  setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
  setlocal filetype=simpleplug
  setlocal nowrap nonumber norelativenumber signcolumn=no
  setlocal modifiable
  setlocal cursorline

  # 按键映射
  nnoremap <buffer><silent> q <Cmd>call simpleplug#UIClose()<CR>
  nnoremap <buffer><silent> <Esc> <Cmd>call simpleplug#UIClose()<CR>
  nnoremap <buffer><silent> j <Cmd>call simpleplug#UIMove(1)<CR>
  nnoremap <buffer><silent> k <Cmd>call simpleplug#UIMove(-1)<CR>
  nnoremap <buffer><silent> R <Cmd>call simpleplug#UIRetry()<CR>
  nnoremap <buffer><silent> S <Cmd>call simpleplug#Status()<CR>
  nnoremap <buffer><silent> <CR> <Cmd>call simpleplug#OpenPluginDir()<CR>
  nnoremap <buffer><silent> d <Cmd>call simpleplug#ViewPluginDiff()<CR>
  nnoremap <buffer><silent> h <Cmd>call simpleplug#ToggleHelp()<CR>
  nnoremap <buffer><silent> ? <Cmd>call simpleplug#ToggleHelp()<CR>
  nnoremap <buffer><silent> / <Cmd>call simpleplug#StartFilterSplit()<CR>

  UIBuildAndRender(true)
  SetupSyntax()
  StartSpinner()
enddef

export def UIClose()
  StopSpinner()
  if s_ui_bufnr > 0 && bufexists(s_ui_bufnr)
    execute 'bwipeout ' .. s_ui_bufnr
  endif
  s_ui_bufnr = -1
  s_ui_winid = 0
  s_ui_filter_active = false
  s_ui_filter_text = ''
enddef

export def UIRetry()
  var failed: list<string> = []
  for name in s_ui_targets
    var action = UiAction(get(s_ui_plug_state, name, {}))
    if action ==# 'error' || action ==# 'missing' || action ==# 'dirty'
      add(failed, name)
    endif
  endfor
  if empty(failed)
    echom '[SimplePlug] nothing to retry'
    return
  endif
  if s_ui_mode =~# 'install'
    Install(failed)
  elseif s_ui_mode =~# 'update'
    Update(failed)
  endif
enddef

def UIRender(move_cursor: bool = false)
  if s_ui_bufnr < 0 || !bufexists(s_ui_bufnr)
    return
  endif
  var wins = win_findbuf(s_ui_bufnr)
  if empty(wins)
    return
  endif
  SetUiBufferLines()
  win_execute(wins[0], ':vertical resize ' .. UiWidth())
  # 只有在选择本身发生变化时才动光标。以前每次渲染都动，于是 200ms 的
  # spinner tick 会把光标一次次拽回去，翻到出错的那个插件根本不可能。
  if move_cursor && s_ui_cursor_buf_line > 0
    win_execute(wins[0], 'normal! ' .. s_ui_cursor_buf_line .. 'G')
  endif
enddef

# ─────────────────── 交互功能 ───────────────────

# Buffer lines that carry a plugin, in display order.
def PluginRows(): list<number>
  return sort(mapnew(keys(s_ui_line_map), (_, k) => str2nr(k)), 'N')
enddef

# The row the user is actually on.  Resolved from the line map built during
# rendering, never by matching plugin names against the rendered text: doing
# that made a name that is a prefix of another shadow it, so pressing <CR> on
# the simpletreesitter row opened simpletree.
def PluginNameAtCursor(): string
  var name = get(s_ui_line_map, string(line('.')), '')
  return name !=# '' ? name : s_ui_cursor_name
enddef

export def UIMove(delta: number)
  var rows = PluginRows()
  if empty(rows)
    return
  endif
  var idx = index(rows, line('.'))
  idx = idx < 0 ? 0 : max([0, min([idx + delta, len(rows) - 1])])
  s_ui_cursor_name = get(s_ui_line_map, string(rows[idx]), '')
  UIBuildAndRender(true)
enddef

def DoViewPluginDiff(name: string)
  if name ==# ''
    return
  endif
  var plug = FindPlugin(name)
  if plug == {} || !isdirectory(plug.dir)
    return
  endif
  var log_output = system('git -C ' .. shellescape(plug.dir) .. ' log --oneline --graph --decorate -20 2>/dev/null')
  if log_output ==# ''
    log_output = '  (no git log available)'
  endif
  var log_lines = split(log_output, "\n")

  botright new
  setlocal buftype=nofile bufhidden=wipe noswapfile
  setlocal nowrap nonumber norelativenumber signcolumn=no
  setline(1, ['  ' .. name .. ' git log', repeat('─', 60)] + log_lines)
  setlocal nomodifiable
  nnoremap <buffer><silent> q <Cmd>bwipeout<CR>
enddef

def DoToggleHelp()
  var help_lines = [
    '',
    '     SimplePlug 快捷键',
    '    ────────────────────────',
    '    j / k       上下滚动',
    '    Enter       打开插件目录',
    '    d           查看 git log',
    '    /           搜索过滤插件',
    '    R           重试失败的插件',
    '    S           查看状态',
    '    q / Esc     关闭窗口',
    '    ? / h       切换帮助',
    '',
  ]

  botright new
  setlocal buftype=nofile bufhidden=wipe noswapfile
  setlocal nowrap nonumber norelativenumber signcolumn=no
  setline(1, help_lines)
  setlocal nomodifiable
  nnoremap <buffer><silent> q <Cmd>bwipeout<CR>
enddef

export def OpenPluginDir()
  var name = PluginNameAtCursor()
  if name ==# ''
    return
  endif
  var plug = FindPlugin(name)
  if plug == {} || !isdirectory(plug.dir)
    return
  endif
  var dir = plug.dir
  UIClose()
  execute 'edit ' .. fnameescape(dir)
enddef

export def ViewPluginDiff()
  var name = PluginNameAtCursor()
  if name ==# ''
    return
  endif
  s_ui_cursor_name = name
  DoViewPluginDiff(name)
enddef

export def ToggleHelp()
  DoToggleHelp()
enddef

export def StartFilterSplit()
  s_ui_filter_text = input(' Filter: ')
  UIBuildAndRender()
enddef

# ─────────────────── 语法高亮 ───────────────────

def SetupSyntax()
  if s_ui_bufnr < 0 || !bufexists(s_ui_bufnr)
    return
  endif
  var wins = win_findbuf(s_ui_bufnr)
  if empty(wins)
    return
  endif
  var w = wins[0]

  win_execute(w, 'syntax clear')
  # 边框
  win_execute(w, 'syntax match SPlugBorder /[╭╮╰╯├┤│─┬┴]/')
  # 标题
  win_execute(w, 'syntax match SPlugTitle /\(Installing\|Updating\|Plugin Status\|Install Complete\|Update Complete\|Clean\|Post-Install Hook\|SimplePlug\)/')
  # 计数 (3/25)
  win_execute(w, 'syntax match SPlugCount /(\d\+\/\d\+)/')
  # 进度条
  win_execute(w, 'syntax match SPlugBarFill /█/')
  win_execute(w, 'syntax match SPlugBarEmpty /░/')
  win_execute(w, 'syntax match SPlugPct /\d\+%/')
  # 状态图标
  win_execute(w, 'syntax match SPlugIconOk /●/')
  win_execute(w, 'syntax match SPlugIconPin /◆/')
  win_execute(w, 'syntax match SPlugStatePin /pinned/')
  win_execute(w, 'syntax match SPlugIconNew /+/')
  win_execute(w, 'syntax match SPlugIconUp /\*/')
  win_execute(w, 'syntax match SPlugIconErr /✘/')
  win_execute(w, 'syntax match SPlugIconDirty /!/')
  win_execute(w, 'syntax match SPlugIconSkip /○/')
  win_execute(w, 'syntax match SPlugIconWait /·/')
  win_execute(w, 'syntax match SPlugIconRemove /-/')
  # 时间
  win_execute(w, 'syntax match SPlugTime /\d\+\.\d\+s/')
  # spinner
  win_execute(w, 'syntax match SPlugSpinner /[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/')
  # ✓
  win_execute(w, 'syntax match SPlugCheckDone /✓/')
  # 光标指示
  win_execute(w, 'syntax match SPlugCursor /▸/')
  # 帮助文本
  win_execute(w, 'syntax match SPlugHelp /q close.*$/')
  # 表头
  win_execute(w, 'syntax match SPlugTableHeader /Plugin\s\+State\s\+Time\s\+Details/')
  # 状态文本
  win_execute(w, 'syntax match SPlugStateNew /installed/')
  win_execute(w, 'syntax match SPlugStateUp /updated/')
  win_execute(w, 'syntax match SPlugStateOk /\<ok\>/')
  win_execute(w, 'syntax match SPlugStateErr /\(error\|missing\)/')
  win_execute(w, 'syntax match SPlugStateDirty /dirty/')
  win_execute(w, 'syntax match SPlugStateHook /hook/')
  # waiting
  win_execute(w, 'syntax match SPlugWaiting /waiting/')
  # frozen
  win_execute(w, 'syntax match SPlugFrozen /frozen/')
  # removed
  win_execute(w, 'syntax match SPlugRemoved /removed/')
  # 搜索栏
  win_execute(w, 'syntax match SPlugFilter /\/ .*▏/')
  # summary
  win_execute(w, 'syntax match SPlugSumInstalled / \d\+ installed/')
  win_execute(w, 'syntax match SPlugSumUpdated / \d\+ updated/')
  win_execute(w, 'syntax match SPlugSumOk / \d\+ ok/')
  win_execute(w, 'syntax match SPlugSumFrozen / \d\+ frozen/')
  win_execute(w, 'syntax match SPlugSumRemoved / \d\+ removed/')
  win_execute(w, 'syntax match SPlugSumErrors / \d\+ errors/')
  # diff stats
  win_execute(w, 'syntax match SPlugDiffAdd /\d\+ insertion\(s\)\=/')
  win_execute(w, 'syntax match SPlugDiffDel /\d\+ deletion\(s\)\=/')
  # size
  win_execute(w, 'syntax match SPlugSize /\d\+\(\.\d\+\)\=[KM]\>/')
  # 错误消息
  win_execute(w, 'syntax match SPlugErrMsg /not installed/')

  # ── highlight 定义 ──
  # 基础
  win_execute(w, 'highlight default SPlugNormal ctermbg=235 guibg=#1e1e2e')
  win_execute(w, 'highlight default SPlugBorder ctermfg=240 guifg=#585858')
  # 标题
  win_execute(w, 'highlight default SPlugTitle ctermfg=75 guifg=#5fafff cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugCount ctermfg=252 guifg=#d0d0d0')
  # 进度条 (渐变色)
  win_execute(w, 'highlight default SPlugBarFill ctermfg=114 guifg=#87d787')
  win_execute(w, 'highlight default SPlugBarEmpty ctermfg=238 guifg=#444444')
  win_execute(w, 'highlight default SPlugPct ctermfg=252 guifg=#d0d0d0 cterm=bold gui=bold')
  # 状态图标
  win_execute(w, 'highlight default SPlugIconOk ctermfg=114 guifg=#87d787')
  win_execute(w, 'highlight default SPlugIconPin ctermfg=141 guifg=#af87ff')
  win_execute(w, 'highlight default SPlugStatePin ctermfg=141 guifg=#af87ff')
  win_execute(w, 'highlight default SPlugIconNew ctermfg=114 guifg=#87d787 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugIconUp ctermfg=180 guifg=#d7af87')
  win_execute(w, 'highlight default SPlugIconErr ctermfg=204 guifg=#ff5f87 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugIconDirty ctermfg=214 guifg=#ffaf00 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugIconSkip ctermfg=245 guifg=#8a8a8a')
  win_execute(w, 'highlight default SPlugIconWait ctermfg=240 guifg=#585858')
  win_execute(w, 'highlight default SPlugIconRemove ctermfg=204 guifg=#ff5f87')
  # 其他
  win_execute(w, 'highlight default SPlugTime ctermfg=245 guifg=#8a8a8a')
  win_execute(w, 'highlight default SPlugSpinner ctermfg=75 guifg=#5fafff')
  win_execute(w, 'highlight default SPlugCheckDone ctermfg=114 guifg=#87d787 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugCursor ctermfg=75 guifg=#5fafff cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugHelp ctermfg=245 guifg=#8a8a8a')
  win_execute(w, 'highlight default SPlugTableHeader ctermfg=252 guifg=#d0d0d0 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugWaiting ctermfg=240 guifg=#585858')
  win_execute(w, 'highlight default SPlugFrozen ctermfg=245 guifg=#8a8a8a')
  win_execute(w, 'highlight default SPlugRemoved ctermfg=204 guifg=#ff5f87')
  win_execute(w, 'highlight default SPlugFilter ctermfg=75 guifg=#5fafff')
  win_execute(w, 'highlight default SPlugSumInstalled ctermfg=114 guifg=#87d787 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugSumUpdated ctermfg=180 guifg=#d7af87 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugSumOk ctermfg=114 guifg=#87d787')
  win_execute(w, 'highlight default SPlugSumFrozen ctermfg=245 guifg=#8a8a8a')
  win_execute(w, 'highlight default SPlugSumRemoved ctermfg=204 guifg=#ff5f87')
  win_execute(w, 'highlight default SPlugSumErrors ctermfg=204 guifg=#ff5f87 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugStateNew ctermfg=114 guifg=#87d787 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugStateUp ctermfg=180 guifg=#d7af87 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugStateOk ctermfg=114 guifg=#87d787')
  win_execute(w, 'highlight default SPlugStateErr ctermfg=204 guifg=#ff5f87 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugStateDirty ctermfg=214 guifg=#ffaf00 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugStateHook ctermfg=75 guifg=#5fafff')
  win_execute(w, 'highlight default SPlugDiffAdd ctermfg=114 guifg=#87d787')
  win_execute(w, 'highlight default SPlugDiffDel ctermfg=204 guifg=#ff5f87')
  win_execute(w, 'highlight default SPlugSize ctermfg=245 guifg=#8a8a8a')
  win_execute(w, 'highlight default SPlugErrMsg ctermfg=204 guifg=#ff5f87')
enddef
