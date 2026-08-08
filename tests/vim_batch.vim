vim9script

# ============================================================================
# What the Vim side does with an install/update batch, driven end to end
# through the real supervisor against a scripted daemon (tests/fake_plug_
# daemon.py): the completion event and its result dictionary, the synchronous
# bang, and activation of a freshly installed plugin in the running session.
#
# Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_batch.vim
# ============================================================================

set nomore
g:simpleplug_auto_install = 0

# -es turns several kinds of abort — including anything that consumes the
# script's own input, which is how the first draft of the synchronous wait
# failed — into a silent exit 0.  A truncated run must never look like a pass.
g:simpleplug_batch_done = 0
autocmd VimLeavePre * {
  if !g:simpleplug_batch_done
    echom 'vim_batch.vim exited before it finished'
    cquit 1
  endif
}

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
execute 'source ' .. fnameescape(root .. '/plugin/simpleplug.vim')

var fake = root .. '/tests/fake_plug_daemon.py'
if !executable(fake)
  # CI checkouts do not always preserve the mode bit.
  setfperm(fake, 'rwxr-xr-x')
endif
g:simpleplug_daemon_path = fake

var home = tempname()
mkdir(home, 'p')

# A plugin's checkout only appears when the daemon reports it installed, so
# End() cannot have loaded it: everything below is activation or nothing.
def PlantTemplate(dir: string, body: list<string>, ftdetect: list<string> = [])
  mkdir(dir .. '.src/plugin', 'p')
  writefile(body, dir .. '.src/plugin/fixture.vim')
  if !empty(ftdetect)
    mkdir(dir .. '.src/ftdetect', 'p')
    writefile(ftdetect, dir .. '.src/ftdetect/fixture.vim')
  endif
enddef

var eager_dir = home .. '/batch-eager'
PlantTemplate(eager_dir, [
  'vim9script',
  "g:simpleplug_batch_eager_loaded = get(g:, 'simpleplug_batch_eager_loaded', 0) + 1",
  'command! BatchEagerCommand g:simpleplug_batch_eager_ran = 1',
], [
  'vim9script',
  'autocmd BufRead,BufNewFile *.batchfixture setfiletype batchfixture',
])

var lazy_dir = home .. '/batch-lazy'
PlantTemplate(lazy_dir, [
  'vim9script',
  "g:simpleplug_batch_lazy_loaded = get(g:, 'simpleplug_batch_lazy_loaded', 0) + 1",
  'command! BatchLazyCommand g:simpleplug_batch_lazy_ran = 1',
])

# Deliberately has no template: the daemon reports it installed, but nothing
# lands on disk. Activation must report that and leave the plugin unloaded.
var phantom_dir = home .. '/batch-phantom'

$FAKE_PLUG_FAIL = 'batch-failing'
$FAKE_PLUG_FROZEN = 'batch-frozen'

g:simpleplug_batch_events = 0
autocmd User SimplePlugComplete g:simpleplug_batch_events += 1

def RegisterAll()
  simpleplug#Begin(home)
  simpleplug#Plug('local/batch-eager', {as: 'batch-eager', dir: eager_dir})
  simpleplug#Plug('local/batch-lazy', {as: 'batch-lazy', dir: lazy_dir, on: 'BatchLazyCommand'})
  simpleplug#Plug('local/batch-phantom', {as: 'batch-phantom', dir: phantom_dir})
  simpleplug#Plug('local/batch-failing', {as: 'batch-failing', dir: home .. '/batch-failing'})
  simpleplug#Plug('local/batch-frozen', {as: 'batch-frozen', dir: home .. '/batch-frozen'})
  simpleplug#End()
enddef

RegisterAll()
assert_false(exists('g:simpleplug_batch_eager_loaded'), 'plugin loaded before it was installed')
assert_true(index(split(&runtimepath, ','), eager_dir) < 0,
  'an uninstalled plugin was already on runtimepath')

