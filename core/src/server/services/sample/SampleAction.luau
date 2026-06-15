--!strict
-- core/src/server/services/sample/SampleAction.luau   [SAMPLE — Lune-clean: relative requires only]
-- The sample action DEFINITION: plain data + pure functions => spec-requirable under Lune, no
-- Roblox global. The spec requires THIS directly and drives it through Mocks.net (-> real
-- Net.dispatch). new-game deletes this whole folder. See docs/CORE-DESIGN.md §8.
local Net = require("../../../shared/Net")
local Result = require("../../../shared/Result")

local SampleAction: Net.Action<{ amount: number }, { balance: number }> = {
	name = Net.Actions.Sample, -- "sample.ping"
	rate = { maxPerWindow = 5, windowSeconds = 1 },
	validate = function(raw): Result.Result<{ amount: number }>
		if typeof(raw) ~= "table" then
			return Result.err(Result.Codes.BadPayload)
		end
		local amount = (raw :: any).amount
		if type(amount) ~= "number" then
			return Result.err(Result.Codes.BadType)
		end
		if amount < 1 or amount > 100 or amount % 1 ~= 0 then
			return Result.err(Result.Codes.OutOfRange)
		end
		return Result.ok({ amount = amount })
	end,
	handler = function(ctx, payload): Result.Result<{ balance: number }>
		-- SYNCHRONOUS transform under the lock (§3.3 rule); no client-controllable yield inside.
		local updated = ctx.data:update(ctx.player, function(d)
			d.currencies.Stardust = (d.currencies.Stardust or 0) + payload.amount
			return d
		end)
		if not updated.ok then
			return updated
		end
		return Result.ok({ balance = updated.value.currencies.Stardust })
	end,
}

return SampleAction
