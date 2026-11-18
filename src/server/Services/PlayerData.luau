--!strict
-- Profile graczy (saldo RX i pozycje) z zapisem w DataStore.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Upgrades = require(ReplicatedStorage.Shared.Upgrades)
local Config = require(ReplicatedStorage.Shared.Config)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Types = require(ReplicatedStorage.Shared.Types)
local PerpEngine = require(script.Parent.PerpEngine)
local Stats = require(script.Parent.Stats)

export type Profile = {
	Balance: number,
	Positions: { [string]: Types.Position },
	-- Zlecenia z księgi; ich zarezerwowane RX/tokeny nie wchodzą do Balance/Positions.
	Orders: { Types.BookOrder },
	FaucetReadyAt: number,
	-- Adres portfela Ghostbox (24 znaki base58), nadawany przy pierwszym logowaniu.
	Wallet: string?,
	-- Czy statystyki są widoczne w Wallet Trackerze. Domyślnie nie: gracz musi sam się zgodzić.
	Public: boolean,
	Stats: Types.TradeStats,
	-- ID ostatnio zaksięgowanych przelewów przychodzących (ochrona przed podwójnym zaksięgowaniem).
	Received: { string },
	Perps: Types.PerpAccount,
	-- Czy gracz przeszedł (albo pominął) samouczek.
	TutorialDone: boolean,
	Alerts: { Types.PriceAlert },
	-- Poziomy kupionych ulepszeń (Upgrades.luau).
	Upgrades: { [string]: number },
}

local WALLET_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
local WALLET_LENGTH = 24
local walletRng = Random.new()

local function isWallet(value: any): boolean
	return typeof(value) == "string" and #value == WALLET_LENGTH and not string.find(value, "[^1-9A-HJ-NP-Za-km-z]")
end

local STORE_NAME = "RXIOM_Profiles_v1"
local AUTOSAVE_SECONDS = 60
-- Ile ID zaksięgowanych przelewów trzymać w profilu.
local MAX_RECEIVED = 200

local PlayerData = {}
PlayerData.Loaded = Signal.new() -- (player)
PlayerData.MaxReceived = MAX_RECEIVED

local profiles: { [Player]: Profile } = {}
-- Profil, którego nie udało się wczytać, nie jest zapisywany, żeby nie nadpisać prawdziwych danych.
local saveable: { [Player]: boolean } = {}

local store: DataStore? = nil
do
	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, STORE_NAME)
	if ok then
		store = result
	else
		warn("[RXIOM] DataStore unavailable, progress will not be saved:", result)
	end
end

local function key(player: Player): string
	return "u_" .. player.UserId
end

local function finite(v: any): boolean
	return typeof(v) == "number" and v == v and math.abs(v) ~= math.huge
end

local function defaultProfile(): Profile
	return {
		Balance = Config.StartingBalance,
		Positions = {},
		Orders = {},
		FaucetReadyAt = 0,
		Public = false,
		Stats = Stats.empty(),
		Received = {},
		Perps = PerpEngine.empty(),
		TutorialDone = false,
		Alerts = {},
		Upgrades = {},
	}
end

local function sanitizeOrder(o: any): Types.BookOrder?
	if
		typeof(o) ~= "table"
		or typeof(o.Id) ~= "string"
		or #o.Id > 64
		or typeof(o.Ticker) ~= "string"
		or not Coins.validTicker(o.Ticker)
		or (o.Side ~= "Buy" and o.Side ~= "Sell")
		or not finite(o.Price)
		or o.Price <= 0
		or not finite(o.Tokens)
	then
		return nil
	end
	return {
		Id = o.Id,
		Ticker = Coins.rename(o.Ticker),
		Side = o.Side,
		Price = o.Price,
		Tokens = math.max(0, o.Tokens),
		Filled = if finite(o.Filled) then math.max(0, o.Filled) else 0,
		Reserved = if o.Side == "Buy" and finite(o.Reserved) then math.max(0, o.Reserved) else 0,
		CreatedAt = if finite(o.CreatedAt) then o.CreatedAt else 0,
	}
end

local ALERT_KINDS = { Above = "Above", Below = "Below", Rise = "Above", Drop = "Below" }

