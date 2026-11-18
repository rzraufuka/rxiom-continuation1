--!strict
-- Strona coina: nagłówek ze statystykami, wykres świecowy, ostatnie transakcje,
-- panel kupna/sprzedaży, pozycja gracza i jego otwarte zlecenia.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Types = require(ReplicatedStorage.Shared.Types)

local State = script.Parent.Parent.Parent.State
local Actions = require(State.Actions)
local Alerts = require(State.Alerts)
local Market = require(State.Market)
local Portfolio = require(State.Portfolio)
local Settings = require(State.Settings)

local UI = script.Parent.Parent
local Chart = require(UI.Chart)
local Icons = require(UI.Icons)
local Theme = require(UI.Theme)
local Util = require(UI.Util)
local OrderBookView = require(script.Parent.OrderBookView)
local TradePanel = require(script.Parent.TradePanel)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local HEADER_HEIGHT = 80
local PANEL_WIDTH = 390
local BOOK_WIDTH = 320
local GAP = 16

export type CoinView = {
	Frame: Frame,
	Open: (ticker: string) -> (),
}

local CoinView = {}

type Stat = { Value: TextLabel, Sub: TextLabel }

local function stat(parent: Instance, title: string, order: number): Stat
	local group = Util.group(title, order, Util.vlist(2))
	group.Parent = parent
	Util.text({ Text = title, Size = 13, Color = Colors.TextMuted, Order = 1, Parent = group })
	local value = Util.text({ Text = "-", Size = 18, Font = Fonts.SemiBold, Order = 2, Parent = group })
	local sub = Util.text({ Text = "", Size = 13, Color = Colors.TextMuted, Order = 3, Parent = group })
	return { Value = value, Sub = sub }
end

local function card(name: string, order: number): Frame
	return create("Frame", {
		Name = name,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Colors.Surface,
		LayoutOrder = order,
	}, {
		Util.corner(8),
		Util.stroke(Colors.Border),
		Util.padding(14, 16),
		Util.vlist(10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top),
	})
end

-- Kolumny listy transakcji: tytuł i szerokość (ułamek).
local TRADE_COLUMNS: { { Title: string, Width: number } } = {
	{ Title = "Age", Width = 0.1 },
	{ Title = "Type", Width = 0.1 },
	{ Title = "MC", Width = 0.16 },
	{ Title = "Amount", Width = 0.18 },
	{ Title = "Tokens", Width = 0.18 },
	{ Title = "Trader", Width = 0.28 },
}

type TradeRow = { Frame: Frame, Cells: { TextLabel } }

local function tradeRow(parent: Instance, order: number, isHeader: boolean): TradeRow
	local row: Frame = create("Frame", {
		Name = if isHeader then "Header" else "Row" .. order,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, if isHeader then 34 else 30),
		LayoutOrder = order,
		Parent = parent,
	}, { Util.padding(0, 16) })
	local cells: { TextLabel } = {}
	local x = 0
	for i, column in TRADE_COLUMNS do
		local title, width = column.Title, column.Width
		cells[i] = Util.label({
			Text = if isHeader then title else "",
			Size = if isHeader then 13 else 14,
			Color = if isHeader then Colors.TextMuted else Colors.Text,
			Position = UDim2.fromScale(x, 0),
			FrameSize = UDim2.fromScale(width, 1),
			Parent = row,
		})
		x += width
	end
	return { Frame = row, Cells = cells }
end

