--!strict
-- Silnik perpetuals bez zależności od sieci i graczy: otwieranie, zamykanie, odwracanie pozycji,
-- zlecenia limit, TP/SL, funding i likwidacje. Ceny podaje funkcja `price(symbol, t)`, więc
-- `advance` rozlicza też czas, kiedy gracz był offline (na próbkach ceny co kilka sekund).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local PerpMath = require(ReplicatedStorage.Shared.PerpMath)
local Types = require(ReplicatedStorage.Shared.Types)
local Stats = require(script.Parent.Stats)

type PerpAccount = Types.PerpAccount
type PerpPosition = Types.PerpPosition
type PerpOrder = Types.PerpOrder
type PerpSide = Types.PerpSide
type PerpAction = Types.PerpAction

export type Profile = { Balance: number, Perps: PerpAccount, Stats: Types.TradeStats }
export type PriceFn = (symbol: string, t: number) -> number
export type FundingFn = (symbol: string, hour: number) -> number
-- Zdarzenie dla gracza (powiadomienie) i dla innych (lista transakcji).
export type Event = { Kind: "Success" | "Error" | "Info", Text: string, Print: Types.PerpPrint? }

local PERPS = Config.Perps
-- Najwięcej próbek ceny przy rozliczaniu długiej nieobecności.
local MAX_SAMPLES = 20_000
local MIN_OFFLINE_STEP = 5

local Engine = {}

local function finite(v: any): boolean
	return typeof(v) == "number" and v == v and math.abs(v) ~= math.huge
end

function Engine.empty(): PerpAccount
	return { Positions = {}, Orders = {}, History = {}, CheckedAt = 0 }
end

local function price(v: number): string
	local digits = if v >= 1000 then 0 elseif v >= 10 then 2 else 4
	return "$" .. string.format(`%.{digits}f`, v)
end
Engine.priceText = price

local function record(account: PerpAccount, trade: Types.PerpTrade)
	table.insert(account.History, trade)
	while #account.History > PERPS.HistoryLength do
		table.remove(account.History, 1)
	end
end

local function makePrint(symbol: string, side: PerpSide, at: number, size: number, t: number): Types.PerpPrint
	return { T = t, Symbol = symbol, Side = side, Price = at, Size = size, Trader = "" }
end

-- Zamyka część `size` pozycji po cenie `at`. Likwidacja zabiera cały margin tej części.
local function reduce(profile: Profile, pos: PerpPosition, size: number, at: number, now: number, action: PerpAction, feeRate: number): number
	local account = profile.Perps
	local f = math.min(1, size / pos.Size)
	local closed = pos.Size * f
	local liquidation = action == "Liquidation"
	local fee = if liquidation then 0 else PerpMath.notionalRx(closed, at) * feeRate
	local margin = pos.Margin * f
	local deposited = pos.Deposited * f
	local payout = if liquidation then 0 else math.max(0, margin + PerpMath.pnl(pos, at) * f - fee)
	profile.Balance += payout
	Stats.recordPerp(profile.Stats, PerpMath.notionalRx(closed, at), payout - deposited)
	record(account, {
		T = now,
		Symbol = pos.Symbol,
		Side = pos.Side,
		Action = action,
		Price = at,
		Size = closed,
		Fee = fee,
		Pnl = payout - deposited,
	})
	if f >= 1 - 1e-9 then
		account.Positions[pos.Symbol] = nil
	else
		pos.Size -= closed
		pos.Margin -= margin
		pos.Deposited -= deposited
	end
	return payout
end

