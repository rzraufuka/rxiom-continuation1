--!strict
-- Lokalna kopia stanu rynku, odświeżana snapshotami z serwera co sekundę.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Amm = require(ReplicatedStorage.Shared.Amm)
local Coins = require(ReplicatedStorage.Shared.Coins)
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Types = require(ReplicatedStorage.Shared.Types)

type Candle = Types.Candle
type TradeEvent = Types.TradeEvent

local Market = {}
Market.Coins = {} :: { [string]: Types.CoinSnapshot }
Market.Changed = Signal.new() -- ()
Market.TradesChanged = Signal.new() -- (ticker)
Market.CandlesChanged = Signal.new() -- (ticker)

local trades: { [string]: { TradeEvent } } = {}
local candles: { [string]: { Candle } } = {}
local loading: { [string]: boolean } = {}

local function mergeCandle(ticker: string, candle: Candle): boolean
	local list = candles[ticker]
	if not list then
		return false
	end
	local last = list[#list]
	if last and last.T == candle.T then
		list[#list] = candle
	elseif not last or candle.T > last.T then
		table.insert(list, candle)
		if #list > Config.CandleHistory then
			table.remove(list, 1)
		end
	end
	return true
end

local function apply(snapshot: Types.MarketSnapshot)
	-- Nowe coiny z Pulse poznajemy ze snapshotu (nazwa, kolor, twórca).
	for ticker, coin in snapshot.Coins do
		local launch = coin.Launch
		if launch and not Coins.get(ticker) then
			Coins.register(Coins.launch(ticker, launch.Name, launch.Color, launch.Creator))
		end
	end
	Market.Coins = snapshot.Coins
	local candleTickers = {}
	for ticker, coin in snapshot.Coins do
		if mergeCandle(ticker, coin.Candle) then
			candleTickers[ticker] = true
		end
	end
	local tradeTickers = {}
	for _, trade in snapshot.Trades do
		local list = trades[trade.Ticker] or {}
		trades[trade.Ticker] = list
		table.insert(list, 1, trade)
		list[Config.TradeFeedLength + 1] = nil
		tradeTickers[trade.Ticker] = true
	end
	Market.Changed:Fire()
	for ticker in tradeTickers do
		Market.TradesChanged:Fire(ticker)
	end
	for ticker in candleTickers do
		Market.CandlesChanged:Fire(ticker)
	end
end

function Market.start(initial: Types.InitialState)
	trades = initial.Trades
	apply(initial.Market)
	Remotes.MarketSnapshot.OnClientEvent:Connect(apply)
end

function Market.now(): number
	return workspace:GetServerTimeNow()
end

function Market.coin(ticker: string): Types.CoinSnapshot?
	return Market.Coins[ticker]
end

function Market.pool(ticker: string): Amm.Pool?
	local coin = Market.Coins[ticker]
	return if coin then { Rx = coin.PoolRx, Tokens = coin.PoolTokens } else nil
end

function Market.trades(ticker: string): { TradeEvent }
	return trades[ticker] or {}
end

-- Zwraca świece z cache; przy pierwszym wywołaniu pobiera je z serwera w tle.
function Market.candles(ticker: string): { Candle }?
	local list = candles[ticker]
	if list or loading[ticker] then
		return list
	end
	loading[ticker] = true
	task.spawn(function()
		local ok, result = pcall(Remotes.GetCandles.InvokeServer, Remotes.GetCandles, ticker)
		loading[ticker] = nil
		if ok and typeof(result) == "table" then
			candles[ticker] = result
			local coin = Market.Coins[ticker]
			if coin then
				mergeCandle(ticker, coin.Candle)
			end
			Market.CandlesChanged:Fire(ticker)
		end
	end)
	return nil
end

-- Market cap w $ dla ceny w RX za token.
function Market.toMarketCap(price: number): number
	return price * Config.TotalSupply * Config.UsdPerRx
end

return Market
