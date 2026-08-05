--!strict
-- core/src/server/data/Clock.luau
-- The injectable server clock. Server time, never client time, and injectable for tests.
-- Lune-clean: uses only os.time/os.clock (both exist under Lune) and no Roblox global.
-- See docs/CORE-DESIGN.md §5.

export type Clock = {
	-- Unix seconds (server wall clock) — for timestamps, streaks, offline accrual.
	-- ONLY this value may be persisted in PlayerData (§5 mono-vs-unix rule).
	unix: (self: Clock) -> number,
	-- Monotonic seconds — for rate windows / throttle intervals (immune to wall-clock jumps).
	-- PROCESS-LOCAL and EPHEMERAL — must NEVER be persisted or compared across sessions/servers.
	mono: (self: Clock) -> number,
}

export type FakeClock = Clock & {
	advance: (self: any, seconds: number) -> (),
}

local Clock = {}

-- Real clock: unix = os.time() (server wall clock). SERVER ONLY.
--
-- mono() needs a MONOTONIC, high-resolution, wall-rate source for rate windows / write
-- throttling. On Roblox, `os.clock()` is CPU-time-of-the-Lua-VM (it advances only while Lua
-- code is executing), NOT monotonic wall time — using it would make rate/throttle windows
-- never elapse (or elapse erratically) at runtime. So `monoSource` is INJECTED: the Roblox
-- bootstrap (Context.build) passes the `time` global (seconds since the server started, a
-- monotonic high-resolution wall clock); Lune/tests fall back to `os.clock`, which under
-- standalone Lune DOES advance with wall time (verified — Clock.luau stays Lune-clean and
-- references no Roblox global itself). This removes the os.clock() CPU-time runtime risk while
-- keeping the module engine-agnostic.
function Clock.real(monoSource: (() -> number)?): Clock
	-- Lune-safe default: under Lune, os.clock advances with wall time. Production overrides this
	-- with the monotonic Roblox `time` global (injected from the Roblox-only Context.build).
	local mono: () -> number = monoSource or os.clock
	local self = {}
	function self.unix(_: Clock): number
		return os.time()
	end
	function self.mono(_: Clock): number
		return mono()
	end
	return self
end

-- Fake clock for tests: starts at `startUnix`; advance(seconds) moves BOTH unix and mono.
function Clock.fake(startUnix: number): FakeClock
	local nowUnix = startUnix
	local nowMono = 0

	local self = {}
	function self.unix(_: any): number
		return nowUnix
	end
	function self.mono(_: any): number
		return nowMono
	end
	function self.advance(_: any, seconds: number): ()
		nowUnix += seconds
		nowMono += seconds
	end
	return self
end

return Clock
