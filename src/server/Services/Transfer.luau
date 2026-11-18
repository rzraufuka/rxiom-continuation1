--!strict
-- Przelewy RXI między graczami: po nazwie użytkownika Roblox, nazwie wyświetlanej gracza na
-- serwerze albo adresie portfela Ghostbox.
--
-- Każdy przelew trafia do "skrzynki" odbiorcy w DataStore i jest księgowany na jego serwerze: od
-- razu, gdy jest na tym samym, po powiadomieniu przez MessagingService, gdy gra gdzie indziej, albo
-- przy następnym wejściu. ID zaksięgowanego przelewu trafia do profilu odbiorcy i dopiero po jego
-- zapisie przelew znika ze skrzynki, więc nie przepada ani nie zostaje zaksięgowany dwa razy.
--
-- Prywatność: podgląd odbiorcy po samym adresie portfela nie zdradza nazwy prywatnego gracza.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserService = game:GetService("UserService")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local PlayerData = require(script.Parent.PlayerData)

type ActionResult = Types.ActionResult

type Entry = { Id: string, FromId: number, From: string, Amount: number, At: number }

-- Rozpoznany odbiorca. ShowName: czy nadawca może zobaczyć nazwę (sam ją wpisał albo profil publiczny).
type Target = {
	UserId: number,
	Name: string,
	DisplayName: string,
	Wallet: string?,
	Player: Player?,
	ShowName: boolean,
}

local INBOX_STORE = "RXIOM_Inbox_v1"
local WALLET_STORE = "RXIOM_Wallets_v1"
local TOPIC = "RXIOM_Transfers"
local MAX_INBOX = 50
local CLAIM_SECONDS = 30
-- Kwoty z dokładnością do milionowej części RXI.
local PRECISION = 1e6

local Transfer = {}

local inbox: DataStore? = nil
local wallets: DataStore? = nil
local claiming: { [Player]: boolean } = {}
local indexed: { [Player]: boolean } = {}
local lastCall: { [Player]: { [string]: number } } = {}
local pushPortfolio: (player: Player) -> () = function() end

local function fail(message: string): ActionResult
	return { Ok = false, Error = message }
end

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

local function shortWallet(wallet: string): string
	return string.sub(wallet, 1, 4) .. "..." .. string.sub(wallet, -4)
end

local function trim(text: string): string
	return (string.gsub(string.gsub(text, "^%s+", ""), "%s+$", ""))
end

local function userInfo(userId: number): (string?, string?)
	local ok, infos = pcall(UserService.GetUserInfosByUserIdsAsync, UserService, { userId })
	if ok and typeof(infos) == "table" and infos[1] then
		return infos[1].Username, infos[1].DisplayName
	end
	local nameOk, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	if nameOk and typeof(name) == "string" then
		return name, name
	end
	return nil, nil
end

local function onlineTarget(player: Player, showName: boolean): Target
	local profile = PlayerData.get(player)
	return {
		UserId = player.UserId,
		Name = player.Name,
		DisplayName = player.DisplayName,
		Wallet = if profile then profile.Wallet else nil,
		Player = player,
		ShowName = showName,
	}
end

-- Rozpoznaje odbiorcę z wpisanego tekstu. Zwraca odbiorcę albo komunikat błędu.
local function resolve(sender: Player, query: any): (Target?, string?)
	if typeof(query) ~= "string" then
		return nil, "Enter a username or wallet address"
	end
	local q = trim(query)
	if #q < 2 or #q > 40 then
		return nil, "Enter a username or wallet address"
	end

	local target: Target? = nil
	if PlayerData.isWallet(q) then
		for _, player in Players:GetPlayers() do
			local profile = PlayerData.get(player)
			if profile and profile.Wallet == q then
				target = onlineTarget(player, profile.Public)
				break
			end
		end
		local store = wallets
		if not target and store then
			local ok, id = pcall(store.GetAsync, store, "w_" .. q)
			if not ok then
				return nil, "Couldn't look up the wallet, try again"
			end
			if typeof(id) == "number" then
				local name, displayName = userInfo(id)
				if not name or not displayName then
					return nil, "Couldn't look up the wallet, try again"
				end
				target = { UserId = id, Name = name, DisplayName = displayName, Wallet = q, ShowName = false }
			end
		end
		if not target then
			return nil, "No RXIOM wallet with this address"
		end
	else
		local needle = string.lower(q)
		local byDisplay: { Player } = {}
		for _, player in Players:GetPlayers() do
			if string.lower(player.Name) == needle then
				target = onlineTarget(player, true)
				break
			elseif string.lower(player.DisplayName) == needle then
				table.insert(byDisplay, player)
			end
		end
		if not target and #byDisplay == 1 then
			target = onlineTarget(byDisplay[1], true)
		elseif not target and #byDisplay > 1 then
			return nil, `Several players are called {q}, use their username`
		end
		if not target then
			if not string.find(q, "^[%w_]+$") or #q < 3 or #q > 20 then
				return nil, "No player with this name"
			end
			local ok, id = pcall(Players.GetUserIdFromNameAsync, Players, q)
			if not ok or typeof(id) ~= "number" then
				return nil, "No player with this name"
			end
			local exists = PlayerData.exists(id)
			if exists == nil then
				return nil, "Couldn't look up the player, try again"
			elseif not exists then
				return nil, `{q} hasn't played RXIOM yet`
			end
			local name, displayName = userInfo(id)
			target = { UserId = id, Name = name or q, DisplayName = displayName or q, ShowName = true }
		end
	end

	local found = target :: Target
	-- Przelew do siebie jest tylko podglądem animacji (nic się nie przesuwa), więc nazwa zawsze widoczna.
	if found.UserId == sender.UserId then
		found.ShowName = true
	end
	return found, nil
