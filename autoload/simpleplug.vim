vim9script

# =============================================================
# SimplePlug — Vim9 包管理器 (Rust 后端)
# =============================================================

# ─────────────────── 插件注册表 ───────────────────

var s_plugins: list<dict<any>> = []
# {name, repo, url, dir, branch, do, frozen, on_ft, on_cmd}

var s_loaded_plugins: dict<bool> = {}

# ─────────────────── 后端状态 ───────────────────

var s_job: any = v:null
var s_running: bool = false
var s_next_id: number = 0
var s_cbs: dict<any> = {}   # id -> callback dict

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
      if stridx(&runtimepath, plug.dir) < 0
        &runtimepath = plug.dir .. ',' .. &runtimepath
        # after 目录
        var afterdir = plug.dir .. '/after'
        if isdirectory(afterdir) && stridx(&runtimepath, afterdir) < 0
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
  s_loaded_plugins[plug.name] = true

  # 执行 plugin/ 下的脚本 — Vim 会通过 runtimepath 自动加载
  # 但如果是延迟加载，先不载入
  if !empty(get(plug, 'on_ft', '')) || !empty(get(plug, 'on_cmd', ''))
    SetupLazyLoad(plug)
    return
  endif
enddef

def SetupLazyLoad(plug: dict<any>)
  var pname = plug.name
  var pdir = plug.dir

  # on_ft 延迟加载
  var ft = get(plug, 'on_ft', '')
  if type(ft) == v:t_string && ft !=# ''
    execute printf('autocmd FileType %s ++once call simpleplug#LazyLoad("%s")', ft, pname)
  elseif type(ft) == v:t_list
    for f in ft
      execute printf('autocmd FileType %s ++once call simpleplug#LazyLoad("%s")', f, pname)
    endfor
  endif

  # on_cmd 延迟加载
  var cmd = get(plug, 'on_cmd', '')
  if type(cmd) == v:t_string && cmd !=# ''
    execute printf('command! -nargs=* -range -bang %s delcommand %s | call simpleplug#LazyLoad("%s") | %s<bang> <args>',
      cmd, cmd, pname, cmd)
  elseif type(cmd) == v:t_list
    for c in cmd
      execute printf('command! -nargs=* -range -bang %s delcommand %s | call simpleplug#LazyLoad("%s") | %s<bang> <args>',
        c, c, pname, c)
    endfor
  endif

  # 从 rtp 里暂时移除
  var idx = stridx(&runtimepath, pdir)
  if idx >= 0
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

export def LazyLoad(name: string)
  var plug = FindPlugin(name)
  if plug == {}
    return
  endif
  if has_key(s_loaded_plugins, name) && s_loaded_plugins[name]
    return
  endif
  s_loaded_plugins[name] = true

  var dir = plug.dir
  if !isdirectory(dir)
    return
  endif

  # 重新加入 runtimepath
  if stridx(&runtimepath, dir) < 0
    &runtimepath = dir .. ',' .. &runtimepath
    var afterdir = dir .. '/after'
    if isdirectory(afterdir)
      &runtimepath = &runtimepath .. ',' .. afterdir
    endif
  endif

  # 手动 source 插件脚本
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
  if repo =~# '^\(https\?://\|git@\)'
    url = repo
    name = fnamemodify(substitute(repo, '\.git$', '', ''), ':t')
  else
    url = 'https://github.com/' .. repo .. '.git'
    name = fnamemodify(repo, ':t')
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

def FindBackend(): string
  var override = get(g:, 'simpleplug_daemon_path', '')
  if type(override) == v:t_string && override !=# '' && executable(override)
    return override
  endif
  for d in split(&runtimepath, ',')
    var p = d .. '/lib/simpleplug-daemon'
    if executable(p)
      return p
    endif
  endfor
  return ''
enddef

def IsRunning(): bool
  return s_running
enddef

