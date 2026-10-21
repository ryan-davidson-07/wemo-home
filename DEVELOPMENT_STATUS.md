# Development status

Updated October 20, 2026 after installing Swift and running the corrected parser suite. **The Linux package builds and all 49 XCTest methods pass on Swift 6.4.1.** The final run treats compiler warnings as errors. iOS compilation and physical iPhone operation remain unvalidated.

## Current validation

| Check | Result |
| --- | --- |
| Independent test run of the original source | Owner reports successful Linux compilation and 38 tests run: 37 passed, 1 failed (`XMLTests.testRejectsEntitiesDepthAndOversizedDocuments`); performed in a separate ChatGPT environment, compiler/version unavailable locally |
| Cause of the entity failure | Original parser relied on declaration delegate callbacks that cannot be relied on across implementations; expected invalidXML became device-schema invalidResponse |
| Parser fix | Implemented explicit preflight DTD rejection, encoding checks and strict error handling; assertion retained |
| Updated test suite | **49 executed, 49 passed, 0 failures**, exit 0; ClientTests 9, DeviceStoreTests 15, EndpointTests 2, XMLTests 23 |
| Local Swift toolchain | Owner installed `swift-bin 6.4.1-1`; Swift 6.4.1, target `x86_64-unknown-linux-gnu` |
| Final test command | `./scripts/test-core.sh --build-system native -Xswiftc -warnings-as-errors`; build and all tests passed, exit 0 |
| Default SwiftPM backend | Default `swiftbuild` emitted a CFSocket error and stalled inside the restricted execution environment; interrupted, then native backend succeeded |
| Direct FoundationXML probe | Custom entity declaration accepted with `parse() = true`, nil parser error, zero internal declaration callbacks and empty character data on installed Swift 6.4.1 |
| System packages/configuration | Owner installed Swift; agent made no package installs or system configuration changes |
| SwiftUI/XcodeGen review | Static review completed and all four app files pass `swiftc -frontend -parse`; Apple SDK type checking and generator execution remain pending |
| Static plist/assets/YAML/script checks | Passed available checks; details in `VALIDATION_LOG.txt` |
| Wemo protocol/state/client code | Unchanged; no physical switch requests or configuration changes |
| Research preservation | Existing research retained unchanged |
| Xcode/iPhone | No XcodeGen generation, simulator build, signing, installation or physical test performed |

The Linux test objective is satisfied for the recorded command and toolchain. See [DEVELOPMENT_LINUX.md](DEVELOPMENT_LINUX.md) for the backend workaround and [DEPLOYMENT_MAC.md](DEPLOYMENT_MAC.md) for the next validation: an actual Xcode build and Apple Foundation test run. SwiftPM reports that the native backend is deprecated; that tooling warning is separate from compiler diagnostics. The runner remains unchanged and does not force this backend globally.

## Entity investigation and parser changes

The original independent run reported that a custom entity declaration reached device-schema validation instead of being rejected as invalidXML. After Swift installation, an in-memory FoundationXML probe using the original delegate/configuration reproduced the acceptance: `parse()` returned true, `parserError` was nil, and the internal declaration callback count was zero. Character data was empty, so this particular Linux implementation suppressed the custom reference rather than returning its replacement text. It still failed the application's required policy of rejecting declarations. The corrected original regression now passes locally.

The inspected [corelibs Swift parser](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/FoundationXML/XMLParser.swift) configures entity substitution and uses `shouldResolveExternalEntities` to control external DTD loading. The [C SAX bridge](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/_CFXMLInterface/CFXMLInterface.c) does not wire a general `entityDecl` callback to the Swift delegate. This explains why relying on `foundInternalEntityDeclarationWithName` fails on Linux. These links refer to the source inspected during review, not a claim about the unknown independent runner's exact revision.

