--!strict
-- games/deep-reach/tests/unit/layout.spec.luau
-- The world's geometry, asserted with no engine at all — shared/Layout is pure numbers precisely so
-- this rung can reach it.
--
-- WHAT THIS PROVES, and why it exists at all:
-- PlotService placed the domes from one private constant and DepthService sized the trench floor
-- from another, and each service's spec asserted only its own. So when the dome ring's radius grew
-- with MaxPlayers and the floor's did not, NOTHING went red: a 60-seat server put every dome 597
-- studs past the floor's edge, floating over open void, and 945 passing tests had nothing to say
-- about it. The assertion that was missing is `floorCoversRing` below — a statement that spans BOTH
-- services because it is made against the shared derivation they now both read.
--
-- SCOPE HONESTY: this says the numbers are consistent. It cannot see a Part, so "the floor is
-- actually built that big" is T2/T2.7's job, not this file's.
local fs = require("@lune/fs")
local testkit = require("../lib/testkit")
local Layout = require("../../src/shared/Layout")

local describe = testkit.describe
local it = testkit.it
local expect = testkit.expect

-- Every plot count the game can actually stand up: the Lune/unreadable default, the floor, a spread
-- of real server sizes, and Roblox's per-server ceiling.
local COUNTS = { 1, 4, 8, 12, 24, 30, 50, 60, 100, 128, 199, 200 }

describe("layout: the dome ring is bounded, and the floor always reaches it", function()
	it("EVERY plot count's trench floor covers every dome on the ring", function()
		-- THE REGRESSION. Before the concentric-ring layout this was false for every count above
		-- ~21, and no spec in the game could express it because the floor's span and the ring's
		-- radius lived in two different services as two unrelated literals.
		for count = 1, Layout.MAX_PLOT_COUNT do
			local outerEdge = Layout.outerRadiusFor(count) + Layout.PAD_SIZE_STUDS / 2
			local half = Layout.floorSpanFor(count) / 2
			if half < outerEdge then
				error(
					`count={count}: floor half-span {half} does not reach the outermost pad edge {outerEdge}`
				)
			end
			expect(Layout.floorCoversRing(count)):toBe(true)
		end
	end)

	it("the tier rim rings the domes from OUTSIDE, never through them", function()
		-- Found live, not by reading code: the humanoid reported `FloorMaterial = Neon` while
		-- standing on a Plastic pad, because the rim — sized `span * 0.62`, a ratio tuned when the
		-- floor was a fixed 640 and the ring sat far outside it — had moved in to radius 387 and was
		-- intersecting rings 1, 2 and 3. A boundary marker must not pass through what it bounds.
		for count = 1, Layout.MAX_PLOT_COUNT do
			local rim = Layout.rimDiameterFor(count) / 2
			local outerPadEdge = Layout.outerRadiusFor(count) + Layout.PAD_SIZE_STUDS / 2
			if rim <= outerPadEdge then
				error(
					`count={count}: rim radius {rim} is inside the outermost pad edge {outerPadEdge}`
				)
			end
			-- ...and inside the floor it is drawn on, or it hangs over open water.
			expect(rim <= Layout.floorSpanFor(count) / 2):toBe(true)
			expect(Layout.rimDiameterFor(count) <= Layout.MAX_PART_STUDS):toBe(true)
		end
	end)

	it("the floor never exceeds Roblox's per-axis Part ceiling", function()
		-- A slab wider than 2048 studs THROWS at world build, in the engine and nowhere else — so a
		-- layout that "covers the ring" by asking for an impossible Part is not a fix.
		for count = 1, Layout.MAX_PLOT_COUNT do
			expect(Layout.floorSpanFor(count) <= Layout.MAX_PART_STUDS):toBe(true)
		end
	end)

	it("radius grows as O(sqrt n), so the ceiling stays a walkable world", function()
		-- The single-ring formula put 200 domes at radius n*96/2pi = 3056 studs. Concentric rings put
		-- them at 832. The bound is what makes both the floor and the walk tractable.
		expect(Layout.outerRadiusFor(Layout.MAX_PLOT_COUNT) <= 900):toBe(true)
		expect(Layout.outerRadiusFor(60) <= 520):toBe(true)
		-- ...and it is still monotonic: more domes never pulls the ring inward.
		local previous = 0
		for count = 1, Layout.MAX_PLOT_COUNT do
			local radius = Layout.outerRadiusFor(count)
			expect(radius >= previous):toBe(true)
			previous = radius
		end
	end)
end)

