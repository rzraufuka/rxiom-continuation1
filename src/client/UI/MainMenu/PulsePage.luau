--!strict
-- Strona Pulse: coiny tworzone przez graczy w trzech kolumnach jak na axiom.trade:
-- New Pairs (świeże), Final Stretch (blisko końca bonding curve) i Migrated (ukończone).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Types = require(ReplicatedStorage.Shared.Types)

local State = script.Parent.Parent.Parent.State
local Actions = require(State.Actions)
local Market = require(State.Market)
local Settings = require(State.Settings)

local UI = script.Parent.Parent
local Icons = require(UI.Icons)
local Theme = require(UI.Theme)
local Toast = require(UI.Toast)
local Util = require(UI.Util)
local CreateCoin = require(script.Parent.CreateCoin)
local QuickBuy = require(script.Parent.QuickBuy)

type CoinDef = Coins.CoinDef
type CoinSnapshot = Types.CoinSnapshot
type LaunchInfo = Types.LaunchInfo

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local HEADER_HEIGHT = 56
local GAP = 16
local COLUMN_HEADER = 60
local ROW_HEIGHT = 100
local ICON_SIZE = 64
local RIGHT_WIDTH = 150

local MUTED = Colors.TextMuted:ToHex()
local GREEN = Colors.Green:ToHex()
local RED = Colors.Red:ToHex()

-- "New" | "Stretch" | "Migrated"
type ColumnKey = string

local COLUMNS: { { Key: ColumnKey, Title: string, Empty: string } } = {
	{ Key = "New", Title = "New Pairs", Empty = "No coins yet. Launch the first one!" },
	{ Key = "Stretch", Title = "Final Stretch", Empty = "No coins close to migrating yet" },
	{ Key = "Migrated", Title = "Migrated", Empty = "No coins have migrated yet" },
}

export type PulsePage = {
	Frame: Frame,
	Refresh: () -> (),
}

local PulsePage = {}

-- Karta jak na Discover: obrys do środka, bo listy w środku przycinają obrys zewnętrzny.
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

local function columnOf(launch: LaunchInfo): ColumnKey
	if launch.Migrated then
		return "Migrated"
	end
	return if launch.Progress >= Config.Launch.FinalStretch then "Stretch" else "New"
end

type Row = {
	Ticker: string,
	Frame: TextButton,
	Update: (coin: CoinSnapshot, launch: LaunchInfo) -> (),
}

