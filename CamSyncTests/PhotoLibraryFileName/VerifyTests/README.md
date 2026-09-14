# Photos filename preservation — verification harness

Standalone (not wired into `CamSync.xcodeproj`) reproduction and regression check for:
"CamSync staging files" — `TransferService` copies each source file to a UUID-named
staging file; the fix makes `PhotoLibraryService` hand Photos an
`originalFilename`, so the library keeps the source device's name.

The target compiles the **real** app sources (`../../CamSync/…`), so the tests
exercise the shipping code, not a copy.

## Run

    ./make-fixtures.sh                 # sips-generated fixtures (not committed)
    xcodegen generate
    xcrun simctl privacy booted grant photos com.misswell.VerifyHost
    xcodebuild test -project CamSyncVerify.xcodeproj -scheme CamSyncVerify \
      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
      -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120

## What it asserts

Each case runs the full `TransferService.transfer(_:to:)` path and reads the stored
name back with `PHAssetResource.assetResources(for:)`:

| source name | expected resource `originalFilename` |
| --- | --- |
| `IMG_1234.JPG` | `IMG_1234.JPG` |
| `IMG_5678.HEIC` | `IMG_5678.HEIC` |
| `Screenshot_0001.PNG` | `Screenshot_0001.PNG` |
| `DSC_0001.NEF` | `DSC_0001.NEF` |

Plus: the UUID staging files are gone after import, and a negative control proves
the old `PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL:)` API
still stores the UUID staging name (i.e. the checks can actually fail).

Verified 2026-09-14, Xcode 26.3 / iOS 26.3 simulator: 6/6 passed.
