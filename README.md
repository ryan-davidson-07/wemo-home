# Wemo Home

Native iPhone control for Rayns, an original Belkin Wemo LightSwitch 1.0. SwiftUI sits over a dependency-free Swift package using Foundation, URLSession and SOAP 1.1. The app starts at `192.168.4.28:49153` and supports manually changing that private IPv4 address and port.

**Linux core validation passed:** the package builds on Swift 6.4.1 and all 49 XCTest methods pass, including the corrected XML entity regression. The recorded run uses `./scripts/test-core.sh --build-system native -Xswiftc -warnings-as-errors` because the default SwiftPM backend stalled with a CFSocket error inside this restricted execution environment. XcodeGen generation, Apple SDK compilation and physical iPhone operation remain unvalidated. No requests were sent to the switch. See [DEVELOPMENT_STATUS.md](DEVELOPMENT_STATUS.md) and [VALIDATION_LOG.txt](VALIDATION_LOG.txt) for results, and [DEPLOYMENT_MAC.md](DEPLOYMENT_MAC.md) for the first Xcode build.

## Run the core tests

With Swift 5.9 or later available:

```bash
cd /home/hokage/wemo-home
./scripts/test-core.sh
```

The script runs `swift test` and installs nothing. Tests use a scripted `HTTPTransport`; no test connects to a network or toggles hardware. The SwiftUI `App` directory is deliberately outside the Swift package's targets, so Linux needs no Apple UI SDKs. Conditional imports provide FoundationNetworking and FoundationXML on Linux.

The owner has installed `swift-bin` on this Arch host. See [DEVELOPMENT_LINUX.md](DEVELOPMENT_LINUX.md) for the validated command, sandbox/backend caveat and installation instructions for other machines. No packages or system configuration were changed by the agent.

