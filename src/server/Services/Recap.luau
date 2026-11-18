--!strict
-- Since You Left: what happened between the player's last save and this login. Every save stores a
-- snapshot (time, portfolio value, prices of coins the player cares about); limit orders that fill
-- when restored and transfers from the inbox are collected for a few seconds after the profile
-- loads. The summary is handed out once per session, after login.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Amm = require(ReplicatedStorage.Shared.Amm)
local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local Upgrades = require(ReplicatedStorage.Shared.Upgrades)
local Launchpad = require(script.Parent.Launchpad)
local Market = require(script.Parent.Market)
local News = require(script.Parent.News)
local PlayerData = require(script.Parent.PlayerData)

type RecapItem = Types.RecapItem
type Fill = { Ticker: string, Side: Types.Side, Tokens: number, Price: number, Complete: boolean }
type Session = {
	Seen: PlayerData.Seen?,
	Fills: { Fill },
	Transfers: { { Amount: number, From: string } },
	-- Notes are accepted until then; the summary is handed out from then on.
	ReadyAt: number,
	Taken: boolean,
}

local RECAP = Config.Recap

local Recap = {}

local sessions: { [Player]: Session } = {}
local valueOf: (player: Player) -> number = function()
	return 0
end

local function usd(price: number): string
	return "$" .. Format.decimal(price * Config.UsdPerRx)
end

local function percent(change: number): string
	return string.format("%.1f%%", math.abs(change))
end

local function session(player: Player): Session
	local s = sessions[player]
	if not s then
		s = { Seen = nil, Fills = {}, Transfers = {}, ReadyAt = os.clock() + RECAP.Settle, Taken = false }
		sessions[player] = s
	end
	return s
end

local function collecting(player: Player): Session?
	local s = session(player)
	return if not s.Taken and os.clock() <= s.ReadyAt then s else nil
end

-- Called when the profile has loaded, before restored orders are activated.
function Recap.begin(player: Player)
	local profile = PlayerData.get(player)
	local s = session(player)
	s.Seen = if profile then profile.Seen else nil
	s.ReadyAt = os.clock() + RECAP.Settle
end

-- A limit order restored at login filled (the price crossed it while the player was away).
function Recap.noteFill(player: Player, order: Types.BookOrder, tokens: number)
	local s = collecting(player)
	if s and tokens > 0 then
		table.insert(s.Fills, {
			Ticker = order.Ticker,
			Side = order.Side,
			Tokens = tokens,
			Price = order.Price,
			Complete = order.Tokens <= Config.DustTokens,
		})
	end
end

function Recap.noteTransfer(player: Player, amount: number, from: string)
	local s = collecting(player)
	if s then
		table.insert(s.Transfers, { Amount = amount, From = from })
	end
end

local function held(profile: PlayerData.Profile, ticker: string): boolean
	local p = profile.Positions[ticker]
	if p and p.Tokens > Config.DustTokens then
		return true
	end
	for _, order in profile.Orders do
		if order.Ticker == ticker then
			return true
		end
	end
	return false
end

-- Coins whose price is remembered: held, in orders, own Pulse coins, then favorites.
local function watched(player: Player, profile: PlayerData.Profile): { string }
	local list: { string } = {}
	local seen: { [string]: boolean } = {}
	local function add(ticker: string)
		if not seen[ticker] and #list < RECAP.MaxPrices and Market.get(ticker) then
			seen[ticker] = true
			table.insert(list, ticker)
		end
	end
	for ticker in profile.Positions do
		if held(profile, ticker) then
			add(ticker)
		end
	end
	for _, order in profile.Orders do
		add(order.Ticker)
	end
	for _, entry in Launchpad.createdBy(player.UserId) do
		add(entry.Ticker)
	end
	for _, ticker in profile.Favorites do
		add(ticker)
	end
	return list
end

function Recap.snapshot(player: Player, profile: PlayerData.Profile): PlayerData.Seen
	local prices: { [string]: number } = {}
	for _, ticker in watched(player, profile) do
		prices[ticker] = Amm.price((Market.get(ticker) :: Market.CoinState).Pool)
	end
	return { At = Market.now(), Value = valueOf(player), Prices = prices }
end

local function transferItems(s: Session): { RecapItem }
	local n = #s.Transfers
	if n == 0 then
		return {}
	end
	if n == 1 then
		local t = s.Transfers[1]
		return {
			{
				Kind = "Transfer",
				Text = `Someone sent you {Format.decimal(t.Amount)} {Config.Currency}`,
				Detail = if t.From ~= "" then `from {t.From}` else nil,
				Tone = "Up",
			},
		}
	end
	local total = 0
	for _, t in s.Transfers do
		total += t.Amount
	end
	return {
		{
			Kind = "Transfer",
			Text = `You received {n} transfers`,
			Detail = `+{Format.decimal(total)} {Config.Currency} in total`,
			Tone = "Up",
		},
	}
end

