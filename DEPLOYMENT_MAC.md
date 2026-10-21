# First Mac and iPhone deployment

This is a build handoff, not a record of a successful build. No Xcode build, code signing, installation or physical-device test has occurred in the Linux development environment.

## 1. Prepare the borrowed Mac

Use full Xcode 15 or later with a compatible iOS SDK; the project targets iPhone with iOS 17 or later and Swift 5 language mode (Swift 5.9+ compiler). Open Xcode once to finish its own SDK/license setup. Ensure `xcode-select -p` selects that Xcode installation, not only Command Line Tools. The Mac and your iPhone must be trusted for local development, and the phone must support the selected deployment target.

Copy the complete `wemo-home` directory to the Mac. You do not need `wemo-research`, private research evidence or any credentials from Linux.

Install XcodeGen deliberately on the Mac using your preferred supported method. With Homebrew already installed, the usual command is:

```bash
brew install xcodegen
xcodegen --version
```

The spec requires XcodeGen 2.44.0 or later. Record the exact Xcode and XcodeGen versions used for the first build. The generator is a development tool, not an app dependency. See [XcodeGen installation](https://github.com/yonaskolb/XcodeGen#installing) and [project spec](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md).

## 2. Generate and check without signing

```bash
cd /path/to/wemo-home
swift --version
./scripts/test-core.sh
xcodegen generate --spec project.yml
xcodebuild -list -project WemoHome.xcodeproj
xcodebuild -project WemoHome.xcodeproj -scheme WemoHome \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

No remote package resolution should be needed: `WemoHomeCore` is the local `Package.swift` in this directory. XcodeGen reads the committed static Info.plist via `INFOPLIST_FILE`; it does not generate or replace its privacy policy. The tracked `Config/Signing.xcconfig` optionally includes an ignored `Local.xcconfig`. That local file may be absent for an unsigned simulator build.

To run the same core tests through Xcode's iOS simulator test target, find an available iPhone simulator first:

```bash
xcrun simctl list devices available
xcodebuild -project WemoHome.xcodeproj -scheme WemoHome \
  -destination 'platform=iOS Simulator,id=REPLACE_WITH_SIMULATOR_UDID' \
  CODE_SIGNING_ALLOWED=NO test
```

Alternatively open `WemoHome.xcodeproj`, select an installed iPhone simulator, and use Product > Test. All unit tests use mocks. A simulator build/test does not validate iPhone Local Network permission, Wi-Fi routing, signing or hardware operation. Launching the actual app, including on a simulator, issues real reads to the configured private IP; do not tap its power control until the owner has approved that integration test.

## 3. Configure personal signing

On the Mac, copy the example only when ready to fill it in:

```bash
cp Local.xcconfig.example Local.xcconfig
open WemoHome.xcodeproj
```

Replace `YOUR_TEAM_ID` and `com.yourname.WemoHome` in `Local.xcconfig` with your own Team ID and unique bundle identifier. `DEVELOPMENT_TEAM` is a public identifier, not an authentication secret. Keep all Apple login credentials, signing private keys, certificates and provisioning management in Xcode/macOS Keychain. No private credential belongs in this repository.

In Xcode Settings > Accounts, sign in with the developer account on the borrowed Mac. Under the **WemoHome** target's Signing & Capabilities, select the available Apple Developer Program team and automatic signing. Confirm the resolved bundle identifier matches your local override. If Xcode writes signing changes into the generated project, it is still disposable; put durable public build overrides in `Local.xcconfig`, then regenerate. No multicast or other special capability is required.

Connect and unlock the iPhone, trust the Mac, and enable Developer Mode if iOS requests it. Select the physical phone as the run destination. Choose Product > Build first, then Product > Run to install and launch. Allow any normal Xcode provisioning prompts using your account on the Mac.

Optional signed device build from Terminal, after setup in Xcode:

```bash
xcrun devicectl list devices
xcodebuild -project WemoHome.xcodeproj -scheme WemoHome \
  -configuration Debug -destination 'id=REPLACE_WITH_DEVICE_UDID' \
  -derivedDataPath DerivedData -allowProvisioningUpdates build
xcrun devicectl device install app --device REPLACE_WITH_DEVICE_UDID \
  DerivedData/Build/Products/Debug-iphoneos/WemoHome.app
```

`Product > Run` in Xcode is the simpler first installation path. This project has no App Store/TestFlight publishing setup.

## 4. First read-only iPhone validation

Connect the phone to the same home Wi-Fi as Rayns. Check that the switch still uses the expected address and HTTP port; a router DHCP reservation can help, but the app does not configure one. Avoid a guest network with client isolation.

1. Launch Wemo Home and allow the Local Network privacy prompt. The first network operation is a setup/state read.
2. Confirm Rayns shows Online and the current ON/OFF state. Compare with the physical light. The large control remains disabled while the state is unknown or a request is pending.
3. Open Settings. Confirm or edit `192.168.4.28` and `49153`, then tap **Save & Test Connection**. This persists the fields and reads identity/state; it does not toggle the light. Confirm model and firmware come from the response.
4. Use manual refresh, background/foreground the app, and dismiss Settings. Confirm the main screen refreshes immediately and polls every 15 seconds while visible. It must show Unknown after suspension until a fresh read completes.
5. Check permission denied/offline behavior by changing the app's Local Network setting or disconnecting the phone from Wi-Fi. Confirm a readable error, unknown light state and disabled control. Restore permission/Wi-Fi and refresh. A timeout alone does not identify permission denial.
6. Check both light/dark appearance, large Dynamic Type, and VoiceOver. Connection status must be understandable without color; errors must be readable by VoiceOver.

Apple explains the privacy setting in [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy). If access fails, confirm **Settings > Privacy & Security > Local Network > Wemo Home**, the saved address/port, Wi-Fi routing and client isolation. Do not broaden ATS to globally allow internet HTTP. The local HTTP policy is in `App/Info.plist`; validate it on the target iOS release.

## 5. Owner-approved control integration test

Do this only after the owner explicitly approves a test that physically changes the light. Approval to build/install or run mocked tests alone is not approval for device-changing requests.

Record the observed starting state and the approved desired state. Tap the large control once. Verify the physical transition and that the UI displays the state from the subsequent GetBinaryState read. If the command times out, refresh to learn the state before deciding whether to send anything else; never assume timeout means the relay did not change. If returning to the starting state is desired, include that second command in the approved test scope.

Do not send rules uploads, scheduling commands, TimeSync, firmware updates or configuration changes. Do not create a port-forwarding rule or expose this client/device over the public internet.

Record date, Xcode/Swift/XcodeGen versions, iPhone/iOS version, build/test results, permission behavior and physically observed control results in `DEVELOPMENT_STATUS.md`. Only after a successful Xcode build and physical test should the project be described as compiling and working on an iPhone.

## 6. Finish on the borrowed Mac

Keep the installed app and source copy you need. Sign out of the developer account when finished and handle any locally created certificates/keys according to your account's normal practice. Do not copy Keychain contents, signing credentials or private provisioning material into this source tree.