local function pulseRow(def: CoinDef, openCoin: (string) -> ()): Row
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
	local content = create("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = row,
	}, { Util.padding(0, 12) })

	local icon = Icons.token(def.Color, def.Ticker, ICON_SIZE)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.fromScale(0, 0.5)
	icon.Parent = content

	-- Środek: nazwa, wiek i twórca, pasek bonding curve
	local middle = create("Frame", {
		Name = "Middle",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(ICON_SIZE + 14, 0),
		Size = UDim2.new(1, -(ICON_SIZE + 14 + RIGHT_WIDTH + 8), 1, 0),
		Parent = content,
	})
	local title = Util.label({
		Name = "Title",
		Text = `<b>{def.Ticker}</b>  <font color="#{MUTED}">{def.Name}</font>`,
		Size = 16,
		Font = Fonts.Medium,
		Position = UDim2.fromOffset(0, 14),
		FrameSize = UDim2.new(1, 0, 0, 20),
		Parent = middle,
	})
	title.RichText = true
	local sub = Util.label({
		Name = "Sub",
		Text = "",
		Size = 14,
		Font = Fonts.Medium,
		Position = UDim2.fromOffset(0, 40),
		FrameSize = UDim2.new(1, 0, 0, 18),
		Parent = middle,
	})
	sub.RichText = true
	local track: Frame = create("Frame", {
		Name = "Bonding",
		Position = UDim2.fromOffset(0, 72),
		Size = UDim2.new(1, -46, 0, 6),
		BackgroundColor3 = Colors.Elevated,
		BorderSizePixel = 0,
		Parent = middle,
	}, { Util.round() })
	local fill: Frame = create("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Colors.Green,
		BorderSizePixel = 0,
		Parent = track,
	}, { Util.round() })
	local percent = Util.label({
		Name = "Percent",
		Text = "",
		Size = 13,
		Font = Fonts.SemiBold,
		AlignX = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 66),
		FrameSize = UDim2.fromOffset(40, 18),
		Parent = middle,
	})
	local migrated: Frame = create("Frame", {
		Name = "Migrated",
		Position = UDim2.fromOffset(0, 64),
		Size = UDim2.fromOffset(0, 22),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Colors.Elevated,
		Visible = false,
		Parent = middle,
	}, { Util.round(), Util.padding(0, 10) })
	local migratedLabel = Util.label({
		Text = "",
		Size = 13,
		Font = Fonts.SemiBold,
		FrameSize = UDim2.fromScale(0, 1),
		Parent = migrated,
	})
	migratedLabel.AutomaticSize = Enum.AutomaticSize.X

	-- Prawa strona: wolumen, market cap, transakcje i szybki zakup
	local right = create("Frame", {
		Name = "Right",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, RIGHT_WIDTH, 1, 0),
		Parent = content,
	})
	local stats = Util.label({
		Name = "Stats",
		Text = "",
		Size = 15,
		Font = Fonts.Medium,
		AlignX = Enum.TextXAlignment.Right,
		Position = UDim2.fromOffset(0, 14),
		FrameSize = UDim2.new(1, 0, 0, 20),
		Parent = right,
	})
	stats.RichText = true
	local txns = Util.label({
		Name = "Txns",
		Text = "",
		Size = 13,
		Font = Fonts.Medium,
		AlignX = Enum.TextXAlignment.Right,
		Position = UDim2.fromOffset(0, 38),
		FrameSize = UDim2.new(1, 0, 0, 16),
		Parent = right,
	})
	txns.RichText = true
	local buy: TextButton = create("TextButton", {
		Name = "Buy",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, -12),
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Colors.Primary,
		Text = "",
		ZIndex = 2,
		Parent = right,
	}, { Util.round(), Util.padding(0, 12), Util.hlist(6) })
	Icons.currency(14, 1).Parent = buy
	local buyLabel =
		Util.text({ Text = "", Size = 14, Font = Fonts.Bold, Color = Colors.OnPrimary, Order = 2, Parent = buy })
	Util.hoverBackground(buy, Colors.Primary, Colors.PrimaryHover)

	local buying = false
	buy.Activated:Connect(function()
		if buying then
			return
		end
		local amount = Settings.State.QuickBuy
		if amount <= 0 then
			Toast.show("Set a Quick Buy amount first", "Error")
			return
		end
		buying = true
		buyLabel.Text = "..."
		Actions.buy(def.Ticker, amount)
		buying = false
		buyLabel.Text = Format.decimal(Settings.State.QuickBuy)
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

	local function update(coin: CoinSnapshot, launch: LaunchInfo)
		local now = Market.now()
		local holders = coin.Holders
		sub.Text = `<font color="#{GREEN}">{Format.age(now - coin.LaunchedAt)}</font>  <font color="#{MUTED}">by {launch.Creator}  ·  {holders} holder{if holders == 1
			then ""
			else "s"}</font>`

		local done = launch.Migrated
		track.Visible = not done
		percent.Visible = not done
		migrated.Visible = done
		if done then
			migratedLabel.Text = `Migrated {Format.age(now - (launch.MigratedAt or now))} ago`
		else
			local p = launch.Progress
			fill.Size = UDim2.fromScale(p / 100, 1)
			fill.BackgroundColor3 = if p >= Config.Launch.FinalStretch then Colors.Yellow else Colors.Green
			percent.Text = string.format("%d%%", math.floor(p))
		end

		local day = coin.Stats["24h"]
		local volume = if day then day.Volume else 0
		stats.Text = `<font color="#{MUTED}">V</font> {Format.usd(volume)}   <font color="#{MUTED}">MC</font> <b>{Format.usd(
			coin.MarketCap
		)}</b>`
		local buys, sells = if day then day.Buys else 0, if day then day.Sells else 0
		txns.Text = `<font color="#{MUTED}">TX</font> {Format.compact(buys + sells)}   <font color="#{GREEN}">{Format.compact(
			buys
		)}</font> / <font color="#{RED}">{Format.compact(sells)}</font>`
		if not buying then
			buyLabel.Text = Format.decimal(Settings.State.QuickBuy)
		end
	end

	return { Ticker = def.Ticker, Frame = row, Update = update }
end

type Column = {
	Key: ColumnKey,
	List: ScrollingFrame,
	Count: TextLabel,
	Search: TextBox,
	Empty: TextLabel,
}

local function column(parent: Instance, index: number, title: string, emptyText: string): Column
	local frame = card(title)
	local top = HEADER_HEIGHT + GAP
	frame.Position = UDim2.new((index - 1) / 3, (index - 1) * GAP / 3, 0, top)
	frame.Size = UDim2.new(1 / 3, -2 * GAP / 3, 1, -top)
	frame.Parent = parent

	local header = create("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, COLUMN_HEADER),
		Parent = frame,
	}, { Util.padding(0, 20) })
	local titleGroup = Util.group("Title", 0, Util.hlist(8, Enum.VerticalAlignment.Center))
	titleGroup.AnchorPoint = Vector2.new(0, 0.5)
	titleGroup.Position = UDim2.fromScale(0, 0.5)
	titleGroup.Parent = header
	Util.text({ Text = title, Size = 18, Font = Fonts.SemiBold, Order = 1, Parent = titleGroup })
	local count = Util.text({ Text = "0", Size = 15, Color = Colors.TextMuted, Order = 2, Parent = titleGroup })

	local searchBox = create("Frame", {
		Name = "Search",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(172, 34),
		BackgroundColor3 = Colors.Background,
		Parent = header,
	}, { Util.round(), Util.stroke(Colors.Border), Util.padding(0, 12) })
	local searchIcon = Icons.search(14, Colors.TextMuted)
	searchIcon.AnchorPoint = Vector2.new(0, 0.5)
	searchIcon.Position = UDim2.fromScale(0, 0.5)
	searchIcon.Parent = searchBox
	local search: TextBox = create("TextBox", {
		Name = "Input",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(22, 0),
		Size = UDim2.new(1, -22, 1, 0),
		ClearTextOnFocus = false,
		Text = "",
		PlaceholderText = "Search ticker or name",
		PlaceholderColor3 = Colors.TextMuted,
		TextColor3 = Colors.Text,
		TextSize = 14,
		FontFace = Fonts.Regular,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = searchBox,
	})

	local divider = Util.divider(false, Colors.Divider)
	divider.Position = UDim2.fromOffset(20, COLUMN_HEADER)
	divider.Size = UDim2.new(1, -40, 0, 1)
	divider.Parent = frame

	local list: ScrollingFrame = create("ScrollingFrame", {
		Name = "Rows",
		Position = UDim2.fromOffset(0, COLUMN_HEADER + 1),
		Size = UDim2.new(1, 0, 1, -(COLUMN_HEADER + 1)),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Colors.Border,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = frame,
	}, { Util.padding(4, 10, 10, 10), Util.vlist(0, nil, Enum.VerticalAlignment.Top) })
	local empty = Util.label({
		Name = "Empty",
		Text = emptyText,
		Size = 15,
		Color = Colors.TextMuted,
		AlignX = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, COLUMN_HEADER + 1),
		FrameSize = UDim2.new(1, 0, 0, 120),
		Parent = frame,
	})

	return { Key = "New", List = list, Count = count, Search = search, Empty = empty }
