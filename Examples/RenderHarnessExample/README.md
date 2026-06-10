# RenderHarnessExample

An iOS example app demonstrating `ImmersiveTestingRenderer`'s off-screen RealityView
render harness, with snapshot tests in `Tests/`.

The Xcode project is not checked in — generate it from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
cd Examples/RenderHarnessExample
xcodegen generate
open RenderHarnessExample.xcodeproj
```

Run the `RenderHarnessExampleTests` test target on an iOS simulator to produce render snapshots.
