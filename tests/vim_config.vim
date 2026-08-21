vim9script

set nocompatible nomore
var root = fnamemodify(expand('<sfile>'), ':p:h:h')
execute 'set runtimepath^=' .. fnameescape(root)

# A malformed vimrc must be corrected at the configuration boundary instead
# of throwing later from a timer, printf(), a boolean branch, or :resize.
g:simpleplug_dir = []
g:simpleplug_daemon_path = {}
g:simpleplug_debug = 'yes'
g:simpleplug_window_width = 'wide'
g:simpleplug_auto_install = []
g:simpleplug_jobs = 0
g:simpleplug_git_timeout = 'slow'
g:simpleplug_hook_timeout = -1
g:simpleplug_activate_on_install = 'now'
g:simpleplug_sync_timeout = 0
g:simpleplug_spinner_interval = -20
g:simpleplug_lazy_event_refire = {}
g:simpleplug_snapshot_format = 'xml'
g:simpleplug_profile_threshold_ms = 'fast'

execute 'source ' .. fnameescape(root .. '/plugin/simpleplug.vim')

assert_equal(expand('~/.vim/plugged'), g:simpleplug_dir)
assert_equal('', g:simpleplug_daemon_path)
assert_equal(0, g:simpleplug_debug)
assert_equal(88, g:simpleplug_window_width)
assert_equal(1, g:simpleplug_auto_install)
assert_equal(1, g:simpleplug_jobs)
assert_equal(300, g:simpleplug_git_timeout)
assert_equal(600, g:simpleplug_hook_timeout)
assert_equal(1, g:simpleplug_activate_on_install)
assert_equal(1800, g:simpleplug_sync_timeout)
assert_equal(200, g:simpleplug_spinner_interval)
assert_equal(1, g:simpleplug_lazy_event_refire)
assert_equal('v1', g:simpleplug_snapshot_format)
assert_equal(5.0, g:simpleplug_profile_threshold_ms)

# Documented live options are validated again where they are consumed.
g:simpleplug_dir = {}
g:simpleplug_git_timeout = 'slow'
g:simpleplug_hook_timeout = []
var health = execute('silent simpleplug#Health()')
assert_match('plugin directory: ' .. escape(expand('~/.vim/plugged'), '\'), health)
assert_match('git timeout: 300s, hook timeout: 600s', health)

if !empty(v:errors)
  writefile(v:errors, root .. '/tests/config-errors.log')
  cquit!
endif
delete(root .. '/tests/config-errors.log')
qall!
