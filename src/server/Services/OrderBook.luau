--!strict
-- Księga zleceń z limitem ceny (bids/asks) dla każdego coina, połączona z pulą AMM.
--
-- Każda transakcja rynkowa (gracze, boty, TP/SL) przechodzi przez `buy`/`sell`: kupuje z puli
-- tylko do ceny najlepszego asku, potem wykonuje ten ask po jego cenie i tak dalej (sprzedaż
-- analogicznie z bidami). Dzięki temu bidy zawsze leżą poniżej ceny puli, aski powyżej, a taker
-- dostaje wykonanie nie gorsze niż z samej puli. Dopasowanie odbywa się wyłącznie na serwerze.
--
-- Taker płaci prowizję Config.FeeBps, maker dostaje/płaci dokładnie cenę swojego zlecenia.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Amm = require(ReplicatedStorage.Shared.Amm)
local Coins = require(ReplicatedStorage.Shared.Coins)
local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Market = require(script.Parent.Market)

type BookOrder = Types.BookOrder
type Entry = { Order: BookOrder, Owner: Player }
type Book = { Bids: { Entry }, Asks: { Entry } }

-- Wywoływane, gdy zlecenie z księgi zostało (częściowo) wykonane po swojej cenie.
-- `order` ma już zaktualizowane Tokens/Filled/Reserved; Tokens <= DustTokens oznacza koniec.
export type FillHandler = (owner: Player, order: BookOrder, tokens: number, rx: number) -> ()

local FEE = Config.FeeBps / 10_000
local EPS = 1e-9
-- Zabezpieczenie przed nieskończoną pętlą przy błędach zaokrągleń.
local MAX_STEPS = 5000

local OrderBook = {}

local books: { [string]: Book } = {}
local onFill: FillHandler = function() end

local function isDone(order: BookOrder): boolean
	return order.Tokens <= Config.DustTokens
end

-- Czy `a` ma pierwszeństwo przed `b` (lepsza cena, potem wcześniejsze złożenie).
local function ahead(a: BookOrder, b: BookOrder): boolean
	if a.Price ~= b.Price then
		return if a.Side == "Buy" then a.Price > b.Price else a.Price < b.Price
	end
	return a.CreatedAt < b.CreatedAt
end

local function sideList(order: BookOrder): { Entry }
	local book = books[order.Ticker]
	return if order.Side == "Buy" then book.Bids else book.Asks
end

local function rest(owner: Player, order: BookOrder)
	local list = sideList(order)
	local index = #list + 1
	for i, entry in list do
		if ahead(order, entry.Order) then
			index = i
			break
		end
	end
	table.insert(list, index, { Order = order, Owner = owner })
end