-- Otwiera albo powiększa pozycję po tej samej stronie. Saldo musi wystarczyć (sprawdza wołający).
local function open(
	profile: Profile,
	symbol: string,
	side: PerpSide,
	margin: number,
	leverage: number,
	at: number,
	now: number,
	feeRate: number,
	tp: number?,
	sl: number?
)
	local account = profile.Perps
	local size = PerpMath.sizeFor(margin, leverage, at)
	local fee = margin * leverage * feeRate
	profile.Balance = math.max(0, profile.Balance - margin - fee)
	Stats.recordPerp(profile.Stats, margin * leverage, -fee)
	local pos = account.Positions[symbol]
	if pos then
		pos.Entry = (pos.Size * pos.Entry + size * at) / (pos.Size + size)
		pos.Size += size
		pos.Margin += margin
		pos.Deposited += margin
	else
		pos = {
			Symbol = symbol,
			Side = side,
			Size = size,
			Entry = at,
			Margin = margin,
			Deposited = margin,
			Funding = 0,
			OpenedAt = now,
			FundingAt = now,
		}
		account.Positions[symbol] = pos
	end
	local p = pos :: PerpPosition
	if tp then
		p.TP = tp
	end
	if sl then
		p.SL = sl
	end
	record(account, { T = now, Symbol = symbol, Side = side, Action = "Open", Price = at, Size = size, Fee = fee })
end

-- Koszt otwarcia: margin + prowizja.
function Engine.cost(margin: number, leverage: number, feeRate: number): number
	return margin * (1 + leverage * feeRate)
end

-- Zlecenie po cenie `at`. Przeciwna pozycja jest najpierw zmniejszana; nadwyżka otwiera pozycję
-- w nową stronę (z odpowiednią częścią marginu). Zwraca komunikat błędu albo nil.
function Engine.execute(
	profile: Profile,
	symbol: string,
	side: PerpSide,
	margin: number,
	leverage: number,
	at: number,
	now: number,
	feeRate: number,
	tp: number?,
	sl: number?
): string?
	local account = profile.Perps
	local pos = account.Positions[symbol]
	if pos and pos.Side ~= side then
		local size = PerpMath.sizeFor(margin, leverage, at)
		if size <= pos.Size * (1 + 1e-9) then
			reduce(profile, pos, size, at, now, "Close", feeRate)
			return nil
		end
		local rest = 1 - pos.Size / size
		reduce(profile, pos, pos.Size, at, now, "Close", feeRate)
		-- Po zamknięciu saldo mogło się zmienić; otwieramy tyle, na ile wystarcza.
		margin = math.min(margin * rest, profile.Balance / (1 + leverage * feeRate))
		if margin < Config.MinTradeRx then
			return nil
		end
	elseif Engine.cost(margin, leverage, feeRate) > profile.Balance + 1e-9 then
		return "Insufficient balance"
	end
	open(profile, symbol, side, margin, leverage, at, now, feeRate, tp, sl)
	return nil
end

function Engine.close(profile: Profile, symbol: string, at: number, now: number): boolean
	local pos = profile.Perps.Positions[symbol]
	if not pos then
		return false
	end
	reduce(profile, pos, pos.Size, at, now, "Close", PERPS.TakerFee)
	return true
end

-- Wartość konta perps w RXI: margin + PnL pozycji (nie mniej niż 0) i rezerwy zleceń limit.
function Engine.equity(account: PerpAccount, priceFn: PriceFn, now: number): number
	local total = 0
	for symbol, pos in account.Positions do
		total += math.max(0, pos.Margin + PerpMath.pnl(pos, priceFn(symbol, now)))
	end
	for _, order in account.Orders do
		total += order.Reserved
	end
	return total
end

local function label(pos: PerpPosition): string
	return `{pos.Symbol} {pos.Side}`
end

-- Funding za pełne godziny do `t`. Zwraca true, gdy pozycja została przy tym zlikwidowana.
local function applyFunding(profile: Profile, pos: PerpPosition, t: number, priceFn: PriceFn, fundingFn: FundingFn, events: { Event }): boolean
	local period = PERPS.FundingSeconds
	local hour = math.floor(pos.FundingAt / period) + 1
	while hour * period <= t do
		local at = hour * period
		local mark = priceFn(pos.Symbol, at)
		local payment = PerpMath.notionalRx(pos.Size, mark) * fundingFn(pos.Symbol, hour)
		local signed = if pos.Side == "Long" then -payment else payment
		pos.Margin += signed
		pos.Funding += signed
		pos.FundingAt = at
		if PerpMath.liquidates(pos, mark) then
			local liq = PerpMath.liqPrice(pos)
			reduce(profile, pos, pos.Size, mark, at, "Liquidation", 0)
			table.insert(events, {
				Kind = "Error",
				Text = `{label(pos)} was liquidated at {price(liq)}`,
				Print = makePrint(pos.Symbol, if pos.Side == "Long" then "Short" else "Long", mark, pos.Size, at),
			})
			return true
		end
		hour += 1
	end
	return false
