--[[
	NFL FRANCHISE TYCOON — Main Server Script
	-----------------------------------------------------------
	HOW TO INSTALL:
	1. In Roblox Studio, go to ServerScriptService.
	2. Insert a new Script (not LocalScript) named "NFLTycoonServer".
	3. Delete the default line and paste this entire file in.
	4. Go to StarterPlayer > StarterPlayerScripts, insert a new LocalScript
	   named "NFLTycoonClient", and paste in NFLTycoonClient.lua (the sibling
	   file next to this one). It drives all of the on-screen UI.
	5. Hit Play. The world builds itself — welcome arch, leaderboard,
	   6 plots, claim signs, 5 floors each, everything.
	6. For DataStores to save while testing in Studio:
	   Game Settings > Security > "Enable Studio Access to API Services" = ON.
	   (Not needed once the game is actually published — it works automatically live.)
	7. Optional but recommended — fill these in once you've set them up:
	     - GAMEPASS_IDS below (create the passes in Studio, paste their ids)
	     - SOUND_IDS below (upload or pick audio, paste the asset ids)
	   Both default to 0/disabled and the game works fine without them.

	No external models or plugins required. Everything is generated at
	runtime with Instance.new().
	-----------------------------------------------------------
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local TextService = game:GetService("TextService")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local RunService = game:GetService("RunService")

-- Wrapped in pcall: if DataStores aren't reachable (Studio testing without
-- "Enable Studio Access to API Services" turned on, or a brand-new unpublished
-- place), the whole script would otherwise crash on this line and nothing
-- would build. Now it just falls back to "saving disabled" and keeps going.
local tycoonStore
local leaderboardStore
do
	local ok, storeOrErr = pcall(function()
		return DataStoreService:GetDataStore("NFLTycoonData_v1")
	end)
	if ok then
		tycoonStore = storeOrErr
	else
		warn("[NFL Tycoon] DataStores unavailable — progress will NOT be saved this session. " ..
			"To fix: Game Settings > Security > Enable Studio Access to API Services (for Studio testing), " ..
			"or publish the game (works automatically live).")
	end

	local ok2, lbOrErr = pcall(function()
		return DataStoreService:GetOrderedDataStore("NFLTycoonLeaderboard_v1")
	end)
	if ok2 then
		leaderboardStore = lbOrErr
	end
end

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------

local NUM_PLOTS = 6
local PLOT_SIZE = 60          -- footprint, studs
local PLOT_SPACING = 100      -- distance between plot origins
local FLOOR_HEIGHT = 16       -- vertical space per floor
local BASE_HEIGHT = 2         -- thickness of the ground pad

-- Structural color per plot (fixed, gives each plot a distinct look
-- regardless of what jersey color its owner picks).
local TEAM_COLORS = {
	BrickColor.new("Bright blue"),
	BrickColor.new("Bright red"),
	BrickColor.new("Earth green"),
	BrickColor.new("New Yeller"),
	BrickColor.new("Deep orange"),
	BrickColor.new("Royal purple"),
}

-- Jersey / accent colors a player can pick for their franchise at the
-- Customize Team podium (floor 1). Index order must match the client script.
local JERSEY_COLOR_PRESETS = {
	{ name = "Blue",   color = BrickColor.new("Bright blue") },
	{ name = "Red",    color = BrickColor.new("Bright red") },
	{ name = "Green",  color = BrickColor.new("Earth green") },
	{ name = "Yellow", color = BrickColor.new("New Yeller") },
	{ name = "Orange", color = BrickColor.new("Deep orange") },
	{ name = "Purple", color = BrickColor.new("Royal purple") },
	{ name = "Pink",   color = BrickColor.new("Hot pink") },
	{ name = "Cyan",   color = BrickColor.new("Cyan") },
	{ name = "Black",  color = BrickColor.new("Really black") },
	{ name = "White",  color = BrickColor.new("Institutional white") },
}

-- Fill these in with your own Game Pass ids from Studio's Monetization tab.
-- Leave at 0 to keep a pass disabled (the shop button will show "Coming Soon").
local GAMEPASS_IDS = {
	DoubleCash  = 0,
	AutoCollect = 0,
	VIP         = 0,
}

-- Fill these in with your own uploaded/toolbox audio asset ids.
-- Leave at 0 to keep that sound disabled.
local SOUND_IDS = {
	StadiumAmbience = 0,
	CashCollect     = 0,
	FloorUnlock     = 0,
	Prestige        = 0,
}

local PRESTIGE_COST = 5000000
local PRESTIGE_BONUS_PER_LEVEL = 0.25 -- +25% permanent cash per ring

-- Each floor: name, unlock cost (paid from the floor below), dropper base rate,
-- drop interval (seconds), a visual theme, and up to two "sign a player"
-- upgrades that permanently add to that floor's dropper output.
local FloorConfig = {
	[1] = {
		name = "Locker Room",
		theme = "locker",
		unlockCost = 0, -- free, built the moment you claim the plot
		dropperRate = 5,
		dropperInterval = 3,
		upgrades = {
			{ name = "Sign Undrafted Free Agent", cost = 200,   boost = 4 },
			{ name = "Sign Veteran Backup",       cost = 900,   boost = 9 },
		},
	},
	[2] = {
		name = "Training Facility",
		theme = "training",
		unlockCost = 1500,
		dropperRate = 15,
		dropperInterval = 3,
		upgrades = {
			{ name = "Hire Strength Coach",   cost = 3000,  boost = 15 },
			{ name = "Sign Pro Bowl Player",  cost = 8000,  boost = 30 },
		},
	},
	[3] = {
		name = "Front Office",
		theme = "office",
		unlockCost = 20000,
		dropperRate = 45,
		dropperInterval = 3,
		upgrades = {
			{ name = "Hire General Manager",   cost = 35000,  boost = 60 },
			{ name = "Sign All-Pro Player",    cost = 70000,  boost = 120 },
		},
	},
	[4] = {
		name = "Owner's Suite",
		theme = "suite",
		unlockCost = 150000,
		dropperRate = 120,
		dropperInterval = 3,
		upgrades = {
			{ name = "Sign Franchise QB",       cost = 250000, boost = 300 },
			{ name = "Retire a Jersey Number",  cost = 400000, boost = 500 },
		},
	},
	[5] = {
		name = "Stadium",
		theme = "stadium",
		unlockCost = 600000,
		dropperRate = 400,
		dropperInterval = 3,
		upgrades = {
			{ name = "Sign Hall of Fame Legend", cost = 1200000, boost = 900 },
			{ name = "Name The Stadium",         cost = 2500000, boost = 2000 },
		},
	},
}
local MAX_FLOOR = #FloorConfig

----------------------------------------------------------------
-- REMOTES
----------------------------------------------------------------

local remotesFolder = Instance.new("Folder")
remotesFolder.Name = "NFLTycoonRemotes"
remotesFolder.Parent = ReplicatedStorage

local remotes = {}
for _, name in ipairs({ "Notify", "OpenCustomizeDialog", "ConfirmCustomize" }) do
	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = remotesFolder
	remotes[name] = event
end

local getLeaderboardFn = Instance.new("RemoteFunction")
getLeaderboardFn.Name = "GetLeaderboardTop"
getLeaderboardFn.Parent = remotesFolder
remotes.GetLeaderboardTop = getLeaderboardFn

----------------------------------------------------------------
-- STADIUM ATMOSPHERE (global lighting mood, one-time setup)
----------------------------------------------------------------

Lighting.ClockTime = 19
Lighting.Brightness = 2.5
Lighting.Ambient = Color3.fromRGB(35, 38, 50)
Lighting.OutdoorAmbient = Color3.fromRGB(60, 65, 85)
Lighting.EnvironmentSpecularScale = 1
Lighting.EnvironmentDiffuseScale = 0.35
Lighting.ShadowSoftness = 0.2

local atmosphere = Instance.new("Atmosphere")
atmosphere.Density = 0.3
atmosphere.Offset = 0.25
atmosphere.Color = Color3.fromRGB(199, 170, 135)
atmosphere.Decay = Color3.fromRGB(92, 60, 25)
atmosphere.Glare = 0.2
atmosphere.Haze = 1.5
atmosphere.Parent = Lighting

local colorCorrection = Instance.new("ColorCorrectionEffect")
colorCorrection.Saturation = 0.2
colorCorrection.Contrast = 0.08
colorCorrection.TintColor = Color3.fromRGB(245, 250, 255)
colorCorrection.Parent = Lighting

local bloom = Instance.new("BloomEffect")
bloom.Intensity = 0.55
bloom.Size = 24
bloom.Threshold = 1.1
bloom.Parent = Lighting

local sunRays = Instance.new("SunRaysEffect")
sunRays.Intensity = 0.15
sunRays.Spread = 0.5
sunRays.Parent = Lighting

----------------------------------------------------------------
-- RUNTIME STATE
----------------------------------------------------------------

local plots = {}            -- plots[i] = plot table (see createBasePlot)
local plotByUserId = {}     -- [userId] = plot table
local dataByUserId = {}     -- [userId] = save data table (see defaultData)
local passOwnership = {}    -- [userId][gamePassId] = bool
local customizeDebounce = {}-- [userId] = os.clock() of last customize request
local cachedTopFranchises = {}
local boardLabels = {}      -- physical leaderboard TextLabels to keep in sync

----------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------

local function newPart(size, cframe, color, parent, material)
	local p = Instance.new("Part")
	p.Anchored = true
	p.Size = size
	p.CFrame = cframe
	p.BrickColor = color or BrickColor.new("Medium stone grey")
	p.Material = material or Enum.Material.SmoothPlastic
	p.Parent = parent
	return p
end

local function newBillboard(parent, text, size)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.new(0, size or 200, 0, size and size * 0.35 or 50)
	gui.StudsOffset = Vector3.new(0, 2, 0)
	gui.AlwaysOnTop = true
	gui.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.3
	label.Parent = gui

	return gui, label
end

local function formatCash(n)
	n = math.floor(n)
	if n >= 1000000 then
		return string.format("$%.2fM", n / 1000000)
	elseif n >= 1000 then
		return string.format("$%.1fK", n / 1000)
	else
		return "$" .. tostring(n)
	end
end

local function playSound(soundId, parent, volume, looped)
	if not soundId or soundId == 0 then return nil end
	local sound = Instance.new("Sound")
	sound.SoundId = "rbxassetid://" .. tostring(soundId)
	sound.Volume = volume or 0.5
	sound.Looped = looped or false
	sound.Parent = parent
	sound:Play()
	if not looped then
		Debris:AddItem(sound, 10)
	end
	return sound
end

local function filterTeamName(player, rawName)
	rawName = tostring(rawName or ""):sub(1, 24)
	if rawName:gsub("%s+", "") == "" then
		return nil
	end
	local ok, result = pcall(function()
		local filterResult = TextService:FilterStringAsync(rawName, player.UserId)
		return filterResult:GetNonChatStringForBroadcastAsync()
	end)
	if ok and result and result ~= "" then
		return result
	end
	return nil
end

local function playerOwnsPass(player, passId)
	if not player or not passId or passId == 0 then return false end
	local userId = player.UserId
	passOwnership[userId] = passOwnership[userId] or {}
	if passOwnership[userId][passId] == nil then
		local ok, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(userId, passId)
		end)
		passOwnership[userId][passId] = ok and owns or false
	end
	return passOwnership[userId][passId]