If `swift --version` fails, follow the [official Swift Linux setup instructions](https://www.swift.org/install/linux/). Choose a compatible toolchain and its documented dependencies yourself; this repository does not install system packages. Arch is not one of the Ubuntu/RHEL distributions targeted by many official prebuilt toolchains, so do not assume an arbitrary Ubuntu tarball will run unchanged on Arch. A supported Linux environment or an official Swift container is another option.

If you already have Docker configured, an isolated test run can use the official `swift:5.9` image (download it first if needed):

```bash
docker pull swift:5.9
docker run --rm --network none \
  -v "$PWD":/workspace -w /workspace \
  swift:5.9 swift test --scratch-path /tmp/wemo-build
```

This mounts the project, has no container network, and writes build products to the container's temporary directory. A successful Linux run validates core logic only. The iOS app still requires Xcode and an iPhone test. You can also run `swift test` on the Mac before opening Xcode.

## Architecture

| Component | Responsibility |
| --- | --- |
| `Sources/WemoCore/Models.swift` | Validated private IPv4 endpoint, light state, identity and typed errors |
| `HTTPTransport.swift` | Injectable HTTP boundary; ephemeral URLSession with timeouts, no redirect following, cookies, credential storage or cache |
| `SOAP.swift` | Closed SOAP action construction, namespace-aware XMLParser, identification, binary state and structured faults |
| `XMLInputSafety.swift` | Encoding-aware preflight rejection of DTDs and custom entity declarations before FoundationXML |
| `WemoClient.swift` | Only setup GET, GetBinaryState and SetBinaryState; HTTP/error validation and no application retry loop |
| `DeviceStore.swift` | MainActor state machine, coalesced refreshes, command/read-back sequence, foreground polling and response invalidation |
| `App/HomeModel.swift` | Combine adapter and UserDefaults for the address/port only |
| `App/HomeView.swift` | Main card, large control, connection/light state, errors and refresh |
| `App/SettingsView.swift` | Address/port editing, save and read-only connection test, model/firmware display |
| `Tests/WemoCoreTests` | Scripted network transport, XML/client/state/lifecycle/concurrency tests |
| `project.yml` | Reproducible app and simulator unit-test target specification |

There are no runtime third-party packages, cloud calls, accounts, servers or database dependencies. Device identification does not retain serial numbers, UDNs or credentials. Settings are local to the iPhone. `DeviceEndpoint` is the future discovery boundary: an SSDP/discovery component could supply an endpoint to `DeviceStore.configure`, while the HTTP client and UI remain independent. Milestone 1 contains no discovery, multicast, Bonjour browsing or subnet scanning.

### State and concurrency

- A nil light state means **Unknown**, never OFF. The app starts unknown and clears state when the device cannot be read or when the screen/app becomes inactive.
- Online means an HTTP response was received; a SOAP/HTTP/XML error can therefore show Online with an unknown light state and a visible error. Offline means the network request failed or timed out; it is not proof the switch has lost power. Local Network denial cannot reliably be distinguished from other connectivity failures by this client.
- Opening the main screen and returning to it in the foreground starts an immediate refresh, then a refresh every 15 seconds after the previous operation completes. The settings sheet pauses main-screen polling. Manual refresh and the settings test read state too.
- All state changes run on MainActor. Refresh callers share a single owned operation. A second control command while busy is ignored. Commands are disabled until a state has been successfully read. There is no optimistic change of the displayed light state.
- Every acknowledged SetBinaryState is followed by GetBinaryState. Its actual response becomes the displayed state. A mismatch is shown explicitly. A command or confirmation failure leaves the state unknown and asks for a read before another command.
- Suspending, hiding the screen or replacing the endpoint cancels the current operation. A generation token rejects late results even if a transport ignores cancellation. Cancellation cannot retract a command already delivered to the switch; the next foreground read reconciles its state.
- No application-level write retries occur. A timeout, connection loss or cancellation does not prove a command failed to reach the relay. Periodic recovery and manual refresh send reads only.

The polling task is an in-process foreground task. There is no background mode, background service or scheduling implementation.

### Protocol and local network policy

Only these operations exist in the client:

| Method | Path | Action |
| --- | --- | --- |
| GET | `/setup.xml` | Read Belkin LightSwitch identity/model/firmware and check basic service |
| POST | `/upnp/control/basicevent1` | `urn:Belkin:service:basicevent:1#GetBinaryState` |
| POST | `/upnp/control/basicevent1` | `urn:Belkin:service:basicevent:1#SetBinaryState`, BinaryState 0 or 1 |

SOAPAction is quoted, with SOAP 1.1 XML and `text/xml; charset="utf-8"`. The parser accepts only 0/1 for this model. Setter responses may echo BinaryState or acknowledge without it; the store always reads back. SOAP faults are parsed on HTTP 500 and other statuses, including HTTP 200. Other non-2xx responses are errors, including redirects. Successful responses must contain valid expected XML; malformed documents, reported parser errors, wrong namespaces, ambiguous states, DTDs/custom entity declarations, excessive nesting and documents over 1 MiB are rejected. The input preflight supports UTF-8 and standard UTF-16/32 signatures; unsupported/mismatched declared encodings fail closed. Harmless declaration-like literals in comments, processing instructions and CDATA, plus predefined/numeric references, remain allowed. Declaration rejection does not rely on FoundationXML delegate coverage. The size check happens after URLSession has received the data; it is a parser limit, not streaming download protection.

The transport uses a five-second request timeout and an eight-second resource timeout. Settings accept only RFC 1918 IPv4 addresses. Public IPs, hostnames, IPv6, URLs and ambiguous octal-style octets are rejected. Redirects are rejected by the URLSession delegate so a device cannot redirect control to another destination. The descriptor cannot replace the fixed control path. A changed address must identify as a Belkin LightSwitch before controls become available; Milestone 1 does not pin a particular unit by UDN.

`App/Info.plist` includes `NSLocalNetworkUsageDescription` and `NSAppTransportSecurity.NSAllowsLocalNetworking = YES`. It contains no `NSAllowsArbitraryLoads`, internet HTTP exception, multicast entitlement or Bonjour declaration. Apple documents this ATS setting for local names and IP addresses; first launch permissions and actual IP HTTP access remain physical-device checks. See [Apple ATS local networking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking) and [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

## Research and licensing

The following were reviewed read-only before implementation:

- `/home/hokage/wemo-research/WEMO_RESEARCH_REPORT.md`
- `/home/hokage/wemo-research/SQLITE_RETENTION_ANALYSIS.md`
- Archived setup/eventservice XML and successful GetBinaryState response/request
- Archived `sources/gist-wemo-soap.md` basic-event protocol reference and pywemo SOAP transport conventions
- `sources/wemo-sos/WemoControlIOS` (revision `79cfbd8eacf4dfce9d2b1c806abc24305cc3374d`), including its MIT licence and SwiftUI/store/client/scanning implementation

The archived iOS app provides a useful reference for SwiftUI lifecycle handling and SOAP framing. This implementation was written for the stated constraints: direct endpoint configuration, structured XML and fault parsing, explicit unknown state, confirmed commands and isolated testing. Its subnet scanner, regex parser, optimistic writes and error-to-OFF behavior were not adopted. The archived pywemo automatic SOAP retry policy was not adopted. The reference licence and attribution are retained in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); the original research directory remains unchanged.

The research did not establish autonomous scheduling on this firmware. This app contains no rules database upload, timer, TimeSync, firmware, Wi-Fi or other device configuration API. It neither restores nor changes prior scheduling experiments.
