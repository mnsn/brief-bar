/// How long a test waits for something before it fails. `make test` runs every test's async work on one thread
/// (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`), and the tests on the main actor share the main thread, so a test may get
/// its turn only after most of the others. On CI's slow runners on 2026-11-08, whole runs took up to about three and a
/// half minutes, and waits of a minute ran out in tests nobody had changed: so four minutes. A wait that's answered
/// still returns as soon as it is: only a test that fails takes this long.
let waitLimit: Duration = .seconds(240)
