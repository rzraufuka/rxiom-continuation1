--!strict
-- Ulepszenia kupowane za RXI (wspólne dla serwera i klienta). Poziom 0 = bez ulepszenia;
-- Values[poziom + 1] to efekt na danym poziomie, Costs[poziom + 1] to cena następnego poziomu.

local Config = require(script.Parent.Config)
local Format = require(script.Parent.Format)

export type Id = "FaucetAmount" | "FaucetSpeed" | "Cashback" | "LaunchDiscount" | "Radar"
export type Levels = { [string]: number }
export type UpgradeDef = {
	Id: Id,
	Name: string,
	Description: string,
	Values: { number },
	Costs: { number },
	Show: (value: number) -> string,
}

local function scaled(base: number, factors: { number }): { number }
	local values = {}
	for i, f in factors do
		values[i] = base * f
	end
	return values
end

local function minutes(seconds: number): string
	if seconds >= 60 then
		local m = seconds / 60
		return (if m == math.floor(m) then tostring(m) else string.format("%.1f", m)) .. " min"
	end
	return math.floor(seconds) .. " s"
end

local LIST: { UpgradeDef } = {
	{
		Id = "FaucetAmount",
		Name = "Bigger Deposit",
		Description = "More free RXI every time you claim Deposit.",
		Values = scaled(Config.Faucet.Amount, { 1, 1.5, 2, 3, 4, 5 }),
		Costs = { 10, 25, 60, 150, 400 },
		Show = function(v: number): string
			return Format.decimal(v) .. " " .. Config.Currency
		end,
	},
	{
		Id = "FaucetSpeed",
		Name = "Faster Deposit",
		Description = "Shorter wait between free Deposit claims.",
		Values = scaled(Config.Faucet.Cooldown, { 1, 0.8, 0.6, 0.4, 0.3, 0.2 }),
		Costs = { 15, 40, 100, 250, 600 },
		Show = minutes,
	},
	{
		Id = "Cashback",
		Name = "Fee Cashback",
		Description = "Get part of every trading fee back right after the trade.",
		Values = { 0, 0.15, 0.3, 0.45, 0.6 },
		Costs = { 20, 60, 150, 400 },
		Show = function(v: number): string
			return math.round(v * 100) .. "%"
		end,
	},
	{
		Id = "LaunchDiscount",
		Name = "Cheaper Launch",
		Description = "Lower cost of creating your own coin on Pulse.",
		Values = scaled(Config.Launch.Fee, { 1, 0.85, 0.7, 0.55, 0.4 }),
		Costs = { 50, 120, 300, 700 },
		Show = function(v: number): string
			return Format.decimal(v) .. " " .. Config.Currency
		end,
	},
	{
		Id = "Radar",
		Name = "Pulse Radar",
		Description = "Get an alert the moment any new coin launches on Pulse, before the snipers.",
		Values = { 0, 1 },
		Costs = { 75 },
		Show = function(v: number): string
			return if v > 0 then "On" else "Off"
		end,
	},
}

local byId: { [string]: UpgradeDef } = {}
for _, def in LIST do
	byId[def.Id] = def
end

local Upgrades = {}
Upgrades.List = LIST

function Upgrades.get(id: any): UpgradeDef?
	return if typeof(id) == "string" then byId[id] else nil
end

function Upgrades.maxLevel(def: UpgradeDef): number
	return #def.Values - 1
end

function Upgrades.level(levels: Levels?, id: Id): number
	local def = byId[id]
	local level = if levels then levels[id] else nil
	if not def or typeof(level) ~= "number" then
		return 0
	end
	return math.clamp(math.floor(level), 0, #def.Values - 1)
end

-- Efekt ulepszenia na obecnym poziomie gracza.
function Upgrades.value(levels: Levels?, id: Id): number
	return byId[id].Values[Upgrades.level(levels, id) + 1]
end

-- Cena następnego poziomu albo nil, gdy ulepszenie jest na maksimum.
function Upgrades.nextCost(levels: Levels?, id: Id): number?
	return byId[id].Costs[Upgrades.level(levels, id) + 1]
end

-- Poziomy z zapisu: tylko znane ulepszenia i poprawne poziomy.
function Upgrades.sanitize(raw: any): Levels
	local levels: Levels = {}
	if typeof(raw) ~= "table" then
		return levels
	end
	for id, level in raw do
		local def = Upgrades.get(id)
		if def and typeof(level) == "number" and level == level and level >= 1 then
			levels[def.Id] = math.min(math.floor(level), #def.Values - 1)
		end
	end
	return levels
end

return Upgrades
