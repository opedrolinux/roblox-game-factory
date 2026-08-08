--!strict
-- src/shared/Layout.luau
-- THE world's geometry, in one place. Pure numbers: no engine globals, no requires — a Lune-clean
-- LEAF, callable from a spec with no harness at all.
--
-- WHY THIS IS SHARED, and not two private constants:
-- PlotService places the domes; DepthService lays the trench floor UNDERNEATH them. Those are two
-- services with two files and two test suites, and each one asserted only its own constant — so the
-- moment their assumptions diverged, nothing could see it.
--
-- MEASURED 2026-08-08 (T2.7 follow-up, `.verify_tmp/layout.js`):
--   DepthService hardcoded a 640-stud floor span, with a comment claiming it covered "PlotService's
--   whole dome ring (radius ~183 studs for a 12-dome server plus a 64-stud pad)". That was true for
--   DEFAULT_PLOT_COUNT and false for every server that ever runs: the count is Players.MaxPlayers,
--   so a 60-seat server rang the domes at radius 917 and left all 60 of them 597 studs PAST the
--   floor's edge, floating over open void. At the 200 ceiling the radius was 3056 against the same
--   640-stud slab.
--   The single ring was the root cause, not the slab: radius grew as n·96/2π without bound, which
--   also meant a joining player spawned ~917 studs from their own dome (the T2.7 finding) and no
--   single Part could ever cover the ring — Roblox caps a Part at 2048 studs per axis.
--
-- THE FIX IS THE LAYOUT, not a bigger slab. Domes fill CONCENTRIC rings: each ring takes as many
-- domes as fit at RING_SPACING_STUDS of arc, then the next ring starts RING_STEP_STUDS further out.
-- Radius now grows as O(sqrt(n)) instead of O(n), which bounds the world:
--
--   count |  1  |  4  |  12 |  50 |  60 | 128 |  200
--   rings |  1  |  1  |   2 |   3 |   4 |   6 |    7
--   outer | 160 | 160 | 272 | 384 | 496 | 720 |  832   (studs; was 3056 at 200)
--   span  | 576 | 576 | 800 |1024 |1248 |1696 | 1920   (<= 2048, so one Part still covers it)
--   minSep| n/a | 226 |  99 |  99 |  96 |  96 |   96   (studs between pad centres)
--
-- The 64-stud non-overlap invariant that plot.spec asserts holds with 32 studs to spare at the
-- ceiling, because within a ring the arc spacing is RING_SPACING_STUDS by construction and between
-- rings the radial spacing is RING_STEP_STUDS, and both exceed the 64-stud pad.

local Layout = {}

-- ── registry size ───────────────────────────────────────────────────────────────────────────────
-- One dome per seat: a registry SMALLER than MaxPlayers refuses a legitimate joiner with
-- Unavailable, which is a capacity bug wearing a correct-looking error code. MAX is Roblox's own
-- per-server ceiling, not a layout convenience — the layout scales to it (see the table above).
Layout.DEFAULT_PLOT_COUNT = 12
Layout.MIN_PLOT_COUNT = 4
Layout.MAX_PLOT_COUNT = 200

-- ── ring geometry ───────────────────────────────────────────────────────────────────────────────
-- Arc distance between two domes on the same ring, and radial distance between rings. Both must
-- exceed PAD_SIZE_STUDS or pads intersect.
Layout.RING_SPACING_STUDS = 96
Layout.RING_STEP_STUDS = 112
Layout.MIN_RING_RADIUS_STUDS = 160

-- ── greybox dimensions ("100% greybox-in-code for v1: domes = Parts + transparency") ────────────
Layout.PAD_SIZE_STUDS = 64
Layout.PAD_THICKNESS_STUDS = 2
Layout.DOME_DIAMETER_STUDS = 56

-- How far the trench floor reaches past the outermost pad edge. Scenery, but load-bearing scenery:
-- it is what a player walking off the far side of their pad lands on instead of falling forever.
Layout.FLOOR_MARGIN_STUDS = 96

-- Roblox refuses a Part larger than this on any axis. `floorSpanFor` is asserted against it by a
-- spec rather than trusted, because exceeding it throws at build time in the engine and nowhere else.
Layout.MAX_PART_STUDS = 2048

-- Where a player STANDS when placed at their dome: on top of the pad, clear of the pad surface and
-- inside the shield. Not the pad's own origin — that is the pad's CENTRE, i.e. half a stud of solid
-- part, and a character pivoted into it is spawned inside geometry.
Layout.STAND_HEIGHT_STUDS = 5

-- The arrival platform at the ring's centre: where a player with no dome yet stands. Small, and
-- deliberately inside MIN_RING_RADIUS_STUDS so it never intersects ring 1.
Layout.ARRIVAL_PAD_SIZE_STUDS = 48
Layout.ARRIVAL_PAD_THICKNESS_STUDS = 2

