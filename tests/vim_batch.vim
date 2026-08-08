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
set filetype=
doautocmd BufRead example.batchfixture
assert_equal('batchfixture', &filetype, 'activated plugin ftdetect did not run')

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
