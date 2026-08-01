--!strict
-- games/collect-sim/src/client/controllers/collection/CollectionController.luau   [collection — UI]
-- The client half of the core loop: the mote cloud, the magnet, the absorb, and the refiner.
--
-- THE AUTHORITY SUBTLETY (keep intact): the server's Collect takes an EMPTY payload and decides, from
-- its own clock and the player's own position, how many motes were earned. It deliberately trusts NO
-- client mote identity. So the visible mote and the authoritative collect are DECOUPLED: motes are
-- cosmetic client props; "collecting" is asking the server what you have earned, and then showing
-- exactly that many motes flying in. We must never smuggle a mote id or position into the payload.
--
-- ----- WHAT CHANGED, AND WHY -----
--
-- 1. THE CLIENT HELD ITS OWN TUNING. `ABSORB_RADIUS = 6` and `TICK = 0.06` were module constants
--    sitting beside the persisted magnet and collect-speed levels that were supposed to control
--    them. Both now come from the SERVER — seeded by FetchUpgrades before the first collect and
--    re-read from every Collect reply — so buying magnet visibly widens the pull on the next frame.
--
-- 2. THE TICK IS NO LONGER THE ECONOMY. The server grants floor(elapsed / collectPeriod) motes per
--    request, so the client polls at a fixed, comfortable rate well under the rate bucket and simply
--    animates however many motes the server says were earned. Collect-speed therefore shows up as
--    MORE MOTES PER PULL rather than more requests — which is what the rate bucket would have shed,
--    capping the upgrade at about 1.2x however many levels were bought.
--
-- 3. MOTES WERE BAIT. `randomOffset` scattered up to 26 studs on a platform whose half-width is 24,
--    and 2-5 studs above the torso, so a large fraction of the visible cloud stood over the void or
--    hung in the air. Placement now raycasts onto real island geometry and rejects anything else.
--
-- 4. COLLECTING PRODUCED ONE LINE OF WHITE TEXT. A mote teleported away and a bar moved 2%. Motes
--    now drift toward you inside the magnet radius, get pulled in with a tween, pop a "+N", and
--    click. That drift IS the magnet upgrade, made visible.
--
-- ROBLOX-ONLY (uses the client Net + Instances/workspace + the Hud singleton).
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
local Client = LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Hud = require(Client.hud.Hud)
local Pads = require(Client.world.Pads)
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Result = require(Shared.Result)

-- Cosmetic cloud size + placement. None of these govern the economy; the server does.
local MOTE_POOL = 22
local SPAWN_RADIUS = 22 -- motes live within this radius of the character
local PLACEMENT_TRIES = 8 -- attempts to find real ground before giving up on one mote
local RAY_UP = 14 -- how far above a candidate point the ground ray starts
local RAY_DOWN = 44 -- how far down it looks for an island surface
local MOTE_HOVER = 2.2 -- how far above the found ground a mote floats

-- Client poll period. FIXED and deliberately below the server's 20/s bucket: the server's clock
-- decides the yield, this only decides how often we ask.
local CLIENT_TICK = 0.09
local ABSORB_DISTANCE = 3.2 -- how close a mote must drift before it counts as absorbable
local ABSORB_TIME = 0.16 -- tween duration for a mote flying into the player

