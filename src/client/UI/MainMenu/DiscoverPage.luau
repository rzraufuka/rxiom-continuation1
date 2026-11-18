--!strict
-- Strona Discover: duża karta "Prices" z rankingiem coinów oraz prawa kolumna z "Top Movers"
-- i kartą doładowania portfela RXI.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Types = require(ReplicatedStorage.Shared.Types)

local State = script.Parent.Parent.Parent.State
local Actions = require(State.Actions)
local Market = require(State.Market)
local Portfolio = require(State.Portfolio)
local Settings = require(State.Settings)

local UI = script.Parent.Parent
local Icons = require(UI.Icons)
local Sparkline = require(UI.Sparkline)
local Theme = require(UI.Theme)
local Util = require(UI.Util)
local QuickBuy = require(script.Parent.QuickBuy)

type CoinDef = Coins.CoinDef
type CoinSnapshot = Types.CoinSnapshot

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local RIGHT_WIDTH = 380
local GAP = 20
local HEADER_HEIGHT = 76
local ROW_HEIGHT = 66
local RANK_WIDTH = 40
local ACTIONS_WIDTH = 126
local MOVERS_COLLAPSED = 5
local SORTS = { "Top", "Trending", "Gainers", "New" }

export type DiscoverPage = {
	Frame: Frame,
	-- Elementy pokazywane w samouczku.
	Targets: { [string]: GuiObject },
}

local DiscoverPage = {}

-- Karta z obrysem do środka: kolumny są w przewijanych ramkach, które przycinają obrys zewnętrzny.
local function card(name: string): Frame
	return create("Frame", {
		Name = name,
		BackgroundColor3 = Colors.Surface,
	}, {
		Util.corner(16),
		create("UIStroke", {
			Color = Colors.Border,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			BorderStrokePosition = Enum.BorderStrokePosition.Inner,
		}),
	})
end

local function pill(name: string, width: number): TextButton
	return create("TextButton", {
		Name = name,
		AutoButtonColor = false,
		Size = UDim2.fromOffset(width, 36),
		BackgroundColor3 = Colors.Elevated,
		Text = "",
	}, { Util.round() })
end

local function dots(parent: Instance)
	local group = Util.group("Dots", 0, Util.hlist(3, nil, Enum.HorizontalAlignment.Center))
	group.AnchorPoint = Vector2.new(0.5, 0.5)
	group.Position = UDim2.fromScale(0.5, 0.5)
	group.Parent = parent
	for i = 1, 3 do
		Icons.dot(4, Colors.Text, i).Parent = group
	end
end

local function sortValue(sort: string, coin: CoinSnapshot, timeframe: string): number
	local stats = coin.Stats[timeframe]
	if sort == "Trending" then
		return if stats then stats.Volume else 0
	elseif sort == "Gainers" then
		return if stats then stats.Change else 0
	elseif sort == "New" then
		return coin.LaunchedAt
	end
	return coin.MarketCap
end

local function usdPrice(coin: CoinSnapshot): string
	return "$" .. Format.decimal(coin.Price * Config.UsdPerRx)
end

type Menus = { Open: Frame? }