describe("layout: ring assignment", function()
	it("fills each ring to capacity before starting the next, with no gaps", function()
		for _, count in COUNTS do
			local seen: { [string]: boolean } = {}
			local perRing: { [number]: number } = {}
			for index = 1, count do
				local ring, k, onThisRing = Layout.slotFor(index, count)
				expect(ring >= 1):toBe(true)
				expect(k >= 1 and k <= onThisRing):toBe(true)
				expect(onThisRing <= Layout.ringCapacityFor(ring)):toBe(true)
				local key = `{ring}:{k}`
				-- Two domes in one slot is the failure this catches: it would place them at the
				-- identical point, which the separation test below would also see but this names.
				expect(seen[key]):toBe(nil)
				seen[key] = true
				perRing[ring] = (perRing[ring] or 0) + 1
			end
			-- Rings are used in order — a gap would mean an inner ring left partly empty while an
			-- outer one was populated, i.e. a bigger world than needed.
			for ring = 1, 40 do
				if perRing[ring] == nil then
					for outer = ring + 1, 40 do
						expect(perRing[outer]):toBe(nil)
					end
					break
				end
				if perRing[ring + 1] ~= nil then
					expect(perRing[ring]):toBe(Layout.ringCapacityFor(ring))
				end
			end
		end
	end)

	it("never puts two pads closer than a pad is wide, at any count", function()
		-- The same invariant plot.spec asserts through PlotService, asserted here at the source of
		-- the math so a layout change goes red in the file that changed.
		for _, count in COUNTS do
			local points: { { x: number, z: number } } = {}
			for index = 1, count do
				local x, _, z = Layout.positionFor(index, count, 0)
				table.insert(points, { x = x, z = z })
			end
			for i = 1, #points do
				for j = i + 1, #points do
					local dx = points[i].x - points[j].x
					local dz = points[i].z - points[j].z
					local d = math.sqrt(dx * dx + dz * dz)
					if d < Layout.PAD_SIZE_STUDS then
						error(
							`count={count}: domes {i} and {j} are {d} studs apart (pads intersect)`
						)
					end
				end
			end
		end
	end)
end)

describe("layout: placement", function()
	it("passes the tier Y through untouched", function()
		for _, tierY in { 0, -450.5, -1200, 88 } do
			local _, y = Layout.positionFor(1, 8, tierY)
			expect(y):toBe(tierY)
		end
	end)

	it("a standing player is ON the pad, not inside it", function()
		-- positionFor answers where the MODEL pivots — the pad's centre, i.e. half a stud of solid
		-- part. A character pivoted there is spawned inside geometry.
		for _, count in COUNTS do
			local _, padY = Layout.positionFor(1, count, -300)
			local x, standY, z = Layout.standPositionFor(1, count, -300)
			expect(standY > padY + Layout.PAD_THICKNESS_STUDS / 2):toBe(true)
			-- ...and directly above it, not offset into open water.
			local px, _, pz = Layout.positionFor(1, count, -300)
			expect(math.abs(x - px) < 1e-9):toBe(true)
			expect(math.abs(z - pz) < 1e-9):toBe(true)
		end
	end)

	it("the arrival platform never intersects ring 1", function()
		-- WorldService puts the game's one SpawnLocation at the origin. If it reached ring 1 a
		-- player would spawn inside a dome pad.
		local reach = Layout.ARRIVAL_PAD_SIZE_STUDS / 2
		expect(reach + Layout.PAD_SIZE_STUDS / 2 < Layout.MIN_RING_RADIUS_STUDS):toBe(true)
	end)

	it("garbage in never becomes NaN out", function()
		for _, bogus in { 0 / 0, -5, 0, "12" :: any, nil :: any, {} :: any } do
			local x, y, z = Layout.positionFor(bogus, bogus, 0)
			expect(x == x and y == y and z == z):toBe(true)
			expect(Layout.floorSpanFor(bogus) > 0):toBe(true)
		end
	end)
end)

