--!strict
-- Pulse: coiny tworzone przez graczy. Każdy startuje z małą wirtualną pulą (bonding curve) i po
-- osiągnięciu Config.Launch.MigrationMarketCap "migruje" na stałe.
--
-- Definicje coinów i ostatni stan puli trafiają do wspólnego rejestru w DataStore, więc coin i
-- pozycje w nim przeżywają restart i są widoczne na innych serwerach. Każdy serwer prowadzi własny
-- rynek (jak przy coinach ze stałej listy) i co minutę zapisuje pule coinów, którymi handlowano.
-- Na rynku serwera jest naraz najwyżej Config.Launch.MaxActive coinów z Pulse (plus te, w których
-- gracze na serwerze mają pozycje), bo wszystkie trafiają do snapshotu wysyłanego co sekundę.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local Upgrades = require(ReplicatedStorage.Shared.Upgrades)
local Bots = require(script.Parent.Bots)
local Market = require(script.Parent.Market)
local OrderBook = require(script.Parent.OrderBook)
local PlayerData = require(script.Parent.PlayerData)
local Snipers = require(script.Parent.Snipers)

type ActionResult = Types.ActionResult

-- Wpis rejestru. Color jako hex, bo DataStore nie zapisuje Color3.
export type Entry = {
	Ticker: string,
	Name: string,
	Color: string,
	Creator: string,
	CreatorId: number,
	CreatedAt: number,
	Rx: number,
	Tokens: number,
	Migrated: boolean,
	MigratedAt: number?,
	UpdatedAt: number,
}

local STORE_NAME = "RXIOM_Launches_v1"
local KEY = "registry"
local SAVE_SECONDS = 60
-- Rejestr trzyma najwyżej tyle coinów; przy przepełnieniu znikają najdawniej aktywne niemigrowane.
local MAX_ENTRIES = 1000
-- Młodszych coinów nie zdejmujemy z rynku, nawet gdy brakuje miejsca.
local PRUNE_MIN_AGE = 600
-- Coiny z innych serwerów stworzone niedawno trafiają od razu na rynek tego serwera.
local FRESH_SECONDS = 1800

local LAUNCH = Config.Launch
local START_PRICE = LAUNCH.StartMarketCap / Config.UsdPerRx / Config.TotalSupply

local Launchpad = {}

-- Wszystkie coiny z rejestru, także nieaktywne na tym serwerze.
local known: { [string]: Entry } = {}
-- Coiny na rynku tego serwera.
local active: { [string]: Entry } = {}
-- RX w puli przy ostatnim zapisie; zmiana oznacza handel do zapisania.
local savedRx: { [string]: number } = {}
-- Wpisy do zapisania niezależnie od zmiany puli (nowe, zmigrowane, zdjęte z rynku).
local pending: { [string]: boolean } = {}
local lastLaunch: { [number]: number } = {}
local store: DataStore? = nil
local pushPortfolio: (player: Player) -> () = function() end

local function fail(message: string): ActionResult
	return { Ok = false, Error = message }
end

local function finite(v: any): boolean
	return typeof(v) == "number" and v == v and math.abs(v) ~= math.huge
end

local function sanitizeEntry(e: any): Entry?
	if
		typeof(e) ~= "table"
		or not Coins.validTicker(e.Ticker)
		or Coins.ByTicker[e.Ticker]
		or not Coins.validName(e.Name)
		or typeof(e.Color) ~= "string"
		or not string.find(e.Color, "^%x%x%x%x%x%x$")
		or typeof(e.Creator) ~= "string"
		or not finite(e.CreatedAt)
		or not finite(e.Rx)
		or not finite(e.Tokens)
		or e.Rx <= 0
		or e.Tokens <= 0
	then
		return nil
	end
	return {
		Ticker = e.Ticker,
		Name = e.Name,
		Color = e.Color,
		Creator = string.sub(e.Creator, 1, 32),
		CreatorId = if finite(e.CreatorId) then e.CreatorId else 0,
		CreatedAt = e.CreatedAt,
		Rx = e.Rx,
		Tokens = e.Tokens,
		Migrated = e.Migrated == true,
		MigratedAt = if finite(e.MigratedAt) then e.MigratedAt else nil,
		UpdatedAt = if finite(e.UpdatedAt) then e.UpdatedAt else e.CreatedAt,
	}
end

local function activeCount(): number
	local n = 0
	for _ in active do
		n += 1
	end
	return n
end