local function sanitizeAlerts(raw: any): { Types.PriceAlert }
	local alerts: { Types.PriceAlert } = {}
	if typeof(raw) ~= "table" then
		return alerts
	end
	for _, a in raw do
		local direction = if typeof(a) == "table" then ALERT_KINDS[a.Kind] else nil
		if
			direction
			and typeof(a.Id) == "string"
			and #a.Id <= 64
			and typeof(a.Ticker) == "string"
			and Coins.validTicker(Coins.rename(a.Ticker))
			and finite(a.MarketCap)
			and a.MarketCap > 0
			and #alerts < Config.MaxAlerts
		then
			table.insert(alerts, {
				Id = a.Id,
				Ticker = Coins.rename(a.Ticker),
				Kind = a.Kind,
				Direction = direction,
				MarketCap = a.MarketCap,
				Percent = if finite(a.Percent) then a.Percent else nil,
				CreatedAt = if finite(a.CreatedAt) then a.CreatedAt else 0,
			})
		end
	end
	return alerts
end

local function sanitize(data: any): Profile
	if typeof(data) ~= "table" or not finite(data.Balance) then
		return defaultProfile()
	end
	local profile: Profile = {
		Balance = math.max(0, data.Balance),
		Positions = {},
		Orders = {},
		FaucetReadyAt = if finite(data.FaucetReadyAt) then data.FaucetReadyAt else 0,
		Wallet = if isWallet(data.Wallet) then data.Wallet else nil,
		Public = data.Public == true,
		Stats = Stats.empty(),
		Received = {},
		Perps = PerpEngine.empty(),
		TutorialDone = false,
		Alerts = {},
		Upgrades = {},
	}
	if typeof(data.Received) == "table" then
		for _, id in data.Received do
			if typeof(id) == "string" and #id <= 64 and #profile.Received < MAX_RECEIVED then
				table.insert(profile.Received, id)
			end
		end
	end
	local orderTickers: { [string]: boolean } = {}
	if typeof(data.Orders) == "table" then
		for _, o in data.Orders do
			local order = sanitizeOrder(o)
			if not order then
				continue
			end
			if order.Tokens <= Config.DustTokens then
				-- Zlecenie już wykonane: oddaj resztę rezerwy zamiast ją zgubić.
				profile.Balance += order.Reserved
			else
				table.insert(profile.Orders, order)
				orderTickers[order.Ticker] = true
			end
		end
	end
	if typeof(data.Positions) == "table" then
		for saved, p in data.Positions do
			local ticker = if typeof(saved) == "string" then Coins.rename(saved) else saved
			-- Coiny z Pulse mogą nie być jeszcze aktywne na tym serwerze, więc liczy się tylko format.
			if
				Coins.validTicker(ticker)
				and typeof(p) == "table"
				and finite(p.Tokens)
				and finite(p.BoughtRx)
				and finite(p.SoldRx)
				-- Pozycja ze wszystkimi tokenami w zleceniu sprzedaży też zostaje (historia, PnL).
				and (p.Tokens > Config.DustTokens or orderTickers[ticker])
			then
				local fills = {}
				if typeof(p.Fills) == "table" then
					for _, f in p.Fills do
						if
							typeof(f) == "table"
							and finite(f.T)
							and (f.Side == "Buy" or f.Side == "Sell")
							and finite(f.Price)
							and finite(f.Tokens)
						then
							table.insert(fills, { T = f.T, Side = f.Side, Price = f.Price, Tokens = f.Tokens })
						end
					end
				end
				while #fills > Config.MaxFills do
					table.remove(fills, 1)
				end
				local position: Types.Position = {
					Tokens = p.Tokens,
					BoughtRx = p.BoughtRx,
					SoldRx = p.SoldRx,
					BuyTokens = if finite(p.BuyTokens) then p.BuyTokens else 0,
					BuyValue = if finite(p.BuyValue) then p.BuyValue else 0,
					Fills = fills,
				}
				-- Dwa zapisane klucze mogą wskazywać ten sam coin po zmianie nazwy: sumujemy.
				local existing = profile.Positions[ticker]
				if existing then
					existing.Tokens += position.Tokens
					existing.BoughtRx += position.BoughtRx
					existing.SoldRx += position.SoldRx
					existing.BuyTokens += position.BuyTokens
					existing.BuyValue += position.BuyValue
				else
					profile.Positions[ticker] = position
				end
			end
		end
	end
	profile.Stats = Stats.sanitize(data.Stats, profile.Positions, profile.Orders)
	profile.Perps = PerpEngine.sanitize(data.Perps, workspace:GetServerTimeNow())
	profile.TutorialDone = data.TutorialDone == true
	profile.Alerts = sanitizeAlerts(data.Alerts)
	profile.Upgrades = Upgrades.sanitize(data.Upgrades)
	return profile
end

