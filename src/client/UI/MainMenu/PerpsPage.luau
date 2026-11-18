--!strict
-- Zakładka Perpetuals: nagłówek rynku (cena, oracle, wolumen, open interest, funding), wykres,
-- księga zleceń i transakcje, panel Long/Short z dźwignią oraz tabela pozycji, zleceń i historii.
-- Księga i część transakcji są poglądowe (generowane wokół ceny mark); pozycje liczy serwer.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local PerpMath = require(ReplicatedStorage.Shared.PerpMath)
local Types = require(ReplicatedStorage.Shared.Types)

local State = script.Parent.Parent.Parent.State
local Actions = require(State.Actions)
local Perps = require(State.Perps)
local Portfolio = require(State.Portfolio)

local UI = script.Parent.Parent
local Chart = require(UI.Chart)
local Icons = require(UI.Icons)
local Theme = require(UI.Theme)
local Toast = require(UI.Toast)
local Util = require(UI.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

type PerpPosition = Types.PerpPosition
type PerpSide = Types.PerpSide

local PERPS = Config.Perps
local HEADER_HEIGHT = 64
local PANEL_WIDTH = 340
local BOOK_WIDTH = 300
local TABLE_HEIGHT = 210
local GAP = 12
local BOOK_ROWS = 14
local ROW_HEIGHT = 20
local TRADE_ROWS = 30
local INPUT_BG = Color3.fromHex("101010")
local TIMEFRAME_LABELS = { [60] = "1m", [300] = "5m", [900] = "15m", [3600] = "1h" }

export type PerpsPage = {
	Frame: Frame,
	Refresh: () -> (),
}

local PerpsPage = {}

local function card(name: string, parent: Instance): Frame
	return create("Frame", {
		Name = name,
		BackgroundColor3 = Colors.Surface,
		Parent = parent,
	}, { Util.corner(8), Util.stroke(Colors.Border) })
end

local function sideColor(side: PerpSide): Color3
	return if side == "Long" then Colors.Green else Colors.Red
end

local function pnlColor(n: number): Color3
	return if n > 0 then Colors.Green elseif n < 0 then Colors.Red else Colors.Text
end

local function signed(n: number): string
	return (if n > 0 then "+" else "") .. Format.decimal(n)
end

local function usd(n: number): string
	return "$" .. Format.int(n)
end

local function sizeText(size: number): string
	return Format.plain(size, 4)
end

local function clock(t: number): string
	return os.date("%H:%M:%S", math.floor(t))
end

local function countdown(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d:%02d", s // 3600, (s // 60) % 60, s % 60)
end

local function textButton(text: string, size: number, order: number, parent: Instance): TextButton
	return create("TextButton", {
		Name = text,
		AutoButtonColor = false,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 28),
		BackgroundTransparency = 1,
		Text = text,
		TextSize = size,
		FontFace = Fonts.SemiBold,
		TextColor3 = Colors.TextMuted,
		LayoutOrder = order,
		Parent = parent,
	})
end

-- Zakładki z podkreśleniem aktywnej.
type Tabs = { Set: (index: number) -> (), Buttons: { TextButton } }
local function tabs(parent: Instance, names: { string }, size: number, onChange: (index: number) -> ()): Tabs
	local buttons: { TextButton } = {}
	local lines: { Frame } = {}
	for i, name in names do
		local button = textButton(name, size, i, parent)
		buttons[i] = button
		lines[i] = create("Frame", {
			Name = "Underline",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 2),
			BackgroundColor3 = Colors.Text,
			BorderSizePixel = 0,
			Visible = false,
			Parent = button,
		})
	end
	local function set(index: number)
		for i, button in buttons do
			button.TextColor3 = if i == index then Colors.Text else Colors.TextMuted
			lines[i].Visible = i == index
		end
	end
	for i, button in buttons do
		button.Activated:Connect(function()
			set(i)
			onChange(i)
		end)
	end
	set(1)
	return { Set = set, Buttons = buttons }
end

local function inputBox(parent: Instance, order: number, height: number, placeholder: string, size: number): (Frame, TextBox)
	local box: Frame = create("Frame", {
		Name = "Box",
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = INPUT_BG,
		LayoutOrder = order,
		Parent = parent,
	}, { Util.corner(8), Util.stroke(Colors.Border), Util.padding(0, 12) })
	local input: TextBox = create("TextBox", {
		Name = "Input",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ClearTextOnFocus = false,
		Text = "",
		PlaceholderText = placeholder,
		PlaceholderColor3 = Colors.TextDim,
		TextColor3 = Colors.Text,
		TextSize = size,
		FontFace = Fonts.SemiBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = box,
	})
	return box, input
end

local function parseNumber(text: string): number?
	local n = tonumber((string.gsub(text, "[%s,$]", "")))
	if n and n == n and n ~= math.huge and n > 0 then
		return n
	end
	return nil
end

------------------------------------------------------------------
-- Tabela z wierszami tworzonymi na żądanie

type Column = { Title: string, Width: number }
type Cell = { Text: string, Color: Color3? }
type RowData = { Cells: { Cell }, Action: { Label: string, Run: () -> () }? }
type DataTable = { Frame: Frame, Set: (rows: { RowData }, empty: string) -> () }

