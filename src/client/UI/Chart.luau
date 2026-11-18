--!strict
-- Wykres świecowy market capu z przybliżaniem (kółko myszy / przyciski), przesuwaniem (przeciąganie)
-- oraz znacznikami transakcji gracza i linią średniej ceny wejścia.
-- Pozycje w skali (0..1), więc działa przy każdym rozmiarze i UIScale.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Types = require(ReplicatedStorage.Shared.Types)
local Theme = require(script.Parent.Theme)
local Util = require(script.Parent.Util)

type Candle = Types.Candle
type Fill = Types.Fill

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local AXIS_WIDTH = 76
local GRID_LINES = 5
local MIN_VISIBLE = 15
local DEFAULT_VISIBLE = 90
local ZOOM_STEP = 1.25
local MAX_MARKERS = Config.MaxFills
local ENTRY_DASHES = 48

export type Chart = {
	Frame: Frame,
	-- `scale` przelicza cenę świecy na wartość na osi (market cap w $).
	Set: (candles: { Candle }, scale: number) -> (),
	-- Transakcje gracza na tym coinie i średnia cena wejścia (nil, gdy brak pozycji).
	SetPosition: (fills: { Fill }, entryPrice: number?) -> (),
	ResetView: () -> (),
}

local Chart = {}

local function controlButton(text: string, order: number): TextButton
	local button: TextButton = create("TextButton", {
		Name = text,
		AutoButtonColor = false,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(26, 24),
		BackgroundColor3 = Colors.Elevated,
		Text = text,
		TextSize = 15,
		FontFace = Fonts.SemiBold,
		TextColor3 = Colors.Text,
		LayoutOrder = order,
	}, { Util.corner(6), Util.stroke(Colors.Border), Util.padding(0, 7) })
	Util.hoverBackground(button, Colors.Elevated, Colors.Border)
	return button
end