-- `onAlerts`: otwiera okno alertów cenowych dla coina.
function CoinView.new(onBack: () -> (), onAlerts: (ticker: string) -> ()): CoinView
	local ticker: string? = nil

	local frame: Frame = create("Frame", {
		Name = "CoinView",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
	})

	-- Nagłówek
	local header = create("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
		BackgroundColor3 = Colors.Surface,
		Parent = frame,
	}, { Util.corner(8), Util.stroke(Colors.Border), Util.padding(0, 16) })
	local headerLeft = Util.group("Identity", 0, Util.hlist(14))
	headerLeft.AnchorPoint = Vector2.new(0, 0.5)
	headerLeft.Position = UDim2.fromScale(0, 0.5)
	headerLeft.Parent = header
	local backButton: TextButton = create("TextButton", {
		Name = "Back",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(36, 36),
		BackgroundColor3 = Colors.Elevated,
		Text = "",
		LayoutOrder = 1,
		Parent = headerLeft,
	}, { Util.round() })
	local backIcon = Icons.chevron(18, Colors.Text, "Left")
	backIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	backIcon.Position = UDim2.fromScale(0.5, 0.5)
	backIcon.Parent = backButton
	Util.hoverBackground(backButton, Colors.Elevated, Colors.Border)
	backButton.Activated:Connect(onBack)

	local iconSlot = create("Frame", {
		Name = "IconSlot",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(48, 48),
		LayoutOrder = 2,
		Parent = headerLeft,
	})
	local names = Util.group("Names", 3, Util.vlist(4))
	names.Parent = headerLeft
	local titleRow = Util.group("Title", 1, Util.hlist(8, Enum.VerticalAlignment.Bottom))
	titleRow.Parent = names
	local tickerLabel = Util.text({ Text = "", Size = 22, Font = Fonts.Bold, Order = 1, Parent = titleRow })
	local nameLabel = Util.text({ Text = "", Size = 16, Color = Colors.TextMuted, Order = 2, Parent = titleRow })
	local subRow = Util.group("Sub", 2, Util.hlist(10, Enum.VerticalAlignment.Center))
	subRow.Parent = names
	local ageLabel =
		Util.text({ Text = "", Size = 14, Font = Fonts.SemiBold, Color = Colors.Green, Order = 1, Parent = subRow })
	-- Opis coina ze stałej listy; ucięty, żeby nie wchodził pod statystyki po prawej.
	local descLabel = Util.text({ Text = "", Size = 14, Color = Colors.TextMuted, Order = 2, Parent = subRow })
	descLabel.TextTruncate = Enum.TextTruncate.AtEnd
	create("UISizeConstraint", { MaxSize = Vector2.new(360, math.huge), Parent = descLabel })

	-- Alerty cenowe: pełny dzwonek, gdy na tym coinie są ustawione alerty.
	local alertButton: TextButton = create("TextButton", {
		Name = "Alerts",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(36, 36),
		BackgroundColor3 = Colors.Elevated,
		Text = "",
		LayoutOrder = 4,
		Parent = headerLeft,
	}, { Util.round() })
	Util.hoverBackground(alertButton, Colors.Elevated, Colors.Border)
	local alertCount = Util.label({
		Name = "Count",
		Text = "",
		Size = 11,
		Font = Fonts.Bold,
		Color = Colors.OnPrimary,
		AlignX = Enum.TextXAlignment.Center,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -4, 0, 4),
		FrameSize = UDim2.fromOffset(16, 16),
		Parent = alertButton,
	})
	alertCount.BackgroundColor3 = Colors.Primary
	alertCount.BackgroundTransparency = 0
	alertCount.ZIndex = 3
	Util.round().Parent = alertCount
	local function refreshAlertButton()
		for _, child in alertButton:GetChildren() do
			if child.Name == "BellIcon" then
				child:Destroy()
			end
		end
		local count = if ticker then #Alerts.list(ticker) else 0
		local icon = Icons.bell(18, Colors.Text, count > 0)
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.5)
		icon.Parent = alertButton
		alertCount.Text = tostring(count)
		alertCount.Visible = count > 0
	end
	alertButton.Activated:Connect(function()
		if ticker then
			onAlerts(ticker)
		end
	end)
	Portfolio.Changed:Connect(refreshAlertButton)

	local stats = Util.group("Stats", 0, Util.hlist(36, nil, Enum.HorizontalAlignment.Right))
	stats.AnchorPoint = Vector2.new(1, 0.5)
	stats.Position = UDim2.fromScale(1, 0.5)
	stats.Parent = header
	local priceStat = stat(stats, "Price", 1)
	local mcStat = stat(stats, "Market Cap", 2)
	local liqStat = stat(stats, "Liquidity", 3)
	local volStat = stat(stats, "Volume", 4)
	local txStat = stat(stats, "TXNS", 5)
	local holdersStat = stat(stats, "Holders", 6)

	-- Lewa kolumna: wykres i transakcje
	local left = create("Frame", {
		Name = "Left",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, HEADER_HEIGHT + GAP),
		Size = UDim2.new(1, -(PANEL_WIDTH + BOOK_WIDTH + 2 * GAP), 1, -(HEADER_HEIGHT + GAP)),
		Parent = frame,
	})
	local chart = Chart.new(Config.CandleHistory)
	chart.Frame.Size = UDim2.new(1, 0, 0.6, -GAP / 2)
	chart.Frame.Parent = left

	local tradesCard = create("Frame", {
		Name = "Trades",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0.4, -GAP / 2),
		BackgroundColor3 = Colors.Surface,
		ClipsDescendants = true,
		Parent = left,
	}, { Util.corner(8), Util.stroke(Colors.Border) })
	tradeRow(tradesCard, 0, true)
	local tradesDivider = Util.divider()
	tradesDivider.Position = UDim2.fromOffset(0, 34)
	tradesDivider.Parent = tradesCard
	local tradesList: ScrollingFrame = create("ScrollingFrame", {
		Name = "List",
		Position = UDim2.fromOffset(0, 35),
		Size = UDim2.new(1, 0, 1, -35),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Colors.Border,
		Parent = tradesCard,
	}, { Util.vlist(0, nil, Enum.VerticalAlignment.Top) })
	local tradeRows: { TradeRow } = {}
	for i = 1, Config.TradeFeedLength do
		tradeRows[i] = tradeRow(tradesList, i, false)
	end

	-- Prawa kolumna: panel, pozycja, zlecenia. ScrollingFrame przycina wszystko poza sobą, a obrysy
	-- (UIStroke) wystają poza krawędź elementu, więc kolumna ma margines EDGE z lewej i u góry,
	-- przesunięty tak, żeby zawartość została w tym samym miejscu.
	local EDGE = 3
	local right: ScrollingFrame = create("ScrollingFrame", {
		Name = "Right",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, HEADER_HEIGHT + GAP - EDGE),
		Size = UDim2.new(0, PANEL_WIDTH + EDGE, 1, -(HEADER_HEIGHT + GAP) + EDGE),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Colors.Border,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = frame,
	}, {
		Util.vlist(GAP, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top),
		Util.padding(EDGE, 8, 8, EDGE),
	})
	local panel = TradePanel.new()
	panel.Frame.LayoutOrder = 1
	panel.Frame.Parent = right

	-- Środkowa kolumna: księga zleceń; kliknięcie poziomu ustawia cenę zlecenia limit.
	local book = OrderBookView.new(panel.SetLimitPrice)
	book.Frame.AnchorPoint = Vector2.new(1, 0)
	book.Frame.Position = UDim2.new(1, -(PANEL_WIDTH + GAP), 0, HEADER_HEIGHT + GAP)
	book.Frame.Size = UDim2.new(0, BOOK_WIDTH, 1, -(HEADER_HEIGHT + GAP))
	book.Frame.Parent = frame

	local positionCard = card("Position", 2)
	positionCard.Parent = right
	Util.text({ Text = "Your position", Size = 15, Font = Fonts.SemiBold, Order = 1, Parent = positionCard })
	local positionGrid = create("Frame", {
		Name = "Grid",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 44),
		LayoutOrder = 2,
		Parent = positionCard,
	}, {
		create("UIGridLayout", {
			CellSize = UDim2.new(0.25, -6, 1, 0),
			CellPadding = UDim2.fromOffset(8, 0),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local function positionStat(title: string, order: number): Stat
		local cell = create("Frame", {
			Name = title,
			BackgroundTransparency = 1,
			LayoutOrder = order,
			Parent = positionGrid,
		}, { Util.vlist(2, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top) })
		Util.text({ Text = title, Size = 12, Color = Colors.TextMuted, Order = 1, Parent = cell })
		local value = Util.text({ Text = "0", Size = 15, Font = Fonts.SemiBold, Order = 2, Parent = cell })
		local sub = Util.text({ Text = "", Size = 12, Color = Colors.TextMuted, Order = 3, Parent = cell })
		return { Value = value, Sub = sub }
	end
	local boughtStat = positionStat("Bought", 1)
	local soldStat = positionStat("Sold", 2)
	local holdingStat = positionStat("Holding", 3)
	local pnlStat = positionStat("PnL", 4)

	local ordersCard = card("Orders", 3)
	ordersCard.Parent = right
	local ordersTitle =
		Util.text({ Text = "Open orders", Size = 15, Font = Fonts.SemiBold, Order = 1, Parent = ordersCard })
	local ordersList = create("Frame", {
		Name = "List",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = ordersCard,
	}, { Util.vlist(8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top) })

	------------------------------------------------------------------

	local function refreshHeader()
		local coin = if ticker then Market.coin(ticker) else nil
		if not coin then
			return
		end
		local tf = Settings.State.Timeframe
		local s = coin.Stats[tf]
		local age = Format.age(Market.now() - coin.LaunchedAt)
		local launch = coin.Launch
		if launch then
			local stage = if launch.Migrated
				then "Migrated"
				else `{math.floor(launch.Progress)}% bonding curve`
			ageLabel.Text = `{age}  ·  {stage}  ·  by {launch.Creator}`
		else
			ageLabel.Text = age
		end
		priceStat.Value.Text = "$" .. Format.decimal(coin.Price * Config.UsdPerRx)
		priceStat.Sub.Text = Format.decimal(coin.Price) .. " " .. Config.Currency
		mcStat.Value.Text = Format.usd(coin.MarketCap)
		if s then
			mcStat.Sub.Text = Format.percent(s.Change) .. " " .. tf
			mcStat.Sub.TextColor3 = Util.changeColor(s.Change)
			volStat.Value.Text = Format.usd(s.Volume)
			volStat.Sub.Text = tf
			txStat.Value.Text = Format.compact(s.Buys + s.Sells)
			txStat.Sub.Text = `{Format.compact(s.Buys)} / {Format.compact(s.Sells)}`
		end
		liqStat.Value.Text = Format.usd(coin.Liquidity)
		liqStat.Sub.Text = Format.decimal(coin.PoolRx) .. " " .. Config.Currency
		holdersStat.Value.Text = Format.compact(coin.Holders)
	end

	local function refreshChart()
		if not ticker then
			return
		end
		local candles = Market.candles(ticker)
		chart.Set(candles or {}, Config.TotalSupply * Config.UsdPerRx)
	end

	-- Średnia cena wejścia (RX za token) bieżącej pozycji albo nil, gdy gracz nic nie trzyma.
	local function entryPrice(): number?
		local p = if ticker then Portfolio.position(ticker) else nil
		if not ticker or not p or p.BuyTokens <= 0 then
			return nil
		end
		if Portfolio.totalTokens(ticker) <= Config.DustTokens then
			return nil
		end
		return p.BuyValue / p.BuyTokens
	end

	local function refreshChartPosition()
		local p = if ticker then Portfolio.position(ticker) else nil
		chart.SetPosition(if p then p.Fills else {}, entryPrice())
	end

	local function refreshTrades()
		if not ticker then
			return
		end
		local trades = Market.trades(ticker)
		local now = Market.now()
		local me = Players.LocalPlayer.DisplayName
		for i, row in tradeRows do
			local trade = trades[i]
			row.Frame.Visible = trade ~= nil
			if trade then
				local color = if trade.Side == "Buy" then Colors.Green else Colors.Red
				local cells = row.Cells
				cells[1].Text = Format.age(now - trade.Time)
				cells[1].TextColor3 = Colors.TextMuted
				cells[2].Text = trade.Side
				cells[2].TextColor3 = color
				cells[3].Text = Format.usd(trade.MarketCap)
				cells[4].Text = Format.rx(trade.Rx)
				cells[4].TextColor3 = color
				cells[5].Text = Format.compact(trade.Tokens)
				-- Prywatny gracz widnieje pod anonimowym adresem z tej sesji.
				local mine = trade.IsPlayer and (trade.Trader == me or trade.Trader == Portfolio.State.Alias)
				cells[6].Text = if mine then trade.Trader .. " (you)" else trade.Trader
				cells[6].TextColor3 = if mine
					then Colors.Text
					elseif trade.IsPlayer then Color3.fromHex("BDBDBD")
					-- Boty-snajperzy z Pulse wyróżnione, żeby było widać, kto zrzuca.
					elseif not trade.IsPlayer and string.sub(trade.Trader, 1, 7) == "sniper_" then Colors.Yellow
					else Colors.TextMuted
			end
		end
	end

	local function refreshPosition()
		if not ticker then
			return
		end
		local coin = Market.coin(ticker)
		local p = Portfolio.position(ticker)
		local tokens = Portfolio.totalTokens(ticker)
		local value = if coin then tokens * coin.Price else 0
		local bought = if p then p.BoughtRx else 0
		local sold = if p then p.SoldRx else 0
		local pnl = sold + value - bought
		boughtStat.Value.Text = Format.decimal(bought)
		local entry = entryPrice()
		boughtStat.Sub.Text = if entry
			then "avg " .. Format.usd(entry * Config.TotalSupply * Config.UsdPerRx)
			else Config.Currency
		soldStat.Value.Text = Format.decimal(sold)
		soldStat.Sub.Text = Config.Currency
		holdingStat.Value.Text = Format.decimal(value)
		holdingStat.Sub.Text = Format.compact(tokens) .. " " .. ticker
		pnlStat.Value.Text = (if pnl > 0 then "+" else "") .. Format.decimal(pnl)
		pnlStat.Value.TextColor3 = if math.abs(pnl) < 1e-9 then Colors.Text else Util.changeColor(pnl)
		pnlStat.Sub.Text = if bought > 0 then Format.percent(pnl / bought * 100) else Config.Currency
	end

	local function describeTrigger(order: Types.TriggerOrder): (string, string)
		return `Sell {Format.compact(order.Tokens)} {order.Ticker}`,
			`TP {Format.usd(order.Above)}  ·  SL {Format.usd(order.Below)}`
	end

	local function describeLimit(order: Types.BookOrder): (string, string)
		local at = "$" .. Format.decimal(order.Price * Config.UsdPerRx)
		local total = order.Tokens + order.Filled
		local title = `{order.Side} {Format.compact(total)} {order.Ticker} @ {at}`
		local filled = if total > 0 then order.Filled / total * 100 else 0
		local detail = if order.Side == "Buy"
			then `Limit  ·  {string.format("%.0f", filled)}% filled  ·  {Format.rx(order.Reserved)} reserved`
			else `Limit  ·  {string.format("%.0f", filled)}% filled  ·  {Format.compact(order.Tokens)} left`
		return title, detail
	end

	local function orderRow(order: number, side: Types.Side, title: string, detail: string, id: string | number)
		local row = create("Frame", {
			Name = "Order" .. order,
			BackgroundColor3 = Colors.Background,
			Size = UDim2.new(1, 0, 0, 48),
			LayoutOrder = order,
			Parent = ordersList,
		}, { Util.corner(6), Util.padding(0, 12) })
		Util.label({
			Text = title,
			Size = 14,
			Font = Fonts.SemiBold,
			Color = if side == "Buy" then Colors.Green else Colors.Red,
			Position = UDim2.fromOffset(0, 6),
			FrameSize = UDim2.new(1, -36, 0, 18),
			Parent = row,
		})
		Util.label({
			Text = detail,
			Size = 13,
			Color = Colors.TextMuted,
			Position = UDim2.fromOffset(0, 25),
			FrameSize = UDim2.new(1, -36, 0, 16),
			Parent = row,
		})
		local cancel: TextButton = create("TextButton", {
			Name = "Cancel",
			AutoButtonColor = false,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.fromScale(1, 0.5),
			Size = UDim2.fromOffset(28, 28),
			BackgroundColor3 = Colors.Elevated,
			Text = "",
			Parent = row,
		}, { Util.round() })
		local x = Icons.close(12, Colors.TextMuted)
		x.AnchorPoint = Vector2.new(0.5, 0.5)
		x.Position = UDim2.fromScale(0.5, 0.5)
		x.Parent = cancel
		Util.hoverBackground(cancel, Colors.Elevated, Colors.Border)
		cancel.Activated:Connect(function()
			Actions.cancelOrder(id)
		end)
	end

	local function refreshOrders()
		for _, child in ordersList:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		local limits: { Types.BookOrder } = if ticker then Portfolio.orders(ticker) else {}
		local brackets: { Types.TriggerOrder } = if ticker then Portfolio.triggers(ticker) else {}
		local count = #limits + #brackets
		ordersCard.Visible = count > 0
		ordersTitle.Text = `Open orders ({count})`
		for i, order in limits do
			local title, detail = describeLimit(order)
			orderRow(i, order.Side, title, detail, order.Id)
		end
		for i, order in brackets do
			local title, detail = describeTrigger(order)
			orderRow(#limits + i, "Sell", title, detail, order.Id)
		end
	end

	Market.Changed:Connect(function()
		if frame.Visible then
			refreshHeader()
			refreshTrades()
			refreshPosition()
			book.Refresh()
		end
	end)
	Market.CandlesChanged:Connect(function(changed: string)
		if frame.Visible and changed == ticker then
			refreshChart()
		end
	end)
	Portfolio.Changed:Connect(function()
		refreshPosition()
		refreshOrders()
		refreshChartPosition()
		if frame.Visible then
			book.Refresh()
		end
	end)
	Settings.Changed:Connect(function(key: string)
		if key == "Timeframe" then
			refreshHeader()
		end
	end)

	return {
		Frame = frame,
		Open = function(newTicker: string)
			local def = Coins.get(newTicker)
			if not def then
				return
			end
			if newTicker ~= ticker then
				chart.ResetView()
			end
			ticker = newTicker
			tickerLabel.Text = def.Ticker
			nameLabel.Text = def.Name
			descLabel.Text = def.Description or ""
			descLabel.Visible = def.Description ~= nil
			refreshAlertButton()
			for _, child in iconSlot:GetChildren() do
				child:Destroy()
			end
			Icons.token(def.Color, def.Ticker, 48).Parent = iconSlot
			panel.SetCoin(newTicker)
			book.SetCoin(newTicker)
			refreshHeader()
			refreshChartPosition()
			refreshChart()
			refreshTrades()
			refreshPosition()
			refreshOrders()
		end,
	}
end

return CoinView
