vim9script

g:simpleplug_event_fixture_loaded = get(g:, 'simpleplug_event_fixture_loaded', 0) + 1

# A plugin deferred to an event only earns its keep if its own handler sees the
# occurrence that woke it — this counter is what proves the re-fire happened.
#
# The body stays on one line on purpose: Vim9's implicit line continuation does
# not reach inside an :autocmd argument, so splitting it registers the autocmd
# as "g:... =" with nothing to assign, and every InsertEnter after the load
# throws E15 instead of counting.
augroup SimplePlugEventFixture
  autocmd!
  autocmd InsertEnter * g:simpleplug_event_fixture_insert = get(g:, 'simpleplug_event_fixture_insert', 0) + 1
  autocmd FileType evtfixture g:simpleplug_event_fixture_ft = get(g:, 'simpleplug_event_fixture_ft', 0) + 1
augroup END
