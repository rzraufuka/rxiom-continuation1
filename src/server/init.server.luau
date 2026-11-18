--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Bots = require(script.Services.Bots)
local Launchpad = require(script.Services.Launchpad)
local Market = require(script.Services.Market)
local OrderBook = require(script.Services.OrderBook)
local PlayerData = require(script.Services.PlayerData)
local Trading = require(script.Services.Trading)
local World = require(script.Services.World)

-- Najpierw podłoga, zanim pojawi się postać gracza.
World.setup()
Market.init()
OrderBook.init()
Bots.warmup()
-- Coiny z Pulse przed profilami graczy, żeby pozycje w nich od razu trafiły na rynek.
Launchpad.load()
PlayerData.start()
Trading.start()

task.spawn(function()
	local last = os.clock()
	local sinceSnapshot = 0
	while true do
		task.wait(Config.TickSeconds)
		local clock = os.clock()
		local dt = math.min(clock - last, 1)
		last = clock

		local t = Market.now()
		Bots.step(dt, t)
		Market.tick(t)
		Trading.checkOrders()
		Launchpad.tick()

		sinceSnapshot += dt
		if sinceSnapshot >= Config.SnapshotSeconds then
			sinceSnapshot = 0
			Remotes.MarketSnapshot:FireAllClients(Market.flush())
		end
	end
end)

print("[Server] RXIOM market started")
