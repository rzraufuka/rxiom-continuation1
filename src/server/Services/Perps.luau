--!strict
-- Perpetuals na serwerze: zlecenia graczy, co sekundę rozliczenie (limit, TP/SL, funding,
-- likwidacje), snapshot cen dla wszystkich i świece do wykresu. Logika pozycji jest w PerpEngine.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local PerpMath = require(ReplicatedStorage.Shared.PerpMath)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local Engine = require(script.Parent.PerpEngine)
local Oracle = require(script.Parent.PerpOracle)
local PlayerData = require(script.Parent.PlayerData)
local Tracker = require(script.Parent.Tracker)

type ActionResult = Types.ActionResult

local PERPS = Config.Perps
local PRINTS = 30

local Perps = {}

local prints: { Types.PerpPrint } = {}
local lastCall: { [Player]: { [string]: number } } = {}
local pushPortfolio: (player: Player) -> () = function() end

local function now(): number
	return workspace:GetServerTimeNow()
end

local function fail(message: string): ActionResult
	return { Ok = false, Error = message }
end

local function finite(v: any): boolean
	return typeof(v) == "number" and v == v and math.abs(v) ~= math.huge
end

local function throttle(player: Player, action: string, seconds: number): boolean
	local calls = lastCall[player] or {}
	lastCall[player] = calls
	local t = os.clock()
	if calls[action] and t - calls[action] < seconds then
		return false
	end
	calls[action] = t
	return true
end

local function addPrint(player: Player?, p: Types.PerpPrint)
	p.Trader = if player then Tracker.traderName(player) else "Anonymous"
	table.insert(prints, p)
	while #prints > PRINTS do
		table.remove(prints, 1)
	end
end

local function notify(player: Player, kind: "Success" | "Error" | "Info", text: string)
	Remotes.Notify:FireClient(player, { Kind = kind, Text = text })
end

-- Rozlicza konto gracza do teraz; zdarzenia trafiają do powiadomień i listy transakcji.
local function settle(player: Player, profile: PlayerData.Profile): boolean
	local events = Engine.advance(profile, now(), Oracle.mark, Oracle.funding)
	for _, e in events do
		notify(player, e.Kind, e.Text)
		if e.Print then
			addPrint(player, e.Print)
		end
	end
	return #events > 0
end

function Perps.equity(profile: PlayerData.Profile): number
	return Engine.equity(profile.Perps, Oracle.mark, now())
end

------------------------------------------------------------------
-- Akcje gracza

local function optionalPrice(v: any): (boolean, number?)
	if v == nil then
		return true, nil
	end
	if finite(v) and v > 0 then
		return true, v
	end
	return false, nil
end

local function placeOrder(player: Player, request: any): ActionResult
	local profile = PlayerData.get(player)
	if not profile then
		return fail("Your data is still loading")
	end
	if not throttle(player, "order", 0.25) then
		return fail("Slow down")
	end
	if typeof(request) ~= "table" then
		return fail("Invalid order")
	end
	local def = PerpMath.market(request.Symbol)
	if not def then
		return fail("Unknown market")
	end
	local symbol = def.Symbol
	local side: Types.PerpSide? = if request.Side == "Long" or request.Side == "Short" then request.Side else nil
	if not side then
		return fail("Pick Long or Short")
	end
	local leverage = request.Leverage
	if not finite(leverage) or leverage ~= math.floor(leverage) or leverage < 1 or leverage > def.MaxLeverage then
		return fail(`Leverage must be 1-{def.MaxLeverage}x`)
	end
	local margin = request.Margin
	if not finite(margin) or margin < Config.MinTradeRx then
		return fail(`Minimum is {Config.MinTradeRx} {Config.Currency}`)
	end
	margin = math.floor(margin * 1e6) / 1e6
	local tpOk, tp = optionalPrice(request.TP)
	local slOk, sl = optionalPrice(request.SL)
	if not tpOk or not slOk then
		return fail("Invalid TP/SL price")
	end

	local t = now()
	settle(player, profile)
	local mark = Oracle.mark(symbol, t)
	local isLimit = request.Type == "Limit"
	local at = mark
	if isLimit then
		if not finite(request.Price) or request.Price <= 0 then
			return fail("Enter a limit price")
		end
		at = request.Price
		if (side == "Long" and at >= mark) or (side == "Short" and at <= mark) then
			return fail(if side == "Long" then "Long limit must be below the current price" else "Short limit must be above the current price")
		end
	elseif request.Type ~= "Market" then
		return fail("Invalid order type")
	end
	local long = side == "Long"
	if tp and (if long then tp <= at else tp >= at) then
		return fail(if long then "Take profit must be above the entry price" else "Take profit must be below the entry price")
	end
	if sl and (if long then sl >= at else sl <= at) then
		return fail(if long then "Stop loss must be below the entry price" else "Stop loss must be above the entry price")
	end

	if isLimit then
		if #profile.Perps.Orders >= PERPS.MaxOrders then
			return fail(`You can have up to {PERPS.MaxOrders} open orders`)
		end
		local reserved = Engine.cost(margin, leverage, PERPS.MakerFee)
		if reserved > profile.Balance + 1e-9 then
			return fail("Insufficient balance")
		end
		profile.Balance = math.max(0, profile.Balance - reserved)
		table.insert(profile.Perps.Orders, {
			Id = HttpService:GenerateGUID(false),
			Symbol = symbol,
			Side = side,
			Price = at,
			Margin = margin,
			Leverage = leverage,
			Reserved = reserved,
			CreatedAt = t,
			TP = tp,
			SL = sl,
		})
		pushPortfolio(player)
		return { Ok = true, Rx = margin }
	end

	local err = Engine.execute(profile, symbol, side, margin, leverage, mark, t, PERPS.TakerFee, tp, sl)
	if err then
		return fail(err)
	end
	addPrint(player, { T = t, Symbol = symbol, Side = side, Price = mark, Size = PerpMath.sizeFor(margin, leverage, mark), Trader = "" })
	pushPortfolio(player)
	return { Ok = true, Rx = margin }
