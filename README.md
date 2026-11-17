# LinkLoop

A tiny macOS menu bar app that turns links into a looping photo widget.

Copy a link to a Pinterest pin, an X (Twitter) post, an Instagram post or any image, click the menu bar icon, and choose **Add link from clipboard**. LinkLoop saves the image on your Mac and shows it in a small widget that slowly cycles through everything you've added.

- Native Swift + AppKit, one source file, no dependencies, no accounts, no API keys
- Images are cached locally, so the loop keeps working offline or if the post is deleted
- Lives in the menu bar only (no Dock icon)

## Features

- **Add images** from the clipboard, by typing or pasting a link, from an image file on your Mac, or by dragging a link or file onto the widget
- **X posts with several photos** add every photo, each with a small `2/4`-style badge. A `…/photo/3` link adds just that photo.
- **Widget** with zoom-to-fill or fit, size presets (Small, Medium, Large, Extra large) plus free resizing from the bottom-right corner, and a fade between images
- **Placement:** float above all windows, or keep it on the desktop behind your windows like Apple's desktop widgets
- **Interval** of 1, 3, 5 or 10 minutes, with optional shuffle
- **Click** the widget to open the original post. **Right-click** it for Next, Remove, Hide and widget options.
- **Launch at login** (on by default, can be turned off in the menu)
- **Small on disk:** images are resized to 1400px and saved as JPEG, about 150–200 KB each

## Requirements

- macOS 13 Ventura or later (Apple Silicon or Intel)
- Xcode Command Line Tools, to compile it:

  ```bash
  xcode-select --install
  ```

## Install

```bash
git clone https://github.com/zalhashemi/linkloop-widget.git
cd linkloop-widget
./build.sh
```

This builds `LinkLoop.app` in the same folder. You can run it from there, or move it to Applications first:

```bash
mv LinkLoop.app /Applications/
open /Applications/LinkLoop.app
```

The app is built and ad-hoc signed on your own Mac, so Gatekeeper doesn't block it.

If you move the app after its first launch, open the menu and click **Launch at login** off and back on, so macOS points to the new location.

## Usage

1. Copy a link (for example a Pinterest pin or an X post with a photo).
2. Click the LinkLoop icon in the menu bar.
3. Choose **Add link from clipboard**, or press `v` while the menu is open.

| Menu item | What it does |
|---|---|
| Add link from clipboard | Adds the link you copied |
| Add link… | Lets you type or paste a link |
| Add image file… | Adds pictures saved on your Mac (useful when Instagram blocks a link) |
| Show widget | Shows or hides the widget |
| Widget | Zoom to fill, size presets, float above windows or keep on desktop |
| Next image / Remove current image | Controls the slideshow |
| Shuffle, Interval | Order and speed of the loop |
| Launch at login | Starts LinkLoop when you log in |
| Open data folder | Shows where your images are saved |

## Supported links

| Link | How it works | Reliability |
|---|---|---|
| Direct image (`.jpg`, `.png`, `.webp`, `pinimg.com`, `pbs.twimg.com`) | Downloaded as is | Good |
| Pinterest (`pinterest.com/pin/…`, `pin.it/…`) | Reads the page's `og:image`, then tries the full-size original | Good |
| X / Twitter (`x.com`, `twitter.com`) | Uses the free [FxTwitter](https://github.com/FxEmbed/FxEmbed) API to list the post's photos | Good for public posts with photos. Text-only and video posts have no image. |
| Instagram | Reads the page's `og:image` | Often blocked. Save the image and use **Add image file…** instead. |
| Any other page | Reads the page's `og:image` | Depends on the site |

Websites change often. All link handling is in the `Resolver` section of `LinkLoop.swift`, so it's easy to fix when a site changes.

## Your data

Everything stays on your Mac, in `~/Library/Application Support/LinkLoop/`:

- `links.json`: the list of saved links
- `cache/`: the image files

To remove an image you can use **Remove current image**, or just delete its file from `cache/`. LinkLoop notices and drops it from the list.

LinkLoop only connects to the internet to fetch the links you add. There's no tracking and no analytics.

## Uninstall

1. Click **Launch at login** in the menu to turn it off, then **Quit LinkLoop**.
2. Delete `LinkLoop.app`.
3. Delete your saved images:

   ```bash
   rm -rf ~/Library/Application\ Support/LinkLoop
   defaults delete com.local.linkloop
   ```

## Testing the link resolver

The app has a self-test mode that fetches links and prints what it found, without changing your saved images:

```bash
./LinkLoop.app/Contents/MacOS/LinkLoop --selftest "https://www.pinterest.com/pin/2603712281386953/" "https://x.com/NASA/status/2051361508181856362"
```

## Note

LinkLoop is meant for personal use. Images are fetched from public pages and stored only on your Mac. Respect the terms of the sites you use it with and the rights of the people who made the images, and don't redistribute what you save.

## License

[MIT](LICENSE)
