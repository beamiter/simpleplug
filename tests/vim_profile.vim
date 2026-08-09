vim9script

# :PlugProfile regressions that only a startup can show.
#
# A vimrc runs *before* Vim walks 'runtimepath' for plugin/ scripts, so an
# eager plugin is never sourced by SimplePlug — which is exactly the case the
# report exists for.  Nothing driven from `-S` can reproduce that (`-S` runs
# after the scan), so the eager half of this file drives a real child Vim with
# a real vimrc and reads the report back out of it.

set nomore
g:simpleplug_auto_install = 0

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)
execute 'source ' .. fnameescape(root .. '/plugin/simpleplug.vim')

var fixture = root .. '/tests/fixtures/profile-plugin'
var home = tempname()
mkdir(home .. '/plugged', 'p')

def HeaderLine(lines: list<string>): string
  for line in lines
    if line =~# 'SimplePlug profile'
      return line
    endif
  endfor
  return ''
enddef

def StartupMs(lines: list<string>): float
  return str2float(matchstr(HeaderLine(lines), '(\zs[0-9.]\+\ze of it at startup)'))
enddef

def RowMs(row: string): float
  return str2float(matchstr(row, '^\s*\zs[0-9.]\+'))
enddef

# Table rows only: they start with the measurement.  The candidate list at the
# bottom of the report names the same plugin and must not be counted as one.
def RowsFor(lines: list<string>, name: string): list<string>
  return filter(copy(lines), (_, l) => l =~# '^\s*[0-9]\+\.[0-9].*\s' .. name .. '\>')
enddef

# ── eager plugins: measured through Vim's own startup scan ──

var child_vimrc = home .. '/vimrc'
var child_probe = home .. '/probe.vim'
var child_out = home .. '/report.txt'
writefile([
  'vim9script',
  'set nomore',
  'g:simpleplug_auto_install = 0',
  'set runtimepath^=' .. fnameescape(root),
  'source ' .. fnameescape(root .. '/plugin/simpleplug.vim'),
  printf('simpleplug#Begin(%s)', string(home .. '/plugged')),
  printf('simpleplug#Plug(%s, {as: %s, dir: %s})',
    string('local/profile-plugin'), string('eager-fixture'), string(fixture)),
  # Recorded before End() so the assertion below proves the vimrc really did
  # run in the window where SimplePlug cannot call :source itself.
  'g:probe_did_enter = v:vim_did_enter',
  'simpleplug#End()',
], child_vimrc)
writefile([
  'vim9script',
  'var report = [',
  '  "did_enter=" .. g:probe_did_enter,',
  '  "loaded=" .. get(g:, "simpleplug_profile_fixture_loaded", 0),',
  '  ]',
  'silent PlugProfile',
  'extend(report, getline(1, "$"))',
  printf('writefile(report, %s)', string(child_out)),
  'qall!',
], child_probe)

# Empty input, not the inherited one: a child in ex mode reads commands from
# stdin once its script is done, and would otherwise hang the suite.
silent call system(printf('%s -N -u %s -n -i NONE -es -S %s',
  shellescape(v:progpath), shellescape(child_vimrc), shellescape(child_probe)), '')
var child = filereadable(child_out) ? readfile(child_out) : []
assert_true(!empty(child), 'the child Vim wrote no profile report')

assert_equal('did_enter=0', get(child, 0, ''),
  'the child vimrc did not run before VimEnter, so it proves nothing')
assert_equal('loaded=1', get(child, 1, ''),
  'the eager fixture was not sourced exactly once at startup')

var eager_rows = RowsFor(child, 'eager-fixture')
assert_equal(1, len(eager_rows),
  'the profile did not attribute the eager startup load: ' .. string(child))
assert_match('\<eager\>', get(eager_rows, 0, ''), 'the startup load was not labelled eager')
assert_true(RowMs(get(eager_rows, 0, '')) >= 25.0,
  'the eager row did not measure the 30 ms the fixture burns: ' .. get(eager_rows, 0, ''))
assert_true(StartupMs(child) >= 25.0,
  'the startup total omitted the eager plugin: ' .. HeaderLine(child))
var candidate = filter(copy(child), (_, l) => l =~# 'consider {for: ')
assert_equal(1, len(candidate),
  'an expensive eager plugin produced no for/on candidate: ' .. string(child))

# ── a `for`/`on` plugin: its ftdetect cost survives the trigger ──

simpleplug#Begin(home .. '/plugged')
simpleplug#Plug('local/profile-plugin', {
  as: 'trigger-fixture',
  dir: fixture,
  on: 'ProfileFixtureCmd',
})
simpleplug#End()

PlugProfile
var before = getline(1, '$')
bwipeout!
var before_rows = RowsFor(before, 'trigger-fixture')
assert_equal(1, len(before_rows), 'ftdetect sourcing was not reported: ' .. string(before))
assert_match('\<ftdetect\>', get(before_rows, 0, ''), 'the eager ftdetect cost was not labelled ftdetect')
var before_startup = StartupMs(before)
assert_true(before_startup >= 25.0,
  'the ftdetect cost was left out of the startup total: ' .. HeaderLine(before))

ProfileFixtureCmd triggered
assert_equal(1, get(g:, 'simpleplug_profile_fixture_loaded', 0),
  'the lazy fixture did not load on its trigger')

PlugProfile
var after = getline(1, '$')
bwipeout!
var after_rows = RowsFor(after, 'trigger-fixture')
# Two rows, not one: loading the body must add to the plugin's account, never
# reclassify the startup cost it already paid.
assert_equal(2, len(after_rows),
  'the ftdetect row vanished once the plugin loaded: ' .. string(after))
var lazy_row = filter(copy(after_rows), (_, l) => l =~# '\<lazy\>')
assert_equal(1, len(lazy_row), 'the triggered load was not labelled lazy: ' .. string(after_rows))
assert_match(':ProfileFixtureCmd', get(lazy_row, 0, ''), 'the profile did not record the trigger')
assert_true(RowMs(get(lazy_row, 0, '')) >= 25.0, 'the lazy row carries no measurement: ' .. get(lazy_row, 0, ''))
var ftdetect_row = filter(copy(after_rows), (_, l) => l =~# '\<ftdetect\>')
assert_equal(1, len(ftdetect_row),
  'the ftdetect cost was reclassified as lazy: ' .. string(after_rows))
assert_true(RowMs(get(ftdetect_row, 0, '')) >= 25.0,
  'the ftdetect row lost its measurement: ' .. get(ftdetect_row, 0, ''))
assert_true(StartupMs(after) >= before_startup,
  printf('triggering a lazy plugin shrank the startup total: %.1f -> %.1f',
    before_startup, StartupMs(after)))

delete(home, 'rf')

if !empty(v:errors)
  for error in v:errors
    echom error
  endfor
  cquit 1
endif
qa!
