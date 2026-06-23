# ql-step

> Quick Look & Finder thumbnail support for STEP (`.step` / `.stp`) CAD files
> on macOS, rendered with OpenCascade and SceneKit (Metal).

Press Space on any STEP file in Finder for an interactive 3D preview —
rotate, zoom, inspect — and get rendered thumbnails in Finder views. Neither
requires the app to be running.

## Architecture

```
.step bytes/file ──► StepPreviewKit.framework ──► Quick Look adapters / host app
                     occt-bridge (OpenCascade)    interactive preview / thumbnail
                     SceneKit/Metal renderer
```

### Mesh backend: OpenCascade (`occt-bridge/`)

The bridge converts STEP to flat triangle/normal/color buffers over a private
C ABI used by `StepPreviewKit`:

* `STEPCAFControl_Reader` with color mode into an XCAF document — assemblies,
  instance placements, and per-face colors come from the reference STEP
  implementation, so output matches OCCT-based viewers by construction.
* `XCAFPrs::CollectStyleSettings` collects document styles, passed down to
  faces deepest-shape-type-first so a face-level style overrides its solid's.
* `BRepMesh_IncrementalMesh` tessellates with f3d's default OCCT settings
  (0.1 linear / 0.5 angular deflection) unless callers provide coarser
  `StepSceneLoader.Options`; per-face `Poly_Triangulation` is emitted with
  instance locations baked into points, normals rotated by the location
  transform and flipped for reversed faces, triangle winding corrected
  likewise.
* XCAF assembly leaf components are emitted as part slices alongside the flat
  mesh buffers. `StepPreviewKit` uses those slices to build one SceneKit node
  per component for interactive exploded views; files without useful assembly
  labels still render as one flattened part.
* Colors are extracted as sRGB floats per vertex.
* Faces without an OCCT surface style fall back to f3d's named preview grey
  (`f3d_grey`, `#545454`) instead of pure white.
* Both file paths and in-memory STEP bytes are supported. The byte path uses
  OpenCascade's `ReadStream`, so a Swift app can preview STEP data loaded from
  SQLite without writing a temporary `.step` file.

On the bundled 178CT fixture, the default settings emit 116,668 vertices /
133,099 triangles. `.fastPreview` emits 57,880 vertices / 58,469 triangles.

### Rendering (`QuickLookStep/StepPreviewKit/`)

* **Physically-based materials** (roughness 0.55) use the STEP vertex colors
  and OCCT face normals directly.
* **SceneKit SSAO and f3d-style lighting** improve legibility on single-color
  parts without replacing SceneKit with OCCT's viewer stack. The direct lights
  mirror f3d's default fallback path: VTK's `vtkLightKit` head/key/fill/back
  camera-relative light rig. Hard SceneKit shadow maps are intentionally off;
  f3d's OCCT config uses ambient occlusion as the depth cue, and cast shadows
  create distracting streaks on perforated CAD panels.
