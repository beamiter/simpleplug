vim9script

# Lazy loading beyond `for` and `on`: autocommand events, mode-aware key
# triggers, and declared dependencies.
#
# Nothing here starts the daemon.  Every fixture is a local directory declared
# with {dir: ...}, so what is under test is only the registry, the trigger
# machinery and 'runtimepath'.
#
# This script runs before VimEnter, so v:vim_did_enter is 0 and End() does not
# source an eager plugin itself — Vim's own startup scan would.  Where a test
# is about eager loading it therefore asserts on 'runtimepath', which is the
# thing that scan reads, and in the order it reads it.

set nomore
g:simpleplug_auto_install = 0

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
execute 'source ' .. fnameescape(root .. '/plugin/simpleplug.vim')

var plugdir = '/tmp/simpleplug-vim-lazy'
var event_fixture = root .. '/tests/fixtures/event-plugin'
var mode_fixture = root .. '/tests/fixtures/mode-plugin'
var dep_core = root .. '/tests/fixtures/dep-core'
var dep_user = root .. '/tests/fixtures/dep-user'

def Rtp(): list<string>
  return split(&runtimepath, ',')
enddef

# ---------------------------------------------------------------------------
# event: the plugin waits for an autocommand event, then sees it happen
# ---------------------------------------------------------------------------

simpleplug#Begin(plugdir)
simpleplug#Plug('local/event-plugin', {
  as: 'event-fixture',
  dir: event_fixture,
  event: 'InsertEnter',
})
simpleplug#End()

assert_false(exists('g:simpleplug_event_fixture_loaded'), 'event plugin loaded eagerly')
assert_true(index(Rtp(), event_fixture) < 0, 'event plugin left on runtimepath')

doautocmd InsertEnter
assert_equal(1, get(g:, 'simpleplug_event_fixture_loaded', 0),
  'InsertEnter did not load the plugin declared for it')
assert_true(index(Rtp(), event_fixture) >= 0, 'event plugin missing from runtimepath after load')
# The re-fire is the whole point: the plugin's own InsertEnter handler was
# registered *during* this InsertEnter, so without it the event that woke the
# plugin is the one event the plugin never handles.
assert_equal(1, get(g:, 'simpleplug_event_fixture_insert', 0),
  'the event that woke the plugin was not re-fired at it')

# The trigger is spent: a second InsertEnter must not re-source the plugin.
doautocmd InsertEnter
assert_equal(1, get(g:, 'simpleplug_event_fixture_loaded', 0),
  'the event trigger fired twice')
assert_equal(2, get(g:, 'simpleplug_event_fixture_insert', 0),
  'the loaded plugin stopped seeing the event it was deferred to')

# g:simpleplug_lazy_event_refire = 0 keeps the deferral without the second
# delivery, for an event whose handlers must not run twice.
unlet g:simpleplug_event_fixture_loaded
unlet g:simpleplug_event_fixture_insert
autocmd! SimplePlugEventFixture
g:simpleplug_lazy_event_refire = 0
simpleplug#Begin(plugdir)
simpleplug#Plug('local/event-plugin', {
  as: 'event-fixture-norefire',
  dir: event_fixture,
  event: 'InsertEnter',
})
simpleplug#End()
doautocmd InsertEnter
assert_equal(1, get(g:, 'simpleplug_event_fixture_loaded', 0),
  'the plugin did not load with re-firing switched off')
assert_false(exists('g:simpleplug_event_fixture_insert'),
  'the event was re-fired although g:simpleplug_lazy_event_refire is 0')
g:simpleplug_lazy_event_refire = 1

# An event may carry a pattern, and only a matching buffer may wake the plugin.
unlet g:simpleplug_event_fixture_loaded
autocmd! SimplePlugEventFixture
simpleplug#Begin(plugdir)
simpleplug#Plug('local/event-plugin', {
  as: 'event-fixture-pattern',
  dir: event_fixture,
  event: 'BufReadPre *.evtfixture',
})
simpleplug#End()
edit /tmp/simpleplug-vim-lazy-nomatch.txt
doautocmd BufReadPre
assert_false(exists('g:simpleplug_event_fixture_loaded'),
  'a buffer outside the declared pattern woke the plugin')
edit /tmp/simpleplug-vim-lazy-match.evtfixture
doautocmd BufReadPre
assert_equal(1, get(g:, 'simpleplug_event_fixture_loaded', 0),
  'a matching buffer did not wake the plugin')