end

local function label(target: Target): string
	if target.ShowName then
		return target.DisplayName
	end
	return shortWallet(target.Wallet or "")
end

------------------------------------------------------------------
-- Skrzynka odbiorcy

local function validEntry(e: any): boolean
	return typeof(e) == "table"
		and typeof(e.Id) == "string"
		and finite(e.Amount)
		and e.Amount > 0
		and typeof(e.From) == "string"
end

-- Księguje przelewy ze skrzynki gracza. Tymczasowy profil (nieudane wczytanie) nic nie księguje,
-- bo nie zostałby zapisany, a gracz mógłby te środki przesłać dalej.
function Transfer.claim(player: Player)
	local store = inbox
	local profile = PlayerData.get(player)
	if not store or not profile or claiming[player] or not PlayerData.canSave(player) then
		return
	end
	claiming[player] = true
	local ok, data = pcall(store.GetAsync, store, "u_" .. player.UserId)
	local entries = if ok and typeof(data) == "table" and typeof(data.Entries) == "table" then data.Entries else {}
	if #entries == 0 then
		claiming[player] = nil
		return
	end

	local credited = false
	for _, e in entries do
		if validEntry(e) and not table.find(profile.Received, e.Id) then
			profile.Balance += e.Amount
			table.insert(profile.Received, e.Id)
			credited = true
			Remotes.TransferReceived:FireClient(player, { Amount = e.Amount, From = string.sub(e.From, 1, 32) })
		end
	end
	while #profile.Received > PlayerData.MaxReceived do
		table.remove(profile.Received, 1)
	end
	if credited then
		pushPortfolio(player)
	end

	-- Ze skrzynki usuwamy dopiero przelewy zapisane już w profilu.
	if PlayerData.saveNow(player) then
		local done: { [string]: boolean } = {}
		for _, id in profile.Received do
			done[id] = true
		end
		pcall(store.UpdateAsync, store, "u_" .. player.UserId, function(old: any)
			if typeof(old) ~= "table" or typeof(old.Entries) ~= "table" then
				return nil
			end
			local keep = {}
			for _, e in old.Entries do
				if not (validEntry(e) and done[e.Id]) then
					table.insert(keep, e)
				end
			end
			old.Entries = keep
			return old
		end)
	end
	claiming[player] = nil
end

-- Wrzuca przelew do skrzynki odbiorcy. Zwraca komunikat błędu albo nil.
local function deliver(target: Target, entry: Entry): string?
	local store = inbox
	if not store then
		-- Bez DataStore (Studio bez API) przelew działa tylko do gracza na tym serwerze.
		local player = target.Player
		local profile = if player then PlayerData.get(player) else nil
		if not player or not profile then
			return "The recipient must be on this server (saving is off in Studio)"
		end
		profile.Balance += entry.Amount
		Remotes.TransferReceived:FireClient(player, { Amount = entry.Amount, From = entry.From })
		pushPortfolio(player)
		return nil
	end
	local full = false
	local ok = pcall(store.UpdateAsync, store, "u_" .. target.UserId, function(old: any)
		local data = if typeof(old) == "table" and typeof(old.Entries) == "table" then old else { Entries = {} }
		full = #data.Entries >= MAX_INBOX
		if full then
			return nil
		end
		table.insert(data.Entries, entry)
		return data
	end)
	if not ok then
		return "Couldn't send, try again"
	end
	if full then
		return "The recipient has too many pending transfers, try later"
	end
	return nil
end

