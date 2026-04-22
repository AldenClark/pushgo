fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios beta_upload

```sh
[bundle exec] fastlane ios beta_upload
```

Archive and upload build to TestFlight

### ios release_upload

```sh
[bundle exec] fastlane ios release_upload
```

Archive and upload build to App Store

### ios beta_dmg

```sh
[bundle exec] fastlane ios beta_dmg
```

Build and notarize DMG for beta tags

### ios release_dmg

```sh
[bundle exec] fastlane ios release_dmg
```

Build and notarize DMG for release tags

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Archive, upload, and notarize beta artifacts

### ios release

```sh
[bundle exec] fastlane ios release
```

Archive, upload, and notarize release artifacts

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