* **OKLab legibility clamp.** Body colors are remapped in
  [OKLab](https://bottosson.github.io/posts/oklab/) with hue/chroma
  preserved: lightness is faithful across the midrange and softly compressed
  only at the extremes, so true black stays barely visible against a dark
  Quick Look panel and white powder-coat stays visible against light Finder
  backgrounds. Conversion is memoized per unique color.
* **Shared preview surface.** The app host and Quick Look preview both use
  `StepPreviewContainerView` / `StepPreviewView` from `StepPreviewKit`; runtime
  background color, camera rig, exploded-view controls, reset behavior, and
  mouse/trackpad input should not be reimplemented in the adapters.
* **Exploded-view hierarchy.** Scenes contain a `step-model-root` node with
  geometry children named `step-part-N`. `StepPreviewView.setExplosionAmount`
  offsets those part nodes radially from the normalized model center; thumbnail
  rendering always forces the amount back to zero.

### SceneKit/Quick Look facts encoded here

Each of these, violated, renders the model solid black or kills the
extension — they are easy to rediscover the hard way:

* Under PBR, **directional lights are the predictable choice** for camera
  relative preview lighting. Camera-distance omni lights use inverse-square
  falloff and contribute almost nothing unless their lumen values are pushed
  very high.
* `SCNView.autoenablesDefaultLighting` must stay off; otherwise SceneKit adds
  a hidden light rig that diverges from the f3d-style lighting used for both
  previews and thumbnails.
* Hard SceneKit shadow maps are intentionally disabled. Screen-space ambient
  occlusion gives useful depth cues without the long black streaks cast
  shadows produce on perforated CAD panels.
* The PBR shader reads **RGBA vertex colors**; a 3-component
  `SCNGeometrySource(.color)` leaves alpha at zero and multiplies the model
  to black (Blinn tolerates RGB).
* Re-signing the app **must preserve entitlements**
  (`codesign --preserve-metadata=entitlements`); stripping the app-sandbox
  entitlement makes pluginkit silently refuse to launch the extensions.
* `qlmanage -t` cannot exercise third-party thumbnail extensions ("No
  sandbox token"); test through `QLThumbnailGenerator` instead.

Note on color coverage: STEP files frequently declare more `COLOUR_RGB`
entities than are visible — interior components (contacts, wiring) carry
styles too. Check what the file declares (`grep -c COLOUR_RGB file.stp`)
before assuming colors are being dropped.

### Reuse in a Swift app

The reusable surface is `StepPreviewKit.framework`; the Quick Look preview,
thumbnail extension, and "Open With QuickLookStep" app are thin adapters over
it.

```swift
import StepPreviewKit

let scene = try StepSceneLoader.scene(from: stepData, name: "part.step")
let view = StepPreviewView(scene: scene)
```

For file-backed content, use `StepSceneLoader.scene(fromFileAt:)`. For
off-screen thumbnails, use `StepThumbnailRenderer`.

`StepPreviewView` resets the camera each time a new scene is displayed. If you
embed AppKit directly, prefer `StepPreviewContainerView`; it includes the same
SceneKit view, full-rotation camera rig, double-click reset, mouse/trackpad
input, and conditional Explode slider used by the Quick Look extension and the
host app. Use `StepPreviewView.configuredSceneView()` or
`StepPreviewView.replaceWithConfiguredSceneView(_:)` only when you need the raw
`SCNView` without framework-owned controls.

Exploded view is preview-only. Use the SwiftUI wrapper's `explosionAmount`
parameter, `StepPreviewContainerView.setExplosionAmount(_:)`, or drive a raw
AppKit view/scene directly:

```swift
previewView.setExplosionAmount(0.6)
StepPreviewView.setExplosionAmount(0.6, in: scnView)
StepPreviewView.setExplosionAmount(0, in: scene)
```

For dense grids or canvases where close-up silhouette fidelity matters less
than throughput, use the coarser preset:

```swift
let scene = try StepSceneLoader.scene(
    from: stepData,
    name: "part.step",
    options: .fastPreview
)
```

The default tessellation mirrors f3d's OCCT settings (`0.1` linear / `0.5`
angular deflection). `.fastPreview` uses `0.5` / `1.0`, which cuts the
bundled 178CT fixture from 133,099 triangles to 58,469 triangles.

For high-throughput batch rendering, drive concurrency outside the framework
with a bounded worker pool. On the 16-logical-CPU development machine used for
profiling, `.fastPreview` scene creation on the 178CT fixture scaled from about
1.03 jobs/s at one worker to 2.78 jobs/s at four workers and 3.06 jobs/s at
eight workers; 16 workers dropped to 2.63 jobs/s. `Options` also exposes
`parallelMeshing`; the default remains `true` for single previews, but batch
callers can experiment with `false` if their files spend more time meshing than
STEP-transfer parsing:

```swift
let options = StepSceneLoader.Options(
    linearDeflection: 0.5,
    angularDeflection: 1.0,
    parallelMeshing: false
)
```

### Profiling

```sh
make bench
QLSTEP_PROFILE=1 swift run -c release StepPreviewBench path/to/part.stp 1 0
swift run -c release StepPreviewBench path/to/part.stp 5 1 0.5 1.0
swift run -c release StepPreviewBench parallel path/to/part.stp 8 32 0.5 1.0 scene-data
swift run -c release StepPreviewBench parallel path/to/part.stp 8 32 0.5 1.0 scene-data mesh-serial
```

`QLSTEP_PROFILE=1` prints the OCCT phase breakdown. `QLSTEP_LOG_LOADS=1`
re-enables per-load framework logging; it is off by default so bulk rendering
doesn't pay for `NSLog` on every scene.

## Requirements

* macOS 14.6 (Sonoma) or newer, Apple Silicon
* Building: Xcode and `brew install opencascade`

## Building & installing

```sh
make install        # builds everything, packages, copies to /Applications
make test           # builds the reusable framework tests
```

which runs:

1. `make occt-bridge` — compiles `libocctbridge.dylib` against Homebrew
   OpenCascade.
2. `xcodebuild` (ad-hoc signed, arm64) — `StepPreviewKit.framework`, app, and
   both extensions.
3. `occt-bridge/bundle-occt.sh` — copies the transitive OCCT dylib closure
   into `Contents/Frameworks`, rewrites Homebrew install names to `@rpath`,
   and re-signs everything inner-out preserving entitlements.
4. `scripts/register-quicklook.sh` — registers and enables both extensions,
   flushes Quick Look caches, and restarts the Quick Look services.

If the extensions still don't activate: `System Settings` → `General` →
`Login Items and Extensions` → enable both under `QuickLookStep`.

## Usage

Select any `.step` / `.stp` file in Finder: Space for the interactive
preview, or see thumbnails in icon/column views. The app itself only needs
to be opened once, to register the extensions.

Camera behavior:

* Opening or reopening a preview resets the camera to the model's default
  framed view.
* Double-click in the preview resets the camera in-place.
* Trackpad and left-mouse drag use ql-step's custom orbit rig, so pitch is not
  clamped at the top or bottom and can continue through a full rotation.
* Trackpad pinch zooms the camera in and out.
* Trackpad two-finger pan moves the camera target.
* Trackpad twist rolls the camera around the view axis.
* On a three-button mouse, middle-drag orbits around the camera Y axis,
  Shift+middle-drag pans, and Control+middle-drag or Option+middle-drag
  dollies.
* Shift+left-drag pans; Control+left-drag or Option+left-drag dollies.

Exploded view:

* The Quick Look preview and host app show an `Explode` slider only when the
  STEP file has multiple explodable parts.
* Slider value `0` is unexploded; dragging right spreads the parts outward.
* Finder thumbnails are always rendered non-exploded.

## Troubleshooting

Stale extension registrations and thumbnail caches cause most problems —
macOS will happily keep serving an old build's renders (even from copies in
the Trash, so empty it after deleting old versions). The fix:

```sh
make register       # or: ./scripts/register-quicklook.sh
```

which re-registers both extensions with pluginkit, flushes the Quick Look
caches (`qlmanage -r` / `qlmanage -r cache`), and restarts
`QuickLookUIService`, `quicklookd`, and Finder.

When developing: never let pluginkit see the appex inside the xcodebuild
products directory — it can win the election over the `/Applications` copy.
Install, then delete the build products app (`make install` handles this).

## License

MIT.
