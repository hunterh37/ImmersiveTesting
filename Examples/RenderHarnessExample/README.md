# RenderHarnessExample

An iOS example app demonstrating `ImmersiveTestingRenderer`'s off-screen RealityView
render harness, with snapshot tests in `Tests/`.

Open `RenderHarnessExample.xcodeproj` directly. If you change `project.yml`, regenerate
the project with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
cd Examples/RenderHarnessExample
xcodegen generate
```

Run the `RenderHarnessExampleTests` test target on an iOS simulator to produce render snapshots.