# ── the synchronous bang ────────────────────────────────────────────────────
# Without it this returns before a single "clone" completes, which is why
# `vim -es +PlugInstall +qall` never worked as a bootstrap.
PlugInstall!

assert_equal(1, g:simpleplug_batch_events, 'SimplePlugComplete did not fire exactly once')
var result = simpleplug#LastResult()
assert_equal('install', get(result, 'mode', ''), 'result did not name the operation')
assert_equal(5, get(result, 'total', 0))
assert_equal(3, get(result, 'installed', -1), 'wrong installed count: ' .. string(result))
assert_equal(1, get(result, 'frozen', -1))
assert_equal(1, get(result, 'errors', -1))
assert_equal(['batch-failing'], mapnew(get(result, 'failed', []), (_, f) => f.name))
assert_match('clone failed', get(result, 'failed', [{}])[0].message)
assert_true(get(result, 'elapsed', -1.0) >= 0.0, 'result carried no elapsed time')

# ── activation ──────────────────────────────────────────────────────────────
assert_equal(1, get(g:, 'simpleplug_batch_eager_loaded', 0),
  'a newly installed plugin was not activated in the running session')
assert_equal(2, exists(':BatchEagerCommand'), 'activated plugin defined no command')
assert_true(index(split(&runtimepath, ','), eager_dir) >= 0,
  'activated plugin is missing from runtimepath')

# Its ftdetect has to be sourced by hand: Vim only walks runtimepath for
# ftdetect at startup, which for a first-run install has long since happened.
# In its own scratch buffer — the current window here is the progress window,
# and setting a filetype on that buffer would break every later UI assertion.
new
setlocal buftype=nofile bufhidden=wipe noswapfile
doautocmd BufRead example.batchfixture
assert_equal('batchfixture', &filetype, 'activated plugin ftdetect did not run')
bwipeout!

# A lazy plugin gets its triggers armed, not its body sourced.
assert_false(exists('g:simpleplug_batch_lazy_loaded'), 'lazy plugin was activated eagerly')
assert_equal(2, exists(':BatchLazyCommand'), 'newly installed lazy plugin got no command stub')
BatchLazyCommand
assert_equal(1, get(g:, 'simpleplug_batch_lazy_loaded', 0), 'lazy stub did not load the plugin')
assert_equal(1, get(g:, 'simpleplug_batch_lazy_ran', 0), 'lazy command was not replayed')

# The plugin that never landed is reported, not silently skipped.
assert_match('batch-phantom runtime directory is missing:', execute('messages'))

# ── a second run must not re-announce or re-activate ────────────────────────
PlugUpdate!
assert_equal(2, g:simpleplug_batch_events, 'update did not announce completion')
result = simpleplug#LastResult()
assert_equal('update', get(result, 'mode', ''))
assert_equal(3, get(result, 'updated', -1), 'wrong updated count: ' .. string(result))
assert_equal(1, get(g:, 'simpleplug_batch_eager_loaded', 0),
  'an update re-sourced an already loaded plugin')

