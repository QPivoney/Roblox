--[[
	ROLL A PUMPKIN — Client Script
	-----------------------------------------------------------
	HOW TO INSTALL:
	1. In Roblox Studio, go to StarterPlayer > StarterPlayerScripts.
	2. Insert a new LocalScript named "RollAPumpkinClient".
	3. Delete the default line and paste this entire file in.
	4. Requires RollAPumpkinServer.lua to already be running in
	   ServerScriptService (it builds the world and creates the remotes
	   and shared config this script waits on).

	Handles everything you see and feel:
	  - the bowling animation (wind-up, back-swing, lunge, release,
	    follow-through) on every player's character
	  - the rolling pumpkin: spin, wobble, ramp hops, dust, trails,
	    sparkles, pin strikes, and the candy burst when it stops
	  - the chase camera with speed FOV and landing shake
	  - per-zone lighting as the camera travels down the track
	  - the HUD: Strength / Wins / Best, "+1" popups, the power meter,
	    the live distance counter, results, the pumpkin shop, rebirth
	-----------------------------------------------------------
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local MarketplaceService = game:GetService("MarketplaceService")
local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = Workspace.CurrentCamera

local remotes = ReplicatedStorage:WaitForChild("RollAPumpkinRemotes")
local requestBowl = remotes:WaitForChild("RequestBowl")
local bowlStarted = remotes:WaitForChild("BowlStarted")
local bowlResult = remotes:WaitForChild("BowlResult")
local notifyEvent = remotes:WaitForChild("Notify")
local buyPumpkinFn = remotes:WaitForChild("BuyPumpkin")
local equipPumpkinFn = remotes:WaitForChild("EquipPumpkin")
local rebirthFn = remotes:WaitForChild("Rebirth")

local CONFIG = HttpService:JSONDecode(remotes:WaitForChild("Config").Value)

local world = Workspace:WaitForChild("RollAPumpkinWorld")
local padsFolder = world:WaitForChild("Pads")
local pinsFolder = world:WaitForChild("Pins")

local R = CONFIG.radius
local rng = Random.new()

local PumpkinById = {}
for _, def in ipairs(CONFIG.pumpkins) do
	PumpkinById[def.id] = def
end

local fxFolder = Instance.new("Folder")
fxFolder.Name = "RollAPumpkinFX"
fxFolder.Parent = Workspace

local PALETTE = {
	bg       = Color3.fromRGB(28, 18, 30),
	panel    = Color3.fromRGB(44, 28, 44),
	panel2   = Color3.fromRGB(60, 38, 58),
	accent   = Color3.fromRGB(255, 140, 30),
	gold     = Color3.fromRGB(255, 205, 70),
	text     = Color3.fromRGB(255, 245, 235),
	subtext  = Color3.fromRGB(200, 175, 185),
	good     = Color3.fromRGB(110, 220, 120),
	bad      = Color3.fromRGB(235, 90, 90),
	purple   = Color3.fromRGB(150, 90, 255),
}

----------------------------------------------------------------
-- UTILITIES
----------------------------------------------------------------

local function rgb(t)
	return Color3.fromRGB(t[1], t[2], t[3])
end

local SUFFIXES = { "", "K", "M", "B", "T", "Qd", "Qn", "Sx" }
local function abbreviate(n)
	n = math.floor(n or 0)
	if math.abs(n) < 1000 then
		return tostring(n)
	end
	local i = 1
	local v = n
	while math.abs(v) >= 999.5 and i < #SUFFIXES do -- 999.5+ would print as "1000K"
		v /= 1000
		i += 1
	end
	local fmt = math.abs(v) < 10 and "%.2f" or (math.abs(v) < 100 and "%.1f" or "%.0f")
	return string.format(fmt, v) .. SUFFIXES[i]
end

local function commas(n)
	local s = tostring(math.floor(n))
	local formatted = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if formatted:sub(1, 1) == "," then
		formatted = formatted:sub(2)
	end
	return formatted
end

local function playSound(name, parent, looped)
	local id = CONFIG.sounds[name]
	if not id or id == 0 then
		return nil
	end
	local sound = Instance.new("Sound")
	sound.SoundId = "rbxassetid://" .. tostring(id)
	sound.Looped = looped or false
	sound.Volume = 0.7
	sound.RollOffMaxDistance = 200
	sound.Parent = parent or SoundService
	sound:Play()
	if not looped then
		sound.Ended:Connect(function()
			sound:Destroy()
		end)
	end
	return sound
end

local function tween(inst, time, props, style, direction)
	local t = TweenService:Create(inst, TweenInfo.new(time, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

----------------------------------------------------------------
-- GUI HELPERS
----------------------------------------------------------------

local function make(className, props, children)
	local inst = Instance.new(className)
	for k, v in pairs(props) do
		if k ~= "Parent" then
			inst[k] = v
		end
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = inst
		end
	end
	inst.Parent = props.Parent
	return inst
end

local function corner(radius)
	return make("UICorner", { CornerRadius = UDim.new(0, radius or 10) })
end

local function stroke(color, thickness)
	return make("UIStroke", { Color = color or Color3.new(0, 0, 0), Thickness = thickness or 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end

local function textStroke(thickness)
	return make("UIStroke", { Color = Color3.fromRGB(25, 10, 15), Thickness = thickness or 2 })
end

local function label(parent, props)
	local l = make("TextLabel", {
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		TextColor3 = PALETTE.text,
		TextScaled = true,
		Parent = parent,
	})
	for k, v in pairs(props) do
		l[k] = v
	end
	return l
end

local function button(parent, props, color)
	local b = make("TextButton", {
		BackgroundColor3 = color or PALETTE.accent,
		Font = Enum.Font.FredokaOne,
		TextColor3 = PALETTE.text,
		TextScaled = true,
		AutoButtonColor = true,
		Parent = parent,
	}, { corner(10), textStroke(2) })
	for k, v in pairs(props) do
		b[k] = v
	end
	make("UIGradient", {
		Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(200, 200, 200)),
		Rotation = 90,
		Parent = b,
	})
	make("UIPadding", {
		PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6),
		PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
		Parent = b,
	})
	return b
end

local function pressBounce(guiObject)
	local scale = guiObject:FindFirstChildOfClass("UIScale") or make("UIScale", { Parent = guiObject })
	scale.Scale = 1.18
	tween(scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
end

----------------------------------------------------------------
-- PUMPKIN MODEL
----------------------------------------------------------------

-- The pumpkin rolls like a wheel around its stem axis (local X), so the
-- ribs spin past the camera as it goes. Every part is anchored and the
-- whole model is moved with PivotTo, which also works inside a
-- ViewportFrame for the shop previews.
local function buildPumpkin(def, radius, forViewport)
	local r = radius
	local model = Instance.new("Model")
	model.Name = "Pumpkin"
	local parts = {}

	local function add(size, cf, color, material, transparency, shape)
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = not forViewport
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = material
		p.Transparency = transparency or 0
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if shape then
			p.Shape = shape
		end
		p.Parent = model
		table.insert(parts, p)
		return p
	end
	local function sphereMesh(p)
		make("SpecialMesh", { MeshType = Enum.MeshType.Sphere, Parent = p })
	end

	local transparency = def.transparency or 0
	local bodyMaterial = Enum.Material[def.material or "SmoothPlastic"]
	local ribMaterial = Enum.Material[def.ribMaterial or def.material or "SmoothPlastic"]

	local body = add(Vector3.new(2 * r * 0.86, 2 * r, 2 * r), CFrame.new(), rgb(def.color), bodyMaterial, transparency)
	sphereMesh(body)
	model.PrimaryPart = body

	for k = 0, 5 do
		local rib = add(Vector3.new(2 * r * 0.8, 2 * r * 1.04, 2 * r * 0.26), CFrame.Angles(k * math.pi / 6, 0, 0),
			rgb(def.rib or def.color), ribMaterial, transparency)
		sphereMesh(rib)
	end

	add(Vector3.new(r * 0.55, r * 0.3, r * 0.3), CFrame.new(r * 0.95, 0, 0) * CFrame.Angles(0, 0.3, 0.25),
		rgb(def.stem), Enum.Material.Wood, 0, Enum.PartType.Cylinder)

	if def.face then
		local glow = rgb(def.glow or { 255, 170, 40 })
		-- x/y are in "unit pumpkin" space; the piece is pushed out onto the
		-- front (-Z) surface and turned to face along the surface normal.
		local function facePiece(x, y, size, roll)
			local z = -math.sqrt(math.max(0.05, 1 - (x / 0.86) ^ 2 - y ^ 2))
			local pos = Vector3.new(x * r, y * r, z * r * 1.02)
			local normal = Vector3.new(x / 0.74, y, z).Unit
			add(size, CFrame.lookAt(pos, pos + normal) * CFrame.Angles(0, 0, roll), glow, Enum.Material.Neon)
		end
		local d = 0.12 * r
		facePiece(-0.3, 0.26, Vector3.new(0.34 * r, 0.34 * r, d), math.pi / 4)
		facePiece(0.3, 0.26, Vector3.new(0.34 * r, 0.34 * r, d), math.pi / 4)
		facePiece(0, 0.0, Vector3.new(0.15 * r, 0.15 * r, d), math.pi / 4)
		facePiece(0, -0.38, Vector3.new(0.5 * r, 0.14 * r, d), 0)
		facePiece(-0.32, -0.28, Vector3.new(0.24 * r, 0.12 * r, d), -0.55)
		facePiece(0.32, -0.28, Vector3.new(0.24 * r, 0.12 * r, d), 0.55)
		if not forViewport then
			make("PointLight", { Color = glow, Range = 12, Brightness = 1.6, Shadows = false, Parent = body })
		end
	end

	return { model = model, body = body, parts = parts }
end

local function fadeAndDestroy(pumpkin, time)
	for _, p in ipairs(pumpkin.parts) do
		tween(p, time, { Transparency = 1 })
	end
	local light = pumpkin.body:FindFirstChildOfClass("PointLight")
	if light then
		tween(light, time, { Brightness = 0 })
	end
	task.delay(time + 0.05, function()
		pumpkin.model:Destroy()
	end)
end

----------------------------------------------------------------
-- BOWLING ANIMATION (procedural, works on R15 and R6)
----------------------------------------------------------------

-- Pose values are in radians (crouch is in studs). Positive arm/hip =
-- swing forward, positive knee = bend, positive lean = bend forward.
local BOWL_KEYFRAMES = {
	{ t = 0.00, pose = {} },
	{ t = 0.30, pose = { rArm = 0.9, lArm = 0.7, lean = 0.1, crouch = 0.1 } },                                   -- cradle
	{ t = 0.75, pose = { rArm = -1.8, lArm = 0.6, lean = 0.3, crouch = 0.35, lHip = 0.5, lKnee = 0.6, rHip = -0.2 } }, -- back-swing
	{ t = 1.20, pose = { rArm = 0.4, lArm = -0.6, lean = 0.6, crouch = 0.65, lHip = 0.95, lKnee = 1.1, rHip = -0.7, rKnee = 0.4 } }, -- release
	{ t = 1.55, pose = { rArm = 2.4, lArm = -0.7, lean = 0.45, crouch = 0.6, lHip = 0.95, lKnee = 1.1, rHip = -0.7, rKnee = 0.4 } }, -- follow-through
	{ t = 2.25, pose = { rArm = 2.3, lArm = -0.6, lean = 0.4, crouch = 0.55, lHip = 0.9, lKnee = 1.0, rHip = -0.6, rKnee = 0.4 } }, -- hold & watch
	{ t = 2.70, pose = {} },
}
local KEYFRAME_RELEASE_T = 1.20
local POSE_KEYS = { "lean", "crouch", "rArm", "lArm", "rHip", "lHip", "rKnee", "lKnee" }

local function getRig(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	local function joint(partName, jointName)
		local part = character:FindFirstChild(partName)
		local motor = part and part:FindFirstChild(jointName)
		return (motor and motor:IsA("Motor6D")) and motor or nil
	end
	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		return {
			r15 = true,
			lean = joint("UpperTorso", "Waist"),
			crouch = joint("LowerTorso", "Root"),
			rArm = joint("RightUpperArm", "RightShoulder"),
			lArm = joint("LeftUpperArm", "LeftShoulder"),
			rHip = joint("RightUpperLeg", "RightHip"),
			lHip = joint("LeftUpperLeg", "LeftHip"),
			rKnee = joint("RightLowerLeg", "RightKnee"),
			lKnee = joint("LeftLowerLeg", "LeftKnee"),
		}
	end
	return {
		r15 = false,
		lean = joint("HumanoidRootPart", "RootJoint"),
		rArm = joint("Torso", "Right Shoulder"),
		lArm = joint("Torso", "Left Shoulder"),
		rHip = joint("Torso", "Right Hip"),
		lHip = joint("Torso", "Left Hip"),
	}
end

-- Turn a pose into a C0 offset per joint. The R6 joints have rotated C0
-- frames (shoulders/hips swing about their Z axis, left side mirrored).
local function poseOffsets(rig, pose)
	local o = {}
	if rig.r15 then
		o.lean = CFrame.Angles(-pose.lean, 0, 0)
		o.crouch = CFrame.new(0, -pose.crouch, 0)
		o.rArm = CFrame.Angles(pose.rArm, 0, 0)
		o.lArm = CFrame.Angles(pose.lArm, 0, 0)
		o.rHip = CFrame.Angles(pose.rHip, 0, 0)
		o.lHip = CFrame.Angles(pose.lHip, 0, 0)
		o.rKnee = CFrame.Angles(-pose.rKnee, 0, 0)
		o.lKnee = CFrame.Angles(-pose.lKnee, 0, 0)
	else
		o.lean = CFrame.new(0, 0, -pose.crouch) * CFrame.Angles(pose.lean, 0, 0)
		o.rArm = CFrame.Angles(0, 0, pose.rArm)
		o.lArm = CFrame.Angles(0, 0, -pose.lArm)
		o.rHip = CFrame.Angles(0, 0, pose.rHip)
		o.lHip = CFrame.Angles(0, 0, -pose.lHip)
	end
	return o
end

local animating = {}

local function playBowlAnimation(character, windup)
	if animating[character] then
		return
	end
	local rig = getRig(character)
	if not rig then
		return
	end
	local baseC0 = {}
	for _, key in ipairs(POSE_KEYS) do
		if rig[key] then
			baseC0[key] = rig[key].C0
		end
	end
	animating[character] = true

	local timeScale = windup / KEYFRAME_RELEASE_T
	local endT = BOWL_KEYFRAMES[#BOWL_KEYFRAMES].t
	local startClock = os.clock()
	local conn
	local function restore()
		for key, c0 in pairs(baseC0) do
			if rig[key] and rig[key].Parent then
				rig[key].C0 = c0
			end
		end
		animating[character] = nil
		conn:Disconnect()
	end
	conn = RunService.RenderStepped:Connect(function()
		local t = (os.clock() - startClock) / timeScale
		if t >= endT or not character.Parent then
			restore()
			return
		end
		local a, b = BOWL_KEYFRAMES[1], BOWL_KEYFRAMES[2]
		for i = 1, #BOWL_KEYFRAMES - 1 do
			if t >= BOWL_KEYFRAMES[i].t and t < BOWL_KEYFRAMES[i + 1].t then
				a, b = BOWL_KEYFRAMES[i], BOWL_KEYFRAMES[i + 1]
				break
			end
		end
		local alpha = (t - a.t) / (b.t - a.t)
		alpha = 0.5 - math.cos(alpha * math.pi) / 2 -- ease in-out
		local pose = {}
		for _, key in ipairs(POSE_KEYS) do
			local from, to = a.pose[key] or 0, b.pose[key] or 0
			pose[key] = from + (to - from) * alpha
		end
		local offsets = poseOffsets(rig, pose)
		for key, c0 in pairs(baseC0) do
			if offsets[key] then
				rig[key].C0 = c0 * offsets[key]
			end
		end
	end)
end

local function getHand(character)
	return character and (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm"))
end

local function handHoldOffset(hand)
	if hand.Name == "RightHand" then
		return CFrame.new(0, -R * 0.75, 0)
	end
	return CFrame.new(0, -1 - R * 0.75, 0)
end

----------------------------------------------------------------
-- HUD (built first so the rolling code can drive it)
----------------------------------------------------------------

local gui = make("ScreenGui", {
	Name = "RollAPumpkinHUD",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})

-- Stats panel (top-left)
local statsPanel = make("Frame", {
	Name = "Stats",
	Position = UDim2.new(0, 12, 0, 12),
	Size = UDim2.new(0, 230, 0, 186),
	BackgroundColor3 = PALETTE.bg,
	BackgroundTransparency = 0.15,
	Parent = gui,
}, { corner(14), stroke(PALETTE.accent, 2) })

label(statsPanel, { Text = "💪 STRENGTH", Position = UDim2.new(0, 12, 0, 8), Size = UDim2.new(1, -24, 0, 18),
	TextColor3 = PALETTE.subtext, TextXAlignment = Enum.TextXAlignment.Left })
local strengthLabel = label(statsPanel, { Text = "0", Position = UDim2.new(0, 12, 0, 26), Size = UDim2.new(1, -24, 0, 40),
	TextColor3 = PALETTE.gold, TextXAlignment = Enum.TextXAlignment.Left })
textStroke(3).Parent = strengthLabel
local perSecondLabel = label(statsPanel, { Text = "+1 / sec", Position = UDim2.new(0, 12, 0, 66), Size = UDim2.new(1, -24, 0, 18),
	TextColor3 = PALETTE.good, TextXAlignment = Enum.TextXAlignment.Left })

local function statRow(y, title)
	label(statsPanel, { Text = title, Position = UDim2.new(0, 12, 0, y), Size = UDim2.new(0.55, -12, 0, 20),
		TextColor3 = PALETTE.subtext, TextXAlignment = Enum.TextXAlignment.Left })
	return label(statsPanel, { Text = "0", Position = UDim2.new(0.45, 0, 0, y), Size = UDim2.new(0.55, -12, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Right })
end
make("Frame", { Position = UDim2.new(0, 12, 0, 90), Size = UDim2.new(1, -24, 0, 2), BackgroundColor3 = PALETTE.panel2,
	BorderSizePixel = 0, Parent = statsPanel })
local winsLabel = statRow(98, "🏆 Wins")
local bestLabel = statRow(120, "📏 Best")
local rebirthsLabel = statRow(142, "🔁 Rebirths")
local pumpkinLabel = statRow(164, "🎃")
pumpkinLabel.TextColor3 = PALETTE.accent

-- Menu buttons (under the stats)
local shopButton = button(gui, { Text = "🎃 PUMPKINS", Position = UDim2.new(0, 12, 0, 206), Size = UDim2.new(0, 112, 0, 50) }, PALETTE.accent)
local rebirthButton = button(gui, { Text = "🔁 REBIRTH", Position = UDim2.new(0, 130, 0, 206), Size = UDim2.new(0, 112, 0, 50) }, PALETTE.purple)

-- Live distance counter (top-centre, during your own roll)
local counterFrame = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 10),
	Size = UDim2.new(0, 340, 0, 92),
	BackgroundTransparency = 1,
	Visible = false,
	Parent = gui,
})
local counterLabel = label(counterFrame, { Text = "0 m", Size = UDim2.new(1, 0, 0, 64), TextColor3 = PALETTE.gold })
textStroke(4).Parent = counterLabel
local counterZoneLabel = label(counterFrame, { Text = "", Position = UDim2.new(0, 0, 0, 64), Size = UDim2.new(1, 0, 0, 24),
	TextColor3 = PALETTE.text })
textStroke(2).Parent = counterZoneLabel

-- Zone banner
local zoneBanner = label(gui, {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.26, 0),
	Size = UDim2.new(0, 560, 0, 70),
	Text = "",
	TextTransparency = 1,
	ZIndex = 5,
})
local zoneBannerStroke = textStroke(4)
zoneBannerStroke.Transparency = 1
zoneBannerStroke.Parent = zoneBanner

-- Big centre flash text ("PERFECT!", "STRIKE!")
local flashLabel = label(gui, {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.36, 0),
	Size = UDim2.new(0, 460, 0, 80),
	Text = "",
	TextTransparency = 1,
	ZIndex = 6,
})
local flashStroke = textStroke(4)
flashStroke.Transparency = 1
flashStroke.Parent = flashLabel

local function flash(text, color, hold)
	flashLabel.Text = text
	flashLabel.TextColor3 = color
	flashLabel.TextTransparency = 0
	flashStroke.Transparency = 0
	pressBounce(flashLabel)
	flashLabel:SetAttribute("Token", HttpService:GenerateGUID(false))
	local myToken = flashLabel:GetAttribute("Token")
	task.delay(hold or 0.9, function()
		if flashLabel:GetAttribute("Token") == myToken then
			tween(flashLabel, 0.4, { TextTransparency = 1 })
			tween(flashStroke, 0.4, { Transparency = 1 })
		end
	end)
end

local function showZoneBanner(index)
	local zone = CONFIG.zones[index]
	if not zone then
		return
	end
	zoneBanner.Text = "ZONE " .. index .. " • " .. string.upper(zone.name)
	zoneBanner.TextColor3 = rgb(zone.accent)
	zoneBanner.Position = UDim2.new(0.5, 0, 0.22, 0)
	zoneBanner.TextTransparency = 0
	zoneBannerStroke.Transparency = 0
	tween(zoneBanner, 0.5, { Position = UDim2.new(0.5, 0, 0.26, 0) }, Enum.EasingStyle.Back)
	task.delay(1.6, function()
		tween(zoneBanner, 0.5, { TextTransparency = 1 })
		tween(zoneBannerStroke, 0.5, { Transparency = 1 })
	end)
end

-- Toasts
local toastHolder = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -170),
	Size = UDim2.new(0, 420, 0, 200),
	BackgroundTransparency = 1,
	Parent = gui,
}, {
	make("UIListLayout", {
		VerticalAlignment = Enum.VerticalAlignment.Bottom,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})
local toastCount = 0
local function toast(text, kind)
	toastCount += 1
	local color = kind == "good" and PALETTE.good or (kind == "bad" and PALETTE.bad or PALETTE.accent)
	local frame = make("Frame", {
		Size = UDim2.new(1, 0, 0, 38),
		BackgroundColor3 = PALETTE.bg,
		BackgroundTransparency = 0.1,
		LayoutOrder = toastCount,
		Parent = toastHolder,
	}, { corner(10), stroke(color, 2) })
	local l = label(frame, { Text = text, Size = UDim2.new(1, -16, 1, -10), Position = UDim2.new(0, 8, 0, 5) })
	pressBounce(frame)
	task.delay(3, function()
		tween(frame, 0.4, { BackgroundTransparency = 1 })
		tween(l, 0.4, { TextTransparency = 1 })
		local s = frame:FindFirstChildOfClass("UIStroke")
		if s then
			tween(s, 0.4, { Transparency = 1 })
		end
		task.wait(0.45)
		frame:Destroy()
	end)
end

notifyEvent.OnClientEvent:Connect(toast)

-- Power meter (bottom-centre, while standing on a pad)
local meterFrame = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -24),
	Size = UDim2.new(0, 440, 0, 140),
	BackgroundColor3 = PALETTE.bg,
	BackgroundTransparency = 0.15,
	Visible = false,
	Parent = gui,
}, { corner(16), stroke(PALETTE.accent, 3) })
local meterTitle = label(meterFrame, { Text = "🎳 TIME YOUR ROLL!", Position = UDim2.new(0, 0, 0, 6), Size = UDim2.new(1, 0, 0, 24),
	TextColor3 = PALETTE.gold })