local function dataTable(parent: Instance, columns: { Column }): DataTable
	local frame: Frame = create("Frame", {
		Name = "Table",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = parent,
	})
	local header = create("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 28),
		Parent = frame,
	}, { Util.padding(0, 16) })
	local x = 0
	for _, column in columns do
		Util.label({
			Text = column.Title,
			Size = 13,
			Color = Colors.TextMuted,
			Position = UDim2.fromScale(x, 0),
			FrameSize = UDim2.fromScale(column.Width, 1),
			Parent = header,
		})
		x += column.Width
	end
	create("Frame", {
		Name = "Line",
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = Colors.Divider,
		BorderSizePixel = 0,
		Parent = frame,
	})
	local body: ScrollingFrame = create("ScrollingFrame", {
		Name = "Rows",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 29),
		Size = UDim2.new(1, 0, 1, -29),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Colors.Border,
		Parent = frame,
	}, { Util.vlist(0, nil, Enum.VerticalAlignment.Top) })
	local empty = Util.label({
		Text = "",
		Size = 15,
		Color = Colors.TextMuted,
		AlignX = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 29),
		FrameSize = UDim2.new(1, 0, 1, -29),
		Parent = frame,
	})

	type Row = { Frame: Frame, Cells: { TextLabel }, Button: TextButton, Run: (() -> ())? }
	local rows: { Row } = {}
	local function row(i: number): Row
		local existing = rows[i]
		if existing then
			return existing
		end
		local r: Frame = create("Frame", {
			Name = "Row" .. i,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 34),
			LayoutOrder = i,
			Parent = body,
		}, { Util.padding(0, 16) })
		local cells: { TextLabel } = {}
		local cx = 0
		for c, column in columns do
			cells[c] = Util.label({
				Text = "",
				Size = 14,
				Position = UDim2.fromScale(cx, 0),
				FrameSize = UDim2.fromScale(column.Width, 1),
				Parent = r,
			})
			cx += column.Width
		end
		local button: TextButton = create("TextButton", {
			Name = "Action",
			AutoButtonColor = false,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.fromScale(1, 0.5),
			Size = UDim2.fromOffset(72, 24),
			BackgroundColor3 = Colors.Elevated,
			Text = "",
			TextSize = 13,
			FontFace = Fonts.SemiBold,
			TextColor3 = Colors.Text,
			Visible = false,
			Parent = r,
		}, { Util.corner(6), Util.stroke(Colors.Border) })
		Util.hoverBackground(button, Colors.Elevated, Colors.Border)
		local entry: Row = { Frame = r, Cells = cells, Button = button, Run = nil }
		button.Activated:Connect(function()
			if entry.Run then
				entry.Run()
			end
		end)
		rows[i] = entry
		return entry
	end

	return {
		Frame = frame,
		Set = function(data: { RowData }, emptyText: string)
			empty.Text = emptyText
			empty.Visible = #data == 0
			for i, d in data do
				local r = row(i)
				r.Frame.Visible = true
				for c, label in r.Cells do
					local cell = d.Cells[c]
					label.Text = if cell then cell.Text else ""
					label.TextColor3 = if cell and cell.Color then cell.Color else Colors.Text
				end
				local action = d.Action
				r.Button.Visible = action ~= nil
				r.Button.Text = if action then action.Label else ""
				r.Run = if action then action.Run else nil
			end
			for i = #data + 1, #rows do
				rows[i].Frame.Visible = false
				rows[i].Run = nil
			end
		end,
	}
end

------------------------------------------------------------------

