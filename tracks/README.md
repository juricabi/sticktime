# Track gallery

Tracks for StickTime and StickTime BW that anyone can fly:

- **In the browser:** open the [emulator](https://juricabi.github.io/sticktime/) and go to **Tracks** → **Gallery**. **Fly it** flies a track straight away, and **Open** loads it into the track editor. From the editor, **Send to radio** or **Save file** puts it on your radio.
- **On the radio:** copy a `.txt` file from this folder to `/SCRIPTS/TOOLS/StickTimeTracks/` on the SD card as `c1.txt` … `c8.txt`. These are tracks 9 to 16 in the game. Restart StickTime to see it.

## Add your track

1. Make the track in the emulator's track editor (**Tracks**). Fly it a few times: the race should flow, and the editor's **Check** should say OK.
2. Click **Save file**. Rename the file to a short name of lowercase letters, digits and dashes, like `tracks/backyard-bando.txt`. Don't edit the file by hand: the id on its second line comes from its numbers. If they don't match, open the file in the editor and save it again.
3. Next to it, add `tracks/backyard-bando.json`:

   ```json
   {
     "by": "your name or handle",
     "about": "One or two sentences: what the track is like, what to look out for.",
     "source": "https://... (optional: where a real track's layout comes from)"
   }
   ```

4. Open a pull request with the two files. A check runs on the pull request: `python tools/gallery.py` checks the files, and `python test/gallery_test.py --tracks` has the game build each track in the emulator. Once the pull request is merged, the gallery on the site lists the track within a few minutes.

A few rules:
- The name (the file's first line, 16 characters at most) is what the game's track menu shows, so it must be different from the names already in the gallery.
- Send your own work, or the layout of a real track with its source linked.

## The MultiGP tracks

The MultiGP qualifier tracks of 2017 to 2026 are built from MultiGP's published diagrams. Each track's `source` links to its diagram. How they were converted:

- **Scale:** the whole layout is scaled 1.7x, because the game's gates are 3 m wide and MultiGP's are 5 ft.
- **Start:** gate 1 is the start/timing gate, and the game puts the start pad 14 m behind it.
- **Hurdles:** a hurdle becomes a high gate set just above the bar.
- **Loops:** where a pilot loops back through a tower or a row of gates in the same direction, the game flies a split-S or a weave instead, because its racing line can't loop.
- **Order:** the race order and directions come from the diagrams' numbered arrows. Diagrams without numbers were read from MultiGP's flight-path renders.

Every track was flown two laps with the game's autopilot without a hit.