local meterBar = make("Frame", {
	Position = UDim2.new(0, 20, 0, 36),
	Size = UDim2.new(1, -40, 0, 30),
	BackgroundColor3 = Color3.new(1, 1, 1),
	Parent = meterFrame,
}, {
	corner(8),
	stroke(Color3.fromRGB(20, 10, 10), 2),
	make("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(220, 50, 50)),
			ColorSequenceKeypoint.new(0.3, Color3.fromRGB(255, 210, 60)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(80, 230, 90)),
			ColorSequenceKeypoint.new(0.7, Color3.fromRGB(255, 210, 60)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(220, 50, 50)),
		}),
	}),
})
make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.5, 0),
	Size = UDim2.new(CONFIG.perfectWindow * 2, 0, 1, 8),
	BackgroundColor3 = PALETTE.gold,
	BackgroundTransparency = 0.2,
	Parent = meterBar,
}, { corner(4), stroke(Color3.new(1, 1, 1), 2) })
local needle = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.5, 0),
	Size = UDim2.new(0, 8, 1, 18),
	BackgroundColor3 = Color3.new(1, 1, 1),
	ZIndex = 3,
	Parent = meterBar,
}, { corner(4), stroke(Color3.fromRGB(20, 10, 10), 2) })
local bowlButton = button(meterFrame, {
	Text = "BOWL!",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 78),
	Size = UDim2.new(0, 200, 0, 52),
}, PALETTE.accent)
label(meterFrame, { Text = "Click / Tap / E", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 104),
	Size = UDim2.new(0, 100, 0, 18), TextColor3 = PALETTE.subtext })

