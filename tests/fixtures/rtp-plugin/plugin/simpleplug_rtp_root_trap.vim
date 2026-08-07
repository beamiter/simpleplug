vim9script

# The checkout root is deliberately not the Vim runtime.  Tests source this
# name through :runtime and assert that it remains invisible.
g:simpleplug_rtp_checkout_root_loaded = true
