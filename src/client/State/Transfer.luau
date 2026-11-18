--!strict
-- Przelewy RXI: podgląd odbiorcy i wysyłka.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)

local Transfer = {}

function Transfer.find(query: string): Types.RecipientInfo
	local ok, result = pcall(Remotes.FindRecipient.InvokeServer, Remotes.FindRecipient, query)
	if not ok or typeof(result) ~= "table" then
		return { Ok = false, Error = "Connection problem, try again" }
	end
	return result
end

function Transfer.send(to: string, amount: number): Types.ActionResult
	local request: Types.TransferRequest = { To = to, Amount = amount }
	local ok, result = pcall(Remotes.SendRxi.InvokeServer, Remotes.SendRxi, request)
	if not ok or typeof(result) ~= "table" then
		return { Ok = false, Error = "Connection problem, try again" }
	end
	return result
end

return Transfer
