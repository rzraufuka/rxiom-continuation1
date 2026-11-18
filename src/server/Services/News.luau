--!strict
-- Breaking News: every 10-15 minutes a headline about one established coin. Whether bots act on it
-- is decided at announcement but only revealed when the window ends; confirmed news comes true far
-- more often than rumours, so players have to weigh the risk before trading on it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Amm = require(ReplicatedStorage.Shared.Amm)
local Coins = require(ReplicatedStorage.Shared.Coins)
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local Bots = require(script.Parent.Bots)
local Market = require(script.Parent.Market)

type NewsEvent = Types.NewsEvent
type Scenario = { Direction: number, Headline: string, Hit: string, Miss: string }

local NEWS = Config.News

-- {T} is replaced with the ticker.
local SCENARIOS: { Scenario } = {
	{
		Direction = 1,
		Headline = "Whale wallet is loading up on {T}",
		Hit = "Whale bought {T}",
		Miss = "No whale showed up for {T}",
	},
	{
		Direction = 1,
		Headline = "{T} rumoured to land a major exchange listing",
		Hit = "{T} listing went live",
		Miss = "No listing for {T}",
	},
	{
		Direction = 1,
		Headline = "Influencer about to shill {T} to 2M followers",
		Hit = "Influencer pumped {T}",
		Miss = "Influencer stayed quiet on {T}",
	},
	{
		Direction = 1,
		Headline = "{T} devs tease a big partnership",
		Hit = "{T} partnership announced",
		Miss = "{T} partnership was just a tease",
	},
	{
		Direction = -1,
		Headline = "{T} liquidity is about to be pulled",
		Hit = "{T} liquidity was pulled",
		Miss = "{T} liquidity stayed put",
	},
	{
		Direction = -1,
		Headline = "Large {T} holder is moving tokens to an exchange",
		Hit = "Big holder dumped {T}",
		Miss = "{T} holder didn't sell",
	},
	{
		Direction = -1,
		Headline = "{T} team wallet flagged for dumping",
		Hit = "{T} team wallet sold",
		Miss = "{T} team wallet held",
	},
	{
		Direction = -1,
		Headline = "Security researchers question the {T} contract",
		Hit = "{T} contract scare hit the price",
		Miss = "{T} contract checked out fine",
	},
}

local News = {}

local rng = Random.new()
local active: NewsEvent? = nil
local nextId = 0
local lastTicker: string? = nil

local function fill(text: string, ticker: string): string
	return (string.gsub(text, "{T}", ticker))
end

-- Bigger coins need a stronger push to move; scale from 0.5 (around $400K) to 1 (above $10M).
local function strength(marketCap: number): number
	return math.clamp(math.log10(marketCap / 1e5) / 2, 0.5, 1)
end

local function candidates(): { Coins.CoinDef }
	local list = {}
	for _, def in Coins.List do
		if def.MarketCap >= NEWS.MinMarketCap and Market.get(def.Ticker) and def.Ticker ~= lastTicker then
			table.insert(list, def)
		end
	end
	return list
end

function News.current(): NewsEvent?
	return active
end

-- Announces one headline and blocks until it resolves. Returns the resolved event, or nil when
-- no coin qualifies. `wait` is task.wait, injectable for tests.
function News.run(wait: ((seconds: number) -> ())?): NewsEvent?
	local sleep = wait or function(seconds: number)
		task.wait(seconds)
	end
	local list = candidates()
	if #list == 0 then
		return nil
	end
	local def = list[rng:NextInteger(1, #list)]
	local scenario = SCENARIOS[rng:NextInteger(1, #SCENARIOS)]
	local confirmed = rng:NextNumber() < NEWS.ConfirmedShare
	local happens = rng:NextNumber() < (if confirmed then NEWS.ConfirmedOdds else NEWS.RumorOdds)

	local now = Market.now()
	local startsAt = now + rng:NextNumber(NEWS.LeadMin, NEWS.LeadMax)
	local endsAt = startsAt + rng:NextNumber(NEWS.DurationMin, NEWS.DurationMax)
	nextId += 1
	lastTicker = def.Ticker
	local event: NewsEvent = {
		Id = nextId,
		Ticker = def.Ticker,
		Headline = fill(scenario.Headline, def.Ticker),
		Direction = scenario.Direction,
		Source = if confirmed then "Confirmed" else "Rumor",
		AnnouncedAt = now,
		StartsAt = startsAt,
		EndsAt = endsAt,
		Resolved = false,
	}
	local state = Market.get(def.Ticker) :: Market.CoinState
	local startPrice = Amm.price(state.Pool)
	if happens then
		local k = strength(def.MarketCap)
		Bots.push(def.Ticker, scenario.Direction * NEWS.Bias * k, startsAt, endsAt, 1 + (NEWS.Boost - 1) * k)
	end
	active = event
	-- The outcome stays on the server until the window ends.
	Remotes.MarketNews:FireAllClients(event)

	sleep(math.max(0, endsAt - Market.now()))

	local resolved = table.clone(event)
	resolved.Resolved = true
	resolved.Happened = happens
	resolved.Change = (Amm.price(state.Pool) / startPrice - 1) * 100
	resolved.Result = fill(if happens then scenario.Hit else scenario.Miss, def.Ticker)
	active = nil
	Remotes.MarketNews:FireAllClients(resolved)
	return resolved
end

function News.start()
	local studio = RunService:IsStudio()
	local minGap = if studio then NEWS.StudioMinGap else NEWS.MinGap
	local maxGap = if studio then NEWS.StudioMaxGap else NEWS.MaxGap
	task.spawn(function()
		task.wait(if studio then NEWS.StudioFirstDelay else NEWS.FirstDelay)
		while true do
			local started = os.clock()
			-- Headlines are only worth anything to someone watching.
			if #Players:GetPlayers() > 0 then
				News.run()
			end
			task.wait(math.max(30, rng:NextNumber(minGap, maxGap) - (os.clock() - started)))
		end
	end)
end

return News