-- Result card
local resultFrame = make("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.new(0.5, 0, 0.42, 0),
	Size = UDim2.new(0, 380, 0, 170),
	BackgroundColor3 = PALETTE.bg,
	BackgroundTransparency = 0.1,
	Visible = false,
	ZIndex = 4,
	Parent = gui,
}, { corner(18), stroke(PALETTE.gold, 3), make("UIScale", {}) })
local resultDistance = label(resultFrame, { Text = "", Position = UDim2.new(0, 0, 0, 10), Size = UDim2.new(1, 0, 0, 60),
	TextColor3 = PALETTE.gold, ZIndex = 4 })
textStroke(3).Parent = resultDistance
local resultWins = label(resultFrame, { Text = "", Position = UDim2.new(0, 0, 0, 72), Size = UDim2.new(1, 0, 0, 34), ZIndex = 4 })
local resultExtra = label(resultFrame, { Text = "", Position = UDim2.new(0, 10, 0, 112), Size = UDim2.new(1, -20, 0, 46),
	TextColor3 = PALETTE.accent, ZIndex = 4 })

----------------------------------------------------------------
-- CAMERA
----------------------------------------------------------------

local camState = nil       -- nil | "windup" | "follow"
local camBase = camera.CFrame
local camOffset = Vector3.new(0, 7, -16)
local shakeAmount = 0
local localRoll = nil      -- the roll this player is watching

