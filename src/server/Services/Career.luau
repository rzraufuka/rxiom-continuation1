--!strict
-- Trader Career: the server is the only source of progress. Chapters are achievements saved in the
-- profile regardless of the chosen path; the reward is a Tracker title that never affects earnings.
-- Depends only on PlayerData, so any service can use it without require cycles.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CareerDefs = require(ReplicatedStorage.Shared.Career)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local PlayerData = require(script.Parent.PlayerData)

type ActionResult = Types.ActionResult

local Career = {}

local lastCall: { [Player]: number } = {}
local pushPortfolio: (player: Player) -> () = function() end

local function fail(message: string): ActionResult
	return { Ok = false, Error = message }
end

-- Returns true only when the chapter was completed by this call.
function Career.complete(player: Player, chapterId: CareerDefs.ChapterId): boolean
	local chapter = CareerDefs.chapter(chapterId)
	local profile = PlayerData.get(player)
	if not chapter or not profile or profile.Career.Done[chapter.Id] then
		return false
	end
	profile.Career.Done[chapter.Id] = os.time()
	profile.Career.Title = chapter.Title
	Remotes.Notify:FireClient(player, {
		Kind = "Success",
		Text = `Chapter complete: {chapter.Name}. New Tracker title: {chapter.Title}`,
	})
	pushPortfolio(player)
	return true
end

-- Also covers favorites saved before the Career existed.
local function checkWatchlist(player: Player)
	local profile = PlayerData.get(player)
	if profile and #profile.Favorites >= CareerDefs.WatchlistSize then
		Career.complete(player, "Watchlist")
	end
end

local function choose(player: Player, pathId: any): ActionResult
	local profile = PlayerData.get(player)
	if not profile then
		return fail("Your data is still loading")
	end
	local now = os.clock()
	if lastCall[player] and now - lastCall[player] < 0.25 then
		return fail("Slow down")
	end
	lastCall[player] = now
	local path = CareerDefs.path(pathId)
	if not path then
		return fail("Unknown career path")
	end
	profile.Career.Path = path.Id
	checkWatchlist(player)
	pushPortfolio(player)
	return { Ok = true }
end

function Career.release(player: Player)
	lastCall[player] = nil
end

function Career.start(push: (player: Player) -> ())
	pushPortfolio = push
	Remotes.ChooseCareer.OnServerInvoke = choose
	PlayerData.FavoritesChanged:Connect(checkWatchlist)
	PlayerData.Loaded:Connect(checkWatchlist)
	Players.PlayerRemoving:Connect(Career.release)
end

Career.choose = choose

return Career
