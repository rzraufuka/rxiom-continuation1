--!strict
-- Stan rynku: pule płynności, historia (świece, statystyki) i ostatnie transakcje każdego coina.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Amm = require(ReplicatedStorage.Shared.Amm)
local Coins = require(ReplicatedStorage.Shared.Coins)
local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)

type Candle = Types.Candle
type TradeEvent = Types.TradeEvent

-- Statystyki zbierane w 10-sekundowych kubełkach (do 24h wstecz).
type Bucket = { T: number, Volume: number, Buys: number, Sells: number, Open: number }

export type CoinState = {
	Def: Coins.CoinDef,
	Pool: Amm.Pool,
	InitialPrice: number,
	LaunchedAt: number,
	Buckets: { Bucket },
	Candles: { Candle },
	Trades: { TradeEvent },
}

local BUCKET_SECONDS = 10
local MAX_BUCKETS = 86400 / BUCKET_SECONDS

local Market = {}

local states: { [string]: CoinState } = {}
local pendingTrades: { TradeEvent } = {}
local holderCounter: (ticker: string) -> number = function(_ticker: string)
	return 0
end
local bookProvider: (ticker: string) -> Types.BookDepth = function(_ticker: string)
	return { Bids = {}, Asks = {} }
end
local launchProvider: (ticker: string) -> Types.LaunchInfo? = function(_ticker: string)
	return nil
end
local recording = true

function Market.now(): number
	return workspace:GetServerTimeNow()
end

function Market.init()
	local t = Market.now()
	for _, def in Coins.List do
		local rx = def.Liquidity / 2 / Config.UsdPerRx
		local price = def.MarketCap / Config.UsdPerRx / Config.TotalSupply
		states[def.Ticker] = {
			Def = def,
			Pool = { Rx = rx, Tokens = rx / price },
			InitialPrice = price,
			LaunchedAt = t - def.Age,
			Buckets = {},
			Candles = {},
			Trades = {},
		}
	end
end

function Market.get(ticker: string): CoinState?
	return states[ticker]
end

function Market.all(): { [string]: CoinState }
	return states
end

function Market.marketCap(ticker: string): number
	return Amm.marketCapUsd(states[ticker].Pool)
end

function Market.setHolderCounter(fn: (ticker: string) -> number)
	holderCounter = fn
end

function Market.setBookProvider(fn: (ticker: string) -> Types.BookDepth)
	bookProvider = fn
end

function Market.setLaunchProvider(fn: (ticker: string) -> Types.LaunchInfo?)
	launchProvider = fn
end

-- Dodaje coin z Pulse z podaną pulą. `initialPrice` to cena startowa (punkt odniesienia botów).
function Market.addCoin(def: Coins.CoinDef, pool: Amm.Pool, launchedAt: number, initialPrice: number): CoinState
	local state: CoinState = {
		Def = def,
		Pool = pool,
		InitialPrice = initialPrice,
		LaunchedAt = launchedAt,
		Buckets = {},
		Candles = {},
		Trades = {},
	}
	states[def.Ticker] = state
	return state
end

function Market.removeCoin(ticker: string)
	states[ticker] = nil
end

-- Podczas rozgrzewki historia jest zapisywana, ale transakcje nie trafiają do broadcastu.
function Market.setBroadcasting(enabled: boolean)
	recording = enabled
end

