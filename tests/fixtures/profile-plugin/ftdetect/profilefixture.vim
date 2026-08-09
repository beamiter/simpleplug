vim9script

# Deliberately slow: :PlugProfile is a measurement, and a measurement is only
# testable against a cost big enough that rounding cannot hide it.
var started = reltime()
while reltimefloat(reltime(started)) < 0.03
endwhile
g:simpleplug_profile_fixture_ftdetect = get(g:, 'simpleplug_profile_fixture_ftdetect', 0) + 1
autocmd BufNewFile,BufRead *.profilefixture setfiletype profilefixture