-- Pigułka z rozwijaną listą. Ramka ma stały rozmiar, a lista wisi pod nią poza jej granicami,
-- więc otwarcie nie przesuwa sąsiednich kontrolek.
local function dropdown(
	menus: Menus,
	name: string,
	width: number,
	order: number,
	options: { string },
	getValue: () -> string,
	onSelect: (string) -> ()
): Frame
	local wrapper: Frame = create("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(width, 36),
		LayoutOrder = order,
	})
	local button = pill("Button", width)
	button.Size = UDim2.fromScale(1, 1)
	button.Parent = wrapper
	local label = Util.label({
		Text = "",
		Size = 15,
		Font = Fonts.Medium,
		Position = UDim2.fromOffset(16, 0),
		FrameSize = UDim2.new(1, -44, 1, 0),
		Parent = button,
	})
	local chevron = Icons.chevronDown(12, Colors.TextMuted)
	chevron.AnchorPoint = Vector2.new(1, 0.5)
	chevron.Position = UDim2.new(1, -16, 0.5, 0)
	chevron.Parent = button
	Util.hoverBackground(button, Colors.Elevated, Colors.Border)

	local menu: Frame = create("Frame", {
		Name = "Menu",
		Position = UDim2.new(0, 0, 1, 6),
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Colors.Elevated,
		Visible = false,
		ZIndex = 10,
		Parent = wrapper,
	}, {
		Util.corner(12),
		Util.stroke(Colors.Border),
		Util.padding(6),
		Util.vlist(2, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top),
	})
	local items: { [string]: TextButton } = {}
	local function refresh()
		local value = getValue()
		label.Text = value
		for option, item in items do
			item.TextColor3 = if option == value then Colors.Text else Colors.TextMuted
		end
	end
	for i, option in options do
		local item: TextButton = create("TextButton", {
			Name = option,
			AutoButtonColor = false,
			Size = UDim2.new(1, 0, 0, 32),
			BackgroundColor3 = Colors.Border,
			BackgroundTransparency = 1,
			Text = option,
			TextSize = 14,
			FontFace = Fonts.Medium,
			TextColor3 = Colors.TextMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = i,
			ZIndex = 11,
			Parent = menu,
		}, { Util.corner(8), Util.padding(0, 10) })
		Util.hoverBackground(item, Colors.Border, Colors.Border, 1)
		item.Activated:Connect(function()
			menu.Visible = false
			menus.Open = nil
			onSelect(option)
			refresh()
		end)
		items[option] = item
	end
	button.Activated:Connect(function()
		local opening = not menu.Visible
		local other = menus.Open
		if other and other ~= menu then
			other.Visible = false
		end
		menu.Visible = opening
		menus.Open = if opening then menu else nil
	end)
	refresh()
	return wrapper
end

local function quickBuy(order: number): Frame
	return QuickBuy.new(order)
end

type PriceRow = {
	Ticker: string,
	Frame: TextButton,
	Rank: TextLabel,
	Update: (coin: CoinSnapshot) -> (),
}