end

local function closePosition(player: Player, symbol: any): ActionResult
	local profile = PlayerData.get(player)
	if not profile then
		return fail("Your data is still loading")
	end
	if not throttle(player, "close", 0.25) then
		return fail("Slow down")
	end
	if not PerpMath.market(symbol) then
		return fail("Unknown market")
	end
	settle(player, profile)
	local pos = profile.Perps.Positions[symbol]
	if not pos then
		return fail("No open position")
	end
	local t = now()
	local mark = Oracle.mark(symbol, t)
	local side: Types.PerpSide = if pos.Side == "Long" then "Short" else "Long"
	local size = pos.Size
	local before = profile.Balance
	Engine.close(profile, symbol, mark, t)
	addPrint(player, { T = t, Symbol = symbol, Side = side, Price = mark, Size = size, Trader = "" })
	pushPortfolio(player)
	return { Ok = true, Rx = profile.Balance - before }
end

local function cancelOrder(player: Player, id: any): ActionResult
	local profile = PlayerData.get(player)
	if not profile then
		return fail("Your data is still loading")
	end
	settle(player, profile)
	for i, order in profile.Perps.Orders do
		if order.Id == id then
			table.remove(profile.Perps.Orders, i)
			profile.Balance += order.Reserved
			pushPortfolio(player)
			return { Ok = true, Rx = order.Reserved }
		end
	end
	return fail("Order not found (it may have been filled)")
end

local function getCandles(player: Player, symbol: any, seconds: any): { Types.Candle }?
	if not throttle(player, "candles", 0.2) then
		return nil
	end
	if not PerpMath.market(symbol) or not table.find(PERPS.Timeframes, seconds) then
		return nil
	end
	return Oracle.candles(symbol, seconds, PERPS.CandleCount, now())
end

function Perps.snapshot(): Types.PerpsSnapshot
	local t = now()
	local markets = {}
	for _, def in PERPS.Markets do
		markets[def.Symbol] = Oracle.market(def.Symbol, t)
	end
	return { T = t, Markets = markets, Prints = prints }
end

function Perps.release(player: Player)
	lastCall[player] = nil
end

function Perps.start(push: (player: Player) -> ())
	pushPortfolio = push
	Remotes.PerpOrder.OnServerInvoke = placeOrder
	Remotes.PerpClose.OnServerInvoke = closePosition
	Remotes.PerpCancel.OnServerInvoke = cancelOrder
	Remotes.GetPerpCandles.OnServerInvoke = getCandles

	-- Po wczytaniu: rozliczenie czasu offline (powiadomienia tylko o tym, co się stało).
	PlayerData.Loaded:Connect(function(player: Player)
		local profile = PlayerData.get(player)
		if profile and settle(player, profile) then
			pushPortfolio(player)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(1)
			for _, player in Players:GetPlayers() do
				local profile = PlayerData.get(player)
				if profile and settle(player, profile) then
					pushPortfolio(player)
				end
			end
			Remotes.PerpsSnapshot:FireAllClients(Perps.snapshot())
		end
	end)
end

Perps.placeOrder = placeOrder
Perps.closePosition = closePosition
Perps.cancelOrder = cancelOrder

return Perps