local function activate(entry: Entry)
	if active[entry.Ticker] then
		return
	end
	local def = Coins.launch(entry.Ticker, entry.Name, Color3.fromHex(entry.Color), entry.Creator)
	Coins.register(def)
	Market.addCoin(def, { Rx = entry.Rx, Tokens = entry.Tokens }, entry.CreatedAt, START_PRICE)
	OrderBook.addCoin(entry.Ticker)
	active[entry.Ticker] = entry
	savedRx[entry.Ticker] = entry.Rx
end

-- Przepisuje bieżącą pulę z rynku do wpisu.
local function capture(entry: Entry)
	local state = Market.get(entry.Ticker)
	if state then
		entry.Rx = state.Pool.Rx
		entry.Tokens = state.Pool.Tokens
	end
	entry.UpdatedAt = Market.now()
end

local function deactivate(ticker: string): boolean
	local entry = active[ticker]
	if not entry or not OrderBook.removeCoin(ticker) then
		return false
	end
	capture(entry)
	pending[ticker] = true
	Market.removeCoin(ticker)
	Coins.unregister(ticker)
	Bots.forget(ticker)
	active[ticker] = nil
	return true
end

-- Zdejmuje z rynku najsłabsze coiny (najniższy market cap), gdy jest ich za dużo. Nie rusza
-- coinów młodszych niż PRUNE_MIN_AGE ani takich, w których gracze na serwerze mają udział.
local function prune()
	local now = Market.now()
	while activeCount() > LAUNCH.MaxActive do
		local weakest: string? = nil
		local weakestCap = math.huge
		for ticker, entry in active do
			if now - entry.CreatedAt < PRUNE_MIN_AGE or PlayerData.hasStake(ticker) then
				continue
			end
			local cap = Market.marketCap(ticker)
			if cap < weakestCap then
				weakest, weakestCap = ticker, cap
			end
		end
		if not weakest or not deactivate(weakest) then
			return
		end
	end
end

local function progress(ticker: string, entry: Entry): number
	if entry.Migrated then
		return 100
	end
	local cap = Market.marketCap(ticker)
	local span = LAUNCH.MigrationMarketCap - LAUNCH.StartMarketCap
	return math.clamp((cap - LAUNCH.StartMarketCap) / span * 100, 0, 100)
end

function Launchpad.info(ticker: string): Types.LaunchInfo?
	local entry = active[ticker]
	local def = Coins.get(ticker)
	if not entry or not def then
		return nil
	end
	return {
		Name = entry.Name,
		Color = def.Color,
		Creator = entry.Creator,
		Progress = progress(ticker, entry),
		Migrated = entry.Migrated,
		MigratedAt = entry.MigratedAt,
	}
end

local function notifyAll(kind: "Success" | "Error" | "Info", text: string, except: Player?)
	for _, player in Players:GetPlayers() do
		if player ~= except then
			Remotes.Notify:FireClient(player, { Kind = kind, Text = text })
		end
	end
end

-- Wykrywa migracje; wywoływane w każdym ticku serwera.
function Launchpad.tick()
	for ticker, entry in active do
		if not entry.Migrated and Market.marketCap(ticker) >= LAUNCH.MigrationMarketCap then
			entry.Migrated = true
			entry.MigratedAt = Market.now()
			pending[ticker] = true
			notifyAll("Success", `{ticker} completed its bonding curve and migrated`)
		end
	end
end

-- Usuwa nadmiar wpisów: najpierw najdawniej aktywne niemigrowane, potem najstarsze migrowane.
local function trim(entries: { [string]: any })
	local list = {}
	for ticker, e in entries do
		local valid = typeof(e) == "table"
		table.insert(list, {
			Ticker = ticker,
			Migrated = valid and e.Migrated == true,
			At = if valid and finite(e.UpdatedAt) then e.UpdatedAt else 0,
		})
	end
	if #list <= MAX_ENTRIES then
		return
	end
	table.sort(list, function(a, b)
		if a.Migrated ~= b.Migrated then
			return not a.Migrated
		end
		return a.At < b.At
	end)
	for i = 1, #list - MAX_ENTRIES do
		entries[list[i].Ticker] = nil
	end
end

-- Dopisuje coiny stworzone na innych serwerach; świeże od razu trafiają na rynek.
local function merge(entries: { [string]: any })
	local now = Market.now()
	for ticker, raw in entries do
		local entry = sanitizeEntry(raw)
		if not entry then
			continue
		end
		local mine = known[ticker]
		if not mine then
			known[ticker] = entry
			if now - entry.CreatedAt < FRESH_SECONDS and activeCount() < LAUNCH.MaxActive then
				activate(entry)
			end
		elseif entry.Migrated and not mine.Migrated then
			-- Migracja jest trwała: coin zmigrowany gdziekolwiek jest zmigrowany wszędzie.
			mine.Migrated = true
			mine.MigratedAt = entry.MigratedAt
		end
	end