local function priceRow(def: CoinDef, openCoin: (string) -> ()): PriceRow
	local row: TextButton = create("TextButton", {
		Name = def.Ticker,
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
		BackgroundColor3 = Colors.SurfaceHover,
		BackgroundTransparency = 1,
		Text = "",
	}, { Util.corner(12) })
	local divider = Util.divider(false, Colors.Divider)
	divider.AnchorPoint = Vector2.new(0, 1)
	divider.Position = UDim2.fromScale(0, 1)
	divider.Parent = row

	local rank = Util.label({
		Name = "Rank",
		Text = "",
		Size = 16,
		Font = Fonts.Medium,
		Color = Colors.TextMuted,
		AlignX = Enum.TextXAlignment.Center,
		FrameSize = UDim2.new(0, RANK_WIDTH, 1, 0),
		Parent = row,
	})
	local body = create("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(RANK_WIDTH + 8, 0),
		Size = UDim2.new(1, -(RANK_WIDTH + 8 + ACTIONS_WIDTH), 1, 0),
		Parent = row,
	})
	local function cell(name: string, x: number, width: number): Frame
		return create("Frame", {
			Name = name,
			BackgroundTransparency = 1,
			Position = UDim2.fromScale(x, 0),
			Size = UDim2.fromScale(width, 1),
			Parent = body,
		})
	end

	local coinCell = cell("Coin", 0, 0.3)
	local icon = Icons.token(def.Color, def.Ticker, 40, nil, true)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.fromScale(0, 0.5)
	icon.Parent = coinCell
	Util.label({
		Name = "Name",
		Text = def.Name,
		Size = 16,
		Font = Fonts.SemiBold,
		Position = UDim2.fromOffset(54, 13),
		FrameSize = UDim2.new(1, -58, 0, 20),
		Parent = coinCell,
	})
	local sub = Util.label({
		Name = "Sub",
		Text = def.Ticker,
		Size = 13,
		Color = Colors.TextMuted,
		Position = UDim2.fromOffset(54, 35),
		FrameSize = UDim2.new(1, -58, 0, 16),
		Parent = coinCell,
	})

	local price =
		Util.label({ Name = "Value", Text = "", Size = 16, Font = Fonts.Medium, Parent = cell("Price", 0.3, 0.16) })

	local chartCell = cell("Chart", 0.46, 0.21)
	local spark = Sparkline.new(23, Vector2.new(120, 32))
	spark.Frame.AnchorPoint = Vector2.new(0, 0.5)
	spark.Frame.Position = UDim2.fromScale(0, 0.5)
	spark.Frame.Parent = chartCell

	local change =
		Util.label({ Name = "Value", Text = "", Size = 16, Font = Fonts.SemiBold, Parent = cell("Change", 0.69, 0.12) })

	local capCell = cell("MarketCap", 0.81, 0.19)
	local cap = Util.label({
		Name = "Value",
		Text = "",
		Size = 16,
		Font = Fonts.Medium,
		Position = UDim2.fromOffset(0, 13),
		FrameSize = UDim2.new(1, 0, 0, 20),
		Parent = capCell,
	})
	local volume = Util.label({
		Name = "Volume",
		Text = "",
		Size = 13,
		Color = Colors.TextMuted,
		Position = UDim2.fromOffset(0, 35),
		FrameSize = UDim2.new(1, 0, 0, 16),
		Parent = capCell,
	})

	local buy: TextButton = create("TextButton", {
		Name = "Buy",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -48, 0.5, 0),
		Size = UDim2.fromOffset(68, 34),
		BackgroundColor3 = Colors.Primary,
		Text = "Buy",
		TextSize = 15,
		FontFace = Fonts.SemiBold,
		TextColor3 = Colors.OnPrimary,
		ZIndex = 2,
		Parent = row,
	}, { Util.round() })
	Util.hoverBackground(buy, Colors.Primary, Colors.PrimaryHover)
	local more: TextButton = create("TextButton", {
		Name = "More",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -4, 0.5, 0),
		Size = UDim2.fromOffset(34, 34),
		BackgroundColor3 = Colors.Elevated,
		Text = "",
		ZIndex = 2,
		Parent = row,
	}, { Util.round() })
	dots(more)
	Util.hoverBackground(more, Colors.Elevated, Colors.Border)

	local buying = false
	buy.Activated:Connect(function()
		if buying then
			return
		end
		buying = true
		buy.Text = "..."
		Actions.buy(def.Ticker, Settings.State.QuickBuy)
		buying = false
		buy.Text = "Buy"
	end)
	more.Activated:Connect(function()
		openCoin(def.Ticker)
	end)
	row.Activated:Connect(function()
		openCoin(def.Ticker)
	end)
	row.MouseEnter:Connect(function()
		Util.tween(row, { BackgroundTransparency = 0 })
	end)
	row.MouseLeave:Connect(function()
		Util.tween(row, { BackgroundTransparency = 1 })
	end)

	local function update(coin: CoinSnapshot)
		local stats = coin.Stats[Settings.State.Timeframe]
		sub.Text = `{def.Ticker}  |  {Format.age(Market.now() - coin.LaunchedAt)}`
		price.Text = usdPrice(coin)
		cap.Text = Format.usd(coin.MarketCap)
		if stats then
			change.Text = Format.percent(stats.Change)
			change.TextColor3 = Util.changeColor(stats.Change)
			volume.Text = "Vol " .. Format.usd(stats.Volume)
		end
		local points = table.clone(coin.Spark)
		table.insert(points, coin.Price)
		spark.Set(points, Util.changeColor(coin.Price - (points[1] or coin.Price)))
	end

	return { Ticker = def.Ticker, Frame = row, Rank = rank, Update = update }
end

type MoverRow = {
	Ticker: string,
	Frame: TextButton,
	Update: (coin: CoinSnapshot) -> (),
}

