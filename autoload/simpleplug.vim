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

# ─────────────────── Popup / 交互状态 ───────────────────

var s_ui_use_popup: bool = false
var s_ui_popup_id: number = 0
var s_ui_cursor_line: number = 0
var s_ui_show_help: bool = false
var s_ui_filter_text: string = ''
var s_ui_filter_active: bool = false
var s_ui_plug_timings: dict<float> = {}
var s_ui_plug_start_times: dict<list<any>> = {}
var s_ui_sorted_names: list<string> = []
var s_ui_help_popup_id: number = 0
var s_ui_cursor_buf_line: number = 0  # 光标对应的缓冲区行号(1-based)

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
  s_ui_plug_timings = {}
  s_ui_plug_start_times = {}
  s_ui_cursor_line = 0
  s_ui_filter_text = ''
  s_ui_filter_active = false
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

  # 记录插件开始时间
  if !has_key(s_ui_plug_start_times, name) && status !=# 'hook'
    s_ui_plug_start_times[name] = reltime()
  endif

  if status ==# 'installed'
    st.status = 'done'
    st.icon = ''
    st.msg = msg
    s_ui_finished += 1
    if has_key(s_ui_plug_start_times, name)
      s_ui_plug_timings[name] = reltimefloat(reltime(s_ui_plug_start_times[name]))
    endif
  elseif status ==# 'updated'
    st.status = 'done'
    st.icon = ''
    st.msg = msg
    s_ui_finished += 1
    if has_key(s_ui_plug_start_times, name)
      s_ui_plug_timings[name] = reltimefloat(reltime(s_ui_plug_start_times[name]))
    endif
  elseif status ==# 'already'
    st.status = 'done'
    st.icon = ''
    st.msg = msg
    s_ui_finished += 1
    if has_key(s_ui_plug_start_times, name)
      s_ui_plug_timings[name] = reltimefloat(reltime(s_ui_plug_start_times[name]))
    endif
  elseif status ==# 'skipped'
    st.status = 'skipped'
    st.icon = ''
    st.msg = msg
    s_ui_finished += 1
    if has_key(s_ui_plug_start_times, name)
      s_ui_plug_timings[name] = reltimefloat(reltime(s_ui_plug_start_times[name]))
    endif
  elseif status ==# 'hook'
    st.msg = st.msg .. ' | ' .. msg
  elseif status ==# 'error'
    st.status = 'error'
    st.icon = ''
    st.msg = msg
    s_ui_finished += 1
    if has_key(s_ui_plug_start_times, name)
      s_ui_plug_timings[name] = reltimefloat(reltime(s_ui_plug_start_times[name]))
    endif
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
      s_ui_plug_state[name] = {status: '', msg: '', icon: '', branch: '', commit: '', dirty: false, size_kb: 0}
    endif
    var st = s_ui_plug_state[name]
    if item.installed
      st.status = 'done'
      st.icon = ''
      st.branch = item.branch
      st.commit = item.commit
      st.dirty = item.dirty
      st.size_kb = get(item, 'size_kb', 0)
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
# UI — 插件状态面板 (增强版: popup + 交互 + 视觉)
# =============================================================

def CanUsePopup(): bool
  return has('popupwin') && get(g:, 'simpleplug_popup', 1)
enddef

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
  if s_ui_mode =~# 'install\|update' && !IsDone()
    var working: list<string> = []
    var finished: list<string> = []
    var waiting: list<string> = []
    for p in s_plugins
      var st = get(s_ui_plug_state, p.name, {})
      var status = get(st, 'status', 'waiting')
      if status ==# 'waiting'
        add(waiting, p.name)
      elseif status ==# 'done' || status ==# 'error' || status ==# 'skipped'
        add(finished, p.name)
      else
        add(working, p.name)
      endif
    endfor
    return working + finished + waiting
  endif
  # 其他模式保持注册顺序
  return mapnew(s_plugins, (_, p) => p.name)
enddef

def GetDisplayPlugins(): list<dict<any>>
  # 应用过滤
  if s_ui_filter_text !=# ''
    return filter(copy(s_plugins), (_, p) => p.name =~? s_ui_filter_text)
  endif
  return s_plugins
