vim9script

set nomore
g:simpleplug_auto_install = 0

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
execute 'source ' .. fnameescape(root .. '/plugin/simpleplug.vim')
assert_equal(2, exists(':PlugSnapshotDiff'))
assert_equal(5.0, g:simpleplug_profile_threshold_ms,
  'the default integer profile threshold was not normalised to Float')

var fixture = root .. '/tests/fixtures/lazy-plugin'
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('local/lazy-plugin', {
  as: 'lazy-fixture',
  dir: fixture,
  for: 'rust',
})
simpleplug#End()

assert_false(exists('g:simpleplug_lazy_fixture_loaded'), 'lazy plugin loaded eagerly')
assert_true(get(g:, 'simpleplug_lazy_fixture_ftdetect', 0) >= 1, 'lazy plugin ftdetect was not sourced eagerly')
doautocmd FileType rust
assert_equal(1, get(g:, 'simpleplug_lazy_fixture_loaded', 0), 'lazy plugin did not load')
assert_true(index(split(&runtimepath, ','), fixture) >= 0, 'lazy plugin missing from runtimepath')

# Command-based lazy loading must source the plugin, then replay the command.
# Each section registers the shared fixture under its own name: a runtime that
# has already been sourced is treated as loaded for the rest of the session,
# so re-registering the *same* plugin deliberately arms no new trigger.
delcommand LazyFixtureCommand
unlet g:simpleplug_lazy_fixture_loaded
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('local/lazy-plugin', {
  as: 'lazy-fixture-cmd',
  dir: fixture,
  on: 'LazyFixtureCommand',
})
simpleplug#End()
assert_false(exists('g:simpleplug_lazy_fixture_loaded'), 'command-lazy plugin loaded eagerly')
LazyFixtureCommand hello
assert_equal(1, get(g:, 'simpleplug_lazy_fixture_loaded', 0), 'command-lazy plugin did not load')
assert_equal('hello', get(g:, 'simpleplug_lazy_fixture_args', ''), 'lazy command arguments were not replayed')

# <Plug> mappings listed in `on` must lazy-load the plugin, then replay the keys.
unlet g:simpleplug_lazy_fixture_loaded
nunmap <Plug>(LazyFixture)
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('local/lazy-plugin', {
  as: 'lazy-fixture-map',
  dir: fixture,
  on: '<Plug>(LazyFixture)',
})
simpleplug#End()
assert_false(exists('g:simpleplug_lazy_fixture_loaded'), 'map-lazy plugin loaded eagerly')
feedkeys("\<Plug>(LazyFixture)", 'x')
assert_equal(1, get(g:, 'simpleplug_lazy_fixture_loaded', 0), 'map-lazy plugin did not load')
assert_equal(1, get(g:, 'simpleplug_lazy_fixture_mapped', 0), 'lazy mapping was not replayed')

# Registering tag/commit pins must be accepted and round-trip through specs.
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('owner/pinned-tag', {tag: 'v1.0'})
simpleplug#Plug('owner/pinned-commit', {commit: 'abc1234'})
simpleplug#End()