local function shake(amount)
	shakeAmount = math.max(shakeAmount, amount)
end

local function restoreCamera()
	camState = nil
	camera.CameraType = Enum.CameraType.Custom
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
	tween(camera, 0.6, { FieldOfView = 70 })
end

RunService:BindToRenderStep("RollAPumpkinCamera", Enum.RenderPriority.Camera.Value + 1, function(dt)
	if not camState then
		return
	end
	local alpha = 1 - math.exp(-dt * 6)
	local fov = 70
	if camState == "windup" then
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if hrp then
			-- over the right shoulder, low, looking down the lane
			local eye = (hrp.CFrame * CFrame.new(5, 2.5, 10)).Position
			local target = (hrp.CFrame * CFrame.new(0, 0, -18)).Position
			camBase = camBase:Lerp(CFrame.lookAt(eye, target), alpha)
		end
	elseif camState == "follow" and localRoll then
		local p = localRoll.position or localRoll.model:GetPivot().Position
		local v = localRoll.speed or 0
		local desired = Vector3.new(0, 6 + math.min(v * 0.012, 6), -(15 + math.min(v * 0.025, 12)))
		camOffset = camOffset:Lerp(desired, alpha)
		-- no positional lag: the camera is locked to the pumpkin and only
		-- the offset eases, so it keeps up at hundreds of studs per second
		camBase = CFrame.lookAt(p + camOffset, p + Vector3.new(0, 1.5, 16))
		fov = 70 + math.min(v / 9, 30)
	end
	local final = camBase
	if shakeAmount > 0.01 then
		final *= CFrame.new(rng:NextNumber(-1, 1) * shakeAmount, rng:NextNumber(-1, 1) * shakeAmount, 0)
			* CFrame.Angles(0, 0, rng:NextNumber(-1, 1) * shakeAmount * 0.02)
		shakeAmount *= math.exp(-dt * 7)
	end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = final
	camera.FieldOfView += (fov - camera.FieldOfView) * alpha
end)

----------------------------------------------------------------
-- ROLLING
----------------------------------------------------------------

local rolls = {}
local pinAnims = {}

local function makeFx(def)
	local part = make("Part", {
		Name = "PumpkinFX",
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Transparency = 1,
		Size = Vector3.new(0.2, 0.2, 0.2),
		Parent = fxFolder,
	})
	local top = make("Attachment", { Position = Vector3.new(0, R * 0.7, 0), Parent = part })
	local bottom = make("Attachment", { Position = Vector3.new(0, -R * 0.7, 0), Parent = part })
	local ground = make("Attachment", { Position = Vector3.new(0, -R + 0.1, 0), Parent = part })
	local trailColor = rgb(def.trail or def.color)

	local trail = make("Trail", {
		Attachment0 = top,
		Attachment1 = bottom,
		Color = ColorSequence.new(trailColor),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) }),
		WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.2) }),
		Lifetime = 0.45,
		LightEmission = 0.6,
		FaceCamera = true,
		Enabled = false,
		Parent = part,
	})
	local dust = make("ParticleEmitter", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 150, 40)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(190, 90, 30)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 70, 40)),
		}),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(0.5, 0.9),
		Speed = NumberRange.new(4, 11),
		SpreadAngle = Vector2.new(45, 45),
		Acceleration = Vector3.new(0, -25, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-200, 200),
		EmissionDirection = Enum.NormalId.Top,
		Rate = 0,
		Parent = ground,
	})
	local burst = make("ParticleEmitter", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 140, 30)),
			ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 230, 90)),
			ColorSequenceKeypoint.new(0.66, Color3.fromRGB(170, 90, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(110, 230, 120)),
		}),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 0.1) }),
		Lifetime = NumberRange.new(1, 1.6),
		Speed = NumberRange.new(16, 34),
		SpreadAngle = Vector2.new(55, 55),
		Acceleration = Vector3.new(0, -45, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-300, 300),
		LightEmission = 0.4,
		EmissionDirection = Enum.NormalId.Top,
		Rate = 0,
		Parent = part,
	})
	local sparkle
	if def.sparkles then
		sparkle = make("ParticleEmitter", {
			Color = ColorSequence.new(rgb(def.glow or def.trail)),
			Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0) }),
			Lifetime = NumberRange.new(0.5, 0.9),
			Speed = NumberRange.new(1, 4),
			SpreadAngle = Vector2.new(180, 180),
			LightEmission = 1,
			Rate = 25,
			Parent = part,
		})
	end
	return { part = part, trail = trail, dust = dust, burst = burst, sparkle = sparkle }
