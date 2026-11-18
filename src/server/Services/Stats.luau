--!strict
-- Statystyki handlu gracza do Wallet Trackera: wolumen, liczba transakcji, zrealizowany PnL
-- (metodą średniego kosztu) i wolumen na token (ulubione tokeny).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)

type TradeStats = Types.TradeStats

-- Limity rozmiaru zapisu: tyle tokenów w wolumenie na token i w bazie kosztowej.
local MAX_TOKENS = 30
local MAX_BASIS = 60

local Stats = {}

local function finite(v: any): boolean
	return typeof(v) == "number" and v == v and math.abs(v) ~= math.huge
end

function Stats.empty(): TradeStats
	return { Volume = 0, Trades = 0, Realized = 0, TokenVolume = {}, Basis = {} }
end

-- Zostawia `limit` tokenów o największym wolumenie.
local function trim(map: { [string]: number }, limit: number)
	local list = {}
	for ticker, volume in map do
		table.insert(list, { Ticker = ticker, Volume = volume })
	end
	if #list <= limit then
		return
	end
	table.sort(list, function(a, b)
		return a.Volume > b.Volume
	end)
	for i = limit + 1, #list do
		map[list[i].Ticker] = nil
	end
end

-- Transakcja perpetuals: wolumen to wartość pozycji w RXI, `realized` od razu trafia do PnL
-- (prowizja przy otwarciu, wynik przy zamknięciu, utracony margin przy likwidacji).
function Stats.recordPerp(stats: TradeStats, volume: number, realized: number)
	if volume > 0 then
		stats.Volume += volume
		stats.Trades += 1
	end
	stats.Realized += realized
end

-- Zapisuje wykonaną transakcję gracza. `rx`: przy kupnie zapłacone RX (z prowizją), przy sprzedaży
-- otrzymane RX (po prowizji).
function Stats.record(stats: TradeStats, ticker: string, side: Types.Side, tokens: number, rx: number)
	if tokens <= 0 then
		return
	end
	local volume = math.max(0, rx)
	stats.Volume += volume
	stats.Trades += 1
	stats.TokenVolume[ticker] = (stats.TokenVolume[ticker] or 0) + volume
	trim(stats.TokenVolume, MAX_TOKENS)

	local basis = stats.Basis[ticker]
	if side == "Buy" then
		if not basis then
			basis = { Tokens = 0, Cost = 0 }
			stats.Basis[ticker] = basis
		end
		basis.Tokens += tokens
		basis.Cost += volume
		return
	end
	-- Tokeny ponad bazę (np. sprzed Wallet Trackera) mają zerowy koszt.
	local cost = 0
	if basis and basis.Tokens > 0 then
		local portion = math.min(tokens, basis.Tokens)
		cost = basis.Cost * portion / basis.Tokens
		basis.Tokens -= portion
		basis.Cost = math.max(0, basis.Cost - cost)
		if basis.Tokens <= Config.DustTokens then
			stats.Basis[ticker] = nil
		end
	end
	stats.Realized += rx - cost
end

-- Najczęściej handlowane tokeny (po wolumenie), od największego.
function Stats.favorites(stats: TradeStats, count: number): { Types.FavoriteToken }
	local list: { Types.FavoriteToken } = {}
	for ticker, volume in stats.TokenVolume do
		if volume > 0 then
			local def = Coins.get(ticker)
			table.insert(list, { Ticker = ticker, Name = if def then def.Name else nil, Volume = volume })
		end
	end
	table.sort(list, function(a, b)
		return a.Volume > b.Volume
	end)
	for i = #list, count + 1, -1 do
		list[i] = nil
	end
	return list
end

-- Wczytuje statystyki z zapisu. Pozycje sprzed Wallet Trackera nie mają bazy kosztowej, więc
-- dostają ją ze średniej ceny wejścia.
function Stats.sanitize(raw: any, positions: { [string]: Types.Position }, orders: { Types.BookOrder }): TradeStats
	local stats = Stats.empty()
	if typeof(raw) == "table" then
		stats.Volume = if finite(raw.Volume) then math.max(0, raw.Volume) else 0
		stats.Trades = if finite(raw.Trades) then math.max(0, math.floor(raw.Trades)) else 0
		stats.Realized = if finite(raw.Realized) then raw.Realized else 0
		if typeof(raw.TokenVolume) == "table" then
			for saved, volume in raw.TokenVolume do
				local ticker = if typeof(saved) == "string" then Coins.rename(saved) else saved
				if Coins.validTicker(ticker) and finite(volume) and volume > 0 then
					stats.TokenVolume[ticker] = (stats.TokenVolume[ticker] or 0) + volume
				end
			end
		end
		if typeof(raw.Basis) == "table" then
			for saved, b in raw.Basis do
				local ticker = if typeof(saved) == "string" then Coins.rename(saved) else saved
				if
					Coins.validTicker(ticker)
					and typeof(b) == "table"
					and finite(b.Tokens)
					and finite(b.Cost)
					and b.Tokens > Config.DustTokens
				then
					local prev = stats.Basis[ticker]
					stats.Basis[ticker] = {
						Tokens = b.Tokens + (if prev then prev.Tokens else 0),
						Cost = math.max(0, b.Cost) + (if prev then prev.Cost else 0),
					}
				end
			end
		end
	end

	local locked: { [string]: number } = {}
	for _, order in orders do
		if order.Side == "Sell" then
			locked[order.Ticker] = (locked[order.Ticker] or 0) + order.Tokens
		end
	end
	for ticker, p in positions do
		if not stats.Basis[ticker] then
			local tokens = p.Tokens + (locked[ticker] or 0)
			if tokens > Config.DustTokens then
				local average = if p.BuyTokens > 0 then p.BuyValue / p.BuyTokens else 0
				stats.Basis[ticker] = { Tokens = tokens, Cost = tokens * average }
			end
		end
	end

	trim(stats.TokenVolume, MAX_TOKENS)
	local sizes: { [string]: number } = {}
	for ticker, b in stats.Basis do
		sizes[ticker] = b.Cost + b.Tokens * 1e-12
	end
	trim(sizes, MAX_BASIS)
	for ticker in stats.Basis do
		if not sizes[ticker] then
			stats.Basis[ticker] = nil
		end
	end
	return stats
end

return table.freeze(Stats)