# ── activation can be switched off ──────────────────────────────────────────
var opt_out_dir = home .. '/batch-optout'
PlantTemplate(opt_out_dir, [
  'vim9script',
  "g:simpleplug_batch_optout_loaded = get(g:, 'simpleplug_batch_optout_loaded', 0) + 1",
])
g:simpleplug_activate_on_install = 0
simpleplug#Begin(home)
simpleplug#Plug('local/batch-optout', {as: 'batch-optout', dir: opt_out_dir})
simpleplug#End()
PlugInstall!
assert_equal(1, get(simpleplug#LastResult(), 'installed', -1))
assert_true(isdirectory(opt_out_dir), 'opt-out run did not install the plugin')
assert_false(exists('g:simpleplug_batch_optout_loaded'),
  'g:simpleplug_activate_on_install = 0 still activated the plugin')
g:simpleplug_activate_on_install = 1

# ── activation must not be able to void the completion contract ─────────────
# `on: 'fzf'` is a plausible typo: a lazy trigger has to be a valid user
# command name, so :command! throws E183 from inside ActivateInstalled. That
# exception used to take the rest of OnDone with it and land in a bare catch —
# no helptags, no fresh g:simpleplug_last_result and no SimplePlugComplete, so
# `:PlugInstall!` returned silently carrying the previous run's dictionary.
var bad_dir = home .. '/batch-badlazy'
PlantTemplate(bad_dir, [
  'vim9script',
  'g:simpleplug_batch_badlazy_loaded = 1',
])
var events_before = g:simpleplug_batch_events
simpleplug#Stop()
simpleplug#Begin(home)
simpleplug#Plug('local/batch-badlazy', {as: 'batch-badlazy', dir: bad_dir, on: 'fzf'})
simpleplug#End()
g:simpleplug_last_result = {'sentinel': 'STALE'}
PlugInstall!
assert_equal(events_before + 1, g:simpleplug_batch_events,
  'a throw inside activation swallowed the completion event')
result = simpleplug#LastResult()
assert_equal('install', get(result, 'mode', ''),
  'the completion result was left stale: ' .. string(result))
assert_equal(1, get(result, 'installed', -1),
  'the completion result was left stale: ' .. string(result))
# And the plugin that could not be activated says so on its own row (the
# Details column is truncated to the window, so only its beginning is visible).
var bad_bufs = filter(getbufinfo(), (_, b) => getbufvar(b.bufnr, '&filetype') ==# 'simpleplug')
assert_equal(1, len(bad_bufs), 'expected exactly one progress buffer')
var bad_rows = filter(getbufline(bad_bufs[0].bufnr, 1, '$'), (_, l) => l =~# 'batch-badlazy')
assert_equal(1, len(bad_rows), 'the progress UI did not render the plugin')
assert_match('activate: Vim', bad_rows[0],
  'a failed activation was not reported on the plugin row')

# ── :PlugRestore must move a frozen plugin ──────────────────────────────────
# The daemon tests `frozen` before it looks at the commit pin, so a restore
# that forwards frozen:true has the plugin reported as skipped and the checkout
# left where it was — while the UI shows a plain `frozen` row that reads as
# success. What goes over the wire is the only place this is observable.
var dump = home .. '/requests.jsonl'
$FAKE_PLUG_DUMP = dump
var pinned_oid = repeat('a1b2c3d4', 5)
var lockfile = home .. '/lock.json'
writefile([json_encode({'batch-frozen': pinned_oid})], lockfile)
simpleplug#Stop()
simpleplug#Begin(home)
simpleplug#Plug('local/batch-frozen', {as: 'batch-frozen', dir: home .. '/batch-frozen', frozen: 1})
simpleplug#End()
simpleplug#Restore(lockfile)
simpleplug#Await(30)
var sent = filter(mapnew(readfile(dump), (_, l) => json_decode(l)),
  (_, r) => get(r, 'type', '') ==# 'update')
assert_equal(1, len(sent), 'restore did not send exactly one update request')
assert_equal(pinned_oid, sent[0].plugins[0].commit, 'restore did not pin the snapshot commit')
assert_false(sent[0].plugins[0].frozen, 'restore asked the daemon to skip a frozen plugin')
$FAKE_PLUG_DUMP = ''

# ── :PlugDiff and per-plugin rollback ───────────────────────────────────────
# An update used to be a formatted string and nothing else: no way to see which
# commits landed, and no way to undo them.
var diff_dump = home .. '/diff-requests.jsonl'
$FAKE_PLUG_DUMP = diff_dump
simpleplug#Stop()
simpleplug#Begin(home)
simpleplug#Plug('local/diff-one', {as: 'diff-one', dir: home .. '/diff-one'})
simpleplug#Plug('local/diff-two', {as: 'diff-two', dir: home .. '/diff-two'})
simpleplug#End()
PlugUpdate!
simpleplug#UIClose()

# The record outlives the session that made it, and carries only plugins that
# are still registered — the earlier sections' updates are not in it.
var record_path = home .. '/.simpleplug-lastupdate.json'
assert_true(filereadable(record_path), 'an update wrote no diff record')
var record = json_decode(join(readfile(record_path), "\n"))
assert_equal(1, get(record, 'version', 0), 'diff record is not versioned')
assert_equal(['diff-one', 'diff-two'], sort(keys(record.plugins)),
  'diff record kept plugins that are no longer registered: ' .. string(keys(record.plugins)))

PlugDiff
assert_match('SimplePlug diff', getline(1), ':PlugDiff rendered no header')
var diff_rows = filter(range(1, line('$')), (_, l) => getline(l) =~# '^  diff-one\s')
assert_equal(1, len(diff_rows), ':PlugDiff did not render one header per plugin')
assert_match('→', getline(diff_rows[0]), ':PlugDiff header shows no commit range')
assert_match('(2 commits)', getline(diff_rows[0]), ':PlugDiff did not count the incoming commits')
assert_true(index(getline(1, '$'), '      1111111 diff-one newer') >= 0,
  ':PlugDiff listed no commit subjects')
assert_match('simpleplug#DiffRollback', maparg('X', 'n'), 'X is not bound to a rollback')
bwipeout!

# Rolling back is an ordinary commit-pinned update; what goes over the wire is
# the only place the pin and the frozen override are observable.
delete(diff_dump)
simpleplug#Rollback('diff-one', true)
simpleplug#Await(30)
var rolled = filter(mapnew(readfile(diff_dump), (_, l) => json_decode(l)),
  (_, r) => get(r, 'type', '') ==# 'update')
assert_equal(1, len(rolled), 'rollback did not send exactly one update request')
assert_equal(['diff-one'], mapnew(rolled[0].plugins, (_, p) => p.name),
  'rollback touched more than the plugin it was asked about')
assert_equal(record.plugins['diff-one'].from, rolled[0].plugins[0].commit,
  'rollback did not pin the commit the plugin was updated from')
assert_false(rolled[0].plugins[0].frozen, 'rollback asked the daemon to skip a frozen plugin')

# A plugin nobody recorded an update for cannot be rolled back to nothing.
simpleplug#Rollback('diff-two-missing', true)
assert_match('no recorded update to roll back for: diff-two-missing', execute('messages'))
simpleplug#UIClose()
$FAKE_PLUG_DUMP = ''

# ── :PlugCheck ──────────────────────────────────────────────────────────────
# Before this, the only way to learn whether anything needed updating was to
# update everything — rewriting every checkout and re-running every `do` hook.
var check_dump = home .. '/check-requests.jsonl'
$FAKE_PLUG_DUMP = check_dump
$FAKE_PLUG_BEHIND = 'check-behind'
$FAKE_PLUG_FROZEN = ''
simpleplug#Stop()
simpleplug#Begin(home)
simpleplug#Plug('local/check-current', {as: 'check-current', dir: home .. '/check-current'})
simpleplug#Plug('local/check-behind', {as: 'check-behind', dir: home .. '/check-behind'})
simpleplug#End()
PlugCheck
simpleplug#Await(30)
var check_result = simpleplug#LastResult()
assert_equal('check', get(check_result, 'mode', ''), ':PlugCheck did not publish a result')
assert_equal(1, get(check_result, 'behind', -1),
  'wrong behind count: ' .. string(check_result))

# The whole point is that it changes nothing.
var check_sent = mapnew(readfile(check_dump), (_, l) => json_decode(l))
assert_equal([], filter(mapnew(check_sent, (_, r) => get(r, 'type', '')),
  (_, t) => t ==# 'install' || t ==# 'update'),
  'a check sent a request that would have changed a checkout')

var check_bufs = filter(getbufinfo(), (_, b) => getbufvar(b.bufnr, '&filetype') ==# 'simpleplug')
assert_equal(1, len(check_bufs), 'expected exactly one progress buffer')
assert_true(win_gotoid(win_findbuf(check_bufs[0].bufnr)[0]), 'the check window is gone')
var check_rows = filter(range(1, line('$')), (_, l) => getline(l) =~# 'check-\%(behind\|current\)')
assert_equal(2, len(check_rows), 'the check did not render both plugins')
assert_match('check-behind', getline(check_rows[0]),
  'a plugin with updates was not sorted to the top')
assert_match('behind', getline(check_rows[0]), 'the behind state was not rendered')
assert_match('2 new on main', getline(check_rows[0]), 'the check did not say what is waiting')

# u updates only the plugin under the cursor — not updating everything is why
# the check exists.
delete(check_dump)
cursor(check_rows[0], 1)
feedkeys('u', 'x')
simpleplug#Await(30)
var check_updated = filter(mapnew(readfile(check_dump), (_, l) => json_decode(l)),
  (_, r) => get(r, 'type', '') ==# 'update')
assert_equal(1, len(check_updated), 'u did not send exactly one update request')
assert_equal(['check-behind'], mapnew(check_updated[0].plugins, (_, p) => p.name),
  'u updated more than the plugin under the cursor')
simpleplug#UIClose()

# A daemon that predates the feature is told apart from a broken one, and the
# message names the fix. The handshake is asynchronous, so this also pins that
# the gate waits for it instead of refusing a daemon that has not answered yet.
$FAKE_PLUG_DROP_CAPS = 'check'
simpleplug#Stop()
messages clear
PlugCheck
assert_match('too old for :PlugCheck', execute('messages'))
assert_true(empty(filter(getbufinfo(), (_, b) => getbufvar(b.bufnr, '&filetype') ==# 'simpleplug')),
  'a refused check still opened the progress window')
$FAKE_PLUG_DROP_CAPS = ''
$FAKE_PLUG_DUMP = ''
$FAKE_PLUG_BEHIND = ''
$FAKE_PLUG_FROZEN = 'batch-frozen'
simpleplug#Stop()

# ── the progress UI's selection model ───────────────────────────────────────
var sp_script = getscriptinfo({name: 'autoload/simpleplug.vim'})[0]
var NameAtCursor = function(printf('<SNR>%d_PluginNameAtCursor', sp_script.sid))
var SpinnerTick = function(printf('<SNR>%d_SpinnerTick', sp_script.sid))

var ui_dump = home .. '/ui-requests.jsonl'
$FAKE_PLUG_DUMP = ui_dump
$FAKE_PLUG_FAIL = 'ui-plug-extra'
simpleplug#Stop()
simpleplug#Begin(home)
# A prefix pair, exactly like the author's own simpletree / simpletreesitter.
simpleplug#Plug('local/ui-plug', {as: 'ui-plug', dir: home .. '/ui-plug'})
simpleplug#Plug('local/ui-plug-extra', {as: 'ui-plug-extra', dir: home .. '/ui-plug-extra'})
simpleplug#End()
PlugInstall!
var ui_bufs = filter(getbufinfo(), (_, b) => getbufvar(b.bufnr, '&filetype') ==# 'simpleplug')
assert_equal(1, len(ui_bufs), 'expected exactly one progress buffer')
assert_true(win_gotoid(win_findbuf(ui_bufs[0].bufnr)[0]), 'the progress window is gone')

var rows = filter(range(1, line('$')), (_, l) => getline(l) =~# 'ui-plug')
assert_equal(2, len(rows), 'the progress UI did not render both plugins: ' .. string(rows))
var extra_row = getline(rows[0]) =~# 'ui-plug-extra' ? rows[0] : rows[1]
cursor(extra_row, 1)
assert_equal('ui-plug-extra', call(NameAtCursor, []),
  'a plugin name that is a prefix of another shadowed it')

# j/k are advertised in the footer and in `?`; they have to actually move.
cursor(rows[0], 1)
feedkeys('j', 'x')
assert_equal(rows[1], line('.'), 'j did not move to the next plugin row')
assert_match('▸', getline(rows[1]), 'the selection marker did not follow the cursor')
feedkeys('k', 'x')
assert_equal(rows[0], line('.'), 'k did not move back to the previous plugin row')

# A spinner tick renders; it must not drag the cursor back to the first row.
cursor(rows[1], 1)
call(SpinnerTick, [0])
assert_equal(rows[1], line('.'), 'a spinner tick dragged the cursor away')

# R retries the failed plugins, which is what the footer and :help promise.
delete(ui_dump)
feedkeys('R', 'x')
simpleplug#Await(30)
var retried = filter(mapnew(readfile(ui_dump), (_, l) => json_decode(l)),
  (_, r) => get(r, 'type', '') ==# 'install')
assert_equal(1, len(retried), 'R did not send exactly one install request')
assert_equal(['ui-plug-extra'], mapnew(retried[0].plugins, (_, p) => p.name),
  'R retried every plugin instead of only the failed ones')
$FAKE_PLUG_DUMP = ''
$FAKE_PLUG_FAIL = ''
simpleplug#UIClose()

# ── :PlugStop followed by a request must not lose it ────────────────────────
# job_stop() only sends SIGTERM, so job_status() keeps answering 'run' until
# the process is reaped. core#Ensure() handed that dying job back and the
# request went into a channel that was already closing: :PlugStop (or the
# daemon-env change every section here makes) immediately followed by
# :PlugInstall either reported "daemon is not running" or watched the daemon
# exit mid-flight. FAKE_PLUG_TERM_DELAY_MS holds that window open on purpose.
$FAKE_PLUG_TERM_DELAY_MS = '300'
simpleplug#Stop()
var race_dir = home .. '/batch-race'
PlantTemplate(race_dir, ['vim9script', 'g:simpleplug_batch_race_loaded = 1'])
simpleplug#Begin(home)
simpleplug#Plug('local/batch-race', {as: 'batch-race', dir: race_dir})
simpleplug#End()
PlugInstall!
assert_equal(1, get(simpleplug#LastResult(), 'installed', -1),
  'the daemon started with the slow-SIGTERM fixture did not install')

# ...and now the window is real: this daemon takes 300ms to die.
delete(race_dir, 'rf')
simpleplug#Stop()
PlugInstall!
result = simpleplug#LastResult()
assert_equal(0, get(result, 'errors', -1),
  'a request sent right after :PlugStop was lost: ' .. string(result))
assert_equal(1, get(result, 'installed', -1),
  'a request sent right after :PlugStop was lost: ' .. string(result))
$FAKE_PLUG_TERM_DELAY_MS = ''

# ── a silent daemon must not wedge Vim forever ──────────────────────────────
simpleplug#Stop()
$FAKE_PLUG_SILENT = '1'
g:simpleplug_sync_timeout = 1
simpleplug#Begin(home)
simpleplug#Plug('local/batch-silent', {as: 'batch-silent', dir: home .. '/batch-silent'})
simpleplug#End()
var waited = reltime()
PlugInstall!
var waited_s = reltimefloat(reltime(waited))
assert_true(waited_s >= 1.0, 'the synchronous bang did not wait at all')
assert_true(waited_s < 30.0, printf('the synchronous bang ignored its timeout (%.1fs)', waited_s))
assert_match('stopped waiting after 1s', execute('messages'))
simpleplug#Stop()

delete(home, 'rf')

g:simpleplug_batch_done = 1
if !empty(v:errors)
  for error in v:errors
    echom error
  endfor
  cquit 1
endif
qa!