local function fillItems(s: Session): { RecapItem }
	local items: { RecapItem } = {}
	for i, f in s.Fills do
		if i == 2 and #s.Fills > 2 then
			table.insert(items, {
				Kind = "Fill",
				Text = `{#s.Fills - 1} more limit orders filled`,
				Detail = "See your orders on each coin page",
				Ticker = f.Ticker,
				Tone = "Neutral",
			})
			break
		end
		local verb = if f.Side == "Buy" then "buy" else "sell"
		table.insert(items, {
			Kind = "Fill",
			Text = `Limit {verb} {if f.Complete then "filled" else "partly filled"}: {Format.compact(f.Tokens)} {f.Ticker}`,
			Detail = `at {usd(f.Price)}`,
			Ticker = f.Ticker,
			Tone = "Neutral",
		})
	end
	return items
end

local function creatorItems(player: Player, since: number): { RecapItem }
	local items: { RecapItem } = {}
	for _, entry in Launchpad.createdBy(player.UserId) do
		if entry.FirstBuyerAt and entry.FirstBuyerAt > since then
			table.insert(items, {
				Kind = "Holder",
				Text = `Someone bought your coin {entry.Ticker}`,
				Detail = "Your first holder on Pulse",
				Ticker = entry.Ticker,
				Tone = "Up",
			})
		end
		if entry.Migrated and entry.MigratedAt and entry.MigratedAt > since then
			table.insert(items, {
				Kind = "Graduated",
				Text = `{entry.Ticker} completed its bonding curve`,
				Detail = "It now trades in Migrated on Pulse",
				Ticker = entry.Ticker,
				Tone = "Up",
			})
		end
	end
	return items
end

local function moverItems(player: Player, profile: PlayerData.Profile, seen: PlayerData.Seen): { RecapItem }
	local own: { [string]: boolean } = {}
	for _, entry in Launchpad.createdBy(player.UserId) do
		own[entry.Ticker] = true
	end
	local moves = {}
	for ticker, old in seen.Prices do
		local state = Market.get(ticker)
		if state then
			local change = (Amm.price(state.Pool) / old - 1) * 100
			if math.abs(change) >= RECAP.MoveThreshold then
				table.insert(moves, { Ticker = ticker, Change = change })
			end
		end
	end
	table.sort(moves, function(a, b)
		return math.abs(a.Change) > math.abs(b.Change)
	end)
	local items: { RecapItem } = {}
	for i = 1, math.min(#moves, RECAP.MaxMovers) do
		local m = moves[i]
		local up = m.Change > 0
		table.insert(items, {
			Kind = "Mover",
			Text = `{m.Ticker} is {if up then "up" else "down"} {percent(m.Change)}`,
			Detail = if own[m.Ticker]
				then "Your Pulse coin"
				elseif held(profile, m.Ticker) then "You hold it"
				else "In your favorites",
			Ticker = m.Ticker,
			Tone = if up then "Up" else "Down",
		})
	end
	return items
end

local function newsItems(since: number): { RecapItem }
	local items: { RecapItem } = {}
	for _, event in News.resolvedSince(since) do
		if #items >= RECAP.MaxNews then
			break
		end
		local change = event.Change or 0
		table.insert(items, {
			Kind = "News",
			Text = event.Result or event.Headline,
			Detail = `{if change >= 0 then "+" else "-"}{percent(change)} after the headline`,
			Ticker = event.Ticker,
			Tone = if change >= 0 then "Up" else "Down",
		})
	end
	return items
end

local function faucetItems(profile: PlayerData.Profile): { RecapItem }
	if os.time() < profile.FaucetReadyAt then
		return {}
	end
	return {
		{
			Kind = "Faucet",
			Text = "Your free deposit is ready",
			Detail = `Claim {Format.decimal(Upgrades.value(profile.Upgrades, "FaucetAmount"))} {Config.Currency}`,
			Tone = "Neutral",
		},
	}
end

function Recap.build(player: Player, s: Session): Types.Recap?
	local seen = s.Seen
	local profile = PlayerData.get(player)
	if not seen or not profile then
		return nil
	end
	local away = Market.now() - seen.At
	if away < (if RunService:IsStudio() then RECAP.StudioMinAway else RECAP.MinAway) then
		return nil
	end
	local items: { RecapItem } = {}
	for _, group in {
		transferItems(s),
		fillItems(s),
		creatorItems(player, seen.At),
		moverItems(player, profile, seen),
		newsItems(seen.At),
		faucetItems(profile),
	} do
		for _, item in group do
			if #items < RECAP.MaxItems then
				table.insert(items, item)
			end
		end
	end
	local value = valueOf(player)
	local change = if seen.Value > 0 then (value / seen.Value - 1) * 100 else nil
	if #items == 0 and (change == nil or math.abs(change) < 1) then
		return nil
	end
	return { Away = away, Value = value, Change = change, Items = items }
end

local function getRecap(player: Player): Types.Recap?
	if not PlayerData.waitFor(player, 15) then
		return nil
	end
	local s = sessions[player]
	if not s or s.Taken then
		return nil
	end
	local wait = s.ReadyAt - os.clock()
	if wait > 0 then
		task.wait(wait)
	end
	if s.Taken or sessions[player] ~= s then
		return nil
	end
	s.Taken = true
	return Recap.build(player, s)
end

function Recap.release(player: Player)
	sessions[player] = nil
end

-- `value`: portfolio value in RX (Trading.portfolioValue; passed in to avoid a require cycle).
function Recap.start(value: (player: Player) -> number)
	valueOf = value
	PlayerData.setSnapshot(Recap.snapshot)
	Remotes.GetRecap.OnServerInvoke = getRecap
end

Recap.get = getRecap

return Recap
