vim9script

# =============================================================
# SimplePlug — Vim9 包管理器 (Rust 后端)
# =============================================================


const s_plugin_root = fnamemodify(expand('<sfile>'), ':p:h:h')

# ─────────────────── 插件注册表 ───────────────────

var s_plugins: list<dict<any>> = []
# {name, repo, url, dir, branch, tag, commit, do, frozen, on_ft, on_cmd}

var s_loaded_plugins: dict<bool> = {}
var s_lazy_commands: list<string> = []
var s_lazy_maps: list<string> = []

# ─────────────────── 后端状态 ───────────────────

var s_next_id: number = 0
var s_cbs: dict<any> = {}   # id -> callback dict
var s_active_id: number = 0

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

# ─────────────────── UI 交互状态 ───────────────────

var s_ui_cursor_line: number = 0
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
      if index(split(&runtimepath, ','), plug.dir) < 0
        &runtimepath = plug.dir .. ',' .. &runtimepath
        # after 目录
        var afterdir = plug.dir .. '/after'
        if isdirectory(afterdir) && index(split(&runtimepath, ','), afterdir) < 0
          &runtimepath = &runtimepath .. ',' .. afterdir
        endif
      endif
      # 加载插件
      LoadPlugin(plug)
    endif
  endfor
  filetype plugin indent on
  syntax enable
enddef

def LoadPlugin(plug: dict<any>)
  if has_key(s_loaded_plugins, plug.name)
    return
  endif
  # 延迟插件必须保持未加载状态，直到对应事件真正触发。
  if !empty(get(plug, 'on_ft', '')) || !empty(get(plug, 'on_cmd', ''))
    s_loaded_plugins[plug.name] = false
    SetupLazyLoad(plug)
    return
  endif
  s_loaded_plugins[plug.name] = true
  # End() 也可能由用户在 VimEnter 之后调用，此时 Vim 不会再自动扫描 plugin/。
  if v:vim_did_enter
    SourcePluginScripts(plug.dir)
  endif
enddef

def SetupLazyLoad(plug: dict<any>)
  var pname = plug.name
  var pdir = plug.dir

  # on_ft 延迟加载
  var ft = get(plug, 'on_ft', '')
  if type(ft) == v:t_string && ft !=# ''
    execute printf('autocmd SimplePlugLazy FileType %s ++once call simpleplug#LazyLoad("%s")', ft, pname)
  elseif type(ft) == v:t_list
    for f in ft
      execute printf('autocmd SimplePlugLazy FileType %s ++once call simpleplug#LazyLoad("%s")', f, pname)
    endfor
  endif

  # on_cmd 延迟加载：普通命令走 command stub，<Plug>/按键序列走 mapping stub
  var cmd = get(plug, 'on_cmd', '')
  var triggers: list<string> = []
  if type(cmd) == v:t_string && cmd !=# ''
    triggers = [cmd]
  elseif type(cmd) == v:t_list
    triggers = cmd
  endif
  for c in triggers
    if c =~# '^<'
      SetupLazyMap(pname, c)
    else
      add(s_lazy_commands, c)
      execute printf('command! -nargs=* -range -bang %s delcommand %s | call simpleplug#LazyLoad("%s") | %s<bang> <args>',
        c, c, pname, c)
    endif
  endfor

  # ftdetect 必须立即生效，否则插件自带的文件类型永远不会被识别，
  # for 延迟加载也就永远不会触发。
  augroup filetypedetect
  for f in globpath(pdir, 'ftdetect/*.vim', 0, 1)
    try
      execute 'source ' .. fnameescape(f)
    catch
      Log('ftdetect source error: ' .. v:exception, 'ErrorMsg')
    endtry
  endfor
  augroup END

  # 从 rtp 里暂时移除
  if index(split(&runtimepath, ','), pdir) >= 0
    var parts = split(&runtimepath, ',')
    var newparts: list<string> = []
    for p in parts
      if p !=# pdir && p !=# pdir .. '/after'
        add(newparts, p)
      endif
    endfor
    &runtimepath = join(newparts, ',')
  endif
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
  for md in ['n', 'x', 'o']
    execute 'silent! ' .. md .. 'unmap ' .. keys
  endfor
  LazyLoad(name)
  if mode ==# 'x'
    feedkeys('gv', 'n')
  endif
  feedkeys(substitute(keys, '\c^<Plug>', "\<Plug>", ''))