Apple documents [external resolution](https://developer.apple.com/documentation/foundation/xmlparser/shouldresolveexternalentities) and [internal declaration notification](https://developer.apple.com/documentation/foundation/xmlparserdelegate/parser(_:foundinternalentitydeclarationwithname:value:)). Neither is an automatic policy rejecting every DTD. The precise Apple delegate behavior has not been tested here. Cross-platform enforcement now occurs before FoundationXML sees the input and no longer depends on those notifications.

`XMLInputSafety.swift` performs a bounded lexical pass after the existing 1 MiB input check. It rejects actual declaration markup (including unused/parameter/external entities and external DTD subsets), while permitting harmless declaration-like text in comments, processing instructions and CDATA. Predefined XML entities and numeric references remain supported. It recognizes UTF-8 and standard UTF-16/32 signatures so NUL-padded declarations cannot bypass the check. Declared encodings must match the supported family; unsupported legacy encodings and mismatches fail closed with invalidXML. Wemo's existing UTF-8 requests and the control protocol are unchanged.

The parser retains external-resolution disabling, adds an explicit `.never` policy and an empty external-URL allowlist, keeps declaration delegate rejection as a secondary defense, rejects any reported parser/validation error, checks matching end elements and requires an end-document callback. Abort handling is idempotent to avoid recursive error handling. Existing limits remain 1 MiB input, 32 element levels and 10,000 nodes. Input-size validation still happens after URLSession has received the response; it is not a streaming download limit.

Regression tests cover the original failure plus used/unused declarations in otherwise valid descriptors, internal/parameter/external/unparsed entities, external subsets, DTDs without entities, all public parsing entry points, Unicode byte orders/BOMs, unsupported encoding bypasses, allowed literals/references, malformed recovered documents and the node count limit. The original invalidXML assertion remains unchanged. All tests are included automatically in SwiftPM and the Xcode unit-test target.

## SwiftUI and XcodeGen static review

- The SwiftUI app imports UIKit only in the iOS target. FoundationNetworking/FoundationXML imports remain conditional in the package. Linux package compilation does not compile the app sources.
- App/view/model types are explicitly MainActor isolated. UI networking calls use Task and async methods; the Combine adapter receives MainActor state callbacks. The core and all tests now compile on Linux, including concurrency tests. All four app files additionally pass Swift frontend syntax parsing; this does not resolve SwiftUI/UIKit imports or type-check Apple APIs.
- The two-argument onChange API and topBarTrailing placement require iOS 17; both package and XcodeGen deployment targets specify iOS 17. NavigationStack/LabeledContent and the other reviewed APIs fit that minimum. Full overload resolution, SwiftUI result builders and actor isolation must still be checked with the selected Xcode compiler.
- The local package name/product (`WemoHomeCore`/`WemoCore`) matches the XcodeGen dependency. App sources and test sources are separate, and the new core source is picked up by SwiftPM automatically. The scheme includes the XCTest target for the test build action. `@testable import WemoCore` requires the package's Debug build to enable testability; verify the resolved Xcode package build settings on the Mac.
- The committed Info.plist is referenced by INFOPLIST_FILE and excluded from app copy resources. No XcodeGen `info` generation block overwrites it. Privacy, local ATS, launch screen and bundle/version substitutions are present; no global HTTP exception or background service is added.
- Tracked signing configuration optionally includes the ignored Local.xcconfig. Missing local signing overrides do not prevent unsigned simulator configuration. Actual resolved bundle identifiers, signing, provisioning and hostless iOS XCTest runner behavior still need Xcode validation.
- Asset names and paths match the icon/accent build settings. JSON/PNG checks do not validate asset-catalog compilation or device layout/accessibility.

No speculative app/config changes were made solely to silence potential Apple compiler diagnostics. One actual Linux compiler warning was fixed by explicitly labeling the test helper's `makeClient` initializer argument; the final full run succeeds with compiler warnings treated as errors. There is no confirmed iOS compile error from static review, and there is no claim of a successful iOS build.

## Implemented milestone features

The project retains the reusable URLSession/SOAP client, strict 0/1 responses and structured faults, setup identification, HTTP/timeouts, MainActor known/unknown connection/light state, coalesced operations, write read-back without automatic write retries, foreground/manual polling, SwiftUI device/settings screens, local address persistence, narrow local network configuration, original icon and optional local signing setup. There are no third-party runtime packages, cloud dependencies, accounts, servers or scheduling APIs.

## Remaining work

1. Generate/build/test in Xcode and run the XML regressions against Apple Foundation.
2. Validate Local Network allowed/denied behavior, ATS local HTTP access, lifecycle refresh, light/dark appearance, Dynamic Type and VoiceOver on an iPhone.
3. Obtain explicit owner approval before a physical ON/OFF integration test, then compare observed relay transitions with read-back state. Building/installing alone does not approve toggling the light.

Milestone 1 remains direct private IPv4 only, with one LightSwitch and no discovery or UDN pinning. Offline status cannot distinguish power loss, an address change, Wi-Fi isolation and privacy denial. Cancelling a delivered command cannot undo it. No rules uploads, native scheduling, TimeSync, firmware updates, switch configuration changes or internet remote control are included.

## First Mac/iPhone results (fill after execution)

- Date / macOS / Xcode / Swift / XcodeGen:
- Swift package and Apple XML regression results:
- Simulator build and test results / resolved testability:
- iPhone model / iOS / signing and installed build:
- Local Network allowed/denied and foreground/background observations:
- VoiceOver / Dynamic Type / light and dark checks:
- Owner-approved control scope and physical observations:
- Remaining failures or limitations:
