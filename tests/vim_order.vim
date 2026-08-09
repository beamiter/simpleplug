vim9script

# One load order, whichever path produced it.
#
# Eager plugins are sourced twice by two different pieces of code.  At startup
# Vim's own 'runtimepath' scan does it, after the vimrc has returned; call
# simpleplug#End() again once VimEnter has passed — re-sourcing a vimrc is the
# usual way — and End() sources them itself, because the scan is over and will
# not run again.  If those two paths disagree, re-sourcing a vimrc silently
# swaps which plugin's settings survive, and `dependencies` only holds on one
# of them.
#
# AddRuntimePath *prepends*, so walking the load order once leaves 'runtimepath'
# holding its reverse — which is the order the startup scan then reads.  End()
# therefore has to walk its own order backwards to match.  Nothing about that
# can be seen from a `-S` script: -S runs after the scan, so a script that
# calls End() itself is always on the post-VimEnter path.  This file starts a
# real child Vim with a real vimrc, lets the scan happen, then re-sources that
# same vimrc from a VimEnter autocommand and compares the two orders.

set nomore

var root = fnamemodify(expand('<sfile>'), ':p:h:h')
var dep_core = root .. '/tests/fixtures/dep-core'
var dep_user = root .. '/tests/fixtures/dep-user'
var home = tempname()
mkdir(home .. '/plugged', 'p')

var child_vimrc = home .. '/vimrc'
var child_probe = home .. '/probe.vim'
var child_out = home .. '/order.txt'

# Both fixtures append their own name to g:simpleplug_dep_order as their
# plugin/ script runs, so the list *is* the order they were sourced in.  It is
# reset here rather than in the probe: the vimrc is sourced twice, and each
# sourcing has to be measured on its own.
writefile([
  'vim9script',
  'set nomore',
  'g:simpleplug_auto_install = 0',
  'set runtimepath^=' .. fnameescape(root),
  'source ' .. fnameescape(root .. '/plugin/simpleplug.vim'),
  'g:simpleplug_dep_order = []',
  printf('simpleplug#Begin(%s)', string(home .. '/plugged')),
  printf('simpleplug#Plug(%s, {as: %s, dir: %s})',
    string('local/dep-core'), string('order-core'), string(dep_core)),
  printf('simpleplug#Plug(%s, {as: %s, dir: %s})',
    string('local/dep-user'), string('order-user'), string(dep_user)),
  'simpleplug#End()',
  # Armed once.  The re-source runs this file again, and a second VimEnter
  # autocommand would be a second re-source measuring the wrong thing.
  'if !exists("g:order_probe_armed")',
  '  g:order_probe_armed = 1',
  '  augroup OrderProbe',
  '    autocmd!',
  printf('    autocmd VimEnter * source %s', fnameescape(child_probe)),
  '  augroup END',
  'endif',
], child_vimrc)

writefile([
  'vim9script',
  'var startup = copy(get(g:, "simpleplug_dep_order", []))',
  'source ' .. fnameescape(child_vimrc),
  'var resourced = copy(get(g:, "simpleplug_dep_order", []))',
  'writefile([',
  '  "did_enter=" .. v:vim_did_enter,',
  '  "startup=" .. join(startup, ","),',
  '  "resourced=" .. join(resourced, ","),',
  printf('  ], %s)', string(child_out)),
  'qall!',
], child_probe)

# No `-S`: it would run the probe *before* VimEnter, which is the one moment
# the probe must not run in.  The vimrc's own VimEnter autocommand sources it
# instead, and the probe quits the child itself.
#
# Empty input, not the inherited one: a child in ex mode reads commands from
# stdin once startup is over, and would otherwise hang the suite.
silent call system(printf('%s -N -u %s -n -i NONE -es',
  shellescape(v:progpath), shellescape(child_vimrc)), '')
var child = filereadable(child_out) ? readfile(child_out) : []
assert_true(!empty(child), 'the child Vim wrote no load order')

# Without this the rest proves nothing: End() only sources plugins itself once
# v:vim_did_enter is set, and before that it would just be measuring the scan
# twice.
assert_equal('did_enter=1', get(child, 0, ''),
  'the re-source did not happen after VimEnter: ' .. string(child))

# The premise the reversal rests on.  The plugins are declared core, user; the
# scan reads 'runtimepath', which AddRuntimePath built by prepending each in
# turn, so the scan sees them in the opposite order.  If this ever flips, the
# reversal in End() becomes the bug rather than the fix.
assert_equal('startup=user,core', get(child, 1, ''),
  'the startup scan did not source eager plugins in reverse declaration order: '
  .. string(child))

assert_equal(get(child, 1, 'startup=?')[8 :], get(child, 2, 'resourced=?')[10 :],
  'End() after VimEnter sourced eager plugins in a different order than the '
  .. 'startup scan did: ' .. string(child))

delete(home, 'rf')

if !empty(v:errors)
  for error in v:errors
    echom error
  endfor
  cquit 1
endif
qa!
