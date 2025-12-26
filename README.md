# quick-look-step

> QuickLook & Finder thumbnail support for STEP (`.step` / `.stp`) 3d model files on macOS.
>
> Built with Swift + SwiftUI, SceneKit, and [foxtrot](https://github.com/Formlabs/foxtrot).

https://github.com/user-attachments/assets/339781d5-3b7b-41c0-b411-d992e49ae5bc

## ✨ What does it do?

* **Quick Look Preview** – Press spacebar in Finder to open an interactive 3d preview of the file (similar to the built-in preview for STL files).
* **Finder Thumbnails** – Generates a raster thumbnail for every STEP file in Finder.
* **STEP viewer app** – A tiny SwiftUI host app lets you drag-and-drop a STEP file to view it. This mostly exists because the preview and thumbnail extensions need to be bundled inside a `.app`.

Because [foxtrot](https://github.com/Formlabs/foxtrot) is neat and very fast, even fairly complex assemblies can be previewed quickly.

## 🚧 Requirements

* macOS 14 (Sonoma) or newer
* M1 or above CPU (Apple Silicon)

## 💻 Installing

* Download the latest verison from [Releases](https://github.com/johnboiles/quick-look-step/releases) and unzip it
* Move QuickLookStep.app to Applications
* Open the QuickLookStep.app
* After a few seconds, a macOS notification appears saying an extension has added. Click this notification.
  * If you miss the notification, open System Settings > General > Login Items and Extensions, then click the (i) next to QuickLookStep.
* Turn the switch on for both options under QuickLookStep and click Done
* Open a Finder window and select a `.step` or `.stp` file. You should be able to preview it with Quick Look (using spacebar) it or see the thumbnail in the sidebar in column view.
* Close the app (it doesn't need to be open for the plugins to work)

## 🛠️ How it works

1. A small Rust crate (shipped pre-built as `libfoxtrot_universal.a`) parses the STEP file and exposes raw vertex/index buffers via a C-compatible FFI declared in `foxtrot.h`.
2. `SceneBuilder.swift` converts those buffers into a `SCNScene`, applies reasonable lighting, and positions a camera so the whole model fits on screen.
3. The scene is consumed by three targets:
   * **`StepThumbnail.appex`** – Renders the scene off-screen to produce the Finder thumbnail.
   * **`StepPreview.appex`** – Embeds an interactive `SCNView` for the Quick Look preview.
   * **`QuickLookStep` macOS app** – Convenient wrapper around the same scene useful during development and as a fallback viewer.

This app is intentionally very simple. macOS has similar built-in support for previewing STL files and I tried to keep this app as-similar-as-possible to that in appearance and feel.

## 🐞 Known issues

* Some STEP files don't load. The underlying [foxtrot](https://github.com/Formlabs/foxtrot) library doesn't like them.
* Some STEP files don't render perfectly. Probably this is also a foxtrot thing, but I could be making a mistake in how I'm loading geometry to SceneKit. More testing against foxtrot is needed. For this app, it's always better to be fast than perfect, but ideally it can be both 😀
* Very large assemblies can take a long time to load and the extensions get stuck for a bit. Better timeouts could probably protect against this.

## 🤝 Contributing

Let's make this better together. Issues and PRs are welcome.

This project is licensed under the terms of the **MIT License**. Do what you want with it but I don't guarantee it works.