local function moverRow(def: CoinDef, openCoin: (string) -> ()): MoverRow
	local row: TextButton = create("TextButton", {
		Name = def.Ticker,
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, 62),
		BackgroundColor3 = Colors.SurfaceHover,
		BackgroundTransparency = 1,
		Text = "",
	}, { Util.corner(10), Util.padding(0, 8) })
	local divider = Util.divider(false, Colors.Divider)
	divider.AnchorPoint = Vector2.new(0, 1)
	divider.Position = UDim2.fromScale(0, 1)
	divider.Parent = row
	local icon = Icons.token(def.Color, def.Ticker, 38, nil, true)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.fromScale(0, 0.5)
	icon.Parent = row
	Util.label({
		Name = "Name",
		Text = def.Name,
		Size = 16,
		Font = Fonts.SemiBold,
		Position = UDim2.fromOffset(52, 12),
		FrameSize = UDim2.new(1, -160, 0, 20),
		Parent = row,
	})
	Util.label({
		Name = "Ticker",
		Text = def.Ticker,
		Size = 13,
		Color = Colors.TextMuted,
		Position = UDim2.fromOffset(52, 34),
		FrameSize = UDim2.new(1, -160, 0, 16),
		Parent = row,
	})
	local price = Util.label({
		Name = "Price",
		Text = "",
		Size = 15,
		Font = Fonts.SemiBold,
		AlignX = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 12),
		FrameSize = UDim2.fromOffset(110, 20),
		Parent = row,
	})
	local change = Util.label({
		Name = "Change",
		Text = "",
		Size = 13,
		Font = Fonts.Medium,
		AlignX = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 34),
		FrameSize = UDim2.fromOffset(110, 16),
		Parent = row,
	})
	row.Activated:Connect(function()
		openCoin(def.Ticker)
	end)
	row.MouseEnter:Connect(function()
		Util.tween(row, { BackgroundTransparency = 0 })
	end)
	row.MouseLeave:Connect(function()
		Util.tween(row, { BackgroundTransparency = 1 })
	end)

	local function update(coin: CoinSnapshot)
		local stats = coin.Stats[Settings.State.Timeframe]
		price.Text = Format.usd(coin.MarketCap)
		if stats then
			change.Text = Format.percent(stats.Change)
			change.TextColor3 = Util.changeColor(stats.Change)
		end
	end

	return { Ticker = def.Ticker, Frame = row, Update = update }
end

-- Karta zachęcająca do odebrania darmowych RXI (Deposit).
local function topUpCard(): (Frame, () -> ())
	local frame = card("TopUp")
	frame.Size = UDim2.new(1, 0, 0, 200)
	Util.padding(24).Parent = frame
	local textWidth = UDim2.new(1, -118, 0, 0)
	local title = Util.label({
		Name = "Title",
		Text = `Top up your\n{Config.Currency} wallet.`,
		Size = 22,
		Font = Fonts.Bold,
		FrameSize = textWidth + UDim2.fromOffset(0, 56),
		Parent = frame,
	})
	title.TextYAlignment = Enum.TextYAlignment.Top
	title.TextTruncate = Enum.TextTruncate.None
	local body = Util.label({
		Name = "Body",
		Text = `Claim free {Config.Currency} every {math.floor(Config.Faucet.Cooldown / 60)} minutes and start trading on {Theme.Site}.`,
		Size = 14,
		Color = Colors.TextMuted,
		Position = UDim2.fromOffset(0, 64),
		FrameSize = textWidth + UDim2.fromOffset(0, 54),
		Parent = frame,
	})
	body.TextWrapped = true
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.TextTruncate = Enum.TextTruncate.None

	local link: TextButton = create("TextButton", {
		Name = "Claim",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 24),
		BackgroundTransparency = 1,
		Text = "",
		Parent = frame,
	}, { Util.hlist(8) })
	local linkLabel = Util.text({ Text = "", Size = 16, Font = Fonts.SemiBold, Order = 1, Parent = link })
	local arrow = Icons.arrow(14, Colors.Text, "Right", 2)
	arrow.Parent = link
	link.Activated:Connect(Actions.claimFaucet)

	local badge = Icons.shieldBadge(112)
	badge.AnchorPoint = Vector2.new(1, 0.5)
	badge.Position = UDim2.fromScale(1, 0.5)
	badge.Parent = frame

	local function refresh()
		local wait = Portfolio.State.FaucetReadyAt - os.time()
		local ready = wait <= 0
		linkLabel.Text = if ready then `Claim free {Config.Currency}` else `Next claim in {Format.age(wait)}`
		linkLabel.TextColor3 = if ready then Colors.Text else Colors.TextMuted
		arrow.Visible = ready
		link.Active = ready
	end
	refresh()
	return frame, refresh
