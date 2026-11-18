--!strict
-- Boty-snajperzy na Pulse: kilka sekund po starcie nowego coina kupuje go kilku botów
-- ("sniper_xxxx"), a potem każdy sprzedaje według swojego stylu:
--   Flipper: sprzedaje wszystko przy +30-80% albo po 15-45 s,
--   Swing:   połowę przy +60-150% albo po 40-90 s, resztę po 2-4 min,
--   Holder:  trzyma 3-7 min i sprzedaje wszystko.
-- Działa na czasie rynku (Snipers.step), więc da się go testować bez czekania.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Amm = require(ReplicatedStorage.Shared.Amm)
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Market = require(script.Parent.Market)
local OrderBook = require(script.Parent.OrderBook)

local SNIPERS = Config.Snipers
local BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

type Sale = { At: number, Fraction: number }
type Sniper = {
	Ticker: string,
	Name: string,
	BuyAt: number,
	Size: number,
	Bought: boolean,
	Tokens: number,
	Entry: number,
	-- Sprzedaż przy cenie >= Entry * TakeProfit (ułamek pozostałych tokenów), nil = brak.
	TakeProfit: number?,
	TakeFraction: number,
	Sales: { Sale },
}
type Launch = { Ticker: string, CreatorId: number?, Pending: number, Bought: number, StartedAt: number }

local Snipers = {}

local rng = Random.new()
local snipers: { Sniper } = {}
local launches: { [string]: Launch } = {}

local function between(range: { number }): number
	return rng:NextNumber(range[1], range[2])
end

local function sniperName(): string
	local chars = table.create(4)
	for i = 1, 4 do
		local index = rng:NextInteger(1, #BASE58)
		chars[i] = string.sub(BASE58, index, index)
	end
	return "sniper_" .. table.concat(chars)
end

-- Plan sprzedaży liczony od chwili zakupu.
local function plan(s: Sniper, boughtAt: number)
	local roll = rng:NextNumber()
	if roll < 0.55 then
		s.TakeProfit = rng:NextNumber(1.3, 1.8)
		s.TakeFraction = 1
		s.Sales = { { At = boughtAt + rng:NextNumber(15, 45), Fraction = 1 } }
	elseif roll < 0.85 then
		s.TakeProfit = rng:NextNumber(1.6, 2.5)
		s.TakeFraction = 0.5
		s.Sales = {
			{ At = boughtAt + rng:NextNumber(40, 90), Fraction = 0.5 },
			{ At = boughtAt + rng:NextNumber(120, 240), Fraction = 1 },
		}
	else
		s.TakeProfit = nil
		s.Sales = { { At = boughtAt + rng:NextNumber(180, 420), Fraction = 1 } }
	end
end

local function notifyCreator(launch: Launch)
	local player = if launch.CreatorId then Players:GetPlayerByUserId(launch.CreatorId) else nil
	if player and launch.Bought > 0 then
		local seconds = math.max(1, math.ceil(Market.now() - launch.StartedAt))
		Remotes.Notify:FireClient(player, {
			Kind = "Info",
			Text = `Snipers spotted: {launch.Bought} bots bought {launch.Ticker} in the first {seconds}s. Watch out for the dump!`,
		})
	end
end

-- Nowy coin na Pulse. `rollChance` false wymusza snajperów (testy).
function Snipers.onLaunch(ticker: string, creator: Player?, now: number?, rollChance: boolean?)
	if rollChance ~= false and rng:NextNumber() > SNIPERS.Chance then
		return
	end
	local t = now or Market.now()
	local count = rng:NextInteger(SNIPERS.Min, SNIPERS.Max)
	local launch: Launch = {
		Ticker = ticker,
		CreatorId = if creator then creator.UserId else nil,
		Pending = count,
		Bought = 0,
		StartedAt = t,
	}
	launches[ticker] = launch
	local at = t + between(SNIPERS.FirstDelay)
	for _ = 1, count do
		table.insert(snipers, {
			Ticker = ticker,
			Name = sniperName(),
			BuyAt = at,
			Size = 0,
			Bought = false,
			Tokens = 0,
			Entry = 0,
			TakeFraction = 1,
			Sales = {},
		})
		at += between(SNIPERS.Gap)
	end
end

local function sell(s: Sniper, fraction: number, t: number)
	local tokens = if fraction >= 1 then s.Tokens else s.Tokens * fraction
	if tokens <= 0 then
		return
	end
	local _, sold = OrderBook.sell(s.Ticker, tokens, s.Name, false, t)
	s.Tokens = math.max(0, s.Tokens - sold)
end

-- Wykonuje zaległe zakupy i sprzedaże do chwili `t`.
function Snipers.step(t: number)
	local i = 1
	while i <= #snipers do
		local s = snipers[i]
		local state = Market.get(s.Ticker)
		local launch = launches[s.Ticker]
		local done = false
		if not state then
			-- Coin zdjęty z rynku tego serwera: snajper znika.
			done = true
			if launch and not s.Bought then
				launch.Pending -= 1
			end
		elseif not s.Bought then
			if t >= s.BuyAt then
				s.Size = state.Pool.Rx * between(SNIPERS.Size)
				local got, spent = OrderBook.buy(s.Ticker, s.Size, s.Name, false, t)
				s.Bought = true
				if got > 0 then
					s.Tokens = got
					s.Entry = spent / got
					plan(s, t)
				else
					done = true
				end
				if launch then
					launch.Pending -= 1
					if got > 0 then
						launch.Bought += 1
					end
				end
			end
		else
			local price = Amm.price(state.Pool)
			if s.TakeProfit and price >= s.Entry * s.TakeProfit then
				sell(s, s.TakeFraction, t)
				s.TakeProfit = nil
				if s.TakeFraction >= 1 then
					s.Sales = {}
				end
			end
			while #s.Sales > 0 and t >= s.Sales[1].At do
				local sale = table.remove(s.Sales, 1) :: Sale
				sell(s, sale.Fraction, t)
			end
			done = s.Tokens <= Config.DustTokens or #s.Sales == 0
		end
		if launch and launch.Pending == 0 then
			launches[s.Ticker] = nil
			notifyCreator(launch)
		end
		if done then
			table.remove(snipers, i)
		else
			i += 1
		end
	end
end

-- Aktywni snajperzy (testy i podgląd).
function Snipers.active(ticker: string?): { Sniper }
	local result = {}
	for _, s in snipers do
		if ticker == nil or s.Ticker == ticker then
			table.insert(result, s)
		end
	end
	return result
end

function Snipers.start()
	task.spawn(function()
		while true do
			task.wait(0.25)
			Snipers.step(Market.now())
		end
	end)
end

return Snipers