enddef

# ─────────────────── 内容构建 (popup/split 通用) ───────────────────

const s_inner_width = 58  # 内容区宽度 (不含左右边框各1字符)

def PadLine(content: string, width: number): string
  var pad = width - strdisplaywidth(content)
  if pad < 0
    pad = 0
  endif
  return content .. repeat(' ', pad)
enddef

def UIBuildAndRender()
  var lines: list<string> = []
  var title = ModeTitle()
  var is_done = IsDone()
  var spinner = is_done ? '✓' : s_spinners[s_ui_spinner_idx]
  var use_popup = s_ui_use_popup
  var W = s_inner_width

  # 更新排序名列表
  s_ui_sorted_names = SortedPluginNames()
  s_ui_cursor_buf_line = 0
  var display_plugins = GetDisplayPlugins()

  # ── 标题头 ──
  var count_text = ''
  if s_ui_mode =~# 'install\|update' && !is_done
    count_text = printf(' (%d/%d)', s_ui_finished, s_ui_total)
  endif
  var header_text = ' ' .. spinner .. '   ' .. title .. count_text .. '  '
  var elapsed = Elapsed()
  var right_info = ' ' .. elapsed .. ' '
  var hdr_content_width = strdisplaywidth(header_text) + strdisplaywidth(right_info)
  var pad_width = W - hdr_content_width
  if pad_width < 1
    pad_width = 1
  endif
  var hdr_pad = repeat(' ', pad_width)

  if !use_popup
    add(lines, '╭' .. repeat('─', W + 2) .. '╮')
  endif

  if use_popup
    add(lines, header_text .. hdr_pad .. right_info)
  else
    add(lines, '│' .. header_text .. hdr_pad .. right_info .. '│')
  endif

  # ── 进度条 (install/update 模式) ──
  if s_ui_mode =~# 'install\|update'
    var bar_width = W - 10
    var bar = ProgressBar(s_ui_finished, s_ui_total, bar_width)
    var pct = s_ui_total > 0 ? (s_ui_finished * 100 / s_ui_total) : 0
    var bar_content = printf('  %s %3d%%  ', bar, pct)
    if use_popup
      add(lines, repeat('─', W + 2))
      add(lines, bar_content)
    else
      add(lines, '├' .. repeat('─', W + 2) .. '┤')
      add(lines, '│' .. bar_content .. '│')
    endif
  endif

  if use_popup
    add(lines, repeat('─', W + 2))
  else
    add(lines, '├' .. repeat('─', W + 2) .. '┤')
  endif

  # ── 插件列表 ──
  if s_ui_mode ==# 'status_done'
    var th = printf('  %-2s %-22s %-10s %-8s %-5s %-6s', '', 'Plugin', 'Branch', 'Commit', 'Stat', 'Size')
    if use_popup
      add(lines, PadLine(th, W + 2))
      add(lines, '  ' .. repeat('─', W - 2) .. '  ')
    else
      add(lines, '│' .. PadLine(th, W + 2) .. '│')
      add(lines, '│  ' .. repeat('─', W - 2) .. '  │')
    endif
  endif

  var maxname = 0
  for p in display_plugins
    if len(p.name) > maxname
      maxname = len(p.name)
    endif
  endfor
  if maxname > 25
    maxname = 25
  endif

  # 获取排序后的显示顺序
  var sorted = s_ui_sorted_names
  if s_ui_filter_text !=# ''
    var filter_names = mapnew(display_plugins, (_, p) => p.name)
    sorted = filter(copy(sorted), (_, n) => index(filter_names, n) >= 0)
  endif

  var plug_line_idx = 0
  for pname in sorted
    var p = FindPlugin(pname)
    if p == {}
      continue
    endif
    var name = p.name
    var st = get(s_ui_plug_state, name, {status: 'waiting', msg: '', icon: '·', branch: '', commit: '', dirty: false})
    var icon = get(st, 'icon', '·')
    var msg = get(st, 'msg', '')
    var status = get(st, 'status', 'waiting')

    # 光标指示 (始终显示，方便导航)
    var is_cursor = (plug_line_idx == s_ui_cursor_line)
    var cursor_mark = is_cursor ? '▸' : ' '
    if is_cursor
      s_ui_cursor_buf_line = len(lines) + 1  # 下一行即将 add 的行号 (1-based)
    endif

    if s_ui_mode ==# 'status_done'
      var branch = get(st, 'branch', '')
      var commit = get(st, 'commit', '')
      var dirty = get(st, 'dirty', false)
      var dirty_flag = dirty ? '*' : ' '
      var status_text = status ==# 'done' ? 'ok' : 'missing'
      var display_name = len(name) > 22 ? name[: 21] : name
      var size_kb = get(st, 'size_kb', 0)
      var size_str = FormatSize(size_kb)
      var content = printf('%s %s %-22s %-10s %-8s %-4s%s %-5s',
        cursor_mark, icon, display_name,
        branch !=# '' ? branch[: 9] : '—',
        commit !=# '' ? commit[: 7] : '—',
        status_text, dirty_flag, size_str)
      if use_popup
        add(lines, PadLine(content, W + 2))
      else
        add(lines, '│' .. PadLine(content, W + 2) .. '│')
      endif
    else
      var display_name = len(name) > maxname ? name[: maxname - 1] : name
      # 耗时
      var timing_str = ''
      if has_key(s_ui_plug_timings, name)
        timing_str = printf(' %.1fs', s_ui_plug_timings[name])
      endif

      var content = ''
      if status ==# 'waiting' && !is_done
        content = printf('%s · %-' .. string(maxname) .. 's  waiting...', cursor_mark, display_name)
      elseif status ==# 'done'
        var avail = W - maxname - strdisplaywidth(timing_str) - 8
        var short_msg = len(msg) > avail ? msg[: avail - 1] : msg
        content = printf('%s %s %-' .. string(maxname) .. 's  %s%s', cursor_mark, icon, display_name, short_msg, timing_str)
      elseif status ==# 'error'
        var avail = W - maxname - strdisplaywidth(timing_str) - 8
        var short_msg = len(msg) > avail ? msg[: avail - 1] : msg
        content = printf('%s %s %-' .. string(maxname) .. 's  %s%s', cursor_mark, icon, display_name, short_msg, timing_str)
      elseif status ==# 'skipped'
        content = printf('%s %s %-' .. string(maxname) .. 's  frozen%s', cursor_mark, icon, display_name, timing_str)
      elseif status ==# 'removed'
        content = printf('%s %s %-' .. string(maxname) .. 's  removed', cursor_mark, icon, display_name)
      endif

      if content !=# ''
        if use_popup
          add(lines, PadLine(content, W + 2))
        else
          add(lines, '│' .. PadLine(content, W + 2) .. '│')
        endif
      endif
    endif
    plug_line_idx += 1
  endfor

  # Clean 模式
  if s_ui_mode =~# 'clean'
    if empty(s_ui_plug_state)
      var c = '  Nothing to clean.'
      if use_popup
        add(lines, PadLine(c, W + 2))
      else
        add(lines, '│' .. PadLine(c, W + 2) .. '│')
      endif
    else
      for [cname, cst] in items(s_ui_plug_state)
        var cicon = get(cst, 'icon', '')
        var c = printf('  %s %-30s removed', cicon, cname)
        if use_popup
          add(lines, PadLine(c, W + 2))
        else
          add(lines, '│' .. PadLine(c, W + 2) .. '│')
        endif
      endfor
    endif
  endif

  # ── 搜索栏 ──
  if s_ui_filter_active
    var filter_line = '  / ' .. s_ui_filter_text .. '▏'
    if use_popup
      add(lines, repeat('─', W + 2))
      add(lines, PadLine(filter_line, W + 2))
    else
      add(lines, '├' .. repeat('─', W + 2) .. '┤')
      add(lines, '│' .. PadLine(filter_line, W + 2) .. '│')
    endif
  endif

  # ── 统计摘要 ──
  if use_popup
    add(lines, repeat('─', W + 2))
  else
    add(lines, '├' .. repeat('─', W + 2) .. '┤')
  endif

  if is_done
    var summary = SummaryLine()
    if use_popup
      add(lines, PadLine(' ' .. summary, W + 2))
    else
      add(lines, '│ ' .. PadLine(summary, W) .. ' │')
    endif
  else
    var progress_text = printf(' %s  %d / %d plugins', spinner, s_ui_finished, s_ui_total)
    if use_popup
      add(lines, PadLine(progress_text, W + 2))
    else
      add(lines, '│' .. PadLine(progress_text, W + 2) .. '│')
    endif
  endif

  if !use_popup
    add(lines, '╰' .. repeat('─', W + 2) .. '╯')
  endif

  if is_done
    add(lines, '')
    add(lines, '  q close  j/k scroll  ⏎ open  d log  / filter  ? help  R retry  S status')
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