end

local function computeHops(D, T)
	local hops = {}
	local v0 = 2 * D / T
	local airborneUntil = -1
	local s = CONFIG.rampStart
	while s < D - 6 do
		if s > airborneUntil then
			local v = v0 * math.sqrt(math.max(0, 1 - s / D))
			if v > 14 then
				local L = math.min(math.clamp(v * 0.45, 8, CONFIG.rampSpacing * 0.8), (D - s) * 0.9)
				if L >= 5 then
					local H = math.min(math.clamp(v * 0.05, 1, 28), L * 0.35)
					table.insert(hops, { s0 = s, L = L, H = H })
					airborneUntil = s + L
				end
			end
		end
		s += CONFIG.rampSpacing
	end
	return hops
end

local function hopHeight(hops, s)
	for _, hop in ipairs(hops) do
		if s >= hop.s0 and s <= hop.s0 + hop.L then
			local u = (s - hop.s0) / hop.L
			return 4 * hop.H * u * (1 - u)
		end
	end
	return 0
end

local function pinSetsFor(lane, D)
	local sets = {}
	for _, set in ipairs(pinsFolder:GetChildren()) do
		local s = set:GetAttribute("S")
		if set:GetAttribute("Lane") == lane and s and s <= D + 1 then
			table.insert(sets, { folder = set, s = s, knocked = false })
		end
	end
	return sets
end

local function knockPins(set, speed)
	for _, pin in ipairs(set:GetChildren()) do
		if pin:IsA("Model") and not pinAnims[pin] then
			local origin = pin:GetPivot()
			pinAnims[pin] = {
				origin = origin,
				cf = origin,
				t = 0,
				vel = Vector3.new(rng:NextNumber(-16, 16), rng:NextNumber(14, 32), math.min(speed * 0.3, 90) + rng:NextNumber(5, 20)),
				spin = Vector3.new(rng:NextNumber(-14, 14), rng:NextNumber(-10, 10), rng:NextNumber(-14, 14)),
			}
		end
	end
end

local function showFloatingText(position, text, color)
	local anchor = make("Part", {
		Anchored = true, CanCollide = false, CanQuery = false, CanTouch = false,
		Transparency = 1, Size = Vector3.new(0.2, 0.2, 0.2), Position = position, Parent = fxFolder,
	})
	local bb = make("BillboardGui", {
		Size = UDim2.new(0, 260, 0, 70),
		StudsOffset = Vector3.new(0, 3, 0),
		AlwaysOnTop = true,
		MaxDistance = 400,
		Parent = anchor,
	})
	local l = label(bb, { Text = text, Size = UDim2.fromScale(1, 1), TextColor3 = color })
	local s = textStroke(3)
	s.Parent = l
	tween(bb, 2.2, { StudsOffset = Vector3.new(0, 7, 0) })
	task.delay(1.6, function()
		tween(l, 0.6, { TextTransparency = 1 })
		tween(s, 0.6, { Transparency = 1 })
	end)
	task.delay(2.3, function()
		anchor:Destroy()
	end)
end

local function startRoll(info, def, releasePos, isLocal)
	local pumpkin = buildPumpkin(def, R)
	pumpkin.model.Parent = fxFolder
	local fx = makeFx(def)
	local roll = {
		model = pumpkin.model,
		pumpkin = pumpkin,
		fx = fx,
		D = info.distance,
		T = info.duration,
		cx = CONFIG.laneCenters[info.lane],
		start = os.clock(),
		releasePos = releasePos,
		isLocal = isLocal,
		hops = computeHops(info.distance, info.duration),
		airborne = false,
		pinSets = pinSetsFor(info.lane, info.distance),
		zoneShown = 1,
		speed = 0,
		finished = false,
	}
	roll.sound = playSound("Roll", fx.part, true)
	playSound("Release", fx.part)
	table.insert(rolls, roll)

	if isLocal then
		localRoll = roll
		camOffset = Vector3.new(0, 6, -15)
		camState = "follow"
		counterFrame.Visible = true
		counterLabel.Text = "0 m"
		counterZoneLabel.Text = CONFIG.zones[1].name
		counterZoneLabel.TextColor3 = rgb(CONFIG.zones[1].accent)
		shake(0.3)
	end
end

