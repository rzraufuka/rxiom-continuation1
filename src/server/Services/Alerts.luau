--!strict
-- Alerty cenowe graczy: próg market capu (powyżej / poniżej) albo zmiana o X % od chwili
-- ustawienia. Serwer sprawdza je co sekundę na rynku tego serwera; alert, który zadziałał, znika
-- i gracz dostaje powiadomienie (baner z dźwiękiem). Alerty są zapisywane w profilu.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local Market = require(script.Parent.Market)
local PlayerData = require(script.Parent.PlayerData)

type ActionResult = Types.ActionResult

local MAX_PERCENT = 10_000

local Alerts = {}

local lastCall: { [Player]: number } = {}
local pushPortfolio: (player: Player) -> () = function() end

local function fail(message: string): ActionResult
	return { Ok = false, Error = message }
end

local function finite(v: any): boolean
	return typeof(v) == "number" and v == v and math.abs(v) ~= math.huge
end

local function create(player: Player, request: any): ActionResult
	local profile = PlayerData.get(player)
	if not profile then
		return fail("Your data is still loading")
	end
	local now = os.clock()
	if lastCall[player] and now - lastCall[player] < 0.25 then
		return fail("Slow down")
	end
	lastCall[player] = now
	if typeof(request) ~= "table" or typeof(request.Ticker) ~= "string" or not finite(request.Value) then
		return fail("Enter a value")
	end
	local ticker = request.Ticker
	local kind = request.Kind
	if not Coins.get(ticker) or not Market.get(ticker) then
		return fail("Unknown coin")
	end
	if #profile.Alerts >= Config.MaxAlerts then
		return fail(`You can have up to {Config.MaxAlerts} alerts`)
	end
	local current = Market.marketCap(ticker)
	local value = request.Value
	local alert: Types.PriceAlert
	local id = HttpService:GenerateGUID(false)
	local t = Market.now()
	if kind == "Above" or kind == "Below" then
		if value <= 0 then
			return fail("Enter a market cap")
		end
		if kind == "Above" and value <= current then
			return fail(`{ticker} is already above {Format.usd(value)}`)
		end
		if kind == "Below" and value >= current then
			return fail(`{ticker} is already below {Format.usd(value)}`)
		end
		alert = { Id = id, Ticker = ticker, Kind = kind, Direction = kind, MarketCap = value, CreatedAt = t }
	elseif kind == "Rise" or kind == "Drop" then
		if value <= 0 or value > MAX_PERCENT or (kind == "Drop" and value >= 100) then
			return fail(if kind == "Drop" then "Drop must be between 0 and 100%" else "Enter a percentage")
		end
		local factor = if kind == "Rise" then 1 + value / 100 else 1 - value / 100
		alert = {
			Id = id,
			Ticker = ticker,
			Kind = kind,
			Direction = if kind == "Rise" then "Above" else "Below",
			MarketCap = current * factor,
			Percent = value,
			CreatedAt = t,
		}
	else
		return fail("Pick an alert type")
	end
	table.insert(profile.Alerts, alert)
	pushPortfolio(player)
	return { Ok = true, Ticker = ticker }
end

local function delete(player: Player, id: any): ActionResult
	local profile = PlayerData.get(player)
	if not profile then
		return fail("Your data is still loading")
	end
	for i, alert in profile.Alerts do
		if alert.Id == id then
			table.remove(profile.Alerts, i)
			pushPortfolio(player)
			return { Ok = true, Ticker = alert.Ticker }
		end
	end
	return fail("Alert not found")
end

-- Sprawdza alerty jednego gracza; zwraca true, gdy któryś zadziałał.
function Alerts.check(player: Player): boolean
	local profile = PlayerData.get(player)
	if not profile or #profile.Alerts == 0 then
		return false
	end
	local fired = false
	local i = 1
	while i <= #profile.Alerts do
		local alert = profile.Alerts[i]
		local mc = if Market.get(alert.Ticker) then Market.marketCap(alert.Ticker) else nil
		if mc and (if alert.Direction == "Above" then mc >= alert.MarketCap else mc <= alert.MarketCap) then
			table.remove(profile.Alerts, i)
			fired = true
			Remotes.AlertTriggered:FireClient(player, {
				Ticker = alert.Ticker,
				Kind = alert.Kind,
				Target = alert.MarketCap,
				MarketCap = mc,
				Percent = alert.Percent,
			})
		else
			i += 1
		end
	end
	return fired
end

function Alerts.release(player: Player)
	lastCall[player] = nil
end

function Alerts.start(push: (player: Player) -> ())
	pushPortfolio = push
	Remotes.CreateAlert.OnServerInvoke = create
	Remotes.DeleteAlert.OnServerInvoke = delete
	task.spawn(function()
		while true do
			task.wait(1)
			for _, player in Players:GetPlayers() do
				if Alerts.check(player) then
					pushPortfolio(player)
				end
			end
		end
	end)
end

Alerts.create = create
Alerts.delete = delete

return Alerts