describe("layout: registry size", function()
	it("one dome per seat, clamped to Roblox's own ceiling", function()
		for _, seats in { 4, 12, 30, 60, 100, 200 } do
			expect(Layout.plotCountFor(seats)):toBe(seats)
		end
		expect(Layout.plotCountFor(100000)):toBe(Layout.MAX_PLOT_COUNT)
		expect(Layout.plotCountFor(1)):toBe(Layout.MIN_PLOT_COUNT)
		for _, bogus in { nil :: any, "12" :: any, 0 / 0, {} :: any } do
			expect(Layout.plotCountFor(bogus)):toBe(Layout.DEFAULT_PLOT_COUNT)
		end
	end)
end)

-- ── the cross-service assertion ──────────────────────────────────────────────────────────────────
-- `buildShell` is Roblox-only (Instance/Vector3 are nil here), so the binding between DepthService's
-- floor and the shared ring math is asserted against the SOURCE — the hudroot.spec / offline.spec
-- idiom. Absence is a hard error, never a skip: a rename that silently drops the assertion is the
-- failure mode of every source-level test.
local DEPTH_CANDIDATES = {
	"src/server/services/depth/DepthService.luau",
	"games/deep-reach/src/server/services/depth/DepthService.luau",
	"../src/server/services/depth/DepthService.luau",
}

local function readDepthService(): string
	for _, path in DEPTH_CANDIDATES do
		if fs.isFile(path) then
			return fs.readFile(path)
		end
	end
	error(
		`layout.spec: DepthService not found from this cwd: {table.concat(DEPTH_CANDIDATES, ", ")}`
	)
end

describe("layout: the tier rim is a RING, not a disc over the whole trench", function()
	it("its segments close the circle without gaps", function()
		for _, count in COUNTS do
			local radius = Layout.rimDiameterFor(count) / 2
			local chord = 2 * radius * math.sin(math.pi / Layout.RIM_SEGMENTS) * 1.02
			-- Total segment length must cover the circumference, or the ring is a dotted line.
			expect(chord * Layout.RIM_SEGMENTS >= 2 * math.pi * radius):toBe(true)
			-- ...and each segment must be far shorter than the diameter, which is what makes this a
			-- ring at all: one segment spanning the circle IS the disc, wearing a different name.
			expect(chord < radius):toBe(true)
		end
	end)

	it("DepthService builds the rim from segments and not from a cylinder", function()
		-- THE DEFECT THIS NAMES: `Shape = PartType.Cylinder` at rim scale is a SOLID DISC covering
		-- the entire play area — a translucent neon sheet over the whole trench, on every tier. It
		-- was found by hiding six Parts in a live session and re-shooting, and by nothing else.
		local source = readDepthService()
		expect(string.find(source, "Layout.RIM_SEGMENTS", 1, true) ~= nil):toBe(true)
		expect(string.find(source, "RimSegment", 1, true) ~= nil):toBe(true)
		-- The rim must not be a cylinder. Anchored to the assignment, not the bare word, so the
		-- comment explaining the defect does not trip it.
		expect(string.find(source, "rim.Shape = enumGlobal.PartType.Cylinder", 1, true)):toBe(nil)
	end)
end)

describe("layout: DepthService derives its floor, never types one in", function()
	it("the trench slab is sized from shared/Layout and not from a literal", function()
		local source = readDepthService()
		-- It must READ the shared derivation...
		expect(string.find(source, "Layout.floorSpanFor", 1, true) ~= nil):toBe(true)
		-- ...and the hardcoded constant that caused the void must not come back. Anchored to a
		-- line-initial `local`, NOT to the bare token: the file's own comment quotes the old
		-- declaration to explain the defect, and an assertion that cannot tell code from prose
		-- fails on the explanation while a re-introduced constant one indent deep would slip past.
		expect(string.find(source, "\nlocal SHELL_SPAN_STUDS", 1, true)):toBe(nil)
		expect(string.find(source, "slab.Size = vector3Global.new(span,", 1, true) ~= nil):toBe(
			true
		)
	end)
end)
