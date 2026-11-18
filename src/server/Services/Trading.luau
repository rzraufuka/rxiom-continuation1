--!strict
-- Obsługa transakcji graczy: market buy/sell z kontrolą slippage, zlecenia w księdze (limit),
-- TP/SL i faucet. Serwer jest jedynym źródłem prawdy; klient wysyła tylko intencję i oczekiwany wynik.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local Upgrades = require(ReplicatedStorage.Shared.Upgrades)
local Amm = require(ReplicatedStorage.Shared.Amm)
local Launchpad = require(script.Parent.Launchpad)
local Market = require(script.Parent.Market)
local OrderBook = require(script.Parent.OrderBook)
local PlayerData = require(script.Parent.PlayerData)
local Tracker = require(script.Parent.Tracker)
local Alerts = require(script.Parent.Alerts)
local Perps = require(script.Parent.Perps)
local Transfer = require(script.Parent.Transfer)

type Profile = PlayerData.Profile
type TriggerOrder = Types.TriggerOrder
type BookOrder = Types.BookOrder
type ActionResult = Types.ActionResult

local Trading = {}

-- TP/SL żyją tylko w sesji; przy wyjściu gracza tokeny wracają do pozycji.
local triggers: { [Player]: { TriggerOrder } } = {}
local recentActions: { [Player]: { number } } = {}
-- Gracze, których portfel zmienił się w tle (wykonanie zlecenia z księgi); wysyłka raz na tick.
local dirty: { [Player]: boolean } = {}
local nextTriggerId = 0

local FEE = Config.FeeBps / 10_000

local function fail(message: string): ActionResult
	return { Ok = false, Error = message }
end

local function finite(v: any): boolean
	return typeof(v) == "number" and v == v and math.abs(v) ~= math.huge
end

local function oneOf(options: { number }, v: any): boolean
	if not finite(v) then
		return false
	end
	for _, option in options do
		if math.abs(option - v) < 1e-9 then
			return true
		end
	end
	return false
end

-- Prosty limiter: najwyżej TradeRateLimit akcji w ciągu ostatniej sekundy.
local function allowAction(player: Player): boolean
	local now = os.clock()
	local list = recentActions[player] or {}
	recentActions[player] = list
	while list[1] and now - list[1] > 1 do
		table.remove(list, 1)
	end
	if #list >= Config.TradeRateLimit then
		return false
	end
	table.insert(list, now)
	return true
end

local function portfolio(player: Player): Types.PortfolioState?
	local profile = PlayerData.get(player)
	if not profile then
		return nil
	end
	return {
		Balance = profile.Balance,
		Positions = profile.Positions,
		Orders = profile.Orders,
		Triggers = triggers[player] or {},
		FaucetReadyAt = profile.FaucetReadyAt,
		Wallet = profile.Wallet,
		Public = profile.Public,
		Alias = Tracker.alias(player),
		Perps = profile.Perps,
		TutorialDone = profile.TutorialDone,
		Alerts = profile.Alerts,
		Upgrades = profile.Upgrades,
	}
end

-- Wartość portfela w RX: saldo, rezerwy zleceń kupna i wszystkie tokeny (także zablokowane w
-- zleceniach sprzedaży i TP/SL) po bieżącej cenie.
function Trading.portfolioValue(player: Player): number
	local profile = PlayerData.get(player)
	if not profile then
		return 0
	end
	local value = profile.Balance
	local tokens: { [string]: number } = {}
	for ticker, p in profile.Positions do
		tokens[ticker] = p.Tokens
	end
	for _, order in profile.Orders do
		if order.Side == "Buy" then
			value += order.Reserved
		else
			tokens[order.Ticker] = (tokens[order.Ticker] or 0) + order.Tokens
		end
	end
	for _, order in triggers[player] or {} :: { TriggerOrder } do
		tokens[order.Ticker] = (tokens[order.Ticker] or 0) + order.Tokens
	end
	for ticker, amount in tokens do
		local state = Market.get(ticker)
		if state then
			value += amount * Amm.price(state.Pool)
		end
	end
	return value + Perps.equity(profile)
end

