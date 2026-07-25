vim9script

g:simpleplug_lazy_fixture_ftdetect = get(g:, 'simpleplug_lazy_fixture_ftdetect', 0) + 1
autocmd BufNewFile,BufRead *.lazyfixture setfiletype lazyfixture