# A monorepo may expose its Vim runtime below the checkout root.  Pre-inserting
# the main runtime without after/ exercises End()'s independent after handling;
# :runtime below emulates Vim's normal eager startup scan (this script itself
# runs before VimEnter).
var rtp_fixture = root .. '/tests/fixtures/rtp-plugin'
var rtp_runtime = rtp_fixture .. '/vim'
var rtp_after = rtp_runtime .. '/after'
&runtimepath = join(filter(split(&runtimepath, ','), (_, entry) =>
  entry !=# rtp_runtime && entry !=# rtp_after && entry !=# rtp_fixture), ',')
&runtimepath = rtp_runtime .. ',' .. &runtimepath
unlet! g:simpleplug_rtp_fixture_loaded
unlet! g:simpleplug_rtp_fixture_after
unlet! g:simpleplug_rtp_checkout_root_loaded
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('local/rtp-plugin', {
  as: 'rtp-fixture',
  dir: rtp_fixture,
  rtp: 'vim',
})
simpleplug#End()
assert_true(index(split(&runtimepath, ','), rtp_runtime) >= 0,
  'eager rtp subdirectory missing from runtimepath')
assert_true(index(split(&runtimepath, ','), rtp_after) >= 0,
  'after directory was not added when the main runtime was already present')
assert_true(index(split(&runtimepath, ','), rtp_fixture) < 0,
  'checkout root leaked into runtimepath')
runtime! plugin/simpleplug_rtp_fixture.vim
runtime! plugin/simpleplug_rtp_after.vim
runtime! plugin/simpleplug_rtp_root_trap.vim
assert_equal(1, get(g:, 'simpleplug_rtp_fixture_loaded', 0),
  'eager startup scan did not find the nested plugin script')
assert_equal(1, get(g:, 'simpleplug_rtp_fixture_after', 0),
  'eager startup scan did not find the nested after script')
assert_false(exists('g:simpleplug_rtp_checkout_root_loaded'),
  'checkout-root plugin script became visible')

# Command lazy loading uses the nested runtime, restores after/, and replays
# the command after the real definition replaces its stub.
silent! delcommand RtpFixtureCommand
unlet! g:simpleplug_rtp_fixture_loaded
unlet! g:simpleplug_rtp_fixture_after
unlet! g:simpleplug_rtp_fixture_triggered
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('local/rtp-plugin', {
  as: 'rtp-fixture',
  dir: rtp_fixture,
  rtp: 'vim',
  on: 'RtpFixtureCommand',
})
simpleplug#End()
assert_false(exists('g:simpleplug_rtp_fixture_loaded'), 'rtp command plugin loaded eagerly')
RtpFixtureCommand
assert_equal(1, get(g:, 'simpleplug_rtp_fixture_loaded', 0), 'rtp plugin script did not load')
assert_equal(1, get(g:, 'simpleplug_rtp_fixture_triggered', 0), 'rtp lazy command was not replayed')
assert_equal(1, get(g:, 'simpleplug_rtp_fixture_after', 0), 'rtp after script did not load')
assert_true(index(split(&runtimepath, ','), rtp_runtime) >= 0,
  'rtp subdirectory missing from runtimepath')
assert_true(index(split(&runtimepath, ','), rtp_fixture) < 0,
  'checkout root leaked into runtimepath')
assert_equal(['rtp-fixture'], simpleplug#CompletePluginNames('rtp-', '', 0))

# `for` keeps ftdetect eager, then loads plugin/ and after/ when that detector
# emits FileType.  Help tags under the nested doc/ remain discoverable too.
unlet! g:simpleplug_rtp_fixture_loaded
unlet! g:simpleplug_rtp_fixture_after
unlet! g:simpleplug_rtp_fixture_ftdetect
set filetype=
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('local/rtp-plugin', {
  as: 'rtp-fixture-for',
  dir: rtp_fixture,
  rtp: 'vim',
  for: 'rtpfixture',
})
simpleplug#End()
assert_true(get(g:, 'simpleplug_rtp_fixture_ftdetect', 0) >= 1,
  'nested ftdetect script was not sourced eagerly')
assert_false(exists('g:simpleplug_rtp_fixture_loaded'), 'for plugin loaded eagerly')
assert_true(index(split(&runtimepath, ','), rtp_runtime) < 0,
  'for plugin runtime was not removed before its trigger')
doautocmd BufRead example.rtpfixture
assert_equal('rtpfixture', &filetype, 'nested ftdetect did not recognize its file')
assert_equal(1, get(g:, 'simpleplug_rtp_fixture_loaded', 0), 'for plugin did not load')
assert_equal(1, get(g:, 'simpleplug_rtp_fixture_after', 0), 'for plugin after script did not load')
assert_true(index(getcompletion('rtp-fixture-test', 'help'), 'rtp-fixture-test') >= 0,
  'nested doc tag was not discoverable')

# A runtime removed between End() and its first command must leave the stub and
# loaded state retryable.  Recreating the directory makes the same command work.
var retry_checkout = tempname()
var retry_runtime = retry_checkout .. '/vim'
mkdir(retry_runtime .. '/plugin', 'p')
writefile([
  'vim9script',
  "g:simpleplug_retry_fixture_loaded = get(g:, 'simpleplug_retry_fixture_loaded', 0) + 1",
  "command! -nargs=* RetryRtpCommand g:simpleplug_retry_fixture_args = '<args>'",
  "nnoremap <Plug>(RetryRtpMap) <Cmd>g:simpleplug_retry_fixture_mapped = get(g:, 'simpleplug_retry_fixture_mapped', 0) + 1<CR>",
], retry_runtime .. '/plugin/retry_rtp.vim')
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('local/retry-rtp', {
  as: 'retry-rtp',
  dir: retry_checkout,
  rtp: 'vim',
  on: ['RetryRtpCommand', '<Plug>(RetryRtpMap)'],
})
simpleplug#End()
delete(retry_runtime, 'rf')
RetryRtpCommand first
assert_false(exists('g:simpleplug_retry_fixture_loaded'),
  'missing runtime was marked loaded')
assert_equal(2, exists(':RetryRtpCommand'), 'missing runtime destroyed its command stub')
assert_match('retry-rtp runtime directory is missing:', execute('messages'))
feedkeys("\<Plug>(RetryRtpMap)", 'x')
assert_match('simpleplug#LazyLoadMap', maparg('<Plug>(RetryRtpMap)', 'n'),
  'missing runtime destroyed its mapping stub')
mkdir(retry_runtime .. '/plugin', 'p')
writefile([
  'vim9script',
  "g:simpleplug_retry_fixture_loaded = get(g:, 'simpleplug_retry_fixture_loaded', 0) + 1",
  "command! -nargs=* RetryRtpCommand g:simpleplug_retry_fixture_args = '<args>'",
  "nnoremap <Plug>(RetryRtpMap) <Cmd>g:simpleplug_retry_fixture_mapped = get(g:, 'simpleplug_retry_fixture_mapped', 0) + 1<CR>",
], retry_runtime .. '/plugin/retry_rtp.vim')
feedkeys("\<Plug>(RetryRtpMap)", 'x')
assert_equal(1, get(g:, 'simpleplug_retry_fixture_mapped', 0),
  'restored runtime mapping was not retried and replayed')
RetryRtpCommand recovered
assert_equal(1, get(g:, 'simpleplug_retry_fixture_loaded', 0),
  'restored runtime was not retried')
assert_equal('recovered', get(g:, 'simpleplug_retry_fixture_args', ''),
  'retried command was not replayed')

# Re-sourcing a vimrc must not disarm a lazy plugin that has already loaded.
# Its plugin script carries the usual reload guard, so anything torn down here
# can never be rebuilt: sourcing the script again finishes immediately.
var guard_checkout = tempname()
mkdir(guard_checkout .. '/plugin', 'p')
writefile([
  'vim9script',
  "if exists('g:simpleplug_guard_fixture_loaded')",
  '  finish',
  'endif',
  'g:simpleplug_guard_fixture_loaded = 1',
  "command! -nargs=* GuardFixtureCommand g:simpleplug_guard_fixture_args = '<args>'",
  'nnoremap <Plug>(GuardFixtureMap) <Cmd>g:simpleplug_guard_fixture_mapped = 1<CR>',
], guard_checkout .. '/plugin/guard.vim')
var guard_opts = {
  as: 'guard-fixture',
  dir: guard_checkout,
  on: ['GuardFixtureCommand', '<Plug>(GuardFixtureMap)'],
}
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('local/guard-plugin', guard_opts)
simpleplug#End()
assert_false(exists('g:simpleplug_guard_fixture_loaded'), 'guarded plugin loaded eagerly')
GuardFixtureCommand first
assert_equal(1, get(g:, 'simpleplug_guard_fixture_loaded', 0), 'guarded plugin did not load')
assert_equal('first', get(g:, 'simpleplug_guard_fixture_args', ''),
  'guarded lazy command was not replayed')

simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('local/guard-plugin', guard_opts)
simpleplug#End()
assert_equal(2, exists(':GuardFixtureCommand'), 'reinitializing deleted the real command')
assert_notmatch('simpleplug#LazyLoadMap', maparg('<Plug>(GuardFixtureMap)', 'n'),
  'reinitializing shadowed the real mapping with a stub')
assert_true(index(split(&runtimepath, ','), guard_checkout) >= 0,
  'reinitializing dropped a loaded plugin from runtimepath')
GuardFixtureCommand second
assert_equal('second', get(g:, 'simpleplug_guard_fixture_args', ''),
  'the real command did not survive reinitialization')
assert_equal(1, get(g:, 'simpleplug_guard_fixture_loaded', 0),
  'the guarded plugin was sourced a second time')
delcommand GuardFixtureCommand
nunmap <Plug>(GuardFixtureMap)
&runtimepath = join(filter(split(&runtimepath, ','), (_, entry) =>
  entry !=# guard_checkout && entry !=# guard_checkout .. '/after'), ',')
delete(guard_checkout, 'rf')

# The same re-source, for a plugin declared with BOTH `for` and `on`.  The
# FileType half hides: every check above still passes immediately after End(),
# and the damage lands on the first matching FileType event — which re-runs
# LazyLoad over an already-loaded plugin and deletes the real command and
# mapping it installed.
var ftguard_checkout = tempname()
mkdir(ftguard_checkout .. '/plugin', 'p')
writefile([
  'vim9script',
  "if exists('g:simpleplug_ftguard_fixture_loaded')",
  '  finish',
  'endif',
  'g:simpleplug_ftguard_fixture_loaded = 1',
  "command! -nargs=* FtGuardFixtureCommand g:simpleplug_ftguard_fixture_args = '<args>'",
  'nnoremap <Plug>(FtGuardFixtureMap) <Cmd>g:simpleplug_ftguard_fixture_mapped = 1<CR>',
], ftguard_checkout .. '/plugin/ftguard.vim')
var ftguard_opts = {
  as: 'ftguard-fixture',
  dir: ftguard_checkout,
  for: 'simpleplugftguard',
  on: ['FtGuardFixtureCommand', '<Plug>(FtGuardFixtureMap)'],
}
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('local/ftguard-plugin', ftguard_opts)
simpleplug#End()
assert_false(exists('g:simpleplug_ftguard_fixture_loaded'), 'for+on plugin loaded eagerly')
FtGuardFixtureCommand first
assert_equal(1, get(g:, 'simpleplug_ftguard_fixture_loaded', 0), 'for+on plugin did not load')

simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('local/ftguard-plugin', ftguard_opts)
simpleplug#End()
doautocmd FileType simpleplugftguard
assert_equal(2, exists(':FtGuardFixtureCommand'),
  'a FileType event after reinitializing deleted the real command')
assert_notmatch('simpleplug#LazyLoadMap', maparg('<Plug>(FtGuardFixtureMap)', 'n'),
  'a FileType event after reinitializing replaced the real mapping with a stub')
assert_true(index(split(&runtimepath, ','), ftguard_checkout) >= 0,
  'a FileType event after reinitializing dropped the plugin from runtimepath')
if exists(':FtGuardFixtureCommand') == 2
  FtGuardFixtureCommand second
endif
assert_equal('second', get(g:, 'simpleplug_ftguard_fixture_args', ''),
  'the real command did not survive a post-reinitialization FileType event')
assert_equal(1, get(g:, 'simpleplug_ftguard_fixture_loaded', 0),
  'the for+on plugin was sourced a second time')
silent! delcommand FtGuardFixtureCommand
silent! nunmap <Plug>(FtGuardFixtureMap)
&runtimepath = join(filter(split(&runtimepath, ','), (_, entry) =>
  entry !=# ftguard_checkout && entry !=# ftguard_checkout .. '/after'), ',')
delete(ftguard_checkout, 'rf')

# Lexical option separators/traversal are rejected before registration.
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
silent simpleplug#Plug('local/unsafe-rtp', {rtp: '../outside'})
silent simpleplug#Plug('local/comma-rtp', {rtp: 'vim,/tmp'})
assert_equal([], simpleplug#CompletePluginNames('unsafe-', '', 0))
assert_equal([], simpleplug#CompletePluginNames('comma-', '', 0))

# Scalar declarations cross a strongly typed JSON boundary.  Reject a bad
# plugin locally instead of sending one malformed field that makes the daemon
# reject the complete install/update batch (including every valid sibling).
var option_noise = execute("silent call simpleplug#Plug('local/bad-alias', {as: 7})")
option_noise ..= execute("silent call simpleplug#Plug('local/bad-dir', {dir: []})")
option_noise ..= execute("silent call simpleplug#Plug('local/bad-branch', {branch: ['main']})")
option_noise ..= execute("silent call simpleplug#Plug('local/bad-tag', {tag: '--help'})")
option_noise ..= execute("silent call simpleplug#Plug('local/bad-commit', {commit: " .. string("abc\ndef") .. "})")
option_noise ..= execute("silent call simpleplug#Plug('local/bad-hook', {do: {}})")
option_noise ..= execute("silent call simpleplug#Plug('local/bad-frozen', {frozen: 'yes'})")
option_noise ..= execute("silent call simpleplug#Plug('local/bad-dir-comma', {dir: '/tmp/a,b'})")
for bad in ['bad-alias', 'bad-dir', 'bad-branch', 'bad-tag', 'bad-commit',
    'bad-hook', 'bad-frozen', 'bad-dir-comma']
  assert_equal([], simpleplug#CompletePluginNames(bad, '', 0),
    bad .. ' was registered despite an invalid scalar option')
endfor
assert_match('`as` must be a string', option_noise)
assert_match('`branch` must be a string', option_noise)
assert_match('`tag` must be a single Git reference', option_noise)
assert_match('`frozen` must be a number or boolean', option_noise)
assert_match('`dir` must not contain a comma', option_noise)

# Containment is rechecked after registration: replacing a valid runtime with
# a symlink cannot make End() source a directory outside the checkout.
if executable('ln')
  var escape_base = tempname()
  var escape_checkout = escape_base .. '/checkout'
  var escape_runtime = escape_checkout .. '/vim'
  var outside_runtime = escape_base .. '/outside-vim'
  mkdir(escape_runtime, 'p')
  mkdir(outside_runtime .. '/plugin', 'p')
  writefile(['vim9script', 'g:simpleplug_escape_fixture_loaded = true'],
    outside_runtime .. '/plugin/escape.vim')
  simpleplug#Begin('/tmp/simpleplug-vim-smoke')
  simpleplug#Plug('local/escape-rtp', {
    as: 'escape-rtp',
    dir: escape_checkout,
    rtp: 'vim',
  })
  delete(escape_runtime, 'rf')
  call system('ln -s ' .. shellescape(outside_runtime) .. ' ' .. shellescape(escape_runtime))
  assert_equal(0, v:shell_error, 'could not create containment-test symlink')
  simpleplug#End()
  assert_false(exists('g:simpleplug_escape_fixture_loaded'),
    'escaping symlink runtime was sourced')
  assert_true(index(split(&runtimepath, ','), escape_runtime) < 0,
    'escaping symlink runtime entered runtimepath')
  assert_match('escape-rtp runtime directory escapes plugin directory:', execute('messages'))
  delete(escape_base, 'rf')
endif

# Snapshots retain the legacy name -> full OID JSON shape, but are written from
# a private same-filesystem staging directory beside the target.
var snapshot_home = tempname()
var snapshot_path = snapshot_home .. '/locks/plugins.json'
mkdir(snapshot_home, 'p')
mkdir(fnamemodify(snapshot_path, ':h'), 'p')
mkdir(snapshot_home .. '/plain-directory', 'p')
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('local/snapshot-fixture', {
  as: 'snapshot-fixture',
  dir: root,
})
simpleplug#Plug('local/missing-fixture', {
  as: 'missing-fixture',
  dir: snapshot_home .. '/not-a-checkout',
})
simpleplug#Plug('local/plain-fixture', {
  as: 'plain-fixture',
  dir: snapshot_home .. '/plain-directory',
})

# mkdir() raises E739 for an occupied candidate. Pre-claim the very first name
# as a directory: Snapshot must leave it untouched, retry the nonce and finish.
var simpleplug_script = getscriptinfo({name: 'autoload/simpleplug.vim'})[0]
var simpleplug_details = getscriptinfo({sid: simpleplug_script.sid})[0]
var snapshot_nonce: number = get(simpleplug_details.variables, 's_snapshot_nonce', -1)
assert_equal(0, snapshot_nonce, 'snapshot staging nonce advanced before its first use')
var occupied_stage = printf('%s/.%s.stage.%d.1', fnamemodify(snapshot_path, ':h'),
  fnamemodify(snapshot_path, ':t'), getpid())
mkdir(occupied_stage, '', 0o700)
simpleplug#Snapshot(snapshot_path)
var snapshot_json = json_decode(join(readfile(snapshot_path), "\n"))
assert_equal(v:t_dict, type(snapshot_json), 'snapshot root is not a JSON object')
assert_equal(1, get(snapshot_json, 'version', 0), 'a new snapshot is not the versioned shape')
var snapshot_entry = get(get(snapshot_json, 'plugins', {}), 'snapshot-fixture', {})
assert_match('^\x\{40}\%([0-9a-f]\{24}\)\?$', get(snapshot_entry, 'commit', ''),
  'snapshot did not contain a full Git OID')
assert_equal('https://github.com/local/snapshot-fixture.git', get(snapshot_entry, 'url', ''),
  'snapshot did not record where the commit came from')
assert_equal([], readdir(occupied_stage), 'snapshot used an attacker-occupied staging directory')
delete(occupied_stage, 'd')
assert_equal([], globpath(fnamemodify(snapshot_path, ':h'), '.*.stage.*', 0, 1),
  'atomic snapshot left a staging directory behind')

# SnapshotDiff is read-only and deterministic. A generated snapshot matches
# the installed checkout while the registered non-checkout is explicitly
# reported as unlocked rather than silently folded into another category.
var clean_diff = execute('PlugSnapshotDiff ' .. fnameescape(snapshot_path))
assert_match('format=v1 matched=1 drifted=0 respecced=0 missing=0 non-git=0 unreadable=0 unlocked=2 orphaned=0', clean_diff)
assert_match('\[matched\] snapshot-fixture current=', clean_diff)
assert_match('\[unlocked\] missing-fixture (missing)', clean_diff)
assert_match('\[unlocked\] plain-fixture (not-git)', clean_diff)
var current_oid: string = snapshot_entry.commit
var drift_oid = (current_oid[0] ==# '0' ? '1' : '0') .. strpart(current_oid, 1)
var diff_snapshot = snapshot_home .. '/locks/diff.json'
writefile([json_encode({
  'z-orphan': repeat('a', 40),
  'snapshot-fixture': drift_oid,
  'missing-fixture': repeat('b', 40),
  'plain-fixture': repeat('c', 40),
})], diff_snapshot)
var diff_before = readfile(diff_snapshot)
var starts_before_diff = simpleplug#core#Health().starts
var drift_output = execute('PlugSnapshotDiff ' .. fnameescape(diff_snapshot))
assert_match('format=legacy matched=0 drifted=1 respecced=0 missing=1 non-git=1 unreadable=0 unlocked=0 orphaned=1', drift_output)
var missing_pos = match(drift_output, '\[missing\] missing-fixture')
var plain_pos = match(drift_output, '\[not-git\] plain-fixture')
var changed_pos = match(drift_output, '\[drifted\] snapshot-fixture')
var orphan_pos = match(drift_output, '\[orphaned\] z-orphan')
assert_true(missing_pos >= 0 && missing_pos < plain_pos && plain_pos < changed_pos
    && changed_pos < orphan_pos,
  'snapshot diff details were not sorted by plugin name: ' .. drift_output)
assert_equal(diff_before, readfile(diff_snapshot), 'snapshot diff modified its input file')
assert_equal(starts_before_diff, simpleplug#core#Health().starts,
  'snapshot diff started the daemon')

# A candidate symlink is another collision, never a directory to enter. Derive
# the next nonce from script state so this remains stable if retries are added.
if executable('ln')
  simpleplug_details = getscriptinfo({sid: simpleplug_script.sid})[0]
  snapshot_nonce = get(simpleplug_details.variables, 's_snapshot_nonce', -1)
  var linked_stage = printf('%s/.%s.stage.%d.%d', fnamemodify(snapshot_path, ':h'),
    fnamemodify(snapshot_path, ':t'), getpid(), snapshot_nonce + 1)
  var linked_stage_target = snapshot_home .. '/stage-symlink-target'
  mkdir(linked_stage_target, 'p')
  call system('ln -s ' .. shellescape(linked_stage_target) .. ' ' .. shellescape(linked_stage))
  assert_equal(0, v:shell_error, 'could not preplant staging symlink')
  simpleplug#Snapshot(snapshot_path)
  assert_equal([], readdir(linked_stage_target), 'snapshot followed a planted staging symlink')
  assert_equal('link', getftype(linked_stage), 'snapshot replaced a planted staging symlink')
  delete(linked_stage)
  assert_equal([], globpath(fnamemodify(snapshot_path, ':h'), '.*.stage.*', 0, 1),
    'symlink collision left a plugin-created staging directory')
endif

# The atomically claimed boundary itself is owner-only on Unix.
if has('unix')
  var CreateStage = function(printf('<SNR>%d_CreateSnapshotStageDir', simpleplug_script.sid))
  var permission_stage: string = call(CreateStage, [snapshot_path])
  assert_equal('rwx------', getfperm(permission_stage), 'snapshot staging directory is not 0700')
  delete(permission_stage, 'd')
endif

# Restore validates the entire legacy object before it starts the daemon. A
# malformed root/value is rejected, while a 64-digit SHA-256 OID remains valid.
var invalid_snapshot = snapshot_home .. '/invalid.json'
var backend_starts_before_invalid_restore = simpleplug#core#Health().starts
writefile(['[]'], invalid_snapshot)
var invalid_diff = execute('PlugSnapshotDiff ' .. fnameescape(invalid_snapshot))
assert_match('snapshot root must be a JSON object', invalid_diff)
assert_notmatch('snapshot diff:', invalid_diff,
  'invalid snapshot produced a partial diff report')
var missing_diff = execute('PlugSnapshotDiff ' .. fnameescape(snapshot_home .. '/absent.json'))
assert_match('snapshot not found:', missing_diff)
assert_notmatch('snapshot diff:', missing_diff,
  'missing snapshot produced a partial diff report')
assert_equal(backend_starts_before_invalid_restore, simpleplug#core#Health().starts,
  'invalid or unreadable snapshot diff started the daemon')
simpleplug#Restore(invalid_snapshot)
assert_match('snapshot root must be a JSON object', execute('messages'))
assert_equal(backend_starts_before_invalid_restore, simpleplug#core#Health().starts,
  'malformed snapshot started the daemon')
writefile([json_encode({snapshot_fixture: 123})], invalid_snapshot)
simpleplug#Restore(invalid_snapshot)
assert_match('must map to a full 40- or 64-digit hexadecimal Git OID', execute('messages'))
assert_equal(backend_starts_before_invalid_restore, simpleplug#core#Health().starts,
  'wrong snapshot entry type started the daemon')
writefile([json_encode({'not-registered': repeat('a', 64)})], invalid_snapshot)
simpleplug#Restore(invalid_snapshot)
assert_match('snapshot matches no registered plugins', execute('messages'),
  'a valid 64-digit OID was rejected')
assert_equal(backend_starts_before_invalid_restore, simpleplug#core#Health().starts,
  'unmatched snapshot started the daemon')

# Force rename() itself to fail by making the destination a non-empty
# directory. The pre-existing target stays intact and finally removes staging.
var rename_failure_target = snapshot_home .. '/rename-failure-target'
mkdir(rename_failure_target, 'p')
writefile(['old-target'], rename_failure_target .. '/old.json')
simpleplug#Snapshot(rename_failure_target)
assert_equal(['old-target'], readfile(rename_failure_target .. '/old.json'),
  'failed atomic rename damaged the old target')
assert_equal([], globpath(snapshot_home, '.*.stage.*', 0, 1),
  'failed atomic rename leaked a staging directory')
assert_match('atomic rename failed', execute('messages'))

# A lockfile path that is itself a symlink is never followed. The pointed-to
# file must retain its old content and no staging directory may leak.
if executable('ln')
  var snapshot_target = snapshot_home .. '/outside.json'
  var snapshot_link = snapshot_home .. '/snapshot-link.json'
  writefile(['keep-me'], snapshot_target)
  call system('ln -s ' .. shellescape(snapshot_target) .. ' ' .. shellescape(snapshot_link))
  assert_equal(0, v:shell_error, 'could not create snapshot symlink')
  simpleplug#Snapshot(snapshot_link)
  assert_equal(['keep-me'], readfile(snapshot_target), 'snapshot followed and overwrote a symlink')
  assert_match('refusing to replace snapshot symlink:', execute('messages'))
  assert_equal([], globpath(snapshot_home, '.*.stage.*', 0, 1),
    'symlink target refusal leaked a staging directory')
endif

&runtimepath = join(filter(split(&runtimepath, ','), (_, entry) =>
  entry !=# retry_runtime && entry !=# retry_runtime .. '/after'), ',')
delete(retry_checkout, 'rf')
delete(snapshot_home, 'rf')

# The lockfile is meant to be committed to a dotfiles repo and reviewed, so it
# is emitted by hand rather than by json_encode: Vim's dictionary order is an
# implementation detail, and a one-line file whose keys reshuffle on every
# regeneration produces a diff nobody can read.
var lock_home = tempname()
mkdir(lock_home, 'p')
var lock_path = lock_home .. '/lock.json'
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
for alias in ['zeta', 'alpha', 'mike']
  simpleplug#Plug('local/lock-fixture', {as: alias, dir: root})
endfor
simpleplug#End()
simpleplug#Snapshot(lock_path)
var lock_lines = readfile(lock_path)
var lock_names = mapnew(filter(copy(lock_lines), (_, l) => l =~# '"commit"'),
  (_, l) => matchstr(l, '"\zs[^"]\+\ze": {'))
assert_equal(['alpha', 'mike', 'zeta'], lock_names,
  'lockfile entries are not sorted one per line: ' .. string(lock_lines))
simpleplug#Snapshot(lock_path)
assert_equal(lock_lines, readfile(lock_path), 'regenerating the lockfile changed it')
var lock_json = json_decode(join(lock_lines, "\n"))
assert_equal('https://github.com/local/lock-fixture.git',
  get(get(get(lock_json, 'plugins', {}), 'alpha', {}), 'url', ''),
  'the versioned lockfile did not record the source repository')

# The same commit under a different declaration is not a match: a report that
# only compares commits calls it matched while the spec has moved underneath.
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('other/lock-fixture', {as: 'alpha', dir: root})
simpleplug#End()
var respec_output = execute('PlugSnapshotDiff ' .. fnameescape(lock_path))
assert_match('respecced=1', respec_output)
assert_match('\[respecced\] alpha current=\x\+ (url .* -> https://github.com/other/lock-fixture.git)',
  respec_output)

# An existing lockfile keeps the shape it already has. Regenerating a file that
# is under version control must not rewrite it into another format.
var legacy_path = lock_home .. '/legacy.json'
writefile([json_encode({alpha: repeat('a', 40)})], legacy_path)
simpleplug#Snapshot(legacy_path)
var legacy_json = json_decode(join(readfile(legacy_path), "\n"))
assert_false(has_key(legacy_json, 'version'), 'an existing legacy lockfile was upgraded in place')
assert_match('^\x\{40}$', get(legacy_json, 'alpha', ''),
  'the legacy shape lost its name -> OID mapping')

# A new lockfile follows g:simpleplug_snapshot_format for people who have to
# keep feeding the old shape to something else.
g:simpleplug_snapshot_format = 'legacy'
var forced_legacy = lock_home .. '/forced.json'
simpleplug#Snapshot(forced_legacy)
assert_false(has_key(json_decode(join(readfile(forced_legacy), "\n")), 'version'),
  'g:simpleplug_snapshot_format = legacy still wrote the versioned shape')
g:simpleplug_snapshot_format = 'v1'

# Both shapes cross the same OID gate before anything reaches the daemon.
var starts_before_v1_restore = simpleplug#core#Health().starts
writefile(['{"version": 1, "plugins": {"alpha": {"commit": "abc1234"}}}'], legacy_path)
simpleplug#Restore(legacy_path)
assert_match('alpha.commit must be a full 40- or 64-digit hexadecimal Git OID', execute('messages'))
writefile(['{"version": 2, "plugins": {}}'], legacy_path)
simpleplug#Restore(legacy_path)
assert_match('unsupported snapshot version: 2', execute('messages'))
assert_equal(starts_before_v1_restore, simpleplug#core#Health().starts,
  'an invalid versioned snapshot started the daemon')
delete(lock_home, 'rf')

# A `.git` directory is not proof of an installed plugin. A clone interrupted
# mid-transfer leaves the destination and its .git behind but never writes the
# index, and auto-install has to keep seeing it as missing rather than skipping
# it for the rest of time.
var checkout_home = tempname()
mkdir(checkout_home .. '/interrupted/.git/refs/heads', 'p')
writefile(['ref: refs/heads/main'], checkout_home .. '/interrupted/.git/HEAD')
mkdir(checkout_home .. '/finished/.git', 'p')
writefile([''], checkout_home .. '/finished/.git/index')
simpleplug#Begin(checkout_home)
simpleplug#Plug('local/finished', {as: 'finished', dir: checkout_home .. '/finished'})
simpleplug#End()
var MissingCount = function(printf('<SNR>%d_MissingPluginCount', simpleplug_script.sid))
assert_equal(0, call(MissingCount, []), 'a finished checkout was counted as missing')
simpleplug#Plug('local/interrupted', {as: 'interrupted', dir: checkout_home .. '/interrupted'})
assert_equal(1, call(MissingCount, []), 'an interrupted clone was counted as installed')
simpleplug#Plug('local/absent', {as: 'absent', dir: checkout_home .. '/absent'})
assert_equal(2, call(MissingCount, []), 'an absent checkout was counted as installed')
delete(checkout_home, 'rf')

# :PlugProfile attributes startup cost to the plugin that spent it. Loading is
# the one thing SimplePlug is always in the middle of, so SourcePluginScripts
# and the eager ftdetect sourcing are where the numbers come from.
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('local/lazy-plugin', {
  as: 'profile-fixture',
  dir: fixture,
  on: 'ProfileFixtureCommand',
})
simpleplug#End()
silent! call simpleplug#LazyLoad('profile-fixture', ':ProfileFixtureCommand')
PlugProfile
var profile_lines = getline(1, '$')
assert_match('SimplePlug profile', profile_lines[0])
assert_match('wall ms', profile_lines[2], 'the profile did not label its unit as wall clock')
var profile_rows = filter(copy(profile_lines), (_, l) => l =~# 'profile-fixture')
# Two rows, not one: the triggered load and the ftdetect the plugin already
# paid for at startup. Loading the body must not relabel that cost as lazy.
assert_equal(2, len(profile_rows), 'the profile did not attribute the load: ' .. string(profile_lines))
var profile_row = filter(copy(profile_rows), (_, l) => l =~# '\<lazy\>')
assert_equal(1, len(profile_row), 'a lazily loaded plugin was not labelled lazy: ' .. string(profile_rows))
assert_match(':ProfileFixtureCommand', profile_row[0], 'the profile did not record the trigger')
assert_match('^\s\+\d\+\.\d', profile_row[0], 'the profile row carries no measurement')
assert_equal(1, len(filter(copy(profile_rows), (_, l) => l =~# '\<ftdetect\>')),
  'the eager ftdetect cost stopped being reported on its own: ' .. string(profile_rows))
assert_match('q close', profile_lines[-1])
bwipeout!

# Reinitializing must clear generated lazy-load state without errors.
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('owner/one')
simpleplug#End()

if !empty(v:errors)
  for error in v:errors
    echom error
  endfor
  cquit 1
endif
qa!