end

local function save()
	local changes: { [string]: Entry } = {}
	for ticker, entry in active do
		local state = Market.get(ticker)
		if state and (pending[ticker] or state.Pool.Rx ~= savedRx[ticker]) then
			capture(entry)
			changes[ticker] = table.clone(entry)
		end
	end
	for ticker in pending do
		local entry = known[ticker]
		if entry and not changes[ticker] then
			changes[ticker] = table.clone(entry)
		end
	end

	local function done()
		for ticker, entry in changes do
			savedRx[ticker] = entry.Rx
			pending[ticker] = nil
		end
	end

	local current = store
	if not current then
		done()
		return
	end
	local incoming: { [string]: any }? = nil
	local ok, err = pcall(current.UpdateAsync, current, KEY, function(old: any)
		local data = if typeof(old) == "table" and typeof(old.Coins) == "table" then old else { Coins = {} }
		for ticker, entry in changes do
			local previous = data.Coins[ticker]
			local write = table.clone(entry)
			if typeof(previous) == "table" and previous.Migrated == true and not write.Migrated then
				write.Migrated = true
				write.MigratedAt = previous.MigratedAt
			end
			data.Coins[ticker] = write
		end
		trim(data.Coins)
		incoming = data.Coins
		return data
	end)
	if not ok then
		warn("[RXIOM] Failed to save Pulse coins:", err)
		return
	end
	done()
	if incoming then
		merge(incoming)
	end
end