end

-- Tracks parts on a plot whose color follows the owner's chosen jersey color
-- (as opposed to the plot's fixed structural color). Floor accents are wiped
-- and rebuilt every time floors are torn down (release/prestige); permanent
-- accents (the entrance monument) live for the plot's entire lifetime.
local function registerAccent(plot, part, permanent)
	local list = permanent and plot.permanentAccents or plot.accentParts
	table.insert(list, part)
	part.BrickColor = plot.jerseyColor
end

local function applyTeamCosmetics(plot, data)
	local preset = JERSEY_COLOR_PRESETS[data.TeamColorIndex] or JERSEY_COLOR_PRESETS[1]
	plot.jerseyColor = preset.color

	for _, part in ipairs(plot.accentParts) do
		if part and part.Parent then
			part.BrickColor = plot.jerseyColor
		end
	end
	for _, part in ipairs(plot.permanentAccents) do
		if part and part.Parent then
			part.BrickColor = plot.jerseyColor
		end
	end

	local displayName = (plot.ownerPlayer and (plot.ownerPlayer.DisplayName or plot.ownerPlayer.Name)) or "Unclaimed"
	plot.signLabel.Text = displayName .. "'s " .. data.TeamName
	plot.sign.BrickColor = plot.jerseyColor

	if plot.trophyLabel and plot.trophyLabel.Parent then
		plot.trophyLabel.Text = "\xF0\x9F\x8F\x86 Championship Podium\nRings: " .. tostring(data.PrestigeLevel or 0)
	end
end

local function updateTycoonInfo(player)
	local info = player:FindFirstChild("TycoonInfo")
	local data = dataByUserId[player.UserId]
	local plot = plotByUserId[player.UserId]
	if not info or not data then return end

	info.TeamName.Value = data.TeamName
	info.PrestigeLevel.Value = data.PrestigeLevel

	if not plot or plot.currentFloor == 0 then
		info.FloorName.Value = "Unclaimed"
		info.NextFloorName.Value = FloorConfig[1].name
		info.NextCost.Value = FloorConfig[1].unlockCost
		return
	end

	local cfg = FloorConfig[plot.currentFloor]
	info.FloorName.Value = cfg.name

	if plot.currentFloor < MAX_FLOOR then
		local nextCfg = FloorConfig[plot.currentFloor + 1]
		info.NextFloorName.Value = nextCfg.name
		info.NextCost.Value = nextCfg.unlockCost
	else
		info.NextFloorName.Value = "Championship"
		info.NextCost.Value = PRESTIGE_COST
	end
end

local function spawnConfetti(plot)
	local anchor = plot.sign
	if not anchor then return end
	local attachment = Instance.new("Attachment")
	attachment.Position = Vector3.new(0, 6, 0)
	attachment.Parent = anchor

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(2, 4)
	emitter.Speed = NumberRange.new(10, 20)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Color = ColorSequence.new(Color3.new(1, 1, 0), Color3.new(1, 0, 0))
	emitter.Size = NumberSequence.new(0.5)
	emitter.Parent = attachment
	emitter:Emit(80)

	Debris:AddItem(attachment, 5)
end

local function spawnAutoCollectVFX(dropperPad, amount)
	local flash = newPart(
		Vector3.new(2, 2, 2),
		dropperPad.CFrame + Vector3.new(0, 2, 0),
		BrickColor.new("New Yeller"),
		dropperPad.Parent,
		Enum.Material.Neon
	)
	flash.Shape = Enum.PartType.Ball
	flash.CanCollide = false
	flash.Anchored = true
	flash.Transparency = 0.2
	newBillboard(flash, formatCash(amount), 80)
	Debris:AddItem(flash, 1)
end

local function buildGoalpost(floorModel, cframe, plot, color)
	newPart(Vector3.new(1, 10, 1), cframe, BrickColor.new("Really black"), floorModel, Enum.Material.Metal)
	local crossbar = newPart(Vector3.new(8, 0.6, 0.6), cframe * CFrame.new(0, 5, 0), color, floorModel, Enum.Material.Metal)
	local leftPost = newPart(Vector3.new(0.6, 6, 0.6), cframe * CFrame.new(-4, 8, 0), color, floorModel, Enum.Material.Metal)
	local rightPost = newPart(Vector3.new(0.6, 6, 0.6), cframe * CFrame.new(4, 8, 0), color, floorModel, Enum.Material.Metal)
	registerAccent(plot, crossbar)
	registerAccent(plot, leftPost)
	registerAccent(plot, rightPost)
end

local function addStadiumLights(floorModel, origin, y, half)
	local offsets = {
		Vector3.new(-half + 3, 0, -half + 3),
		Vector3.new(half - 3, 0, -half + 3),
		Vector3.new(-half + 3, 0, half - 3),
		Vector3.new(half - 3, 0, half - 3),
	}
	for _, offset in ipairs(offsets) do
		newPart(
			Vector3.new(1, FLOOR_HEIGHT - 1, 1),
			origin * CFrame.new(offset.X, y + (FLOOR_HEIGHT - 1) / 2, offset.Z),
			BrickColor.new("Really black"),
			floorModel,
			Enum.Material.Metal
		)
		local lightHead = newPart(
			Vector3.new(3, 1, 3),
			origin * CFrame.new(offset.X, y + FLOOR_HEIGHT - 1.5, offset.Z),
			BrickColor.new("Institutional white"),
			floorModel,
			Enum.Material.Neon
		)
		local spot = Instance.new("SpotLight")
		spot.Brightness = 3
		spot.Range = 40
		spot.Angle = 90
		spot.Face = Enum.NormalId.Bottom
		spot.Parent = lightHead
	end
end

----------------------------------------------------------------
-- BUILDING SHELL (modern dark facade + neon team trim + an actual door)
----------------------------------------------------------------

local DOOR_WIDTH = 10
local DOOR_HEIGHT = 10

-- Only floor 1's front wall needs a real opening — every floor above it is
-- reached from the interior staircase, never from outside.
local function buildFrontWallWithDoor(floorModel, origin, wallY, wallHeight, half, wallColor, plot)
	local segWidth = half - DOOR_WIDTH / 2
	local segCenter = DOOR_WIDTH / 2 + segWidth / 2
	local wallBottom = wallY - wallHeight / 2

	newPart(Vector3.new(segWidth, wallHeight, 1), origin * CFrame.new(-segCenter, wallY, -half), wallColor, floorModel, Enum.Material.Metal)
	newPart(Vector3.new(segWidth, wallHeight, 1), origin * CFrame.new(segCenter, wallY, -half), wallColor, floorModel, Enum.Material.Metal)

	local topSegHeight = wallHeight - DOOR_HEIGHT
	if topSegHeight > 0 then
		newPart(
			Vector3.new(DOOR_WIDTH + 2, topSegHeight, 1),
			origin * CFrame.new(0, wallBottom + DOOR_HEIGHT + topSegHeight / 2, -half),
			wallColor,
			floorModel,
			Enum.Material.Metal
		)
	end

	local lintelY = wallBottom + DOOR_HEIGHT + 0.75
	newPart(Vector3.new(DOOR_WIDTH + 2.4, 1.5, 1.2), origin * CFrame.new(0, lintelY, -half), wallColor, floorModel, Enum.Material.Metal)

	local leftJamb = newPart(
		Vector3.new(0.6, DOOR_HEIGHT, 1.3),
		origin * CFrame.new(-DOOR_WIDTH / 2, wallBottom + DOOR_HEIGHT / 2, -half),
		plot.jerseyColor,
		floorModel,
		Enum.Material.Neon
	)
	local rightJamb = newPart(
		Vector3.new(0.6, DOOR_HEIGHT, 1.3),
		origin * CFrame.new(DOOR_WIDTH / 2, wallBottom + DOOR_HEIGHT / 2, -half),
		plot.jerseyColor,
		floorModel,
		Enum.Material.Neon
	)
	registerAccent(plot, leftJamb)
	registerAccent(plot, rightJamb)

	local signPart = newPart(
		Vector3.new(DOOR_WIDTH, 1.2, 0.3),
		origin * CFrame.new(0, lintelY + 1.4, -half),
		plot.jerseyColor,
		floorModel,
		Enum.Material.Neon
	)
	registerAccent(plot, signPart)
	newBillboard(signPart, "ENTRANCE", 140)
end

local function addWallWithTrim(floorModel, origin, wallY, wallHeight, size, cf, wallColor, trimSize, plot)
	newPart(size, origin * cf, wallColor, floorModel, Enum.Material.Metal)
	local trim = newPart(trimSize, origin * cf * CFrame.new(0, wallHeight / 2 - 0.3, 0), plot.jerseyColor, floorModel, Enum.Material.Neon)
	registerAccent(plot, trim)
end

-- Dark modern shell for a floor: slate arena floor with a team-color center
-- emblem and glowing edge border, dark metal walls with a glowing top trim,
-- and corner pillars capped with a neon ring. Floor 1 gets a real doorway.
local function buildFloorShell(floorModel, origin, y, half, plot, floorIndex)
	local platform = newPart(
		Vector3.new(PLOT_SIZE, 1, PLOT_SIZE),
		origin * CFrame.new(0, y, 0),
		BrickColor.new("Smoky grey"),
		floorModel,
		Enum.Material.Slate
	)
	platform.Name = "Platform"

	local emblem = newPart(
		Vector3.new(0.2, 16, 16),
		origin * CFrame.new(0, y + 0.6, 0),
		plot.color,
		floorModel,
		Enum.Material.Neon
	)
	emblem.Shape = Enum.PartType.Cylinder
	emblem.Orientation = Vector3.new(0, 0, 90)

	local edges = {
		{ size = Vector3.new(PLOT_SIZE, 0.3, 0.6), cf = CFrame.new(0, 0.65, -half + 0.3) },
		{ size = Vector3.new(PLOT_SIZE, 0.3, 0.6), cf = CFrame.new(0, 0.65, half - 0.3) },
		{ size = Vector3.new(0.6, 0.3, PLOT_SIZE), cf = CFrame.new(-half + 0.3, 0.65, 0) },
		{ size = Vector3.new(0.6, 0.3, PLOT_SIZE), cf = CFrame.new(half - 0.3, 0.65, 0) },
	}
	for _, edge in ipairs(edges) do
		local border = newPart(edge.size, origin * CFrame.new(0, y, 0) * edge.cf, plot.jerseyColor, floorModel, Enum.Material.Neon)
		registerAccent(plot, border)
	end

	local wallHeight = FLOOR_HEIGHT - 2
	local wallY = y + 0.5 + wallHeight / 2
	local wallColor = BrickColor.new("Dark stone grey")

	if floorIndex == 1 then
		buildFrontWallWithDoor(floorModel, origin, wallY, wallHeight, half, wallColor, plot)
	else
		addWallWithTrim(
			floorModel, origin, wallY, wallHeight,
			Vector3.new(PLOT_SIZE, wallHeight, 1), CFrame.new(0, wallY, -half),
			wallColor, Vector3.new(PLOT_SIZE, 0.6, 1.05), plot
		)
	end

	addWallWithTrim(
		floorModel, origin, wallY, wallHeight,
		Vector3.new(PLOT_SIZE, wallHeight, 1), CFrame.new(0, wallY, half),
		wallColor, Vector3.new(PLOT_SIZE, 0.6, 1.05), plot
	)
	addWallWithTrim(
		floorModel, origin, wallY, wallHeight,
		Vector3.new(1, wallHeight, PLOT_SIZE), CFrame.new(-half, wallY, 0),
		wallColor, Vector3.new(1.05, 0.6, PLOT_SIZE), plot
	)
	addWallWithTrim(
		floorModel, origin, wallY, wallHeight,
		Vector3.new(1, wallHeight, PLOT_SIZE), CFrame.new(half, wallY, 0),
		wallColor, Vector3.new(1.05, 0.6, PLOT_SIZE), plot
	)

	local corners = {
		{ x = -half, z = -half },
		{ x = half, z = -half },
		{ x = -half, z = half },
		{ x = half, z = half },
	}
	for _, c in ipairs(corners) do
		newPart(Vector3.new(2, wallHeight, 2), origin * CFrame.new(c.x, wallY, c.z), BrickColor.new("Really black"), floorModel, Enum.Material.Metal)
		local ring = newPart(
			Vector3.new(2.4, 0.4, 2.4),
			origin * CFrame.new(c.x, wallY + wallHeight / 2 - 1, c.z),
			plot.jerseyColor,
			floorModel,
			Enum.Material.Neon
		)
		registerAccent(plot, ring)
	end

	-- A big illuminated team crest on the ground floor's exterior face —
	-- this is the plot's "curb appeal" signature, visible from the plaza.
	if floorIndex == 1 then
		local crest = newPart(
			Vector3.new(0.6, 10, 10),
			origin * CFrame.new(0, wallY + 3, -half - 0.6),
			plot.jerseyColor,
			floorModel,
			Enum.Material.Neon
		)
		crest.Shape = Enum.PartType.Cylinder
		crest.Orientation = Vector3.new(0, 90, 0) -- faces forward along Z, not up
		registerAccent(plot, crest)
	end
end

----------------------------------------------------------------
-- FLOOR THEME DECORATIONS
----------------------------------------------------------------

local function decorateLockerRoom(floorModel, origin, y, half, plot)
	for i = -3, 3 do
		if i ~= 0 then
			local locker = newPart(
				Vector3.new(3, 6, 1.5),
				origin * CFrame.new(i * 4, y + 0.5 + 3, -half + 1.5),
				BrickColor.new("Medium stone grey"),
				floorModel,
				Enum.Material.Metal
			)
			registerAccent(plot, locker)
			newPart(
				Vector3.new(2.6, 0.4, 0.1),
				origin * CFrame.new(i * 4, y + 0.5 + 5, -half + 0.7),
				BrickColor.new("Really black"),
				floorModel
			)
		end
	end
	newPart(Vector3.new(10, 1, 3), origin * CFrame.new(0, y + 1, 0), BrickColor.new("Brown"), floorModel, Enum.Material.Wood)
end

local function decorateTrainingFacility(floorModel, origin, y, half, plot)
	newPart(
		Vector3.new(PLOT_SIZE - 10, 0.2, PLOT_SIZE - 10),
		origin * CFrame.new(0, y + 0.6, 0),
		BrickColor.new("Earth green"),
		floorModel,
		Enum.Material.Grass
	)
	for i = -1, 1, 2 do
		local barY = y + 2
		newPart(Vector3.new(6, 0.4, 0.4), origin * CFrame.new(i * 10, barY, 5), BrickColor.new("Really black"), floorModel, Enum.Material.Metal)
		for side = -1, 1, 2 do
			local plate = newPart(
				Vector3.new(0.6, 2, 2),
				origin * CFrame.new(i * 10 + side * 3, barY, 5),
				plot.jerseyColor,
				floorModel,
				Enum.Material.Metal
			)
			registerAccent(plot, plate)
		end
	end
end

local function decorateFrontOffice(floorModel, origin, y, half, plot)
	newPart(Vector3.new(10, 3, 5), origin * CFrame.new(0, y + 1.5, -5), BrickColor.new("Brown"), floorModel, Enum.Material.Wood)
	for i = -1, 1, 2 do
		local monitor = newPart(
			Vector3.new(3, 2, 0.2),
			origin * CFrame.new(i * 2.5, y + 4, -5),
			BrickColor.new("Really black"),
			floorModel,
			Enum.Material.Neon
		)
		monitor.Color = Color3.fromRGB(80, 160, 255)
	end
	for i = -2, 2 do
		newPart(Vector3.new(2, 2, 0.2), origin * CFrame.new(i * 6, y + 8, half - 0.6), BrickColor.new("Really black"), floorModel)
		local photo = newPart(
			Vector3.new(1.6, 1.6, 0.1),
			origin * CFrame.new(i * 6, y + 8, half - 0.5),
			plot.jerseyColor,
			floorModel
		)
		registerAccent(plot, photo)
	end
end

local function decorateOwnersSuite(floorModel, origin, y, half, plot)
	local window = newPart(
		Vector3.new(PLOT_SIZE - 8, 8, 0.3),
		origin * CFrame.new(0, y + 8, half - 0.5),
		BrickColor.new("Institutional white"),
		floorModel,
		Enum.Material.Glass
	)
	window.Transparency = 0.5

	newPart(Vector3.new(3, 4, 3), origin * CFrame.new(0, y + 2, 0), BrickColor.new("Reddish brown"), floorModel, Enum.Material.Fabric)

	newPart(Vector3.new(10, 0.5, 2), origin * CFrame.new(0, y + 6, -half + 3), BrickColor.new("Brown"), floorModel, Enum.Material.Wood)
	for i = -2, 2 do
		local trophy = newPart(
			Vector3.new(1, 2, 1),
			origin * CFrame.new(i * 2, y + 7, -half + 3),
			BrickColor.new("New Yeller"),
			floorModel,
			Enum.Material.Metal
		)
		registerAccent(plot, trophy)
	end
end

local function decorateStadium(floorModel, origin, y, half, plot)
	local field = floorModel:FindFirstChild("Platform")
	if field then
		field.BrickColor = BrickColor.new("Earth green")
		field.Material = Enum.Material.Grass
	end

	for i = 1, 7 do
		local z = -half + (PLOT_SIZE / 8) * i
		newPart(Vector3.new(PLOT_SIZE - 6, 0.1, 0.4), origin * CFrame.new(0, y + 0.6, z), BrickColor.new("Institutional white"), floorModel)
	end

	local endzone1 = newPart(Vector3.new(PLOT_SIZE - 6, 0.15, 6), origin * CFrame.new(0, y + 0.62, -half + 5), plot.jerseyColor, floorModel)
	local endzone2 = newPart(Vector3.new(PLOT_SIZE - 6, 0.15, 6), origin * CFrame.new(0, y + 0.62, half - 5), plot.jerseyColor, floorModel)
	registerAccent(plot, endzone1)
	registerAccent(plot, endzone2)

	buildGoalpost(floorModel, origin * CFrame.new(0, y + 0.5, -half + 1), plot, plot.jerseyColor)
	buildGoalpost(floorModel, origin * CFrame.new(0, y + 0.5, half - 1), plot, plot.jerseyColor)

	addStadiumLights(floorModel, origin, y, half)

	local podium = newPart(Vector3.new(6, 3, 6), origin * CFrame.new(half - 8, y + 2, 0), BrickColor.new("New Yeller"), floorModel, Enum.Material.Metal)
	podium.Name = "ChampionshipPodium"
	local _, label = newBillboard(podium, "\xF0\x9F\x8F\x86 Championship Podium\nRings: 0", 220)
	plot.trophyLabel = label

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Retire & Rebuild"
	prompt.ObjectText = "Win The Super Bowl"
	prompt.HoldDuration = 2
	prompt.MaxActivationDistance = 10
	prompt.Parent = podium

	-- PrestigePlotFn is defined further down this script. Lua resolves
	-- globals at call time, so this works even though it isn't defined yet.
	prompt.Triggered:Connect(function(player)
		PrestigePlotFn(plot, player)
	end)
end

----------------------------------------------------------------
-- LEADERBOARD (global, cross-server via OrderedDataStore)
----------------------------------------------------------------

local function updateLeaderboardBoards(results)
	local lines = { "TOP FRANCHISES", "" }
	for i, entry in ipairs(results) do
		table.insert(lines, i .. ". " .. entry.name .. " \xE2\x80\x94 " .. formatCash(entry.value))
	end
	if #results == 0 then
		table.insert(lines, "No franchises yet — be the first!")
	end
	local text = table.concat(lines, "\n")
	for _, label in ipairs(boardLabels) do
		if label and label.Parent then
			label.Text = text
		end
	end
end

local function refreshLeaderboardCache()
	if not leaderboardStore then return end
	local ok, pages = pcall(function()
		return leaderboardStore:GetSortedAsync(false, 10)
	end)
	if not ok or not pages then return end

	local page = pages:GetCurrentPage()
	local results = {}
	for _, entry in ipairs(page) do
		local userId = tonumber(entry.key)
		local name = "Unknown Franchise"
		local liveData = userId and dataByUserId[userId]
		if liveData then
			name = liveData.TeamName
		elseif userId then
			local ok2, plrName = pcall(function()
				return Players:GetNameFromUserIdAsync(userId)
			end)
			if ok2 and plrName then
				name = plrName .. "'s Team"
			end
		end
		table.insert(results, { name = name, value = entry.value })
	end

	cachedTopFranchises = results
	updateLeaderboardBoards(results)
end

getLeaderboardFn.OnServerInvoke = function()
	return cachedTopFranchises
end

----------------------------------------------------------------
-- DATASTORE
----------------------------------------------------------------

local function defaultData()
	return {
		HighestFloor = 0,
		Upgrades = {},
		Cash = 0,
		TotalEarned = 0,
		TeamName = "My Team",
		TeamColorIndex = 1,
		PrestigeLevel = 0,
	}
end

local function mergeDefaults(data)
	for key, value in pairs(defaultData()) do
		if data[key] == nil then
			data[key] = value
		end
	end
	return data
end

local function loadData(player)
	if not tycoonStore then
		return defaultData()
	end
	local ok, result = pcall(function()
		return tycoonStore:GetAsync("Player_" .. player.UserId)
	end)
	if ok and result then
		return mergeDefaults(result)
	end
	return defaultData()
end

local function saveData(player)
	if not tycoonStore then return end
	local data = dataByUserId[player.UserId]
	if not data then return end
	local stats = player:FindFirstChild("leaderstats")
	if stats and stats:FindFirstChild("Cash") then
		data.Cash = stats.Cash.Value
	end
	pcall(function()
		tycoonStore:SetAsync("Player_" .. player.UserId, data)
	end)
	if leaderboardStore then
		pcall(function()
			leaderboardStore:SetAsync(tostring(player.UserId), math.max(0, math.floor(data.TotalEarned or 0)))
		end)
	end
end

----------------------------------------------------------------
-- LEADERSTATS / TYCOON INFO
----------------------------------------------------------------

local function setupLeaderstats(player, startingCash)
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	stats.Parent = player

	local cash = Instance.new("IntValue")
	cash.Name = "Cash"
	cash.Value = startingCash or 0
	cash.Parent = stats

	local floorVal = Instance.new("IntValue")
	floorVal.Name = "Floor"
	floorVal.Value = 0
	floorVal.Parent = stats

	return cash, floorVal
end

local function setupTycoonInfo(player, data)
	local info = Instance.new("Folder")
	info.Name = "TycoonInfo"
	info.Parent = player

	local floorName = Instance.new("StringValue")
	floorName.Name = "FloorName"
	floorName.Value = "Unclaimed"
	floorName.Parent = info

	local nextFloorName = Instance.new("StringValue")
	nextFloorName.Name = "NextFloorName"
	nextFloorName.Value = FloorConfig[1].name
	nextFloorName.Parent = info

	local nextCost = Instance.new("NumberValue")
	nextCost.Name = "NextCost"
	nextCost.Value = FloorConfig[1].unlockCost
	nextCost.Parent = info

	local prestigeLevel = Instance.new("IntValue")
	prestigeLevel.Name = "PrestigeLevel"
	prestigeLevel.Value = data.PrestigeLevel or 0
	prestigeLevel.Parent = info

	local teamName = Instance.new("StringValue")
	teamName.Name = "TeamName"
	teamName.Value = data.TeamName
	teamName.Parent = info

	return info
end

----------------------------------------------------------------
-- PLOT CREATION (the empty base + claim sign, before anyone owns it)
----------------------------------------------------------------

local function createBasePlot(index)
	local originX = (index - 1) * PLOT_SPACING
	local origin = CFrame.new(originX, 0, 0)
	local color = TEAM_COLORS[((index - 1) % #TEAM_COLORS) + 1]
	local half = PLOT_SIZE / 2

	local model = Instance.new("Model")
	model.Name = "TeamPlot_" .. index
	model.Parent = Workspace

	local pad = newPart(
		Vector3.new(PLOT_SIZE, BASE_HEIGHT, PLOT_SIZE),
		origin * CFrame.new(0, BASE_HEIGHT / 2, 0),
		BrickColor.new("Dark stone grey"),
		model
	)
	pad.Name = "Pad"

	local plot = {
		index = index,
		origin = origin,
		color = color,
		jerseyColor = color,
		model = model,
		sign = nil,
		signLabel = nil,
		owner = nil,             -- userId
		ownerPlayer = nil,       -- Player instance
		currentFloor = 0,
		dropperConnections = {}, -- [floorIndex] = true/false running flag
		floorParts = {},         -- [floorIndex] = Model
		accentParts = {},        -- floor-level parts that follow the jersey color
		permanentAccents = {},   -- monument parts that follow the jersey color for the plot's whole lifetime
		trophyLabel = nil,
	}

	-- Entrance monument, standing clear of the doorway (built later, on floor 1)
	-- instead of blocking it. A lit walkway connects it to the building face.
	local monumentZ = -half - 8

	newPart(
		Vector3.new(14, 0.3, 8),
		origin * CFrame.new(0, BASE_HEIGHT + 0.15, -half - 4),
		BrickColor.new("Medium stone grey"),
		model,
		Enum.Material.Concrete
	)
	local walkEdge1 = newPart(Vector3.new(14, 0.15, 0.4), origin * CFrame.new(0, BASE_HEIGHT + 0.35, -half - 0.2), color, model, Enum.Material.Neon)
	local walkEdge2 = newPart(Vector3.new(14, 0.15, 0.4), origin * CFrame.new(0, BASE_HEIGHT + 0.35, -half - 7.8), color, model, Enum.Material.Neon)
	registerAccent(plot, walkEdge1, true)
	registerAccent(plot, walkEdge2, true)

	newPart(
		Vector3.new(8, 2, 4),
		origin * CFrame.new(0, BASE_HEIGHT + 1, monumentZ),
		BrickColor.new("Really black"),
		model,
		Enum.Material.Basalt
	)

	local sign = newPart(
		Vector3.new(6, 8, 1),
		origin * CFrame.new(0, BASE_HEIGHT + 2 + 4, monumentZ),
		color,
		model,
		Enum.Material.SmoothPlastic
	)
	sign.Name = "ClaimSign"
	sign.Anchored = true

	local _, label = newBillboard(sign, "UNCLAIMED\nTeam Plot " .. index, 220)

	local crest = newPart(
		Vector3.new(3.4, 3.4, 0.4),
		origin * CFrame.new(0, BASE_HEIGHT + 2 + 8.3, monumentZ),
		color,
		model,
		Enum.Material.Neon
	)
	crest.Shape = Enum.PartType.Cylinder
	crest.Orientation = Vector3.new(0, 90, 0)
	registerAccent(plot, crest, true)

	for _, side in ipairs({ -1, 1 }) do
		local postX = side * 6
		newPart(
			Vector3.new(0.8, 6, 0.8),
			origin * CFrame.new(postX, BASE_HEIGHT + 3, monumentZ + 2),
			BrickColor.new("Really black"),
			model,
			Enum.Material.Metal
		)
		local lightOrb = newPart(
			Vector3.new(1.4, 1.4, 1.4),
			origin * CFrame.new(postX, BASE_HEIGHT + 6, monumentZ + 2),
			color,
			model,
			Enum.Material.Neon
		)
		lightOrb.Shape = Enum.PartType.Ball
		registerAccent(plot, lightOrb, true)

		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 255, 255)
		light.Range = 16
		light.Brightness = 2
		light.Parent = lightOrb
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Claim This Team"
	prompt.ObjectText = "Team Plot " .. index
	prompt.HoldDuration = 1
	prompt.MaxActivationDistance = 12
	prompt.Parent = sign

	plot.sign = sign
	plot.signLabel = label

	-- ClaimPlotFn is a global function defined further down this script.
	-- Lua looks up globals at call time, so this works fine even though
	-- ClaimPlotFn hasn't been defined yet at the point this line runs.
	prompt.Triggered:Connect(function(player)
		ClaimPlotFn(plot, player)
	end)

	return plot
end

----------------------------------------------------------------
-- FLOOR BUILDING
----------------------------------------------------------------

-- Builds the physical floor (platform + walls + staircase + theme decor +
-- dropper + upgrade stations + "unlock next floor" prompt), and wires up
-- all the touch/prompt logic.
local function buildFloor(plot, floorIndex)
	local cfg = FloorConfig[floorIndex]
	local origin = plot.origin
	local y = BASE_HEIGHT + FLOOR_HEIGHT * (floorIndex - 1)

	local floorModel = Instance.new("Model")
	floorModel.Name = "Floor_" .. floorIndex .. "_" .. cfg.name
	floorModel.Parent = plot.model
	plot.floorParts[floorIndex] = floorModel

	local half = PLOT_SIZE / 2
	buildFloorShell(floorModel, origin, y, half, plot, floorIndex)

	local labelPart = newPart(Vector3.new(1, 1, 1), origin * CFrame.new(0, y + FLOOR_HEIGHT - 0.5, -half + 1), plot.color, floorModel)
	labelPart.Transparency = 1
	labelPart.CanCollide = false
	newBillboard(labelPart, "Floor " .. floorIndex .. ": " .. cfg.name, 260)

	-- Staircase up to the next floor (skip on the top floor).
	if floorIndex < MAX_FLOOR then
		local steps = 10
		local stepDepth = 4
		local stepRise = FLOOR_HEIGHT / steps
		local startZ = half - stepDepth / 2
		local stairX = half - 5

		for s = 1, steps do
			local stepY = y + 0.5 + stepRise * (s - 0.5)
			local stepZ = startZ - stepDepth * (s - 1)
			newPart(
				Vector3.new(8, stepRise, stepDepth),
				origin * CFrame.new(stairX, stepY, stepZ),
				BrickColor.new("Medium stone grey"),
				floorModel
			)
		end
	end

	-- Themed visual decoration for this floor
	if cfg.theme == "locker" then
		decorateLockerRoom(floorModel, origin, y, half, plot)
	elseif cfg.theme == "training" then
		decorateTrainingFacility(floorModel, origin, y, half, plot)
	elseif cfg.theme == "office" then
		decorateFrontOffice(floorModel, origin, y, half, plot)
	elseif cfg.theme == "suite" then
		decorateOwnersSuite(floorModel, origin, y, half, plot)
	elseif cfg.theme == "stadium" then
		decorateStadium(floorModel, origin, y, half, plot)
	end

	-- The Customize Team podium only needs to exist once, on floor 1.
	if floorIndex == 1 then
		local podium = newPart(
			Vector3.new(4, 5, 3),
			origin * CFrame.new(half - 4, y + 0.5 + 2.5, half - 10),
			BrickColor.new("Really black"),
			floorModel
		)
		podium.Name = "CustomizePodium"
		newBillboard(podium, "Customize Team\nName & Colors", 180)

		local customizePrompt = Instance.new("ProximityPrompt")
		customizePrompt.ActionText = "Customize Team"
		customizePrompt.ObjectText = "Team Name & Colors"
		customizePrompt.HoldDuration = 0.5
		customizePrompt.MaxActivationDistance = 10
		customizePrompt.Parent = podium

		customizePrompt.Triggered:Connect(function(player)
			if plot.owner ~= player.UserId then return end
			local data = dataByUserId[player.UserId]
			if not data then return end
			remotes.OpenCustomizeDialog:FireClient(player, data.TeamName, data.TeamColorIndex)
		end)
	end

	----------------------------------------------------------------
	-- DROPPER
	----------------------------------------------------------------
	local dropperBase = newPart(
		Vector3.new(8, 0.4, 8),
		origin * CFrame.new(-half + 8, y + 0.7, -half + 8),
		BrickColor.new("Really black"),
		floorModel,
		Enum.Material.Metal
	)
	dropperBase.Shape = Enum.PartType.Cylinder
	dropperBase.Orientation = Vector3.new(0, 0, 90)

	local dropperPad = newPart(
		Vector3.new(0.6, 6, 6),
		origin * CFrame.new(-half + 8, y + 1, -half + 8),
		BrickColor.new("Gold"),
		floorModel,
		Enum.Material.Neon
	)
	dropperPad.Name = "Dropper"
	dropperPad.Shape = Enum.PartType.Cylinder
	dropperPad.Orientation = Vector3.new(0, 0, 90)
	newBillboard(dropperPad, "Income Dropper", 150)

	local dropperLight = Instance.new("PointLight")
	dropperLight.Color = Color3.fromRGB(255, 221, 120)
	dropperLight.Range = 14
	dropperLight.Brightness = 2.5
	dropperLight.Parent = dropperPad

	local floorState = {
		bonus = 0, -- extra income from purchased upgrades on this floor
	}

	plot.dropperConnections[floorIndex] = true
	task.spawn(function()
		while plot.dropperConnections[floorIndex] and plot.owner do
			task.wait(cfg.dropperInterval)
			if not (plot.dropperConnections[floorIndex] and plot.owner) then break end

			local ownerPlayer = plot.ownerPlayer
			local data = dataByUserId[plot.owner]
			if not ownerPlayer or not data then continue end

			local stats = ownerPlayer:FindFirstChild("leaderstats")
			if not stats then continue end

			local mult = 1 + (data.PrestigeLevel * PRESTIGE_BONUS_PER_LEVEL)
			if playerOwnsPass(ownerPlayer, GAMEPASS_IDS.DoubleCash) then
				mult *= 2
			end
			local amount = math.floor((cfg.dropperRate + floorState.bonus) * mult)

			if playerOwnsPass(ownerPlayer, GAMEPASS_IDS.AutoCollect) then
				stats.Cash.Value += amount
				data.TotalEarned += amount
				spawnAutoCollectVFX(dropperPad, amount)
			else
				-- Floats in place (Anchored) instead of physically falling, so it
				-- can never clip through the floor before a player can reach it.
				local ball = Instance.new("Part")
				ball.Shape = Enum.PartType.Ball
				ball.Size = Vector3.new(2.6, 1.7, 1.7)
				local restCFrame = dropperPad.CFrame * CFrame.new(0, 4, 0)
				ball.CFrame = restCFrame
				ball.BrickColor = BrickColor.new("Reddish brown")
				ball.Material = Enum.Material.Neon
				ball.Anchored = true
				ball.CanCollide = false
				ball.Parent = floorModel
				newBillboard(ball, formatCash(amount), 90)
				playSound(SOUND_IDS.CashCollect, ball, 0.25, false)

				local spinConn
				spinConn = RunService.Heartbeat:Connect(function()
					if not ball.Parent then
						spinConn:Disconnect()
						return
					end
					local t = os.clock()
					ball.CFrame = restCFrame * CFrame.new(0, math.sin(t * 3) * 0.6, 0) * CFrame.Angles(0, t * 2, 0)
				end)

				local collected = false
				local conn
				conn = ball.Touched:Connect(function(hit)
					if collected then return end
					local char = hit.Parent
					local plr = Players:GetPlayerFromCharacter(char)
					if plr and plot.owner == plr.UserId then
						collected = true
						local s = plr:FindFirstChild("leaderstats")
						if s then
							s.Cash.Value += amount
						end
						local d = dataByUserId[plr.UserId]
						if d then
							d.TotalEarned += amount
						end
						conn:Disconnect()
						ball:Destroy()
					end
				end)
				Debris:AddItem(ball, 15) -- despawn if left uncollected
			end
		end
	end)

	----------------------------------------------------------------
	-- UPGRADE STATIONS ("sign a player")
	----------------------------------------------------------------
	local upgradeSpacing = PLOT_SIZE / (#cfg.upgrades + 1)
	for u, upgradeCfg in ipairs(cfg.upgrades) do
		local zPos = -half + upgradeSpacing * u
		local station = newPart(
			Vector3.new(5, 6, 3),
			origin * CFrame.new(half - 6, y + 3.5, zPos),
			BrickColor.new("Really black"),
			floorModel
		)
		station.Name = "Upgrade_" .. floorIndex .. "_" .. u

		local _, label = newBillboard(
			station,
			upgradeCfg.name .. "\nCost: " .. formatCash(upgradeCfg.cost) .. "\n+" .. formatCash(upgradeCfg.boost) .. "/drop",
			220
		)

		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Sign Player"
		prompt.ObjectText = upgradeCfg.name
		prompt.HoldDuration = 0.5
		prompt.MaxActivationDistance = 10
		prompt.Parent = station

		local key = floorIndex .. "_" .. u

		local function markPurchased()
			label.Text = upgradeCfg.name .. "\n(SIGNED)"
			station.BrickColor = BrickColor.new("Bright green")
			prompt.Enabled = false
		end

		prompt.Triggered:Connect(function(player)
			if plot.owner ~= player.UserId then return end
			local data = dataByUserId[player.UserId]
			if data.Upgrades[key] then return end

			local stats = player:FindFirstChild("leaderstats")
			if not stats then return end
			if stats.Cash.Value < upgradeCfg.cost then
				remotes.Notify:FireClient(player, "Not Enough Cash", "You need " .. formatCash(upgradeCfg.cost) .. " to sign this player.", "error")
				return
			end

			stats.Cash.Value -= upgradeCfg.cost
			data.Upgrades[key] = true
			floorState.bonus += upgradeCfg.boost
			markPurchased()
			remotes.Notify:FireClient(player, "Player Signed!", upgradeCfg.name .. " joins the roster (+" .. formatCash(upgradeCfg.boost) .. "/drop)", "success")
			saveData(player)
		end)

		-- expose so restore-on-join can re-apply without re-charging
		floorState["restore_" .. key] = function()
			floorState.bonus += upgradeCfg.boost
			markPurchased()
		end
	end

	----------------------------------------------------------------
	-- UNLOCK-NEXT-FLOOR PROMPT
	----------------------------------------------------------------
	if floorIndex < MAX_FLOOR then
		local nextCfg = FloorConfig[floorIndex + 1]
		local unlockPad = newPart(
			Vector3.new(6, 6, 6),
			origin * CFrame.new(half - 5, y + 3.5, half - 5),
			BrickColor.new("Cyan"),
			floorModel,
			Enum.Material.Neon
		)
		unlockPad.Name = "UnlockNext"
		newBillboard(unlockPad, "Build Floor " .. (floorIndex + 1) .. ": " .. nextCfg.name .. "\nCost: " .. formatCash(nextCfg.unlockCost), 220)

		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Build Floor"
		prompt.ObjectText = nextCfg.name
		prompt.HoldDuration = 1
		prompt.MaxActivationDistance = 10
		prompt.Parent = unlockPad

		prompt.Triggered:Connect(function(player)
			if plot.owner ~= player.UserId then return end
			if plot.currentFloor ~= floorIndex then return end

			local stats = player:FindFirstChild("leaderstats")
			if not stats then return end
			if stats.Cash.Value < nextCfg.unlockCost then
				remotes.Notify:FireClient(player, "Not Enough Cash", "You need " .. formatCash(nextCfg.unlockCost) .. " to build " .. nextCfg.name .. ".", "error")
				return
			end

			stats.Cash.Value -= nextCfg.unlockCost
			unlockPad:Destroy()

			plot.currentFloor = floorIndex + 1
			stats.Floor.Value = plot.currentFloor
			dataByUserId[player.UserId].HighestFloor = plot.currentFloor

			buildFloor(plot, floorIndex + 1)
			applyTeamCosmetics(plot, dataByUserId[player.UserId])
			updateTycoonInfo(player)
			playSound(SOUND_IDS.FloorUnlock, Workspace, 0.6, false)
			remotes.Notify:FireClient(player, "Floor Unlocked!", "Welcome to " .. nextCfg.name .. "!", "success")
			saveData(player)
		end)
	end

	return floorState
end

----------------------------------------------------------------
-- CLAIM / RESTORE LOGIC
----------------------------------------------------------------

function ClaimPlotFn(plot, player)
	if plot.owner then return end -- already taken

	plot.owner = player.UserId
	plot.ownerPlayer = player
	plotByUserId[player.UserId] = plot

	local data = dataByUserId[player.UserId]
	if not data.TeamColorIndex or not JERSEY_COLOR_PRESETS[data.TeamColorIndex] then
		data.TeamColorIndex = ((plot.index - 1) % #JERSEY_COLOR_PRESETS) + 1
	end

	local existingPrompt = plot.sign:FindFirstChild("ProximityPrompt")
	if existingPrompt then
		existingPrompt:Destroy()
	end

	applyTeamCosmetics(plot, data)

	local targetFloor = math.max(1, data.HighestFloor)

	local stats = player:FindFirstChild("leaderstats")
	if stats then
		stats.Floor.Value = targetFloor
	end

	local floorStates = {}
	for f = 1, targetFloor do
		plot.currentFloor = f
		floorStates[f] = buildFloor(plot, f)
	end

	-- Re-apply previously purchased upgrades without re-charging the player
	for key, bought in pairs(data.Upgrades) do
		if bought then
			local floorIndexStr = key:match("^(%d+)_")
			local floorIndex = tonumber(floorIndexStr)
			local state = floorStates[floorIndex]
			if state and state["restore_" .. key] then
				state["restore_" .. key]()
			end
		end
	end

	applyTeamCosmetics(plot, data) -- refresh trophy label now that floors exist
	updateTycoonInfo(player)
	saveData(player)
end

local function releasePlot(plot)
	if not plot.owner then return end
	for f = 1, plot.currentFloor do
		plot.dropperConnections[f] = false
	end
	plot.owner = nil
	plot.ownerPlayer = nil
	plot.currentFloor = 0
	for _, floorModel in pairs(plot.floorParts) do
		floorModel:Destroy()
	end
	plot.floorParts = {}
	plot.accentParts = {}
	plot.trophyLabel = nil
	plot.jerseyColor = plot.color
	plot.sign.BrickColor = plot.color
	plot.signLabel.Text = "UNCLAIMED\nTeam Plot " .. plot.index

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Claim This Team"
	prompt.ObjectText = "Team Plot " .. plot.index
	prompt.HoldDuration = 1
	prompt.MaxActivationDistance = 12
	prompt.Parent = plot.sign
	prompt.Triggered:Connect(function(player)
		ClaimPlotFn(plot, player)
	end)
end

----------------------------------------------------------------
-- PRESTIGE ("Win the Super Bowl" — retire & rebuild for a permanent bonus)
----------------------------------------------------------------

function PrestigePlotFn(plot, player)
	if plot.owner ~= player.UserId then return end
	local data = dataByUserId[player.UserId]
	if not data then return end
	if plot.currentFloor ~= MAX_FLOOR then return end
	if not (data.Upgrades["5_1"] and data.Upgrades["5_2"]) then
		remotes.Notify:FireClient(player, "Not Ready", "Sign your Hall of Fame Legend and name the stadium before you can go for the ring.", "error")
		return
	end

	local stats = player:FindFirstChild("leaderstats")
	if not stats then return end
	if stats.Cash.Value < PRESTIGE_COST then
		remotes.Notify:FireClient(player, "Not Enough Cash", "You need " .. formatCash(PRESTIGE_COST) .. " to retire and rebuild.", "error")
		return
	end

	stats.Cash.Value = 0 -- the prestige cost is paid by resetting the till entirely
	data.PrestigeLevel += 1
	data.HighestFloor = 0
	data.Upgrades = {}

	for f = 1, plot.currentFloor do
		plot.dropperConnections[f] = false
	end
	for _, floorModel in pairs(plot.floorParts) do
		floorModel:Destroy()
	end
	plot.floorParts = {}
	plot.accentParts = {}
	plot.trophyLabel = nil
	plot.currentFloor = 0

	spawnConfetti(plot)
	playSound(SOUND_IDS.Prestige, Workspace, 0.8, false)
	remotes.Notify:FireClient(
		player,
		"\xF0\x9F\x8F\x86 CHAMPIONSHIP WON!",
		"Ring #" .. data.PrestigeLevel .. " earned! Permanent bonus: +" .. math.floor(PRESTIGE_BONUS_PER_LEVEL * 100 * data.PrestigeLevel) .. "% cash.",
		"prestige"
	)

	plot.currentFloor = 1
	buildFloor(plot, 1)
	stats.Floor.Value = 1
	data.HighestFloor = 1
	applyTeamCosmetics(plot, data)
	updateTycoonInfo(player)

	saveData(player)
end

----------------------------------------------------------------
-- WORLD DRESSING (welcome arch + physical leaderboard)
----------------------------------------------------------------

local function buildWelcomeArch(centerX)
	local archModel = Instance.new("Model")
	archModel.Name = "WelcomeArch"
	archModel.Parent = Workspace

	local archZ = -PLOT_SIZE / 2 - 45
	local gold = BrickColor.new("New Yeller")

	-- Plaza floor: dark concrete with a glowing gold ring inlay
	newPart(Vector3.new(46, 1, 46), CFrame.new(centerX, 0.5, archZ), BrickColor.new("Smoky grey"), archModel, Enum.Material.Concrete)
	local ring = newPart(Vector3.new(1, 34, 34), CFrame.new(centerX, 1.05, archZ), gold, archModel, Enum.Material.Neon)
	ring.Shape = Enum.PartType.Cylinder
	ring.Orientation = Vector3.new(0, 0, 90)
	local ringCore = newPart(Vector3.new(1, 32, 32), CFrame.new(centerX, 1.06, archZ), BrickColor.new("Smoky grey"), archModel, Enum.Material.Concrete)
	ringCore.Shape = Enum.PartType.Cylinder
	ringCore.Orientation = Vector3.new(0, 0, 90)

	-- Twin pillars with a glowing marquee crossbar
	for _, side in ipairs({ -1, 1 }) do
		local pillarX = centerX + side * 16
		newPart(Vector3.new(3, 24, 3), CFrame.new(pillarX, 12, archZ), BrickColor.new("Dark stone grey"), archModel, Enum.Material.Metal)
		local cap = newPart(Vector3.new(3.6, 0.6, 3.6), CFrame.new(pillarX, 24.3, archZ), gold, archModel, Enum.Material.Neon)
		cap.Shape = Enum.PartType.Cylinder
		cap.Orientation = Vector3.new(0, 0, 90)

		local flagPole = newPart(Vector3.new(0.3, 10, 0.3), CFrame.new(pillarX, 26, archZ), BrickColor.new("Dark stone grey"), archModel, Enum.Material.Metal)
		local flag = newPart(Vector3.new(0.15, 4, 6), CFrame.new(pillarX + side * 3, 29, archZ), BrickColor.new("Bright red"), archModel, Enum.Material.SmoothPlastic)
	end

	local marquee = newPart(Vector3.new(38, 5, 2), CFrame.new(centerX, 22, archZ), BrickColor.new("Really black"), archModel, Enum.Material.Metal)
	local marqueeGlow = newPart(Vector3.new(36, 3.4, 0.4), CFrame.new(centerX, 22, archZ - 1.2), gold, archModel, Enum.Material.Neon)
	newBillboard(marqueeGlow, "\xF0\x9F\x8F\x88 NFL FRANCHISE TYCOON \xF0\x9F\x8F\x88", 560)

	local spotLight = Instance.new("PointLight")
	spotLight.Color = Color3.fromRGB(255, 230, 150)
	spotLight.Range = 40
	spotLight.Brightness = 3
	spotLight.Parent = marqueeGlow

	local spawnLocation = Instance.new("SpawnLocation")
	spawnLocation.Size = Vector3.new(10, 1, 10)
	spawnLocation.CFrame = CFrame.new(centerX, 1, archZ + 8)
	spawnLocation.Anchored = true
	spawnLocation.CanCollide = true
	spawnLocation.Transparency = 1
	spawnLocation.Neutral = true
	spawnLocation.Parent = archModel

	return archModel
end

local function buildLeaderboardBoard(position)
	local standModel = Instance.new("Model")
	standModel.Name = "LeaderboardStand"
	standModel.Parent = Workspace

	local boardCFrame = CFrame.new(position)

	-- Support legs, running from the ground up to the board
	for _, side in ipairs({ -1, 1 }) do
		newPart(
			Vector3.new(1.2, position.Y, 1.2),
			boardCFrame * CFrame.new(side * 8, -position.Y / 2, 0),
			BrickColor.new("Dark stone grey"),
			standModel,
			Enum.Material.Metal
		)
	end

	-- Frame + screen
	local frame = newPart(Vector3.new(22, 13, 1.4), boardCFrame, BrickColor.new("Really black"), standModel, Enum.Material.Metal)
	local trim = newPart(Vector3.new(22.6, 13.6, 0.6), boardCFrame * CFrame.new(0, 0, 0.5), BrickColor.new("New Yeller"), standModel, Enum.Material.Neon)

	local board = newPart(Vector3.new(20, 12, 1), boardCFrame * CFrame.new(0, 0, -0.3), BrickColor.new("Really black"), standModel, Enum.Material.Metal)
	board.Name = "LeaderboardBoard"

	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Face = Enum.NormalId.Front
	surfaceGui.LightInfluence = 0
	surfaceGui.Parent = board

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundColor3 = Color3.fromRGB(8, 10, 14)
	label.TextColor3 = Color3.fromRGB(255, 215, 0)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = "TOP FRANCHISES\n\nLoading..."
	label.Parent = surfaceGui

	table.insert(boardLabels, label)
	return standModel
end

----------------------------------------------------------------
-- BUILD ALL PLOTS AT SERVER START
----------------------------------------------------------------

for i = 1, NUM_PLOTS do
	plots[i] = createBasePlot(i)
end

local centerX = ((NUM_PLOTS - 1) * PLOT_SPACING) / 2
buildWelcomeArch(centerX)
buildLeaderboardBoard(Vector3.new(centerX, 7, -PLOT_SIZE / 2 - 65))

if SOUND_IDS.StadiumAmbience ~= 0 then
	local ambience = playSound(SOUND_IDS.StadiumAmbience, SoundService, 0.3, true)
	if ambience then
		ambience.Name = "StadiumAmbience"
	end
end

task.spawn(function()
	while true do
		refreshLeaderboardCache()
		task.wait(60)
	end
end)

----------------------------------------------------------------
-- REMOTE HANDLERS
----------------------------------------------------------------

remotes.ConfirmCustomize.OnServerEvent:Connect(function(player, rawName, colorIndex)
	local last = customizeDebounce[player.UserId]
	if last and os.clock() - last < 2 then return end
	customizeDebounce[player.UserId] = os.clock()

	local plot = plotByUserId[player.UserId]
	local data = dataByUserId[player.UserId]
	if not plot or not data then return end

	colorIndex = tonumber(colorIndex)
	if type(colorIndex) ~= "number" or not JERSEY_COLOR_PRESETS[colorIndex] then
		colorIndex = data.TeamColorIndex
	end

	local filtered = filterTeamName(player, rawName)
	if filtered then
		data.TeamName = filtered
	end
	data.TeamColorIndex = colorIndex

	applyTeamCosmetics(plot, data)
	updateTycoonInfo(player)
	saveData(player)
	remotes.Notify:FireClient(player, "Team Updated", "Your franchise now appears as \"" .. data.TeamName .. "\"", "success")
end)

----------------------------------------------------------------
-- GAME PASSES
----------------------------------------------------------------

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
	if not wasPurchased then return end
	passOwnership[player.UserId] = passOwnership[player.UserId] or {}
	passOwnership[player.UserId][gamePassId] = true

	if gamePassId == GAMEPASS_IDS.VIP and gamePassId ~= 0 then
		local char = player.Character
		if char then
			local humanoid = char:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.WalkSpeed = 22
			end
		end
	end

	remotes.Notify:FireClient(player, "Purchase Complete", "Thanks for supporting the franchise!", "success")
end)

----------------------------------------------------------------
-- PLAYER JOIN / LEAVE
----------------------------------------------------------------

Players.PlayerAdded:Connect(function(player)
	local data = loadData(player)
	dataByUserId[player.UserId] = data

	setupLeaderstats(player, data.Cash)
	setupTycoonInfo(player, data)

	player.CharacterAdded:Connect(function(char)
		if playerOwnsPass(player, GAMEPASS_IDS.VIP) then
			local humanoid = char:WaitForChild("Humanoid")
			humanoid.WalkSpeed = 22
		end
	end)

	-- If they have saved progress (HighestFloor > 0), auto-claim any open plot
	if data.HighestFloor and data.HighestFloor > 0 then
		for _, plot in ipairs(plots) do
			if not plot.owner then
				ClaimPlotFn(plot, player)
				break
			end
		end
	else
		updateTycoonInfo(player)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	saveData(player)
	local plot = plotByUserId[player.UserId]
	if plot then
		-- Keep the build standing (so others can see it) but free ownership
		-- only if you want plots to recycle. Comment out releasePlot() below
		-- if you'd rather leave finished team buildings permanently in world.
		releasePlot(plot)
		plotByUserId[player.UserId] = nil
	end
	dataByUserId[player.UserId] = nil
	passOwnership[player.UserId] = nil
	customizeDebounce[player.UserId] = nil
end)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		saveData(player)
	end
end)

print("NFL Franchise Tycoon loaded — " .. NUM_PLOTS .. " plots ready, " .. MAX_FLOOR .. " floors each.")
