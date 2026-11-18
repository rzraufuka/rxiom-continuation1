--!strict
-- Akcje handlowe gracza: wyliczają podgląd, wysyłają żądanie i pokazują wynik w powiadomieniu.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Amm = require(ReplicatedStorage.Shared.Amm)
local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)

local Market = require(script.Parent.Market)
local Portfolio = require(script.Parent.Portfolio)
local Settings = require(script.Parent.Settings)
local Toast = require(script.Parent.Parent.UI.Toast)

local Actions = {}

local function invoke(remote: RemoteFunction, payload: any): Types.ActionResult
	local ok, result = pcall(remote.InvokeServer, remote, payload)
	if not ok or typeof(result) ~= "table" then
		return { Ok = false, Error = "Connection problem, try again" }
	end
	return result
end

-- Liczba tokenów do sprzedaży dla danego procentu pozycji.
function Actions.sellTokens(ticker: string, percent: number): number
	local p = Portfolio.position(ticker)
	if not p then
		return 0
	end
	return if percent >= 100 then p.Tokens else p.Tokens * percent / 100
end

export type Bracket = { TakeProfit: number, StopLoss: number }

function Actions.buy(ticker: string, rx: number, bracket: Bracket?): boolean
	local pool = Market.pool(ticker)
	if not pool then
		return false
	end
	if rx < Config.MinTradeRx then
		Toast.show(`Minimum buy is {Config.MinTradeRx} {Config.Currency}`, "Error")
		return false
	end
	local s = Settings.State
	if rx + s.PriorityFee + s.Tip > Portfolio.State.Balance + 1e-9 then
		Toast.show("Insufficient balance", "Error")
		return false
	end
	local request: Types.TradeRequest = {
		Ticker = ticker,
		Side = "Buy",
		Amount = rx,
		ExpectedOut = Amm.buyQuote(pool, rx),
		Slippage = s.Slippage,
		PriorityFee = s.PriorityFee,
		Tip = s.Tip,
		Bracket = bracket,
	}
	local result = invoke(Remotes.SubmitTrade, request)
	if result.Ok then
		Toast.show(`Bought {Format.compact(result.Tokens or 0)} {ticker} for {Format.rx(rx)}`, "Success")
	else
		Toast.show(result.Error or "Trade failed", "Error")
	end
	return result.Ok
end

function Actions.sell(ticker: string, percent: number): boolean
	local pool = Market.pool(ticker)
	local tokens = Actions.sellTokens(ticker, percent)
	if not pool or tokens <= Config.DustTokens then
		Toast.show(`You don't hold any {ticker}`, "Error")
		return false
	end
	local s = Settings.State
	local request: Types.TradeRequest = {
		Ticker = ticker,
		Side = "Sell",
		Amount = percent,
		ExpectedOut = Amm.sellQuote(pool, tokens),
		Slippage = s.Slippage,
		PriorityFee = s.PriorityFee,
		Tip = s.Tip,
	}
	local result = invoke(Remotes.SubmitTrade, request)
	if result.Ok then
		Toast.show(`Sold {Format.compact(result.Tokens or 0)} {ticker} for {Format.rx(result.Rx or 0)}`, "Success")
	else
		Toast.show(result.Error or "Trade failed", "Error")
	end
	return result.Ok
end

-- Składa zlecenie w księdze. `price` w RX za token; `amount`: RX przy kupnie, procent przy sprzedaży.
function Actions.placeLimit(ticker: string, side: Types.Side, amount: number, price: number): boolean
	local request: Types.LimitRequest = {
		Ticker = ticker,
		Side = side,
		Price = price,
		Amount = amount,
	}
	local result = invoke(Remotes.PlaceLimitOrder, request)
	if result.Ok then
		local at = "$" .. Format.decimal(price * Config.UsdPerRx)
		local filled = result.Tokens or 0
		local text = `Limit {string.lower(side)} placed at {at}`
		if filled > 0 then
			text ..= ` · {Format.compact(filled)} {ticker} filled instantly`
		end
		Toast.show(text, "Success")
	else
		Toast.show(result.Error or "Order failed", "Error")
	end
	return result.Ok
end

-- `id`: string dla zlecenia z księgi, number dla TP/SL.
function Actions.cancelOrder(id: string | number)
	local result = invoke(Remotes.CancelLimitOrder, id)
	Toast.show(
		if result.Ok then "Order cancelled" else result.Error or "Cancel failed",
		if result.Ok then "Info" else "Error"
	)
end

-- Tworzy coin na Pulse. Czeka, aż coin pojawi się w snapshocie rynku (żeby dało się go od razu
-- otworzyć), a potem opcjonalnie kupuje go za `devBuy` RXI. Zwraca ticker albo nil.
function Actions.createCoin(name: string, ticker: string, color: number, devBuy: number): string?
	local request: Types.CreateCoinRequest = { Name = name, Ticker = ticker, Color = color }
	local result = invoke(Remotes.CreateCoin, request)
	local created = result.Ticker
	if not result.Ok or not created then
		Toast.show(result.Error or "Couldn't create the coin", "Error")
		return nil
	end
	local deadline = os.clock() + 5
	while not Market.pool(created) and os.clock() < deadline do
		task.wait(0.1)
	end
	Toast.show(`{created} is live on Pulse`, "Success")
	if devBuy > 0 and Market.pool(created) then
		Actions.buy(created, devBuy)
	end
	return created
end

function Actions.claimFaucet()
	local result = invoke(Remotes.ClaimFaucet, nil)
	if result.Ok then
		Toast.show(`Deposited {Format.rx(result.Rx or 0)}`, "Success")
	else
		Toast.show(result.Error or "Deposit failed", "Error")
	end
end

return Actions