-- Engine-BUNDLED sounds (rbxasset://, shipped with the client) — not Creator-Store assets, so no
-- asset audit is needed (CLAUDE.md §11). -- TODO(verify): confirm both paths resolve in a live
-- client; if either is missing the pcall below leaves the game silent rather than erroring.
local COLLECT_SOUND = "rbxasset://sounds/electronicpingshort.wav"
local SELL_SOUND = "rbxasset://sounds/switch3.wav"

-- Per-island mote tint, so island 3's motes read as richer than island 1's rather than every zone
-- looking identical. Indexed by island id, wrapping.
local MOTE_RGB: { { number } } = {
	{ 0.55, 0.78, 1.00 },
	{ 0.42, 1.00, 0.92 },
	{ 0.78, 0.58, 1.00 },
	{ 1.00, 0.52, 0.78 },
	{ 1.00, 0.86, 0.42 },
}

local CollectionController = { name = "CollectionController" }

local function tintFor(islandId: number?): any
	local index = (((islandId or 1) - 1) % #MOTE_RGB) + 1
	local rgb = MOTE_RGB[index]
	return Color3.new(rgb[1], rgb[2], rgb[3])
end

-- A cosmetic mote: a small non-colliding neon ball with a point light. Purely visual — the server
-- never sees it.
local function makeMote(parent: any): any
	local mote: any = Instance.new("Part")
	mote.Name = "Mote"
	mote.Shape = Enum.PartType.Ball
	mote.Size = Vector3.new(1.3, 1.3, 1.3)
	mote.Anchored = true
	mote.CanCollide = false
	mote.CanQuery = false
	mote.CanTouch = false
	mote.Material = Enum.Material.Neon
	mote.Color = tintFor(1)
	local light: any = Instance.new("PointLight")
	light.Name = "Glow"
	light.Range = 12
	light.Brightness = 3
	light.Color = mote.Color
	light.Parent = mote
	mote.Parent = parent
	return mote
end

-- A short-lived "+N" that rises and fades where the motes were taken. This is the smallest possible
-- confirmation that an action did something, and the game had none of it.
local function floatText(position: any, text: string, color: any): ()
	local anchor: any = Instance.new("Part")
	anchor.Name = "Popup"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Position = position
	anchor.Parent = workspace

	local billboard: any = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 130, 0, 40)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 120
	billboard.Parent = anchor

	local label: any = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.4
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = text
	label.Parent = billboard

	local info = TweenInfo.new(0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(anchor, info, { Position = position + Vector3.new(0, 6, 0) }):Play()
	TweenService:Create(label, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	task.delay(0.8, function(): ()
		anchor:Destroy()
	end)
end

function CollectionController:Start(context: any): ()
	local net = context.net

	-- ----- SERVER-OWNED TUNING (seeded before the first collect, refreshed from every reply) -----
	-- These were client constants. They are mirrors of server state now, and nothing here computes
	-- them: a stale mirror shows the wrong pull radius, a fabricated one would be a client-authored
	-- gameplay value.
	local tuning = { magnetRadius = 6, collectPeriod = 0.06, capacity = 50 }
	local backpackFull = false
	local backpackCount = 0
	local backpackValue = 0
	-- nil, not 1: the readout is written on the FIRST reply as well as on every change. Seeded to 1
	-- it matched the starting island, so the "Island N · xM per mote" line never appeared at all
	-- until the player crossed a bridge — which was the one thing they could not do yet.
	local currentIsland: number? = nil

	local function applyTuning(source: any): ()
		if source == nil then
			return
		end
		if type(source.magnetRadius) == "number" and source.magnetRadius > 0 then
			tuning.magnetRadius = source.magnetRadius
		end
		if type(source.collectPeriod) == "number" and source.collectPeriod > 0 then
			tuning.collectPeriod = source.collectPeriod
		end
		if type(source.capacity) == "number" and source.capacity > 0 then
			tuning.capacity = source.capacity
		end
	end

	-- Ask once at boot so the very first pull already uses the player's purchased radius, rather than
	-- the level-0 default until their first successful collect.
	local function refreshTuning(): ()
		local result = net:call(Net.Actions.FetchUpgrades, {})
		if result.ok then
			applyTuning(result.value.tuning)
			Hud.setBackpack(backpackCount, tuning.capacity)
		end
	end
	self.refreshTuning = refreshTuning
	task.spawn(refreshTuning)
	-- A purchase changes the pull radius and the capacity; re-read them when the server pushes.
	net:on("data", function(_view: any): ()
		task.spawn(refreshTuning)
	end)

	-- ----- REFINER PADS (one per island now — ALL of them get wired) -----
	local function refinerLabel(): string
		if backpackCount <= 0 then
			return "Refiner — bring me motes"
		end
		return `Refiner — sell {backpackCount} motes for {math.floor(backpackValue)} Stardust`
	end

	local function pulsePad(pad: any): ()
		if pad == nil then
			return
		end
		local light = pad:FindFirstChild("Glow")
		if light == nil then
			return
		end
		local original = light.Brightness
		light.Brightness = original * 5
		TweenService
			:Create(light, TweenInfo.new(0.45, Enum.EasingStyle.Quad), { Brightness = original })
			:Play()
	end

	local function playSound(parent: any, id: string, pitch: number, volume: number): ()
		pcall(function()
			local sound: any = Instance.new("Sound")
			sound.SoundId = id
			sound.Volume = volume
			sound.PlaybackSpeed = pitch
			sound.Parent = parent
			sound:Play()
			task.delay(3, function(): ()
				sound:Destroy()
			end)
		end)
	end

	Pads.onTrigger("refiner", nil, LocalPlayer, function(pad: any): ()
		local result = net:call(Net.Actions.Sell, {})
		if result.ok then
			backpackFull = false
			local sold = result.value.sold
			local earned = result.value.earned
			backpackCount = 0
			backpackValue = 0
			Hud.setBackpack(0, tuning.capacity)
			Hud.setStardust(result.value.balance)
			Pads.setLabelAll("refiner", refinerLabel())
			if sold > 0 then
				pulsePad(pad)
				-- The pitch rises with the size of the sale, so a big haul SOUNDS like one.
				playSound(pad, SELL_SOUND, 0.85 + math.min(0.6, earned / 4000), 0.6)
				floatText(
					pad.Position + Vector3.new(0, 3, 0),
					`+{earned}`,
					Color3.new(1, 0.86, 0.4)
				)
				Hud.flash(`Sold {sold} motes for {earned} Stardust`)
			else
				Hud.flash("Backpack empty — go collect some motes")
			end
		elseif result.code == Result.Codes.RateLimited then
			Hud.flash("Selling too fast — try again in a moment")
		else
			Hud.flash("Sell failed")
		end
	end)

	-- ----- THE MOTE CLOUD -----
	task.spawn(function(): ()
		local folder: any = workspace:FindFirstChild("ClientMotes")
		if folder == nil then
			folder = Instance.new("Folder")
			folder.Name = "ClientMotes"
			folder.Parent = workspace
		end

		local motes: { any } = {}
		local homes: { [any]: any } = {} -- mote -> its resting position
		local busy: { [any]: boolean } = {} -- mote -> mid-absorb (skip the idle drift)
		for _ = 1, MOTE_POOL do
			local mote = makeMote(folder)
			table.insert(motes, mote)
			homes[mote] = mote.Position
		end

		local function rootOf(): any
			local character = LocalPlayer.Character
			if character == nil then
				return nil
			end
			return character:FindFirstChild("HumanoidRootPart")
		end

		-- Find a resting spot that is ACTUALLY STANDABLE: raycast down onto island geometry only.
		-- The old placement scattered blind, so a large share of every cloud hung over the void or
		-- floated above head height — visible bait the player could never reach.
		local islandFilter: { any } = {}
		local function refreshFilter(): ()
			local world = workspace:FindFirstChild("World")
			if world == nil then
				islandFilter = {}
				return
			end
			local islands = world:FindFirstChild("Islands")
			islandFilter = if islands ~= nil then { islands } else {}
		end
		refreshFilter()

		local function groundedSpot(origin: any): any?
			if #islandFilter == 0 then
				refreshFilter()
			end
			if #islandFilter == 0 then
				return nil
			end
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Include
			params.FilterDescendantsInstances = islandFilter
			for _ = 1, PLACEMENT_TRIES do
				local angle = math.random() * math.pi * 2
				local dist = SPAWN_RADIUS * (0.25 + 0.75 * math.random())
				local candidate = origin
					+ Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
				local hit = workspace:Raycast(
					candidate + Vector3.new(0, RAY_UP, 0),
					Vector3.new(0, -RAY_DOWN, 0),
					params
				)
				if hit ~= nil then
					return hit.Position + Vector3.new(0, MOTE_HOVER, 0)
				end
			end
			return nil
		end

		local function place(mote: any, origin: any): ()
			local spot = groundedSpot(origin)
			if spot == nil then
				-- No island underfoot at all (mid-fall, or the world has not replicated): park the
				-- mote out of sight rather than dropping it into the void where it reads as bait.
				mote.Transparency = 1
				return
			end
			mote.Transparency = 0
			mote.Position = spot
			homes[mote] = spot
			busy[mote] = false
		end

		-- Idle life + magnetism. A mote inside the pull radius drifts toward the player, faster the
		-- closer it gets — that drift is the magnet upgrade made visible, and it is what turns
		-- "walk near a thing" into something that reads as a mechanic.
		local phase = 0
		RunService.Heartbeat:Connect(function(dt: number): ()
			phase += dt
			local root = rootOf()
			if root == nil then
				return
			end
			local origin = root.Position
			for index, mote in motes do
				if busy[mote] or mote.Transparency >= 1 then
					continue
				end
				local home = homes[mote] or mote.Position
				local toPlayer = origin - mote.Position
				local distance = toPlayer.Magnitude
				if distance <= tuning.magnetRadius and not backpackFull then
					local pull =
						math.clamp((tuning.magnetRadius - distance) / tuning.magnetRadius, 0, 1)
					mote.Position = mote.Position + toPlayer.Unit * (6 + 26 * pull) * dt
				else
					-- Gentle bob, offset per mote so the cloud breathes instead of pulsing in unison.
					local bob = math.sin(phase * 2 + index) * 0.35
					mote.Position = home + Vector3.new(0, bob, 0)
				end
				mote.CFrame = CFrame.new(mote.Position) * CFrame.Angles(0, phase * 1.4 + index, 0)
			end
		end)

		-- Fly one mote into the player, then re-place it. The absorb is what makes a collect feel
		-- like an event rather than a teleport.
		local function absorb(mote: any, origin: any): ()
			busy[mote] = true
			local info = TweenInfo.new(ABSORB_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			TweenService:Create(mote, info, {
				Position = origin,
				Size = Vector3.new(0.15, 0.15, 0.15),
				Transparency = 1,
			}):Play()
			task.delay(ABSORB_TIME + 0.02, function(): ()
				mote.Size = Vector3.new(1.3, 1.3, 1.3)
				mote.Transparency = 0
				local root = rootOf()
				place(mote, if root ~= nil then root.Position else origin)
			end)
		end

		local scattered = false
		local pitchStep = 0
		while true do
			task.wait(CLIENT_TICK)
			local root = rootOf()
			if root == nil then
				scattered = false
				continue
			end
			local origin = root.Position
			if not scattered then
				refreshFilter()
				for _, mote in motes do
					place(mote, origin)
				end
				scattered = true
			end

			-- Recycle motes the player has walked away from, AND retry any mote that is currently
			-- parked because no ground was found for it.
			--
			-- That second clause is load-bearing and was missing. The world replicates to the client
			-- a moment after the controller starts, so the first placement pass found no island
			-- geometry and parked all 22 motes invisible. The recycle test only re-placed motes that
			-- had drifted FAR from the player — and a parked mote sits at the origin, right next to
			-- them — so nothing ever re-placed it. Measured in a live session: `22 total, 0 visible,
			-- 22 parked`. The player stood on the starting island with no motes at all, which is to
			-- say: with no game.
			for _, mote in motes do
				local parked = mote.Transparency >= 1
				local strayed = (mote.Position - origin).Magnitude > SPAWN_RADIUS * 1.9
				if not busy[mote] and (parked or strayed) then
					place(mote, origin)
				end
			end

			if backpackFull then
				continue -- wait for a Sell to free room before collecting again
			end

			-- Which motes are close enough to count as absorbable this tick?
			local near: { any } = {}
			for _, mote in motes do
				if not busy[mote] and mote.Transparency < 1 then
					if (mote.Position - origin).Magnitude <= ABSORB_DISTANCE then
						table.insert(near, mote)
					end
				end
			end
			if #near == 0 then
				continue
			end

			local result = net:call(Net.Actions.Collect, {}) -- EMPTY payload — no mote identity sent
			if result.ok then
				local value = result.value
				applyTuning(value)
				backpackFull = value.full
				backpackCount = value.count
				backpackValue = value.value or 0
				if value.islandId ~= nil and value.islandId ~= currentIsland then
					currentIsland = value.islandId
					local tint = tintFor(currentIsland)
					for _, mote in motes do
						mote.Color = tint
						local glow = mote:FindFirstChild("Glow")
						if glow ~= nil then
							glow.Color = tint
						end
					end
					Hud.setIsland(value.islandId, value.islandMultiplier)
				end
				Hud.setBackpack(value.count, value.capacity)

				local granted = value.granted or 0
				if granted > 0 then
					-- Animate exactly as many motes as the SERVER granted, capped by what is in
					-- range. The visible pull and the authoritative grant stay in step, so a player
					-- can never watch motes fly in that they were not paid for.
					local toAbsorb = math.min(granted, #near)
					for index = 1, toAbsorb do
						absorb(near[index], origin)
					end
					pitchStep = (pitchStep + 1) % 6
					playSound(root, COLLECT_SOUND, 1 + pitchStep * 0.06, 0.28)
					floatText(origin + Vector3.new(0, 3.4, 0), `+{granted}`, tintFor(currentIsland))
					Pads.setLabelAll("refiner", refinerLabel())
				end

				if backpackFull then
					Hud.flash("Backpack full — sell at a Refiner")
				end
			elseif result.code == Result.Codes.OutOfRange then
				backpackFull = true
				Hud.flash("Backpack full — sell at a Refiner")
			elseif result.code == Result.Codes.Rejected then
				-- Standing over the void / no character: nothing to collect out here.
				continue
			elseif result.code == Result.Codes.RateLimited then
				task.wait(0.2) -- back-pressure: the bucket shed, slow down
			end
		end
	end)
end

return CollectionController
