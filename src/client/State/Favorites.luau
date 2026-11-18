--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Signal = require(ReplicatedStorage.Shared.Signal)

local Favorites = {}
Favorites.Changed = Signal.new()

local selected: { [string]: boolean } = {}
local ordered: { string } = {}
local inFlight: { [string]: boolean } = {}
local initialized = false

local function update(ticker: string, enabled: boolean, notify: boolean)
	local current = selected[ticker] == true
	if current == enabled then
		return
	end
	if enabled then
		selected[ticker] = true
		table.insert(ordered, ticker)
	else
		selected[ticker] = nil
		local index = table.find(ordered, ticker)
		if index then
			table.remove(ordered, index)
		end
	end
	if notify then
		Favorites.Changed:Fire(ticker, enabled)
	end
end

function Favorites.start(initial: { string }?)
	if initialized or typeof(initial) ~= "table" then
		return
	end
	initialized = true
	for _, saved in initial do
		if typeof(saved) == "string" then
			local ticker = Coins.rename(saved)
			if Coins.validTicker(ticker) then
				update(ticker, true, false)
			end
		end
	end
	Favorites.Changed:Fire()
end

function Favorites.has(ticker: string): boolean
	if not Coins.validTicker(ticker) then
		return false
	end
	return selected[Coins.rename(ticker)] == true
end

function Favorites.list(): { string }
	return table.clone(ordered)
end

function Favorites.set(ticker: string, enabled: boolean): (boolean, string?)
	if not Coins.validTicker(ticker) or typeof(enabled) ~= "boolean" then
		return false, "Invalid favorite request"
	end
	if not initialized then
		return false, "Your favorites are still loading. Try again."
	end
	ticker = Coins.rename(ticker)
	if inFlight[ticker] then
		return false, "Favorite update is in progress"
	end
	if (selected[ticker] == true) == enabled then
		return true, nil
	end
	inFlight[ticker] = true

	local callOk, success, message = pcall(function()
		return Remotes.SetFavorite:InvokeServer(ticker, enabled)
	end)
	inFlight[ticker] = nil
	if not callOk or success ~= true then
		return false, if callOk and typeof(message) == "string" then message else "Could not update favorites. Try again."
	end
	update(ticker, enabled, true)
	return true, nil
end

return Favorites
