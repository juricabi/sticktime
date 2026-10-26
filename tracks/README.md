# Track gallery

Tracks for StickTime and StickTime BW that anyone can fly. A bigger track (its card says *color radios*) needs StickTime 1.8.0 or later on a color radio: StickTime BW doesn't list it. A track with scenery (props, rails, decals) needs StickTime 1.10.0 or later (StickTime BW flies its gates and structures), a bigger one with scenery 1.10.0 on a color radio.

- **In the browser:** open the [emulator](https://juricabi.github.io/sticktime/) and go to **Tracks** → **Open**, then **Open** a track of the Gallery. In the editor, **Send to emulator** and **Fly c1** fly it, and **Send to radio** or **Save file** puts it on your radio.
- **On the radio:** copy a `.txt` file from this folder to `/SCRIPTS/TOOLS/StickTimeTracks/` on the SD card as `c1.txt` … `c8.txt`. These are tracks 9 to 16 in the game. Restart StickTime to see it.

## Add your track

1. Make the track in the emulator's track editor (**Tracks**). Give it a name of its own (not a built-in track's name, and not the editor's "My Track" or "My Meadow" and so on). Fly it a few times: the race should flow, and the editor's **Check** should say OK.
2. Click **Save file**. Rename the file to a short name of lowercase letters, digits and dashes, like `tracks/backyard-bando.txt`. Don't edit the file by hand: the id on its second line comes from its numbers. If they don't match, open the file in the editor and save it again.
3. Next to it, add `tracks/backyard-bando.json`:

   ```json
   {
     "by": "your name or handle",
     "about": "One or two sentences: what the track is like, what to look out for.",
     "source": "https://... (optional: where a real track's layout comes from)"
   }
   ```

   `about` and `source` are optional: leave a key out rather than give it an empty text. `python tools/gallery.py` checks the files the way the pull request's check does.

4. Open a pull request with the two files. A check runs on the pull request: `python tools/gallery.py` checks the files, and `python test/gallery_test.py --tracks` has the game build each track in the emulator. (A first pull request to the repo waits for the maintainer to let the check run.) Once the pull request is merged, the gallery on the site lists the track within a few minutes.

A few rules:
- The name (the file's first line, 16 characters at most) is what the game's track menu shows, so it must be different from the names already in the gallery and from the game's own tracks (and the editor's names for a new track: My Track, My Meadow, ...).
- Send your own work, or the layout of a real track with its source linked.
- A track with more than 24 gates, 16 structures or 999 bytes is a bigger track (format 2: up to 48 gates, 64 structures and 5999 bytes). Only StickTime 1.8.0 or later on a color radio flies it; StickTime BW and older versions don't list it. Keep it light enough for a TX16S: fly it in the emulator on the TX16S with **Radio load** on, and keep the busiest views near 50 ms.
- A track with scenery (props, rails, decals, or structures in the colors added in 1.10.0) is format 3: up to 24 gates, 16 structures, 32 props, 12 rails, 8 decals and 1599 bytes, for StickTime 1.10.0 or later on a color radio (StickTime BW flies its gates and structures, without the scenery). A bigger one is format 4: up to 48 gates, 64 structures, 128 props, 32 rails, 32 decals and 9999 bytes, for StickTime 1.10.0 or later on a color radio. Earlier versions don't list either. Keep props and rails off the racing line: the editor's **Check** says where they're in the way.

## The MultiGP tracks

The MultiGP qualifier tracks of 2017 to 2026 are built from MultiGP's published diagrams. Each track's `source` links to its diagram. How they were converted:

- **Scale:** the whole layout is scaled 1.7x, because the game's gates are 3 m wide and MultiGP's are 5 ft.
- **Start:** gate 1 is the start/timing gate, and the game puts the start pad 14 m behind it.
- **Hurdles:** a hurdle becomes a high gate set just above the bar.
- **Loops:** where a pilot loops back through a tower or a row of gates in the same direction, the game flies a split-S or a weave instead, because its racing line can't loop.
- **Order:** the race order and directions come from the diagrams' numbered arrows. Diagrams without numbers were read from MultiGP's flight-path renders.

Every track was flown two laps with the game's autopilot without a hit.

For the maintainer: the check runs the pull request's own copy of `tools/gallery.py` and `test/gallery_test.py`, so look at any change to those (or to `.github/`) in a track's pull request.