-- ── the pure math ───────────────────────────────────────────────────────────────────────────────

-- Registry size from Players.MaxPlayers. Any non-number / NaN / <1 reading answers the default
-- rather than propagating garbage into the layout.
function Layout.plotCountFor(maxPlayers: any): number
	if type(maxPlayers) == "number" and maxPlayers == maxPlayers and maxPlayers >= 1 then
		return math.clamp(math.floor(maxPlayers), Layout.MIN_PLOT_COUNT, Layout.MAX_PLOT_COUNT)
	end
	return Layout.DEFAULT_PLOT_COUNT
end

function Layout.ringRadiusFor(ring: number): number
	local r = math.max(1, math.floor(ring))
	return Layout.MIN_RING_RADIUS_STUDS + (r - 1) * Layout.RING_STEP_STUDS
end

-- How many domes fit on ring `r` at RING_SPACING_STUDS of arc. At least 1, so the walk in
-- `slotFor` always advances and can never loop forever on a degenerate radius.
function Layout.ringCapacityFor(ring: number): number
	local circumference = 2 * math.pi * Layout.ringRadiusFor(ring)
	return math.max(1, math.floor(circumference / Layout.RING_SPACING_STUDS))
end

-- Which ring dome `index` lands on, its 1-based position within that ring, and how many domes
-- share that ring for this `count`. Splitting this out is what lets a spec assert the ASSIGNMENT
-- (a ring never over-filled, indices contiguous) separately from the trigonometry.
-- Any non-number / NaN reads as 1 rather than propagating into the trigonometry as a NaN radius.
local function whole(value: any): number
	if type(value) ~= "number" or value ~= value then
		return 1
	end
	return math.floor(value)
end

function Layout.slotFor(index: any, count: any): (number, number, number)
	local n = math.max(1, whole(count))
	local i = math.clamp(whole(index), 1, n)
	local ring = 1
	local before = 0
	while before + Layout.ringCapacityFor(ring) < i do
		before += Layout.ringCapacityFor(ring)
		ring += 1
	end
	-- Divide by how many domes ACTUALLY land on this ring, not its capacity, so a partly-filled
	-- outer ring spreads its domes evenly instead of clustering them in one arc. Spacing only ever
	-- increases relative to capacity-based spacing, so the non-overlap invariant is preserved.
	local onThisRing = math.min(Layout.ringCapacityFor(ring), n - before)
	return ring, i - before, math.max(1, onThisRing)
end

-- The dome's world position. Y IS THE PERSISTED TIER'S Y, passed straight through — a returning
-- player whose blob says tier 4 must find their dome at tier 4, not at Depth 1.
function Layout.positionFor(index: any, count: any, tierY: number): (number, number, number)
	local ring, k, onThisRing = Layout.slotFor(index, count)
	local radius = Layout.ringRadiusFor(ring)
	-- Stagger successive rings by half a slot so domes do not line up radially. Cosmetic on its own,
	-- but it also raises the closest approach between adjacent rings.
	local offset = ((ring - 1) * math.pi) / 6
	local angle = ((k - 1) / onThisRing) * 2 * math.pi + offset
	return radius * math.cos(angle), tierY, radius * math.sin(angle)
end

-- Where to put a CHARACTER so they are standing on this dome's pad.
function Layout.standPositionFor(index: any, count: any, tierY: number): (number, number, number)
	local x, y, z = Layout.positionFor(index, count, tierY)
	return x, y + Layout.PAD_THICKNESS_STUDS / 2 + Layout.STAND_HEIGHT_STUDS, z
end

-- The outermost ring in use for `count` domes.
function Layout.outerRadiusFor(count: any): number
	local n = math.max(1, whole(count))
	local ring = select(1, Layout.slotFor(n, n))
	return Layout.ringRadiusFor(ring)
end

-- The square trench slab that must sit under EVERY dome for `count` plots. Derived, never typed in
-- by hand — that is the whole point of this module. Clamped to Roblox's Part ceiling so this can
-- never be the line that throws at world build; `floorCoversRing` is the honest report of whether
-- the clamp bit, and a spec asserts it is false for every count up to MAX_PLOT_COUNT.
function Layout.floorSpanFor(count: any): number
	local edge = Layout.outerRadiusFor(count) + Layout.PAD_SIZE_STUDS / 2
	return math.min(2 * (edge + Layout.FLOOR_MARGIN_STUDS), Layout.MAX_PART_STUDS)
end

function Layout.floorCoversRing(count: any): boolean
	local needed = 2 * (Layout.outerRadiusFor(count) + Layout.PAD_SIZE_STUDS / 2)
	return needed <= Layout.MAX_PART_STUDS
end

return Layout
