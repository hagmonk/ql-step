# ql-step

> Quick Look & Finder thumbnail support for STEP (`.step` / `.stp`) CAD files
> on macOS, rendered with OpenCascade and SceneKit (Metal).

Press Space on any STEP file in Finder for an interactive 3D preview —
rotate, zoom, inspect — and get rendered thumbnails in Finder views. Neither
requires the app to be running.

## Architecture

```
.step file ──► occt-bridge (OpenCascade) ──► SceneBuilder (SceneKit/Metal)
               STEPCAFControl_Reader          PBR + image-based lighting
               XCAF colors & assemblies       OKLab legibility clamp
               BRepMesh tessellation          interactive preview / thumbnail
```

### Mesh backend: OpenCascade (`occt-bridge/`)

The bridge converts STEP to flat triangle/normal/color buffers over a C ABI:

* `STEPCAFControl_Reader` with color mode into an XCAF document — assemblies,
  instance placements, and per-face colors come from the reference STEP
  implementation, so output matches OCCT-based viewers by construction.
* `XCAFPrs::CollectStyleSettings` collects document styles, passed down to
  faces deepest-shape-type-first so a face-level style overrides its solid's.
* `BRepMesh_IncrementalMesh` (0.1 linear / 0.5 angular deflection)
  tessellates; per-face `Poly_Triangulation` is emitted with instance
  locations baked into points, normals rotated by the location transform and
  flipped for reversed faces, triangle winding corrected likewise.
* Colors are extracted as sRGB floats per vertex.

Load time for a ~75k-triangle assembly is ~1.3 s.

### Rendering (`QuickLookStep/SceneBuilder.swift`)

* **Physically-based materials** (roughness 0.55) lit by a procedural
  studio-dome gradient as the `lightingEnvironment` plus a directional
  headlight. Every orientation is lit coherently — orbiting the model in the
  preview can't drop faces into blackness.
* **OKLab legibility clamp.** Body colors are remapped in
  [OKLab](https://bottosson.github.io/posts/oklab/) with hue/chroma
  preserved: lightness is faithful across the midrange and softly compressed
  only at the extremes, so true black stays barely visible against a dark
  Quick Look panel and white powder-coat stays visible against light Finder
  backgrounds. Conversion is memoized per unique color.

### SceneKit/Quick Look facts encoded here

Each of these, violated, renders the model solid black or kills the
extension — they are easy to rediscover the hard way:

* `lightingEnvironment` textures must be **2:1 equirectangular**; any other
  aspect is silently ignored.
* Environment images must be drawn with **CoreGraphics** — AppKit
  `lockFocus` has no graphics context inside the sandboxed headless
  thumbnail extension and produces a dead texture.
* Under PBR, **omni light intensity is lumens with inverse-square falloff**;
  a camera-distance omni contributes ~nothing. Directional lights are lux
  with no falloff.
* The PBR shader reads **RGBA vertex colors**; a 3-component
  `SCNGeometrySource(.color)` leaves alpha at zero and multiplies the model
  to black (Blinn tolerates RGB).
* Re-signing the app **must preserve entitlements**
  (`codesign --preserve-metadata=entitlements`); stripping the app-sandbox
  entitlement makes pluginkit silently refuse to launch the extensions.
* `qlmanage -t` cannot exercise third-party thumbnail extensions ("No
  sandbox token"); test through `QLThumbnailGenerator` instead.

### Diagnostic parser (`foxtrot/`, `ffi/`)

A vendored Rust STEP parser/triangulator used only for diagnostics — the app
renders exclusively through the OpenCascade bridge.

```sh
cargo run --release -p foxtrot_ffi --example dump_colors \
  --target aarch64-apple-darwin -- file.stp
```

prints the unique vertex colors extracted from a file with counts. Note that
STEP files frequently declare more `COLOUR_RGB` entities than are visible:
interior components (contacts, wiring) carry styles too. Compare against
`dump_colors` output before assuming colors are being dropped.

## Requirements

* macOS 14.6 (Sonoma) or newer, Apple Silicon
* Building: Xcode, `brew install opencascade`, and a Rust toolchain +
  `cbindgen` (diagnostic parser only)

## Building & installing

```sh
make install        # builds everything, packages, copies to /Applications
```

which runs:

1. `make occt-bridge` — compiles `libocctbridge.dylib` against Homebrew
   OpenCascade.
2. `xcodebuild` (ad-hoc signed, arm64) — app + both extensions.
3. `occt-bridge/bundle-occt.sh` — copies the transitive OCCT dylib closure
   into `Contents/Frameworks`, rewrites Homebrew install names to `@rpath`,
   and re-signs everything inner-out preserving entitlements.

Open `QuickLookStep.app` once to register the extensions. If they don't
activate automatically: `System Settings` → `General` → `Login Items and
Extensions` → enable both under `QuickLookStep`.

## Usage

Select any `.step` / `.stp` file in Finder: Space for the interactive
preview, or see thumbnails in icon/column views. The app itself only needs
to be opened once, to register the extensions.

## Troubleshooting

Stale extension registrations and thumbnail caches cause most problems —
macOS will happily keep serving an old build's renders (even from copies in
the Trash, so empty it after deleting old versions). The full reset:

```sh
pluginkit -r -u com.johnboiles.QuickLookStep.StepThumbnail
pluginkit -r -u com.johnboiles.QuickLookStep.StepPreview
pluginkit -a /Applications/QuickLookStep.app
qlmanage -r
qlmanage -r cache
pluginkit -e use -i com.johnboiles.QuickLookStep.StepThumbnail
pluginkit -e use -i com.johnboiles.QuickLookStep.StepPreview
killall QuickLookUIService
killall Finder
```

When developing: never let pluginkit see the appex inside the xcodebuild
products directory — it can win the election over the `/Applications` copy.
Install, then delete the build products app.

## License

MIT.
