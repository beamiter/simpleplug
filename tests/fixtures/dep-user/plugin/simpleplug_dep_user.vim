vim9script

g:simpleplug_dep_order = add(get(g:, 'simpleplug_dep_order', []), 'user')
command! -nargs=0 DepUserCommand g:simpleplug_dep_user_ran = 1