enddef

export def LazyLoad(name: string)
  var plug = FindPlugin(name)
  if plug == {}
    return
  endif
  if get(s_loaded_plugins, name, false)
    return
  endif
  s_loaded_plugins[name] = true

  var dir = plug.dir
  if !isdirectory(dir)
    return
  endif

  # 重新加入 runtimepath
  if index(split(&runtimepath, ','), dir) < 0
    &runtimepath = dir .. ',' .. &runtimepath
    var afterdir = dir .. '/after'
    if isdirectory(afterdir)
      &runtimepath = &runtimepath .. ',' .. afterdir
    endif
  endif

  SourcePluginScripts(dir)
enddef

def SourcePluginScripts(dir: string)
  for f in globpath(dir, 'plugin/**/*.vim', 0, 1)
    try
      execute 'source ' .. fnameescape(f)
    catch
      Log('LazyLoad source error: ' .. v:exception, 'ErrorMsg')
    endtry
  endfor
  for f in globpath(dir, 'after/plugin/**/*.vim', 0, 1)
    try
      execute 'source ' .. fnameescape(f)
    catch
    endtry
  endfor
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
  UIBuildAndRender()
enddef

export def Stop()
  SetupCore()
  simpleplug#core#Stop()
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
  if !simpleplug#core#Send(req)
    s_active_id = 0
    OnError({message: 'daemon is not running'})
  endif
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
      endtry
      remove(s_cbs, id)
    endif
  elseif ev.type ==# 'error'
    OnError(ev)
    if has_key(s_cbs, id)
      try
        s_cbs[id].OnError(ev)
      catch
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

def MissingPluginCount(): number
  var missing = 0
  for p in s_plugins
    if getftype(p.dir .. '/.git') ==# ''
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
      GenerateHelptags()
      UIBuildAndRender()
    },
    OnError: (ev) => {
      StopSpinner()
      UIBuildAndRender()
    },
  }
  Send({type: mode, id: id, plugins: specs, jobs: JobCount()})
enddef

def GenerateHelptags()
  for p in s_plugins
    var doc = p.dir .. '/doc'
    if isdirectory(doc)
      execute 'silent! helptags ' .. fnameescape(doc)
    endif
  endfor
enddef

export def Install(names: list<string> = [])
  if !EnsureBackend()
    return
  endif
  var plugs = SelectPlugins(names)
  if empty(plugs)
    return
  endif
  RunBatch('install', plugs, PluginSpecs(plugs))
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

export def Update(names: list<string> = [])
  if !EnsureBackend()
    return
  endif
  var plugs = SelectPlugins(names)
  if empty(plugs)
    return
  endif
  RunBatch('update', plugs, PluginSpecs(plugs))
enddef

# =============================================================
# Snapshot / Restore — 记录并恢复所有插件的精确 commit
# =============================================================

def SnapshotPath(file: string): string
  return file ==# '' ? g:simpleplug_dir .. '/simpleplug.snapshot.json' : fnamemodify(file, ':p')
enddef

export def Snapshot(file: string = '')
  var path = SnapshotPath(file)
  var snap: dict<string> = {}
  for p in s_plugins
    if getftype(p.dir .. '/.git') ==# ''
      continue
    endif
    var commit = trim(system('git -C ' .. shellescape(p.dir) .. ' rev-parse HEAD'))
    if v:shell_error == 0 && commit =~# '^\x\+$'
      snap[p.name] = commit
    endif
  endfor
  if writefile([json_encode(snap)], path) != 0
    echohl ErrorMsg
    echom '[SimplePlug] failed to write snapshot: ' .. path
    echohl None
    return
  endif
  echom printf('[SimplePlug] snapshot of %d plugins written to %s', len(snap), path)
enddef

export def Restore(file: string = '')
  if !EnsureBackend()
    return
  endif
  var path = SnapshotPath(file)
  if !filereadable(path)
    echohl ErrorMsg
    echom '[SimplePlug] snapshot not found: ' .. path
    echohl None
    return
  endif
  var snap: dict<any>
  try
    snap = json_decode(join(readfile(path), "\n"))
  catch
    echohl ErrorMsg
    echom '[SimplePlug] invalid snapshot file: ' .. path
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
  var specs = PluginSpecs(plugs)
  for spec in specs
    spec.commit = snap[spec.name]
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
  s_ui_cursor_line = 0
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
  if IsInstallUpdateRunning()
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

