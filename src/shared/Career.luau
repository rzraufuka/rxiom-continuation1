--!strict
-- Trader Career: three optional paths of short chapters, each teaching one part of the market.
-- Finishing a chapter awards a title shown in the Wallet Tracker. Titles never change earnings.
-- Shared by the server (progress is authoritative there) and the client (cards and dialog).

local Config = require(script.Parent.Config)
local Format = require(script.Parent.Format)

export type PathId = "Analyst" | "Trader" | "Founder"
export type ChapterId =
	"Watchlist"
	| "Alert"
	| "AlertTriggered"
	| "LimitPlaced"
	| "LimitBuyFilled"
	| "LimitProfit"
	| "Launch"
	| "FirstHolder"
	| "Graduate"

export type Chapter = {
	Id: ChapterId,
	Path: PathId,
	Index: number,
	Name: string,
	Goal: string,
	Hint: string,
	Title: string,
}

export type Path = {
	Id: PathId,
	Name: string,
	Tagline: string,
	Chapters: { Chapter },
}

-- Saved in the player profile. Done maps a chapter to os.time() of completion.
-- Title is the most recently earned chapter title, shown in the Tracker.
export type State = {
	Path: PathId?,
	Done: { [string]: number },
	Title: string?,
}

local Career = {}

-- Favorites needed for the first Analyst chapter.
Career.WatchlistSize = 3

local function path(id: PathId, name: string, tagline: string, chapters: { { any } }): Path
	local list: { Chapter } = {}
	for i, c in chapters do
		list[i] = table.freeze({
			Id = c[1],
			Path = id,
			Index = i,
			Name = c[2],
			Goal = c[3],
			Hint = c[4],
			Title = c[5],
		}) :: Chapter
	end
	return table.freeze({ Id = id, Name = name, Tagline = tagline, Chapters = table.freeze(list) }) :: Path
end

Career.Paths = table.freeze({
	path("Analyst", "Analyst", "Follow coins, set alerts and see how prices really move.", {
		{
			"Watchlist",
			"Build a watchlist",
			`Save {Career.WatchlistSize} coins to Favorites`,
			"Press the star next to any coin in Discover or Pulse.",
			"Watcher",
		},
		{
			"Alert",
			"Set a price alert",
			"Create a price alert on any coin",
			"Open a coin and press the bell next to its name.",
			"Signal Setter",
		},
		{
			"AlertTriggered",
			"Read the move",
			"Have one of your price alerts trigger",
			"Alerts fire while you're in the game. A banner shows where the price went.",
			"Market Analyst",
		},
	}),
	path("Trader", "Trader", "Name your own price with limit orders instead of pressing Buy.", {
		{
			"LimitPlaced",
			"Set your price",
			"Place a limit buy order",
			"On a coin page switch the panel to Limit and pick a price below the market.",
			"Order Setter",
		},
		{
			"LimitBuyFilled",
			"Get filled",
			"Have a limit buy order fill",
			"Limit orders fill when the market reaches your price, even while you browse.",
			"Patient Buyer",
		},
		{
			"LimitProfit",
			"Sell into strength",
			"Fill a limit sell above your average buy price",
			"Place a limit sell above the entry price shown in your position.",
			"Limit Trader",
		},
	}),
	path("Founder", "Founder", "Launch your own coin on Pulse and grow a community around it.", {
		{
			"Launch",
			"Launch a coin",
			"Create your own coin on Pulse",
			`Open Pulse and press Create coin. Launching costs {Config.Launch.Fee} {Config.Currency}.`,
			"Founder",
		},
		{
			"FirstHolder",
			"First holder",
			"Another player buys your coin",
			"Players with Pulse Radar are alerted when you launch. Tell your friends the ticker.",
			"Community Builder",
		},
		{
			"Graduate",
			"Graduation",
			"Your coin completes its bonding curve",
			`A coin migrates once its market cap reaches {Format.usd(Config.Launch.MigrationMarketCap)}.`,
			"Graduate",
		},
	}),
})

local byPath: { [string]: Path } = {}
local chapters: { [string]: Chapter } = {}
local titles: { [string]: boolean } = {}
for _, p in Career.Paths do
	byPath[p.Id] = p
	for _, c in p.Chapters do
		chapters[c.Id] = c
		titles[c.Title] = true
	end
end

function Career.path(id: any): Path?
	return if typeof(id) == "string" then byPath[id] else nil
end

function Career.chapter(id: any): Chapter?
	return if typeof(id) == "string" then chapters[id] else nil
end

function Career.isTitle(title: any): boolean
	return typeof(title) == "string" and titles[title] == true
end

function Career.default(): State
	return { Path = nil, Done = {}, Title = nil }
end

-- Accepts anything loaded from a DataStore or received from a remote.
function Career.sanitize(raw: any): State
	local state = Career.default()
	if typeof(raw) ~= "table" then
		return state
	end
	if Career.path(raw.Path) then
		state.Path = raw.Path
	end
	if typeof(raw.Done) == "table" then
		for id, at in raw.Done do
			if chapters[id] and typeof(at) == "number" and at == at and at >= 0 and at < math.huge then
				state.Done[id] = at
			end
		end
	end
	local title = raw.Title
	if Career.isTitle(title) then
		-- A title is only valid when its chapter is done.
		for id, c in chapters do
			if c.Title == title and state.Done[id] then
				state.Title = title
				break
			end
		end
	end
	return state
end

-- First unfinished chapter of a path, or nil when the path is complete.
function Career.current(state: State, pathId: PathId): Chapter?
	local p = byPath[pathId]
	for _, c in p.Chapters do
		if not state.Done[c.Id] then
			return c
		end
	end
	return nil
end

function Career.doneCount(state: State, pathId: PathId): number
	local count = 0
	for _, c in byPath[pathId].Chapters do
		if state.Done[c.Id] then
			count += 1
		end
	end
	return count
end

return table.freeze(Career)
