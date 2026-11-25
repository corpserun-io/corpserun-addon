# CorpseRun addon

Records your PvP kills and deaths in game so you can post them to
[corpserun.io](https://corpserun.io). Works on WoW Forever, Classic Era /
Anniversary, Progression Classic and Retail, in battlegrounds and world PvP.

## Install

1. **Close WoW** (or at least log out to the character screen).
2. Find your game's AddOns folder. It's inside the folder for the version you
   play:

   | Version | Folder |
   | --- | --- |
   | WoW Forever | `_forever_` |
   | Classic Era | `_classic_era_` |
   | Anniversary | `_anniversary_` |
   | Progression Classic | `_classic_` |
   | Retail | `_retail_` |

   - **Windows:** `C:\Program Files (x86)\World of Warcraft\<version>\Interface\AddOns\`
   - **Mac:** `/Applications/World of Warcraft/<version>/Interface/AddOns/`

   If `Interface` or `AddOns` doesn't exist yet, create it.
3. Copy the whole **`CorpseRun`** folder into `AddOns`. You should end up with
   `AddOns/CorpseRun/CorpseRun.toc`, not `AddOns/CorpseRun/CorpseRun/…`. If
   unzipping gave you a folder inside a folder, move the inner one.
4. Start WoW. On the character screen click **AddOns** (bottom left) and make
   sure **CorpseRun** is ticked.
5. Log in. You'll see `[CorpseRun] Loaded…` in chat.

## Set up exports (once)

Exports are signed so nobody can post kills in your name.

1. Log in at [corpserun.io](https://corpserun.io) with Battle.net.
2. Open **API tokens** and create a token.
3. Click **Copy command** and paste it into WoW chat. It looks like
   `/cr key wkb_…`.

That's it for every character on your account. Only a key derived from the
token is saved in game, never the token itself. Type `/cr test` to check it
works.

## Post your kills

Kills and deaths are recorded automatically. When you want to post them:

1. Type `/cr export` (or open `/cr` and click **Export new**).
2. Press **Ctrl+C** (**Cmd+C** on Mac) to copy the text.
3. On the site go to **Submit kills**, paste it and submit.

Reports stay in the addon for 14 days, so you don't have to export after
every fight.

## Commands

| Command | What it does |
| --- | --- |
| `/cr` | Opens or closes the window with your recent kills and losses. Click **_** to shrink it to a small bar; it stays open or minimized, where you left it, after a reload |
| `/cr export` | Export everything you haven't exported yet |
| `/cr export all` | Export the last 14 days again |
| `/cr clear` | Remove reports you've already exported (keeps the rest) |
| `/cr clear all` | Delete every saved report (asks again if some aren't exported yet) |
| `/cr minimap` | Hide or show the minimap button (click it to open or close the window, drag it to move it) |
| `/cr key <token>` | Set or change your API token |
| `/cr test` | Export a test kill to check your key (the site doesn't save it) |
| `/cr debug` | Debug log summary. Debug mode is off by default: `/cr debug on` / `/cr debug off` toggle it, `/cr debug clear` empties the log |
| `/cr help` | List the commands |

If another addon already uses `/cr`, type `/corpserun` instead; it does the
same thing.

## Updating

Close WoW, delete the old `CorpseRun` folder from `AddOns` and copy in the new
one. Your recorded kills and API key are kept: they live in the game's `WTF`
folder, not in the addon folder.


## Troubleshooting

- **"Incompatible" or "Out of date" in the AddOns list:** tick
  **Load out of date AddOns** at the top of that list. The addon is updated
  when a new game patch comes out.
- **CorpseRun isn't in the AddOns list:** the folder is in the wrong place or
  nested twice. Check for `AddOns/CorpseRun/CorpseRun.toc`.
- **"Nothing new to export":** everything has already been exported. Use
  `/cr export all` to export the last 14 days again; the site ignores
  duplicates.
- **A kill has no final blow on the site:** the killing blow is only known
  when the victim, or someone who hit the victim, has the addon and posts the
  kill. It fills in when they do.

## Tests

Plain Lua 5.1 with stubbed WoW APIs, from this folder:

```sh
docker run --rm -v "$PWD:/addon/CorpseRun:ro" -v "$PWD/tests:/addon/tests:ro" nickblah/lua:5.1 lua /addon/tests/run.lua
```

## License

[MIT](LICENSE)