# ─────────────────── 窗口管理 (popup / split 双模式) ───────────────────

def UIOpen()
  if CanUsePopup()
    UIOpenPopup()
  else
    UIOpenSplit()
  endif
enddef

def UIOpenPopup()
  # 复用已有 popup
  if s_ui_popup_id > 0
    try
      popup_close(s_ui_popup_id)
    catch
    endtry
    s_ui_popup_id = 0
  endif

  # 创建后备缓冲区
  if s_ui_bufnr < 0 || !bufexists(s_ui_bufnr)
    s_ui_bufnr = bufadd('')
    bufload(s_ui_bufnr)
    setbufvar(s_ui_bufnr, '&buftype', 'nofile')
    setbufvar(s_ui_bufnr, '&bufhidden', 'hide')
    setbufvar(s_ui_bufnr, '&swapfile', 0)
    setbufvar(s_ui_bufnr, '&buflisted', 0)
  endif

  s_ui_use_popup = true
  UIBuildAndRender()

  var max_h = get(g:, 'simpleplug_window_height', 35)
  s_ui_popup_id = popup_create(s_ui_bufnr, {
    pos: 'center',
    minwidth: 62,
    maxwidth: 62,
    minheight: 10,
    maxheight: max_h,
    border: [],
    borderchars: ['─', '│', '─', '│', '╭', '╮', '╰', '╯'],
    borderhighlight: ['SPlugPopupBorder'],
    highlight: 'SPlugNormal',
    padding: [0, 0, 0, 0],
    scrollbar: 0,
    filter: function('PopupFilter'),
    callback: function('PopupOnClose'),
    mapping: 0,
    zindex: 200,
  })

  win_execute(s_ui_popup_id, 'setlocal cursorline')
  SetupSyntax()
  StartSpinner()
