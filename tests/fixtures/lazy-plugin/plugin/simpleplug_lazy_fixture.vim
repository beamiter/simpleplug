vim9script

g:simpleplug_lazy_fixture_loaded = get(g:, 'simpleplug_lazy_fixture_loaded', 0) + 1
command! -nargs=* LazyFixtureCommand g:simpleplug_lazy_fixture_args = '<args>'
