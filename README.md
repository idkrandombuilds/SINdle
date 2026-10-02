<p align="center">
  <img src="decoy-book/cover.jpg" width="320" alt="The decoy book">
</p>

<h1 align="center">SINdle</h1>
<p align="center"><b>A hidden private library for KOReader, behind the most boring book on your shelf.</b></p>

---

**What it does.** A dull decoy book sits in your normal library. Open it, enter your passcode, and KOReader's library switches to a hidden library of private books. Press the power button or Home, and everything snaps back to normal (customizable in settings). Private books never show up in history, continue, or reading statistics, and the folder is hidden while locked. Works with the ZenOS/Zen UI and Bookshelf plugins, or plain KOReader.

### Install

**Easiest: Storefront.** In KOReader's Storefront, search **SINdle** under patches, install, and restart KOReader. The decoy book is created in your library automatically.

**Or manually:** **[⬇ Download the latest SINdle zip](https://github.com/idkrandombuilds/SINdle/releases/latest)**, unzip it, then:

- Place `koreader/patches/2-sindle.lua` in your device's **`koreader/patches/`** folder (create `patches` if it doesn't exist).
- Restart KOReader. The decoy book appears in your library automatically (or copy one from `decoy-book/` yourself).

Then put your private books in **`koreader/system/`** (you can change this folder later).

### First use

- **Tap the decoy book.**
- **Set your passcode** (4–8 letters/numbers).
- **Change the security method via settings** if you like (more on that below).

### Security methods

- **Passcode** (default): enter your passcode to get in. A wrong passcode just closes the box.
  <br><img src="images/02-code-prompt.png" width="220" alt="Secret code prompt">
- **Secret button**: the decoy shows a fake *"Error, could not load book"*. Double-Tap the empty top-right corner of the box (circled in red here) to get in. X, OK or tapping outside just closes it.
  <br><img src="images/05-fake-error.png" width="220" alt="Fake error with the secret button marked">

### Settings

Tap the top of the screen to reveal KoReader's top menu, tap the gear <img src="images/gear.png" height="22" alt="gear icon">, then tap **Privacy**.
*Note: Privacy only appears while unlocked: in the private library and inside private books.*

### Features

- **Optional: Custom Decoy:** Privacy → Decoy book lets you pick any book you own. To edit the included one, open the EPUB in Calibre (Edit metadata / Edit book) or use the files in `decoy-book/source/`.
- **Alternate Private Library Folder:** Privacy → Private library folder. Hidden dot-folders like `.private` work too.
- **Lock with a gesture:** gear → Taps and gestures → Gesture manager → pick a gesture → General → **Lock now**. Handy with Bookshelf, which has no Home button.
- **Bookshelf:** unlocking shows the private library on Bookshelf's Home tab. If your Home tab is set to a fixed folder (or turned off), the private folder opens on the shelf instead.
- **For plugin makers:** other plugins can check whether the private library is open via the read-only `__SINDLE` table (`is_unlocked()`, `private_dir()`, `public_home_dir()`, `is_private(path)`). While locked it reveals nothing about the private folder.
- **Forgot your passcode:** Just delete `koreader/settings/private-code (delete to reset).lua` from a computer. Your books aren't touched.
- **Uninstall:** delete `2-sindle.lua` and restart KOReader.

### Disclaimer
- **Not encryption:** anyone with a computer and a USB cable can still see the files.

<sub>MIT licensed. See [LICENSE](LICENSE). Not affiliated with Amazon, KOReader, ZenOS or Bookshelf.</sub>
