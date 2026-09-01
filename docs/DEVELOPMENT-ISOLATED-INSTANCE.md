# Isolated development instance

To run a second MClash checkout without reusing the production profile store or
automation endpoint, set these variables only on the development process:

```sh
MCLASH_APPLICATION_SUPPORT_IDENTIFIER=MClash-Dev \
MCLASH_AUTOMATION_DIRECTORY_IDENTIFIER=MClash-Dev \
MCLASH_INSTANCE_NAMESPACE=one.leaper.mclash-dev \
MCLASH_TEST_MODE=1 \
swift run MClash
```

For an exact endpoint location, use an absolute path instead of the identifier:

```sh
MCLASH_APPLICATION_SUPPORT_IDENTIFIER=MClash-Dev \
MCLASH_AUTOMATION_DIRECTORY_PATH=/tmp/mclash-dev-automation \
MCLASH_INSTANCE_NAMESPACE=one.leaper.mclash-dev \
MCLASH_TEST_MODE=1 \
swift run MClash
```

Both variables are opt-in. With neither set, the application continues to use
the normal `MClash` Application Support and automation directories. The
override changes local profile/discovery storage only; it does not create a
second Apple Network Extension identity. `MCLASH_INSTANCE_NAMESPACE` also
separates the single-instance lock under `~/Library/Caches`, preventing the
test app from contending with the production process. Keep Network Extension/TUN and
system-proxy capture disabled for the isolated process, and use distinct local
listener ports. The running production app and its extension must not be
stopped or reconfigured as part of this test.

For a packaged app launched by LaunchServices (where shell environment
variables are not inherited), pass the explicit test argument instead:

```sh
open -n .build/isolated-test/MClash.app --args \
  --mclash-background --mclash-test-instance
```

The argument selects `MClash-Shadow` storage and the
`one.leaper.mclash-shadow` lock namespace. It also enables the inert Network
Extension boundary used by shadow builds, so the production extension is never
installed or reconfigured.