# Not every event matches its pattern against a file name: FileType matches on
# the filetype, User on the user event name.  Such an event must reach the
# plugin that was deferred to it just like a buffer event does.
unlet g:simpleplug_event_fixture_loaded
silent! unlet g:simpleplug_event_fixture_ft
autocmd! SimplePlugEventFixture
simpleplug#Begin(plugdir)
simpleplug#Plug('local/event-plugin', {
  as: 'event-fixture-filetype',
  dir: event_fixture,
  event: 'FileType evtfixture',
})
simpleplug#End()
doautocmd FileType evtfixture
assert_equal(1, get(g:, 'simpleplug_event_fixture_loaded', 0),
  'a FileType event did not load the plugin declared for it')
assert_equal(1, get(g:, 'simpleplug_event_fixture_ft', 0),
  'the FileType occurrence that woke the plugin never reached it')

# A misspelt event name would otherwise mean a plugin that never loads and
# never says why.  It is rejected at registration, leaving the plugin eager.
unlet g:simpleplug_event_fixture_loaded
autocmd! SimplePlugEventFixture
simpleplug#Begin(plugdir)
silent! simpleplug#Plug('local/event-plugin', {
  as: 'event-fixture-bogus',
  dir: event_fixture,
  event: 'NoSuchEventPlease',
})
simpleplug#End()
assert_true(index(Rtp(), event_fixture) >= 0,
  'a plugin with only an unknown event trigger was left deferred forever')

# ---------------------------------------------------------------------------
# on: {keys, modes} — a trigger that exists in insert or cmdline mode only
# ---------------------------------------------------------------------------

simpleplug#Begin(plugdir)
simpleplug#Plug('local/mode-plugin', {
  as: 'mode-fixture',
  dir: mode_fixture,
  on: [
    {keys: '<Plug>(ModeFixtureI)', modes: 'i'},
    {keys: '<Plug>(ModeFixtureC)', modes: 'c'},
  ],
})
simpleplug#End()

assert_false(exists('g:simpleplug_mode_fixture_loaded'), 'mode-lazy plugin loaded eagerly')
assert_match('simpleplug#LazyLoadMap', maparg('<Plug>(ModeFixtureI)', 'i'),
  'insert-mode stub was not installed')
assert_equal('', maparg('<Plug>(ModeFixtureI)', 'n'),
  'an insert-only trigger leaked into normal mode')
assert_match('simpleplug#LazyLoadMap', maparg('<Plug>(ModeFixtureC)', 'c'),
  'cmdline-mode stub was not installed')

feedkeys("i\<Plug>(ModeFixtureI)\<Esc>", 'x')
assert_equal(1, get(g:, 'simpleplug_mode_fixture_loaded', 0),
  'an insert-mode trigger did not load the plugin')
assert_equal(1, get(g:, 'simpleplug_mode_fixture_insert', 0),
  'the insert-mode key was not replayed into the real mapping')
assert_notmatch('simpleplug#LazyLoadMap', maparg('<Plug>(ModeFixtureI)', 'i'),
  'the insert-mode stub survived the load')
# The cmdline trigger of the same plugin is spent too, and unmapping it is only
# half the job: the stub must also be off the lazy-map list, because what sits
# under those keys now is the mapping the plugin itself installed, and Begin()
# unmaps everything that list still names.
simpleplug#Begin(plugdir)
assert_match('mode_fixture_cmdline', maparg('<Plug>(ModeFixtureC)', 'c'),
  'the cmdline-mode stub of an already-loaded plugin was left armed')

# The same for cmdline mode, from a clean registration.
iunmap <Plug>(ModeFixtureI)
cunmap <Plug>(ModeFixtureC)
unlet g:simpleplug_mode_fixture_loaded
simpleplug#Begin(plugdir)
simpleplug#Plug('local/mode-plugin', {
  as: 'mode-fixture-cmdline',
  dir: mode_fixture,
  on: [{keys: '<Plug>(ModeFixtureC)', modes: 'c'}],
})
simpleplug#End()
feedkeys(":\<Plug>(ModeFixtureC)\<CR>", 'x')
assert_equal(1, get(g:, 'simpleplug_mode_fixture_loaded', 0),
  'a cmdline-mode trigger did not load the plugin')
assert_equal(1, get(g:, 'simpleplug_mode_fixture_cmdline', 0),
  'the cmdline-mode key was not replayed into the real mapping')

# An unknown mode letter is refused rather than silently mapping nothing.
iunmap <Plug>(ModeFixtureI)
unlet g:simpleplug_mode_fixture_loaded
simpleplug#Begin(plugdir)
silent! simpleplug#Plug('local/mode-plugin', {
  as: 'mode-fixture-bogus',
  dir: mode_fixture,
  on: [{keys: '<Plug>(ModeFixtureI)', modes: 'z'}],
})
simpleplug#End()
assert_equal('', maparg('<Plug>(ModeFixtureI)', 'i'),
  'a trigger with an unknown mode was installed anyway')
assert_true(index(Rtp(), mode_fixture) >= 0,
  'a plugin whose only trigger was rejected was left deferred forever')

