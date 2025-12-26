# quick-look-step

> **_Fast_** QuickLook & Finder thumbnail support for STEP (`.step` / `.stp`) 3d model files on macOS.
>
> Built with Swift + SwiftUI, SceneKit, and [Formlabs/foxtrot](https://github.com/Formlabs/foxtrot).

## ✨ What does it do?

This allows you to **quickly** preview STEP files from Finder before opening them in your CAD tool. It will not render your STEP files as well as your CAD tool, but it will almost certainly open them faster!

https://github.com/user-attachments/assets/339781d5-3b7b-41c0-b411-d992e49ae5bc

## 🚧 Requirements

* macOS 14 (Sonoma) or newer
* M1 or above CPU (Apple Silicon)

## 💻 Installing

* Download the latest verison from [Releases](https://github.com/johnboiles/quick-look-step/releases) and unzip it
* Move `QuickLookStep.app` to Applications
* Open the `QuickLookStep.app`
* After a few seconds, a macOS notification appears saying an extension has added. Click this notification
  * If you miss the notification, open System Settings > General > Login Items and Extensions, then click the (i) next to QuickLookStep
* Turn the switch on for both options under QuickLookStep and click Done
* Open a Finder window and select a `.step` or `.stp` file. You should be able to preview it from Finder with Quick Look (using spacebar) or see the thumbnail in the sidebar in column view
* Close the app (it doesn't need to be open for the plugins to work)

## 🐞 Known issues

* Some STEP files don't load. The underlying [Foxtrot](https://github.com/Formlabs/foxtrot) library doesn't like them.
* Some STEP files have holes. Probably this is also a [Foxtrot](https://github.com/Formlabs/foxtrot) thing, but I could also be making a mistake in how I'm loading geometry to SceneKit. More testing against [Foxtrot](https://github.com/Formlabs/foxtrot) is needed. For this app, it's always better to be fast than perfect, but ideally it can be both 😀
* The examples in the [Foxtrot README.md](https://github.com/Formlabs/foxtrot/blob/master/README.md) suggests Foxtrot supports textures. I don't have that hooked up in SceneKit yet.
* Very large assemblies can take a long time to load and the extensions get stuck for a bit. Better timeouts could probably protect against this.

## 🔫 Troubleshooting

Mostly when I'm developing I sometimes get a stale version of the extension, or the extension doesn't load at all. When that happens I run this to do everything I know to do to clear the macOS cache.

```sh
pluginkit -r -u com.johnboiles.QuickLookStep.StepThumbnail
pluginkit -a /Applications/QuickLookStep.app
qlmanage -r
qlmanage -r cache
killall QuickLookUIService
killall Finder
```

## 🤝 Contributing

Let's make this better together. Issues and PRs are welcome.

This project is licensed under the terms of the **MIT License**. Do what you want with it but I don't guarantee it works.
