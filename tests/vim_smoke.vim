vim9script

set nomore
g:simpleplug_auto_install = 0

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
execute 'source ' .. fnameescape(root .. '/plugin/simpleplug.vim')

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
delcommand LazyFixtureCommand
unlet g:simpleplug_lazy_fixture_loaded
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('local/lazy-plugin', {
  as: 'lazy-fixture',
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
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
simpleplug#Plug('local/lazy-plugin', {
  as: 'lazy-fixture',
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

# Lexical option separators/traversal are rejected before registration.
simpleplug#Begin('/tmp/simpleplug-vim-smoke')
silent simpleplug#Plug('local/unsafe-rtp', {rtp: '../outside'})
silent simpleplug#Plug('local/comma-rtp', {rtp: 'vim,/tmp'})
assert_equal([], simpleplug#CompletePluginNames('unsafe-', '', 0))
assert_equal([], simpleplug#CompletePluginNames('comma-', '', 0))

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

&runtimepath = join(filter(split(&runtimepath, ','), (_, entry) =>
  entry !=# retry_runtime && entry !=# retry_runtime .. '/after'), ',')
delete(retry_checkout, 'rf')

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
