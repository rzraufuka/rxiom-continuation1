--!strict
-- Ustawienia interfejsu i handlu wybrane przez gracza (tylko po stronie klienta).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Signal = require(ReplicatedStorage.Shared.Signal)

export type State = {
	Timeframe: string,
	Sort: "Top" | "Trending" | "Gainers" | "New",
	Search: string,
	QuickBuy: number,
	Slippage: number,
	PriorityFee: number,
	Tip: number,
	Mev: boolean,
	BuyPresets: { number },
	SellPresets: { number },
}

local Settings = {}
Settings.State = {
	Timeframe = "24h",
	Sort = "Top",
	Search = "",
	QuickBuy = 0.1,
	Slippage = 20,
	PriorityFee = 0.001,
	Tip = 0.01,
	Mev = true,
	BuyPresets = table.clone(Config.DefaultBuyPresets),
	SellPresets = table.clone(Config.DefaultSellPresets),
} :: State
Settings.Changed = Signal.new() -- (key)

function Settings.set(key: string, value: any)
	(Settings.State :: any)[key] = value
	Settings.Changed:Fire(key)
end

-- Przechodzi do następnej wartości z listy (np. slippage 5 -> 10 -> 20 -> 50 -> 5).
function Settings.cycle(key: string, options: { number })
	local current = (Settings.State :: any)[key]
	local index = 0
	for i, option in options do
		if math.abs(option - current) < 1e-9 then
			index = i
		end
	end
	Settings.set(key, options[index % #options + 1])
end

return Settings
