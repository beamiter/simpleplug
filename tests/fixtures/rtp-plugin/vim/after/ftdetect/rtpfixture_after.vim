vim9script

g:simpleplug_rtp_after_ftdetect = get(g:, 'simpleplug_rtp_after_ftdetect', 0) + 1
autocmd BufRead,BufNewFile *.afterrtp setfiletype afterrtp