------------------------------------------------------------------
-- Akcje gracza

local function findRecipient(sender: Player, query: any): Types.RecipientInfo
	if not throttle(sender, "find", 0.4) then
		return { Ok = false, Error = "Slow down" }
	end
	local target, err = resolve(sender, query)
	if not target then
		return { Ok = false, Error = err }
	end
	if target.ShowName then
		return {
			Ok = true,
			UserId = target.UserId,
			Name = target.Name,
			DisplayName = target.DisplayName,
			Wallet = target.Wallet,
			Online = target.Player ~= nil,
			Self = target.UserId == sender.UserId,
		}
	end
	return { Ok = true, Wallet = target.Wallet }
end

local function send(sender: Player, request: any): ActionResult
	local profile = PlayerData.get(sender)
	if not profile then
		return fail("Your data is still loading")
	end
	if PlayerData.persistent() and not PlayerData.canSave(sender) then
		return fail("Your data didn't load, rejoin to send RXI")
	end
	if typeof(request) ~= "table" or not finite(request.Amount) then
		return fail("Enter an amount")
	end
	local amount = math.floor(request.Amount * PRECISION) / PRECISION
	if amount < Config.MinTradeRx then
		return fail(`Minimum is {Config.MinTradeRx} {Config.Currency}`)
	end
	if amount > profile.Balance + 1e-9 then
		return fail("Insufficient balance")
	end
	if not throttle(sender, "send", 2) then
		return fail("Wait a moment before sending again")
	end
	local target, err = resolve(sender, request.To)
	if not target then
		return fail(err or "Recipient not found")
	end
	-- Saldo mogło się zmienić podczas szukania odbiorcy.
	if amount > profile.Balance + 1e-9 then
		return fail("Insufficient balance")
	end
	if target.UserId == sender.UserId then
		return { Ok = true, Rx = amount, To = "yourself", Self = true }
	end

	profile.Balance = math.max(0, profile.Balance - amount)
	pushPortfolio(sender)
	local entry: Entry = {
		Id = HttpService:GenerateGUID(false),
		FromId = sender.UserId,
		From = sender.DisplayName,
		Amount = amount,
		At = workspace:GetServerTimeNow(),
	}
	local deliveryError = deliver(target, entry)
	if deliveryError then
		profile.Balance += amount
		pushPortfolio(sender)
		return fail(deliveryError)
	end

	-- Zapis nadawcy od razu, żeby awaria serwera nie przywróciła mu wysłanych środków.
	task.spawn(PlayerData.saveNow, sender)
	local recipient = target.Player
	if inbox then
		if recipient and recipient.Parent then
			task.spawn(Transfer.claim, recipient)
		else
			task.spawn(function()
				pcall(MessagingService.PublishAsync, MessagingService, TOPIC, target.UserId)
			end)
		end
	end
	return { Ok = true, Rx = amount, To = label(target) }
end

-- Zapisuje adres portfela gracza w indeksie (raz na sesję), żeby dało się mu wysłać RXI po adresie.
function Transfer.indexWallet(player: Player, wallet: string)
	local store = wallets
	if not store or indexed[player] or not PlayerData.canSave(player) then
		return
	end
	if pcall(store.SetAsync, store, "w_" .. wallet, player.UserId) then
		indexed[player] = true
	end
end

function Transfer.release(player: Player)
	claiming[player] = nil
	indexed[player] = nil
	lastCall[player] = nil
end

function Transfer.start(push: (player: Player) -> ())
	pushPortfolio = push
	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, INBOX_STORE)
	if ok and PlayerData.persistent() then
		inbox = result
	end
	local walletOk, walletStore = pcall(DataStoreService.GetDataStore, DataStoreService, WALLET_STORE)
	if walletOk and PlayerData.persistent() then
		wallets = walletStore
	end

	Remotes.FindRecipient.OnServerInvoke = findRecipient
	Remotes.SendRxi.OnServerInvoke = send

	PlayerData.Loaded:Connect(function(player: Player)
		Transfer.claim(player)
	end)
	task.spawn(function()
		pcall(MessagingService.SubscribeAsync, MessagingService, TOPIC, function(message)
			local id = message.Data
			if typeof(id) == "number" then
				local player = Players:GetPlayerByUserId(id)
				if player then
					Transfer.claim(player)
				end
			end
		end)
	end)
	task.spawn(function()
		while true do
			task.wait(CLAIM_SECONDS)
			for _, player in Players:GetPlayers() do
				task.spawn(Transfer.claim, player)
			end
		end
	end)
end

-- Do testów.
Transfer.send = send
Transfer.findRecipient = findRecipient

return Transfer