def EnsureBackend(): bool
  if IsRunning()
    return true
  endif
  var exe = FindBackend()
  if exe ==# '' || !executable(exe)
    echohl ErrorMsg
    echom '[SimplePlug] daemon not found. Run install.sh or set g:simpleplug_daemon_path.'
    echohl None
    return false
  endif

  try
    s_job = job_start([exe], {
      in_io: 'pipe',
      out_mode: 'nl',
      out_cb: (ch, line) => {
        OnDaemonEvent(line)
      },
      err_mode: 'nl',
      err_cb: (ch, line) => {
        Log('stderr: ' .. line)
      },
      exit_cb: (ch, code) => {
        s_running = false
        s_job = v:null
        s_cbs = {}
      },
      stoponexit: 'term'
    })
  catch
    s_job = v:null
    s_running = false
    echohl ErrorMsg
    echom '[SimplePlug] job_start failed: ' .. v:exception
    echohl None
    return false
  endtry

  s_running = (s_job != v:null)
  return s_running
enddef

export def Stop()
  if s_job != v:null
    try
      call('job_stop', [s_job])
    catch
    endtry
  endif
  s_running = false
  s_job = v:null
  s_cbs = {}
enddef

def Send(req: dict<any>)
  if !IsRunning()
    return
  endif
  try
    var json = json_encode(req) .. "\n"
    ch_sendraw(s_job, json)
  catch
    Log('Send error: ' .. v:exception, 'ErrorMsg')
  endtry
enddef

def OnDaemonEvent(line: string)
  if line ==# ''
    return
  endif
  var ev: any
  try
    ev = json_decode(line)
  catch
    Log('JSON decode error: ' .. v:exception)
    return
  endtry

  if type(ev) != v:t_dict || !has_key(ev, 'type')
    return
  endif

  var id = get(ev, 'id', 0)

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
enddef

# =============================================================
# Install / Update / Clean / Status
# =============================================================

def PluginSpecs(): list<dict<any>>
  var specs: list<dict<any>> = []
  for p in s_plugins
    add(specs, {
      name: p.name,
      url: p.url,
      dir: p.dir,
      branch: p.branch,
      do_cmd: p.do,
      frozen: p.frozen,
    })
  endfor
  return specs
enddef

def MissingPluginCount(): number
  var missing = 0
  for p in s_plugins
    if !isdirectory(p.dir .. '/.git')
      missing += 1
    endif
  endfor
  return missing
enddef

export def Install()
  if !EnsureBackend()
    return
  endif
  s_ui_mode = 'install'
  s_ui_total = len(s_plugins)
  s_ui_finished = 0
  s_ui_start_time = reltime()
  InitPlugStates('waiting', '·')
  UIOpen()
  var id = NextId()
  s_cbs[id] = {
    OnDone: (ev) => {
      StopSpinner()
      var s = ev.summary
      s_ui_mode = 'install_done'
      UIBuildAndRender()
    },
    OnError: (ev) => {
      StopSpinner()
      UIBuildAndRender()
    },
  }
  Send({type: 'install', id: id, plugins: PluginSpecs()})
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

export def Update()
  if !EnsureBackend()
    return
  endif
  s_ui_mode = 'update'
  s_ui_total = len(s_plugins)
  s_ui_finished = 0
  s_ui_start_time = reltime()
  InitPlugStates('waiting', '·')
  UIOpen()
  var id = NextId()
  s_cbs[id] = {
    OnDone: (ev) => {
      StopSpinner()
      var s = ev.summary
      s_ui_mode = 'update_done'
      UIBuildAndRender()
    },
    OnError: (ev) => {
      StopSpinner()
      UIBuildAndRender()
    },
  }
  Send({type: 'update', id: id, plugins: PluginSpecs()})
enddef

export def Clean()
  if !EnsureBackend()
    return
  endif
  var keep: list<string> = []
  for p in s_plugins
    add(keep, fnamemodify(p.dir, ':t'))
  endfor
  s_ui_mode = 'clean'
  s_ui_total = 0
  s_ui_finished = 0
  s_ui_start_time = reltime()
  s_ui_plug_state = {}
  UIOpen()
  var id = NextId()
  Send({type: 'clean', id: id, plugdir: g:simpleplug_dir, keep: keep})
enddef

