--[[
	ROLL A PUMPKIN — Main Server Script
	-----------------------------------------------------------
	HOW TO INSTALL:
	1. In Roblox Studio, go to ServerScriptService.
	2. Insert a new Script (not LocalScript) named "RollAPumpkinServer".
	3. Delete the default line and paste this entire file in.
	4. Go to StarterPlayer > StarterPlayerScripts, insert a new LocalScript
	   named "RollAPumpkinClient", and paste in RollAPumpkinClient.lua (the
	   sibling file). It drives the bowling animation, the rolling pumpkin,
	   the camera, and all of the on-screen UI.
	5. Hit Play. The world builds itself — the bowling approach, 4 lanes,
	   6 themed zones, ramps, pins, distance markers, everything.
	6. For DataStores to save while testing in Studio:
	   Game Settings > Security > "Enable Studio Access to API Services" = ON.

	HOW THE GAME WORKS:
	  - Every second you gain +Strength (+1 base, multiplied by your pumpkin,
	    your rebirths, and the 2x Strength pass).
	  - Stand on a glowing pad at the start of a lane, time the power meter,
	    and bowl your pumpkin. Strength + timing decide how far it rolls.
	  - Distance pays out Wins. Spend Wins on better pumpkins (bigger
	    Strength multipliers), or Rebirth for a permanent bonus.

	No external models or plugins required. Everything is generated at
	runtime with Instance.new().
	-----------------------------------------------------------
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")

-- Wrapped in pcall so the game still builds and runs (just unsaved) when
-- DataStores aren't reachable, e.g. Studio without API access turned on.
local dataStore
do
	local ok, storeOrErr = pcall(function()
		return DataStoreService:GetDataStore("RollAPumpkinData_v1")
	end)
	if ok then
		dataStore = storeOrErr
	else
		warn("[Roll a Pumpkin] DataStores unavailable — progress will NOT be saved this session. " ..
			"To fix: Game Settings > Security > Enable Studio Access to API Services (for Studio testing), " ..
			"or publish the game (works automatically live).")
	end
end

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------

-- Fill these in with your own Game Pass ids from Studio's Monetization tab.
-- Leave at 0 to keep a pass disabled (its shop button shows "Soon").
-- The client reads these from the server, so there is only one place to edit.
local GAMEPASS_IDS = {
	DoubleStrength = 0,
	DoubleWins     = 0,
}

-- Fill these in with your own uploaded/toolbox audio asset ids (plain
-- numbers). Leave at 0 to keep that sound disabled.
local SOUND_IDS = {
	Roll    = 0, -- looped rumble while the pumpkin rolls
	Release = 0, -- whoosh as the pumpkin leaves the hand
	Land    = 0, -- thud when it lands off a ramp
	Strike  = 0, -- pins crashing
	Finish  = 0, -- pumpkin comes to a stop
	Rebirth = 0,
	Buy     = 0,
}

-- Track layout
local LANE_COUNT = 4
local LANE_WIDTH = 12
local GUTTER_WIDTH = 3
local LANE_PITCH = LANE_WIDTH + GUTTER_WIDTH * 2 + 2 -- lane + gutters + divider
local LANE_TOP_Y = 1
local ORIGIN_Z = 0            -- distance 0 = the foul line
local ZONE_LENGTH = 1000
local PUMPKIN_RADIUS = 1.6
local RAMP_START = 150        -- first ramp
local RAMP_SPACING = 250      -- a ramp every N studs after that
local PIN_SETS = { 95, 495, 995, 1995, 2995, 3995, 4995, 5970 }

-- Progression / balance
local STRENGTH_PER_SECOND = 1
local DISTANCE_SCALE = 8        -- distance = SCALE * strength ^ EXPONENT * power
local DISTANCE_EXPONENT = 0.6
local MIN_DISTANCE = 6
local MIN_POWER = 0.15          -- worst possible timing still gives 15% power
local PERFECT_WINDOW = 0.05     -- needle within this of the centre = PERFECT
local PERFECT_BONUS = 1.25
local WINS_PER_STUD = 0.25
local ZONE_BONUS_WINS = 250     -- first time reaching zone k pays k^2 * this
local REBIRTH_BASE_COST = 2500
local REBIRTH_COST_GROWTH = 3
local REBIRTH_BONUS = 0.5       -- +50% Strength and Wins per rebirth
local WINDUP_TIME = 1.2         -- seconds from click to the pumpkin leaving the hand
local AUTOSAVE_INTERVAL = 90

local Zones = {
	{
		name = "Pumpkin Patch", decor = "patch",
		ground = { 92, 148, 62 }, accent = { 255, 140, 30 },
		lighting = { clock = 16.8, ambient = { 110, 90, 70 }, outdoor = { 170, 140, 110 }, atmo = { 255, 200, 150 }, density = 0.28 },
	},
	{
		name = "Cornfield", decor = "corn",
		ground = { 168, 150, 72 }, accent = { 255, 214, 80 },
		lighting = { clock = 17.6, ambient = { 120, 90, 60 }, outdoor = { 180, 130, 90 }, atmo = { 255, 180, 120 }, density = 0.32 },
	},
	{
		name = "Haunted Woods", decor = "woods",
		ground = { 52, 62, 46 }, accent = { 160, 90, 255 },
		lighting = { clock = 18.5, ambient = { 70, 60, 100 }, outdoor = { 90, 80, 130 }, atmo = { 120, 90, 170 }, density = 0.42 },
	},
	{
		name = "Graveyard", decor = "graves",
		ground = { 72, 76, 72 }, accent = { 170, 210, 255 },
		lighting = { clock = 20.5, ambient = { 70, 80, 110 }, outdoor = { 80, 95, 130 }, atmo = { 90, 110, 150 }, density = 0.45 },
	},
	{
		name = "Witch Swamp", decor = "swamp",
		ground = { 44, 70, 50 }, accent = { 110, 255, 110 },
		lighting = { clock = 19.2, ambient = { 60, 100, 60 }, outdoor = { 80, 130, 80 }, atmo = { 100, 170, 100 }, density = 0.45 },
	},
	{
		name = "Candy Kingdom", decor = "candy",
		ground = { 255, 176, 214 }, accent = { 255, 90, 180 },
		lighting = { clock = 14.5, ambient = { 150, 110, 140 }, outdoor = { 220, 170, 210 }, atmo = { 255, 190, 230 }, density = 0.3 },
	},
}

local TRACK_LENGTH = #Zones * ZONE_LENGTH - 20 -- max distance; stops just short of the finish wall

-- Pumpkins you can buy with Wins. `mult` multiplies Strength gained per second.
-- Colours are {r, g, b}. Order = shop order. The first one is the free starter.
local Pumpkins = {
	{ id = "classic",   name = "Classic Pumpkin", cost = 0,       mult = 1,
		color = { 232, 125, 35 }, rib = { 200, 96, 22 }, stem = { 96, 120, 50 }, trail = { 255, 160, 60 } },
	{ id = "jack",      name = "Jack-o'-Lantern", cost = 150,     mult = 2,
		color = { 240, 130, 30 }, rib = { 205, 98, 20 }, stem = { 90, 110, 45 }, trail = { 255, 200, 80 },
		face = true, glow = { 255, 190, 60 } },
	{ id = "candycorn", name = "Candy Corn",       cost = 1000,    mult = 4,
		color = { 255, 186, 40 }, rib = { 255, 245, 230 }, stem = { 240, 110, 30 }, trail = { 255, 240, 200 },
		face = true, glow = { 255, 110, 20 } },
	{ id = "ghost",     name = "Ghost Pumpkin",    cost = 5000,    mult = 8,
		color = { 235, 240, 255 }, rib = { 200, 215, 240 }, stem = { 150, 160, 180 }, trail = { 170, 220, 255 },
		face = true, glow = { 120, 200, 255 }, transparency = 0.3 },
	{ id = "witch",     name = "Witch Pumpkin",    cost = 20000,   mult = 15,
		color = { 120, 50, 170 }, rib = { 80, 30, 120 }, stem = { 30, 30, 30 }, trail = { 170, 90, 255 },
		face = true, glow = { 120, 255, 90 } },
	{ id = "toxic",     name = "Toxic Pumpkin",    cost = 80000,   mult = 25,
		color = { 80, 200, 60 }, rib = { 170, 255, 60 }, stem = { 40, 70, 30 }, trail = { 150, 255, 80 },
		face = true, glow = { 230, 255, 90 }, ribMaterial = "Neon", sparkles = true },
	{ id = "golden",    name = "Golden Pumpkin",   cost = 300000,  mult = 50,
		color = { 255, 200, 50 }, rib = { 225, 165, 25 }, stem = { 140, 100, 30 }, trail = { 255, 230, 120 },
		face = true, glow = { 255, 255, 210 }, material = "Foil", sparkles = true },
	{ id = "galaxy",    name = "Galaxy Pumpkin",   cost = 1500000, mult = 100,
		color = { 40, 22, 90 }, rib = { 140, 70, 255 }, stem = { 255, 120, 255 }, trail = { 255, 120, 255 },
		face = true, glow = { 255, 140, 255 }, ribMaterial = "Neon", sparkles = true },
}

local PumpkinById = {}
for _, def in ipairs(Pumpkins) do
	PumpkinById[def.id] = def
end

local LANE_CENTERS = {}
for i = 1, LANE_COUNT do
	LANE_CENTERS[i] = (i - (LANE_COUNT + 1) / 2) * LANE_PITCH
end
local TRACK_HALF_WIDTH = LANE_COUNT * LANE_PITCH / 2

----------------------------------------------------------------
-- REMOTES (+ shared config the client reads)
----------------------------------------------------------------

local remotesFolder = Instance.new("Folder")
remotesFolder.Name = "RollAPumpkinRemotes"

local remotes = {}
for _, name in ipairs({ "RequestBowl", "BowlStarted", "BowlResult", "Notify" }) do
	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = remotesFolder
	remotes[name] = event
end
for _, name in ipairs({ "BuyPumpkin", "EquipPumpkin", "Rebirth" }) do
	local fn = Instance.new("RemoteFunction")
	fn.Name = name
	fn.Parent = remotesFolder
	remotes[name] = fn
end

local configValue = Instance.new("StringValue")
configValue.Name = "Config"
configValue.Value = HttpService:JSONEncode({
	laneCenters = LANE_CENTERS,
	laneWidth = LANE_WIDTH,
	laneTopY = LANE_TOP_Y,
	originZ = ORIGIN_Z,
	zoneLength = ZONE_LENGTH,
	trackLength = TRACK_LENGTH,
	radius = PUMPKIN_RADIUS,
	rampStart = RAMP_START,
	rampSpacing = RAMP_SPACING,
	perfectWindow = PERFECT_WINDOW,
	windup = WINDUP_TIME,
	rebirthBonus = REBIRTH_BONUS,
	zones = Zones,
	pumpkins = Pumpkins,
	passes = GAMEPASS_IDS,
	sounds = SOUND_IDS,
})
configValue.Parent = remotesFolder

----------------------------------------------------------------
-- WORLD HELPERS
----------------------------------------------------------------

local function rgb(t)
	return Color3.fromRGB(t[1], t[2], t[3])
end

local function makePart(parent, size, cframe, color, material, props)
	local p = Instance.new("Part")
	p.Anchored = true
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if props then
		for k, v in pairs(props) do
			p[k] = v
		end
	end
	p.Parent = parent
	return p
end

local function addSurfaceText(part, text, textColor, pixelsPerStud, face)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face or Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pixelsPerStud or 30
	gui.LightInfluence = 0
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = textColor or Color3.new(1, 1, 1)
	label.Parent = gui

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.08, 0)
	pad.PaddingBottom = UDim.new(0.08, 0)
	pad.PaddingLeft = UDim.new(0.04, 0)
	pad.PaddingRight = UDim.new(0.04, 0)
	pad.Parent = label

	local s = Instance.new("UIStroke")
	s.Thickness = 3
	s.Color = Color3.fromRGB(30, 15, 5)
	s.Parent = label
	return label
end

local function addLight(part, color, range, brightness)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range or 16
	light.Brightness = brightness or 1.5
	light.Shadows = false
	light.Parent = part
	return light
end

----------------------------------------------------------------
-- ATMOSPHERE (the client tweens these per zone as the camera moves)
----------------------------------------------------------------

Lighting.ClockTime = Zones[1].lighting.clock
Lighting.Brightness = 2.4
Lighting.Ambient = rgb(Zones[1].lighting.ambient)
Lighting.OutdoorAmbient = rgb(Zones[1].lighting.outdoor)
Lighting.ColorShift_Top = Color3.fromRGB(255, 200, 150)
Lighting.EnvironmentSpecularScale = 1
Lighting.EnvironmentDiffuseScale = 0.4
Lighting.GeographicLatitude = 30

for _, child in ipairs(Lighting:GetChildren()) do
	if child:IsA("Atmosphere") or child:IsA("PostEffect") then
		child:Destroy()
	end
end

local atmosphere = Instance.new("Atmosphere")
atmosphere.Density = Zones[1].lighting.density
atmosphere.Offset = 0.1
atmosphere.Color = rgb(Zones[1].lighting.atmo)
atmosphere.Decay = Color3.fromRGB(140, 90, 90)
atmosphere.Glare = 0.4
atmosphere.Haze = 1.4
atmosphere.Parent = Lighting

local bloom = Instance.new("BloomEffect")
bloom.Intensity = 0.6
bloom.Size = 24
bloom.Threshold = 1.6
bloom.Parent = Lighting

local sunRays = Instance.new("SunRaysEffect")
sunRays.Intensity = 0.08
sunRays.Spread = 0.6
sunRays.Parent = Lighting

local colorCorrection = Instance.new("ColorCorrectionEffect")
colorCorrection.Saturation = 0.15
colorCorrection.Contrast = 0.08
colorCorrection.TintColor = Color3.fromRGB(255, 245, 235)
colorCorrection.Parent = Lighting

----------------------------------------------------------------
-- WORLD BUILD
----------------------------------------------------------------

-- A fresh baseplate template ships with a Baseplate and SpawnLocation that
-- would z-fight with / sit in the middle of our lanes.
do
	local oldBaseplate = Workspace:FindFirstChild("Baseplate")
	if oldBaseplate and oldBaseplate:IsA("BasePart") then
		oldBaseplate:Destroy()
	end
	for _, d in ipairs(Workspace:GetDescendants()) do
		if d:IsA("SpawnLocation") then
			d:Destroy()
		end
	end
end

local world = Instance.new("Folder")
world.Name = "RollAPumpkinWorld"
world.Parent = Workspace

local trackFolder = Instance.new("Folder")
trackFolder.Name = "Track"
trackFolder.Parent = world

local decorFolder = Instance.new("Folder")
decorFolder.Name = "Decor"
decorFolder.Parent = world

local padsFolder = Instance.new("Folder")
padsFolder.Name = "Pads"
padsFolder.Parent = world

local pinsFolder = Instance.new("Folder")
pinsFolder.Name = "Pins"
pinsFolder.Parent = world

local WOOD = Color3.fromRGB(226, 186, 136)
local DARK = Color3.fromRGB(38, 34, 40)

-- Decorations, one builder per zone theme. Each places one "item" at pos (ground level).
local DecorBuilders = {}

function DecorBuilders.patch(folder, pos, rng)
	if rng:NextNumber() < 0.25 then
		-- hay bale
		makePart(folder, Vector3.new(6, 3, 4), CFrame.new(pos + Vector3.new(0, 1.5, 0)) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0),
			Color3.fromRGB(214, 184, 100), Enum.Material.Fabric)
		return
	end
	local d = rng:NextNumber(2.5, 6.5)
	local body = makePart(folder, Vector3.new(d, d, d), CFrame.new(pos + Vector3.new(0, d * 0.42, 0)),
		Color3.fromRGB(235, 120 + rng:NextInteger(-10, 15), 30), Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Ball })
	body.CastShadow = true
	makePart(folder, Vector3.new(d * 0.3, d * 0.12, d * 0.12),
		CFrame.new(pos + Vector3.new(0, d * 0.92, 0)) * CFrame.Angles(0, 0, math.pi / 2 + 0.3),
		Color3.fromRGB(90, 115, 45), Enum.Material.Wood, { Shape = Enum.PartType.Cylinder })