-- `formatValue`: podpisy osi i ceny (domyślnie market cap w $, np. "$14.2K").
function Chart.new(maxCandles: number, formatValue: ((number) -> string)?): Chart
	local format = formatValue or Format.usd
	local candles: { Candle } = {}
	local valueScale = 1
	local fills: { Fill } = {}
	local entryPrice: number? = nil
	local visible = DEFAULT_VISIBLE
	-- Ile świec od prawej krawędzi jest ukrytych (0 = widać najnowsze).
	local offset = 0
	local lastSeenT: number? = nil

	local frame: Frame = create("Frame", {
		Name = "Chart",
		BackgroundColor3 = Colors.Surface,
		ClipsDescendants = true,
	}, { Util.corner(8), Util.stroke(Colors.Border) })

	local plot: Frame = create("Frame", {
		Name = "Plot",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 30),
		Size = UDim2.new(1, -(AXIS_WIDTH + 12), 1, -46),
		ClipsDescendants = true,
		Active = true,
		Parent = frame,
	})
	local axis: Frame = create("Frame", {
		Name = "Axis",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 30),
		Size = UDim2.new(0, AXIS_WIDTH, 1, -46),
		Parent = frame,
	})

	local gridLabels: { TextLabel } = {}
	for i = 1, GRID_LINES do
		local y = (i - 1) / (GRID_LINES - 1)
		create("Frame", {
			Name = "Grid",
			Position = UDim2.fromScale(0, y),
			Size = UDim2.new(1, 0, 0, 1),
			BackgroundColor3 = Colors.Divider,
			BorderSizePixel = 0,
			Parent = plot,
		})
		gridLabels[i] = Util.label({
			Text = "",
			Size = 12,
			Color = Colors.TextDim,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 8, y, 0),
			FrameSize = UDim2.new(1, -8, 0, 14),
			Parent = axis,
		})
	end

	local candleFrames: { { Wick: Frame, Body: Frame } } = {}
	for i = 1, maxCandles do
		local wick = create("Frame", {
			Name = "Wick" .. i,
			AnchorPoint = Vector2.new(0.5, 0),
			BorderSizePixel = 0,
			Visible = false,
			Parent = plot,
		})
		local body = create("Frame", {
			Name = "Body" .. i,
			AnchorPoint = Vector2.new(0.5, 0),
			BorderSizePixel = 0,
			Visible = false,
			ZIndex = 2,
			Parent = plot,
		})
		candleFrames[i] = { Wick = wick, Body = body }
	end

	local lastLine: Frame = create("Frame", {
		Name = "LastPrice",
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = Colors.Green,
		BackgroundTransparency = 0.4,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = plot,
	})
	local lastLabel: TextLabel = create("TextLabel", {
		Name = "LastPriceLabel",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromOffset(4, 0),
		Size = UDim2.new(1, -4, 0, 20),
		BackgroundColor3 = Colors.Green,
		Text = "",
		TextSize = 12,
		FontFace = Fonts.SemiBold,
		TextColor3 = Colors.Background,
		ZIndex = 4,
		Parent = axis,
	}, { Util.corner(4) })

	-- Średnia cena wejścia: przerywana biała linia z etykietą na osi.
	local entryLine: Frame = create("Frame", {
		Name = "EntryLine",
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 5,
		Parent = plot,
	})
	for i = 0, ENTRY_DASHES - 1 do
		create("Frame", {
			Position = UDim2.fromScale(i / ENTRY_DASHES, 0),
			Size = UDim2.new(0.6 / ENTRY_DASHES, 0, 0, 1),
			BackgroundColor3 = Colors.Text,
			BorderSizePixel = 0,
			ZIndex = 5,
			Parent = entryLine,
		})
	end
	local entryLabel: TextLabel = create("TextLabel", {
		Name = "EntryLabel",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromOffset(4, 0),
		Size = UDim2.new(1, -4, 0, 20),
		BackgroundColor3 = Colors.Text,
		Text = "",
		TextSize = 11,
		FontFace = Fonts.Bold,
		TextColor3 = Colors.Background,
		Visible = false,
		ZIndex = 6,
		Parent = axis,
	}, { Util.corner(4) })

	-- Znaczniki transakcji gracza: "B" (kupno) i "S" (sprzedaż) w miejscu ceny wykonania.
	local markers: { TextLabel } = {}
	for i = 1, MAX_MARKERS do
		markers[i] = create("TextLabel", {
			Name = "Marker" .. i,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(18, 18),
			BackgroundColor3 = Colors.Green,
			Text = "B",
			TextSize = 11,
			FontFace = Fonts.Bold,
			TextColor3 = Colors.Background,
			Visible = false,
			ZIndex = 7,
			Parent = plot,
		}, { Util.round(), Util.stroke(Colors.Background, 2) })
	end

	local empty = Util.label({
		Name = "Empty",
		Text = "Loading chart...",
		Size = 15,
		Color = Colors.TextMuted,
		AlignX = Enum.TextXAlignment.Center,
		Parent = plot,
	})

	-- Pasek nad wykresem: legenda i sterowanie przybliżeniem.
	Util.label({
		Name = "Legend",
		Text = `{Config.CandleSeconds}s candles · Market cap · scroll to zoom at cursor, drag to move`,
		Size = 12,
		Color = Colors.TextDim,
		Position = UDim2.fromOffset(14, 4),
		FrameSize = UDim2.new(1, -280, 0, 22),
		Parent = frame,
	})
	local controls = Util.group("Zoom", 0, Util.hlist(4, nil, Enum.HorizontalAlignment.Right))
	controls.AnchorPoint = Vector2.new(1, 0)
	controls.Position = UDim2.new(1, -10, 0, 4)
	controls.ZIndex = 8
	controls.Parent = frame
	local toStart = controlButton("<<", 1)
	toStart.Parent = controls
	local zoomOut = controlButton("-", 2)
	zoomOut.Parent = controls
	local zoomIn = controlButton("+", 3)
	zoomIn.Parent = controls
	local toEnd = controlButton(">>", 4)
	toEnd.Parent = controls
	local reset = controlButton("Reset", 5)
	reset.Parent = controls

	------------------------------------------------------------------

	local function maxOffset(): number
		return math.max(0, #candles - math.min(visible, #candles))
	end

	local function draw()
		local total = #candles
		local count = math.min(total, visible)
		empty.Visible = count == 0
		lastLine.Visible = count > 0
		lastLabel.Visible = count > 0
		if count == 0 then
			for _, c in candleFrames do
				c.Wick.Visible = false
				c.Body.Visible = false
			end
			for _, m in markers do
				m.Visible = false
			end
			entryLine.Visible = false
			entryLabel.Visible = false
			return
		end
		offset = math.clamp(offset, 0, maxOffset())
		local last = total - offset
		local first = last - count + 1

		local lo, hi = math.huge, -math.huge
		for i = first, last do
			lo = math.min(lo, candles[i].L)
			hi = math.max(hi, candles[i].H)
		end
		local pad = math.max((hi - lo) * 0.08, hi * 0.002)
		lo, hi = lo - pad, hi + pad
		local range = hi - lo
		local function y(v: number): number
			return (hi - v) / range
		end

		-- Liczba slotów = poziom przybliżenia; przy krótkiej historii świece są wyrównane do prawej.
		local slots = math.max(count, visible)
		local slot = 1 / slots
		local slotOf: { [number]: number } = {}
		for i, frames in candleFrames do
			local index = first + i - 1
			local candle = candles[index]
			local show = i <= count and candle ~= nil
			frames.Wick.Visible = show
			frames.Body.Visible = show
			if show then
				local x = (slots - count + i - 0.5) * slot
				slotOf[candle.T] = x
				local color = if candle.C >= candle.O then Colors.Green else Colors.Red
				frames.Wick.BackgroundColor3 = color
				frames.Wick.Position = UDim2.fromScale(x, y(candle.H))
				frames.Wick.Size = UDim2.new(0, 1, (candle.H - candle.L) / range, 0)
				local top = math.max(candle.O, candle.C)
				local bottom = math.min(candle.O, candle.C)
				frames.Body.BackgroundColor3 = color
				frames.Body.Position = UDim2.fromScale(x, y(top))
				frames.Body.Size = UDim2.new(slot * 0.7, 0, (top - bottom) / range, 1)
			end
		end

		for i, label in gridLabels do
			local v = hi - (i - 1) / (GRID_LINES - 1) * range
			label.Text = format(v * valueScale)
		end

		local newest = candles[total]
		local lastY = y(newest.C)
		local lastVisible = offset == 0
		local color = if newest.C >= candles[first].O then Colors.Green else Colors.Red
		lastLine.Visible = lastVisible
		lastLabel.Visible = lastVisible
		lastLine.Position = UDim2.fromScale(0, lastY)
		lastLine.BackgroundColor3 = color
		lastLabel.Position = UDim2.new(0, 4, lastY, 0)
		lastLabel.BackgroundColor3 = color
		lastLabel.Text = format(newest.C * valueScale)

		-- Średnia cena wejścia; poza zakresem przyklejona do krawędzi, żeby zawsze było ją widać.
		local entry = entryPrice
		entryLine.Visible = entry ~= nil
		entryLabel.Visible = entry ~= nil
		if entry then
			local ey = math.clamp(y(entry), 0, 1)
			entryLine.Position = UDim2.fromScale(0, ey)
			entryLabel.Position = UDim2.new(0, 4, ey, 0)
			entryLabel.Text = "Entry " .. format(entry * valueScale)
		end

		-- Znaczniki: świeca, w której była transakcja, i cena wykonania.
		local used = 0
		for i = #fills, 1, -1 do
			if used >= MAX_MARKERS then
				break
			end
			local f = fills[i]
			local x = slotOf[math.floor(f.T / Config.CandleSeconds) * Config.CandleSeconds]
			if x then
				used += 1
				local marker = markers[used]
				local isBuy = f.Side == "Buy"
				marker.Visible = true
				marker.Text = if isBuy then "B" else "S"
				marker.BackgroundColor3 = if isBuy then Colors.Green else Colors.Red
				marker.Position = UDim2.fromScale(x, math.clamp(y(f.Price), 0.03, 0.97))
			end
		end
		for i = used + 1, MAX_MARKERS do
			markers[i].Visible = false
		end
	end

	-- Przybliża tak, żeby świeca w miejscu `fraction` (0 = lewa krawędź, 1 = prawa) została pod kursorem.
	local function zoom(factor: number, fraction: number)
		local nextVisible = math.clamp(math.round(visible * factor), MIN_VISIBLE, maxCandles)
		if nextVisible == visible then
			return
		end
		offset = math.round(offset + (visible - nextVisible) * (1 - fraction))
		visible = nextVisible
		draw()
	end

	local function cursorFraction(x: number): number
		local width = plot.AbsoluteSize.X
		if width <= 0 then
			return 1
		end
		return math.clamp((x - plot.AbsolutePosition.X) / width, 0, 1)
	end

	zoomIn.Activated:Connect(function()
		zoom(1 / ZOOM_STEP, 0.5)
	end)
	zoomOut.Activated:Connect(function()
		zoom(ZOOM_STEP, 0.5)
	end)
	toStart.Activated:Connect(function()
		offset = maxOffset()
		draw()
	end)
	toEnd.Activated:Connect(function()
		offset = 0
		draw()
	end)
	reset.Activated:Connect(function()
		visible = DEFAULT_VISIBLE
		offset = 0
		draw()
	end)

	-- Cały wykres (poza przyciskami) reaguje na kółko i przeciąganie, nie tylko pole świec.
	frame.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			zoom(if input.Position.Z > 0 then 1 / ZOOM_STEP else ZOOM_STEP, cursorFraction(input.Position.X))
		end
	end)

	-- Przeciąganie w prawo pokazuje starsze świece, w lewo nowsze.
	local dragStartX: number? = nil
	local dragStartOffset = 0
	frame.InputBegan:Connect(function(input: InputObject)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
			dragStartX = input.Position.X
			dragStartOffset = offset
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		local startX = dragStartX
		local kind = input.UserInputType
		if startX and (kind == Enum.UserInputType.MouseMovement or kind == Enum.UserInputType.Touch) then
			local width = plot.AbsoluteSize.X
			if width <= 0 then
				return
			end
			local perCandle = width / math.max(visible, 1)
			local moved = math.round((input.Position.X - startX) / perCandle)
			local nextOffset = math.clamp(dragStartOffset + moved, 0, maxOffset())
			if nextOffset ~= offset then
				offset = nextOffset
				draw()
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
			dragStartX = nil
		end
	end)

	return {
		Frame = frame,
		Set = function(newCandles: { Candle }, scale: number)
			-- Przy przesuniętym widoku nowe świece nie przesuwają oglądanego fragmentu.
			-- Lista bywa modyfikowana w miejscu, więc porównujemy z zapamiętanym czasem, nie z tabelą.
			if offset > 0 and lastSeenT then
				for i = #newCandles, 1, -1 do
					if newCandles[i].T <= lastSeenT then
						break
					end
					offset += 1
				end
			end
			local newest = newCandles[#newCandles]
			lastSeenT = if newest then newest.T else nil
			candles = newCandles
			valueScale = scale
			draw()
		end,
		SetPosition = function(newFills: { Fill }, newEntry: number?)
			fills = newFills
			entryPrice = newEntry
			draw()
		end,
		ResetView = function()
			visible = DEFAULT_VISIBLE
			offset = 0
			lastSeenT = nil
			draw()
		end,
	}
end

return Chart
