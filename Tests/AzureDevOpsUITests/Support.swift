/// How long a test waits for something before it fails. `make test` runs every test's async work on one thread
/// (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`), and the tests on the main actor share the main thread, so a test may get
/// its turn only after most of the others. On CI's busy runner, tests waited half a minute or more, about as long as the
/// whole run takes. A wait that's answered still returns as soon as it is: only a test that fails takes this long.
let waitLimit: Duration = .seconds(60)