enddef

def UIOpenSplit()
  # 如果已有窗口，复用
  if s_ui_bufnr > 0 && bufexists(s_ui_bufnr)
    var wins = win_findbuf(s_ui_bufnr)
    if !empty(wins)
      win_gotoid(wins[0])
      s_ui_winid = wins[0]
      s_ui_use_popup = false
      UIBuildAndRender()
      StartSpinner()
      return
    endif
  endif

  # 新建分屏
  s_ui_use_popup = false
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
  nnoremap <buffer><silent> <CR> <Cmd>call simpleplug#OpenPluginDir()<CR>
  nnoremap <buffer><silent> d <Cmd>call simpleplug#ViewPluginDiff()<CR>
  nnoremap <buffer><silent> ? <Cmd>call simpleplug#ToggleHelp()<CR>
  nnoremap <buffer><silent> / <Cmd>call simpleplug#StartFilterSplit()<CR>

  UIBuildAndRender()
  SetupSyntax()
  StartSpinner()
enddef

export def UIClose()
  StopSpinner()
  if s_ui_use_popup
    if s_ui_popup_id > 0
      try
        popup_close(s_ui_popup_id)
      catch
      endtry
      s_ui_popup_id = 0
    endif
    # 清理缓冲区
    if s_ui_bufnr > 0 && bufexists(s_ui_bufnr)
      try
        execute 'bwipeout! ' .. s_ui_bufnr
      catch
      endtry
    endif
  else
    if s_ui_bufnr > 0 && bufexists(s_ui_bufnr)
      execute 'bwipeout ' .. s_ui_bufnr
    endif
  endif
  s_ui_bufnr = -1
  s_ui_winid = 0
  s_ui_popup_id = 0
  s_ui_use_popup = false
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
  if s_ui_use_popup
    if s_ui_popup_id > 0 && s_ui_bufnr > 0 && bufexists(s_ui_bufnr)
      setbufvar(s_ui_bufnr, '&modifiable', 1)
      deletebufline(s_ui_bufnr, 1, '$')
      setbufline(s_ui_bufnr, 1, s_ui_lines)
      setbufvar(s_ui_bufnr, '&modifiable', 0)
      # 将 popup 内光标移动到选中行
      if s_ui_cursor_buf_line > 0
        win_execute(s_ui_popup_id, 'normal! ' .. s_ui_cursor_buf_line .. 'G')
      endif
    endif
    return
  endif

  # Split 模式
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
  var desired_h = len(s_ui_lines) + 1
  var max_h = get(g:, 'simpleplug_window_height', 15)
  if desired_h > max_h
    desired_h = max_h
  endif
  if desired_h < 5
    desired_h = 5
  endif
  win_execute(wins[0], ':resize ' .. desired_h)
  # 将光标移动到选中行
  if s_ui_cursor_buf_line > 0
    win_execute(wins[0], 'normal! ' .. s_ui_cursor_buf_line .. 'G')
  endif