local function pushPortfolio(player: Player)
	dirty[player] = nil
	local state = portfolio(player)
	if state then
		Remotes.PortfolioChanged:FireClient(player, state)
	end
end

local function notify(player: Player, kind: "Success" | "Error" | "Info", text: string)
	Remotes.Notify:FireClient(player, { Kind = kind, Text = text })
end

local function position(profile: Profile, ticker: string): Types.Position
	local existing = profile.Positions[ticker]
	if existing then
		return existing
	end
	local created = { Tokens = 0, BoughtRx = 0, SoldRx = 0, BuyTokens = 0, BuyValue = 0, Fills = {} }
	profile.Positions[ticker] = created
	return created
end

-- Zapisuje wejście/wyjście do historii pozycji (znaczniki na wykresie, średnia cena wejścia).
-- `poolRx` to RX za tokeny bez prowizji.
local function recordFill(p: Types.Position, side: Types.Side, poolRx: number, tokens: number)
	if tokens <= 0 then
		return
	end
	local price = poolRx / tokens
	table.insert(p.Fills, { T = Market.now(), Side = side, Price = price, Tokens = tokens })
	while #p.Fills > Config.MaxFills do
		table.remove(p.Fills, 1)
	end
	if side == "Buy" then
		p.BuyTokens += tokens
		p.BuyValue += tokens * price
	end
end

local function hasOrdersFor(player: Player, profile: Profile, ticker: string): boolean
	local list: { TriggerOrder } = triggers[player] or {}
	for _, order in list do
		if order.Ticker == ticker then
			return true
		end
	end
	for _, order in profile.Orders do
		if order.Ticker == ticker then
			return true
		end
	end
	return false
end

-- Usuwa pustą pozycję, chyba że jakieś zlecenie wciąż jej dotyczy.
local function cleanup(player: Player, profile: Profile, ticker: string)
	local p = profile.Positions[ticker]
	if p and p.Tokens <= Config.DustTokens and not hasOrdersFor(player, profile, ticker) then
		profile.Positions[ticker] = nil
	end
end

local function traderName(player: Player): string
	return Tracker.traderName(player)
end

local function usdPrice(price: number): string
	return "$" .. Format.decimal(price * Config.UsdPerRx)
end

local function validateFees(request: any): string?
	if not oneOf(Config.PriorityFeeOptions, request.PriorityFee) then
		return "Invalid priority fee"
	end
	if not oneOf(Config.TipOptions, request.Tip) then
		return "Invalid tip"
	end
	return nil
end

local function sellTokens(p: Types.Position?, percent: number): number
	if not p or p.Tokens <= Config.DustTokens then
		return 0
	end
	-- 100% sprzedaje wszystko co do jednostki, bez pyłu po zaokrągleniach.
	return if percent >= 100 then p.Tokens else p.Tokens * percent / 100
end

------------------------------------------------------------------
-- Zlecenia w księdze

-- Kończy zlecenie z księgi: usuwa je z profilu i oddaje niewykorzystaną rezerwę RX.
local function finishOrder(player: Player, profile: Profile, order: BookOrder)
	local index = table.find(profile.Orders, order)
	if index then
		table.remove(profile.Orders, index)
	end
	if order.Side == "Buy" and order.Reserved > 0 then
		profile.Balance += order.Reserved
		order.Reserved = 0
	end
	cleanup(player, profile, order.Ticker)
end

-- Rozlicza część zlecenia wykonaną po stronie gracza. `rx`: dla kupna zapłacone RX, dla sprzedaży
-- otrzymane RX. `poolRx` to wartość bez prowizji (dla historii wejść).
local function settle(player: Player, profile: Profile, order: BookOrder, tokens: number, rx: number, poolRx: number)
	local p = position(profile, order.Ticker)
	if order.Side == "Buy" then
		p.Tokens += tokens
		p.BoughtRx += rx
	else
		profile.Balance += rx
		p.SoldRx += rx
	end
	recordFill(p, order.Side, poolRx, tokens)
	Tracker.record(player, order.Ticker, order.Side, tokens, rx)
end