end

-- TP, SL i likwidacja po cenie `mark`. TP/SL wykonują się po swojej cenie, likwidacja po cenie likwidacji.
local function checkTriggers(profile: Profile, pos: PerpPosition, mark: number, t: number, events: { Event })
	local long = pos.Side == "Long"
	local closing: PerpSide = if long then "Short" else "Long"
	local size = pos.Size
	local tp, sl = pos.TP, pos.SL
	if tp and (if long then mark >= tp else mark <= tp) then
		local payout = reduce(profile, pos, size, tp, t, "TP", PERPS.TakerFee)
		table.insert(events, {
			Kind = "Success",
			Text = `{label(pos)} take profit hit at {price(tp)}, got {Format.rx(payout)}`,
			Print = makePrint(pos.Symbol, closing, tp, size, t),
		})
		return
	end
	if sl and (if long then mark <= sl else mark >= sl) then
		local payout = reduce(profile, pos, size, sl, t, "SL", PERPS.TakerFee)
		table.insert(events, {
			Kind = "Info",
			Text = `{label(pos)} stop loss hit at {price(sl)}, got {Format.rx(payout)}`,
			Print = makePrint(pos.Symbol, closing, sl, size, t),
		})
		return
	end
	if PerpMath.liquidates(pos, mark) then
		local liq = PerpMath.liqPrice(pos)
		reduce(profile, pos, size, liq, t, "Liquidation", 0)
		table.insert(events, {
			Kind = "Error",
			Text = `{label(pos)} was liquidated at {price(liq)}`,
			Print = makePrint(pos.Symbol, closing, liq, size, t),
		})
	end
end

-- Rozlicza konto od CheckedAt do `to`: wykonania zleceń limit, funding, TP/SL i likwidacje.
function Engine.advance(profile: Profile, to: number, priceFn: PriceFn, fundingFn: FundingFn): { Event }
	local account = profile.Perps
	local events: { Event } = {}
	local from = account.CheckedAt
	if to <= from then
		return events
	end
	if next(account.Positions) == nil and #account.Orders == 0 then
		account.CheckedAt = to
		return events
	end
	local gap = to - from
	local step = if gap <= MIN_OFFLINE_STEP then gap else math.max(MIN_OFFLINE_STEP, gap / MAX_SAMPLES)
	local t = from
	while t < to do
		t = math.min(to, t + step)
		local i = 1
		while i <= #account.Orders do
			local o = account.Orders[i]
			local mark = priceFn(o.Symbol, t)
			if (o.Side == "Long" and mark <= o.Price) or (o.Side == "Short" and mark >= o.Price) then
				table.remove(account.Orders, i)
				profile.Balance += o.Reserved
				Engine.execute(profile, o.Symbol, o.Side, o.Margin, o.Leverage, o.Price, t, PERPS.MakerFee, o.TP, o.SL)
				table.insert(events, {
					Kind = "Success",
					Text = `Limit filled: {o.Side} {o.Symbol} at {price(o.Price)}`,
					Print = makePrint(o.Symbol, o.Side, o.Price, PerpMath.sizeFor(o.Margin, o.Leverage, o.Price), t),
				})
			else
				i += 1
			end
		end
		local symbols = {}
		for symbol in account.Positions do
			table.insert(symbols, symbol)
		end
		for _, symbol in symbols do
			local pos = account.Positions[symbol]
			if pos and not applyFunding(profile, pos, t, priceFn, fundingFn, events) then
				checkTriggers(profile, pos, priceFn(symbol, t), t, events)
			end
		end
		if next(account.Positions) == nil and #account.Orders == 0 then
			break
		end
	end
	account.CheckedAt = to
	return events