local function bucketAt(state: CoinState, t: number): Bucket
	local key = math.floor(t / BUCKET_SECONDS)
	local list = state.Buckets
	local last = list[#list]
	if last and last.T == key then
		return last
	end
	local bucket = { T = key, Volume = 0, Buys = 0, Sells = 0, Open = Amm.price(state.Pool) }
	table.insert(list, bucket)
	if #list > MAX_BUCKETS then
		table.remove(list, 1)
	end
	return bucket
end

local function updateCandle(state: CoinState, t: number)
	local price = Amm.price(state.Pool)
	local start = math.floor(t / Config.CandleSeconds) * Config.CandleSeconds
	local list = state.Candles
	local last = list[#list]
	if last and last.T == start then
		last.H = math.max(last.H, price)
		last.L = math.min(last.L, price)
		last.C = price
		return
	end
	local open = if last then last.C else price
	table.insert(list, { T = start, O = open, H = math.max(open, price), L = math.min(open, price), C = price })
	if #list > Config.CandleHistory then
		table.remove(list, 1)
	end
end

local function record(
	state: CoinState,
	side: Types.Side,
	rx: number,
	tokens: number,
	trader: string,
	isPlayer: boolean,
	t: number
)
	local bucket = bucketAt(state, t)
	bucket.Volume += rx
	if side == "Buy" then
		bucket.Buys += 1
	else
		bucket.Sells += 1
	end
	updateCandle(state, t)

	local event: TradeEvent = {
		Ticker = state.Def.Ticker,
		Side = side,
		Rx = rx,
		Tokens = tokens,
		MarketCap = Amm.marketCapUsd(state.Pool),
		Trader = trader,
		IsPlayer = isPlayer,
		Time = t,
	}
	table.insert(state.Trades, 1, event)
	state.Trades[Config.TradeFeedLength + 1] = nil
	if recording then
		table.insert(pendingTrades, event)
	end
end

-- Otwiera kubełek statystyk przed zmianą ceny, żeby zapamiętał cenę otwarcia.
function Market.beginTrade(ticker: string, t: number)
	bucketAt(states[ticker], t)
end

-- Zapisuje transakcję (wolumen, świeca, lista transakcji). Rx: brutto przy kupnie, netto przy sprzedaży.
-- Samo wykonanie (pula + księga zleceń) odbywa się w OrderBook.
function Market.recordTrade(
	ticker: string,
	side: Types.Side,
	rx: number,
	tokens: number,
	trader: string,
	isPlayer: boolean,
	t: number
)
	record(states[ticker], side, rx, tokens, trader, isPlayer, t)
end

-- Domyka świece także wtedy, gdy przez dłuższy czas nikt nie handluje.
function Market.tick(t: number)
	for _, state in states do
		if t >= state.LaunchedAt then
			updateCandle(state, t)
		end
	end
end

local function stats(state: CoinState, t: number): { [string]: Types.TimeframeStats }
	local result = {}
	local price = Amm.price(state.Pool)
	local list = state.Buckets
	local current = math.floor(t / BUCKET_SECONDS)
	local volume, buys, sells, open = 0, 0, 0, price
	local i = #list
	-- Okna są zagnieżdżone (1m ⊂ 5m ⊂ ...), więc jedno przejście od najnowszego kubełka wystarcza.
	for _, timeframe in Config.Timeframes do
		local oldest = current - timeframe.Seconds / BUCKET_SECONDS + 1
		while i >= 1 and list[i].T >= oldest do
			local bucket = list[i]
			volume += bucket.Volume
			buys += bucket.Buys
			sells += bucket.Sells
			open = bucket.Open
			i -= 1
		end
		result[timeframe.Key] = {
			Volume = volume * Config.UsdPerRx,
			Buys = buys,
			Sells = sells,
			Change = (price / open - 1) * 100,
		}
	end
	return result
end

function Market.snapshot(): Types.MarketSnapshot
	local t = Market.now()
	local coins: { [string]: Types.CoinSnapshot } = {}
	for ticker, state in states do
		local candles = state.Candles
		local last = candles[#candles]
		local price = Amm.price(state.Pool)
		local launch = launchProvider(ticker)
		-- Coiny z Pulse nie mają sparkline'a w UI, więc nie wysyłamy go co sekundę.
		local spark = {}
		if not launch then
			for i = math.max(1, #candles - Config.SparkPoints + 1), #candles do
				table.insert(spark, candles[i].C)
			end
		end
		coins[ticker] = {
			Ticker = ticker,
			Book = bookProvider(ticker),
			Launch = launch,
			Price = price,
			PoolRx = state.Pool.Rx,
			PoolTokens = state.Pool.Tokens,
			MarketCap = Amm.marketCapUsd(state.Pool),
			Liquidity = Amm.liquidityUsd(state.Pool),
			Holders = state.Def.Holders + holderCounter(ticker),
			LaunchedAt = state.LaunchedAt,
			Stats = stats(state, t),
			Candle = if last then table.clone(last) else { T = t, O = price, H = price, L = price, C = price },
			Spark = spark,
		}
	end
	return { Time = t, Coins = coins, Trades = {} }
end

-- Snapshot razem z transakcjami od poprzedniego wywołania.
function Market.flush(): Types.MarketSnapshot
	local snapshot = Market.snapshot()
	snapshot.Trades = pendingTrades
	pendingTrades = {}
	return snapshot
end

function Market.recentTrades(): { [string]: { TradeEvent } }
	local result = {}
	for ticker, state in states do
		result[ticker] = table.clone(state.Trades)
	end
	return result
end

function Market.candles(ticker: string): { Candle }
	local state = states[ticker]
	if not state then
		return {}
	end
	local copy = {}
	for i, candle in state.Candles do
		copy[i] = table.clone(candle)
	end
	return copy
end

return Market
