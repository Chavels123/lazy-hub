local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local WINDUI_URL = "https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"
local CHECK_EVERY = 3
local MIN_TAP_AGE = 0.45
local TAP_RETRY = 0.5
local RETRY_FAILED_AFTER = 30
local START_TIMEOUT = 6
local THROW_TIMEOUT = 90
local PAUSE_BETWEEN = 3

local env = getgenv()
local oldStops = {
	"__ThrowHubStop",
	"__AutoThrowStop",
	"__AutoEquipBestStop",
	"__AutoBuyBestFoodStop",
	"__AutoFenceUpgradeStop",
	"__ThrowRoutineStop",
}
for _, name in ipairs(oldStops) do
	if env[name] then
		pcall(env[name])
	end
end

local loaded, WindUI = pcall(function()
	return loadstring(game:HttpGet(WINDUI_URL))()
end)
if not loaded or not WindUI then
	warn("could not load WindUI: " .. tostring(WindUI))
	return
end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local controllers = player.PlayerScripts.Client.Controllers
local DataController = require(controllers.DataController)
local ClientState = require(controllers.ClientState)
local InputActions = require(controllers.InputActions)
local FoodsConfig = require(ReplicatedStorage.Config.FoodsConfig)
local FenceConfig = require(ReplicatedStorage.Config.FenceConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local starterArea = workspace:WaitForChild("StarterArea")
local crossLine = starterArea:WaitForChild("CrossLine")

local settings = {
	autoTap = false,
	tapTarget = 20,
	autoEquip = false,
	autoBuy = false,
	autoFence = false,
	routineThrows = 3,
}

local running = true
local routineActive = false
local connections = {}
local failedAt = {}
local fenceMaxShown = false

local Window

local function notify(title, content)
	pcall(function()
		WindUI:Notify({
			Title = title,
			Content = content,
			Duration = 4,
		})
	end)
end

local function waitUntil(condition, timeout)
	local startedAt = os.clock()
	while not condition() do
		if not running or os.clock() - startedAt > timeout then
			return false
		end
		task.wait(0.1)
	end
	return true
end

local confirmAction = InputActions.GetAction("Confirm")

local function tap()
	if confirmAction then
		firesignal(confirmAction.Pressed)
		return
	end

	local camera = workspace.CurrentCamera
	local screen = camera and camera.ViewportSize or Vector2.new(800, 600)
	firesignal(UserInputService.InputBegan, {
		UserInputType = Enum.UserInputType.MouseButton1,
		KeyCode = Enum.KeyCode.Unknown,
		Position = Vector3.new(screen.X / 2, screen.Y / 2, 0),
	}, false)
end

local function getMeterParts()
	local gui = playerGui:FindFirstChild("ThrowSequence")
	local meter = gui and gui:FindFirstChild("Meter")
	local bar = meter and meter:FindFirstChild("Bar")
	local marker = bar and bar:FindFirstChild("Marker")
	local numberLabel = marker and marker:FindFirstChild("Text")
	local prompt = meter and meter:FindFirstChild("Prompt")
	return meter, numberLabel, prompt
end

local currentMeter = nil
local meterFirstSeen = 0
local promptAtStart = nil
local lastTapTime = 0

table.insert(connections, RunService.RenderStepped:Connect(function()
	if not (settings.autoTap or routineActive) then
		currentMeter = nil
		return
	end

	local meter, numberLabel, prompt = getMeterParts()
	if not meter or not numberLabel or not numberLabel:IsA("TextLabel") then
		currentMeter = nil
		return
	end

	if meter ~= currentMeter then
		currentMeter = meter
		meterFirstSeen = os.clock()
		promptAtStart = prompt and prompt.Text
		lastTapTime = 0
	end

	if prompt and prompt.Text ~= promptAtStart then
		return
	end

	local number = tonumber(numberLabel.Text:match("%d+"))
	if not number or number < settings.tapTarget then
		return
	end

	local now = os.clock()
	if now - meterFirstSeen < MIN_TAP_AGE or now - lastTapTime < TAP_RETRY then
		return
	end

	lastTapTime = now
	tap()
end))

local function checkEquipBest()
	local ok, result = pcall(Remotes.Invoke, "Plot_EquipBest")
	if ok and type(result) == "table" and result.Ok then
		local changed = (result.Placed or 0) + (result.Removed or 0)
		if changed > 0 then
			notify("Equip Best", "your best " .. (result.Count or 0) .. " animals are on your plot")
		end
	end
end

local function isOwned(food)
	return DataController:GetPath("OwnedFoods." .. food.Index) == true
end

local function tryBuy(slot, food)
	local failedTime = failedAt[slot]
	if failedTime and os.clock() - failedTime < RETRY_FAILED_AFTER then
		return false
	end

	local ok, result = pcall(Remotes.Invoke, "Shop_Buy", slot)
	if ok and type(result) == "table" and result.Ok then
		failedAt[slot] = nil
		notify("Food Shop", "bought " .. food.Name)
		return true
	end

	failedAt[slot] = os.clock()
	return false
end

local function equipFood(slot, food)
	local ok, result = pcall(Remotes.Invoke, "Shop_Equip", slot)
	if ok and type(result) == "table" and result.Ok then
		notify("Food Shop", "equipped " .. food.Name)
	end
end

local function checkBuyFood()
	local money = DataController:Get("Money") or 0
	local equipped = DataController:Get("EquippedFood")

	for slot = FoodsConfig.CountAll(), 1, -1 do
		local food = FoodsConfig.GetAny(slot)

		if food and not FoodsConfig.IsLocked(food.Index) then
			if isOwned(food) then
				if equipped ~= food.Index then
					equipFood(slot, food)
				end
				return
			end

			if food.Price <= money and tryBuy(slot, food) then
				equipFood(slot, food)
				return
			end
		end
	end
end

local function checkFence()
	if ClientState.Busy then
		return
	end

	local level = DataController:Get("FenceLevel") or 0
	if level >= FenceConfig.MaxLevel() then
		if not fenceMaxShown then
			fenceMaxShown = true
			notify("Fence", "your fence is already at the max level")
		end
		return
	end

	local nextUpgrade = FenceConfig.Get(level + 1)
	local money = DataController:Get("Money") or 0
	if not nextUpgrade or money < nextUpgrade.Price then
		return
	end

	local result = Remotes.Invoke("Plot_UpgradeFence")
	if type(result) == "table" and result.Ok then
		notify("Fence", "upgraded to level " .. tostring(result.Level))
	end
end

task.spawn(function()
	while running do
		if settings.autoEquip then
			pcall(checkEquipBest)
		end
		if settings.autoBuy then
			pcall(checkBuyFood)
		end
		if settings.autoFence then
			pcall(checkFence)
		end
		task.wait(CHECK_EVERY)
	end
end)

local function getCharacterParts()
	local character = player.Character
	if not character then
		return nil, nil
	end
	return character:FindFirstChild("HumanoidRootPart"), character:FindFirstChildOfClass("Humanoid")
end

local function throwZoneCFrame(root, humanoid)
	local half = starterArea.Size / 2
	local x = math.clamp(root.Position.X, starterArea.Position.X - half.X + 2, starterArea.Position.X + half.X - 2)
	local y = starterArea.Position.Y + half.Y + humanoid.HipHeight + root.Size.Y / 2 + 0.1
	return CFrame.new(x, y, crossLine.Position.Z - 3)
end

local function runRoutine()
	if routineActive then
		return
	end

	local root = getCharacterParts()
	if not root then
		notify("Throw Routine", "no character found")
		return
	end

	routineActive = true
	local savedCFrame = root.CFrame
	local total = settings.routineThrows
	local done = 0
	local attempts = 0

	notify("Throw Routine", "starting " .. total .. " throws")

	while running and done < total and attempts < total * 3 do
		attempts += 1

		waitUntil(function()
			return ClientState.Busy == nil
		end, 30)

		local currentRoot, humanoid = getCharacterParts()
		if not currentRoot or not humanoid then
			break
		end

		currentRoot.AssemblyLinearVelocity = Vector3.zero
		currentRoot.CFrame = throwZoneCFrame(currentRoot, humanoid)

		local started = waitUntil(function()
			return ClientState.Busy == "Throw"
		end, START_TIMEOUT)

		if started then
			local sawMeter = false
			local finished = waitUntil(function()
				if playerGui:FindFirstChild("ThrowSequence") then
					sawMeter = true
				end
				return ClientState.Busy == nil
			end, THROW_TIMEOUT)

			if finished and sawMeter then
				done += 1
			end
		end

		task.wait(PAUSE_BETWEEN)
	end

	local finalRoot = getCharacterParts()
	if finalRoot then
		finalRoot.AssemblyLinearVelocity = Vector3.zero
		finalRoot.CFrame = savedCFrame
	end

	routineActive = false
	notify("Throw Routine", "finished, " .. done .. " of " .. total .. " throws done")
end

local function stopHub()
	if not running then
		return
	end
	running = false
	for _, connection in ipairs(connections) do
		connection:Disconnect()
	end
	env.__ThrowHubStop = nil
end

Window = WindUI:CreateWindow({
	Title = "Lazy Hub",
	Author = "Throw Food For Animals",
	Icon = "utensils",
	Theme = "Dark",
	ToggleKey = Enum.KeyCode.RightShift,
})

Window:OnDestroy(stopHub)

env.__ThrowHubStop = function()
	stopHub()
	pcall(function()
		Window:Destroy()
	end)
end

local throwTab = Window:Tab({
	Title = "Throw",
	Icon = "target",
})

throwTab:Toggle({
	Title = "Auto Tap",
	Desc = "taps the throw meter for you once the number reaches the target",
	Value = false,
	Callback = function(state)
		settings.autoTap = state
	end,
})

throwTab:Slider({
	Title = "Tap at",
	Desc = "20 is the top of the bar (PERFECT)",
	Step = 1,
	Value = {
		Min = 1,
		Max = 20,
		Default = 20,
	},
	Callback = function(value)
		settings.tapTarget = value
	end,
})

throwTab:Slider({
	Title = "Routine throws",
	Desc = "how many throws the routine does",
	Step = 1,
	Value = {
		Min = 1,
		Max = 10,
		Default = 3,
	},
	Callback = function(value)
		settings.routineThrows = value
	end,
})

local routineToggle
routineToggle = throwTab:Toggle({
	Title = "Throw Routine",
	Desc = "teleports to the throw zone, throws, then teleports you back (auto tap is used while it runs)",
	Value = false,
	Callback = function(state)
		if not state then
			return
		end
		task.spawn(function()
			runRoutine()
			routineToggle:Set(false)
		end)
	end,
})

local autoTab = Window:Tab({
	Title = "Auto",
	Icon = "zap",
})

autoTab:Toggle({
	Title = "Auto Equip Best",
	Desc = "keeps your best animals on your plot",
	Value = false,
	Callback = function(state)
		settings.autoEquip = state
	end,
})

autoTab:Toggle({
	Title = "Auto Buy Best Food",
	Desc = "buys and equips the best food your money allows",
	Value = false,
	Callback = function(state)
		settings.autoBuy = state
	end,
})

autoTab:Toggle({
	Title = "Auto Fence Upgrade",
	Desc = "upgrades the fence as soon as you can afford it, stay near the sign",
	Value = false,
	Callback = function(state)
		settings.autoFence = state
	end,
})

local settingsTab = Window:Tab({
	Title = "Settings",
	Icon = "settings",
})

settingsTab:Paragraph({
	Title = "Toggle key",
	Desc = "press Right Shift to hide or show this window",
})

settingsTab:Button({
	Title = "Unload",
	Desc = "stops everything and closes the window",
	Callback = function()
		env.__ThrowHubStop()
	end,
})

notify("Throw Food Hub", "loaded, turn on what you want")