export def Status()
  if !EnsureBackend()
    return
  endif
  s_ui_mode = 'status'
  s_ui_total = len(s_plugins)
  s_ui_finished = 0
  s_ui_start_time = reltime()
  InitPlugStates('waiting', '·')
  UIOpen()
  var id = NextId()
  Send({type: 'status', id: id, plugins: PluginSpecs()})
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
  s_ui_mode = 'hook'
  s_ui_total = 1
  s_ui_finished = 0
  s_ui_start_time = reltime()
  s_ui_plug_state = {}
  s_ui_plug_state[name] = {status: 'waiting', msg: '', icon: '·', branch: '', commit: '', dirty: false}
  UIOpen()
  var id = NextId()
  Send({type: 'post_hook', id: id, name: name, dir: plug.dir, cmd: do_cmd})
enddef

export def CompletePluginNames(arglead: string, cmdline: string, cursorpos: number): list<string>
  var names: list<string> = []
  for p in s_plugins
    if p.name =~? '^' .. arglead
      add(names, p.name)
    endif
  endfor
  return names
enddef

# =============================================================
# 事件处理
# =============================================================

def InitPlugStates(status: string, icon: string)
  s_ui_plug_state = {}
  for p in s_plugins
    s_ui_plug_state[p.name] = {status: status, msg: '', icon: icon, branch: '', commit: '', dirty: false}
  endfor
enddef

def OnProgress(ev: dict<any>)
  var name = get(ev, 'name', '')
  var status = get(ev, 'status', '')
  var msg = get(ev, 'message', '')

  if !has_key(s_ui_plug_state, name)
    s_ui_plug_state[name] = {status: '', msg: '', icon: '', branch: '', commit: '', dirty: false}
  endif
  var st = s_ui_plug_state[name]

  if status ==# 'installed'
    st.status = 'done'
    st.icon = ''
    st.msg = msg
    s_ui_finished += 1
  elseif status ==# 'updated'
    st.status = 'done'
    st.icon = ''
    st.msg = msg
    s_ui_finished += 1
  elseif status ==# 'already'
    st.status = 'done'
    st.icon = ''
    st.msg = msg
    s_ui_finished += 1
  elseif status ==# 'skipped'
    st.status = 'skipped'
    st.icon = ''
    st.msg = msg
    s_ui_finished += 1
  elseif status ==# 'hook'
    st.msg = st.msg .. ' | ' .. msg
  elseif status ==# 'error'
    st.status = 'error'
    st.icon = ''
    st.msg = msg
    s_ui_finished += 1
  endif

  s_ui_plug_state[name] = st
  UIBuildAndRender()
enddef

def OnDone(ev: dict<any>)
  # 由回调处理
enddef

def OnError(ev: dict<any>)
  var msg = get(ev, 'message', '')
  Log('Error: ' .. msg, 'ErrorMsg')
  UIBuildAndRender()
enddef

def OnStatusResult(ev: dict<any>)
  StopSpinner()
  var items = get(ev, 'items', [])
  for item in items
    var name = item.name
    if !has_key(s_ui_plug_state, name)
      s_ui_plug_state[name] = {status: '', msg: '', icon: '', branch: '', commit: '', dirty: false}
    endif
    var st = s_ui_plug_state[name]
    if item.installed
      st.status = 'done'
      st.icon = ''
      st.branch = item.branch
      st.commit = item.commit
      st.dirty = item.dirty
      st.msg = ''
    else
      st.status = 'error'
      st.icon = ''
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
    s_ui_plug_state[name] = {status: '', msg: '', icon: '', branch: '', commit: '', dirty: false}
  endif
  var st = s_ui_plug_state[name]
  st.status = ok ? 'done' : 'error'
  st.icon = ok ? '' : ''
  st.msg = output
  s_ui_plug_state[name] = st
  s_ui_mode = 'hook_done'
  UIBuildAndRender()
enddef

def OnCleanDone(ev: dict<any>)
  StopSpinner()
  var removed = get(ev, 'removed', [])
  for r in removed
    s_ui_plug_state[r] = {status: 'removed', msg: 'removed', icon: '󰩺', branch: '', commit: '', dirty: false}
  endfor
  s_ui_finished = len(removed)
  s_ui_mode = 'clean_done'
  UIBuildAndRender()
enddef

# =============================================================
# UI — 插件状态面板
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
  s_ui_spinner_timer = timer_start(80, function('SpinnerTick'), {repeat: -1})
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