end

function DiscoverPage.new(openCoin: (ticker: string) -> ()): DiscoverPage
	local frame: Frame = create("Frame", {
		Name = "Discover",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
	})
	local menus: Menus = { Open = nil }

	-- Karta "Prices"
	local prices = card("Prices")
	prices.Size = UDim2.new(1, -(RIGHT_WIDTH + GAP), 1, 0)
	prices.Parent = frame
	-- Nagłówek nad listą (ZIndex), żeby rozwijane menu przykrywało wiersze.
	local header = create("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
		ZIndex = 5,
		Parent = prices,
	}, { Util.padding(0, 24) })
	Util.label({
		Name = "Title",
		Text = "Prices",
		Size = 22,
		Font = Fonts.SemiBold,
		FrameSize = UDim2.new(0, 200, 1, 0),
		Parent = header,
	})
	local controls = Util.group("Controls", 0, Util.hlist(10, nil, Enum.HorizontalAlignment.Right))
	controls.AnchorPoint = Vector2.new(1, 0.5)
	controls.Position = UDim2.fromScale(1, 0.5)
	controls.Parent = header
	local timeframes = {}
	for i, timeframe in Config.Timeframes do
		timeframes[i] = timeframe.Key
	end
	dropdown(menus, "Sort", 132, 1, SORTS, function()
		return Settings.State.Sort
	end, function(value)
		Settings.set("Sort", value)
	end).Parent =
		controls
	dropdown(menus, "Timeframe", 88, 2, timeframes, function()
		return Settings.State.Timeframe
	end, function(value)
		Settings.set("Timeframe", value)
	end).Parent =
		controls
	local quickBuyControl = quickBuy(3)
	quickBuyControl.Parent = controls

	local headerDivider = Util.divider(false, Colors.Divider)
	headerDivider.Position = UDim2.fromOffset(24, HEADER_HEIGHT)
	headerDivider.Size = UDim2.new(1, -48, 0, 1)
	headerDivider.Parent = prices

	local list: ScrollingFrame = create("ScrollingFrame", {
		Name = "Rows",
		Position = UDim2.fromOffset(0, HEADER_HEIGHT + 1),
		Size = UDim2.new(1, 0, 1, -(HEADER_HEIGHT + 1)),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Colors.Border,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = prices,
	}, { Util.padding(4, 16, 12, 16), Util.vlist(0, nil, Enum.VerticalAlignment.Top) })
	local empty = Util.label({
		Name = "Empty",
		Text = "No coins match your search",
		Size = 16,
		Color = Colors.TextMuted,
		AlignX = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, HEADER_HEIGHT + 1),
		FrameSize = UDim2.new(1, 0, 0, 120),
		Parent = prices,
	})

	-- Prawa kolumna
	local side: ScrollingFrame = create("ScrollingFrame", {
		Name = "Side",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, RIGHT_WIDTH, 1, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 0,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = frame,
	}, { Util.vlist(GAP, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top) })

	local movers = card("TopMovers")
	movers.Size = UDim2.fromScale(1, 0)
	movers.AutomaticSize = Enum.AutomaticSize.Y
	movers.LayoutOrder = 1
	movers.Parent = side
	Util.padding(20, 20, 14, 20).Parent = movers
	Util.vlist(8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top).Parent = movers
	local moversHeader = create("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 36),
		LayoutOrder = 1,
		Parent = movers,
	})
	local moversTitle = Util.label({
		Name = "Title",
		Text = "",
		Size = 20,
		Font = Fonts.SemiBold,
		FrameSize = UDim2.new(1, -100, 1, 0),
		Parent = moversHeader,
	})
	moversTitle.RichText = true
	local seeAll = pill("SeeAll", 88)
	seeAll.AnchorPoint = Vector2.new(1, 0.5)
	seeAll.Position = UDim2.fromScale(1, 0.5)
	seeAll.Text = "See All"
	seeAll.TextSize = 14
	seeAll.FontFace = Fonts.Medium
	seeAll.TextColor3 = Colors.Text
	seeAll.Parent = moversHeader
	Util.hoverBackground(seeAll, Colors.Elevated, Colors.Border)
	local moversList = create("Frame", {
		Name = "List",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = movers,
	}, { Util.vlist(0, nil, Enum.VerticalAlignment.Top) })

	local topUp, refreshTopUp = topUpCard()
	topUp.LayoutOrder = 2
	topUp.Parent = side

	local priceRows: { PriceRow } = {}
	local moverRows: { MoverRow } = {}
	for _, def in Coins.List do
		local r = priceRow(def, openCoin)
		r.Frame.Parent = list
		table.insert(priceRows, r)
		local m = moverRow(def, openCoin)
		m.Frame.Parent = moversList
		table.insert(moverRows, m)
	end

	local showAll = false

	local function refresh()
		local s = Settings.State
		local query = string.lower(s.Search)

		local visible: { PriceRow } = {}
		for _, r in priceRows do
			local coin = Market.coin(r.Ticker)
			local def = Coins.ByTicker[r.Ticker]
			local matches = query == ""
				or string.find(string.lower(def.Ticker), query, 1, true) ~= nil
				or string.find(string.lower(def.Name), query, 1, true) ~= nil
			r.Frame.Visible = matches and coin ~= nil
			if coin then
				r.Update(coin)
				if matches then
					table.insert(visible, r)
				end
			end
		end
		table.sort(visible, function(a, b)
			local ca, cb = Market.coin(a.Ticker) :: CoinSnapshot, Market.coin(b.Ticker) :: CoinSnapshot
			return sortValue(s.Sort, ca, s.Timeframe) > sortValue(s.Sort, cb, s.Timeframe)
		end)
		for i, r in visible do
			r.Frame.LayoutOrder = i
			r.Rank.Text = tostring(i)
		end
		empty.Visible = #visible == 0

		-- Top Movers: największa zmiana (w górę lub w dół) w wybranym przedziale.
		local ranked: { MoverRow } = {}
		for _, m in moverRows do
			local coin = Market.coin(m.Ticker)
			m.Frame.Visible = false
			if coin then
				m.Update(coin)
				table.insert(ranked, m)
			end
		end
		local function absChange(m: MoverRow): number
			local stats = (Market.coin(m.Ticker) :: CoinSnapshot).Stats[s.Timeframe]
			return if stats then math.abs(stats.Change) else 0
		end
		table.sort(ranked, function(a, b)
			return absChange(a) > absChange(b)
		end)
		for i, m in ranked do
			m.Frame.LayoutOrder = i
			m.Frame.Visible = showAll or i <= MOVERS_COLLAPSED
		end
		moversTitle.Text = `Top Movers <font color="#575757">· {s.Timeframe}</font>`
		seeAll.Text = if showAll then "See Less" else "See All"
		refreshTopUp()
	end

	seeAll.Activated:Connect(function()
		showAll = not showAll
		refresh()
	end)
	Market.Changed:Connect(refresh)
	Portfolio.Changed:Connect(refreshTopUp)
	Settings.Changed:Connect(function(key: string)
		if key == "Search" or key == "Sort" or key == "Timeframe" then
			refresh()
		end
	end)
	refresh()

	return {
		Frame = frame,
		Targets = { Prices = prices, Rows = list, QuickBuy = quickBuyControl, Movers = movers, Side = side },
	}
end

return DiscoverPage
