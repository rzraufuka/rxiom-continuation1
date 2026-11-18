--!strict
-- Księga zleceń coina: aski (sprzedaż) nad ceną, bidy (kupno) pod nią. Każdy poziom łączy płynność
-- puli AMM w swoim przedziale cen ze zleceniami limit graczy, czyli pokazuje dokładnie to, co zje
-- transakcja rynkowa. Pasek w tle wiersza to skumulowana głębokość (market depth).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Amm = require(ReplicatedStorage.Shared.Amm)
local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Types = require(ReplicatedStorage.Shared.Types)

local State = script.Parent.Parent.Parent.State
local Market = require(State.Market)
local Portfolio = require(State.Portfolio)

local UI = script.Parent.Parent
local Theme = require(UI.Theme)
local Util = require(UI.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local ROW_HEIGHT = 22
local MAX_ROWS = 24
local HEADER_HEIGHT = 44
local COLUMNS_HEIGHT = 24
local SPREAD_HEIGHT = 40
local FOOTER_HEIGHT = 32
local TOP = HEADER_HEIGHT + COLUMNS_HEIGHT
-- Wysokość jednej połówki (asków albo bidów) to połowa tego, co zostaje po stałych elementach.
local HALF_OFFSET = (TOP + SPREAD_HEIGHT + FOOTER_HEIGHT) / 2

-- Szerokość poziomu cenowego jako % aktualnej ceny.
local STEPS = { 0.1, 0.25, 0.5, 1, 2.5 }
local DEFAULT_STEP = 3

export type OrderBookView = {
	Frame: Frame,
	SetCoin: (ticker: string) -> (),
	-- Odświeża księgę z bieżącego snapshotu rynku i zleceń gracza.
	Refresh: () -> (),
}

type Level = { Price: number, Tokens: number, Rx: number, Orders: number, Own: boolean }

type Row = {
	Button: TextButton,
	Bar: Frame,
	Marker: Frame,
	Price: TextLabel,
	Amount: TextLabel,
	Total: TextLabel,
}

local OrderBookView = {}

-- Krok ceny 1, 2 albo 5 razy potęga 10, najbliższy `x`.
local function niceStep(x: number): number
	local e = 10 ^ math.floor(math.log10(x))
	local m = x / e
	local nice = if m < 1.5 then 1 elseif m < 3.5 then 2 elseif m < 7.5 then 5 else 10
	return nice * e
end

local function inRange(price: number, lo: number, hi: number, first: boolean, side: Types.Side): boolean
	-- Pierwszy poziom zbiera też zlecenia po "złej" stronie ceny (snapshot sprzed sekundy).
	if side == "Sell" then
		return price <= hi and (first or price > lo)
	end
	return price >= lo and (first or price < hi)
end

local function buildSide(
	side: Types.Side,
	coin: Types.CoinSnapshot,
	tick: number,
	orders: { Types.BookLevel },
	own: { number }
): { Level }
	local pool = { Rx = coin.PoolRx, Tokens = coin.PoolTokens }
	local p0 = coin.Price
	local levels: { Level } = {}
	local edge = p0
	local base = if side == "Sell" then math.floor(p0 / tick + 1e-9) else math.ceil(p0 / tick - 1e-9)
	for i = 1, MAX_ROWS do
		local price = if side == "Sell" then (base + i) * tick else (base - i) * tick
		if price <= 0 then
			break
		end
		local lo, hi = math.min(edge, price), math.max(edge, price)
		local tokens, rx = Amm.depth(pool, lo, hi)
		local level: Level = { Price = price, Tokens = tokens, Rx = rx, Orders = 0, Own = false }
		for _, o in orders do
			if inRange(o.Price, lo, hi, i == 1, side) then
				level.Tokens += o.Tokens
				level.Rx += o.Tokens * o.Price
				level.Orders += o.Orders
			end
		end
		for _, ownPrice in own do
			if inRange(ownPrice, lo, hi, i == 1, side) then
				level.Own = true
			end
		end
		levels[i] = level
		edge = price
	end
	return levels
end

local function makeRow(parent: Instance, order: number, color: Color3): Row
	local button: TextButton = create("TextButton", {
		Name = "Level" .. order,
		AutoButtonColor = false,
		BackgroundColor3 = Colors.SurfaceHover,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		Text = "",
		LayoutOrder = order,
		Parent = parent,
	})
	local bar: Frame = create("Frame", {
		Name = "Depth",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = color,
		BackgroundTransparency = 0.85,
		BorderSizePixel = 0,
		Parent = button,
	})
	local marker: Frame = create("Frame", {
		Name = "Orders",
		Position = UDim2.fromOffset(0, 4),
		Size = UDim2.new(0, 3, 1, -8),
		BackgroundColor3 = Colors.Text,
		BorderSizePixel = 0,
		Visible = false,
		Parent = button,
	})
	local price = Util.label({
		Name = "Price",
		Text = "",
		Size = 13,
		Font = Fonts.Mono,
		Color = color,
		Position = UDim2.fromOffset(12, 0),
		FrameSize = UDim2.new(0.4, -12, 1, 0),
		Parent = button,
	})
	local amount = Util.label({
		Name = "Amount",
		Text = "",
		Size = 13,
		Font = Fonts.Mono,
		AlignX = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.4, 0),
		FrameSize = UDim2.fromScale(0.28, 1),
		Parent = button,
	})
	local total = Util.label({
		Name = "Total",
		Text = "",
		Size = 13,
		Font = Fonts.Mono,
		Color = Colors.TextMuted,
		AlignX = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.68, 0),
		FrameSize = UDim2.new(0.32, -12, 1, 0),
		Parent = button,
	})
	Util.hoverBackground(button, Colors.SurfaceHover, Colors.SurfaceHover, 1)
	return { Button = button, Bar = bar, Marker = marker, Price = price, Amount = amount, Total = total }