enddef

# ─────────────────── Popup 事件处理 ───────────────────

def PopupFilter(winid: number, key: string): bool
  # 搜索模式的按键处理
  if s_ui_filter_active
    if key ==# "\<CR>" || key ==# "\<Esc>"
      s_ui_filter_active = false
      if key ==# "\<Esc>"
        s_ui_filter_text = ''
      endif
      UIBuildAndRender()
      return true
    elseif key ==# "\<BS>"
      if len(s_ui_filter_text) > 0
        s_ui_filter_text = s_ui_filter_text[: -2]
      endif
      UIBuildAndRender()
      return true
    elseif len(key) == 1 && key =~# '[[:print:]]'
      s_ui_filter_text ..= key
      UIBuildAndRender()
      return true
    endif
    return true
  endif

  # 普通模式按键
  if key ==# 'q' || key ==# "\<Esc>"
    popup_close(winid)
    return true
  elseif key ==# 'j'
    ScrollDown()
    return true
  elseif key ==# 'k'
    ScrollUp()
    return true
  elseif key ==# "\<CR>"
    DoOpenPluginDir()
    return true
  elseif key ==# 'd'
    DoViewPluginDiff()
    return true
  elseif key ==# '?'
    DoToggleHelp()
    return true
  elseif key ==# '/'
    s_ui_filter_active = true
    s_ui_filter_text = ''
    UIBuildAndRender()
    return true
  elseif key ==# 'R'
    UIRetry()
    return true
  elseif key ==# 'S'
    Status()
    return true
  endif
  return false
enddef

def PopupOnClose(winid: number, result: any)
  StopSpinner()
  s_ui_popup_id = 0
  s_ui_use_popup = false
  s_ui_filter_active = false
  s_ui_filter_text = ''
  # 清理缓冲区
  if s_ui_bufnr > 0 && bufexists(s_ui_bufnr)
    try
      execute 'bwipeout! ' .. s_ui_bufnr
    catch
    endtry
  endif
  s_ui_bufnr = -1
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

def LogPopupFilter(wid: number, k: string): bool
  if k ==# 'q' || k ==# "\<Esc>"
    popup_close(wid)
    return true
  elseif k ==# 'j'
    win_execute(wid, 'normal! j')
    return true
  elseif k ==# 'k'
    win_execute(wid, 'normal! k')
    return true
  endif
  return false
enddef

