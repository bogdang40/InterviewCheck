# Abley floating glass

The approved Abley direction uses separate navigation, content and action dock surfaces, a forest and mint palette, ivory text and the character asset. The desktop remains visible through native materials. The limestone scene used in design previews is not an application background.

Editable design: [desktop](https://www.figma.com/design/m4zSmoMTmJx1EneM5fBhzy?node-id=8-6) and [compact](https://www.figma.com/design/m4zSmoMTmJx1EneM5fBhzy?node-id=23-33).

## Native implementation

`FloatingShellGeometry` places the retained navigation, pane and dock. The dock has the same width and horizontal edges as the pane. Glass and Liquid default to a border width of 6 points; saved custom optical recipes are preserved. Borders expand around content, and the empty gaps use native pointer routing with drag ownership preserved until release.

`FloatingGlassBackdrop` applies a single committed appearance snapshot to all three surfaces and the outer window geometry. Floating pane backgrounds use `NSVisualEffectView` with `underWindowBackground`, `behindWindow`, active state and no emphasis. This keeps the blur treatment stable when window focus changes. The existing Metal renderer still supplies the distinct Glass and Liquid rims. Legacy hosts retain their native glass behavior.

The floating surfaces use a literal forest tint of 24% to 36% and a fixed 3.5% grain. `SurfaceGrain` creates one cached sRGB texture shared by the surfaces. None retains an 84% to 92% reading veil and 2.5% grain. Accessibility preferences use a solid surface without grain. No texture animation or new rendering loop is introduced.

The app retains its existing navigation, streaming, cancellation, source and transcript actions, editing state and history flows. The character welcome presentation has 120 bundled frames and respects reduced motion. Sign in requests a welcome only after credential persistence succeeds; sign out and stale completions cannot replay it.

## Validation

The selected native preview was inspected while focused, after switching away, and after clicking back into the app. The user approved the resulting reading background. Wide and compact shell fixtures, geometry, style changes, grain pixels, appearance fallbacks, access persistence and welcome playback have focused XCTest coverage. Test storage is isolated before app startup and checked against the live storage fingerprint afterward.

Native focus testing needs an interactive foreground app. It is deliberately separate from ordinary render smoke tests:

```sh
TEST_RUNNER_MEMANAGER_NATIVE_FOCUS_SMOKE=1 ./scripts/test.sh \
  -only-testing:memanagerTests/OverlayGlassHostMaterialTests/testReadingMaterialSurvivesNativeKeyTransitionsWithoutChangingBlurOrEditorState
```

Production screen capture protection remains unchanged. Window raster images do not establish desktop transmission; the native preview and actual app are the relevant visual evidence. Full desktop input behavior is not inferred from a bitmap.

The final release was built and deployed with `scripts/build-release.sh`, then its installed signature and executable UUIDs were verified. The `memanager` shell alias opens `~/.memanager/memanager.app`. Close the previous process after a deployment before assessing the new build.
