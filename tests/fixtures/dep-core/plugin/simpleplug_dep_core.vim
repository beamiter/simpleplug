vim9script

g:simpleplug_dep_order = add(get(g:, 'simpleplug_dep_order', []), 'core')
command! -nargs=0 DepCoreCommand g:simpleplug_dep_core_ran = 1
