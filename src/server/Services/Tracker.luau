--!strict
-- Wallet Tracker: publiczne profile graczy (wartość portfela, zrealizowany PnL, wolumen, liczba
-- transakcji, ulubione tokeny) i ranking po zrealizowanym PnL.
--
-- Prywatność: profil jest prywatny, dopóki gracz sam go nie upubliczni. Prywatny profil nie zdradza
-- żadnych liczb ani adresu portfela (także wyszukiwanie po adresie go nie znajduje), nie trafia do
-- rankingu, a w listach transakcji gracz widnieje pod anonimowym adresem. Upublicznione dane
-- trafiają do DataStore, żeby było je widać, gdy gracz jest offline; przejście na prywatny od razu
-- je usuwa.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserService = game:GetService("UserService")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local PlayerData = require(script.Parent.PlayerData)
local Stats = require(script.Parent.Stats)

type WalletProfile = Types.WalletProfile
type LeaderboardEntry = Types.LeaderboardEntry

-- Dane publicznego profilu zapisywane w DataStore (bez salda i pozycji).
type Record = {
	UserId: number,
	Name: string,
	DisplayName: string,
	Wallet: string?,
	Value: number,
	Realized: number,
	Volume: number,
	Trades: number,
	Favorites: { Types.FavoriteToken },
	UpdatedAt: number,
}

local PUBLIC_STORE = "RXIOM_Public_v1"
local BOARD_STORE = "RXIOM_Leaderboard_v1"
local PUBLISH_SECONDS = 60
local BOARD_REFRESH_SECONDS = 60
-- Ranking liczy pozycje w tylu najlepszych publicznych graczach; dalej to "poza rankingiem".
local BOARD_SIZE = 100
local BOARD_SHOWN = 25
local MAX_RESULTS = 10
local FAVORITES = 5
local RECORD_CACHE_SECONDS = 30
-- OrderedDataStore przyjmuje liczby całkowite: ranking w tysięcznych RXI.
local SCALE = 1000
local BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

local Tracker = {}

local publicStore: DataStore? = nil
local boardStore: OrderedDataStore? = nil
local aliases: { [Player]: string } = {}
-- Podpis ostatnio opublikowanych danych gracza; "private" po usunięciu z DataStore.
local published: { [number]: string } = {}
local storedBoard: { { UserId: number, Realized: number } } = {}
local names: { [number]: { Name: string, DisplayName: string } } = {}
local recordCache: { [number]: { At: number, Record: Record? } } = {}
local lastCall: { [Player]: { [string]: number } } = {}
local mergedBoard: { LeaderboardEntry }? = nil
local mergedAt = 0
local rng = Random.new()
local valueOf: (player: Player) -> number = function()
	return 0
end
local pushPortfolio: (player: Player) -> () = function() end

local function finite(v: any): boolean
	return typeof(v) == "number" and v == v and math.abs(v) ~= math.huge
end

local function throttle(player: Player, action: string, seconds: number): boolean
	local calls = lastCall[player] or {}
	lastCall[player] = calls
	local now = os.clock()
	if calls[action] and now - calls[action] < seconds then
		return false
	end
	calls[action] = now
	return true
end

