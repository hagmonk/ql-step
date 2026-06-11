# ql-step

> **_Fast_** QuickLook & Finder thumbnail support for STEP (`.step` / `.stp`) 3d model files on macOS.
>
> Built with Swift + SwiftUI, SceneKit, and [Formlabs/foxtrot](https://github.com/Formlabs/foxtrot).

Fork of [johnboiles/quick-look-step](https://github.com/johnboiles/quick-look-step) (MIT).
Changes from upstream:

* **The mesh backend is OpenCascade** (`occt-bridge/`), the same engine f3d
  uses — so geometry, assembly placement, and colors match f3d by
  construction. The bridge mirrors f3d's `vtkF3DOCCTReader`:
  `STEPCAFControl_Reader` with color mode into an XCAF document,
  `XCAFPrs::CollectStyleSettings` passed down to faces,
  `BRepMesh_IncrementalMesh` (0.1 linear / 0.5 angular deflection), per-face
  `Poly_Triangulation` with instance locations baked into points. Building
  requires `brew install opencascade`; the needed OCCT dylibs are bundled
  into the app's `Contents/Frameworks` by `occt-bridge/bundle-occt.sh`
  (which preserves the sandbox entitlements Quick Look requires when
  re-signing). Apple Silicon only. Load time for a ~75k-triangle assembly
  is ~1.3 s — slower than foxtrot, but correct.
* **Vendored foxtrot remains** as a diagnostic backend
  (`ffi/examples/dump_colors.rs`) with the fixes below, but the app no
  longer renders with it: its custom triangulator corrupts swept/NURBS
  surfaces (e.g. coiled power cords) and its style resolution is partial.
* **STEP colors render.** foxtrot already resolved `STYLED_ITEM`/`COLOUR_RGB`
  into per-vertex colors; the FFI layer dropped them. They now cross the
  boundary (`MeshSlice.colors`) and feed a `.color` `SCNGeometrySource`.
* **OKLab legibility clamp.** Body colors are remapped in
  [OKLab](https://bottosson.github.io/posts/oklab/): lightness passes through
  unchanged across the legible midrange and is compressed only at the
  extremes, hue/chroma preserved — a black power cord still reads black next
  to a gray body, but pure black stays visible against a dark Quick Look
  panel and white powder-coat stays visible against light Finder backgrounds.
  Conversion is memoized per unique color.
* **foxtrot is vendored**, not a submodule, so parser/triangulator patches are
  ordinary commits in this repo.
* **Assembly traversal follows OCCT semantics** (the reference STEP reader
  behind f3d, `STEPControl_ActorRead`), not argument-order guessing:
  - Instance edges wrapped in `CONTEXT_DEPENDENT_SHAPE_REPRESENTATION` take
    parent/child orientation from the `NEXT_ASSEMBLY_USAGE_OCCURRENCE`
    product hierarchy, with per-edge reversal + inverted transform when the
    SRR contradicts the NAUO (OCCT `CheckSRRReversesNAUO`).
  - `ITEM_DEFINED_TRANSFORMATION` axis placements are validated against
    their representations' item lists and swapped when crossed (OCCT's
    TEST_MCI_2.step workaround).
  - Plain transform-free `SHAPE_REPRESENTATION_RELATIONSHIP`s merge both
    representations into one component ("on prend les 2"), so traversal
    reaches geometry on either side regardless of argument order. foxtrot
    previously trusted `rep_1 -> rep_2`, dead-ended at part frames for
    exporters that write `(brep rep, part frame)`, and fell back to drawing
    each unique solid once at the origin.
  The legacy flip-whole-graph heuristic survives only for files that provide
  no NAUO hierarchy.
* **Per-face colors.** Vendored foxtrot originally only honored `STYLED_ITEM`s
  that (a) pointed at a whole solid and (b) carried exactly one style — in
  real AP214 exports most styles target individual `ADVANCED_FACE`s (a black
  body with a green LED face and brass contact faces). Style resolution now
  scans every style at each level and face-level colors override the parent
  solid's.
* `ffi/examples/dump_colors.rs` prints the unique vertex colors foxtrot
  extracts from a file (with counts) for debugging color coverage.
* `QuickLookStep/libfoxtrot_universal.a` is no longer committed; build it with
  `make libfoxtrot_universal.a` before `make xcodebuild`.

Note on color coverage: STEP files frequently declare more `COLOUR_RGB`
entities than are visible — interior components (contacts, wiring) carry
styles too. Compare against `dump_colors` output before assuming colors are
being dropped.

## ✨ What does it do?

This allows you to **quickly** preview STEP files from Finder before opening them in your CAD tool. It will not render your STEP files as well as your CAD tool, but it will almost certainly open them faster!

https://github.com/user-attachments/assets/339781d5-3b7b-41c0-b411-d992e49ae5bc

## 🚧 Requirements

* macOS 14.6 (Sonoma) or newer
* M1 or above CPU (Apple Silicon)

## 💻 Installing

You can either download `QuickLookStep.app` from the [Releases page](https://github.com/johnboiles/quick-look-step/releases) or via Homebrew:

```sh
brew tap johnboiles/homebrew-tap
brew install quicklookstep
```

After installing, open `QuickLookStep.app` once to enable the extensions.

If for some reason the extensions aren't enabled automatically:
* Open `System Settings` > `General` > `Login Items and Extensions`
* Click the (i) next to `QuickLookStep`
* Turn the switch on for both options under `QuickLookStep`
* Cick `Done`

## 🕶️ Usage

Open a Finder window and select a `.step` or `.stp` file. You should be able to preview it from Finder with Quick Look (using spacebar) or see the thumbnail in the sidebar in column view. `QuickLookStep.app` does _not_ need to be open for the extensions to work.

## 🐞 Known issues

* Some STEP files don't load. The underlying [Foxtrot](https://github.com/Formlabs/foxtrot) library doesn't like them.
* Some STEP files have holes. Probably this is also a [Foxtrot](https://github.com/Formlabs/foxtrot) thing, but I could also be making a mistake in how I'm loading geometry to SceneKit. More testing against [Foxtrot](https://github.com/Formlabs/foxtrot) is needed. For this app, it's always better to be fast than perfect, but ideally it can be both 😀
* The examples in the [Foxtrot README.md](https://github.com/Formlabs/foxtrot/blob/master/README.md) suggests Foxtrot supports textures. I don't have that hooked up in SceneKit yet.
* Very large assemblies can take a long time to load and the extensions get stuck for a bit. Better timeouts could probably protect against this.

## 🔫 Troubleshooting

If you used older versions of `QuickLookStep.app` (especially <v1.5), make sure to delete them and to empty trash (`Finder` -> `Empty Trash...`). I've noticed macOS will sometimes try to use old extensions from the Trash! Then you should restart Finder:

```sh
killall Finder
```

If restarting Finder doesn't make it work, I run this to do everything I know to do to clear the macOS cache:

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

And of course rebooting is also worth trying!

## 🤝 Contributing

Let's make this better together. Issues and PRs are welcome.

This project is licensed under the terms of the **MIT License**. Do what you want with it but I don't guarantee it works. If you do something neat with it, I'd always appreciate a shoutout!