# ---------------------------------------------------------------------------
# dependencies
# ---------------------------------------------------------------------------

# A lazy plugin loads its lazy dependency first, and does it on the trigger,
# not at startup.
silent! delcommand DepCoreCommand
silent! delcommand DepUserCommand
g:simpleplug_dep_order = []
simpleplug#Begin(plugdir)
simpleplug#Plug('local/dep-user', {
  as: 'dep-user',
  dir: dep_user,
  on: 'DepUserCommand',
  dependencies: ['dep-core'],
})
simpleplug#Plug('local/dep-core', {
  as: 'dep-core',
  dir: dep_core,
  on: 'DepCoreCommand',
})
simpleplug#End()
assert_equal([], g:simpleplug_dep_order, 'a dependency was loaded at startup')
DepUserCommand
assert_equal(['core', 'user'], g:simpleplug_dep_order,
  'the dependency was not sourced before the plugin that declared it')
assert_true(index(Rtp(), dep_core) >= 0, 'the dependency is not on runtimepath')

# A dependency may be named by the repository string it was declared with.
silent! delcommand DepCoreCommand
silent! delcommand DepUserCommand
g:simpleplug_dep_order = []
simpleplug#Begin(plugdir)
simpleplug#Plug('local/dep-user', {
  as: 'dep-user-byrepo',
  dir: dep_user,
  on: 'DepUserCommand',
  dependencies: ['local/dep-core'],
})
simpleplug#Plug('local/dep-core', {as: 'dep-core-byrepo', dir: dep_core, on: 'DepCoreCommand'})
simpleplug#End()
DepUserCommand
assert_equal(['core', 'user'], g:simpleplug_dep_order,
  'a dependency named by its repository string was not resolved')

# An eager plugin's dependency cannot stay deferred: "first" is decided by
# 'runtimepath' order at startup, and a trigger that never fires never gets
# there.  The dependency is promoted to eager and placed ahead of it.
&runtimepath = join(filter(Rtp(), (_, e) =>
  e !=# dep_core && e !=# dep_user), ',')
simpleplug#Begin(plugdir)
simpleplug#Plug('local/dep-user', {
  as: 'dep-user-eager',
  dir: dep_user,
  dependencies: ['dep-core-lazy'],
})
simpleplug#Plug('local/dep-core', {as: 'dep-core-lazy', dir: dep_core, for: 'rust'})
simpleplug#End()
var rtp = Rtp()
assert_true(index(rtp, dep_core) >= 0,
  'a dependency of an eager plugin was left deferred')
assert_true(index(rtp, dep_core) < index(rtp, dep_user),
  'the dependency is not ahead of its dependant on runtimepath')

# Declaration order is preserved for everything a dependency edge does not
# move, so adding the feature does not reshuffle anyone else's runtimepath.
&runtimepath = join(filter(Rtp(), (_, e) =>
  e !=# dep_core && e !=# dep_user), ',')
simpleplug#Begin(plugdir)
simpleplug#Plug('local/dep-core', {as: 'dep-core-plain', dir: dep_core})
simpleplug#Plug('local/dep-user', {as: 'dep-user-plain', dir: dep_user})
simpleplug#End()
rtp = Rtp()
assert_true(index(rtp, dep_user) < index(rtp, dep_core),
  'runtimepath order changed for plugins that declare no dependencies')

# A cycle must be reported and fall back, not hang and not lose a plugin.
&runtimepath = join(filter(Rtp(), (_, e) =>
  e !=# dep_core && e !=# dep_user), ',')
simpleplug#Begin(plugdir)
simpleplug#Plug('local/dep-core', {as: 'cycle-a', dir: dep_core, dependencies: ['cycle-b']})
simpleplug#Plug('local/dep-user', {as: 'cycle-b', dir: dep_user, dependencies: ['cycle-a']})
silent simpleplug#End()
rtp = Rtp()
assert_true(index(rtp, dep_core) >= 0, 'a plugin in a dependency cycle was dropped')
assert_true(index(rtp, dep_user) >= 0, 'a plugin in a dependency cycle was dropped')

# A dependency on something that was never declared is reported, and the
# plugin that declared it still loads.
silent! delcommand DepUserCommand
g:simpleplug_dep_order = []
simpleplug#Begin(plugdir)
simpleplug#Plug('local/dep-user', {
  as: 'dep-user-missing',
  dir: dep_user,
  on: 'DepUserCommand',
  dependencies: ['not-declared-anywhere'],
})
silent simpleplug#End()
silent DepUserCommand
assert_equal(['user'], g:simpleplug_dep_order,
  'an unresolvable dependency stopped its dependant from loading')

if !empty(v:errors)
  for error in v:errors
    echom error
  endfor
  cquit 1
endif
qa!
