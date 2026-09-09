# Drop audio here

This is the staging folder for sound you supply yourself. Roblox cannot play a
file from disk — every sound has to be uploaded and referenced by asset id — so
this folder is the **before** step, and `Data/audio.json` is the **after** step.

The media files themselves are gitignored. This is an open-source repository and
music mixes are large binaries; the folder, this README and the structure are
tracked, the `.mp3`s are not. If you want a particular track committed, add an
exception to `.gitignore` deliberately.

```
assets/audio/
  music/   full-length mixes: hub, match, results
  sfx/     one-shots: the marker firing, paint hitting, a reload
```

## What the files have to be

Checked against [Roblox's audio asset
requirements](https://create.roblox.com/docs/audio/assets) on 2026-09-09:

| | |
| --- | --- |
| Formats | `.mp3`, `.ogg`, `.wav`, `.flac` |
| Size | under 20 MB |
| Length | under 7 minutes |
| Sample rate | 48 kHz or lower |
| Channels | mono, or stereo 2.0 / 3.0 / 5.1 |

Free uploads are capped per 30 days: **2,000 if you are ID-verified, 100 if you
are not.** That is not a limit this project will trouble.

## Royalty-free is not the same as clearable

Upload it only if one of these is true:

- you made it, or
- the licence permits commercial use **and** redistribution inside a game, and
  you have kept the licence text.

Roblox's Content Moderation applies to audio, and an experience earning Robux is
commercial use no matter how small it is. "Free to download" and "free to
publish inside a paid product" are different permissions and a lot of sites
blur them. Keep the licence file next to the mix — put it in `music/` beside
the track — so a question about it later has an answer.

Reasonable sources: Free Music Archive (check the per-track licence, they vary),
Incompetech, and Roblox's own Creator Store library, which needs no upload at
all — see below.

## Getting it into the game

1. Drop the file in `music/` or `sfx/`.
2. Upload it: [Creator Dashboard](https://create.roblox.com/dashboard/creations)
   → **Development Items** → **Audio** → **Upload Asset**. Or in Studio, the
   Asset Manager's bulk import.
3. Copy the asset id from the dashboard.
4. Paste it into `Data/audio.json` as the full string,
   `"rbxassetid://1234567890"` — into a `cues.<name>.soundId` for a one-shot, or
   into a `music.playlists.<context>` array for a track.
5. Rebuild and play. Nothing else needs wiring: every cue is already called from
   the right moment, and `lune run tools/check-audio` will tell you what is still
   silent.

## The shortcut, if you do not want to upload anything

Roblox's Creator Store carries **over 100,000 free-to-use sound effects and music
tracks**, usable without uploading anything of your own. In Studio: **View →
Toolbox → Marketplace → Audio**, search, audition, right-click → **Copy Asset
ID**, and paste it into `Data/audio.json`. Ten minutes there fills every cue in
the file.

## The trap that will waste your afternoon

**An asset id you found somewhere is not necessarily one you can use.** Roblox's
audio privacy rules mean private audio will not play in an experience whose
owner did not upload it — and it fails *silently*, and it fails **only when
published**. It will work perfectly in Studio.

So: use the Creator Store's free-to-use library or your own uploads, and confirm
sound in a **published test place**, not in Studio.
