--!strict
-- Boty symulujące innych traderów, żeby rynek żył także przy kilku graczach na serwerze.
-- Każdy coin ma "sentyment" (losowy spacer z wygaszaniem) i słabe przyciąganie do ceny startowej,
-- dzięki czemu ceny pompują i zrzucają, ale nie uciekają w nieskończoność.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Amm = require(ReplicatedStorage.Shared.Amm)
local Config = require(ReplicatedStorage.Shared.Config)
local Market = require(script.Parent.Market)
local OrderBook = require(script.Parent.OrderBook)

local BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

local Bots = {}

local rng = Random.new()
local sentiment: { [string]: number } = {}
-- Coiny z Pulse: logarytm "hype'u", czyli ceny, do której ciągną boty (względem ceny startowej).
-- Błądzi losowo z rzadkimi skokami, więc część coinów pompuje aż do migracji, a część umiera.
local hype: { [string]: number } = {}

local function walletName(): string
	local function part(n: number): string
		local chars = table.create(n)
		for i = 1, n do
			local index = rng:NextInteger(1, #BASE58)
			chars[i] = string.sub(BASE58, index, index)
		end
		return table.concat(chars)
	end
	return part(4) .. "..." .. part(4)
end

local function anchor(ticker: string, state: Market.CoinState): number
	if state.Def.Creator then
		return state.InitialPrice * math.exp(hype[ticker] or 0)
	end
	return state.InitialPrice
end

-- Coiny z Pulse mają małą pulę i ruszają się gwałtowniej: mocniej ciągną za hype'em i boty
-- kupują w nich większe kwoty, jak na pump.fun.
local LAUNCH_PULL = 0.3
local LAUNCH_PULL_MAX = 0.45
local LAUNCH_SIZE = 1.3

local function trade(ticker: string, state: Market.CoinState, s: number, t: number)
	local pool = state.Pool
	local launched = state.Def.Creator ~= nil
	local pull = if launched then LAUNCH_PULL else 0.2
	local pullMax = if launched then LAUNCH_PULL_MAX else 0.35
	local reversion = math.clamp(pull * math.log(anchor(ticker, state) / Amm.price(pool)), -pullMax, pullMax)
	local buyChance = math.clamp(0.5 + s + reversion, 0.08, 0.92)
	-- Rozkład z długim ogonem: zwykle małe transakcje, czasem wieloryb. Duże coiny ruszają się spokojniej.
	local calm = math.clamp(1 - math.log10(state.Def.MarketCap / 1e4) * 0.22, 0.25, 1)
	local size = pool.Rx * (0.0006 + rng:NextNumber() ^ 3 * 0.015) * calm * (if launched then LAUNCH_SIZE else 1)

	if rng:NextNumber() < buyChance then
		OrderBook.buy(ticker, size, walletName(), false, t)
	else
		local tokens = pool.Tokens * size / (pool.Rx - size)
		OrderBook.sell(ticker, tokens, walletName(), false, t)
	end
end

local function stepCoin(ticker: string, state: Market.CoinState, dt: number, t: number)
	local s = sentiment[ticker] or 0
	s = s * math.max(0, 1 - 0.06 * dt) + rng:NextNumber(-1, 1) * 0.12 * math.sqrt(dt)
	-- Rzadkie gwałtowne zwroty: pompa albo dump.
	if rng:NextNumber() < dt / 240 then
		s += if rng:NextNumber() < 0.55 then 0.35 else -0.35
	end
	s = math.clamp(s, -0.45, 0.45)
	sentiment[ticker] = s

	if state.Def.Creator then
		-- Start od bieżącej ceny, żeby coin wczytany z zapisu nie dostał nagłego szarpnięcia.
		local h = hype[ticker] or math.log(Amm.price(state.Pool) / state.InitialPrice)
		h += rng:NextNumber(-1, 1) * 0.09 * math.sqrt(dt)
		if rng:NextNumber() < dt / 150 then
			h += if rng:NextNumber() < 0.5 then 0.7 else -0.6
		end
		hype[ticker] = math.clamp(h, -1.6, 3.2)
	end

	-- Oczekiwana liczba transakcji w kroku; przy dłuższym kroku (rozgrzewka) bywa ich kilka.
	local expected = state.Def.Activity * dt
	local count = math.floor(expected) + (if rng:NextNumber() < expected % 1 then 1 else 0)
	for _ = 1, count do
		trade(ticker, state, s, t)
	end
end

-- `onlyListed`: pomija coiny z Pulse (rozgrzewka nie dopisuje im historii do zapisanej puli).
function Bots.step(dt: number, t: number, onlyListed: boolean?)
	for ticker, state in Market.all() do
		if t >= state.LaunchedAt and not (onlyListed and state.Def.Creator) then
			stepCoin(ticker, state, dt, t)
		end
	end
end

-- Czyści stan botów usuniętego coina.
function Bots.forget(ticker: string)
	sentiment[ticker] = nil
	hype[ticker] = nil
end

-- Symuluje ostatnie Config.WarmupSeconds handlu (lub krócej, jeśli coin jest młodszy), żeby zmiana
-- i wolumen 24h były pełne od startu serwera. Historia starsza niż zakres świec liczona jest
-- grubszym krokiem, bo trafia już tylko do statystyk.
function Bots.warmup()
	local finish = Market.now()
	local detailedFrom = finish - Config.CandleHistory * Config.CandleSeconds
	Market.setBroadcasting(false)
	local t = finish - Config.WarmupSeconds
	while t < finish do
		local detailed = t >= detailedFrom
		local step = if detailed then 0.5 else 2
		Bots.step(step, t, true)
		if detailed then
			Market.tick(t)
		end
		t += step
	end
	Market.setBroadcasting(true)
end

return Bots
