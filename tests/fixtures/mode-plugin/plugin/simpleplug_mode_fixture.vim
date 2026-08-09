vim9script

g:simpleplug_mode_fixture_loaded = get(g:, 'simpleplug_mode_fixture_loaded', 0) + 1
inoremap <Plug>(ModeFixtureI) <Cmd>g:simpleplug_mode_fixture_insert = get(g:, 'simpleplug_mode_fixture_insert', 0) + 1<CR>
cnoremap <Plug>(ModeFixtureC) <Cmd>g:simpleplug_mode_fixture_cmdline = get(g:, 'simpleplug_mode_fixture_cmdline', 0) + 1<CR>
