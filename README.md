

<p align="center">
  <img src="docs/icon.png" width="160" alt="Convert Anything app icon">
</p>

<h1 align="center">Convert Anything</h1>

<p align="center">
  <b>Convert any file on your Mac by renaming it.</b><br>
  Change <code>notes.md</code> to <code>notes.pdf</code>, <code>photo.heic</code> to <code>photo.jpg</code>
  or <code>presentation.pptx</code> to <code>presentation.txt</code>, and it's converted in place.
</p>

<p align="center">
  <a href="https://github.com/JayBirdZhang/convert-anything/releases/latest/download/Convert-Anything.dmg">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/download-dark.svg">
      <img src="docs/download-light.svg" width="330" alt="Download Convert Anything for Mac">
    </picture>
  </a>
</p>

<p align="center">
  <a href="../../releases/latest"><img src="docs/badge-release.svg" height="28" alt="Release v1.4"></a>
  <img src="docs/badge-macos.svg" height="28" alt="macOS 14 or later">
  <img src="docs/badge-chip.svg" height="28" alt="Runs on Apple Silicon and Intel">
  <a href="LICENSE"><img src="docs/badge-license.svg" height="28" alt="License: GPL-3.0"></a>
</p>

https://github.com/user-attachments/assets/cd589974-3f86-4b3d-a146-ac4dc21ce3fd

## Features

- **Just rename it.** That's all you have to do to convert a file.
- **Lives in the menu bar.** Watches the folders you choose (Desktop, Documents and Downloads by default).
- **Private.** Everything runs on your Mac: no uploads, no accounts, all offline.
- **Undo by renaming back.** Change the extension back or just ⌘ + Z to get the original.
- **Many files at once.** Select them, right-click → Rename..., and replace the extension.
- **Or right-click → Convert to.** A Finder menu with the formats each file can become, in any folder.
- **History by day.** Recent conversions in the menu, color-coded by kind of file.
- **Updates itself** with [Sparkle](https://sparkle-project.org).

## Supported formats

| Kind | Formats |
|---|---|
| **Images** | PNG, JPEG, HEIC, TIFF, GIF, BMP, WebP, AVIF, ICO, ICNS (app icons), TGA. Convert *from* but not to: camera RAW (CR2, CR3, NEF, ARW, DNG, RAF, ORF, RW2, PEF, SRW), Photoshop (PSD), SVG and JPEG XL (to JPEG XL only where macOS can write it) |
| **Documents** | PDF, Markdown, TXT, HTML, Word (.docx/.doc), RTF, ODT, Pages, EPUB, PowerPoint (.pptx/.ppt), Keynote |
| **Spreadsheets** | Excel (.xlsx/.xls), CSV, Numbers, JSON |
| **Audio** | MP3, WAV, M4A, AAC, FLAC, Ogg, Opus, AIFF |
| **Video** | MP4, MOV, M4V, and video → GIF |
| **Transcripts** | Audio or video → TXT, SRT or WebVTT (.vtt) subtitles; SRT ↔ WebVTT; subtitles → TXT or any document format |

Click **Formats** at the bottom of the menu to see every conversion. (Pretty much anything you can think of is convertible.)

## Install

1. Download `Convert-Anything.dmg` from the [latest release](../../releases/latest) and open it.
2. Drag **Convert Anything** into the Applications folder.
3. Open the app. MacOS blocks it when you first open it because it isn't from the App Store.
   Click **Done**, then open **System Settings → Privacy & Security**, scroll down and click
   **Open Anyway** next to "Convert Anything was blocked". You only need to do this once.

   <p align="center">
     <img src="docs/open-anyway.gif" width="680" alt="Opening Convert Anything the first time: System Settings → Privacy &amp; Security → Open Anyway">
   </p>

4. Turn off Finder's extension warning so renaming converts straight away. Otherwise Finder asks
   "Are you sure you want to change the extension?" every time you rename a file.
   Open **Finder → Settings → Advanced** and uncheck **Show warning before changing an extension**.

   <p align="center">
     <img src="docs/finder.gif" width="680" alt="Finder Settings → Advanced: unchecking Show warning before changing an extension">
   </p>

<details>
<summary>No "Open Anyway" button?</summary>

Paste this into Terminal:

```bash
xattr -dr com.apple.quarantine "/Applications/Convert Anything.app"
```
</details>

Requires macOS 14 (Sonoma) or later, on Apple Silicon or Intel.

## Usage

1. Click the prism icon in the menu bar. Add or remove watched folders under **Settings**.
2. In a watched folder, rename a file to the extension you want, for example `report.docx` → `report.pdf`.
3. The converted file appears in place and shows up in the menu's history.

Allow notifications when asked, and turn on **Open at login** if you want it always running.

Hint: To convert multiple files at once, select them, right-click → Rename..., and replace the extension.

Prefer a menu? Right-click files in Finder and choose **Convert to**. It lists what they can become, the likely ones first, and converts them just like a rename. Turn it on once under **Settings → Finder menu** (it opens System Settings → General → Login Items & Extensions → Finder).

## FAQ

**Do my files leave my Mac?**
No. Conversions use macOS's own frameworks plus two small bundled libraries and are all offline. Nothing is uploaded.

**Do I need Microsoft Office?**
No. Keynote, Pages and Numbers (free from Apple) are optional but give the best results for
PowerPoint → PDF and Word → PDF, and Numbers is needed for Excel → PDF. The first time the app uses
one, macOS asks for permission to control it: click **OK**.

**How do updates work?**
About once a day the app checks this repository's latest release and offers to install it.
Turn that off or check it yourself under **Settings → Updates**.

## License

Copyright (C) 2026 JayBirdZhang.

Convert Anything is free software: you can redistribute it and/or modify it under the terms of the
[GNU General Public License](LICENSE) as published by the Free Software Foundation, either version 3
of the License, or (at your option) any later version. It is distributed in the hope that it will be
useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
A PARTICULAR PURPOSE. See the GNU General Public License for more details.

In short: you may use, change and share it, even for money, but anything you distribute that is
based on it must also be released under the GPL with its full source code.

The bundled libraries keep their own licenses (LAME: LGPL 2; libwebp: BSD 3-Clause; Sparkle: MIT); see
[ThirdPartyNotices.txt](Convert%20Anything/ThirdPartyNotices.txt). The name "Convert Anything" and
the app icon are not covered by the license.