end

local function legendItem(parent: Instance, order: number, color: Color3, text: string)
	local item = Util.group("Legend" .. order, order, Util.hlist(5))
	item.Parent = parent
	create("Frame", {
		Name = "Swatch",
		Size = UDim2.fromOffset(3, 12),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		LayoutOrder = 1,
		Parent = item,
	})
	Util.text({ Text = text, Size = 12, Color = Colors.TextMuted, Order = 2, Parent = item })
end

-- `onPick(usd)` jest wywoływane po kliknięciu poziomu (cena poziomu w $).
function OrderBookView.new(onPick: (usd: number) -> ()): OrderBookView
	local ticker: string? = nil
	local stepIndex = DEFAULT_STEP

	local frame: Frame = create("Frame", {
		Name = "OrderBook",
		BackgroundColor3 = Colors.Surface,
		ClipsDescendants = true,
	}, { Util.corner(8), Util.stroke(Colors.Border) })

	-- Nagłówek: tytuł, legenda, szerokość poziomu
	local header = create("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
		Parent = frame,
	}, { Util.padding(0, 12) })
	local titleRow = Util.group("Title", 0, Util.hlist(12))
	titleRow.AnchorPoint = Vector2.new(0, 0.5)
	titleRow.Position = UDim2.fromScale(0, 0.5)
	titleRow.Parent = header
	Util.text({ Text = "Order Book", Size = 15, Font = Fonts.SemiBold, Order = 1, Parent = titleRow })
	legendItem(titleRow, 2, Colors.Text, "Yours")
	legendItem(titleRow, 3, Colors.TextDim, "Players")
	local stepButton: TextButton = create("TextButton", {
		Name = "Step",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(56, 26),
		BackgroundColor3 = Colors.Elevated,
		Text = "",
		TextSize = 13,
		FontFace = Fonts.Medium,
		TextColor3 = Colors.Text,
		Parent = header,
	}, { Util.corner(6) })
	Util.hoverBackground(stepButton, Colors.Elevated, Colors.Border)

	-- Nagłówki kolumn
	local columns = create("Frame", {
		Name = "Columns",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, HEADER_HEIGHT),
		Size = UDim2.new(1, 0, 0, COLUMNS_HEIGHT),
		Parent = frame,
	})
	Util.label({
		Text = "Price ($)",
		Size = 12,
		Color = Colors.TextMuted,
		Position = UDim2.fromOffset(12, 0),
		FrameSize = UDim2.new(0.4, -12, 1, 0),
		Parent = columns,
	})
	local amountHeader = Util.label({
		Text = "Amount",
		Size = 12,
		Color = Colors.TextMuted,
		AlignX = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.4, 0),
		FrameSize = UDim2.fromScale(0.28, 1),
		Parent = columns,
	})
	Util.label({
		Text = `Total ({Config.Currency})`,
		Size = 12,
		Color = Colors.TextMuted,
		AlignX = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.68, 0),
		FrameSize = UDim2.new(0.32, -12, 1, 0),
		Parent = columns,
	})

	-- Aski: najbliższy cenie poziom na dole, tuż nad ceną
	local asksFrame: Frame = create("Frame", {
		Name = "Asks",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Position = UDim2.fromOffset(0, TOP),
		Size = UDim2.new(1, 0, 0.5, -HALF_OFFSET),
		Parent = frame,
	}, { Util.vlist(0, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Bottom) })
	local askRows: { Row } = {}
	for i = 1, MAX_ROWS do
		askRows[i] = makeRow(asksFrame, MAX_ROWS - i, Colors.Red)
	end

	-- Cena bieżąca między stronami
	local spread = create("Frame", {
		Name = "Spread",
		BackgroundColor3 = Colors.Background,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0.5, TOP - HALF_OFFSET),
		Size = UDim2.new(1, 0, 0, SPREAD_HEIGHT),
		Parent = frame,
	}, { Util.padding(0, 12) })
	local priceLabel = Util.label({
		Name = "Price",
		Text = "",
		Size = 17,
		Font = Fonts.Bold,
		FrameSize = UDim2.fromScale(0.6, 1),
		Parent = spread,
	})
	local mcLabel = Util.label({
		Name = "MarketCap",
		Text = "",
		Size = 13,
		Color = Colors.TextMuted,
		AlignX = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		FrameSize = UDim2.fromScale(0.4, 1),
		Parent = spread,
	})

	-- Bidy: najbliższy cenie poziom na górze
	local bidsFrame: Frame = create("Frame", {
		Name = "Bids",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Position = UDim2.new(0, 0, 0.5, TOP - HALF_OFFSET + SPREAD_HEIGHT),
		Size = UDim2.new(1, 0, 0.5, -HALF_OFFSET),
		Parent = frame,
	}, { Util.vlist(0, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top) })
	local bidRows: { Row } = {}
	for i = 1, MAX_ROWS do
		bidRows[i] = makeRow(bidsFrame, i, Colors.Green)
	end

	-- Stopka: przewaga kupujących/sprzedających w widocznej głębokości
	local footer = create("Frame", {
		Name = "Ratio",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, FOOTER_HEIGHT),
		Parent = frame,
	}, { Util.padding(0, 12) })
	local bidShare = Util.label({
		Text = "",
		Size = 12,
		Font = Fonts.SemiBold,
		Color = Colors.Green,
		FrameSize = UDim2.new(0, 52, 1, 0),
		Parent = footer,
	})
	local askShare = Util.label({
		Text = "",
		Size = 12,
		Font = Fonts.SemiBold,
		Color = Colors.Red,
		AlignX = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		FrameSize = UDim2.new(0, 52, 1, 0),
		Parent = footer,
	})
	local ratioTrack = create("Frame", {
		Name = "Track",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 56, 0.5, 0),
		Size = UDim2.new(1, -112, 0, 6),
		BackgroundColor3 = Colors.Red,
		BorderSizePixel = 0,
		Parent = footer,
	}, { Util.round() })
	local ratioFill = create("Frame", {
		Name = "Bids",
		Size = UDim2.fromScale(0.5, 1),
		BackgroundColor3 = Colors.Green,
		BorderSizePixel = 0,
		Parent = ratioTrack,
	}, { Util.round() })

	------------------------------------------------------------------

	local askLevels: { Level } = {}
	local bidLevels: { Level } = {}

	local function visibleRows(container: Frame, rows: { Row }): number
		local rowHeight = rows[1].Button.AbsoluteSize.Y
		if rowHeight <= 0 then
			return MAX_ROWS
		end
		return math.clamp(math.floor(container.AbsoluteSize.Y / rowHeight), 1, MAX_ROWS)
	end

	local function render(rows: { Row }, levels: { Level }, count: number, maxDepth: number, decimals: number)
		local cumulative = 0
		for i, row in rows do
			local level = levels[i]
			row.Button.Visible = level ~= nil
			if not level then
				continue
			end
			cumulative += level.Rx
			local share = if i <= count and maxDepth > 0 then math.min(cumulative / maxDepth, 1) else 0
			row.Bar.Size = UDim2.fromScale(share, 1)
			row.Price.Text = string.format("%." .. decimals .. "f", level.Price * Config.UsdPerRx)
			row.Amount.Text = Format.compact(level.Tokens)
			row.Total.Text = Format.decimal(level.Rx)
			row.Marker.Visible = level.Own or level.Orders > 0
			row.Marker.BackgroundColor3 = if level.Own then Colors.Text else Colors.TextDim
		end
	end

	local function sum(levels: { Level }, count: number): number
		local total = 0
		for i = 1, math.min(count, #levels) do
			total += levels[i].Rx
		end
		return total
	end

	local function refresh()
		local coin = if ticker then Market.coin(ticker) else nil
		if not ticker or not coin or coin.Price <= 0 then
			return
		end
		local step = STEPS[stepIndex]
		stepButton.Text = step .. "%"
		amountHeader.Text = `Amount ({ticker})`

		local usd = coin.Price * Config.UsdPerRx
		local tickUsd = niceStep(usd * step / 100)
		local decimals = math.clamp(-math.floor(math.log10(tickUsd) + 1e-9), 0, 16)
		local tick = tickUsd / Config.UsdPerRx

		local ownBids, ownAsks = {}, {}
		for _, order in Portfolio.orders(ticker) do
			table.insert(if order.Side == "Buy" then ownBids else ownAsks, order.Price)
		end
		local book = coin.Book or { Bids = {}, Asks = {} }
		askLevels = buildSide("Sell", coin, tick, book.Asks, ownAsks)
		bidLevels = buildSide("Buy", coin, tick, book.Bids, ownBids)

		local askCount = visibleRows(asksFrame, askRows)
		local bidCount = visibleRows(bidsFrame, bidRows)
		local askDepth = sum(askLevels, askCount)
		local bidDepth = sum(bidLevels, bidCount)
		local maxDepth = math.max(askDepth, bidDepth)
		render(askRows, askLevels, askCount, maxDepth, decimals)
		render(bidRows, bidLevels, bidCount, maxDepth, decimals)

		local candle = coin.Candle
		priceLabel.Text = "$" .. Format.plain(usd, 5)
		priceLabel.TextColor3 = if candle.C >= candle.O then Colors.Green else Colors.Red
		mcLabel.Text = "MC " .. Format.usd(coin.MarketCap)

		local total = askDepth + bidDepth
		local bidRatio = if total > 0 then bidDepth / total else 0.5
		ratioFill.Size = UDim2.fromScale(bidRatio, 1)
		bidShare.Text = string.format("B %d%%", math.round(bidRatio * 100))
		askShare.Text = string.format("%d%% S", 100 - math.round(bidRatio * 100))
	end

	local function connectPick(rows: { Row }, levels: () -> { Level })
		for i, row in rows do
			row.Button.Activated:Connect(function()
				local level = levels()[i]
				if level then
					onPick(level.Price * Config.UsdPerRx)
				end
			end)
		end
	end
	connectPick(askRows, function()
		return askLevels
	end)
	connectPick(bidRows, function()
		return bidLevels
	end)

	stepButton.Activated:Connect(function()
		stepIndex = stepIndex % #STEPS + 1
		refresh()
	end)
	asksFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(refresh)

	return {
		Frame = frame,
		SetCoin = function(newTicker: string)
			ticker = newTicker
			refresh()
		end,
		Refresh = refresh,
	}
end

return OrderBookView