-- Wczytuje rejestr i wystawia na rynek najnowsze coiny. Blokuje do końca odczytu, żeby profile
-- graczy wczytywały się już ze znanymi coinami.
function Launchpad.load()
	Market.setLaunchProvider(Launchpad.info)
	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, STORE_NAME)
	if not ok then
		warn("[RXIOM] DataStore unavailable, Pulse coins will not be saved:", result)
		return
	end
	store = result
	local attempts = if RunService:IsStudio() then 1 else 3
	local loaded = false
	for attempt = 1, attempts do
		local success, data = pcall(result.GetAsync, result, KEY)
		if success then
			loaded = true
			local entries = if typeof(data) == "table" and typeof(data.Coins) == "table" then data.Coins else {}
			for _, raw in entries do
				local entry = sanitizeEntry(raw)
				if entry then
					known[entry.Ticker] = entry
				end
			end
			break
		end
		warn(`[RXIOM] Failed to load Pulse coins (attempt {attempt}):`, data)
		if attempt < attempts then
			task.wait(attempt)
		end
	end
	if not loaded and RunService:IsStudio() then
		-- Studio bez dostępu do API: coiny działają tylko w tej sesji.
		warn("[RXIOM] Pulse coins will not be saved in this Studio session")
		store = nil
	end

	local recent = {}
	for _, entry in known do
		table.insert(recent, entry)
	end
	table.sort(recent, function(a, b)
		return a.UpdatedAt > b.UpdatedAt
	end)
	for i = 1, math.min(LAUNCH.MaxActive, #recent) do
		activate(recent[i])
	end
end

-- Wystawia na rynek coiny, w których gracz ma pozycje lub zlecenia (przed odtworzeniem zleceń).
function Launchpad.ensureActive(player: Player)
	local profile = PlayerData.get(player)
	if not profile then
		return
	end
	local tickers: { [string]: boolean } = {}
	for ticker in profile.Positions do
		tickers[ticker] = true
	end
	for _, order in profile.Orders do
		tickers[order.Ticker] = true
	end
	for ticker in tickers do
		local entry = known[ticker]
		if entry and not Market.get(ticker) then
			activate(entry)
		end
	end
end

local function filtered(text: string, player: Player): string?
	local ok, result = pcall(function()
		local filter = TextService:FilterStringAsync(text, player.UserId, Enum.TextFilterContext.PublicChat)
		return filter:GetNonChatStringForBroadcastAsync()
	end)
	if ok then
		return result
	end
	-- Filtr nie działa w Studio bez dostępu do API; poza Studio odrzucamy niesprawdzony tekst.
	return if RunService:IsStudio() then text else nil
end

local function createCoin(player: Player, request: any): ActionResult
	local profile = PlayerData.get(player)
	if not profile then
		return fail("Your data is still loading")
	end
	local last = lastLaunch[player.UserId]
	if last and os.clock() - last < LAUNCH.Cooldown then
		return fail(`You can launch another coin in {math.ceil(LAUNCH.Cooldown - (os.clock() - last))}s`)
	end
	if typeof(request) ~= "table" or typeof(request.Name) ~= "string" or typeof(request.Ticker) ~= "string" then
		return fail("Invalid request")
	end
	local name = string.gsub(string.gsub(request.Name, "^%s+", ""), "%s+$", "")
	name = string.gsub(name, "%s+", " ")
	local ticker = string.upper(request.Ticker)
	local colorIndex = request.Color
	if not Coins.validName(name) then
		return fail("Name must be 2-24 letters, digits or spaces")
	end
	if not Coins.validTicker(ticker) then
		return fail("Ticker must be 2-8 letters or digits")
	end
	if typeof(colorIndex) ~= "number" or not LAUNCH.Colors[colorIndex] then
		return fail("Pick a color")
	end
	if Coins.get(ticker) or known[ticker] then
		return fail(`{ticker} is already taken`)
	end
	local fee = Upgrades.value(profile.Upgrades, "LaunchDiscount")
	if profile.Balance + 1e-9 < fee then
		return fail(`Creating a coin costs {fee} {Config.Currency}`)
	end

	-- Opłata i cooldown od razu, przed czekaniem na filtr i zapis, żeby nie dało się kliknąć dwa razy.
	lastLaunch[player.UserId] = os.clock()
	profile.Balance -= fee
	local function abort(message: string): ActionResult
		profile.Balance += fee
		lastLaunch[player.UserId] = nil
		pushPortfolio(player)
		return fail(message)
	end

	local cleanName, cleanTicker = filtered(name, player), filtered(ticker, player)
	if not cleanName or not cleanTicker then
		return abort("Couldn't check the name, try again")
	end
	if cleanName ~= name or cleanTicker ~= ticker then
		return abort("That name or ticker isn't allowed")
	end
	if player.Parent == nil then
		return abort("Left the game")
	end
	if Coins.get(ticker) or known[ticker] then
		return abort(`{ticker} is already taken`)
	end

	local now = Market.now()
	local entry: Entry = {
		Ticker = ticker,
		Name = name,
		Color = LAUNCH.Colors[colorIndex],
		Creator = player.DisplayName,
		CreatorId = player.UserId,
		CreatedAt = now,
		Rx = LAUNCH.PoolRx,
		Tokens = LAUNCH.PoolRx / START_PRICE,
		Migrated = false,
		UpdatedAt = now,
	}

	-- Rezerwacja tickera w rejestrze (wspólnym dla wszystkich serwerów).
	local current = store
	if current then
		local taken = false
		local ok, err = pcall(current.UpdateAsync, current, KEY, function(old: any)
			local data = if typeof(old) == "table" and typeof(old.Coins) == "table" then old else { Coins = {} }
			taken = data.Coins[ticker] ~= nil
			if taken then
				return nil
			end
			data.Coins[ticker] = table.clone(entry)
			trim(data.Coins)
			return data
		end)
		if not ok then
			warn("[RXIOM] Failed to register coin:", err)
			return abort("Couldn't create the coin, try again")
		end
		if taken then
			return abort(`{ticker} is already taken`)
		end
		if Coins.get(ticker) then
			-- Ten sam ticker zdążył się pojawić z innego serwera podczas zapisu.
			return abort(`{ticker} is already taken`)
		end
	end

	known[ticker] = entry
	activate(entry)
	Snipers.onLaunch(ticker, player)
	prune()
	pushPortfolio(player)
	notifyAll("Info", `{player.DisplayName} launched {ticker} on Pulse`, player)
	-- Pulse Radar: gracze z tym ulepszeniem dostają baner z przyciskiem do szybkiego zakupu.
	for _, other in Players:GetPlayers() do
		local otherProfile = PlayerData.get(other)
		if other ~= player and otherProfile and Upgrades.level(otherProfile.Upgrades, "Radar") > 0 then
			Remotes.PulseRadar:FireClient(other, { Ticker = ticker, Name = name, Creator = player.DisplayName })
		end
	end
	return { Ok = true, Ticker = ticker }
end

-- `push` wysyła graczowi aktualny portfel (po pobraniu opłaty).
function Launchpad.start(push: (player: Player) -> ())
	pushPortfolio = push
	Remotes.CreateCoin.OnServerInvoke = createCoin
	Snipers.start()
	task.spawn(function()
		while true do
			task.wait(SAVE_SECONDS)
			save()
			prune()
		end
	end)
	game:BindToClose(save)
end

-- Do testów: wpisy na rynku tego serwera.
function Launchpad.active(): { [string]: Entry }
	return active
end

Launchpad.save = save

return Launchpad
