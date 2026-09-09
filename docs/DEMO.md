# Play the local demo

Double-click **Play Demo.command** to rebuild and open the demo in Roblox Studio. Choose **Test → Play (F5)**, not Run/F8: the game needs a local player. The edit viewport starts empty because the server builds the world after joining.

The Landing contains the supply counters, NPCs and field gates. Gauntlet rounds field **4/6/8/10/12 bots**. Shoothouse is a separate four-stage course. Supply is free; skill rewards remain earned. Demo progress is temporary and resets with the session.

Use **Play.command** or `build/paintball-release.rbxlx` to test the full project. Ordinary Studio uses ProfileStore.Mock; only a private published save/shutdown/rejoin test verifies real persistence.

Current controls, changes, debug results and remaining playtest items are consolidated in the [change report](CHANGE_REPORT.md#playtest-and-release).

```sh
./"Play Demo.command" --build-only
lune run tools/check-all
```

Stop the test, rebuild and reopen after source changes. Generated places are outputs; author code and data in the repository. If startup fails, inspect Studio Output for the first error.