end

function PulsePage.new(openCoin: (string) -> ()): PulsePage
	local frame: Frame = create("Frame", {
		Name = "Pulse",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
	})

	-- Nagłówek strony
	local header = create("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
		Parent = frame,
	})
	local titles = Util.group("Titles", 0, Util.vlist(2))
	titles.AnchorPoint = Vector2.new(0, 0.5)
	titles.Position = UDim2.fromScale(0, 0.5)
	titles.Parent = header
	Util.text({ Text = "Pulse", Size = 26, Font = Fonts.Bold, Order = 1, Parent = titles })
	Util.text({
		Text = `Coins launched by players. Each one migrates at {Format.usd(Config.Launch.MigrationMarketCap)} market cap.`,
		Size = 14,
		Color = Colors.TextMuted,
		Order = 2,
		Parent = titles,
	})
	local controls = Util.group("Controls", 0, Util.hlist(10, nil, Enum.HorizontalAlignment.Right))
	controls.AnchorPoint = Vector2.new(1, 0.5)
	controls.Position = UDim2.fromScale(1, 0.5)
	controls.Parent = header
	QuickBuy.new(1).Parent = controls
	local createButton: TextButton = create("TextButton", {
		Name = "CreateCoin",
		AutoButtonColor = false,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 36),
		BackgroundColor3 = Colors.Primary,
		Text = "",
		LayoutOrder = 2,
		Parent = controls,
	}, { Util.round(), Util.padding(0, 16), Util.hlist(8) })
	Icons.plus(12, Colors.OnPrimary, 1).Parent = createButton
	Util.text({
		Text = "Create coin",
		Size = 15,
		Font = Fonts.SemiBold,
		Color = Colors.OnPrimary,
		Order = 2,
		Parent = createButton,
	})
	Util.hoverBackground(createButton, Colors.Primary, Colors.PrimaryHover)

	local columns: { [ColumnKey]: Column } = {}
	for i, spec in COLUMNS do
		local col = column(frame, i, spec.Title, spec.Empty)
		col.Key = spec.Key
		columns[spec.Key] = col
	end

	local dialog = CreateCoin.new(frame, openCoin)
	createButton.Activated:Connect(dialog.Open)

	------------------------------------------------------------------

	local rows: { [string]: Row } = {}

	type Item = { Row: Row, Coin: CoinSnapshot, Launch: LaunchInfo }

	local function matches(def: CoinDef, query: string): boolean
		return query == ""
			or string.find(string.lower(def.Ticker), query, 1, true) ~= nil
			or string.find(string.lower(def.Name), query, 1, true) ~= nil
	end

	local function refresh()
		local buckets: { [ColumnKey]: { Item } } = { New = {}, Stretch = {}, Migrated = {} }
		local seen: { [string]: boolean } = {}
		for ticker, coin in Market.Coins do
			local launch = coin.Launch
			local def = Coins.get(ticker)
			if not launch or not def then
				continue
			end
			local row = rows[ticker]
			if not row then
				row = pulseRow(def, openCoin)
				rows[ticker] = row
			end
			row.Update(coin, launch)
			seen[ticker] = true
			table.insert(buckets[columnOf(launch)], { Row = row, Coin = coin, Launch = launch })
		end
		for ticker, row in rows do
			if not seen[ticker] then
				row.Frame.Visible = false
			end
		end

		for index, spec in COLUMNS do
			local key = spec.Key
			local col = columns[key]
			local items = buckets[key]
			table.sort(items, function(a, b)
				if key == "Stretch" then
					return a.Launch.Progress > b.Launch.Progress
				elseif key == "Migrated" then
					return (a.Launch.MigratedAt or 0) > (b.Launch.MigratedAt or 0)
				end
				return a.Coin.LaunchedAt > b.Coin.LaunchedAt
			end)
			local query = string.lower(col.Search.Text)
			local shown = 0
			for i, item in items do
				local row = item.Row
				local def = Coins.get(row.Ticker) :: CoinDef
				row.Frame.Parent = col.List
				row.Frame.LayoutOrder = i
				row.Frame.Visible = matches(def, query)
				if row.Frame.Visible then
					shown += 1
				end
			end
			col.Count.Text = tostring(#items)
			col.Empty.Visible = shown == 0
			col.Empty.Text = if #items > 0 then "No coins match your search" else COLUMNS[index].Empty
		end
	end

	for _, col in columns do
		col.Search:GetPropertyChangedSignal("Text"):Connect(refresh)
	end
	Market.Changed:Connect(function()
		if frame.Visible then
			refresh()
		end
	end)
	Settings.Changed:Connect(function(key: string)
		if key == "QuickBuy" and frame.Visible then
			refresh()
		end
	end)

	return { Frame = frame, Refresh = refresh }
end

return PulsePage