local function load(player: Player)
	local data: any = nil
	local ok = false
	if store then
		local attempts = if RunService:IsStudio() then 1 else 3
		for attempt = 1, attempts do
			local success, result = pcall(store.GetAsync, store, key(player))
			if success then
				data, ok = result, true
				break
			end
			warn(`[RXIOM] Failed to load data for {player.Name} (attempt {attempt}):`, result)
			if attempt < attempts then
				task.wait(attempt)
			end
		end
	end
	if player.Parent == nil then
		return
	end
	profiles[player] = sanitize(data)
	saveable[player] = ok
	if not ok then
		warn(`[RXIOM] Using a temporary profile for {player.Name}; it will not be saved.`)
	end
	PlayerData.Loaded:Fire(player)
end

local function save(player: Player): boolean
	local profile = profiles[player]
	if not profile or not saveable[player] or not store then
		return false
	end
	local payload = {
		Balance = profile.Balance,
		Positions = profile.Positions,
		Orders = profile.Orders,
		FaucetReadyAt = profile.FaucetReadyAt,
		Wallet = profile.Wallet,
		Public = profile.Public,
		Stats = profile.Stats,
		Received = profile.Received,
		Perps = profile.Perps,
		TutorialDone = profile.TutorialDone,
		Alerts = profile.Alerts,
		Upgrades = profile.Upgrades,
	}
	local ok, err = pcall(store.UpdateAsync, store, key(player), function()
		return payload
	end)
	if not ok then
		warn(`[RXIOM] Failed to save data for {player.Name}:`, err)
	end
	return ok
end

-- Zapisuje profil od razu (np. po przelewie). Zwraca true, gdy zapis się udał.
function PlayerData.saveNow(player: Player): boolean
	return save(player)
end

-- Czy profile są w ogóle zapisywane (false np. w Studio bez dostępu do API).
function PlayerData.persistent(): boolean
	return store ~= nil
end

-- Czy gracz ma zapisany profil RXIOM. nil, gdy nie da się tego sprawdzić.
function PlayerData.exists(userId: number): boolean?
	local current = store
	if not current then
		return nil
	end
	local ok, data = pcall(current.GetAsync, current, "u_" .. userId)
	if not ok then
		return nil
	end
	return data ~= nil
end

function PlayerData.get(player: Player): Profile?
	return profiles[player]
end

-- Czy profil gracza jest zapisywany (tymczasowego profilu nie publikujemy w Wallet Trackerze).
function PlayerData.canSave(player: Player): boolean
	return saveable[player] == true and store ~= nil
end

PlayerData.isWallet = isWallet

-- Czeka na wczytanie profilu (np. gdy gracz loguje się zaraz po wejściu).
function PlayerData.waitFor(player: Player, timeout: number): Profile?
	local deadline = os.clock() + timeout
	while not profiles[player] and player.Parent ~= nil and os.clock() < deadline do
		task.wait(0.1)
	end
	return profiles[player]
end

-- Zwraca adres portfela gracza, nadając nowy przy pierwszym logowaniu. Drugi wynik: czy nowy.
function PlayerData.ensureWallet(profile: Profile): (string, boolean)
	local existing = profile.Wallet
	if existing then
		return existing, false
	end
	local chars = table.create(WALLET_LENGTH)
	for i = 1, WALLET_LENGTH do
		local index = walletRng:NextInteger(1, #WALLET_ALPHABET)
		chars[i] = string.sub(WALLET_ALPHABET, index, index)
	end
	local wallet = table.concat(chars)
	profile.Wallet = wallet
	return wallet, true
end

function PlayerData.countHolders(ticker: string): number
	local count = 0
	for _, profile in profiles do
		local position = profile.Positions[ticker]
		if position and position.Tokens > Config.DustTokens then
			count += 1
		end
	end
	return count
end

-- Czy ktoś z graczy na serwerze ma w coinie pozycję (także zablokowaną w zleceniach) albo zlecenie.
function PlayerData.hasStake(ticker: string): boolean
	for _, profile in profiles do
		if profile.Positions[ticker] then
			return true
		end
		for _, order in profile.Orders do
			if order.Ticker == ticker then
				return true
			end
		end
	end
	return false
end

-- Zapisuje i usuwa profil gracza opuszczającego grę.
function PlayerData.release(player: Player)
	save(player)
	profiles[player] = nil
	saveable[player] = nil
end

function PlayerData.saveAll()
	local threads = 0
	for player in profiles do
		threads += 1
		task.spawn(function()
			save(player)
			threads -= 1
		end)
	end
	local deadline = os.clock() + 25
	while threads > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end

function PlayerData.start()
	Players.PlayerAdded:Connect(load)
	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_SECONDS)
			for player in profiles do
				task.spawn(save, player)
			end
		end
	end)
end

return PlayerData
