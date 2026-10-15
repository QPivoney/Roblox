# 🎃 Roll a Pumpkin

A "+1 Strength every second" Roblox game in the style of **+1 Skipping
Stone**, except you **bowl a pumpkin** down a huge haunted bowling lane.
Drop two scripts into Studio and the whole world (lanes, zones, ramps,
pins, scenery, UI) builds itself at runtime. You don't need any models,
plugins or Rojo.

## What's here

```
RollAPumpkin/ServerScriptService/RollAPumpkinServer.lua    -- world, data, game rules (Script)
RollAPumpkin/StarterPlayerScripts/RollAPumpkinClient.lua   -- animations, camera, UI (LocalScript)
```

## Installation

1. Open a place in Roblox Studio. A blank **Baseplate** template is fine:
   the script removes the default baseplate and spawn.
2. In **ServerScriptService**, insert a **Script** named
   `RollAPumpkinServer` and paste in `RollAPumpkinServer.lua`.
3. In **StarterPlayer > StarterPlayerScripts**, insert a **LocalScript**
   named `RollAPumpkinClient` and paste in `RollAPumpkinClient.lua`.
4. Press **Play**.
5. For saving while testing in Studio, turn on **Game Settings > Security >
   Enable Studio Access to API Services**. Once published, saving works
   automatically.

> Don't run this in the same place as the NFL Tycoon scripts. Both build
> their own world and lighting.

## The game loop

1. **+1 💪 Strength every second.** A "+N 💪" pops over your head every tick.
2. **Walk onto a glowing lane pad.** A power meter appears with a needle
   sweeping back and forth.
3. **Click, tap BOWL! or press E** to stop the needle. The middle is best,
   and the gold strip is a **PERFECT** roll (+25% distance).
4. Your character does a full **bowling animation**: cradle, back-swing,
   lunge, release, follow-through.
5. The **pumpkin rolls** down the lane, and the camera chases it:
   - it spins on its stem and wobbles, with a trail and leaf/dust spray
   - it **launches off ramps**, and higher speed means bigger air
   - it lands with a dust burst and camera shake
   - it **smashes bowling pins** ("STRIKE! 🎳") when it reaches them
   - FOV kicks out as it speeds up
   - a zone banner shows as it enters each new zone, and the sky and fog
     change to match
   - it explodes into a **candy burst** when it stops
6. **Distance pays out 🏆 Wins.** Reaching a new zone for the first time
   pays a big bonus.
7. **Spend Wins on pumpkins.** Each one multiplies your Strength per second:

   | Pumpkin | Cost | Strength |
   |---|---|---|
   | Classic Pumpkin | free | x1 |
   | Jack-o'-Lantern | 150 | x2 |
   | Candy Corn | 1K | x4 |
   | Ghost Pumpkin | 5K | x8 |
   | Witch Pumpkin | 20K | x15 |
   | Toxic Pumpkin | 80K | x25 |
   | Golden Pumpkin | 300K | x50 |
   | Galaxy Pumpkin | 1.5M | x100 |

8. **Rebirth** resets Strength and Wins for a permanent **+50% Strength and
   Wins** per rebirth. You keep your pumpkins and best distance.

### The track

Six 1,000m zones, each with its own scenery and lighting:

**Pumpkin Patch → Cornfield → Haunted Woods → Graveyard → Witch Swamp →
Candy Kingdom**

There are 4 lanes, so 4 players can bowl side by side. Every lane has
distance signs every 100m, a gantry every 500m and a launch ramp every
250m. A "MAX DISTANCE" wall stands at the end.

## Configuring

All config is at the top of `RollAPumpkinServer.lua`. The client reads
it from the server, so **there's only one place to edit**.

- **`GAMEPASS_IDS`**: paste your *2x Strength* / *2x Wins* game pass ids.
  Left at `0`, the shop shows them as "Soon".
- **`SOUND_IDS`**: audio asset ids for the roll rumble, release whoosh,
  ramp landing, strike, finish, rebirth and purchase. `0` means silent.
- **`Pumpkins`**: name, cost, multiplier, colours, glowing face, material,
  sparkles. Add a row to add a new pumpkin to the shop.
- **`Zones`**: name, ground and accent colours, scenery theme and lighting.
- **Balance**: `DISTANCE_SCALE` / `DISTANCE_EXPONENT` (how strength turns
  into distance), `WINS_PER_STUD`, `PERFECT_BONUS`, the `REBIRTH_*` values
  and `STRENGTH_PER_SECOND`.

With the defaults, the first roll goes about 30m, about an hour of play
reaches 1,000m, and a max-distance roll needs about 62K Strength. That
last one is a 16-second ride peaking around 750 studs/s.

## Notes

- Animations are procedural (they move the character's joints from code),
  so you don't need to upload any animation assets. They work on both R15
  and R6 avatars.
- Every player sees every other player's bowl and pumpkin. The visuals run
  on each client, so rolling stays smooth at any speed.
- The server picks the distance from your Strength and timing. The client
  only reports where the needle stopped.
- Data is stored under `RollAPumpkinData_v1`. Bump the suffix to wipe
  progress during development.