end

function DecorBuilders.corn(folder, pos, rng)
	for _ = 1, 3 do
		local h = rng:NextNumber(9, 14)
		local off = Vector3.new(rng:NextNumber(-3, 3), 0, rng:NextNumber(-3, 3))
		makePart(folder, Vector3.new(h, 0.55, 0.55),
			CFrame.new(pos + off + Vector3.new(0, h / 2, 0)) * CFrame.Angles(rng:NextNumber(-0.08, 0.08), 0, math.pi / 2),
			Color3.fromRGB(130, 160, 55), Enum.Material.Grass, { Shape = Enum.PartType.Cylinder })
	end
	makePart(folder, Vector3.new(1, 2.4, 1), CFrame.new(pos + Vector3.new(0.6, 8, 0)) * CFrame.Angles(0, 0, 0.3),
		Color3.fromRGB(255, 214, 70), Enum.Material.SmoothPlastic)
end

function DecorBuilders.woods(folder, pos, rng)
	local h = rng:NextNumber(14, 26)
	local trunkColor = Color3.fromRGB(58, 44, 40)
	makePart(folder, Vector3.new(1.8, h, 1.8), CFrame.new(pos + Vector3.new(0, h / 2, 0)), trunkColor, Enum.Material.Wood)
	for _, dir in ipairs({ -1, 1 }) do
		local len = h * rng:NextNumber(0.3, 0.45)
		makePart(folder, Vector3.new(0.7, len, 0.7),
			CFrame.new(pos + Vector3.new(dir * len * 0.35, h * rng:NextNumber(0.6, 0.85), 0)) * CFrame.Angles(0, rng:NextNumber(-0.6, 0.6), -dir * 0.75),
			trunkColor, Enum.Material.Wood)
	end
	if rng:NextNumber() < 0.3 then
		-- glowing eyes peering out of the trunk, facing the lanes
		local faceX = pos.X > 0 and -0.95 or 0.95
		for _, side in ipairs({ -0.35, 0.35 }) do
			makePart(folder, Vector3.new(0.1, 0.25, 0.45), CFrame.new(pos + Vector3.new(faceX, h * 0.45, side)),
				Color3.fromRGB(200, 120, 255), Enum.Material.Neon, { CanCollide = false })
		end
	end