-- Wystawia zlecenie w księdze (nowe albo wczytane z profilu) i rozlicza część wykonaną od razu.
local function activate(player: Player, profile: Profile, order: BookOrder): (number, number)
	local tokens, rx = OrderBook.place(player, order, traderName(player))
	if tokens > 0 then
		local poolRx = if order.Side == "Buy" then rx * (1 - FEE) else rx / (1 - FEE)
		settle(player, profile, order, tokens, rx, poolRx)
	end
	if order.Tokens <= Config.DustTokens then
		finishOrder(player, profile, order)
	end
	return tokens, rx
end

-- Zlecenie z księgi zostało wykonane przez cudzą transakcję (maker, bez prowizji).
local function onMakerFill(owner: Player, order: BookOrder, tokens: number, rx: number)
	local profile = PlayerData.get(owner)
	if not profile then
		return
	end
	settle(owner, profile, order, tokens, rx, rx)
	dirty[owner] = true
	if order.Tokens <= Config.DustTokens then
		finishOrder(owner, profile, order)
		local verb = if order.Side == "Buy" then "buy" else "sell"
		notify(
			owner,
			"Success",
			`Limit {verb} filled: {Format.compact(order.Filled)} {order.Ticker} at {usdPrice(order.Price)}`
		)
	end
end

local function restoreOrders(player: Player)
	local profile = PlayerData.get(player)
	if not profile then
		return
	end
	for _, order in table.clone(profile.Orders) do
		activate(player, profile, order)
	end
end

local function placeLimitOrder(player: Player, request: any): ActionResult
	if not allowAction(player) then
		return fail("Too many requests, slow down")
	end
	local profile = PlayerData.get(player)
	if not profile then
		return fail("Your data is still loading")
	end
	if typeof(request) ~= "table" or typeof(request.Ticker) ~= "string" or not Market.get(request.Ticker) then
		return fail("Unknown coin")
	end
	if request.Side ~= "Buy" and request.Side ~= "Sell" then
		return fail("Invalid side")
	end
	if not finite(request.Amount) or request.Amount <= 0 then
		return fail("Enter an amount")
	end
	if not finite(request.Price) or request.Price <= 0 then
		return fail("Enter a limit price")
	end
	local ticker: string = request.Ticker
	local price: number = request.Price
	local market = Amm.price((Market.get(ticker) :: Market.CoinState).Pool)
	if price > market * Config.BookPriceBand or price < market / Config.BookPriceBand then
		return fail("Price is too far from the market price")
	end
	if #profile.Orders >= Config.MaxBookOrders then
		return fail(`You can have at most {Config.MaxBookOrders} open limit orders`)
	end

	local order: BookOrder = {
		Id = HttpService:GenerateGUID(false),
		Ticker = ticker,
		Side = request.Side,
		Price = price,
		Tokens = 0,
		Filled = 0,
		Reserved = 0,
		CreatedAt = Market.now(),
	}
	if order.Side == "Buy" then
		local rx: number = request.Amount
		if rx < Config.MinTradeRx then
			return fail(`Minimum order is {Config.MinTradeRx} {Config.Currency}`)
		end
		if rx > profile.Balance + 1e-9 then
			return fail("Insufficient balance")
		end
		profile.Balance = math.max(0, profile.Balance - rx)
		-- Rezerwa pokrywa też prowizję, gdyby zlecenie od razu trafiło na rynek; nadwyżka wraca.
		order.Reserved = rx
		order.Tokens = rx * (1 - FEE) / price
	else
		local p = profile.Positions[ticker]
		local tokens = sellTokens(p, math.min(request.Amount, 100))
		if tokens <= Config.DustTokens or not p then
			return fail("You don't hold this coin")
		end
		if tokens * price < Config.MinTradeRx then
			return fail(`Minimum order is {Config.MinTradeRx} {Config.Currency}`)
		end
		p.Tokens -= tokens
		order.Tokens = tokens
	end

	table.insert(profile.Orders, order)
	local tokens, rx = activate(player, profile, order)
	pushPortfolio(player)
	return { Ok = true, Tokens = tokens, Rx = rx }
end

