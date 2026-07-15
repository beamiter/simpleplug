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