local function updateRoll(roll, now)
	local t = now - roll.start
	local u = math.clamp(t / roll.T, 0, 1)
	local s = roll.D * (1 - (1 - u) ^ 2)
	local v = u < 1 and (2 * roll.D / roll.T) * (1 - u) or 0
	roll.speed = v

	local hop = hopHeight(roll.hops, s)
	local airborne = hop > 0.05
	local x = roll.cx + math.sin(s * 0.045) * 0.35 * (1 - u)
	local pos = Vector3.new(x, CONFIG.laneTopY + R + hop, CONFIG.originZ + s)
	if t < 0.3 and roll.releasePos then
		-- drop from the bowler's hand onto the lane
		local a = t / 0.3
		pos = roll.releasePos:Lerp(pos, a * a)
	end
	roll.position = pos

	local wobble = math.sin(t * 11) * 0.08 * math.min(1, v / 30)
	roll.model:PivotTo(CFrame.new(pos) * CFrame.Angles(0, 0, wobble) * CFrame.Angles(s / R, 0, 0))

	local fx = roll.fx
	fx.part.CFrame = CFrame.new(pos)
	fx.trail.Enabled = v > 4
	fx.dust.Rate = (airborne or u >= 1) and 0 or math.clamp(v * 0.8, 4, 90)
	if roll.sound then
		roll.sound.PlaybackSpeed = 0.6 + math.min(v / 300, 1.2)
		roll.sound.Volume = airborne and 0.15 or math.clamp(v / 150, 0.2, 0.9)
	end

	-- landing off a ramp
	if roll.airborne and not airborne then
		fx.dust:Emit(30)
		playSound("Land", fx.part)
		if roll.isLocal then
			shake(0.2 + math.min(v / 250, 0.8))
		end
	end
	roll.airborne = airborne

	-- pins
	for _, set in ipairs(roll.pinSets) do
		if not set.knocked and s >= set.s - 1 then
			set.knocked = true
			knockPins(set.folder, v)
			fx.dust:Emit(20)
			playSound("Strike", fx.part)
			if roll.isLocal then
				flash("STRIKE! 🎳", PALETTE.gold, 0.7)
				shake(0.6)
			end
		end
	end

	if roll.isLocal then
		counterLabel.Text = commas(s) .. " m"
		local zoneIndex = math.clamp(math.floor(s / CONFIG.zoneLength) + 1, 1, #CONFIG.zones)
		if zoneIndex > roll.zoneShown then
			roll.zoneShown = zoneIndex
			showZoneBanner(zoneIndex)
			counterZoneLabel.Text = CONFIG.zones[zoneIndex].name
			counterZoneLabel.TextColor3 = rgb(CONFIG.zones[zoneIndex].accent)
			pressBounce(counterLabel)
		end
	end

	if u >= 1 and not roll.finished then
		roll.finished = true
		roll.finishedAt = now
		fx.trail.Enabled = false
		fx.burst:Emit(70)
		if fx.sparkle then
			fx.sparkle.Rate = 0
		end
		if roll.sound then
			roll.sound:Destroy()
			roll.sound = nil
		end
		playSound("Finish", fx.part)
		showFloatingText(pos, commas(roll.D) .. " m", roll.isLocal and PALETTE.gold or PALETTE.text)
		if roll.isLocal then
			counterLabel.Text = commas(roll.D) .. " m"
			pressBounce(counterLabel)
			shake(0.4)
		end
	end
end

local function finishRoll(roll)
	fadeAndDestroy(roll.pumpkin, 0.5)
	local fxPart = roll.fx.part
	task.delay(1.8, function()
		fxPart:Destroy()
	end)
	if roll == localRoll then
		localRoll = nil
		counterFrame.Visible = false
		restoreCamera()
	end
end

RunService.RenderStepped:Connect(function(dt)
	local now = os.clock()
	for i = #rolls, 1, -1 do
		local roll = rolls[i]
		updateRoll(roll, now)
		if roll.finished and now - roll.finishedAt > 2.4 then
			table.remove(rolls, i)
			finishRoll(roll)
		end
	end

	for pin, st in pairs(pinAnims) do
		st.t += dt
		if not pin.Parent then
			pinAnims[pin] = nil
		elseif st.t < 1.6 then
			st.vel += Vector3.new(0, -70, 0) * dt
			local p = st.cf.Position + st.vel * dt
			local floorY = CONFIG.laneTopY + 0.4
			if p.Y < floorY then
				p = Vector3.new(p.X, floorY, p.Z)
				st.vel = Vector3.new(st.vel.X * 0.5, math.abs(st.vel.Y) * 0.3, st.vel.Z * 0.5)
				st.spin *= 0.6
			end
			st.cf = CFrame.new(p) * st.cf.Rotation * CFrame.Angles(st.spin.X * dt, st.spin.Y * dt, st.spin.Z * dt)
			pin:PivotTo(st.cf)
		elseif st.t >= 3.2 and st.t < 3.7 then
			pin:PivotTo(st.cf:Lerp(st.origin, (st.t - 3.2) / 0.5))
		elseif st.t >= 3.7 then
			pin:PivotTo(st.origin)
			pinAnims[pin] = nil
		end
	end
end)

----------------------------------------------------------------
-- BOWLING FLOW
----------------------------------------------------------------

local localBusy = false
local awaitingStart = false

bowlStarted.OnClientEvent:Connect(function(info)
	local bowler = info.player
	local def = PumpkinById[info.pumpkin] or CONFIG.pumpkins[1]
	local isLocal = bowler == player
	local character = bowler and bowler.Character
	local windup = CONFIG.windup

	if isLocal then
		awaitingStart = false
		localBusy = true
		camBase = camera.CFrame
		camState = "windup"
	end

	if character then
		playBowlAnimation(character, windup)
	end

	-- the pumpkin sits in the bowler's hand through the swing
	local held = buildPumpkin(def, R)
	held.model.Parent = fxFolder
	local hand = getHand(character)
	local fallback = CFrame.new(CONFIG.laneCenters[info.lane], CONFIG.laneTopY + R + 2, CONFIG.originZ - 3)
	local holdConn = RunService.RenderStepped:Connect(function()
		if hand and hand.Parent then
			held.model:PivotTo(hand.CFrame * handHoldOffset(hand))
		else
			held.model:PivotTo(fallback)
		end
	end)
	held.model:PivotTo(hand and hand.Parent and hand.CFrame * handHoldOffset(hand) or fallback)

	task.delay(windup, function()
		holdConn:Disconnect()
		local releasePos = held.model:GetPivot().Position
		held.model:Destroy()
		startRoll(info, def, releasePos, isLocal)
	end)
end)

local function showResult(info)
	resultDistance.Text = "📏 " .. commas(info.distance) .. " m"
	resultWins.Text = "+" .. abbreviate(info.wins) .. " 🏆 Wins"
	local extras = {}
	if info.maxed then
		table.insert(extras, "🎃 MAX DISTANCE! Rebirth to grow faster!")
	elseif info.newBest then
		table.insert(extras, "⭐ NEW BEST!")
	end
	if info.zoneName then
		table.insert(extras, "Reached " .. info.zoneName .. "! +" .. abbreviate(info.zoneBonus) .. " 🏆")
	end
	if info.perfect then
		table.insert(extras, "✨ Perfect roll bonus!")
	end
	resultExtra.Text = table.concat(extras, "\n")
	resultFrame.Size = UDim2.new(0, 380, 0, #extras > 0 and 170 or 120)
	resultFrame.Visible = true
	local scale = resultFrame:FindFirstChildOfClass("UIScale")
	scale.Scale = 0.4
	tween(scale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
	local myToken = HttpService:GenerateGUID(false)
	resultFrame:SetAttribute("Token", myToken)
	task.delay(2.6, function()
		if resultFrame:GetAttribute("Token") == myToken then
			tween(scale, 0.25, { Scale = 0 }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
			task.wait(0.26)
			if resultFrame:GetAttribute("Token") == myToken then
				resultFrame.Visible = false
			end
		end
	end)
end

bowlResult.OnClientEvent:Connect(function(info)
	localBusy = false
	showResult(info)
end)

-- Power meter
local meterLocked = false
local meterNeedle = 0.5
local meterPhase = 0
local NEEDLE_SPEED = 1.2

local function laneAt(position)
	for _, pad in ipairs(padsFolder:GetChildren()) do
		local rel = position - pad.Position
		if math.abs(rel.X) <= pad.Size.X / 2 + 1 and math.abs(rel.Z) <= pad.Size.Z / 2 + 1 and math.abs(rel.Y) < 8 then
			return pad:GetAttribute("Lane")
		end
	end
	return nil
end

local function bowl()
	if localBusy or meterLocked or not meterFrame.Visible then
		return
	end
	localBusy = true
	awaitingStart = true
	meterLocked = true

	local offset = math.abs(meterNeedle - 0.5)
	if offset <= CONFIG.perfectWindow then
		flash("PERFECT! ✨", PALETTE.gold)
	elseif offset < 0.18 then
		flash("GREAT!", PALETTE.good)
	elseif offset < 0.32 then
		flash("GOOD", Color3.fromRGB(255, 220, 120))
	else
		flash("WEAK...", PALETTE.bad)
	end
	pressBounce(needle)
	requestBowl:FireServer(meterNeedle)

	task.delay(0.5, function()
		meterFrame.Visible = false
		meterLocked = false
	end)
	-- If the server rejected it (e.g. we'd stepped off the pad), unlock.
	task.delay(3, function()
		if awaitingStart then
			awaitingStart = false
			localBusy = false
		end
	end)
	-- Last-resort unlock in case a result is ever lost.
	task.delay(30, function()
		if localBusy and not localRoll then
			localBusy = false
		end
	end)
end

bowlButton.Activated:Connect(bowl)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.KeyCode == Enum.KeyCode.E
		or input.KeyCode == Enum.KeyCode.ButtonR2
		or input.KeyCode == Enum.KeyCode.ButtonX then
		bowl()
	end
end)

RunService.Heartbeat:Connect(function(dt)
	if not meterLocked then
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		local show = hrp ~= nil and not localBusy and laneAt(hrp.Position) ~= nil
		if show ~= meterFrame.Visible then
			meterFrame.Visible = show
			if show then
				meterPhase = rng:NextNumber(0, 2)
				local scale = meterFrame:FindFirstChildOfClass("UIScale") or make("UIScale", { Parent = meterFrame })
				scale.Scale = 0.6
				tween(scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
			end
		end
		if meterFrame.Visible then
			meterPhase = (meterPhase + dt * NEEDLE_SPEED) % 2
			meterNeedle = meterPhase < 1 and meterPhase or 2 - meterPhase
			needle.Position = UDim2.new(meterNeedle, 0, 0.5, 0)
		end
	end
	meterTitle.TextColor3 = math.abs(meterNeedle - 0.5) <= CONFIG.perfectWindow and PALETTE.good or PALETTE.gold
end)

----------------------------------------------------------------
-- STATS + "+1" POPUPS
----------------------------------------------------------------

local function showPlusPopup(amount)
	local head = player.Character and player.Character:FindFirstChild("Head")
	if not head then
		return
	end
	local bb = make("BillboardGui", {
		Adornee = head,
		Size = UDim2.new(0, 140, 0, 40),
		StudsOffset = Vector3.new(rng:NextNumber(-1.5, 1.5), 2.2, 0),
		AlwaysOnTop = true,
		Parent = playerGui,
	})
	local l = label(bb, { Text = "+" .. abbreviate(amount) .. " 💪", Size = UDim2.fromScale(1, 1), TextColor3 = PALETTE.gold })
	local s = textStroke(2)
	s.Parent = l
	tween(bb, 1, { StudsOffset = bb.StudsOffset + Vector3.new(0, 2.5, 0) })
	tween(l, 1, { TextTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	tween(s, 1, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(1.05, function()
		bb:Destroy()
	end)
end

local refreshShop -- forward declared, defined with the shop below
local refreshRebirth

task.spawn(function()
	local stats = player:WaitForChild("leaderstats")
	local strength = stats:WaitForChild("Strength")
	local wins = stats:WaitForChild("Wins")
	local best = stats:WaitForChild("Best")
	local rebirths = stats:WaitForChild("Rebirths")

	local lastStrength = strength.Value
	strengthLabel.Text = abbreviate(strength.Value)
	strength.Changed:Connect(function(value)
		local delta = value - lastStrength
		lastStrength = value
		strengthLabel.Text = abbreviate(value)
		if delta > 0 then
			showPlusPopup(delta)
			pressBounce(strengthLabel)
		end
	end)

	local function updateOthers()
		winsLabel.Text = abbreviate(wins.Value)
		bestLabel.Text = commas(best.Value) .. " m"
		rebirthsLabel.Text = tostring(rebirths.Value)
		if refreshShop then
			refreshShop()
		end
		if refreshRebirth then
			refreshRebirth()
		end
	end
	wins.Changed:Connect(updateOthers)
	best.Changed:Connect(updateOthers)
	rebirths.Changed:Connect(updateOthers)
	updateOthers()
end)

local function updateAttributeLabels()
	perSecondLabel.Text = "+" .. abbreviate(player:GetAttribute("StrengthPerSecond") or 1) .. " / sec"
	local def = PumpkinById[player:GetAttribute("Equipped") or "classic"]
	pumpkinLabel.Text = def and def.name or ""
	if refreshShop then
		refreshShop()
	end
	if refreshRebirth then
		refreshRebirth()
	end
end
player.AttributeChanged:Connect(updateAttributeLabels)

----------------------------------------------------------------
-- MODAL PANELS (shop, rebirth)
----------------------------------------------------------------

local openPanel = nil

local function makePanel(title, size, accent)
	local panel = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 0),
		Size = size,
		BackgroundColor3 = PALETTE.bg,
		BackgroundTransparency = 0.05,
		Visible = false,
		ZIndex = 10,
		Parent = gui,
	}, { corner(18), stroke(accent, 3), make("UIScale", {}) })
	label(panel, { Text = title, Position = UDim2.new(0, 16, 0, 10), Size = UDim2.new(1, -80, 0, 38),
		TextColor3 = accent, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 10 })
	local close = button(panel, { Text = "X", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 10),
		Size = UDim2.new(0, 40, 0, 40), ZIndex = 11 }, PALETTE.bad)
	close.Activated:Connect(function()
		panel.Visible = false
		openPanel = nil
	end)
	return panel
end

local function togglePanel(panel)
	if openPanel and openPanel ~= panel then
		openPanel.Visible = false
	end
	if panel.Visible then
		panel.Visible = false
		openPanel = nil
		return
	end
	panel.Visible = true
	openPanel = panel
	-- shrink to fit small (phone) screens
	local viewport = camera.ViewportSize
	local fit = math.min(1, (viewport.X - 24) / panel.Size.X.Offset, (viewport.Y - 60) / panel.Size.Y.Offset)
	local scale = panel:FindFirstChildOfClass("UIScale")
	scale.Scale = fit * 0.6
	tween(scale, 0.3, { Scale = fit }, Enum.EasingStyle.Back)
end

-- Pumpkin shop
local shopPanel = makePanel("🎃 PUMPKINS", UDim2.new(0, 660, 0, 470), PALETTE.accent)
label(shopPanel, { Text = "Better pumpkins multiply the Strength you gain every second.", Position = UDim2.new(0, 16, 0, 48),
	Size = UDim2.new(1, -32, 0, 20), TextColor3 = PALETTE.subtext, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 10 })
local shopScroll = make("ScrollingFrame", {
	Position = UDim2.new(0, 12, 0, 76),
	Size = UDim2.new(1, -24, 1, -146),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 8,
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	CanvasSize = UDim2.new(),
	ZIndex = 10,
	Parent = shopPanel,
}, {
	make("UIGridLayout", {
		CellSize = UDim2.new(0, 145, 0, 200),
		CellPadding = UDim2.new(0, 10, 0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
	}),
})

local passBar = make("Frame", {
	Position = UDim2.new(0, 12, 1, -62),
	Size = UDim2.new(1, -24, 0, 50),
	BackgroundTransparency = 1,
	ZIndex = 10,
	Parent = shopPanel,
}, {
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0, 12),
	}),
})
local passButtons = {}
for _, pass in ipairs({
	{ key = "DoubleStrength", attr = "HasDoubleStrength", text = "⭐ 2x STRENGTH" },
	{ key = "DoubleWins", attr = "HasDoubleWins", text = "⭐ 2x WINS" },
}) do
	local b = button(passBar, { Text = pass.text, Size = UDim2.new(0, 240, 1, 0), ZIndex = 11 }, Color3.fromRGB(60, 160, 255))
	passButtons[pass.key] = { button = b, pass = pass }
	b.Activated:Connect(function()
		local id = CONFIG.passes[pass.key]
		if id and id ~= 0 and not player:GetAttribute(pass.attr) then
			MarketplaceService:PromptGamePassPurchase(player, id)
		end
	end)
end

local cards = {}
local viewportModels = {}

for i, def in ipairs(CONFIG.pumpkins) do
	local card = make("Frame", {
		BackgroundColor3 = PALETTE.panel,
		LayoutOrder = i,
		ZIndex = 10,
		Parent = shopScroll,
	}, { corner(12) })
	local cardStroke = stroke(rgb(def.trail or def.color), 2)
	cardStroke.Parent = card

	local viewport = make("ViewportFrame", {
		Position = UDim2.new(0, 6, 0, 6),
		Size = UDim2.new(1, -12, 0, 96),
		BackgroundColor3 = PALETTE.panel2,
		Ambient = Color3.fromRGB(170, 160, 160),
		LightColor = Color3.fromRGB(255, 240, 220),
		LightDirection = Vector3.new(-1, -1, 1),
		ZIndex = 10,
		Parent = card,
	}, { corner(10) })
	local preview = buildPumpkin(def, 1, true)
	preview.model.Parent = viewport
	local vpCam = make("Camera", { FieldOfView = 40, Parent = viewport })
	vpCam.CFrame = CFrame.lookAt(Vector3.new(0, 0.9, -4.6), Vector3.new(0, 0, 0))
	viewport.CurrentCamera = vpCam
	table.insert(viewportModels, { model = preview.model, offset = i * 0.7 })

	label(card, { Text = def.name, Position = UDim2.new(0, 6, 0, 104), Size = UDim2.new(1, -12, 0, 22), ZIndex = 10 })
	label(card, { Text = "x" .. abbreviate(def.mult) .. " 💪/sec", Position = UDim2.new(0, 6, 0, 126), Size = UDim2.new(1, -12, 0, 20),
		TextColor3 = PALETTE.good, ZIndex = 10 })
	local action = button(card, { Text = "", Position = UDim2.new(0, 8, 1, -46), Size = UDim2.new(1, -16, 0, 38), ZIndex = 11 })

	action.Activated:Connect(function()
		local owned = string.find("," .. (player:GetAttribute("Owned") or "") .. ",", "," .. def.id .. ",", 1, true)
		local fn = owned and equipPumpkinFn or buyPumpkinFn
		local ok, message = fn:InvokeServer(def.id)
		toast(message or "", ok and "good" or "bad")
		if ok then
			pressBounce(card)
			if not owned then
				playSound("Buy")
			end
		end
	end)

	cards[def.id] = { card = card, action = action, def = def, stroke = cardStroke }
end

refreshShop = function()
	local ownedSet = {}
	for id in string.gmatch(player:GetAttribute("Owned") or "", "[^,]+") do
		ownedSet[id] = true
	end
	local equipped = player:GetAttribute("Equipped")
	local stats = player:FindFirstChild("leaderstats")
	local wins = stats and stats:FindFirstChild("Wins") and stats.Wins.Value or 0

	for id, c in pairs(cards) do
		if id == equipped then
			c.action.Text = "EQUIPPED"
			c.action.BackgroundColor3 = PALETTE.good
			c.action.AutoButtonColor = false
			c.stroke.Thickness = 4
		elseif ownedSet[id] then
			c.action.Text = "EQUIP"
			c.action.BackgroundColor3 = PALETTE.accent
			c.action.AutoButtonColor = true
			c.stroke.Thickness = 2
		else
			c.action.Text = "🏆 " .. abbreviate(c.def.cost)
			c.action.BackgroundColor3 = wins >= c.def.cost and PALETTE.good or Color3.fromRGB(110, 90, 100)
			c.action.AutoButtonColor = true
			c.stroke.Thickness = 2
		end
	end

	for _, entry in pairs(passButtons) do
		local id = CONFIG.passes[entry.pass.key]
		if player:GetAttribute(entry.pass.attr) then
			entry.button.Text = entry.pass.text .. " ✅"
		elseif not id or id == 0 then
			entry.button.Text = entry.pass.text .. " (Soon)"
		else
			entry.button.Text = entry.pass.text
		end
	end
end

RunService.RenderStepped:Connect(function()
	if shopPanel.Visible then
		local t = os.clock()
		for _, vm in ipairs(viewportModels) do
			-- stem up, slowly turning so the face swings round to the camera
			vm.model:PivotTo(CFrame.Angles(0, t * 1.2 + vm.offset, 0) * CFrame.Angles(0, 0, math.pi / 2))
		end
	end
end)

-- Rebirth panel
local rebirthPanel = makePanel("🔁 REBIRTH", UDim2.new(0, 400, 0, 290), PALETTE.purple)
local rebirthInfo = label(rebirthPanel, { Text = "", Position = UDim2.new(0, 20, 0, 56), Size = UDim2.new(1, -40, 0, 110),
	TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 10 })
label(rebirthPanel, { Text = "Resets your Strength and Wins.\nKeeps your pumpkins and best distance.", Position = UDim2.new(0, 20, 0, 170),
	Size = UDim2.new(1, -40, 0, 40), TextColor3 = PALETTE.subtext, ZIndex = 10 })
local rebirthConfirm = button(rebirthPanel, { Text = "REBIRTH", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -16),
	Size = UDim2.new(0, 220, 0, 50), ZIndex = 11 }, PALETTE.purple)

refreshRebirth = function()
	local stats = player:FindFirstChild("leaderstats")
	local r = stats and stats:FindFirstChild("Rebirths") and stats.Rebirths.Value or 0
	local wins = stats and stats:FindFirstChild("Wins") and stats.Wins.Value or 0
	local cost = player:GetAttribute("RebirthCost") or 0
	local now = 1 + CONFIG.rebirthBonus * r
	local nextMult = 1 + CONFIG.rebirthBonus * (r + 1)
	rebirthInfo.Text = string.format("Rebirths: %d\nBonus: x%s → x%s 💪 & 🏆\nCost: 🏆 %s  (you have %s)",
		r, tostring(now), tostring(nextMult), abbreviate(cost), abbreviate(wins))
	rebirthConfirm.BackgroundColor3 = wins >= cost and PALETTE.purple or Color3.fromRGB(110, 90, 100)
end

rebirthConfirm.Activated:Connect(function()
	local ok, message = rebirthFn:InvokeServer()
	toast(message or "", ok and "good" or "bad")
	if ok then
		playSound("Rebirth")
		flash("🔁 REBIRTH!", PALETTE.purple, 1.4)
		rebirthPanel.Visible = false
		openPanel = nil
	end
end)

shopButton.Activated:Connect(function()
	pressBounce(shopButton)
	refreshShop()
	togglePanel(shopPanel)
end)
rebirthButton.Activated:Connect(function()
	pressBounce(rebirthButton)
	refreshRebirth()
	togglePanel(rebirthPanel)
end)

updateAttributeLabels()

----------------------------------------------------------------
-- ZONE LIGHTING (local only, follows the camera down the track)
----------------------------------------------------------------

task.spawn(function()
	local currentZone = nil
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	while true do
		local z = camera.CFrame.Position.Z
		local zoneIndex = math.clamp(math.floor((z - CONFIG.originZ) / CONFIG.zoneLength) + 1, 1, #CONFIG.zones)
		if zoneIndex ~= currentZone then
			currentZone = zoneIndex
			local l = CONFIG.zones[zoneIndex].lighting
			tween(Lighting, 1.5, {
				ClockTime = l.clock,
				Ambient = rgb(l.ambient),
				OutdoorAmbient = rgb(l.outdoor),
			}, Enum.EasingStyle.Sine)
			atmosphere = atmosphere and atmosphere.Parent and atmosphere or Lighting:FindFirstChildOfClass("Atmosphere")
			if atmosphere then
				tween(atmosphere, 1.5, { Color = rgb(l.atmo), Density = l.density }, Enum.EasingStyle.Sine)
			end
		end
		task.wait(0.25)
	end
end)
