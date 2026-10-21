# Linux toolchain setup and tests

The owner has installed `swift-bin 6.4.1-1` on this Arch x86_64 host. `swift --version` reports Swift 6.4.1 (`swift-6.4.1-RELEASE`), target `x86_64-unknown-linux-gnu`. The core package compiles, and all 49 XCTest methods pass locally with zero failures. No package installation or system configuration change was performed by the agent.

## Validated test command

```bash
cd /home/hokage/wemo-home
./scripts/test-core.sh --build-system native -Xswiftc -warnings-as-errors
```

The final recorded command exited 0. Compiler warnings are treated as errors; the only emitted warning is SwiftPM's own native-backend deprecation notice. The test helper's deprecated trailing closure was fixed with an explicit `makeClient` label before this run.

Swift 6.4.1 defaults to the `swiftbuild` backend. In this restricted execution environment it printed `Could not create wakeup socket pair for CFSocket` and stalled before compilation; that attempt was interrupted. Selecting `native` allowed the complete build/test run without changing the system, toolchain or project runner. This is a local workaround using a deprecated backend, not a global configuration change or proof that the default backend fails in a normal host terminal. Try the standard `./scripts/test-core.sh` first outside this sandbox; use the recorded fallback here while supported. The Xcode build workflow is unaffected.

## Installation on another Arch setup (requires approval)

[ArchWiki's Swift page](https://wiki.archlinux.org/title/Swift) recommends `swift-bin` from the AUR for the released binary toolchain, or `swift-language` for a native source build. Prefer `swift-bin` for this project's core tests to avoid building the compiler from source. Swift 5.9 or later is required. The package's actual current version and dependencies must be checked before installation; direct access to the current AUR recipe was blocked during this review, so it has not been audited here.

`yay`, Git and `base-devel` are already installed on this host. After approving installation and reviewing the current recipe, run this in a normal terminal on the Arch host:

```bash
yay -S swift-bin
swift --version
swiftc --version
cd /home/hokage/wemo-home
./scripts/test-core.sh
```

Do not use `--noconfirm`. Review the AUR build files and package/dependency transaction before accepting. The installation changes system files and may install dependencies. These installation commands were provided for review and were **not executed by the agent**. The owner subsequently installed the package independently. This workspace's restricted permissions do not permit installing files under `/usr`; any system installation must be performed from an appropriately authorized host terminal.

For an explicit manual AUR review/build workflow instead of using the helper:

```bash
mkdir -p "$HOME/Builds"
git clone https://aur.archlinux.org/swift-bin.git "$HOME/Builds/swift-bin"
cd "$HOME/Builds/swift-bin"
less PKGBUILD .SRCINFO
# Continue only after reviewing and approving the recipe and dependencies:
makepkg -si
```

Use either workflow, not both. If the package transaction requires a full Arch system upgrade, review that separately before proceeding. No distribution upgrade is authorized or performed by this project.

[Swift.org](https://www.swift.org/install/linux/) documents Swiftly and official supported-distribution containers. For Arch, use the Arch-specific packaging guidance rather than silently selecting a different distribution's toolchain/dependencies. A container is an alternative if you already manage a container runtime; neither Docker nor Podman was found locally, and installing one would also require approval. See the container test command in [README.md](README.md).

## Validation records

The full suite of 49 XCTest methods has been run, not just XMLTests. All network transports are mocked; no physical switch requests were made. The compiler version, command, suite counts, successful exit status, direct FoundationXML probe and complete final test output are recorded in [VALIDATION_LOG.txt](VALIDATION_LOG.txt). The original missing-toolchain attempt is historical and is superseded by this successful run.

Linux tests cover the core only. The same XML regressions also belong to the generated iOS test target and must be run on Apple Foundation with Xcode. Linux cannot verify SwiftUI/UIKit type checking, code signing, local network permission or physical relay behavior.