def UIBuildAndRender()
  var lines: list<string> = []
  var title = ModeTitle()
  var is_done = IsDone()
  var spinner = is_done ? '✓' : s_spinners[s_ui_spinner_idx]

  # ── 标题头 ──
  var header_text = ' ' .. spinner .. '  ' .. title .. '  '
  var elapsed = Elapsed()
  var right_info = ' ' .. elapsed .. ' '
  var hdr_content_width = strdisplaywidth(header_text) + strdisplaywidth(right_info)
  var pad_width = 60 - hdr_content_width
  if pad_width < 1
    pad_width = 1
  endif
  var hdr_pad = repeat('─', pad_width)

  add(lines, '╭' .. repeat('─', 60) .. '╮')
  add(lines, '│' .. header_text .. hdr_pad .. right_info .. '│')

  # ── 进度条 (install/update 模式) ──
  if s_ui_mode =~# 'install\|update'
    var bar = ProgressBar(s_ui_finished, s_ui_total, 50)
    var pct = s_ui_total > 0 ? (s_ui_finished * 100 / s_ui_total) : 0
    var bar_line = printf('│  %s %3d%%  │', bar, pct)
    add(lines, '├' .. repeat('─', 60) .. '┤')
    add(lines, bar_line)
  endif

  add(lines, '├' .. repeat('─', 60) .. '┤')

  # ── 插件列表 ──
  if s_ui_mode ==# 'status_done'
    # 状态模式：表头
    add(lines, printf('│  %-2s %-25s %-12s %-8s %-7s │', '', 'Plugin', 'Branch', 'Commit', 'Status'))
    add(lines, '│  ' .. repeat('─', 56) .. '  │')
  endif

  var maxname = 0
  for p in s_plugins
    if len(p.name) > maxname
      maxname = len(p.name)
    endif
  endfor
  if maxname > 25
    maxname = 25
  endif

  # 按照注册顺序渲染
  for p in s_plugins
    var name = p.name
    var st = get(s_ui_plug_state, name, {status: 'waiting', msg: '', icon: '·', branch: '', commit: '', dirty: false})
    var icon = get(st, 'icon', '·')
    var msg = get(st, 'msg', '')
    var status = get(st, 'status', 'waiting')

    if s_ui_mode ==# 'status_done'
      # 状态表格行
      var branch = get(st, 'branch', '')
      var commit = get(st, 'commit', '')
      var dirty = get(st, 'dirty', false)
      var dirty_flag = dirty ? '*' : ' '
      var status_text = status ==# 'done' ? 'ok' : 'missing'
      var display_name = len(name) > 25 ? name[: 24] : name
      var line = printf('│  %s %-25s %-12s %-8s %-6s%s│',
        icon, display_name,
        branch !=# '' ? branch[: 11] : '—',
        commit !=# '' ? commit[: 7] : '—',
        status_text, dirty_flag)
      add(lines, line)
    else
      # install/update 模式的行
      var display_name = len(name) > maxname ? name[: maxname - 1] : name

      if status ==# 'waiting' && !is_done
        # 等待中 — 灰色
        var line = printf('│  · %-' .. string(maxname) .. 's  waiting...', display_name)
        var pad = 58 - strdisplaywidth(line)
        if pad < 0
          pad = 0
        endif
        add(lines, line .. repeat(' ', pad) .. '│')
      elseif status ==# 'done'
        var short_msg = len(msg) > (52 - maxname) ? msg[: 51 - maxname] : msg
        var line = printf('│  %s %-' .. string(maxname) .. 's  %s', icon, display_name, short_msg)
        var pad = 58 - strdisplaywidth(line)
        if pad < 0
          pad = 0
        endif
        add(lines, line .. repeat(' ', pad) .. '│')
      elseif status ==# 'error'
        var short_msg = len(msg) > (52 - maxname) ? msg[: 51 - maxname] : msg
        var line = printf('│  %s %-' .. string(maxname) .. 's  %s', icon, display_name, short_msg)
        var pad = 58 - strdisplaywidth(line)
        if pad < 0
          pad = 0
        endif
        add(lines, line .. repeat(' ', pad) .. '│')
      elseif status ==# 'skipped'
        var line = printf('│  %s %-' .. string(maxname) .. 's  frozen', icon, display_name)
        var pad = 58 - strdisplaywidth(line)
        if pad < 0
          pad = 0
        endif
        add(lines, line .. repeat(' ', pad) .. '│')
      elseif status ==# 'removed'
        var line = printf('│  %s %-' .. string(maxname) .. 's  removed', icon, display_name)
        var pad = 58 - strdisplaywidth(line)
        if pad < 0
          pad = 0
        endif
        add(lines, line .. repeat(' ', pad) .. '│')
      endif
    endif
  endfor

  # Clean 模式没有注册的插件列表
  if s_ui_mode =~# 'clean'
    if empty(s_ui_plug_state)
      add(lines, '│  Nothing to clean.' .. repeat(' ', 39) .. '│')
    else
      for [name, st] in items(s_ui_plug_state)
        var icon = get(st, 'icon', '')
        var line = printf('│  %s %-30s removed', icon, name)
        var pad = 58 - strdisplaywidth(line)
        if pad < 0
          pad = 0
        endif
        add(lines, line .. repeat(' ', pad) .. '│')
      endfor
    endif
  endif

  # ── 统计摘要 ──
  add(lines, '├' .. repeat('─', 60) .. '┤')
  if is_done
    var summary = SummaryLine()
    var spad = 58 - strdisplaywidth(summary)
    if spad < 0
      spad = 0
    endif
    add(lines, '│ ' .. summary .. repeat(' ', spad) .. ' │')
  else
    var progress_text = printf(' %s  %d / %d plugins', spinner, s_ui_finished, s_ui_total)
    var ppad = 58 - strdisplaywidth(progress_text)
    if ppad < 0
      ppad = 0
    endif
    add(lines, '│' .. progress_text .. repeat(' ', ppad) .. ' │')
  endif
  add(lines, '╰' .. repeat('─', 60) .. '╯')

  if is_done
    add(lines, '')
    add(lines, '  Press q to close, R to retry, S for status')
  endif

  s_ui_lines = lines
  UIRender()
