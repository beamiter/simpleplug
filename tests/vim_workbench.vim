vim9script

set nomore
g:simpleplug_workbench_test_done = false
autocmd VimLeavePre * {
  if !g:simpleplug_workbench_test_done
    cquit 1
  endif
}
const ROOT = fnamemodify(expand('<sfile>'), ':p:h:h')
const TMP = tempname()
mkdir(TMP, 'p')
execute 'set runtimepath^=' .. fnameescape(ROOT)
g:simpleplug_auto_install = 0
g:simpleplug_activate_on_install = 0
g:simpleplug_daemon_path = ROOT .. '/tests/fake_plug_daemon.py'
execute 'source ' .. fnameescape(ROOT .. '/plugin/simpleplug.vim')
simpleplug#Begin(TMP)
for name in ['one', 'two', 'broken']
  simpleplug#Plug('fixture/' .. name, {dir: TMP .. '/' .. name})
endfor
simpleplug#End()

var original_buffer = bufnr()
var original_window = win_getid()
var original_windows = winnr('$')
var original_text = getline(1, '$')
var original_view = winsaveview()
var expected = {known: true, running: false, operation: '', total: 0,
  completed: 0, installed: 0, updated: 0, errors: 0}
for _ in range(20)
  assert_equal(expected, simpleplug#WorkbenchState())
endfor
assert_false(simpleplug#core#IsRunning(), 'snapshot started the plugin daemon')
assert_false(exists('g:simpleplug_last_result'), 'snapshot manufactured an operation result')
assert_equal(original_buffer, bufnr())
assert_equal(original_window, win_getid())
assert_equal(original_windows, winnr('$'))
assert_equal(original_text, getline(1, '$'))
assert_equal(original_view, winsaveview())

g:simpleplug_workbench_events = []
autocmd User SimplePlugStateChanged add(g:simpleplug_workbench_events, simpleplug#WorkbenchState())
$FAKE_PLUG_DELAY_MS = '250'
$FAKE_PLUG_FAIL = 'broken'
simpleplug#Install()
var running = simpleplug#WorkbenchState()
assert_true(running.running)
assert_equal('install', running.operation)
assert_equal(3, running.total)
assert_equal(0, running.completed)
var copy = simpleplug#WorkbenchState()
copy.operation = 'corrupted'
assert_equal('install', simpleplug#WorkbenchState().operation)
simpleplug#Update()
assert_equal('install', simpleplug#WorkbenchState().operation,
  'a concurrent operation replaced the active one')
simpleplug#Await(10)
var complete = simpleplug#WorkbenchState()
assert_equal({known: true, running: false, operation: 'install', total: 3,
  completed: 3, installed: 2, updated: 0, errors: 1}, complete)
assert_true(len(g:simpleplug_workbench_events) >= 3, 'missing progress events')
assert_true(g:simpleplug_workbench_events[0].running, 'start event was already idle')
assert_false(g:simpleplug_workbench_events[-1].running, 'completion event still advertised Stop')
assert_true(len(filter(copy(g:simpleplug_workbench_events), (_, state) => state.running && state.completed > 0)) > 0,
  'intermediate progress was not published')
simpleplug#UIClose()
simpleplug#Stop()

# Cancellation used to leave the UI spinning and allowed a late response to
# republish a successful result because active_id == 0 bypassed its guard.
$FAKE_PLUG_DELAY_MS = '1500'
$FAKE_PLUG_FAIL = ''
$FAKE_PLUG_DUMP = TMP .. '/requests.jsonl'
simpleplug#Update()
assert_true(simpleplug#WorkbenchState().running)
sleep 100m
var requests = mapnew(readfile($FAKE_PLUG_DUMP), (_, value) => json_decode(value))
var update = filter(requests, (_, request) => request.type ==# 'update')[0]
simpleplug#Stop()
var cancelled = simpleplug#WorkbenchState()
assert_false(cancelled.running)
assert_equal(3, cancelled.errors, 'cancelled tasks were reported as successful')
assert_equal('update', cancelled.operation)
var script = getscriptinfo({name: 'autoload/simpleplug.vim'})[0]
var Dispatch = function(printf('<SNR>%d_OnDaemonEvent', script.sid))
call(Dispatch, [{type: 'progress', id: update.id, name: 'one', status: 'updated', message: 'late'}])
call(Dispatch, [{type: 'done', id: update.id}])
assert_equal(cancelled, simpleplug#WorkbenchState(), 'stale response mutated a cancelled result')
simpleplug#UIClose()

# Consumer errors cannot abort the operation or suppress its completion.
autocmd User SimplePlugStateChanged throw 'broken workbench observer fixture'
$FAKE_PLUG_DELAY_MS = ''
simpleplug#Install([], true)
assert_false(simpleplug#WorkbenchState().running)
assert_equal(3, simpleplug#WorkbenchState().installed)
assert_equal(0, simpleplug#WorkbenchState().errors)
simpleplug#UIClose()
simpleplug#Stop()
delete(TMP, 'rf')

g:simpleplug_workbench_test_done = true
if !empty(v:errors)
  writefile(v:errors, '/dev/stderr')
  cquit 1
endif
qa!