end

------------------------------------------------------------------
-- Wczytywanie zapisu

local function side(v: any): PerpSide?
	return if v == "Long" or v == "Short" then v else nil
end

local function optionalPrice(v: any): number?
	return if finite(v) and v > 0 then v else nil
end

-- Kopia wpisu z zapisu z nazwą rynku po zmianie nazw (BTC -> GHST itd.).
local function renamed(entry: any): any
	if typeof(entry) ~= "table" then
		return entry
	end
	local copy = table.clone(entry)
	copy.Symbol = PerpMath.rename(copy.Symbol)
	return copy
end

function Engine.sanitize(raw: any, now: number): PerpAccount
	local account = Engine.empty()
	account.CheckedAt = now
	if typeof(raw) ~= "table" then
		return account
	end
	if finite(raw.CheckedAt) then
		account.CheckedAt = math.min(raw.CheckedAt, now)
	end
	if typeof(raw.Positions) == "table" then
		for _, entry in raw.Positions do
			local p = renamed(entry)
			if
				typeof(p) == "table"
				and PerpMath.market(p.Symbol)
				and side(p.Side)
				and finite(p.Size)
				and p.Size > 0
				and finite(p.Entry)
				and p.Entry > 0
				and finite(p.Margin)
				and finite(p.Deposited)
				and not account.Positions[p.Symbol]
			then
				account.Positions[p.Symbol] = {
					Symbol = p.Symbol,
					Side = side(p.Side) :: PerpSide,
					Size = p.Size,
					Entry = p.Entry,
					Margin = p.Margin,
					Deposited = math.max(0, p.Deposited),
					Funding = if finite(p.Funding) then p.Funding else 0,
					OpenedAt = if finite(p.OpenedAt) then p.OpenedAt else 0,
					FundingAt = if finite(p.FundingAt) then math.min(p.FundingAt, now) else account.CheckedAt,
					TP = optionalPrice(p.TP),
					SL = optionalPrice(p.SL),
				}
			end
		end
	end
	if typeof(raw.Orders) == "table" then
		for _, entry in raw.Orders do
			local o = renamed(entry)
			if
				typeof(o) == "table"
				and typeof(o.Id) == "string"
				and #o.Id <= 64
				and PerpMath.market(o.Symbol)
				and side(o.Side)
				and finite(o.Price)
				and o.Price > 0
				and finite(o.Margin)
				and o.Margin > 0
				and finite(o.Leverage)
				and o.Leverage >= 1
				and o.Leverage <= (PerpMath.market(o.Symbol) :: Config.PerpMarketDef).MaxLeverage
				and finite(o.Reserved)
				and o.Reserved >= 0
				and #account.Orders < PERPS.MaxOrders
			then
				table.insert(account.Orders, {
					Id = o.Id,
					Symbol = o.Symbol,
					Side = side(o.Side) :: PerpSide,
					Price = o.Price,
					Margin = o.Margin,
					Leverage = o.Leverage,
					Reserved = o.Reserved,
					CreatedAt = if finite(o.CreatedAt) then o.CreatedAt else 0,
					TP = optionalPrice(o.TP),
					SL = optionalPrice(o.SL),
				})
			end
		end
	end
	if typeof(raw.History) == "table" then
		for _, entry in raw.History do
			local h = renamed(entry)
			local action = if typeof(h) == "table" then h.Action else nil
			if
				typeof(h) == "table"
				and PerpMath.market(h.Symbol)
				and side(h.Side)
				and (action == "Open" or action == "Close" or action == "Liquidation" or action == "TP" or action == "SL")
				and finite(h.T)
				and finite(h.Price)
				and finite(h.Size)
				and finite(h.Fee)
			then
				record(account, {
					T = h.T,
					Symbol = h.Symbol,
					Side = side(h.Side) :: PerpSide,
					Action = action,
					Price = h.Price,
					Size = h.Size,
					Fee = h.Fee,
					Pnl = if finite(h.Pnl) then h.Pnl else nil,
				})
			end
		end
	end
	return account
end

return Engine
