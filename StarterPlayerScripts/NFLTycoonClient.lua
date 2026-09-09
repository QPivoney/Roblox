--[[
	NFL FRANCHISE TYCOON — Client UI Script
	-----------------------------------------------------------
	HOW TO INSTALL:
	1. In Roblox Studio, go to StarterPlayer > StarterPlayerScripts.
	2. Insert a new LocalScript named "NFLTycoonClient".
	3. Delete the default line and paste this entire file in.
	4. Requires NFLTycoonServer.lua to already be running in
	   ServerScriptService (it creates the RemoteEvents this script waits on).

	Builds the entire HUD at runtime: cash/floor readout with a progress bar,
	toast notifications, a live top-10 leaderboard panel, a team customize
	dialog (name + jersey color), and a game pass shop. No external UI
	assets required.
	-----------------------------------------------------------
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local MarketplaceService = game:GetService("MarketplaceService")
local SoundService = game:GetService("SoundService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local remotesFolder = ReplicatedStorage:WaitForChild("NFLTycoonRemotes")
local notifyEvent = remotesFolder:WaitForChild("Notify")
local openCustomizeEvent = remotesFolder:WaitForChild("OpenCustomizeDialog")
local confirmCustomizeEvent = remotesFolder:WaitForChild("ConfirmCustomize")
local getLeaderboardFn = remotesFolder:WaitForChild("GetLeaderboardTop")

-- Keep these in sync with GAMEPASS_IDS in NFLTycoonServer.lua
local GAMEPASS_IDS = {
	DoubleCash  = 0,
	AutoCollect = 0,
	VIP         = 0,
}

-- Keep this list (order + count) in sync with JERSEY_COLOR_PRESETS on the server.
local JERSEY_COLOR_PRESETS = {
	{ name = "Blue",   color = Color3.fromRGB(13, 105, 172) },
	{ name = "Red",    color = Color3.fromRGB(196, 40, 28) },
	{ name = "Green",  color = Color3.fromRGB(31, 128, 29) },
	{ name = "Yellow", color = Color3.fromRGB(245, 205, 48) },
	{ name = "Orange", color = Color3.fromRGB(218, 133, 65) },
	{ name = "Purple", color = Color3.fromRGB(107, 50, 124) },
	{ name = "Pink",   color = Color3.fromRGB(255, 102, 204) },
	{ name = "Cyan",   color = Color3.fromRGB(4, 175, 236) },
	{ name = "Black",  color = Color3.fromRGB(17, 17, 17) },
	{ name = "White",  color = Color3.fromRGB(248, 248, 248) },
}

local PALETTE = {
	bg       = Color3.fromRGB(18, 24, 33),
	panel    = Color3.fromRGB(26, 34, 46),
	accent   = Color3.fromRGB(245, 197, 66),
	text     = Color3.fromRGB(240, 240, 245),
	subtext  = Color3.fromRGB(160, 170, 185),
	good     = Color3.fromRGB(94, 201, 120),
	bad      = Color3.fromRGB(224, 90, 90),
}

----------------------------------------------------------------
-- GUI HELPERS
----------------------------------------------------------------

local function corner(inst, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = inst
	return c
end

local function stroke(inst, color, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color or Color3.fromRGB(0, 0, 0)
	s.Thickness = thickness or 1
	s.Parent = inst
	return s
end

local function newFrame(parent, size, position, color, transparency)
	local f = Instance.new("Frame")
	f.Size = size
	f.Position = position or UDim2.new(0, 0, 0, 0)
	f.BackgroundColor3 = color or PALETTE.panel
	f.BackgroundTransparency = transparency or 0
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

local function newLabel(parent, size, position, text, textSize, color, font)
	local l = Instance.new("TextLabel")
	l.Size = size
	l.Position = position or UDim2.new(0, 0, 0, 0)
	l.BackgroundTransparency = 1
	l.Text = text or ""
	l.TextSize = textSize or 18
	l.TextColor3 = color or PALETTE.text
	l.Font = font or Enum.Font.GothamBold
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

local function newButton(parent, size, position, text, bgColor)
	local b = Instance.new("TextButton")
	b.Size = size
	b.Position = position or UDim2.new(0, 0, 0, 0)
	b.BackgroundColor3 = bgColor or PALETTE.accent
	b.Text = text or ""
	b.TextSize = 18
	b.TextColor3 = Color3.fromRGB(20, 20, 25)
	b.Font = Enum.Font.GothamBold
	b.AutoButtonColor = true
	b.Parent = parent
	corner(b, 8)
	return b
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

----------------------------------------------------------------
-- ROOT
----------------------------------------------------------------

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "NFLTycoonHUD"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = false
screenGui.Parent = playerGui

----------------------------------------------------------------
-- TOP BAR (team name, cash, floor, progress bar)
----------------------------------------------------------------

local topBar = newFrame(screenGui, UDim2.new(0, 300, 0, 120), UDim2.new(0, 12, 0, 12), PALETTE.panel)
corner(topBar, 14)
stroke(topBar, Color3.fromRGB(0, 0, 0), 1)

local teamNameLabel = newLabel(topBar, UDim2.new(1, -20, 0, 22), UDim2.new(0, 10, 0, 6), "My Team", 18, PALETTE.accent)
local cashLabel = newLabel(topBar, UDim2.new(1, -20, 0, 32), UDim2.new(0, 10, 0, 28), "$0", 28, PALETTE.good)
local floorLabel = newLabel(topBar, UDim2.new(1, -20, 0, 18), UDim2.new(0, 10, 0, 62), "Unclaimed", 15, PALETTE.subtext, Enum.Font.Gotham)

local progressBg = newFrame(topBar, UDim2.new(1, -20, 0, 14), UDim2.new(0, 10, 0, 84), Color3.fromRGB(12, 16, 22))
corner(progressBg, 7)
local progressFill = newFrame(progressBg, UDim2.new(0, 0, 1, 0), UDim2.new(0, 0, 0, 0), PALETTE.accent)
corner(progressFill, 7)

local nextLabel = newLabel(topBar, UDim2.new(1, -20, 0, 14), UDim2.new(0, 10, 0, 100), "", 12, PALETTE.subtext, Enum.Font.Gotham)

----------------------------------------------------------------
-- TOP RIGHT BUTTON ROW
----------------------------------------------------------------

local buttonRow = newFrame(screenGui, UDim2.new(0, 160, 0, 46), UDim2.new(1, -172, 0, 12), PALETTE.panel, 1)
local leaderboardButton = newButton(buttonRow, UDim2.new(0, 46, 0, 46), UDim2.new(0, 0, 0, 0), "\xF0\x9F\x8F\x86", PALETTE.panel)
leaderboardButton.TextColor3 = PALETTE.accent
leaderboardButton.TextSize = 22
stroke(leaderboardButton, Color3.fromRGB(0, 0, 0), 1)

local shopButton = newButton(buttonRow, UDim2.new(0, 46, 0, 46), UDim2.new(0, 56, 0, 0), "\xF0\x9F\x9B\x92", PALETTE.panel)
shopButton.TextColor3 = PALETTE.accent
shopButton.TextSize = 22
stroke(shopButton, Color3.fromRGB(0, 0, 0), 1)

local settingsButton = newButton(buttonRow, UDim2.new(0, 46, 0, 46), UDim2.new(0, 112, 0, 0), "\xE2\x9A\x99", PALETTE.panel)
settingsButton.TextColor3 = PALETTE.accent
settingsButton.TextSize = 22
stroke(settingsButton, Color3.fromRGB(0, 0, 0), 1)

----------------------------------------------------------------
-- TOAST NOTIFICATIONS
----------------------------------------------------------------

local toastContainer = newFrame(screenGui, UDim2.new(0, 360, 1, 0), UDim2.new(0.5, -180, 0, 0), PALETTE.panel, 1)
local toastLayout = Instance.new("UIListLayout")
toastLayout.Padding = UDim.new(0, 8)
toastLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
toastLayout.SortOrder = Enum.SortOrder.LayoutOrder
toastLayout.Parent = toastContainer

local toastColors = {
	success = PALETTE.good,
	error = PALETTE.bad,
	info = PALETTE.accent,
	prestige = Color3.fromRGB(255, 215, 0),
}

local toastOrderCounter = 0

local function spawnToast(title, message, kind)
	local color = toastColors[kind] or PALETTE.accent

	toastOrderCounter += 1
	local toast = newFrame(toastContainer, UDim2.new(1, 0, 0, 60), UDim2.new(0, 0, 0, 20), PALETTE.panel)
	toast.BackgroundTransparency = 0.05
	toast.LayoutOrder = toastOrderCounter
	corner(toast, 10)
	stroke(toast, color, 2)

	newLabel(toast, UDim2.new(1, -16, 0, 22), UDim2.new(0, 10, 0, 4), title, 16, color)
	local msgLabel = newLabel(toast, UDim2.new(1, -16, 0, 30), UDim2.new(0, 10, 0, 26), message, 13, PALETTE.text, Enum.Font.Gotham)
	msgLabel.TextWrapped = true

	toast.Position = UDim2.new(0, 0, 0, -70)
	toast.BackgroundTransparency = 1
	local showTween = TweenService:Create(toast, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 0.05,
	})
	showTween:Play()

	task.delay(4.5, function()
		local fadeTween = TweenService:Create(toast, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			BackgroundTransparency = 1,
		})
		fadeTween:Play()
		fadeTween.Completed:Wait()
		toast:Destroy()
	end)
end

notifyEvent.OnClientEvent:Connect(function(title, message, kind)
	spawnToast(title, message, kind)
end)

----------------------------------------------------------------
-- LEADERBOARD PANEL
----------------------------------------------------------------

local leaderboardPanel = newFrame(screenGui, UDim2.new(0, 320, 0, 380), UDim2.new(0.5, -160, 0.5, -190), PALETTE.panel)
corner(leaderboardPanel, 14)
stroke(leaderboardPanel, Color3.fromRGB(0, 0, 0), 1)
leaderboardPanel.Visible = false

newLabel(leaderboardPanel, UDim2.new(1, -20, 0, 30), UDim2.new(0, 10, 0, 10), "\xF0\x9F\x8F\x86 Top Franchises", 20, PALETTE.accent)
local closeLbButton = newButton(leaderboardPanel, UDim2.new(0, 28, 0, 28), UDim2.new(1, -38, 0, 10), "X", PALETTE.bad)
closeLbButton.TextColor3 = PALETTE.text

local leaderboardList = newFrame(leaderboardPanel, UDim2.new(1, -20, 1, -60), UDim2.new(0, 10, 0, 50), PALETTE.panel, 1)
local lbLayout = Instance.new("UIListLayout")
lbLayout.Padding = UDim.new(0, 4)
lbLayout.SortOrder = Enum.SortOrder.LayoutOrder
lbLayout.Parent = leaderboardList

local leaderboardOpen = false

local function refreshLeaderboard()
	task.spawn(function()
		local ok, results = pcall(function()
			return getLeaderboardFn:InvokeServer()
		end)
		if not ok or not results then return end

		for _, child in ipairs(leaderboardList:GetChildren()) do
			if not child:IsA("UIListLayout") then
				child:Destroy()
			end
		end

		if #results == 0 then
			newLabel(leaderboardList, UDim2.new(1, 0, 0, 24), UDim2.new(0, 0, 0, 0), "No franchises yet — be the first!", 14, PALETTE.subtext, Enum.Font.Gotham)
			return
		end

		for i, entry in ipairs(results) do
			local row = newFrame(leaderboardList, UDim2.new(1, 0, 0, 26), UDim2.new(0, 0, 0, 0), Color3.fromRGB(20, 27, 37))
			corner(row, 6)
			newLabel(row, UDim2.new(0, 30, 1, 0), UDim2.new(0, 6, 0, 0), "#" .. i, 14, PALETTE.accent)
			newLabel(row, UDim2.new(1, -140, 1, 0), UDim2.new(0, 38, 0, 0), entry.name, 14, PALETTE.text, Enum.Font.Gotham)
			local moneyLabel = newLabel(row, UDim2.new(0, 90, 1, 0), UDim2.new(1, -96, 0, 0), formatCash(entry.value), 14, PALETTE.good)
			moneyLabel.TextXAlignment = Enum.TextXAlignment.Right
		end
	end)
end

closeLbButton.MouseButton1Click:Connect(function()
	leaderboardOpen = false
	leaderboardPanel.Visible = false
end)

task.spawn(function()
	while true do
		task.wait(20)
		if leaderboardOpen then
			refreshLeaderboard()
		end
	end
end)

----------------------------------------------------------------
-- GAME PASS SHOP PANEL
----------------------------------------------------------------

local shopPanel = newFrame(screenGui, UDim2.new(0, 340, 0, 300), UDim2.new(0.5, -170, 0.5, -150), PALETTE.panel)
corner(shopPanel, 14)
stroke(shopPanel, Color3.fromRGB(0, 0, 0), 1)
shopPanel.Visible = false

newLabel(shopPanel, UDim2.new(1, -20, 0, 30), UDim2.new(0, 10, 0, 10), "\xF0\x9F\x9B\x92 Franchise Shop", 20, PALETTE.accent)
local closeShopButton = newButton(shopPanel, UDim2.new(0, 28, 0, 28), UDim2.new(1, -38, 0, 10), "X", PALETTE.bad)
closeShopButton.TextColor3 = PALETTE.text

local shopItems = {
	{ name = "2x Cash",       desc = "Double all dropper income, forever.", id = GAMEPASS_IDS.DoubleCash },
	{ name = "Auto Collector", desc = "Cash is credited instantly, no touching required.", id = GAMEPASS_IDS.AutoCollect },
	{ name = "VIP",           desc = "Faster movement + a VIP badge.", id = GAMEPASS_IDS.VIP },
}

for i, item in ipairs(shopItems) do
	local card = newFrame(shopPanel, UDim2.new(1, -20, 0, 68), UDim2.new(0, 10, 0, 46 + (i - 1) * 76), Color3.fromRGB(20, 27, 37))
	corner(card, 10)

	newLabel(card, UDim2.new(1, -110, 0, 22), UDim2.new(0, 10, 0, 8), item.name, 16, PALETTE.accent)
	local descLabel = newLabel(card, UDim2.new(1, -110, 0, 32), UDim2.new(0, 10, 0, 30), item.desc, 12, PALETTE.subtext, Enum.Font.Gotham)
	descLabel.TextWrapped = true

	local buyButton = newButton(card, UDim2.new(0, 90, 0, 40), UDim2.new(1, -100, 0, 14), item.id == 0 and "Soon" or "Buy", item.id == 0 and Color3.fromRGB(60, 65, 75) or PALETTE.accent)
	if item.id == 0 then
		buyButton.AutoButtonColor = false
		buyButton.TextColor3 = PALETTE.subtext
	else
		buyButton.MouseButton1Click:Connect(function()
			MarketplaceService:PromptGamePassPurchase(player, item.id)
		end)
	end
end

closeShopButton.MouseButton1Click:Connect(function()
	shopPanel.Visible = false
end)

----------------------------------------------------------------
-- SETTINGS PANEL
----------------------------------------------------------------

local settingsPanel = newFrame(screenGui, UDim2.new(0, 300, 0, 180), UDim2.new(0.5, -150, 0.5, -90), PALETTE.panel)
corner(settingsPanel, 14)
stroke(settingsPanel, Color3.fromRGB(0, 0, 0), 1)
settingsPanel.Visible = false

newLabel(settingsPanel, UDim2.new(1, -20, 0, 30), UDim2.new(0, 10, 0, 10), "\xE2\x9A\x99 Settings", 20, PALETTE.accent)
local closeSettingsButton = newButton(settingsPanel, UDim2.new(0, 28, 0, 28), UDim2.new(1, -38, 0, 10), "X", PALETTE.bad)
closeSettingsButton.TextColor3 = PALETTE.text

local musicButton = newButton(settingsPanel, UDim2.new(1, -20, 0, 40), UDim2.new(0, 10, 0, 54), "Toggle Stadium Music", PALETTE.accent)
local musicOn = true

musicButton.MouseButton1Click:Connect(function()
	local ambience = SoundService:FindFirstChild("StadiumAmbience")
	if not ambience then
		spawnToast("No Music Set", "The host hasn't uploaded stadium ambience audio yet.", "info")
		return
	end
	musicOn = not musicOn
	ambience.Volume = musicOn and 0.3 or 0
	musicButton.Text = musicOn and "Toggle Stadium Music (On)" or "Toggle Stadium Music (Off)"
end)

newLabel(settingsPanel, UDim2.new(1, -20, 0, 40), UDim2.new(0, 10, 0, 104), "NFL Franchise Tycoon", 13, PALETTE.subtext, Enum.Font.Gotham)

closeSettingsButton.MouseButton1Click:Connect(function()
	settingsPanel.Visible = false
end)

----------------------------------------------------------------
-- PANEL TOGGLE WIRING (mutual exclusion so panels never stack)
----------------------------------------------------------------

local function closeAllPanels()
	leaderboardOpen = false
	leaderboardPanel.Visible = false
	shopPanel.Visible = false
	settingsPanel.Visible = false
end

leaderboardButton.MouseButton1Click:Connect(function()
	local opening = not leaderboardPanel.Visible
	closeAllPanels()
	leaderboardOpen = opening
	leaderboardPanel.Visible = opening
	if opening then
		refreshLeaderboard()
	end
end)

shopButton.MouseButton1Click:Connect(function()
	local opening = not shopPanel.Visible
	closeAllPanels()
	shopPanel.Visible = opening
end)

settingsButton.MouseButton1Click:Connect(function()
	local opening = not settingsPanel.Visible
	closeAllPanels()
	settingsPanel.Visible = opening
end)

----------------------------------------------------------------
-- CUSTOMIZE TEAM DIALOG
----------------------------------------------------------------

local customizePanel = newFrame(screenGui, UDim2.new(0, 360, 0, 320), UDim2.new(0.5, -180, 0.5, -160), PALETTE.panel)
corner(customizePanel, 14)
stroke(customizePanel, Color3.fromRGB(0, 0, 0), 1)
customizePanel.Visible = false
customizePanel.ZIndex = 5

newLabel(customizePanel, UDim2.new(1, -20, 0, 30), UDim2.new(0, 10, 0, 10), "Customize Your Franchise", 18, PALETTE.accent)

newLabel(customizePanel, UDim2.new(1, -20, 0, 18), UDim2.new(0, 10, 0, 46), "Team Name", 13, PALETTE.subtext, Enum.Font.Gotham)
local nameBox = Instance.new("TextBox")
nameBox.Size = UDim2.new(1, -20, 0, 36)
nameBox.Position = UDim2.new(0, 10, 0, 66)
nameBox.BackgroundColor3 = Color3.fromRGB(12, 16, 22)
nameBox.TextColor3 = PALETTE.text
nameBox.PlaceholderText = "My Team"
nameBox.Text = ""
nameBox.ClearTextOnFocus = false
nameBox.Font = Enum.Font.Gotham
nameBox.TextSize = 16
nameBox.Parent = customizePanel
corner(nameBox, 8)

newLabel(customizePanel, UDim2.new(1, -20, 0, 18), UDim2.new(0, 10, 0, 112), "Jersey Color", 13, PALETTE.subtext, Enum.Font.Gotham)

local swatchContainer = newFrame(customizePanel, UDim2.new(1, -20, 0, 90), UDim2.new(0, 10, 0, 132), PALETTE.panel, 1)
local swatchLayout = Instance.new("UIGridLayout")
swatchLayout.CellSize = UDim2.new(0, 30, 0, 30)
swatchLayout.CellPadding = UDim2.new(0, 6, 0, 6)
swatchLayout.Parent = swatchContainer

local selectedColorIndex = 1
local swatchButtons = {}

for i, preset in ipairs(JERSEY_COLOR_PRESETS) do
	local swatch = Instance.new("TextButton")
	swatch.Size = UDim2.new(0, 30, 0, 30)
	swatch.BackgroundColor3 = preset.color
	swatch.Text = ""
	swatch.LayoutOrder = i
	swatch.Parent = swatchContainer
	corner(swatch, 15)
	local ring = stroke(swatch, PALETTE.text, 1)
	ring.Transparency = 1
	swatchButtons[i] = swatch

	swatch.MouseButton1Click:Connect(function()
		selectedColorIndex = i
		for idx, btn in ipairs(swatchButtons) do
			local s = btn:FindFirstChildOfClass("UIStroke")
			if s then
				s.Transparency = (idx == i) and 0 or 1
				s.Thickness = 3
			end
		end
	end)
end

local confirmButton = newButton(customizePanel, UDim2.new(0, 150, 0, 40), UDim2.new(0, 10, 1, -50), "Confirm", PALETTE.good)
confirmButton.TextColor3 = Color3.fromRGB(15, 15, 15)
local cancelButton = newButton(customizePanel, UDim2.new(0, 150, 0, 40), UDim2.new(1, -160, 1, -50), "Cancel", PALETTE.bad)

confirmButton.MouseButton1Click:Connect(function()
	confirmCustomizeEvent:FireServer(nameBox.Text, selectedColorIndex)
	customizePanel.Visible = false
end)

cancelButton.MouseButton1Click:Connect(function()
	customizePanel.Visible = false
end)

openCustomizeEvent.OnClientEvent:Connect(function(currentName, currentColorIndex)
	nameBox.Text = currentName or ""
	selectedColorIndex = currentColorIndex or 1
	for idx, btn in ipairs(swatchButtons) do
		local s = btn:FindFirstChildOfClass("UIStroke")
		if s then
			s.Transparency = (idx == selectedColorIndex) and 0 or 1
			s.Thickness = 3
		end
	end
	customizePanel.Visible = true
end)

----------------------------------------------------------------
-- LIVE STAT BINDING
----------------------------------------------------------------

local leaderstats = player:WaitForChild("leaderstats")
local cashStat = leaderstats:WaitForChild("Cash")
local floorStat = leaderstats:WaitForChild("Floor")

local tycoonInfo = player:WaitForChild("TycoonInfo")
local floorNameValue = tycoonInfo:WaitForChild("FloorName")
local nextFloorNameValue = tycoonInfo:WaitForChild("NextFloorName")
local nextCostValue = tycoonInfo:WaitForChild("NextCost")
local prestigeLevelValue = tycoonInfo:WaitForChild("PrestigeLevel")
local teamNameValue = tycoonInfo:WaitForChild("TeamName")

local displayedCash = Instance.new("NumberValue")
displayedCash.Value = cashStat.Value

displayedCash:GetPropertyChangedSignal("Value"):Connect(function()
	cashLabel.Text = formatCash(displayedCash.Value)
end)
cashLabel.Text = formatCash(displayedCash.Value)

local function animateCashTo(target)
	local tween = TweenService:Create(displayedCash, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = target })
	tween:Play()
end

cashStat:GetPropertyChangedSignal("Value"):Connect(function()
	animateCashTo(cashStat.Value)
end)

local function refreshHud()
	local ringSuffix = prestigeLevelValue.Value > 0 and (" \xF0\x9F\x8F\x86 x" .. prestigeLevelValue.Value) or ""
	teamNameLabel.Text = teamNameValue.Value .. ringSuffix

	if floorStat.Value == 0 then
		floorLabel.Text = "Unclaimed — find an open plot!"
	else
		floorLabel.Text = "Floor " .. floorStat.Value .. ": " .. floorNameValue.Value
	end

	if nextCostValue.Value > 0 then
		local percent = math.clamp(cashStat.Value / nextCostValue.Value, 0, 1)
		local fillTween = TweenService:Create(progressFill, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.new(percent, 0, 1, 0),
		})
		fillTween:Play()
		nextLabel.Text = "Next: " .. nextFloorNameValue.Value .. " (" .. formatCash(nextCostValue.Value) .. ")"
	else
		progressFill.Size = UDim2.new(1, 0, 1, 0)
		nextLabel.Text = "Fully built!"
	end
end

floorNameValue.Changed:Connect(refreshHud)
nextFloorNameValue.Changed:Connect(refreshHud)
nextCostValue.Changed:Connect(refreshHud)
prestigeLevelValue.Changed:Connect(refreshHud)
teamNameValue.Changed:Connect(refreshHud)
floorStat:GetPropertyChangedSignal("Value"):Connect(refreshHud)
cashStat:GetPropertyChangedSignal("Value"):Connect(refreshHud)

refreshHud()

----------------------------------------------------------------
-- WELCOME MESSAGE
----------------------------------------------------------------

task.delay(2, function()
	spawnToast("Welcome!", "Touch a Claim Sign to start your franchise. Collect footballs, sign players, and build to the Stadium!", "info")
end)
