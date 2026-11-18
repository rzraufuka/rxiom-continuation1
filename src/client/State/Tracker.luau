--!strict
-- Zapytania Wallet Trackera do serwera: wyszukiwanie, profile, ranking i prywatność profilu.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)

local Toast = require(script.Parent.Parent.UI.Toast)

local Tracker = {}

function Tracker.search(query: string): Types.WalletSearch
	local ok, result = pcall(Remotes.SearchWallets.InvokeServer, Remotes.SearchWallets, query)
	if not ok or typeof(result) ~= "table" then
		return { Ok = false, Error = "Connection problem, try again", Results = {} }
	end
	return result
end

function Tracker.profile(userId: number): Types.WalletProfile?
	local ok, result = pcall(Remotes.GetWalletProfile.InvokeServer, Remotes.GetWalletProfile, userId)
	return if ok and typeof(result) == "table" then result else nil
end

function Tracker.leaderboard(): { Types.LeaderboardEntry }?
	local ok, result = pcall(Remotes.GetLeaderboard.InvokeServer, Remotes.GetLeaderboard)
	return if ok and typeof(result) == "table" then result else nil
end

function Tracker.setPublic(public: boolean): boolean
	local ok, result = pcall(Remotes.SetProfilePublic.InvokeServer, Remotes.SetProfilePublic, public)
	if not ok or typeof(result) ~= "table" or not result.Ok then
		Toast.show(if ok and typeof(result) == "table" and result.Error then result.Error else "Couldn't change it, try again", "Error")
		return false
	end
	Toast.show(if public then "Your profile is now public" else "Your profile is now private", "Info")
	return true
end

return Tracker
