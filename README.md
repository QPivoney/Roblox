# NFL Franchise Tycoon

A complete, self-building Roblox tycoon game. Drop two scripts into Studio and
the whole world — plots, a stadium, a live leaderboard, shops, UI — builds
itself at runtime. No external models, plugins, or Rojo setup required.

## What's here

```
ServerScriptService/NFLTycoonServer.lua      -- all server logic (Script)
StarterPlayerScripts/NFLTycoonClient.lua     -- all UI (LocalScript)
```

## Installation

1. Open your place in Roblox Studio.
2. In **ServerScriptService**, insert a new **Script** named `NFLTycoonServer`,
   delete its default contents, and paste in `ServerScriptService/NFLTycoonServer.lua`.
3. In **StarterPlayer > StarterPlayerScripts**, insert a new **LocalScript**
   named `NFLTycoonClient`, delete its default contents, and paste in
   `StarterPlayerScripts/NFLTycoonClient.lua`.
4. Press Play. You should see a welcome arch, a live leaderboard screen, and
   6 team plots, each with a claim sign.
5. For DataStores to save while testing in Studio: **Game Settings > Security
   > Enable Studio Access to API Services** = ON. Not required once published
   — it works automatically live.

## What's in the game

- **6 claimable team plots**, each growing to **5 themed floors**:
  Locker Room → Training Facility → Front Office → Owner's Suite → Stadium.
- **Income droppers** on every floor that pay out on an interval; walk into
  the dropped football to collect it.
- **Upgrade stations** ("sign a player") on every floor that permanently
  boost that floor's income.
- **Team customization**: a podium on the Locker Room floor lets you rename
  your franchise and pick a jersey color from a 10-color palette, filtered
  through Roblox's text service for safety.
- **The Stadium floor**: a real end-to-end field with yard lines, end zones,
  goalposts, and stadium lights, once you build all the way up.
- **Prestige ("Win the Super Bowl")**: once the Stadium is fully built and
  upgraded, retire your franchise from the Championship Podium for a
  permanent +25%-per-ring cash bonus and a ring counter on your sign.
- **A live global leaderboard**, both as an in-game top-10 panel and a
  physical scoreboard near spawn, ranked by lifetime earnings via an
  `OrderedDataStore`.
- **Game passes** (2x Cash, Auto Collector, VIP) wired up and ready — just
  fill in their ids (see below).
- **Toast notifications, an animated cash/progress HUD, and a shop/settings
  panel**, all built at runtime with no external UI assets.
- **DataStore saving** with safe fallback if DataStores are unavailable
  (Studio testing without API access enabled), so the game never crashes on
  load — it just runs unsaved.

## Configuring optional extras

Both are optional — the game runs fine with everything below left at its
default (`0` / disabled).

### Game passes

In `NFLTycoonServer.lua`, near the top:

```lua
local GAMEPASS_IDS = {
	DoubleCash  = 0,
	AutoCollect = 0,
	VIP         = 0,
}
```

Create the corresponding Game Passes for your place (Studio > Monetization),
then paste their ids in here. **Also update the matching table in
`NFLTycoonClient.lua`** (`GAMEPASS_IDS` near the top) so the shop buttons
call the right ids — the shop button shows "Soon" and is disabled for any id
left at `0`.

### Sound

```lua
local SOUND_IDS = {
	StadiumAmbience = 0,
	CashCollect     = 0,
	FloorUnlock     = 0,
	Prestige        = 0,
}
```

Paste in your own uploaded or Toolbox audio asset ids (as plain numbers, no
`rbxassetid://` prefix needed). Left at `0`, that sound simply never plays.

## Tuning the game

Everything about pacing lives in `FloorConfig` near the top of
`NFLTycoonServer.lua` — unlock costs, dropper rates, and each floor's two
upgrades. `PRESTIGE_COST` and `PRESTIGE_BONUS_PER_LEVEL` control the
end-game reset. `NUM_PLOTS` controls how many players can own a franchise at
once — plots are laid out in a row automatically, so raising it just extends
the row.

## Notes

- Data is stored per-player under `NFLTycoonData_v1` and lifetime earnings
  (for the leaderboard) under `NFLTycoonLeaderboard_v1`. If you need to wipe
  progress during development, bump the version suffix in both
  `DataStoreService:GetDataStore(...)` calls.
- Leaving a plot frees it up for another player to claim (the code keeps the
  original design's comment on this — see `releasePlot` in the server
  script if you'd rather leave builds standing permanently instead).
