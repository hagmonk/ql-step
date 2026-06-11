# ql-step

> **_Fast_** QuickLook & Finder thumbnail support for STEP (`.step` / `.stp`) 3d model files on macOS.
>
> Built with Swift + SwiftUI, SceneKit, and [Formlabs/foxtrot](https://github.com/Formlabs/foxtrot).

Fork of [johnboiles/quick-look-step](https://github.com/johnboiles/quick-look-step) (MIT).
Changes from upstream:

* **STEP colors render.** foxtrot already resolved `STYLED_ITEM`/`COLOUR_RGB`
  into per-vertex colors; the FFI layer dropped them. They now cross the
  boundary (`MeshSlice.colors`) and feed a `.color` `SCNGeometrySource`.
* **OKLab legibility squeeze.** Body colors are remapped in
  [OKLab](https://bottosson.github.io/posts/oklab/) so lightness lands in
  `[0.34, 0.82]` with hue/chroma preserved — pure-white powder-coat models stay
  visible on a light Finder background, black bodies stay visible in a dark
  Quick Look panel. Conversion is memoized per unique color.
* **foxtrot is vendored**, not a submodule, so parser/triangulator patches are
  ordinary commits in this repo.
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
