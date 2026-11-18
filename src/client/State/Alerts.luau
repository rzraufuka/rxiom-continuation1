--!strict
-- Alerty cenowe po stronie klienta: tworzenie, usuwanie, lista i opis alertu.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Format = require(ReplicatedStorage.Shared.Format)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)

local Portfolio = require(script.Parent.Portfolio)
local Toast = require(script.Parent.Parent.UI.Toast)

local Alerts = {}

local function invoke(remote: RemoteFunction, payload: any): Types.ActionResult
	local ok, result = pcall(remote.InvokeServer, remote, payload)
	if not ok or typeof(result) ~= "table" then
		return { Ok = false, Error = "Connection problem, try again" }
	end
	return result
end

-- Opis warunku, np. "MC above $200K" albo "Rises 20% (MC $140K)".
function Alerts.describe(alert: Types.PriceAlert): string
	if alert.Kind == "Above" then
		return "MC above " .. Format.usd(alert.MarketCap)
	elseif alert.Kind == "Below" then
		return "MC below " .. Format.usd(alert.MarketCap)
	end
	local verb = if alert.Kind == "Rise" then "Rises" else "Drops"
	return `{verb} {Format.decimal(alert.Percent or 0)}% (MC {Format.usd(alert.MarketCap)})`
end

-- Tekst powiadomienia, gdy alert zadziała.
function Alerts.noticeText(notice: Types.AlertNotice): string
	local mc = Format.usd(notice.MarketCap)
	if notice.Kind == "Above" then
		return `Market cap went above {Format.usd(notice.Target)} (now {mc})`
	elseif notice.Kind == "Below" then
		return `Market cap dropped below {Format.usd(notice.Target)} (now {mc})`
	elseif notice.Kind == "Rise" then
		return `Up {Format.decimal(notice.Percent or 0)}% since you set the alert (MC {mc})`
	end
	return `Down {Format.decimal(notice.Percent or 0)}% since you set the alert (MC {mc})`
end

function Alerts.list(ticker: string?): { Types.PriceAlert }
	local result = {}
	for _, alert in Portfolio.State.Alerts or ({} :: { Types.PriceAlert }) do
		if ticker == nil or alert.Ticker == ticker then
			table.insert(result, alert)
		end
	end
	return result
end

function Alerts.create(ticker: string, kind: Types.AlertKind, value: number): boolean
	local request: Types.AlertRequest = { Ticker = ticker, Kind = kind, Value = value }
	local result = invoke(Remotes.CreateAlert, request)
	if result.Ok then
		Toast.show(`Alert set for {ticker}`, "Success")
	else
		Toast.show(result.Error or "Couldn't set the alert", "Error")
	end
	return result.Ok
end

function Alerts.delete(id: string)
	local result = invoke(Remotes.DeleteAlert, id)
	if not result.Ok then
		Toast.show(result.Error or "Couldn't remove the alert", "Error")
	end
end

return Alerts