function PerpsPage.new(): PerpsPage
	local symbol = PERPS.Markets[1].Symbol
	local timeframe = PERPS.Timeframes[1]
	local side: PerpSide = "Long"
	local orderType: "Market" | "Limit" = "Market"
	local leverage = 10
	local percent = 0
	local tpslOn = false

	local frame: Frame = create("Frame", {
		Name = "PerpsPage",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
	})
	local left = create("Frame", {
		Name = "Left",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -(PANEL_WIDTH + GAP), 1, 0),
		Parent = frame,
	})

	--------------------------------------------------------------
	-- Nagłówek

	local header = card("Header", left)
	header.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
	Util.padding(0, 16).Parent = header
	Util.hlist(28).Parent = header

	local selector: TextButton = create("TextButton", {
		Name = "Market",
		AutoButtonColor = false,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 40),
		BackgroundColor3 = Colors.Elevated,
		BackgroundTransparency = 1,
		Text = "",
		LayoutOrder = 1,
		Parent = header,
	}, { Util.corner(8), Util.padding(0, 8), Util.hlist(8) })
	Util.hoverBackground(selector, Colors.Elevated, Colors.Elevated, 1)
	local iconSlot = create("Frame", { Name = "Icon", BackgroundTransparency = 1, Size = UDim2.fromOffset(28, 28), LayoutOrder = 1, Parent = selector })
	local symbolLabel = Util.text({ Text = symbol, Size = 22, Font = Fonts.Bold, Order = 2, Parent = selector })
	Icons.chevronDown(12, Colors.TextMuted, 3).Parent = selector

	local priceGroup = Util.group("Price", 2, Util.hlist(8, Enum.VerticalAlignment.Bottom))
	priceGroup.Parent = header
	local markLabel = Util.text({ Text = "-", Size = 24, Font = Fonts.Bold, Order = 1, Parent = priceGroup })
	local changeLabel = Util.text({ Text = "", Size = 15, Font = Fonts.SemiBold, Order = 2, Parent = priceGroup })

	local function stat(title: string, order: number): (TextLabel, TextLabel)
		local group = Util.group(title, order, Util.vlist(2))
		group.Parent = header
		Util.text({ Text = title, Size = 13, Color = Colors.TextMuted, Order = 1, Parent = group })
		local row = Util.group("Value", 2, Util.hlist(8))
		row.Parent = group
		local value = Util.text({ Text = "-", Size = 16, Font = Fonts.SemiBold, Order = 1, Parent = row })
		local extra = Util.text({ Text = "", Size = 16, Font = Fonts.SemiBold, Order = 2, Parent = row })
		return value, extra
	end
	local oracleValue = stat("Oracle Price", 3)
	local volumeValue = stat("24h Volume", 4)
	local oiValue = stat("Open Interest", 5)
	local fundingValue, countdownValue = stat("Funding / Countdown", 6)

	-- Lista rynków pod przyciskiem (nad resztą strony).
	local dropdown: Frame = create("Frame", {
		Name = "Markets",
		Position = UDim2.fromOffset(8, HEADER_HEIGHT - 4),
		Size = UDim2.fromOffset(320, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Colors.Elevated,
		Visible = false,
		ZIndex = 20,
		Parent = frame,
	}, { Util.corner(8), Util.stroke(Colors.Border), Util.padding(6), Util.vlist(2) })
	type MarketRow = { Price: TextLabel, Change: TextLabel }
	local marketRows: { [string]: MarketRow } = {}

	--------------------------------------------------------------
	-- Wykres

	local middleTop = HEADER_HEIGHT + GAP
	local middleHeight = -(HEADER_HEIGHT + TABLE_HEIGHT + 2 * GAP)
	local chartArea = create("Frame", {
		Name = "ChartArea",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, middleTop),
		Size = UDim2.new(1, -(BOOK_WIDTH + GAP), 1, middleHeight),
		Parent = left,
	})
	local tfRow = Util.group("Timeframes", 0, Util.hlist(4))
	tfRow.Size = UDim2.fromOffset(0, 28)
	tfRow.Parent = chartArea
	local tfButtons: { [number]: TextButton } = {}
	for i, seconds in PERPS.Timeframes do
		local button: TextButton = create("TextButton", {
			Name = TIMEFRAME_LABELS[seconds] or tostring(seconds),
			AutoButtonColor = false,
			Size = UDim2.fromOffset(44, 26),
			BackgroundColor3 = Colors.Elevated,
			BackgroundTransparency = 1,
			Text = TIMEFRAME_LABELS[seconds] or tostring(seconds),
			TextSize = 14,
			FontFace = Fonts.SemiBold,
			TextColor3 = Colors.TextMuted,
			LayoutOrder = i,
			Parent = tfRow,
		}, { Util.corner(6) })
		tfButtons[seconds] = button
	end
	local chart = Chart.new(PERPS.CandleCount, Format.price)
	chart.Frame.Position = UDim2.fromOffset(0, 34)
	chart.Frame.Size = UDim2.new(1, 0, 1, -34)
	chart.Frame.Parent = chartArea

	--------------------------------------------------------------
	-- Księga zleceń / transakcje

	local book = card("Book", left)
	book.AnchorPoint = Vector2.new(1, 0)
	book.Position = UDim2.new(1, 0, 0, middleTop)
	book.Size = UDim2.new(0, BOOK_WIDTH, 1, middleHeight)
	book.ClipsDescendants = true
	local bookTabsRow = Util.group("Tabs", 0, Util.hlist(20))
	bookTabsRow.Position = UDim2.fromOffset(14, 4)
	bookTabsRow.Size = UDim2.fromOffset(0, 32)
	bookTabsRow.Parent = book

	local function columnsRow(parent: Instance, titles: { string }, y: number)
		local row = create("Frame", {
			Name = "Columns",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, y),
			Size = UDim2.new(1, 0, 0, 22),
			Parent = parent,
		}, { Util.padding(0, 14) })
		for i, title in titles do
			Util.label({
				Text = title,
				Size = 12,
				Color = Colors.TextMuted,
				AlignX = if i == 1 then Enum.TextXAlignment.Left else Enum.TextXAlignment.Right,
				Position = UDim2.fromScale((i - 1) / #titles, 0),
				FrameSize = UDim2.fromScale(1 / #titles, 1),
				Parent = row,
			})
		end
	end

	local bookView = create("Frame", { Name = "BookView", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = book })
	columnsRow(bookView, { "Price", "Amount (USD)", "Total (USD)" }, 40)
	local SPREAD = 24
	local function half(name: string, top: boolean): Frame
		return create("Frame", {
			Name = name,
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Position = if top then UDim2.fromOffset(0, 62) else UDim2.new(0, 0, 0.5, 31 + SPREAD / 2),
			Size = UDim2.new(1, 0, 0.5, -(31 + SPREAD / 2)),
			Parent = bookView,
		}, { Util.vlist(0, nil, if top then Enum.VerticalAlignment.Bottom else Enum.VerticalAlignment.Top) })
	end
	local asksFrame = half("Asks", true)
	local bidsFrame = half("Bids", false)
	local spreadRow = create("Frame", {
		Name = "Spread",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 31),
		Size = UDim2.new(1, 0, 0, SPREAD),
		BackgroundColor3 = Colors.Elevated,
		BorderSizePixel = 0,
		Parent = bookView,
	})
	local spreadLabel = Util.label({
		Text = "",
		Size = 13,
		Font = Fonts.SemiBold,
		AlignX = Enum.TextXAlignment.Center,
		Parent = spreadRow,
	})

	type BookRow = { Bar: Frame, Price: TextLabel, Amount: TextLabel, Total: TextLabel }
	local function bookRows(parent: Frame, color: Color3, ask: boolean): { BookRow }
		local list: { BookRow } = {}
		for i = 1, BOOK_ROWS do
			local row = create("Frame", {
				Name = "Level" .. i,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
				-- Asks: najlepsza cena na dole, przy spreadzie.
				LayoutOrder = if ask then BOOK_ROWS - i else i,
				Parent = parent,
			})
			local bar = create("Frame", {
				Name = "Bar",
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.fromScale(1, 0),
				Size = UDim2.fromScale(0, 1),
				BackgroundColor3 = color,
				BackgroundTransparency = 0.85,
				BorderSizePixel = 0,
				Parent = row,
			})
			local cells = create("Frame", { Name = "Cells", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = row }, { Util.padding(0, 14) })
			local function cell(x: number, align: Enum.TextXAlignment, c: Color3): TextLabel
				return Util.label({
					Text = "",
					Size = 13,
					Font = Fonts.Mono,
					Color = c,
					AlignX = align,
					Position = UDim2.fromScale(x, 0),
					FrameSize = UDim2.fromScale(1 / 3, 1),
					Parent = cells,
				})
			end
			list[i] = {
				Bar = bar,
				Price = cell(0, Enum.TextXAlignment.Left, color),
				Amount = cell(1 / 3, Enum.TextXAlignment.Right, Colors.Text),
				Total = cell(2 / 3, Enum.TextXAlignment.Right, Colors.Text),
			}
		end
		return list
	end
	local askRows = bookRows(asksFrame, Colors.Red, true)
	local bidRows = bookRows(bidsFrame, Colors.Green, false)

	local tradesView = create("Frame", { Name = "TradesView", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Parent = book })
	columnsRow(tradesView, { "Price", "Size (USD)", "Time" }, 40)
	local tradesList = create("Frame", {
		Name = "List",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Position = UDim2.fromOffset(0, 62),
		Size = UDim2.new(1, 0, 1, -62),
		Parent = tradesView,
	}, { Util.vlist(0, nil, Enum.VerticalAlignment.Top) })
	type TradeRow = { Frame: Frame, Price: TextLabel, Size: TextLabel, Time: TextLabel }
	local tradeRows: { TradeRow } = {}
	for i = 1, TRADE_ROWS do
		local row = create("Frame", {
			Name = "Trade" .. i,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			LayoutOrder = i,
			Visible = false,
			Parent = tradesList,
		}, { Util.padding(0, 14) })
		local function cell(x: number, align: Enum.TextXAlignment): TextLabel
			return Util.label({
				Text = "",
				Size = 13,
				Font = Fonts.Mono,
				AlignX = align,
				Position = UDim2.fromScale(x, 0),
				FrameSize = UDim2.fromScale(1 / 3, 1),
				Parent = row,
			})
		end
		tradeRows[i] = {
			Frame = row,
			Price = cell(0, Enum.TextXAlignment.Left),
			Size = cell(1 / 3, Enum.TextXAlignment.Right),
			Time = cell(2 / 3, Enum.TextXAlignment.Right),
		}
	end
	tabs(bookTabsRow, { "Order Book", "Trades" }, 15, function(index: number)
		bookView.Visible = index == 1
		tradesView.Visible = index == 2
	end)

	--------------------------------------------------------------
	-- Tabela: pozycje, zlecenia, historia

	local tableCard = card("Positions", left)
	tableCard.AnchorPoint = Vector2.new(0, 1)
	tableCard.Position = UDim2.fromScale(0, 1)
	tableCard.Size = UDim2.new(1, 0, 0, TABLE_HEIGHT)
	tableCard.ClipsDescendants = true
	local tableTabsRow = Util.group("Tabs", 0, Util.hlist(22))
	tableTabsRow.Position = UDim2.fromOffset(16, 4)
	tableTabsRow.Size = UDim2.fromOffset(0, 32)
	tableTabsRow.Parent = tableCard
	local tableBody = create("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 38),
		Size = UDim2.new(1, 0, 1, -38),
		Parent = tableCard,
	})
	local positionsTable = dataTable(tableBody, {
		{ Title = "Asset", Width = 0.1 },
		{ Title = "Position", Width = 0.12 },
		{ Title = "Position Value", Width = 0.11 },
		{ Title = "Entry Price", Width = 0.1 },
		{ Title = "Mark Price", Width = 0.1 },
		{ Title = "Liq. Price", Width = 0.1 },
		{ Title = "Margin Used (PnL)", Width = 0.2 },
		{ Title = "TP / SL", Width = 0.12 },
	})
	local ordersTable = dataTable(tableBody, {
		{ Title = "Time", Width = 0.1 },
		{ Title = "Asset", Width = 0.1 },
		{ Title = "Side", Width = 0.08 },
		{ Title = "Limit Price", Width = 0.12 },
		{ Title = "Margin", Width = 0.12 },
		{ Title = "Leverage", Width = 0.09 },
		{ Title = "Size", Width = 0.14 },
		{ Title = "TP / SL", Width = 0.16 },
	})
	local historyTable = dataTable(tableBody, {
		{ Title = "Time", Width = 0.1 },
		{ Title = "Asset", Width = 0.08 },
		{ Title = "Action", Width = 0.14 },
		{ Title = "Price", Width = 0.12 },
		{ Title = "Size", Width = 0.16 },
		{ Title = "Fee", Width = 0.12 },
		{ Title = "PnL", Width = 0.18 },
	})
	local tableIndex = 1
	local tableTabs = tabs(tableTabsRow, { "Positions", "Open Orders", "Trades" }, 15, function(index: number)
		tableIndex = index
		positionsTable.Frame.Visible = index == 1
		ordersTable.Frame.Visible = index == 2
		historyTable.Frame.Visible = index == 3
	end)
	ordersTable.Frame.Visible = false
	historyTable.Frame.Visible = false

	--------------------------------------------------------------
	-- Panel Long / Short

	local panel: ScrollingFrame = create("ScrollingFrame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, PANEL_WIDTH, 1, 0),
		BackgroundColor3 = Colors.Surface,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = Colors.Border,
		Parent = frame,
	}, {
		Util.corner(8),
		Util.stroke(Colors.Border),
		Util.padding(16),
		Util.vlist(12, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top),
	})

	-- Long / Short
	local sideToggle = create("Frame", {
		Name = "Side",
		Size = UDim2.new(1, 0, 0, 40),
		BackgroundColor3 = Colors.Elevated,
		LayoutOrder = 1,
		Parent = panel,
	}, { Util.corner(8), Util.padding(3) })
	local function sideButton(name: PerpSide, x: number): TextButton
		return create("TextButton", {
			Name = name,
			AutoButtonColor = false,
			Position = UDim2.fromScale(x, 0),
			Size = UDim2.fromScale(0.5, 1),
			BackgroundColor3 = sideColor(name),
			BackgroundTransparency = 1,
			Text = name,
			TextSize = 16,
			FontFace = Fonts.Bold,
			TextColor3 = Colors.TextMuted,
			Parent = sideToggle,
		}, { Util.corner(6) })
	end
	local longButton = sideButton("Long", 0)
	local shortButton = sideButton("Short", 0.5)

	-- Market / Limit + dźwignia
	local typeRow = create("Frame", { Name = "Type", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 2, Parent = panel })
	local typeTabsRow = Util.group("Tabs", 0, Util.hlist(18))
	typeTabsRow.Size = UDim2.fromOffset(0, 30)
	typeTabsRow.Parent = typeRow
	local leverageButton: TextButton = create("TextButton", {
		Name = "Leverage",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 26),
		BackgroundColor3 = Colors.Elevated,
		Text = "",
		TextSize = 14,
		FontFace = Fonts.SemiBold,
		TextColor3 = Colors.Text,
		Parent = typeRow,
	}, { Util.corner(6), Util.stroke(Colors.Border), Util.padding(0, 10) })
	Util.hoverBackground(leverageButton, Colors.Elevated, Colors.Border)

	local leverageRow = create("Frame", {
		Name = "LeveragePresets",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 30),
		LayoutOrder = 3,
		Visible = false,
		Parent = panel,
	}, { Util.hlist(6) })
	local leverageChips: { [number]: TextButton } = {}

	local priceBox, priceInput = inputBox(panel, 4, 44, "Limit price (USD)", 16)
	priceBox.Visible = false
	local markButton: TextButton = create("TextButton", {
		Name = "Mark",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(48, 24),
		BackgroundColor3 = Colors.Elevated,
		Text = "Mark",
		TextSize = 13,
		FontFace = Fonts.SemiBold,
		TextColor3 = Colors.Text,
		Parent = priceBox,
	}, { Util.corner(6) })
	priceInput.Size = UDim2.new(1, -56, 1, 0)

	-- Margin
	local amountBox: Frame = create("Frame", {
		Name = "Amount",
		Size = UDim2.new(1, 0, 0, 70),
		BackgroundColor3 = INPUT_BG,
		LayoutOrder = 5,
		Parent = panel,
	}, { Util.corner(8), Util.stroke(Colors.Border), Util.padding(8, 12) })
	Util.label({ Text = "Margin", Size = 13, Color = Colors.TextMuted, FrameSize = UDim2.new(0.5, 0, 0, 18), Parent = amountBox })
	local sizeLabel = Util.label({
		Text = "",
		Size = 13,
		Color = Colors.TextMuted,
		AlignX = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.4, 0),
		FrameSize = UDim2.new(0.6, 0, 0, 18),
		Parent = amountBox,
	})
	local amountInput: TextBox = create("TextBox", {
		Name = "Input",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.new(1, -50, 0, 30),
		ClearTextOnFocus = false,
		Text = "",
		PlaceholderText = "0.0",
		PlaceholderColor3 = Colors.TextDim,
		TextColor3 = Colors.Text,
		TextSize = 22,
		FontFace = Fonts.Bold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = amountBox,
	})
	local currencyTag = Util.group("Currency", 0, Util.hlist(6, nil, Enum.HorizontalAlignment.Right))
	currencyTag.AnchorPoint = Vector2.new(1, 0)
	currencyTag.Position = UDim2.new(1, 0, 0, 26)
	currencyTag.Parent = amountBox
	Icons.currency(18, 1).Parent = currencyTag
	Util.text({ Text = Config.Currency, Size = 15, Font = Fonts.SemiBold, Order = 2, Parent = currencyTag })

	-- Suwak 0-100% dostępnego salda
	local slider = create("Frame", { Name = "Slider", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 38), LayoutOrder = 6, Parent = panel })
	local track: TextButton = create("TextButton", {
		Name = "Track",
		AutoButtonColor = false,
		Text = "",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(7, 0),
		Size = UDim2.new(1, -14, 0, 18),
		Parent = slider,
	})
	create("Frame", {
		Name = "Rail",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(1, 0, 0, 4),
		BackgroundColor3 = Colors.Border,
		BorderSizePixel = 0,
		Parent = track,
	}, { Util.round() })
	local fill = create("Frame", {
		Name = "Fill",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(0, 0, 0, 4),
		BackgroundColor3 = Colors.Green,
		BorderSizePixel = 0,
		Parent = track,
	}, { Util.round() })
	local knob = create("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(14, 14),
		BackgroundColor3 = Colors.Green,
		ZIndex = 2,
		Parent = track,
	}, { Util.round(), Util.stroke(Colors.Surface, 2) })
	local percentMarks: { [number]: TextButton } = {}
	for i, p in { 0, 25, 50, 75, 100 } do
		percentMarks[p] = create("TextButton", {
			Name = "P" .. p,
			AutoButtonColor = false,
			AnchorPoint = Vector2.new(p / 100, 0),
			Position = UDim2.new(p / 100, 0, 0, 20),
			Size = UDim2.fromOffset(40, 16),
			BackgroundTransparency = 1,
			Text = p .. "%",
			TextSize = 12,
			FontFace = Fonts.Medium,
			TextColor3 = Colors.TextMuted,
			TextXAlignment = if i == 1 then Enum.TextXAlignment.Left elseif i == 5 then Enum.TextXAlignment.Right else Enum.TextXAlignment.Center,
			Parent = track,
		})
	end

	-- TP/SL
	local tpslRow = create("Frame", { Name = "TpSl", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = 7, Parent = panel })
	local tpslToggle: TextButton = create("TextButton", {
		Name = "Toggle",
		AutoButtonColor = false,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 24),
		BackgroundTransparency = 1,
		Text = "",
		Parent = tpslRow,
	}, { Util.hlist(8) })
	local checkbox = create("Frame", {
		Name = "Checkbox",
		Size = UDim2.fromOffset(18, 18),
		BackgroundColor3 = Colors.Primary,
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = tpslToggle,
	}, { Util.corner(4), Util.stroke(Colors.Border, 1.5) })
	local checkmark = Icons.check(13, Colors.OnPrimary)
	checkmark.AnchorPoint = Vector2.new(0.5, 0.5)
	checkmark.Position = UDim2.fromScale(0.5, 0.5)
	checkmark.Visible = false
	checkmark.Parent = checkbox
	Util.text({ Text = "TP/SL", Size = 14, Order = 2, Parent = tpslToggle })
	local liqLabel = Util.label({
		Text = "Est. Liq. Price: --",
		Size = 13,
		Color = Colors.TextMuted,
		AlignX = Enum.TextXAlignment.Right,
		Position = UDim2.fromScale(0.35, 0),
		FrameSize = UDim2.fromScale(0.65, 1),
		Parent = tpslRow,
	})
	local tpslInputs = create("Frame", { Name = "Prices", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), LayoutOrder = 8, Visible = false, Parent = panel })
	local tpBox, tpInput = inputBox(tpslInputs, 1, 40, "TP price", 14)
	tpBox.Size = UDim2.new(0.5, -4, 1, 0)
	local slBox, slInput = inputBox(tpslInputs, 2, 40, "SL price", 14)
	slBox.Size = UDim2.new(0.5, -4, 1, 0)
	slBox.Position = UDim2.new(0.5, 4, 0, 0)

	local function infoRow(order: number, title: string): TextLabel
		local row = create("Frame", { Name = title, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = order, Parent = panel })
		Util.label({ Text = title, Size = 13, Color = Colors.TextMuted, FrameSize = UDim2.fromScale(0.5, 1), Parent = row })
		return Util.label({
			Text = "-",
			Size = 13,
			AlignX = Enum.TextXAlignment.Right,
			Position = UDim2.fromScale(0.4, 0),
			FrameSize = UDim2.fromScale(0.6, 1),
			Parent = row,
		})
	end
	local positionSizeLabel = infoRow(9, "Position Size")
	local feeLabel = infoRow(10, "Fee")

	local submit: TextButton = create("TextButton", {
		Name = "Submit",
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, 46),
		BackgroundColor3 = Colors.Green,
		Text = "",
		TextSize = 17,
		FontFace = Fonts.Bold,
		TextColor3 = Colors.OnPrimary,
		LayoutOrder = 11,
		Parent = panel,
	}, { Util.round() })
	local divider = Util.divider()
	divider.LayoutOrder = 12
	divider.Parent = panel
	local availableLabel = infoRow(13, "Available Margin")
	local accountLabel = infoRow(14, "Account Value")
	local currentLabel = infoRow(15, "Current Position")

	--------------------------------------------------------------
	-- Logika

	local busy = false
	local syntheticTrades: { { T: number, Price: number, Size: number, Side: PerpSide, Trader: string? } } = {}
	local seenPrints: { [string]: boolean } = {}
	local lastMark: number? = nil

	local function def(): Config.PerpMarketDef
		return PerpMath.market(symbol) :: Config.PerpMarketDef
	end

	local function account(): Types.PerpAccount
		return Portfolio.State.Perps or { Positions = {}, Orders = {}, History = {}, CheckedAt = 0 }
	end

	local function feeRate(): number
		return if orderType == "Limit" then PERPS.MakerFee else PERPS.TakerFee
	end

	local function maxMargin(): number
		return math.max(0, Portfolio.State.Balance / (1 + leverage * feeRate()))
	end

	local function margin(): number?
		return parseNumber(amountInput.Text)
	end

	local function entryPrice(): number?
		if orderType == "Limit" then
			return parseNumber(priceInput.Text)
		end
		return Perps.mark(symbol)
	end

	local function setPercent(p: number, updateText: boolean)
		percent = math.clamp(p, 0, 1)
		fill.Size = UDim2.new(percent, 0, 0, 4)
		knob.Position = UDim2.fromScale(percent, 0.5)
		if updateText then
			local m = math.floor(maxMargin() * percent * 1e4) / 1e4
			amountInput.Text = if m > 0 then Format.plain(m, 6) else ""
		end
	end

	local function equity(): number
		local total = 0
		local acc = account()
		for s, pos in acc.Positions do
			local mark = Perps.mark(s) or pos.Entry
			total += math.max(0, pos.Margin + PerpMath.pnl(pos, mark))
		end
		for _, o in acc.Orders do
			total += o.Reserved
		end
		return total
	end

	local function refreshPanel()
		local color = sideColor(side)
		longButton.BackgroundTransparency = if side == "Long" then 0 else 1
		longButton.TextColor3 = if side == "Long" then Colors.OnPrimary else Colors.TextMuted
		shortButton.BackgroundTransparency = if side == "Short" then 0 else 1
		shortButton.TextColor3 = if side == "Short" then Colors.OnPrimary else Colors.TextMuted
		fill.BackgroundColor3 = color
		knob.BackgroundColor3 = color
		leverageButton.Text = `Leverage: {leverage}x`
		priceBox.Visible = orderType == "Limit"
		tpslInputs.Visible = tpslOn
		checkbox.BackgroundTransparency = if tpslOn then 0 else 1
		checkmark.Visible = tpslOn
		for lev, chip in leverageChips do
			chip.BackgroundColor3 = if lev == leverage then Colors.Primary else Colors.Elevated
			chip.TextColor3 = if lev == leverage then Colors.OnPrimary else Colors.Text
		end

		local m = margin()
		local price = entryPrice()
		local balance = Portfolio.State.Balance
		if m and price then
			local size = PerpMath.sizeFor(m, leverage, price)
			sizeLabel.Text = `≈ {sizeText(size)} {symbol}`
			positionSizeLabel.Text = `{usd(size * price)}  ({sizeText(size)} {symbol})`
			feeLabel.Text = Format.rx(m * leverage * feeRate())
			local liq = PerpMath.liqPriceFor(side, size, price, m, PerpMath.mmr(symbol))
			local pos = account().Positions[symbol]
			if pos and pos.Side == side then
				-- Dokładanie do pozycji: cena likwidacji połączonej pozycji.
				local total = pos.Size + size
				local entry = (pos.Size * pos.Entry + size * price) / total
				liq = PerpMath.liqPriceFor(side, total, entry, pos.Margin + m, PerpMath.mmr(symbol))
			end
			liqLabel.Text = "Est. Liq. Price: " .. (if liq > 0 then Format.price(liq) else "--")
		else
			sizeLabel.Text = ""
			positionSizeLabel.Text = "-"
			feeLabel.Text = "-"
			liqLabel.Text = "Est. Liq. Price: --"
		end
		local max = maxMargin()
		if m and not busy then
			-- Pozycja suwaka za wpisaną kwotą (bez zmiany tekstu).
			setPercent(if max > 0 then m / max else 0, false)
		end

		if balance < Config.MinTradeRx then
			submit.Text = "Add More Funds"
			submit.BackgroundColor3 = Colors.Primary
		else
			submit.Text = if busy then "Placing..." else `{side} {symbol}`
			submit.BackgroundColor3 = color
		end
		submit.BackgroundTransparency = if busy then 0.4 else 0

		availableLabel.Text = Format.rx(balance)
		accountLabel.Text = Format.rx(balance + equity())
		local pos = account().Positions[symbol]
		if pos then
			currentLabel.Text = `{sizeText(pos.Size)} {symbol} {pos.Side}`
			currentLabel.TextColor3 = sideColor(pos.Side)
		else
			currentLabel.Text = "--"
			currentLabel.TextColor3 = Colors.Text
		end
	end

	local function tpslText(tp: number?, sl: number?): string
		return (if tp then Format.price(tp) else "--") .. " / " .. (if sl then Format.price(sl) else "--")
	end

	local function actionText(trade: Types.PerpTrade): string
		if trade.Action == "Open" then
			return "Open " .. trade.Side
		elseif trade.Action == "Close" then
			return "Close " .. trade.Side
		elseif trade.Action == "Liquidation" then
			return "Liquidated"
		elseif trade.Action == "TP" then
			return "Take profit"
		end
		return "Stop loss"
	end

	local function refreshTables()
		local acc = account()
		local positions: { RowData } = {}
		local list: { PerpPosition } = {}
		for _, pos in acc.Positions do
			table.insert(list, pos)
		end
		table.sort(list, function(a, b)
			return a.OpenedAt > b.OpenedAt
		end)
		for _, pos in list do
			local mark = Perps.mark(pos.Symbol) or pos.Entry
			local pnl = PerpMath.pnl(pos, mark)
			local roe = if pos.Margin > 0 then pnl / pos.Margin * 100 else 0
			local s = pos.Symbol
			table.insert(positions, {
				Cells = {
					{ Text = `{s} {math.round(PerpMath.leverage(pos))}x`, Color = sideColor(pos.Side) },
					{ Text = `{sizeText(pos.Size)} {s}`, Color = sideColor(pos.Side) },
					{ Text = usd(pos.Size * mark) },
					{ Text = Format.price(pos.Entry) },
					{ Text = Format.price(mark) },
					{ Text = Format.price(PerpMath.liqPrice(pos)) },
					{ Text = `{Format.rx(pos.Margin)} ({signed(pnl)} · {Format.percent(roe)})`, Color = pnlColor(pnl) },
					{ Text = tpslText(pos.TP, pos.SL) },
				},
				Action = {
					Label = "Close",
					Run = function()
						Perps.close(s)
					end,
				},
			})
		end
		positionsTable.Set(positions, "No open positions")

		local orders: { RowData } = {}
		for i = #acc.Orders, 1, -1 do
			local o = acc.Orders[i]
			local id = o.Id
			table.insert(orders, {
				Cells = {
					{ Text = clock(o.CreatedAt) },
					{ Text = o.Symbol },
					{ Text = o.Side, Color = sideColor(o.Side) },
					{ Text = Format.price(o.Price) },
					{ Text = Format.rx(o.Margin) },
					{ Text = `{o.Leverage}x` },
					{ Text = `{sizeText(PerpMath.sizeFor(o.Margin, o.Leverage, o.Price))} {o.Symbol}` },
					{ Text = tpslText(o.TP, o.SL) },
				},
				Action = {
					Label = "Cancel",
					Run = function()
						Perps.cancel(id)
					end,
				},
			})
		end
		ordersTable.Set(orders, "No open orders")

		local history: { RowData } = {}
		for i = #acc.History, 1, -1 do
			local h = acc.History[i]
			local pnl = h.Pnl
			table.insert(history, {
				Cells = {
					{ Text = clock(h.T) },
					{ Text = h.Symbol },
					{ Text = actionText(h), Color = if h.Action == "Liquidation" then Colors.Red else sideColor(h.Side) },
					{ Text = Format.price(h.Price) },
					{ Text = `{sizeText(h.Size)} {h.Symbol}` },
					{ Text = Format.rx(h.Fee) },
					{ Text = if pnl then signed(pnl) .. " " .. Config.Currency else "--", Color = if pnl then pnlColor(pnl) else nil },
				},
			})
		end
		historyTable.Set(history, "No trades yet")

		local count = 0
		for _ in acc.Positions do
			count += 1
		end
		tableTabs.Buttons[1].Text = if count > 0 then `Positions ({count})` else "Positions"
		tableTabs.Buttons[2].Text = if #acc.Orders > 0 then `Open Orders ({#acc.Orders})` else "Open Orders"
		tableTabs.Set(tableIndex)
	end

	-- Księga poglądowa: poziomy co Tick wokół ceny mark, wielkości z ziarna (poziom, chwila).
	local function refreshBook(market: Types.PerpMarket)
		local tick = def().Tick
		local decimals = math.max(0, -math.floor(math.log10(tick) + 1e-9))
		local bestBid = math.floor(market.Mark / tick) * tick
		local bestAsk = bestBid + tick
		local slot = math.floor(os.clock() / 2)
		local base = market.Volume / 50_000
		local function amount(level: number): number
			local rng = Random.new(level * 7919 + slot * 104_729 + #symbol)
			return base * math.exp(rng:NextNumber(-3, 1.6))
		end
		local function fillSide(rows: { BookRow }, start: number, step: number)
			local amounts = {}
			local cumulative = 0
			for i = 1, BOOK_ROWS do
				local level = math.round((start + step * (i - 1)) / tick)
				amounts[i] = amount(level)
				cumulative += amounts[i]
			end
			local running = 0
			for i, row in rows do
				running += amounts[i]
				row.Price.Text = string.format(`%.{decimals}f`, start + step * (i - 1))
				row.Amount.Text = Format.int(amounts[i])
				row.Total.Text = Format.int(running)
				row.Bar.Size = UDim2.fromScale(running / cumulative, 1)
			end
		end
		fillSide(askRows, bestAsk, tick)
		fillSide(bidRows, bestBid, -tick)
		spreadLabel.Text = string.format(`Spread  %.{decimals}f   %.3f%%`, tick, tick / market.Mark * 100)
	end

	local function refreshTrades(snapshot: Types.PerpsSnapshot, market: Types.PerpMarket)
		-- Transakcje graczy z serwera plus poglądowy ruch rynku przy każdej zmianie ceny.
		for _, p in snapshot.Prints do
			local k = `{p.T}:{p.Trader}:{p.Symbol}:{p.Size}`
			if not seenPrints[k] then
				seenPrints[k] = true
				table.insert(syntheticTrades, { T = p.T, Price = p.Price, Size = p.Size * p.Price, Side = p.Side, Trader = p.Trader, Symbol = p.Symbol } :: any)
			end
		end
		if lastMark and lastMark ~= market.Mark then
			local rng = Random.new(math.floor(snapshot.T * 10))
			for _ = 1, rng:NextInteger(1, 3) do
				table.insert(syntheticTrades, {
					T = snapshot.T,
					Price = market.Mark * (1 + rng:NextNumber(-0.0001, 0.0001)),
					Size = market.Volume / 400_000 * math.exp(rng:NextNumber(-2.5, 2)),
					Side = if market.Mark > lastMark then "Long" else "Short",
					Symbol = symbol,
				} :: any)
			end
		end
		lastMark = market.Mark
		while #syntheticTrades > 200 do
			table.remove(syntheticTrades, 1)
		end
		local shown = 0
		for i = #syntheticTrades, 1, -1 do
			local t = syntheticTrades[i] :: any
			if t.Symbol ~= symbol then
				continue
			end
			shown += 1
			if shown > TRADE_ROWS then
				break
			end
			local row = tradeRows[shown]
			row.Frame.Visible = true
			row.Price.Text = Format.price(t.Price)
			row.Price.TextColor3 = sideColor(t.Side)
			row.Size.Text = Format.int(t.Size)
			row.Time.Text = if t.Trader then t.Trader else clock(t.T)
			row.Time.TextColor3 = if t.Trader then Colors.Text else Colors.TextMuted
		end
		for i = shown + 1, TRADE_ROWS do
			tradeRows[i].Frame.Visible = false
		end
	end

	local function refreshHeader(snapshot: Types.PerpsSnapshot, market: Types.PerpMarket)
		markLabel.Text = Format.price(market.Mark)
		changeLabel.Text = Format.percent(market.Change)
		changeLabel.TextColor3 = Util.changeColor(market.Change)
		oracleValue.Text = Format.price(market.Oracle)
		volumeValue.Text = Format.usd(market.Volume)
		oiValue.Text = Format.usd(market.OpenInterest)
		fundingValue.Text = string.format("%.5f%%", market.Funding * 100)
		fundingValue.TextColor3 = Util.changeColor(market.Funding)
		countdownValue.Text = countdown(market.NextFunding - snapshot.T)
		for s, row in marketRows do
			local m = snapshot.Markets[s]
			if m then
				row.Price.Text = Format.price(m.Mark)
				row.Change.Text = Format.percent(m.Change)
				row.Change.TextColor3 = Util.changeColor(m.Change)
			end
		end
	end

	local function refreshChart()
		local candles = Perps.candles(symbol, timeframe)
		chart.Set(candles or {}, 1)
		local pos = account().Positions[symbol]
		chart.SetPosition({}, if pos then pos.Entry else nil)
		for seconds, button in tfButtons do
			button.BackgroundTransparency = if seconds == timeframe then 0 else 1
			button.TextColor3 = if seconds == timeframe then Colors.Text else Colors.TextMuted
		end
	end

	local function refreshLive()
		local snapshot = Perps.Snapshot
		local market = Perps.market(symbol)
		if not snapshot or not market then
			return
		end
		refreshHeader(snapshot, market)
		refreshBook(market)
		refreshTrades(snapshot, market)
		refreshChart()
		refreshPanel()
		refreshTables()
	end

	local function setSymbol(newSymbol: string)
		symbol = newSymbol
		symbolLabel.Text = newSymbol
		for _, child in iconSlot:GetChildren() do
			child:Destroy()
		end
		local d = def()
		Icons.token(Color3.fromHex(d.Color), d.Symbol, 28, nil, true).Parent = iconSlot
		leverage = math.min(leverage, d.MaxLeverage)
		for _, chip in leverageChips do
			chip:Destroy()
		end
		table.clear(leverageChips)
		local presets = {}
		for _, lev in PERPS.LeveragePresets do
			if lev < d.MaxLeverage then
				table.insert(presets, lev)
			end
		end
		table.insert(presets, d.MaxLeverage)
		for i, lev in presets do
			local chip: TextButton = create("TextButton", {
				Name = lev .. "x",
				AutoButtonColor = false,
				Size = UDim2.new(1 / #presets, -5, 1, 0),
				BackgroundColor3 = Colors.Elevated,
				Text = if i == #presets then `Max {lev}x` else `{lev}x`,
				TextSize = 13,
				FontFace = Fonts.SemiBold,
				TextColor3 = Colors.Text,
				LayoutOrder = i,
				Parent = leverageRow,
			}, { Util.corner(6) })
			chip.Activated:Connect(function()
				leverage = lev
				leverageRow.Visible = false
				refreshPanel()
			end)
			leverageChips[lev] = chip
		end
		priceInput.Text = ""
		lastMark = nil
		dropdown.Visible = false
		refreshLive()
		refreshPanel()
	end

	for i, d in PERPS.Markets do
		local row: TextButton = create("TextButton", {
			Name = d.Symbol,
			AutoButtonColor = false,
			Size = UDim2.new(1, 0, 0, 40),
			BackgroundColor3 = Colors.Border,
			BackgroundTransparency = 1,
			Text = "",
			LayoutOrder = i,
			ZIndex = 21,
			Parent = dropdown,
		}, { Util.corner(6), Util.padding(0, 10) })
		Util.hoverBackground(row, Colors.Border, Colors.Border, 1)
		local icon = Icons.token(Color3.fromHex(d.Color), d.Symbol, 24, nil, true)
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.fromScale(0, 0.5)
		icon.Parent = row
		Util.label({ Text = d.Symbol, Size = 15, Font = Fonts.Bold, Position = UDim2.fromOffset(34, 0), FrameSize = UDim2.new(0, 60, 1, 0), Parent = row })
		Util.label({ Text = d.Name, Size = 13, Color = Colors.TextMuted, Position = UDim2.fromOffset(84, 0), FrameSize = UDim2.new(0, 80, 1, 0), Parent = row })
		local price = Util.label({ Text = "-", Size = 14, AlignX = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.45, 0), FrameSize = UDim2.fromScale(0.3, 1), Parent = row })
		local change = Util.label({ Text = "", Size = 13, AlignX = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.75, 0), FrameSize = UDim2.fromScale(0.25, 1), Parent = row })
		for _, child in row:GetDescendants() do
			if child:IsA("GuiObject") then
				child.ZIndex = 21
			end
		end
		marketRows[d.Symbol] = { Price = price, Change = change }
		row.Activated:Connect(function()
			setSymbol(d.Symbol)
		end)
	end

	tabs(typeTabsRow, { "Market", "Limit" }, 15, function(index: number)
		orderType = if index == 1 then "Market" else "Limit"
		if orderType == "Limit" and priceInput.Text == "" then
			local mark = Perps.mark(symbol)
			priceInput.Text = if mark then Format.plain(mark, 6) else ""
		end
		refreshPanel()
	end)

	-- Suwak: przeciąganie i kliknięcia w procenty.
	local dragging = false
	local function dragTo(x: number)
		local width = track.AbsoluteSize.X
		if width > 0 then
			setPercent((x - track.AbsolutePosition.X) / width, true)
		end
	end
	track.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragTo(input.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			dragTo(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	for p, button in percentMarks do
		button.Activated:Connect(function()
			setPercent(p / 100, true)
		end)
	end

	local function submitOrder()
		if busy then
			return
		end
		if Portfolio.State.Balance < Config.MinTradeRx then
			Actions.claimFaucet()
			return
		end
		local m = margin()
		if not m then
			Toast.show("Enter a margin amount", "Error")
			return
		end
		local request: Types.PerpOrderRequest = {
			Symbol = symbol,
			Side = side,
			Type = orderType,
			Margin = m,
			Leverage = leverage,
			Price = if orderType == "Limit" then parseNumber(priceInput.Text) else nil,
			TP = if tpslOn then parseNumber(tpInput.Text) else nil,
			SL = if tpslOn then parseNumber(slInput.Text) else nil,
		}
		busy = true
		refreshPanel()
		task.spawn(function()
			local ok = Perps.order(request)
			busy = false
			if ok then
				amountInput.Text = ""
				tpInput.Text = ""
				slInput.Text = ""
				setPercent(0, false)
			end
			refreshPanel()
		end)
	end

	longButton.Activated:Connect(function()
		side = "Long"
		refreshPanel()
	end)
	shortButton.Activated:Connect(function()
		side = "Short"
		refreshPanel()
	end)
	leverageButton.Activated:Connect(function()
		leverageRow.Visible = not leverageRow.Visible
	end)
	tpslToggle.Activated:Connect(function()
		tpslOn = not tpslOn
		refreshPanel()
	end)
	markButton.Activated:Connect(function()
		local mark = Perps.mark(symbol)
		if mark then
			priceInput.Text = Format.plain(mark, 6)
		end
	end)
	selector.Activated:Connect(function()
		dropdown.Visible = not dropdown.Visible
	end)
	for seconds, button in tfButtons do
		button.Activated:Connect(function()
			timeframe = seconds
			chart.ResetView()
			refreshChart()
		end)
	end
	submit.Activated:Connect(submitOrder)
	amountInput:GetPropertyChangedSignal("Text"):Connect(refreshPanel)
	priceInput:GetPropertyChangedSignal("Text"):Connect(refreshPanel)
	amountInput.FocusLost:Connect(function(enter: boolean)
		if enter then
			submitOrder()
		end
	end)

	Perps.Changed:Connect(function()
		if frame.Visible then
			refreshLive()
		end
	end)
	Portfolio.Changed:Connect(function()
		if frame.Visible then
			refreshPanel()
			refreshTables()
			refreshChart()
		end
	end)

	setSymbol(symbol)

	return {
		Frame = frame,
		Refresh = function()
			refreshLive()
			refreshPanel()
			refreshTables()
		end,
	}
end

return PerpsPage
