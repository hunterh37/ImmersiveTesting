// Re-export the XCTest-free runtime so existing test code that `import ImmersiveTesting`
// continues to see `TestScene`, the provider protocols, fakes, `SceneEnvironment`, and
// `SceneBuilder` through a single import. Production targets import `ImmersiveTestingRuntime`
// directly (no XCTest).
@_exported import ImmersiveTestingRuntime
