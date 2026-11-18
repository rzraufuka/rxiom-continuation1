--!strict
-- Perpetuals po stronie klienta: snapshot cen co sekundę, świece (pobierane z serwera i
-- przedłużane na bieżąco ceną mark) oraz akcje gracza z powiadomieniami.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Signal = require(ReplicatedStorage.Shared.Signal)
local Types = require(ReplicatedStorage.Shared.Types)

local Toast = require(script.Parent.Parent.UI.Toast)

type Candle = Types.Candle

local PERPS = Config.Perps
local REFETCH_SECONDS = 30

local Perps = {}
Perps.Snapshot = nil :: Types.PerpsSnapshot?
Perps.Changed = Signal.new() -- ()

type CacheEntry = { List: { Candle }, FetchedAt: number, Loading: boolean }
local cache: { [string]: CacheEntry } = {}

local function key(symbol: string, seconds: number): string
	return symbol .. ":" .. seconds
end

-- Ostatnia świeca idzie za ceną mark; nowy przedział czasu otwiera nową świecę.
local function extend(entry: CacheEntry, seconds: number, mark: number, t: number)
	local list = entry.List
	local last = list[#list]
	if not last then
		return
	end
	local bucket = math.floor(t / seconds) * seconds
	if bucket == last.T then
		last.H = math.max(last.H, mark)
		last.L = math.min(last.L, mark)
		last.C = mark
	elseif bucket > last.T then
		table.insert(list, { T = bucket, O = last.C, H = math.max(last.C, mark), L = math.min(last.C, mark), C = mark })
		while #list > PERPS.CandleCount do
			table.remove(list, 1)
		end
	end
end

function Perps.start()
	Remotes.PerpsSnapshot.OnClientEvent:Connect(function(snapshot: Types.PerpsSnapshot)
		Perps.Snapshot = snapshot
		for _, def in PERPS.Markets do
			local market = snapshot.Markets[def.Symbol]
			if market then
				for _, seconds in PERPS.Timeframes do
					local entry = cache[key(def.Symbol, seconds)]
					if entry then
						extend(entry, seconds, market.Mark, snapshot.T)
					end
				end
			end
		end
		Perps.Changed:Fire()
	end)
end

function Perps.market(symbol: string): Types.PerpMarket?
	local snapshot = Perps.Snapshot
	return if snapshot then snapshot.Markets[symbol] else nil
end

function Perps.mark(symbol: string): number?
	local market = Perps.market(symbol)
	return if market then market.Mark else nil
end

-- Świece z pamięci; starsze niż REFETCH_SECONDS są w tle pobierane od nowa (wtedy Changed).
function Perps.candles(symbol: string, seconds: number): { Candle }?
	local k = key(symbol, seconds)
	local entry = cache[k]
	if not entry or (os.clock() - entry.FetchedAt > REFETCH_SECONDS and not entry.Loading) then
		local current: CacheEntry = entry or { List = {} :: { Candle }, FetchedAt = -math.huge, Loading = false }
		cache[k] = current
		current.Loading = true
		task.spawn(function()
			local ok, list = pcall(Remotes.GetPerpCandles.InvokeServer, Remotes.GetPerpCandles, symbol, seconds)
			current.Loading = false
			if ok and typeof(list) == "table" then
				current.List = list
				current.FetchedAt = os.clock()
				Perps.Changed:Fire()
			end
		end)
	end
	return if entry and #entry.List > 0 then entry.List else nil
end

local function invoke(remote: RemoteFunction, ...: any): Types.ActionResult
	local ok, result = pcall(remote.InvokeServer, remote, ...)
	if not ok or typeof(result) ~= "table" then
		return { Ok = false, Error = "Connection problem, try again" }
	end
	return result
end

function Perps.order(request: Types.PerpOrderRequest): boolean
	local result = invoke(Remotes.PerpOrder, request)
	if result.Ok then
		local text = if request.Type == "Limit"
			then `{request.Side} limit placed: {request.Symbol} at ${Format.price(request.Price or 0)}`
			else `{request.Side} {request.Symbol} opened with {Format.rx(request.Margin)} at {request.Leverage}x`
		Toast.show(text, "Success")
	else
		Toast.show(result.Error or "Order failed", "Error")
	end
	return result.Ok
end

function Perps.close(symbol: string)
	local result = invoke(Remotes.PerpClose, symbol)
	if result.Ok then
		Toast.show(`{symbol} position closed, got {Format.rx(result.Rx or 0)}`, "Success")
	else
		Toast.show(result.Error or "Couldn't close", "Error")
	end
end

function Perps.cancel(id: string)
	local result = invoke(Remotes.PerpCancel, id)
	if result.Ok then
		Toast.show(`Order cancelled, {Format.rx(result.Rx or 0)} returned`, "Info")
	else
		Toast.show(result.Error or "Couldn't cancel", "Error")
	end
end

return Perps