local function cancelBookOrder(player: Player, profile: Profile, id: string): ActionResult
	for _, order in profile.Orders do
		if order.Id == id then
			OrderBook.remove(order)
			if order.Side == "Sell" then
				position(profile, order.Ticker).Tokens += order.Tokens
				order.Tokens = 0
			end
			finishOrder(player, profile, order)
			pushPortfolio(player)
			return { Ok = true }
		end
	end
	return fail("Order not found")
end

------------------------------------------------------------------
-- TP/SL

local function refundTrigger(profile: Profile, order: TriggerOrder)
	position(profile, order.Ticker).Tokens += order.Tokens
end

local function cancelTrigger(player: Player, profile: Profile, id: number): ActionResult
	local list = triggers[player]
	if not list then
		return fail("Order not found")
	end
	for i, order in list do
		if order.Id == id then
			table.remove(list, i)
			refundTrigger(profile, order)
			cleanup(player, profile, order.Ticker)
			pushPortfolio(player)
			return { Ok = true }
		end
	end
	return fail("Order not found")
end

-- Zwrot części prowizji (ulepszenie Fee Cashback) od prowizji `fee`.
local function cashback(profile: Profile, fee: number): number
	local rate = Upgrades.value(profile.Upgrades, "Cashback")
	if rate <= 0 or fee <= 0 then
		return 0
	end
	local back = fee * rate
	profile.Balance += back
	return back
end

local function fillTrigger(player: Player, profile: Profile, order: TriggerOrder)
	-- Etykietę liczymy przed sprzedażą, bo sama sprzedaż obniża market cap.
	local label = if Market.marketCap(order.Ticker) >= order.Above then "Take profit" else "Stop loss"
	local received, sold = OrderBook.sell(order.Ticker, order.Tokens, traderName(player), true)
	local rx = math.max(0, received - order.Fees)
	local p = position(profile, order.Ticker)
	recordFill(p, "Sell", received / (1 - FEE), sold)
	p.SoldRx += rx
	profile.Balance += rx
	local back = cashback(profile, received / (1 - FEE) * FEE)
	Tracker.record(player, order.Ticker, "Sell", sold, rx + back)
	notify(player, "Success", `{label} filled: {Format.compact(sold)} {order.Ticker} for {Format.rx(rx)}`)
end

------------------------------------------------------------------
-- Akcje gracza

