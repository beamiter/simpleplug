vim9script

var started = reltime()
while reltimefloat(reltime(started)) < 0.03
endwhile
g:simpleplug_profile_fixture_loaded = get(g:, 'simpleplug_profile_fixture_loaded', 0) + 1
command! -nargs=* ProfileFixtureCmd g:simpleplug_profile_fixture_args = '<args>'
