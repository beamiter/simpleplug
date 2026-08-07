vim9script

g:simpleplug_rtp_fixture_ftdetect = get(g:, 'simpleplug_rtp_fixture_ftdetect', 0) + 1
augroup SimplePlugRtpFixtureDetect
  autocmd!
  autocmd BufRead,BufNewFile *.rtpfixture setfiletype rtpfixture
augroup END