local function submitTrade(player: Player, request: any): ActionResult
	if not allowAction(player) then
		return fail("Too many requests, slow down")
	end
	local profile = PlayerData.get(player)
	if not profile then
		return fail("Your data is still loading")
	end
	if typeof(request) ~= "table" or typeof(request.Ticker) ~= "string" then
		return fail("Invalid request")
	end
	local ticker: string = request.Ticker
	if not Market.get(ticker) then
		return fail("Unknown coin")
	end
	if request.Side ~= "Buy" and request.Side ~= "Sell" then
		return fail("Invalid side")
	end
	if not finite(request.Amount) or request.Amount <= 0 then
		return fail("Enter an amount")
	end
	if not finite(request.ExpectedOut) or request.ExpectedOut < 0 then
		return fail("Invalid quote")
	end
	if not oneOf(Config.SlippageOptions, request.Slippage) then
		return fail("Invalid slippage")
	end
	local feeError = validateFees(request)
	if feeError then
		return fail(feeError)
	end

	local state = Market.get(ticker) :: Market.CoinState
	local fees: number = request.PriorityFee + request.Tip
	local minOut = request.ExpectedOut * (1 - request.Slippage / 100)

	if request.Side == "Buy" then
		local rx: number = request.Amount
		if rx < Config.MinTradeRx then
			return fail(`Minimum buy is {Config.MinTradeRx} {Config.Currency}`)
		end
		if rx + fees > profile.Balance + 1e-9 then
			return fail("Insufficient balance")
		end
		-- Wycena z samej puli; księga zleceń może ją tylko poprawić.
		local quote = Amm.buyQuote(state.Pool, rx)
		if quote < minOut then
			return fail("Price moved more than your slippage")
		end

		local tokens, spent = OrderBook.buy(ticker, rx, traderName(player), true)
		profile.Balance = math.max(0, profile.Balance - spent - fees)
		local back = cashback(profile, spent * FEE)
		local p = position(profile, ticker)
		p.Tokens += tokens
		p.BoughtRx += spent + fees - back
		recordFill(p, "Buy", spent * (1 - FEE), tokens)
		Tracker.record(player, ticker, "Buy", tokens, spent + fees - back)

		local bracket = request.Bracket
		if typeof(bracket) == "table" and finite(bracket.TakeProfit) and finite(bracket.StopLoss) then
			local tp = math.clamp(bracket.TakeProfit, 1, 100_000)
			local sl = math.clamp(bracket.StopLoss, 1, 99)
			local mc = Market.marketCap(ticker)
			local list = triggers[player] or {}
			triggers[player] = list
			if #list < Config.MaxOpenOrders then
				nextTriggerId += 1
				table.insert(list, {
					Id = nextTriggerId,
					Ticker = ticker,
					Tokens = tokens,
					Fees = fees,
					Above = mc * (1 + tp / 100),
					Below = mc * (1 - sl / 100),
					CreatedAt = Market.now(),
				})
				p.Tokens -= tokens
			else
				notify(player, "Error", "TP/SL not set: too many open orders")
			end
		end

		pushPortfolio(player)
		return { Ok = true, Rx = spent, Tokens = tokens }
	end

	local percent: number = math.min(request.Amount, 100)
	local p = profile.Positions[ticker]
	local tokens = sellTokens(p, percent)
	if tokens <= Config.DustTokens or not p then
		return fail("You don't hold this coin")
	end
	local quote = Amm.sellQuote(state.Pool, tokens)
	if quote < minOut then
		return fail("Price moved more than your slippage")
	end
	if quote <= fees then
		return fail("Amount too small to cover fees")
	end

	local received, sold = OrderBook.sell(ticker, tokens, traderName(player), true)
	local rx = received - fees
	recordFill(p, "Sell", received / (1 - FEE), sold)
	p.Tokens -= sold
	local back = cashback(profile, received / (1 - FEE) * FEE)
	p.SoldRx += rx + back
	profile.Balance += rx
	Tracker.record(player, ticker, "Sell", sold, rx + back)
	cleanup(player, profile, ticker)
	pushPortfolio(player)
	return { Ok = true, Rx = rx + back, Tokens = sold }
end

local function cancelLimitOrder(player: Player, id: any): ActionResult
	if not allowAction(player) then
		return fail("Too many requests, slow down")
	end
	local profile = PlayerData.get(player)
	if not profile then
		return fail("Order not found")
	end
	if typeof(id) == "string" then
		return cancelBookOrder(player, profile, id)
	elseif typeof(id) == "number" then
		return cancelTrigger(player, profile, id)
	end
	return fail("Order not found")
end

local function claimFaucet(player: Player): ActionResult
	local profile = PlayerData.get(player)
	if not profile then
		return fail("Your data is still loading")
	end
	local now = os.time()
	if now < profile.FaucetReadyAt then
		return fail(`Next deposit available in {Format.age(profile.FaucetReadyAt - now)}`)
	end
	profile.Balance += Upgrades.value(profile.Upgrades, "FaucetAmount")
	profile.FaucetReadyAt = now + Upgrades.value(profile.Upgrades, "FaucetSpeed")
	pushPortfolio(player)
	return { Ok = true, Rx = Upgrades.value(profile.Upgrades, "FaucetAmount") }
end

local function buyUpgrade(player: Player, id: any): ActionResult
	if not allowAction(player) then
		return fail("Too many requests, slow down")
	end
	local profile = PlayerData.get(player)
	if not profile then
		return fail("Your data is still loading")
	end
	local def = Upgrades.get(id)
	if not def then
		return fail("Unknown upgrade")
	end
	local cost = Upgrades.nextCost(profile.Upgrades, def.Id)
	if not cost then
		return fail(`{def.Name} is already maxed`)
	end
	if cost > profile.Balance + 1e-9 then
		return fail(`{def.Name} costs {Format.rx(cost)}`)
	end
	profile.Balance = math.max(0, profile.Balance - cost)
	local level = Upgrades.level(profile.Upgrades, def.Id) + 1
	profile.Upgrades[def.Id] = level
	-- Szybszy Deposit działa od razu, także na trwające odliczanie.
	if def.Id == "FaucetSpeed" then
		local ready = os.time() + def.Values[level + 1]
		profile.FaucetReadyAt = math.min(profile.FaucetReadyAt, ready)
	end
	pushPortfolio(player)
	return { Ok = true, Rx = cost }
