vim9script

g:simpleplug_rtp_fixture_loaded = get(g:, 'simpleplug_rtp_fixture_loaded', 0) + 1
command! RtpFixtureCommand g:simpleplug_rtp_fixture_triggered = 1
