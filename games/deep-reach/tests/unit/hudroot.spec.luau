--!strict
-- games/deep-reach/tests/unit/hudroot.spec.luau   [contract pass — infra, AMENDMENT A10d]
-- The shared HUD root's SLOT LAYOUT, driven under Lune. HudRoot declares its layout as plain numbers
-- precisely so this rung can reach it: UDim2/Vector2/Instance are all nil here.
--
-- WHAT THIS PROVES: that the layout actually SEPARATES panels — distinct names, distinct anchored
-- corners, and no slot covering the whole screen. That is the defect the amendment exists for: nine
-- controllers each newing their own full-screen ScreenGui produces a pile of stacked panels, and a
-- "slot layout" whose slots all sit at 0,0 at full size would reproduce it exactly while looking
-- like a fix. It also proves mount() REFUSES an unknown slot rather than silently parenting a panel
-- to nothing.
--
-- SCOPE HONESTY: no rung below T2.7 can see a pixel. This spec says the layout is well-formed; it
-- says nothing about how the HUD looks.
local testkit = require("../lib/testkit")
local HudRoot = require("../../src/client/framework/HudRoot")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

describe("client/framework/HudRoot — the slot vocabulary", function()
	it("declares slots, and slotNames matches SLOTS exactly", function()
		expect(#HudRoot.SLOTS > 0):toBe(true)
		expect(#HudRoot.slotNames()):toBe(#HudRoot.SLOTS)
		for _, slot in HudRoot.SLOTS do
			expect(HudRoot.isSlot(slot.name)):toBe(true)
			expect(HudRoot.slot(slot.name)):toBe(slot)
		end
	end)

	it("has one ScreenGui name, and every slot name is unique and non-empty", function()
		expect(type(HudRoot.SCREEN_GUI_NAME)):toBe("string")
		expect(HudRoot.SCREEN_GUI_NAME ~= ""):toBe(true)

		local seen: { [string]: boolean } = {}
		for _, slot in HudRoot.SLOTS do
			expect(type(slot.name)):toBe("string")
			expect(slot.name ~= ""):toBe(true)
			expect(seen[slot.name]):toBe(nil) -- a duplicate name means two panels share a region
			seen[slot.name] = true
			expect(slot.purpose ~= ""):toBe(true) -- an unexplained slot gets misused
		end
	end)

	it("no slot covers the whole screen", function()
		-- A full-screen slot IS the overlap problem wearing a slot's name.
		for _, slot in HudRoot.SLOTS do
			expect(slot.sizeXScale > 0):toBe(true)
			expect(slot.sizeYScale > 0):toBe(true)
			expect(slot.sizeXScale < 1 or slot.sizeYScale < 1):toBe(true)
		end
	end)

	it("no two slots share the same anchored position — the panels are separated", function()
		local seen: { [string]: string } = {}
		for _, slot in HudRoot.SLOTS do
			-- The anchor point plus the scaled position is what fixes a panel on screen; two slots
			-- agreeing on both would render exactly on top of each other.
			local key = `{slot.anchorX},{slot.anchorY}@{slot.posXScale},{slot.posYScale}`
			expect(seen[key]):toBe(nil)
			seen[key] = slot.name
		end
	end)

	it("every slot is anchored consistently with the corner it names", function()
		-- Position scale and anchor point must agree, or the panel hangs off the screen edge.
		for _, slot in HudRoot.SLOTS do
			expect(slot.anchorX):toBe(slot.posXScale)
			expect(slot.anchorY):toBe(slot.posYScale)
			expect(slot.anchorX >= 0 and slot.anchorX <= 1):toBe(true)
			expect(slot.anchorY >= 0 and slot.anchorY <= 1):toBe(true)
		end
	end)
end)

describe("client/framework/HudRoot — mount", function()
	it("refuses an unknown slot BEFORE touching the runtime", function()
		-- Validated first, so a typo'd slot is a loud error at the call site rather than a panel
		-- parented to nothing and never seen again. Under Lune this must be the slot error, not the
		-- "requires the Roblox runtime" error — proving the order.
		local ok, err = pcall(function()
			HudRoot.mount({}, "TopLeftt", nil)
		end)
		expect(ok):toBe(false)
		expect(string.find(tostring(err), "unknown slot", 1, true) ~= nil):toBe(true)
	end)

	it("rejects a non-string slot name", function()
		expect(HudRoot.isSlot(nil)):toBe(false)
		expect(HudRoot.isSlot(7)):toBe(false)
		expect(HudRoot.isSlot({})):toBe(false)
	end)

	it("a KNOWN slot gets past validation and fails only for want of a runtime", function()
		-- The complement of the case above: proves the unknown-slot rejection is a real check and
		-- not just the Roblox-runtime guard firing for every input.
		local ok, err = pcall(function()
			HudRoot.mount({}, HudRoot.SLOTS[1].name, nil)
		end)
		expect(ok):toBe(false)
		expect(string.find(tostring(err), "Roblox runtime", 1, true) ~= nil):toBe(true)
	end)
end)