end

function DecorBuilders.graves(folder, pos, rng)
	local stone = Color3.fromRGB(118, 118, 124)
	local tilt = CFrame.Angles(rng:NextNumber(-0.12, 0.12), rng:NextNumber(-0.3, 0.3), rng:NextNumber(-0.12, 0.12))
	local base = CFrame.new(pos) * tilt
	makePart(folder, Vector3.new(3, 3.5, 0.8), base * CFrame.new(0, 1.75, 0), stone, Enum.Material.Slate)
	makePart(folder, Vector3.new(0.8, 3, 3), base * CFrame.new(0, 3.5, 0) * CFrame.Angles(0, math.pi / 2, 0),
		stone, Enum.Material.Slate, { Shape = Enum.PartType.Cylinder })
	if rng:NextNumber() < 0.18 then
		local ghost = makePart(folder, Vector3.new(3, 3, 3), CFrame.new(pos + Vector3.new(rng:NextNumber(-4, 4), 7, 0)),
			Color3.fromRGB(230, 240, 255), Enum.Material.Neon, { Shape = Enum.PartType.Ball, Transparency = 0.45, CanCollide = false })
		addLight(ghost, Color3.fromRGB(170, 210, 255), 12, 1)
	end
end

function DecorBuilders.swamp(folder, pos, rng)
	if rng:NextNumber() < 0.55 then
		local d = rng:NextNumber(8, 18)
		makePart(folder, Vector3.new(0.2, d, d), CFrame.new(pos + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.pi / 2),
			Color3.fromRGB(70, 140, 60), Enum.Material.Glass, { Shape = Enum.PartType.Cylinder, Transparency = 0.15, CanCollide = false })
		return
	end
	makePart(folder, Vector3.new(4.5, 4.5, 4.5), CFrame.new(pos + Vector3.new(0, 2.2, 0)),
		Color3.fromRGB(25, 25, 28), Enum.Material.Metal, { Shape = Enum.PartType.Ball })
	local brew = makePart(folder, Vector3.new(0.3, 3.6, 3.6), CFrame.new(pos + Vector3.new(0, 3.9, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Color3.fromRGB(120, 255, 90), Enum.Material.Neon, { Shape = Enum.PartType.Cylinder })
	local bubbles = Instance.new("ParticleEmitter")
	bubbles.Color = ColorSequence.new(Color3.fromRGB(140, 255, 110))
	bubbles.LightEmission = 0.8
	bubbles.Size = NumberSequence.new(0.5, 0.1)
	bubbles.Lifetime = NumberRange.new(1, 1.6)
	bubbles.Speed = NumberRange.new(2, 4)
	bubbles.Rate = 5
	bubbles.EmissionDirection = Enum.NormalId.Right -- cylinder's +X is world up here
	bubbles.Parent = brew
	addLight(brew, Color3.fromRGB(120, 255, 90), 12, 1.2)
end

local CANDY_COLORS = {
	Color3.fromRGB(255, 90, 160), Color3.fromRGB(110, 200, 255), Color3.fromRGB(255, 220, 80),
	Color3.fromRGB(150, 255, 140), Color3.fromRGB(200, 130, 255),
}

function DecorBuilders.candy(folder, pos, rng)
	local color = CANDY_COLORS[rng:NextInteger(1, #CANDY_COLORS)]
	if rng:NextNumber() < 0.4 then
		local d = rng:NextNumber(4, 8)
		makePart(folder, Vector3.new(d, d, d), CFrame.new(pos), color, Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Ball })
		return
	end
	local h = rng:NextNumber(8, 13)
	makePart(folder, Vector3.new(h, 0.5, 0.5), CFrame.new(pos + Vector3.new(0, h / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder })
	local center = CFrame.new(pos + Vector3.new(0, h + 2.5, 0)) * CFrame.Angles(0, math.pi / 2, 0)
	makePart(folder, Vector3.new(0.8, 6, 6), center, color, Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder })
	makePart(folder, Vector3.new(0.9, 3.8, 3.8), center, Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder })
	makePart(folder, Vector3.new(1, 1.8, 1.8), center, color, Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder })
end

local function buildArch(z, text, accent, height, textColor)
	local arch = Instance.new("Model")
	arch.Name = "Arch"
	local x = TRACK_HALF_WIDTH + 6
	for _, side in ipairs({ -1, 1 }) do
		makePart(arch, Vector3.new(3, height, 3), CFrame.new(side * x, height / 2, z), DARK, Enum.Material.Slate)
		local cap = makePart(arch, Vector3.new(4, 4, 4), CFrame.new(side * x, height + 2, z), Color3.fromRGB(235, 120, 30),
			Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Ball })
		addLight(cap, Color3.fromRGB(255, 160, 60), 20, 1.4)
	end
	local beam = makePart(arch, Vector3.new(x * 2 + 3, 6, 2), CFrame.new(0, height - 3, z), DARK, Enum.Material.Slate)
	addSurfaceText(beam, text, textColor or Color3.new(1, 1, 1), 12)
	local strip = makePart(arch, Vector3.new(x * 2 + 3, 0.6, 2.2), CFrame.new(0, height - 6.2, z), accent, Enum.Material.Neon)
	addLight(strip, accent, 30, 1.5)
	arch.Parent = trackFolder
	return arch
