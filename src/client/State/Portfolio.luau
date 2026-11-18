--!strict
-- Portfel gracza (saldo, pozycje, zlecenia) synchronizowany z serwera.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Types = require(ReplicatedStorage.Shared.Types)

local Portfolio = {}
Portfolio.State = {
	Balance = 0,
	Positions = {},
	Orders = {},
	Triggers = {},
	FaucetReadyAt = 0,
	Public = false,
	Alias = "",
	Perps = { Positions = {}, Orders = {}, History = {}, CheckedAt = 0 },
	TutorialDone = false,
	Alerts = {},
	Upgrades = {},
} :: Types.PortfolioState
Portfolio.Changed = Signal.new() -- ()

local function apply(state: Types.PortfolioState)
	Portfolio.State = state
	Portfolio.Changed:Fire()
end

function Portfolio.start(initial: Types.PortfolioState?)
	if initial then
		apply(initial)
	end
	Remotes.PortfolioChanged.OnClientEvent:Connect(apply)
end

function Portfolio.position(ticker: string): Types.Position?
	return Portfolio.State.Positions[ticker]
end

-- Zlecenia z księgi (limit), opcjonalnie tylko dla jednego coina.
function Portfolio.orders(ticker: string?): { Types.BookOrder }
	local result = {}
	for _, order in Portfolio.State.Orders do
		if ticker == nil or order.Ticker == ticker then
			table.insert(result, order)
		end
	end
	return result
end

-- TP/SL, opcjonalnie tylko dla jednego coina.
function Portfolio.triggers(ticker: string?): { Types.TriggerOrder }
	local result = {}
	for _, order in Portfolio.State.Triggers do
		if ticker == nil or order.Ticker == ticker then
			table.insert(result, order)
		end
	end
	return result
end

-- Tokeny gracza łącznie z tymi zablokowanymi w zleceniach sprzedaży i TP/SL.
function Portfolio.totalTokens(ticker: string): number
	local p = Portfolio.State.Positions[ticker]
	local total = if p then p.Tokens else 0
	for _, order in Portfolio.State.Triggers do
		if order.Ticker == ticker then
			total += order.Tokens
		end
	end
	for _, order in Portfolio.State.Orders do
		if order.Ticker == ticker and order.Side == "Sell" then
			total += order.Tokens
		end
	end
	return total
end

return Portfolio
