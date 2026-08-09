vim9script

# Deliberately throws.  Sourcing third-party code is best-effort by design: the
# failure is caught, reported through the debug log and the rest of the plugin
# still loads.  This fixture is how a test reaches that reporting path.
g:simpleplug_broken_fixture_sourced =
  get(g:, 'simpleplug_broken_fixture_sourced', 0) + 1
throw 'simpleplug-broken-fixture'