local function aggregate(list: { Entry }): { Types.BookLevel }
	local levels: { Types.BookLevel } = {}
	for _, entry in list do
		local order = entry.Order
		local last = levels[#levels]
		if last and last.Price == order.Price then
			last.Tokens += order.Tokens
			last.Orders += 1
		elseif #levels >= Config.BookDepthLevels then
			break
		else
			table.insert(levels, { Price = order.Price, Tokens = order.Tokens, Orders = 1 })
		end
	end
	return levels
end

function OrderBook.init()
	for _, def in Coins.List do
		books[def.Ticker] = { Bids = {}, Asks = {} }
	end
	Market.setBookProvider(OrderBook.depth)
end

function OrderBook.setFillHandler(fn: FillHandler)
	onFill = fn
end

function OrderBook.addCoin(ticker: string)
	if not books[ticker] then
		books[ticker] = { Bids = {}, Asks = {} }
	end
end

-- Usuwa pustą księgę coina. Zwraca false (i nic nie robi), gdy w księdze są zlecenia.
function OrderBook.removeCoin(ticker: string): boolean
	local book = books[ticker]
	if book and (#book.Bids > 0 or #book.Asks > 0) then
		return false
	end
	books[ticker] = nil
	return true
end

function OrderBook.depth(ticker: string): Types.BookDepth
	local book = books[ticker]
	if not book then
		return { Bids = {}, Asks = {} }
	end
	return { Bids = aggregate(book.Bids), Asks = aggregate(book.Asks) }
end

-- Kupno za `rxIn` RX (z prowizją). `limit` to najwyższa akceptowana cena (RX za token),
-- `maxTokens` ogranicza liczbę kupionych tokenów. Zwraca (tokeny, wydane RX z prowizją).
function OrderBook.buy(
	ticker: string,
	rxIn: number,
	trader: string,
	isPlayer: boolean,
	t: number?,
	limit: number?,
	maxTokens: number?
): (number, number)
	local state = Market.get(ticker)
	local book = books[ticker]
	if not state or not book or rxIn <= 0 then
		return 0, 0
	end
	local time = t or Market.now()
	local pool = state.Pool
	local cap = limit or math.huge
	local wanted = maxTokens or math.huge
	local budget = rxIn * (1 - FEE)
	local got = 0
	local started = false
	local asks = book.Asks

	for _ = 1, MAX_STEPS do
		if budget <= rxIn * EPS or wanted - got <= Config.DustTokens then
			break
		end
		if not started then
			Market.beginTrade(ticker, time)
			started = true
		end
		local best = asks[1]
		local price = Amm.price(pool)
		if best and best.Order.Price <= cap and best.Order.Price <= price * (1 + EPS) then
			local order = best.Order
			local tokens = math.min(order.Tokens, budget / order.Price, wanted - got)
			local rx = tokens * order.Price
			order.Tokens -= tokens
			order.Filled += tokens
			budget -= rx
			got += tokens
			if isDone(order) then
				table.remove(asks, 1)
			end
			onFill(best.Owner, order, tokens, rx)
			continue
		end
		local target = math.min(cap, if best then best.Order.Price else math.huge)
		if price >= target * (1 - EPS) then
			break
		end
		local need = if target == math.huge then math.huge else Amm.rxToPrice(pool, target)
		local spend = math.min(budget, need, Amm.rxForTokens(pool, wanted - got))
		if spend <= 0 then
			break
		end
		got += Amm.swapRx(pool, spend)
		budget -= spend
		if spend < need then
			break
		end
	end

	local spent = math.max(0, rxIn - budget / (1 - FEE))
	if got > 0 then
		Market.recordTrade(ticker, "Buy", spent, got, trader, isPlayer, time)
	end
	return got, spent
end

-- Sprzedaż `tokensIn` tokenów. `limit` to najniższa akceptowana cena (RX za token).
-- Zwraca (RX po prowizji, sprzedane tokeny).
function OrderBook.sell(
	ticker: string,
	tokensIn: number,
	trader: string,
	isPlayer: boolean,
	t: number?,
	limit: number?
): (number, number)
	local state = Market.get(ticker)
	local book = books[ticker]
	if not state or not book or tokensIn <= 0 then
		return 0, 0
	end
	local time = t or Market.now()
	local pool = state.Pool
	local floor = limit or 0
	local left = tokensIn
	local gross = 0
	local started = false
	local bids = book.Bids

	for _ = 1, MAX_STEPS do
		if left <= tokensIn * EPS then
			break
		end
		if not started then
			Market.beginTrade(ticker, time)
			started = true
		end
		local best = bids[1]
		local price = Amm.price(pool)
		if best and best.Order.Price >= floor and best.Order.Price >= price * (1 - EPS) then
			local order = best.Order
			local tokens = math.min(order.Tokens, left)
			local rx = tokens * order.Price
			order.Tokens -= tokens
			order.Filled += tokens
			order.Reserved = math.max(0, order.Reserved - rx)
			left -= tokens
			gross += rx
			if isDone(order) then
				table.remove(bids, 1)
			end
			onFill(best.Owner, order, tokens, rx)
			continue
		end
		local target = math.max(floor, if best then best.Order.Price else 0)
		if target > 0 and price <= target * (1 + EPS) then
			break
		end
		local need = if target > 0 then Amm.tokensToPrice(pool, target) else math.huge
		local spend = math.min(left, need)
		if spend <= 0 then
			break
		end
		gross += Amm.swapTokens(pool, spend)
		left -= spend
		if spend < need then
			break
		end
	end

	local sold = tokensIn - left
	local received = gross * (1 - FEE)
	if sold > 0 then
		Market.recordTrade(ticker, "Sell", received, sold, trader, isPlayer, time)
	end
	return received, sold
end

-- Składa zlecenie (nowe albo wczytane z profilu). Część, która od razu krzyżuje się z rynkiem,
-- jest wykonywana jako taker, reszta czeka w księdze. Zwraca wykonaną od razu część:
-- (tokeny, RX wydane z rezerwy przy kupnie / RX otrzymane przy sprzedaży).
function OrderBook.place(owner: Player, order: BookOrder, trader: string): (number, number)
	if not books[order.Ticker] then
		return 0, 0
	end
	local tokens, rx = 0, 0
	if order.Side == "Buy" then
		tokens, rx = OrderBook.buy(order.Ticker, order.Reserved, trader, true, nil, order.Price, order.Tokens)
		order.Reserved = math.max(0, order.Reserved - rx)
	else
		rx, tokens = OrderBook.sell(order.Ticker, order.Tokens, trader, true, nil, order.Price)
	end
	order.Tokens = math.max(0, order.Tokens - tokens)
	order.Filled += tokens
	if not isDone(order) then
		rest(owner, order)
	end
	return tokens, rx
end

-- Zdejmuje zlecenie z księgi. Zwraca false, gdy go tam nie było.
function OrderBook.remove(order: BookOrder): boolean
	if not books[order.Ticker] then
		return false
	end
	local list = sideList(order)
	for i, entry in list do
		if entry.Order == order then
			table.remove(list, i)
			return true
		end
	end
	return false
end

-- Zdejmuje z księgi wszystkie zlecenia gracza (zostają w jego profilu do następnej sesji).
function OrderBook.removeOwner(owner: Player)
	for _, book in books do
		for _, list in { book.Bids, book.Asks } do
			for i = #list, 1, -1 do
				if list[i].Owner == owner then
					table.remove(list, i)
				end
			end
		end
	end
end

return OrderBook