end


-- Wykonuje TP/SL, których warunek na market cap został spełniony, i wysyła zaległe portfele.
function Trading.checkOrders()
	for player, list in triggers do
		local profile = PlayerData.get(player)
		if not profile then
			continue
		end
		local changed = false
		for i = #list, 1, -1 do
			local order = list[i]
			if not Market.get(order.Ticker) then
				continue
			end
			local mc = Market.marketCap(order.Ticker)
			if mc >= order.Above or mc <= order.Below then
				table.remove(list, i)
				fillTrigger(player, profile, order)
				cleanup(player, profile, order.Ticker)
				changed = true
			end
		end
		if changed then
			dirty[player] = true
		end
	end
	for player in dirty do
		pushPortfolio(player)
	end
end

-- Przed zapisem: tokeny z TP/SL wracają do pozycji, zlecenia z księgi zostają w profilu,
-- ale znikają z księgi tego serwera.
function Trading.release(player: Player)
	local profile = PlayerData.get(player)
	local list = triggers[player]
	if profile and list then
		for _, order in list do
			refundTrigger(profile, order)
		end
	end
	triggers[player] = nil
	OrderBook.removeOwner(player)
	dirty[player] = nil
end

function Trading.start()
	Market.setHolderCounter(PlayerData.countHolders)
	OrderBook.setFillHandler(onMakerFill)
	Launchpad.start(pushPortfolio)
	Tracker.start(Trading.portfolioValue, pushPortfolio)
	Transfer.start(pushPortfolio)
	Perps.start(pushPortfolio)
	Alerts.start(pushPortfolio)
	Remotes.CompleteTutorial.OnServerEvent:Connect(function(player: Player)
		local profile = PlayerData.get(player)
		if profile and not profile.TutorialDone then
			profile.TutorialDone = true
			pushPortfolio(player)
		end
	end)

	Remotes.SubmitTrade.OnServerInvoke = submitTrade
	Remotes.PlaceLimitOrder.OnServerInvoke = placeLimitOrder
	Remotes.CancelLimitOrder.OnServerInvoke = cancelLimitOrder
	Remotes.ClaimFaucet.OnServerInvoke = claimFaucet
	Remotes.BuyUpgrade.OnServerInvoke = buyUpgrade
	Remotes.GetCandles.OnServerInvoke = function(_player: Player, ticker: any)
		return if typeof(ticker) == "string" then Market.candles(ticker) else {}
	end
	Remotes.Login.OnServerInvoke = function(player: Player): Types.LoginResult
		local profile = PlayerData.waitFor(player, 15)
		if not profile then
			return { Ok = false, Error = "Your data is still loading, try again" }
		end
		local wallet, isNew = PlayerData.ensureWallet(profile)
		task.spawn(Transfer.indexWallet, player, wallet)
		pushPortfolio(player)
		return { Ok = true, Wallet = wallet, New = isNew }
	end
	Remotes.GetInitialState.OnServerInvoke = function(player: Player): Types.InitialState
		return {
			Market = Market.snapshot(),
			Trades = Market.recentTrades(),
			Portfolio = portfolio(player),
		}
	end

	PlayerData.Loaded:Connect(function(player: Player)
		-- Coiny z Pulse, w których gracz ma udział, muszą być na rynku przed odtworzeniem zleceń.
		Launchpad.ensureActive(player)
		restoreOrders(player)
		pushPortfolio(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		Trading.release(player)
		recentActions[player] = nil
		-- Publiczne statystyki przed zapisem profilu (wartość portfela liczona z jeszcze wczytanego).
		Tracker.release(player)
		Transfer.release(player)
		Perps.release(player)
		Alerts.release(player)
		PlayerData.release(player)
	end)
	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			Trading.release(player)
		end
		PlayerData.saveAll()
	end)
end

return Trading