def HelpPopupFilter(wid: number, k: string): bool
  if k ==# '?' || k ==# 'q' || k ==# "\<Esc>"
    popup_close(wid)
    s_ui_help_popup_id = 0
    return true
  endif
  return false
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

  if CanUsePopup()
    popup_create(log_lines, {
      pos: 'center',
      minwidth: 72,
      maxwidth: 72,
      minheight: 5,
      maxheight: 25,
      border: [],
      borderchars: ['─', '│', '─', '│', '╭', '╮', '╰', '╯'],
      borderhighlight: ['SPlugPopupBorder'],
      highlight: 'SPlugNormal',
      title: ' ' .. name .. ' git log ',
      scrollbar: 1,
      zindex: 250,
      filter: function('LogPopupFilter'),
      mapping: 0,
    })
  else
    botright new
    setlocal buftype=nofile bufhidden=wipe noswapfile
    setlocal nowrap nonumber norelativenumber
    setline(1, ['  ' .. name .. ' git log', repeat('─', 60)] + log_lines)
    setlocal nomodifiable
    nnoremap <buffer><silent> q <Cmd>bwipeout<CR>
  endif
enddef

def DoToggleHelp()
  if s_ui_help_popup_id > 0
    try
      popup_close(s_ui_help_popup_id)
    catch
    endtry
    s_ui_help_popup_id = 0
    return
  endif

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
    '    ?           切换帮助',
    '',
  ]

  if CanUsePopup()
    s_ui_help_popup_id = popup_create(help_lines, {
      pos: 'center',
      minwidth: 36,
      maxwidth: 36,
      border: [],
      borderchars: ['─', '│', '─', '│', '╭', '╮', '╰', '╯'],
      borderhighlight: ['SPlugPopupBorder'],
      highlight: 'SPlugNormal',
      zindex: 300,
      filter: function('HelpPopupFilter'),
      mapping: 0,
    })
  else
    for l in help_lines
      echo l
    endfor
  endif
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
  var w: number
  if s_ui_use_popup && s_ui_popup_id > 0
    w = s_ui_popup_id
  else
    if s_ui_bufnr < 0 || !bufexists(s_ui_bufnr)
      return
    endif
    var wins = win_findbuf(s_ui_bufnr)
    if empty(wins)
      return
    endif
    w = wins[0]
  endif

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
  # ✓
  win_execute(w, 'syntax match SPlugCheckDone /✓/')
  # 光标指示
  win_execute(w, 'syntax match SPlugCursor /▸/')
  # 帮助文本
  win_execute(w, 'syntax match SPlugHelp /q close.*$/')
  # 表头
  win_execute(w, 'syntax match SPlugTableHeader /Plugin\s\+Branch\s\+Commit\s\+Stat\s\+Size/')
  # waiting
  win_execute(w, 'syntax match SPlugWaiting /waiting\.\.\./')
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
  win_execute(w, 'highlight default SPlugPopupBorder ctermfg=75 guifg=#5fafff')
  # 标题
  win_execute(w, 'highlight default SPlugTitle ctermfg=75 guifg=#5fafff cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugCount ctermfg=252 guifg=#d0d0d0')
  # 进度条 (渐变色)
  win_execute(w, 'highlight default SPlugBarFill ctermfg=114 guifg=#87d787')
  win_execute(w, 'highlight default SPlugBarEmpty ctermfg=238 guifg=#444444')
  win_execute(w, 'highlight default SPlugPct ctermfg=252 guifg=#d0d0d0 cterm=bold gui=bold')
  # 状态图标
  win_execute(w, 'highlight default SPlugIconOk ctermfg=114 guifg=#87d787')
  win_execute(w, 'highlight default SPlugIconNew ctermfg=114 guifg=#87d787 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugIconUp ctermfg=180 guifg=#d7af87')
  win_execute(w, 'highlight default SPlugIconErr ctermfg=204 guifg=#ff5f87 cterm=bold gui=bold')
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
  win_execute(w, 'highlight default SPlugSumErrors ctermfg=204 guifg=#ff5f87 cterm=bold gui=bold')
  win_execute(w, 'highlight default SPlugDiffAdd ctermfg=114 guifg=#87d787')
  win_execute(w, 'highlight default SPlugDiffDel ctermfg=204 guifg=#ff5f87')
  win_execute(w, 'highlight default SPlugSize ctermfg=245 guifg=#8a8a8a')
  win_execute(w, 'highlight default SPlugErrMsg ctermfg=204 guifg=#ff5f87')
enddef