enddef

def SummaryLine(): string
  var n_ok = 0
  var n_err = 0
  var n_skip = 0
  var n_new = 0
  var n_up = 0
  for [name, st] in items(s_ui_plug_state)
    var s = get(st, 'status', '')
    if s ==# 'done'
      # Distinguish install vs update via icon
      var icon = get(st, 'icon', '')
      if icon ==# ''
        n_new += 1
      elseif icon ==# ''
        n_up += 1
      else
        n_ok += 1
      endif
    elseif s ==# 'error'
      n_err += 1
    elseif s ==# 'skipped'
      n_skip += 1
    endif
  endfor

  var parts: list<string> = []
  if n_new > 0
    add(parts, printf(' %d installed', n_new))
  endif
  if n_up > 0
    add(parts, printf(' %d updated', n_up))
  endif
  if n_ok > 0
    add(parts, printf(' %d ok', n_ok))
  endif
  if n_skip > 0
    add(parts, printf(' %d frozen', n_skip))
  endif
  if n_err > 0
    add(parts, printf(' %d errors', n_err))
  endif
  if empty(parts)
    return ' All done  (' .. Elapsed() .. ')'
  endif
  return join(parts, '  ') .. '  (' .. Elapsed() .. ')'
enddef

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

  # 新建分屏
  botright new
  execute ':resize ' .. g:simpleplug_window_height
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
  win_execute(wins[0], 'setlocal modifiable')
  deletebufline(s_ui_bufnr, 1, '$')
  setbufline(s_ui_bufnr, 1, s_ui_lines)
  win_execute(wins[0], 'setlocal nomodifiable')
  # 调整窗口大小以适应内容
  var desired_h = len(s_ui_lines) + 1
  var max_h = get(g:, 'simpleplug_window_height', 15)
  if desired_h > max_h
    desired_h = max_h
  endif
  if desired_h < 5
    desired_h = 5
  endif
  win_execute(wins[0], ':resize ' .. desired_h)