end

local function buildPin(parent, pos)
	local pin = Instance.new("Model")
	pin.Name = "Pin"
	local white = Color3.fromRGB(245, 245, 245)
	local body = makePart(pin, Vector3.new(2.2, 0.75, 0.75), CFrame.new(pos + Vector3.new(0, 1.1, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		white, Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder, CanCollide = false })
	makePart(pin, Vector3.new(0.22, 0.8, 0.8), CFrame.new(pos + Vector3.new(0, 1.85, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Color3.fromRGB(220, 40, 40), Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Cylinder, CanCollide = false })
	makePart(pin, Vector3.new(0.85, 0.85, 0.85), CFrame.new(pos + Vector3.new(0, 2.45, 0)),
		white, Enum.Material.SmoothPlastic, { Shape = Enum.PartType.Ball, CanCollide = false })
	pin.PrimaryPart = body
	pin.Parent = parent
end

-- Ground: one slab per zone plus the start area and a strip past the finish.
makePart(trackFolder, Vector3.new(900, 1, 320), CFrame.new(0, -0.5, ORIGIN_Z - 160), rgb(Zones[1].ground), Enum.Material.Grass)
makePart(trackFolder, Vector3.new(900, 1, 320), CFrame.new(0, -0.5, ORIGIN_Z + #Zones * ZONE_LENGTH + 160),
	rgb(Zones[#Zones].ground), Enum.Material.Grass)

for zi, zone in ipairs(Zones) do
	local z0 = ORIGIN_Z + (zi - 1) * ZONE_LENGTH
	local zc = z0 + ZONE_LENGTH / 2
	local groundMat = zone.decor == "candy" and Enum.Material.SmoothPlastic or Enum.Material.Grass
	makePart(trackFolder, Vector3.new(900, 1, ZONE_LENGTH), CFrame.new(0, -0.5, zc), rgb(zone.ground), groundMat)

	for _, cx in ipairs(LANE_CENTERS) do
		makePart(trackFolder, Vector3.new(LANE_WIDTH, LANE_TOP_Y, ZONE_LENGTH), CFrame.new(cx, LANE_TOP_Y / 2, zc),
			WOOD, Enum.Material.WoodPlanks)
		for _, side in ipairs({ -1, 1 }) do
			makePart(trackFolder, Vector3.new(GUTTER_WIDTH, 0.4, ZONE_LENGTH),
				CFrame.new(cx + side * (LANE_WIDTH + GUTTER_WIDTH) / 2, 0.2, zc), DARK, Enum.Material.Metal)
		end
	end
	for j = 0, LANE_COUNT do
		local x = -TRACK_HALF_WIDTH + j * LANE_PITCH
		makePart(trackFolder, Vector3.new(2, 1.6, ZONE_LENGTH), CFrame.new(x, 0.8, zc), DARK, Enum.Material.Slate)
		makePart(trackFolder, Vector3.new(2.05, 0.25, ZONE_LENGTH), CFrame.new(x, 1.65, zc), rgb(zone.accent), Enum.Material.Neon)
	end

	-- Zone gate (zone 1's gate is the big start arch built below)
	if zi > 1 then
		buildArch(z0, "ZONE " .. zi .. " • " .. string.upper(zone.name), rgb(zone.accent), 30)
	end

	-- Scenery on both sides of the track
	local rng = Random.new(zi * 7919)
	for side = -1, 1, 2 do
		for _ = 1, 22 do
			local pos = Vector3.new(side * rng:NextNumber(TRACK_HALF_WIDTH + 12, 180), 0, z0 + rng:NextNumber(15, ZONE_LENGTH - 15))
			DecorBuilders[zone.decor](decorFolder, pos, rng)
		end
	end
end

-- Ramps: glowing launch strips the pumpkin hops off (the hop itself is
-- animated client-side from RAMP_START / RAMP_SPACING).
for s = RAMP_START, TRACK_LENGTH - 50, RAMP_SPACING do
	local zone = Zones[math.clamp(math.floor(s / ZONE_LENGTH) + 1, 1, #Zones)]
	for _, cx in ipairs(LANE_CENTERS) do
		makePart(trackFolder, Vector3.new(LANE_WIDTH - 3, 0.8, 5), CFrame.new(cx, LANE_TOP_Y + 0.4, ORIGIN_Z + s),
			rgb(zone.accent), Enum.Material.Neon, { Transparency = 0.1 }).Name = "Ramp"
	end
end

-- Distance markers: a line across the track every 100, signs on both sides,
-- and a lantern on every other one.
for s = 100, TRACK_LENGTH, 100 do
	local z = ORIGIN_Z + s
	makePart(trackFolder, Vector3.new(TRACK_HALF_WIDTH * 2, 0.06, 0.5), CFrame.new(0, LANE_TOP_Y + 0.03, z),
		Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, { Transparency = 0.35, CanCollide = false })
	for _, side in ipairs({ -1, 1 }) do
		local x = side * (TRACK_HALF_WIDTH + 5)
		makePart(trackFolder, Vector3.new(0.6, 7, 0.6), CFrame.new(x, 3.5, z), DARK, Enum.Material.Metal)
		local board = makePart(trackFolder, Vector3.new(7, 2.6, 0.4), CFrame.new(x, 8.2, z), Color3.fromRGB(60, 40, 30), Enum.Material.Wood)
		addSurfaceText(board, s .. "m", Color3.fromRGB(255, 200, 120), 30)
		if s % 200 == 0 then
			local lantern = makePart(trackFolder, Vector3.new(1.4, 1.4, 1.4), CFrame.new(x, 10.2, z), Color3.fromRGB(255, 140, 30),
				Enum.Material.Neon, { Shape = Enum.PartType.Ball })
			addLight(lantern, Color3.fromRGB(255, 160, 70), 26, 1.6)
		end
	end
	if s % 500 == 0 and s % ZONE_LENGTH ~= 0 then
		local zone = Zones[math.clamp(math.floor(s / ZONE_LENGTH) + 1, 1, #Zones)]
		buildArch(z, s .. "m", rgb(zone.accent), 22)
	end
end

-- Pins
for laneIndex, cx in ipairs(LANE_CENTERS) do
	for _, s in ipairs(PIN_SETS) do
		local set = Instance.new("Folder")
		set.Name = "PinSet"
		set:SetAttribute("Lane", laneIndex)
		set:SetAttribute("S", s)
		for row = 0, 3 do
			for j = 0, row do
				buildPin(set, Vector3.new(cx + (j - row / 2) * 1.7, LANE_TOP_Y, ORIGIN_Z + s + row * 1.6))
			end
		end
		set.Parent = pinsFolder
	end
end

-- Finish wall
do
	local zEnd = ORIGIN_Z + #Zones * ZONE_LENGTH + 4
	local wall = makePart(trackFolder, Vector3.new(TRACK_HALF_WIDTH * 2 + 20, 32, 4), CFrame.new(0, 16, zEnd),
		Color3.fromRGB(70, 20, 60), Enum.Material.Slate)
	addSurfaceText(wall, "🎃 MAX DISTANCE! 🎃\nREBIRTH TO GO EVEN FASTER", Color3.fromRGB(255, 220, 120), 8)
	local glow = makePart(trackFolder, Vector3.new(TRACK_HALF_WIDTH * 2 + 20, 1, 4.2), CFrame.new(0, 32.5, zEnd),
		Color3.fromRGB(255, 90, 180), Enum.Material.Neon)
	addLight(glow, Color3.fromRGB(255, 120, 200), 40, 2)
end

-- Bowling approach, pads, foul line, start arch, spawn, how-to board
do
	makePart(trackFolder, Vector3.new(TRACK_HALF_WIDTH * 2 + 20, LANE_TOP_Y, 70), CFrame.new(0, LANE_TOP_Y / 2, ORIGIN_Z - 35),
		Color3.fromRGB(150, 98, 60), Enum.Material.WoodPlanks)
	makePart(trackFolder, Vector3.new(TRACK_HALF_WIDTH * 2, 0.08, 0.5), CFrame.new(0, LANE_TOP_Y + 0.04, ORIGIN_Z),
		Color3.fromRGB(255, 60, 40), Enum.Material.Neon, { CanCollide = false })

	for laneIndex, cx in ipairs(LANE_CENTERS) do
		local pad = makePart(padsFolder, Vector3.new(LANE_WIDTH - 1, 0.3, 10), CFrame.new(cx, LANE_TOP_Y + 0.15, ORIGIN_Z - 5.5),
			Color3.fromRGB(255, 130, 30), Enum.Material.Neon, { Transparency = 0.25, CanCollide = false })
		pad.Name = "BowlPad"
		pad:SetAttribute("Lane", laneIndex)
		addLight(pad, Color3.fromRGB(255, 150, 50), 14, 1)

		local bb = Instance.new("BillboardGui")
		bb.Size = UDim2.new(0, 160, 0, 50)
		bb.StudsOffset = Vector3.new(0, 4, 0)
		bb.MaxDistance = 80
		bb.Parent = pad
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = "🎳 LANE " .. laneIndex .. "\nSTAND HERE TO BOWL"
		label.TextScaled = true
		label.Font = Enum.Font.FredokaOne
		label.TextColor3 = Color3.fromRGB(255, 220, 140)
		label.Parent = bb
		local s = Instance.new("UIStroke")
		s.Thickness = 2
		s.Parent = label

		-- bowling-lane aiming dots
		for k = -2, 2 do
			makePart(trackFolder, Vector3.new(0.8, 0.05, 0.8), CFrame.new(cx + k * 2, LANE_TOP_Y + 0.03, ORIGIN_Z + 14) * CFrame.Angles(0, math.pi / 4, 0),
				Color3.fromRGB(255, 120, 30), Enum.Material.Neon, { CanCollide = false })
		end
	end

	buildArch(ORIGIN_Z - 1, "🎃 ROLL A PUMPKIN 🎃", Color3.fromRGB(255, 130, 30), 26, Color3.fromRGB(255, 190, 80))

	local spawn = Instance.new("SpawnLocation")
	spawn.Anchored = true
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.CFrame = CFrame.new(0, LANE_TOP_Y + 0.5, ORIGIN_Z - 50) * CFrame.Angles(0, math.pi, 0) -- face down the lanes
	spawn.Color = Color3.fromRGB(255, 140, 30)
	spawn.Material = Enum.Material.Neon
	spawn.Transparency = 0.3
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.Parent = world

	local board = makePart(trackFolder, Vector3.new(22, 12, 0.6),
		CFrame.new(-TRACK_HALF_WIDTH - 12, 8, ORIGIN_Z - 40) * CFrame.Angles(0, -math.pi / 2, 0), Color3.fromRGB(50, 30, 25), Enum.Material.Wood)
	addSurfaceText(board,
		"HOW TO PLAY\n💪 +1 Strength every second\n🎳 Stand on a lane pad & time the meter\n🏆 Farther rolls = more Wins\n🎃 Buy pumpkins to grow stronger faster\n🔁 Rebirth for a permanent boost",
		Color3.fromRGB(255, 225, 170), 20)
	for _, x in ipairs({ -TRACK_HALF_WIDTH - 12, TRACK_HALF_WIDTH + 12 }) do
		makePart(trackFolder, Vector3.new(1, 2, 1), CFrame.new(x, 1, ORIGIN_Z - 28), DARK, Enum.Material.Metal)
	end

	-- a few pumpkins around spawn
	local rng = Random.new(42)
	for _ = 1, 14 do
		local side = rng:NextNumber() < 0.5 and -1 or 1
		DecorBuilders.patch(decorFolder, Vector3.new(side * rng:NextNumber(TRACK_HALF_WIDTH + 14, 90), 0, ORIGIN_Z - rng:NextNumber(10, 140)), rng)
	end
end

local pads = {}
for _, pad in ipairs(padsFolder:GetChildren()) do
	pads[pad:GetAttribute("Lane")] = pad
end

local function laneAtPosition(pos)
	for laneIndex, pad in pairs(pads) do
		local rel = pos - pad.Position
		if math.abs(rel.X) <= pad.Size.X / 2 + 2 and math.abs(rel.Z) <= pad.Size.Z / 2 + 2 and math.abs(rel.Y) < 8 then
			return laneIndex
		end
	end
	return nil
end

-- Remotes are parented last so the client never sees a half-built world.
remotesFolder.Parent = ReplicatedStorage

----------------------------------------------------------------
-- PLAYER DATA
----------------------------------------------------------------

local profiles = {}      -- [player] = data table
local passes = {}        -- [player] = { DoubleStrength = bool, DoubleWins = bool }
local busy = {}          -- [player] = true while a bowl is in progress

local function defaultData()
	return {
		strength = 0,
		wins = 0,
		best = 0,
		rebirths = 0,
		owned = { classic = true },
		equipped = "classic",
	}
end

local function notify(player, text, kind)
	remotes.Notify:FireClient(player, text, kind or "info")
end

local function rebirthCost(rebirths)
	return math.floor(REBIRTH_BASE_COST * REBIRTH_COST_GROWTH ^ rebirths)
end

local function rebirthMultiplier(data)
	return 1 + REBIRTH_BONUS * data.rebirths
end

local function strengthPerSecond(player, data)
	local def = PumpkinById[data.equipped] or Pumpkins[1]
	local passMult = (passes[player] and passes[player].DoubleStrength) and 2 or 1
	return math.max(1, math.floor(STRENGTH_PER_SECOND * def.mult * rebirthMultiplier(data) * passMult))
end

local function winMultiplier(player, data)
	local passMult = (passes[player] and passes[player].DoubleWins) and 2 or 1
	return rebirthMultiplier(data) * passMult
end

local function syncPlayer(player)
	local data = profiles[player]
	local stats = player:FindFirstChild("leaderstats")
	if not data or not stats then
		return
	end
	stats.Strength.Value = data.strength
	stats.Wins.Value = data.wins
	stats.Best.Value = math.floor(data.best)
	stats.Rebirths.Value = data.rebirths

	local owned = {}
	for _, def in ipairs(Pumpkins) do
		if data.owned[def.id] then
			table.insert(owned, def.id)
		end
	end
	player:SetAttribute("Owned", table.concat(owned, ","))
	player:SetAttribute("Equipped", data.equipped)
	player:SetAttribute("StrengthPerSecond", strengthPerSecond(player, data))
	player:SetAttribute("RebirthCost", rebirthCost(data.rebirths))
	player:SetAttribute("HasDoubleStrength", passes[player] and passes[player].DoubleStrength or false)
	player:SetAttribute("HasDoubleWins", passes[player] and passes[player].DoubleWins or false)
end

local function loadData(player)
	local data = defaultData()
	if dataStore then
		local ok, saved = pcall(function()
			return dataStore:GetAsync("p_" .. player.UserId)
		end)
		if ok and type(saved) == "table" then
			data.strength = tonumber(saved.strength) or 0
			data.wins = tonumber(saved.wins) or 0
			data.best = tonumber(saved.best) or 0
			data.rebirths = tonumber(saved.rebirths) or 0
			if type(saved.owned) == "table" then
				for id, has in pairs(saved.owned) do
					if PumpkinById[id] and has then
						data.owned[id] = true
					end
				end
			end
			if type(saved.equipped) == "string" and data.owned[saved.equipped] then
				data.equipped = saved.equipped
			end
		elseif not ok then
			-- Don't overwrite real progress with a blank profile if the load failed.
			data.loadFailed = true
			warn("[Roll a Pumpkin] Failed to load data for " .. player.Name .. ": " .. tostring(saved))
		end
	end
	return data
end

local function saveData(player)
	local data = profiles[player]
	if not dataStore or not data or data.loadFailed then
		return
	end
	local payload = {
		strength = data.strength,
		wins = data.wins,
		best = data.best,
		rebirths = data.rebirths,
		owned = data.owned,
		equipped = data.equipped,
	}
	local ok, err = pcall(function()
		dataStore:SetAsync("p_" .. player.UserId, payload)
	end)
	if not ok then
		warn("[Roll a Pumpkin] Failed to save data for " .. player.Name .. ": " .. tostring(err))
	end
end

local function checkPasses(player)
	local owned = { DoubleStrength = false, DoubleWins = false }
	for name, id in pairs(GAMEPASS_IDS) do
		if id ~= 0 then
			local ok, has = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
			end)
			owned[name] = ok and has or false
		end
	end
	passes[player] = owned
end

local function onPlayerAdded(player)
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	for _, name in ipairs({ "Strength", "Wins", "Best", "Rebirths" }) do
		local v = Instance.new("IntValue")
		v.Name = name
		v.Parent = stats
	end
	stats.Parent = player

	checkPasses(player)
	local data = loadData(player)
	if not player.Parent then
		return
	end
	profiles[player] = data
	syncPlayer(player)
	if data.loadFailed then
		notify(player, "Couldn't load your save — progress this session won't be saved.", "bad")
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

Players.PlayerRemoving:Connect(function(player)
	saveData(player)
	profiles[player] = nil
	passes[player] = nil
	busy[player] = nil
end)

game:BindToClose(function()
	for player in pairs(profiles) do
		task.spawn(saveData, player)
	end
	task.wait(3)
end)

task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for player in pairs(profiles) do
			task.spawn(saveData, player)
		end
	end
end)

-- +1 Strength every second (the heart of the game)
task.spawn(function()
	while true do
		task.wait(1)
		for player, data in pairs(profiles) do
			data.strength += strengthPerSecond(player, data)
			local stats = player:FindFirstChild("leaderstats")
			if stats then
				stats.Strength.Value = data.strength
			end
		end
	end
end)

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
	if not wasPurchased then
		return
	end
	for name, id in pairs(GAMEPASS_IDS) do
		if id ~= 0 and id == gamePassId then
			passes[player] = passes[player] or {}
			passes[player][name] = true
			syncPlayer(player)
			notify(player, "Thanks! " .. (name == "DoubleStrength" and "2x Strength" or "2x Wins") .. " is now active!", "good")
		end
	end
end)

----------------------------------------------------------------
-- BOWLING
----------------------------------------------------------------

local function computeDistance(strength, power, perfect)
	local d = DISTANCE_SCALE * math.max(strength, 0) ^ DISTANCE_EXPONENT * power
	if perfect then
		d *= PERFECT_BONUS
	end
	return math.clamp(d, MIN_DISTANCE, TRACK_LENGTH)
end

local function rollDuration(distance)
	return math.clamp(2.2 + distance / 220, 2.2, 16)
end

remotes.RequestBowl.OnServerEvent:Connect(function(player, needle)
	local data = profiles[player]
	if not data or busy[player] then
		return
	end
	if typeof(needle) ~= "number" or needle ~= needle then
		return
	end
	needle = math.clamp(needle, 0, 1)

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not hrp or not humanoid or humanoid.Health <= 0 then
		return
	end
	local lane = laneAtPosition(hrp.Position)
	if not lane then
		return
	end
	busy[player] = true

	local offset = math.abs(needle - 0.5)
	local perfect = offset <= PERFECT_WINDOW
	local power = perfect and 1 or math.max(MIN_POWER, 1 - offset * 2)
	local distance = computeDistance(data.strength, power, perfect)
	local duration = rollDuration(distance)

	-- Square the bowler up to the lane (slightly left of centre so the
	-- right-handed release lines up with the middle) and freeze them.
	local pad = pads[lane]
	local standPos = Vector3.new(LANE_CENTERS[lane] + 1.2, hrp.Position.Y, pad.Position.Z + 1)
	hrp.CFrame = CFrame.lookAt(standPos, standPos + Vector3.new(0, 0, 1))
	hrp.Anchored = true
	local oldWalk, oldJumpPower, oldJumpHeight = humanoid.WalkSpeed, humanoid.JumpPower, humanoid.JumpHeight
	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0

	remotes.BowlStarted:FireAllClients({
		player = player,
		lane = lane,
		distance = distance,
		duration = duration,
		pumpkin = data.equipped,
		perfect = perfect,
		power = power,
	})

	-- Release the bowler once the follow-through finishes.
	task.delay(WINDUP_TIME + 1.5, function()
		if hrp.Parent then
			hrp.Anchored = false
		end
		if humanoid.Parent then
			humanoid.WalkSpeed = oldWalk
			humanoid.JumpPower = oldJumpPower
			humanoid.JumpHeight = oldJumpHeight
		end
	end)

	-- Pay out when the pumpkin stops.
	task.delay(WINDUP_TIME + duration + 0.2, function()
		busy[player] = nil
		local current = profiles[player]
		if not current or not player.Parent then
			return
		end
		local wins = math.max(1, math.floor(distance * WINS_PER_STUD * winMultiplier(player, current)))
		local previousBest = current.best
		local newBest = distance > previousBest
		local zoneBonus = 0
		local newZone
		if newBest then
			current.best = distance
			local oldZone = math.floor(previousBest / ZONE_LENGTH)
			local reachedZone = math.min(math.floor(distance / ZONE_LENGTH), #Zones - 1)
			for k = oldZone + 1, reachedZone do
				zoneBonus += math.floor(ZONE_BONUS_WINS * k * k * winMultiplier(player, current))
				newZone = k + 1
			end
		end
		current.wins += wins + zoneBonus
		syncPlayer(player)

		remotes.BowlResult:FireClient(player, {
			distance = distance,
			wins = wins,
			newBest = newBest,
			perfect = perfect,
			zoneBonus = zoneBonus,
			zoneName = newZone and Zones[newZone].name or nil,
			maxed = distance >= TRACK_LENGTH,
		})
	end)
end)

----------------------------------------------------------------
-- SHOP / REBIRTH
----------------------------------------------------------------

remotes.BuyPumpkin.OnServerInvoke = function(player, id)
	local data = profiles[player]
	local def = type(id) == "string" and PumpkinById[id]
	if not data or not def then
		return false, "Unknown pumpkin."
	end
	if data.owned[id] then
		data.equipped = id
		syncPlayer(player)
		return true, "Equipped " .. def.name .. "!"
	end
	if data.wins < def.cost then
		return false, "Not enough Wins!"
	end
	data.wins -= def.cost
	data.owned[id] = true
	data.equipped = id
	syncPlayer(player)
	return true, "You got the " .. def.name .. "! (x" .. def.mult .. " Strength)"
end

remotes.EquipPumpkin.OnServerInvoke = function(player, id)
	local data = profiles[player]
	if not data or type(id) ~= "string" or not data.owned[id] then
		return false, "You don't own that pumpkin."
	end
	data.equipped = id
	syncPlayer(player)
	return true, "Equipped " .. PumpkinById[id].name .. "!"
end

remotes.Rebirth.OnServerInvoke = function(player)
	local data = profiles[player]
	if not data then
		return false, "Still loading..."
	end
	if busy[player] then
		return false, "Wait for your pumpkin to stop rolling!"
	end
	local cost = rebirthCost(data.rebirths)
	if data.wins < cost then
		return false, "You need " .. cost .. " Wins to rebirth."
	end
	data.rebirths += 1
	data.strength = 0
	data.wins = 0
	syncPlayer(player)
	return true, "REBIRTH " .. data.rebirths .. "! Now x" .. rebirthMultiplier(data) .. " Strength & Wins"
end