-- Adres w stylu portfeli botów, więc prywatny gracz nie wyróżnia się w listach transakcji.
local function newAlias(): string
	local function part(n: number): string
		local chars = table.create(n)
		for i = 1, n do
			local index = rng:NextInteger(1, #BASE58)
			chars[i] = string.sub(BASE58, index, index)
		end
		return table.concat(chars)
	end
	return part(4) .. "..." .. part(4)
end

function Tracker.alias(player: Player): string
	local alias = aliases[player]
	if not alias then
		alias = newAlias()
		aliases[player] = alias
	end
	return alias
end

-- Nazwa gracza w listach transakcji: prawdziwa tylko przy publicznym profilu.
function Tracker.traderName(player: Player): string
	local profile = PlayerData.get(player)
	if profile and profile.Public then
		return player.DisplayName
	end
	return Tracker.alias(player)
end

function Tracker.record(player: Player, ticker: string, side: Types.Side, tokens: number, rx: number)
	local profile = PlayerData.get(player)
	if profile then
		Stats.record(profile.Stats, ticker, side, tokens, rx)
		mergedBoard = nil
	end
end

local function liveRecord(player: Player, profile: PlayerData.Profile): Record
	local stats = profile.Stats
	return {
		UserId = player.UserId,
		Name = player.Name,
		DisplayName = player.DisplayName,
		Wallet = profile.Wallet,
		Value = valueOf(player),
		Realized = stats.Realized,
		Volume = stats.Volume,
		Trades = stats.Trades,
		Favorites = Stats.favorites(stats, FAVORITES),
		UpdatedAt = workspace:GetServerTimeNow(),
	}
end

local function sanitizeRecord(userId: number, raw: any): Record?
	if
		typeof(raw) ~= "table"
		or typeof(raw.Name) ~= "string"
		or typeof(raw.DisplayName) ~= "string"
		or not finite(raw.Value)
		or not finite(raw.Realized)
		or not finite(raw.Volume)
		or not finite(raw.Trades)
	then
		return nil
	end
	local favorites: { Types.FavoriteToken } = {}
	if typeof(raw.Favorites) == "table" then
		for _, f in raw.Favorites do
			if typeof(f) == "table" and typeof(f.Ticker) == "string" and finite(f.Volume) and #favorites < FAVORITES then
				local ticker = Coins.rename(f.Ticker)
				local renamed = if ticker ~= f.Ticker then Coins.get(ticker) else nil
				table.insert(favorites, {
					Ticker = string.sub(ticker, 1, 8),
					Name = if renamed
						then renamed.Name
						elseif typeof(f.Name) == "string" then string.sub(f.Name, 1, 24)
						else nil,
					Volume = f.Volume,
				})
			end
		end
	end
	return {
		UserId = userId,
		Name = string.sub(raw.Name, 1, 32),
		DisplayName = string.sub(raw.DisplayName, 1, 32),
		Wallet = if PlayerData.isWallet(raw.Wallet) then raw.Wallet else nil,
		Value = raw.Value,
		Realized = raw.Realized,
		Volume = raw.Volume,
		Trades = raw.Trades,
		Favorites = favorites,
		UpdatedAt = if finite(raw.UpdatedAt) then raw.UpdatedAt else 0,
	}
end

------------------------------------------------------------------
-- Publikacja w DataStore

local function signature(record: Record): string
	local favorites = {}
	for _, f in record.Favorites do
		table.insert(favorites, f.Ticker)
	end
	return string.format(
		"%s|%.4f|%.4f|%.4f|%d|%s|%s",
		record.Wallet or "",
		record.Value,
		record.Realized,
		record.Volume,
		record.Trades,
		table.concat(favorites, ","),
		record.DisplayName
	)
end

local function unpublish(userId: number, wallet: string?)
	if published[userId] == "private" then
		return
	end
	local store, board = publicStore, boardStore
	local ok = true
	if store then
		ok = pcall(store.RemoveAsync, store, "u_" .. userId) and ok
		if wallet then
			ok = pcall(store.RemoveAsync, store, "w_" .. wallet) and ok
		end
	end
	if board then
		ok = pcall(board.RemoveAsync, board, "u_" .. userId) and ok
	end
	recordCache[userId] = nil
	if ok then
		published[userId] = "private"
	end
end

-- Zapisuje (albo usuwa) publiczne dane gracza. Tymczasowy profil, który się nie wczytał, nie jest
-- publikowany, żeby nie nadpisać prawdziwych danych.
local function publish(player: Player)
	local profile = PlayerData.get(player)
	if not profile or not PlayerData.canSave(player) then
		return
	end
	local userId = player.UserId
	if not profile.Public then
		unpublish(userId, profile.Wallet)
		return
	end
	local record = liveRecord(player, profile)
	local sig = signature(record)
	if published[userId] == sig then
		return
	end
	local store, board = publicStore, boardStore
	local ok = true
	if store then
		ok = pcall(store.SetAsync, store, "u_" .. userId, record) and ok
		if record.Wallet then
			ok = pcall(store.SetAsync, store, "w_" .. record.Wallet, userId) and ok
		end
	end
	if board then
		local score = math.floor(record.Realized * SCALE)
		if score > 0 then
			ok = pcall(board.SetAsync, board, "u_" .. userId, score) and ok
		else
			ok = pcall(board.RemoveAsync, board, "u_" .. userId) and ok
		end
	end
	recordCache[userId] = { At = os.clock(), Record = record }
	if ok then
		published[userId] = sig
	end
end

local function loadRecord(userId: number): Record?
	local cached = recordCache[userId]
	if cached and os.clock() - cached.At < RECORD_CACHE_SECONDS then
		return cached.Record
	end
	local store = publicStore
	local record: Record? = nil
	if store then
		local ok, raw = pcall(store.GetAsync, store, "u_" .. userId)
		if not ok then
			return nil
		end
		record = sanitizeRecord(userId, raw)
	end
	recordCache[userId] = { At = os.clock(), Record = record }
	return record
end

------------------------------------------------------------------
-- Ranking

local function rememberNames(ids: { number })
	local missing = {}
	for _, id in ids do
		if not names[id] then
			table.insert(missing, id)
		end
	end
	if #missing == 0 then
		return
	end
	local ok, infos = pcall(UserService.GetUserInfosByUserIdsAsync, UserService, missing)
	if ok and typeof(infos) == "table" then
		for _, info in infos do
			names[info.Id] = { Name = info.Username, DisplayName = info.DisplayName }
		end
	end
end

local function refreshBoard()
	local board = boardStore
	if not board then
		return
	end
	local ok, pages = pcall(board.GetSortedAsync, board, false, BOARD_SIZE, 1)
	if not ok then
		return
	end
	local list = {}
	local ids = {}
	for _, item in pages:GetCurrentPage() do
		local id = tonumber(string.match(item.key, "^u_(%d+)$"))
		if id and typeof(item.value) == "number" then
			table.insert(list, { UserId = id, Realized = item.value / SCALE })
			table.insert(ids, id)
		end
	end
	rememberNames(ids)
	storedBoard = list
	mergedBoard = nil
end

-- Ranking z DataStore uzupełniony bieżącymi danymi graczy na serwerze (prywatni wypadają od razu).
local function leaderboard(): { LeaderboardEntry }
	local cached = mergedBoard
	if cached and os.clock() - mergedAt < 5 then
		return cached
	end
	local scores: { [number]: number? } = {}
	for _, e in storedBoard do
		scores[e.UserId] = e.Realized
	end
	for _, player in Players:GetPlayers() do
		local profile = PlayerData.get(player)
		if profile then
			scores[player.UserId] = if profile.Public then profile.Stats.Realized else nil
			names[player.UserId] = { Name = player.Name, DisplayName = player.DisplayName }
		end
	end
	local list: { LeaderboardEntry } = {}
	for id, score in scores do
		local known = names[id]
		local realized = score or 0
		if realized > 0 and known then
			table.insert(
				list,
				{ Rank = 0, UserId = id, Name = known.Name, DisplayName = known.DisplayName, Realized = realized }
			)
		end
	end
	table.sort(list, function(a, b)
		if a.Realized ~= b.Realized then
			return a.Realized > b.Realized
		end
		return a.UserId < b.UserId
	end)
	for i = #list, BOARD_SIZE + 1, -1 do
		list[i] = nil
	end
	for i, entry in list do
		entry.Rank = i
	end
	mergedBoard = list
	mergedAt = os.clock()
	return list
end

local function rankOf(userId: number): number?
	for _, entry in leaderboard() do
		if entry.UserId == userId then
			return entry.Rank
		end
	end
	return nil
end

------------------------------------------------------------------
-- Profile

local function fromRecord(record: Record, online: boolean): WalletProfile
	return {
		UserId = record.UserId,
		Name = record.Name,
		DisplayName = record.DisplayName,
		Public = true,
		Online = online,
		Wallet = record.Wallet,
		Value = record.Value,
		Realized = record.Realized,
		Volume = record.Volume,
		Trades = record.Trades,
		Favorites = record.Favorites,
		Rank = rankOf(record.UserId),
		UpdatedAt = record.UpdatedAt,
	}
end

local function privateProfile(userId: number, name: string, displayName: string, online: boolean): WalletProfile
	return { UserId = userId, Name = name, DisplayName = displayName, Public = false, Online = online }
end

-- Profil widziany przez `viewer`. Pełne dane tylko dla publicznych profili i dla samego siebie.
local function profileFor(viewer: Player, userId: number): WalletProfile?
	local player = Players:GetPlayerByUserId(userId)
	local profile = if player then PlayerData.get(player) else nil
	if player and profile then
		if profile.Public or player == viewer then
			local result = fromRecord(liveRecord(player, profile), true)
			result.Public = profile.Public
			result.UpdatedAt = nil
			if not profile.Public then
				result.Rank = nil
			end
			return result
		end
		return privateProfile(userId, player.Name, player.DisplayName, true)
	end
	local record = loadRecord(userId)
	if record then
		return fromRecord(record, player ~= nil)
	end
	-- Gracz prywatny albo bez profilu RXIOM; obu przypadków celowo nie rozróżniamy.
	rememberNames({ userId })
	local known = names[userId]
	if not known then
		return nil
	end
	return privateProfile(userId, known.Name, known.DisplayName, player ~= nil)
end

local function trim(text: string): string
	return (string.gsub(string.gsub(text, "^%s+", ""), "%s+$", ""))
end

local function search(viewer: Player, query: any): Types.WalletSearch
	if typeof(query) ~= "string" then
		return { Ok = false, Error = "Invalid search", Results = {} }
	end
	local q = trim(query)
	if #q < 2 or #q > 32 then
		return { Ok = false, Error = "Type at least 2 characters", Results = {} }
	end
	if not throttle(viewer, "search", 1) then
		return { Ok = false, Error = "Searching too fast, wait a moment", Results = {} }
	end

	local results: { WalletProfile } = {}
	local seen: { [number]: boolean } = {}
	local function add(userId: number)
		if seen[userId] or #results >= MAX_RESULTS then
			return
		end
		seen[userId] = true
		local found = profileFor(viewer, userId)
		if found then
			table.insert(results, found)
		end
	end

	-- Adres portfela: tylko publiczne profile (i własny), żeby adres nie zdradzał prywatnego gracza.
	if PlayerData.isWallet(q) then
		for _, player in Players:GetPlayers() do
			local profile = PlayerData.get(player)
			if profile and profile.Wallet == q then
				if profile.Public or player == viewer then
					add(player.UserId)
				end
				return { Ok = true, Results = results }
			end
		end
		local store = publicStore
		if store then
			local ok, id = pcall(store.GetAsync, store, "w_" .. q)
			if ok and typeof(id) == "number" then
				local found = profileFor(viewer, id)
				if found and found.Public and found.Wallet == q then
					table.insert(results, found)
				end
			end
		end
		return { Ok = true, Results = results }
	end

	local needle = string.lower(q)
	local function matches(name: string, displayName: string): boolean
		return string.find(string.lower(name), needle, 1, true) ~= nil
			or string.find(string.lower(displayName), needle, 1, true) ~= nil
	end
	for _, player in Players:GetPlayers() do
		if matches(player.Name, player.DisplayName) then
			add(player.UserId)
		end
	end
	for _, entry in leaderboard() do
		if matches(entry.Name, entry.DisplayName) then
			add(entry.UserId)
		end
	end
	-- Dokładna nazwa użytkownika Roblox (gracze offline spoza rankingu).
	if #results < MAX_RESULTS and string.find(q, "^[%w_]+$") and #q >= 3 and #q <= 20 then
		local ok, id = pcall(Players.GetUserIdFromNameAsync, Players, q)
		if ok and typeof(id) == "number" then
			add(id)
		end
	end
	return { Ok = true, Results = results }
end

local function setPublic(player: Player, value: any): Types.ActionResult
	if typeof(value) ~= "boolean" then
		return { Ok = false, Error = "Invalid request" }
	end
	local profile = PlayerData.get(player)
	if not profile then
		return { Ok = false, Error = "Your data is still loading" }
	end
	if not throttle(player, "privacy", 2) then
		return { Ok = false, Error = "Wait a moment before changing this again" }
	end
	profile.Public = value
	-- Wymusza zapis albo usunięcie przy najbliższej publikacji.
	published[player.UserId] = nil
	mergedBoard = nil
	pushPortfolio(player)
	task.spawn(publish, player)
	return { Ok = true }
end

-- Publikuje dane gracza przed zapisem profilu przy wyjściu.
function Tracker.release(player: Player)
	publish(player)
	aliases[player] = nil
	lastCall[player] = nil
	mergedBoard = nil
end

-- `value` liczy wartość portfela gracza, `push` wysyła mu aktualny portfel.
function Tracker.start(value: (player: Player) -> number, push: (player: Player) -> ())
	valueOf = value
	pushPortfolio = push
	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, PUBLIC_STORE)
	if ok then
		publicStore = result
	end
	local boardOk, board = pcall(DataStoreService.GetOrderedDataStore, DataStoreService, BOARD_STORE)
	if boardOk then
		boardStore = board
	end

	Remotes.SearchWallets.OnServerInvoke = search
	Remotes.GetWalletProfile.OnServerInvoke = function(player: Player, userId: any): WalletProfile?
		if typeof(userId) ~= "number" or userId ~= math.floor(userId) or userId <= 0 then
			return nil
		end
		if not throttle(player, "profile", 0.25) then
			return nil
		end
		return profileFor(player, userId)
	end
	Remotes.GetLeaderboard.OnServerInvoke = function(player: Player): { LeaderboardEntry }
		if not throttle(player, "board", 1) then
			return {}
		end
		local list = leaderboard()
		return table.move(list, 1, math.min(#list, BOARD_SHOWN), 1, {})
	end
	Remotes.SetProfilePublic.OnServerInvoke = setPublic

	task.spawn(function()
		while true do
			refreshBoard()
			task.wait(BOARD_REFRESH_SECONDS)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(PUBLISH_SECONDS)
			for _, player in Players:GetPlayers() do
				task.spawn(publish, player)
			end
		end
	end)
	game:BindToClose(function()
		for _, player in Players:GetPlayers() do
			publish(player)
		end
	end)
end

-- Do testów.
Tracker.publish = publish
Tracker.refreshBoard = refreshBoard
Tracker.search = search
Tracker.profileFor = profileFor
Tracker.leaderboard = leaderboard
Tracker.setPublic = setPublic

return Tracker
