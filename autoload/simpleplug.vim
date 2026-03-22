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
        newparts->add(p)
      endif
    endfor
    &runtimepath = newparts->join(',')
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

  s_plugins->add({
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
    specs->add({
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

export def Install()
  if !EnsureBackend()
    return
  endif
  UIOpen('Installing plugins...')
  var id = NextId()
  s_cbs[id] = {
    OnDone: (ev) => {
      var s = ev.summary
      UIAppend(printf('Done! Installed: %d, Already: %d, Errors: %d',
        get(s, 'installed', 0), get(s, 'already_ok', 0), get(s, 'errors', 0)))
      UIAppend('')
      UIAppend('Press q to close.')
    },
    OnError: (ev) => {
      UIAppend('ERROR: ' .. get(ev, 'message', ''))
    },
  }
  Send({type: 'install', id: id, plugins: PluginSpecs()})
enddef

export def Update()
  if !EnsureBackend()
    return
  endif
  UIOpen('Updating plugins...')
  var id = NextId()
  s_cbs[id] = {
    OnDone: (ev) => {
      var s = ev.summary
      UIAppend(printf('Done! Updated: %d, Already: %d, Errors: %d',
        get(s, 'updated', 0), get(s, 'already_ok', 0), get(s, 'errors', 0)))
      UIAppend('')
      UIAppend('Press q to close.')
    },
    OnError: (ev) => {
      UIAppend('ERROR: ' .. get(ev, 'message', ''))
    },
  }
  Send({type: 'update', id: id, plugins: PluginSpecs()})
enddef

export def Clean()
  if !EnsureBackend()
    return
  endif
  # 收集所有注册插件的目录名
  var keep: list<string> = []
  for p in s_plugins
    keep->add(fnamemodify(p.dir, ':t'))
  endfor
  UIOpen('Cleaning unregistered plugins...')
  var id = NextId()
  Send({type: 'clean', id: id, plugdir: g:simpleplug_dir, keep: keep})
enddef

export def Status()
  if !EnsureBackend()
    return
  endif
  UIOpen('Querying plugin status...')
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
  UIOpen('Running hook for ' .. name .. '...')
  var id = NextId()
  Send({type: 'post_hook', id: id, name: name, dir: plug.dir, cmd: do_cmd})
enddef

export def CompletePluginNames(arglead: string, cmdline: string, cursorpos: number): list<string>
  var names: list<string> = []
  for p in s_plugins
    if p.name =~? '^' .. arglead
      names->add(p.name)
    endif
  endfor
  return names
enddef

# =============================================================
# 事件处理
# =============================================================

def OnProgress(ev: dict<any>)
  var name = get(ev, 'name', '')
  var status = get(ev, 'status', '')
  var msg = get(ev, 'message', '')
  var icon = StatusIcon(status)
  UIUpdateOrAppend(name, printf('%s %s: %s', icon, name, msg))
enddef

def OnDone(ev: dict<any>)
  # 由回调处理
enddef

def OnError(ev: dict<any>)
  var msg = get(ev, 'message', '')
  UIAppend('ERROR: ' .. msg)
enddef

def OnStatusResult(ev: dict<any>)
  var items = get(ev, 'items', [])
  s_ui_lines = ['Plugin Status:', '']
  var maxlen = 0
  for item in items
    var l = len(item.name)
    if l > maxlen
      maxlen = l
    endif
  endfor
  for item in items
    var icon = item.installed ? '✓' : '✗'
    var branch = item.branch
    var commit = item.commit
    var dirty = item.dirty ? ' [modified]' : ''
    var line = printf(' %s %-' .. string(maxlen) .. 's  %s %s%s',
      icon, item.name,
      branch !=# '' ? branch : '-',
      commit !=# '' ? commit : '-',
      dirty)
    s_ui_lines->add(line)
  endfor
  s_ui_lines->add('')
  s_ui_lines->add('Press q to close.')
  UIRender()
enddef

def OnHookDone(ev: dict<any>)
  var name = get(ev, 'name', '')
  var ok = get(ev, 'ok', false)
  var output = get(ev, 'output', '')
  var icon = ok ? '✓' : '✗'
  UIAppend(printf('%s Hook %s: %s', icon, name, output))
  UIAppend('')
  UIAppend('Press q to close.')
enddef

def OnCleanDone(ev: dict<any>)
  var removed = get(ev, 'removed', [])
  if empty(removed)
    UIAppend('Nothing to clean.')
  else
    UIAppend('Removed ' .. string(len(removed)) .. ' plugin(s):')
    for r in removed
      UIAppend('  - ' .. r)
    endfor
  endif
  UIAppend('')
  UIAppend('Press q to close.')
enddef

def StatusIcon(status: string): string
  if status ==# 'installed'
    return '+'
  elseif status ==# 'updated'
    return '↑'
  elseif status ==# 'already'
    return '='
  elseif status ==# 'skipped'
    return '-'
  elseif status ==# 'hook'
    return '⚙'
  elseif status ==# 'error'
    return '✗'
  endif
  return '·'
enddef

# =============================================================
# UI — 底部分屏进度窗口
# =============================================================

def UIOpen(title: string)
  s_ui_lines = [title, '']

  # 如果已有窗口，复用
  if s_ui_bufnr > 0 && bufexists(s_ui_bufnr)
    var wins = win_findbuf(s_ui_bufnr)
    if !empty(wins)
      win_gotoid(wins[0])
      s_ui_winid = wins[0]
      UIRender()
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

  # 按键映射
  nnoremap <buffer><silent> q <Cmd>close<CR>

  UIRender()
  SetupSyntax()
enddef

def UIRender()
  if s_ui_bufnr < 0 || !bufexists(s_ui_bufnr)
    return
  endif
  var wins = win_findbuf(s_ui_bufnr)
  if empty(wins)
    return
  endif
  # 在 UI 窗口中执行
  win_execute(wins[0], 'setlocal modifiable')
  deletebufline(s_ui_bufnr, 1, '$')
  setbufline(s_ui_bufnr, 1, s_ui_lines)
  win_execute(wins[0], 'setlocal nomodifiable')
  # 滚动到底部
  win_execute(wins[0], 'normal! G')
enddef

def UIAppend(line: string)
  s_ui_lines->add(line)
  UIRender()
enddef

def UIUpdateOrAppend(name: string, newline: string)
  # 如果已有该插件的行，更新之；否则追加
  var found = false
  var i = 0
  for l in s_ui_lines
    if l =~# '\V' .. escape(name, '\') .. ':'
      s_ui_lines[i] = newline
      found = true
      break
    endif
    i += 1
  endfor
  if !found
    s_ui_lines->add(newline)
  endif
  UIRender()
enddef

def SetupSyntax()
  if s_ui_bufnr < 0 || !bufexists(s_ui_bufnr)
    return
  endif
  var wins = win_findbuf(s_ui_bufnr)
  if empty(wins)
    return
  endif
  win_execute(wins[0], 'syntax clear')
  win_execute(wins[0], 'syntax match SimplePlugTitle /^.*plugins\.\.\.$/  contains=SimplePlugHeader')
  win_execute(wins[0], 'syntax match SimplePlugInstalled /^+ .*$/')
  win_execute(wins[0], 'syntax match SimplePlugUpdated /^↑ .*$/')
  win_execute(wins[0], 'syntax match SimplePlugAlready /^= .*$/')
  win_execute(wins[0], 'syntax match SimplePlugError /^✗ .*$/')
  win_execute(wins[0], 'syntax match SimplePlugHook /^⚙ .*$/')
  win_execute(wins[0], 'syntax match SimplePlugOk / ✓ /')
  win_execute(wins[0], 'syntax match SimplePlugFail / ✗ /')
  win_execute(wins[0], 'syntax match SimplePlugDone /^Done!.*$/')

  win_execute(wins[0], 'highlight default link SimplePlugTitle Title')
  win_execute(wins[0], 'highlight default link SimplePlugInstalled DiffAdd')
  win_execute(wins[0], 'highlight default link SimplePlugUpdated DiffChange')
  win_execute(wins[0], 'highlight default link SimplePlugAlready Comment')
  win_execute(wins[0], 'highlight default link SimplePlugError ErrorMsg')
  win_execute(wins[0], 'highlight default link SimplePlugHook Type')
  win_execute(wins[0], 'highlight default link SimplePlugOk DiffAdd')
  win_execute(wins[0], 'highlight default link SimplePlugFail ErrorMsg')
  win_execute(wins[0], 'highlight default link SimplePlugDone MoreMsg')
enddef