enddef

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
  # 标题行内容
  win_execute(w, 'syntax match SPlugTitle /\(Installing\|Updating\|Plugin Status\|Install Complete\|Update Complete\|Clean\|Post-Install Hook\|SimplePlug\)/')
  # 进度条
  win_execute(w, 'syntax match SPlugBarFill /█/')
  win_execute(w, 'syntax match SPlugBarEmpty /░/')
  win_execute(w, 'syntax match SPlugPct /\d\+%/')
  # 状态图标
  win_execute(w, 'syntax match SPlugIconOk / /')
  win_execute(w, 'syntax match SPlugIconNew / /')
  win_execute(w, 'syntax match SPlugIconUp / /')
  win_execute(w, 'syntax match SPlugIconErr / /')
  win_execute(w, 'syntax match SPlugIconSkip / /')
  win_execute(w, 'syntax match SPlugIconWait /· /')
  win_execute(w, 'syntax match SPlugIconRemove /󰩺/')
  # 时间
  win_execute(w, 'syntax match SPlugTime /\d\+\.\d\+s/')
  # spinner
  win_execute(w, 'syntax match SPlugSpinner /[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/')
  # ✓ in header
  win_execute(w, 'syntax match SPlugCheckDone /✓/')
  # 底部帮助
  win_execute(w, 'syntax match SPlugHelp /Press.*$/')
  # 表头
  win_execute(w, 'syntax match SPlugTableHeader /Plugin\s\+Branch\s\+Commit\s\+Status/')
  # waiting
  win_execute(w, 'syntax match SPlugWaiting /waiting\.\.\./')
  # frozen
  win_execute(w, 'syntax match SPlugFrozen /frozen/')
  # removed
  win_execute(w, 'syntax match SPlugRemoved /removed/')
  # summary counters
  win_execute(w, 'syntax match SPlugSumInstalled / \d\+ installed/')
  win_execute(w, 'syntax match SPlugSumUpdated / \d\+ updated/')
  win_execute(w, 'syntax match SPlugSumOk / \d\+ ok/')
  win_execute(w, 'syntax match SPlugSumFrozen / \d\+ frozen/')
  win_execute(w, 'syntax match SPlugSumErrors / \d\+ errors/')
  # 错误消息
  win_execute(w, 'syntax match SPlugErrMsg /not installed/')

  # highlight 定义
  win_execute(w, 'highlight default SPlugBorder ctermfg=240 guifg=#585858')
  win_execute(w, 'highlight default SPlugTitle ctermfg=75 guifg=#5fafff cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugBarFill ctermfg=114 guifg=#87d787')
  win_execute(w, 'highlight default SPlugBarEmpty ctermfg=238 guifg=#444444')
  win_execute(w, 'highlight default SPlugPct ctermfg=252 guifg=#d0d0d0 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugIconOk ctermfg=114 guifg=#87d787')
  win_execute(w, 'highlight default SPlugIconNew ctermfg=114 guifg=#87d787 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugIconUp ctermfg=180 guifg=#d7af87')
  win_execute(w, 'highlight default SPlugIconErr ctermfg=204 guifg=#ff5f87 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugIconSkip ctermfg=245 guifg=#8a8a8a')
  win_execute(w, 'highlight default SPlugIconWait ctermfg=240 guifg=#585858')
  win_execute(w, 'highlight default SPlugIconRemove ctermfg=204 guifg=#ff5f87')
  win_execute(w, 'highlight default SPlugTime ctermfg=245 guifg=#8a8a8a')
  win_execute(w, 'highlight default SPlugSpinner ctermfg=75 guifg=#5fafff')
  win_execute(w, 'highlight default SPlugCheckDone ctermfg=114 guifg=#87d787 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugHelp ctermfg=245 guifg=#8a8a8a')
  win_execute(w, 'highlight default SPlugTableHeader ctermfg=252 guifg=#d0d0d0 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugWaiting ctermfg=240 guifg=#585858')
  win_execute(w, 'highlight default SPlugFrozen ctermfg=245 guifg=#8a8a8a')
  win_execute(w, 'highlight default SPlugRemoved ctermfg=204 guifg=#ff5f87')
  win_execute(w, 'highlight default SPlugSumInstalled ctermfg=114 guifg=#87d787 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugSumUpdated ctermfg=180 guifg=#d7af87 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugSumOk ctermfg=114 guifg=#87d787')
  win_execute(w, 'highlight default SPlugSumFrozen ctermfg=245 guifg=#8a8a8a')
  win_execute(w, 'highlight default SPlugSumErrors ctermfg=204 guifg=#ff5f87 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugErrMsg ctermfg=204 guifg=#ff5f87')
enddef
