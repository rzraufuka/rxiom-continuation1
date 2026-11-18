--!strict
-- Dolny pasek: preset, portfel, ceny głównych coinów, liczba graczy online, status.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Format = require(ReplicatedStorage.Shared.Format)

local State = script.Parent.Parent.Parent.State
local Market = require(State.Market)
local Portfolio = require(State.Portfolio)

local UI = script.Parent.Parent
local Icons = require(UI.Icons)
local Theme = require(UI.Theme)
local Util = require(UI.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local TICKER_COUNT = 5

local BottomBar = {}
BottomBar.Height = 40

local function separator(order: number): Frame
	return create("Frame", {
		Name = "Separator",
		Size = UDim2.fromOffset(1, 18),
		BackgroundColor3 = Colors.Border,
		BorderSizePixel = 0,
		LayoutOrder = order,
	})
end

local function presetBadge(): TextLabel
	return create("TextLabel", {
		Name = "Preset",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 26),
		BackgroundColor3 = Colors.Primary,
		BackgroundTransparency = 0.82,
		Text = "P1",
		TextSize = 14,
		FontFace = Fonts.SemiBold,
		TextColor3 = Colors.Primary,
		LayoutOrder = 1,
	}, { Util.corner(6), Util.padding(0, 10) })
end

local function wallet(): Frame
	local frame: Frame = create("Frame", {
		Name = "Wallet",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 26),
		BackgroundTransparency = 1,
		LayoutOrder = 2,
	}, { Util.round(), Util.stroke(Colors.Border), Util.padding(0, 10), Util.hlist(6) })
	Util.text({ Text = "1", Size = 14, Order = 1, Parent = frame })
	Icons.currency(12, 2).Parent = frame
	local balance = Util.text({ Text = "0", Size = 14, Order = 3, Parent = frame })
	Icons.chevronDown(10, Colors.TextMuted, 4).Parent = frame
	local function update()
		balance.Text = Format.decimal(Portfolio.State.Balance)
	end
	Portfolio.Changed:Connect(update)
	update()
	return frame
end

local function priceTicker(): Frame
	local frame = Util.group("Prices", 4, Util.hlist(16))
	local labels: { [string]: TextLabel } = {}
	for i = 1, math.min(TICKER_COUNT, #Coins.List) do
		local def = Coins.List[i]
		local item = Util.group(def.Ticker, i, Util.hlist(6))
		item.Parent = frame
		Icons.dot(10, def.Color, 1).Parent = item
		labels[def.Ticker] = Util.text({
			Text = "-",
			Size = 14,
			Font = Fonts.Medium,
			Color = def.Color,
			Order = 2,
			Parent = item,
		})
	end
	Market.Changed:Connect(function()
		for ticker, label in labels do
			local coin = Market.coin(ticker)
			if coin then
				label.Text = Format.usd(coin.MarketCap)
			end
		end
	end)
	return frame
end

local function onlineCount(): Frame
	local frame = Util.group("Online", 1, Util.hlist(6))
	Icons.dot(8, Colors.Green, 1).Parent = frame
	local label = Util.text({ Text = "", Size = 14, Color = Colors.TextMuted, Order = 2, Parent = frame })
	local function update()
		label.Text = `{#Players:GetPlayers()} online`
	end
	update()
	Players.PlayerAdded:Connect(update)
	Players.PlayerRemoving:Connect(function()
		-- Gracz jest jeszcze na liście w trakcie PlayerRemoving.
		task.defer(update)
	end)
	return frame
end

local function statusPill(): Frame
	local frame: Frame = create("Frame", {
		Name = "Status",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 26),
		BackgroundColor3 = Colors.Green,
		BackgroundTransparency = 0.85,
		LayoutOrder = 2,
	}, { Util.corner(6), Util.padding(0, 10), Util.hlist(6) })
	Icons.dot(8, Colors.Green, 1).Parent = frame
	Util.text({ Text = "AUTO", Size = 13, Font = Fonts.Bold, Color = Colors.Green, Order = 2, Parent = frame })
	return frame
end

export type BottomBar = {
	Frame: Frame,
}

function BottomBar.new(): BottomBar
	local frame: Frame = create("Frame", {
		Name = "BottomBar",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, BottomBar.Height),
		BackgroundColor3 = Colors.Background,
		BorderSizePixel = 0,
	})
	create("Frame", {
		Name = "Divider",
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = Colors.Border,
		BorderSizePixel = 0,
		Parent = frame,
	})
	local inner = create("Frame", {
		Name = "Inner",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	}, { Util.padding(0, 24) })

	local left = Util.group("Left", 0, Util.hlist(14))
	left.AnchorPoint = Vector2.new(0, 0.5)
	left.Position = UDim2.fromScale(0, 0.5)
	left.Parent = inner
	presetBadge().Parent = left
	wallet().Parent = left
	separator(3).Parent = left
	priceTicker().Parent = left

	local right = Util.group("Right", 0, Util.hlist(16, nil, Enum.HorizontalAlignment.Right))
	right.AnchorPoint = Vector2.new(1, 0.5)
	right.Position = UDim2.fromScale(1, 0.5)
	right.Parent = inner
	onlineCount().Parent = right
	statusPill().Parent = right

	return { Frame = frame }
end

return BottomBar