def PadLine(content: string, width: number): string
  var text = content
  while strdisplaywidth(text) > width && strchars(text) > 0
    text = strcharpart(text, 0, strchars(text) - 1)
  endwhile
  var pad = width - strdisplaywidth(text)
  if pad < 0
    pad = 0
  endif
  return text .. repeat(' ', pad)
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

def AddUiLine(lines: list<string>, content: string, width: number)
  add(lines, PadLine(content, width))
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

def UIBuildAndRender()
  var lines: list<string> = []
  var title = ModeTitle()
  var is_done = IsDone()
  var spinner = is_done ? '✓' : s_spinners[s_ui_spinner_idx]
  var W = UiWidth()

  s_ui_sorted_names = SortedPluginNames()
  s_ui_cursor_buf_line = 0
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
  if empty(sorted)
    s_ui_cursor_line = 0
  elseif s_ui_cursor_line >= len(sorted)
    s_ui_cursor_line = len(sorted) - 1
  endif

  var plug_line_idx = 0
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

    var is_cursor = (plug_line_idx == s_ui_cursor_line)
    var cursor_mark = is_cursor ? '▸' : ' '
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
    plug_line_idx += 1
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
  AddUiLine(lines, '  q close   j/k move   <CR> open   d log   / filter   ? help   R retry   S status', W)

  s_ui_lines = lines
  UIRender()
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
      UIBuildAndRender()
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
  nnoremap <buffer><silent> R <Cmd>call simpleplug#UIRetry()<CR>
  nnoremap <buffer><silent> S <Cmd>call simpleplug#Status()<CR>
  nnoremap <buffer><silent> <CR> <Cmd>call simpleplug#OpenPluginDir()<CR>
  nnoremap <buffer><silent> d <Cmd>call simpleplug#ViewPluginDiff()<CR>
  nnoremap <buffer><silent> h <Cmd>call simpleplug#ToggleHelp()<CR>
  nnoremap <buffer><silent> ? <Cmd>call simpleplug#ToggleHelp()<CR>
  nnoremap <buffer><silent> / <Cmd>call simpleplug#StartFilterSplit()<CR>

  UIBuildAndRender()
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
  if s_ui_mode =~# 'install'
    Install()
  elseif s_ui_mode =~# 'update'
    Update()
  endif
enddef

def UIRender()
  if s_ui_bufnr < 0 || !bufexists(s_ui_bufnr)
    return
  endif
  var wins = win_findbuf(s_ui_bufnr)
  if empty(wins)
    return
  endif
  SetUiBufferLines()
  win_execute(wins[0], ':vertical resize ' .. UiWidth())
  # 将光标移动到选中行
  if s_ui_cursor_buf_line > 0
    win_execute(wins[0], 'normal! ' .. s_ui_cursor_buf_line .. 'G')
  endif
enddef

# ─────────────────── 交互功能 ───────────────────

def ScrollDown()
  var max_line = len(s_ui_sorted_names) - 1
  if s_ui_cursor_line < max_line
    s_ui_cursor_line += 1
  endif
  UIBuildAndRender()
enddef

def ScrollUp()
  if s_ui_cursor_line > 0
    s_ui_cursor_line -= 1
  endif
  UIBuildAndRender()
enddef

def GetCurrentPluginName(): string
  if s_ui_cursor_line < 0 || s_ui_cursor_line >= len(s_ui_sorted_names)
    return ''
  endif
  return s_ui_sorted_names[s_ui_cursor_line]
enddef

def DoOpenPluginDir()
  var name = GetCurrentPluginName()
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

def DoViewPluginDiff()
  var name = GetCurrentPluginName()
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
    '    R           重试操作',
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

# Split 模式下的交互导出 (从光标行解析插件名)

def SplitGetPluginNameFromCursor(): string
  var lnum = line('.')
  var ltext = getline(lnum)
  for p in s_plugins
    if ltext =~# '\V' .. escape(p.name, '\')
      return p.name
    endif
  endfor
  return ''
enddef

export def OpenPluginDir()
  var name = SplitGetPluginNameFromCursor()
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
  var name = SplitGetPluginNameFromCursor()
  if name ==# ''
    return
  endif
  for i in range(len(s_ui_sorted_names))
    if s_ui_sorted_names[i] ==# name
      s_ui_cursor_line = i
      break
    endif
  endfor
  DoViewPluginDiff()
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
