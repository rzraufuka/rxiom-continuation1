--!strict
-- Okno "Price alert" na stronie coina: rodzaj alertu (MC powyżej / poniżej, wzrost / spadek o %),
-- wartość z szybkimi podpowiedziami, podgląd warunku i lista alertów ustawionych na tym coinie.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Format = require(ReplicatedStorage.Shared.Format)
local Types = require(ReplicatedStorage.Shared.Types)

local State = script.Parent.Parent.Parent.State
local Alerts = require(State.Alerts)
local Market = require(State.Market)
local Portfolio = require(State.Portfolio)

local UI = script.Parent.Parent
local Icons = require(UI.Icons)
local Theme = require(UI.Theme)
local Util = require(UI.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local WIDTH = 440
local INPUT_BG = Color3.fromHex("101010")

type Kind = Types.AlertKind

local KINDS: { { Kind: Kind, Label: string } } = {
	{ Kind = "Above", Label = "MC above" },
	{ Kind = "Below", Label = "MC below" },
	{ Kind = "Rise", Label = "Rises by" },
	{ Kind = "Drop", Label = "Drops by" },
}

-- Podpowiedzi: mnożnik obecnego MC albo procent.
local CHIPS: { [Kind]: { number } } = {
	Above = { 1.5, 2, 5, 10 },
	Below = { 0.9, 0.75, 0.5, 0.25 },
	Rise = { 10, 25, 50, 100 },
	Drop = { 10, 20, 30, 50 },
}

export type AlertDialog = {
	Open: (ticker: string) -> (),
}

local AlertDialog = {}

local function tween(instance: Instance, seconds: number, props: { [string]: any }, style: Enum.EasingStyle?)
	TweenService:Create(instance, TweenInfo.new(seconds, style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props):Play()
end

-- "200k", "1.5m", "$2,000,000" -> liczba.
local function parseAmount(text: string): number?
	local clean = string.lower((string.gsub(text, "[%s,$%%]", "")))
	local number, suffix = string.match(clean, "^([%d%.]+)([kmb]?)$")
	local n = if number then tonumber(number) else nil
	if not n or n ~= n or n <= 0 or n == math.huge then
		return nil
	end
	local mult = if suffix == "k" then 1e3 elseif suffix == "m" then 1e6 elseif suffix == "b" then 1e9 else 1
	return n * mult
end

function AlertDialog.new(parent: GuiObject): AlertDialog
	local ticker: string? = nil
	local kind: Kind = "Above"
	local busy = false

	local overlay: TextButton = create("TextButton", {
		Name = "PriceAlert",
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 40,
		Parent = parent,
	})
	local dialog: CanvasGroup = create("CanvasGroup", {
		Name = "Dialog",
		Active = true,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Colors.Surface,
		GroupTransparency = 1,
		Parent = overlay,
	}, {
		Util.corner(18),
		create("UIStroke", {
			Color = Colors.Border,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			BorderStrokePosition = Enum.BorderStrokePosition.Inner,
		}),
		Util.padding(22, 24, 24, 24),
		Util.vlist(14, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top),
	})
	local dialogScale: UIScale = create("UIScale", { Scale = 0.94, Parent = dialog })

	-- Nagłówek
	local header = create("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = 1, Parent = dialog })
	local titleGroup = Util.group("Title", 0, Util.hlist(10))
	titleGroup.AnchorPoint = Vector2.new(0, 0.5)
	titleGroup.Position = UDim2.fromScale(0, 0.5)
	titleGroup.Parent = header
	local bellHolder = create("Frame", {
		Name = "Bell",
		Size = UDim2.fromOffset(32, 32),
		BackgroundColor3 = Colors.Elevated,
		LayoutOrder = 1,
		Parent = titleGroup,
	}, { Util.round() })
	local bell = Icons.bell(18, Colors.Text, true)
	bell.AnchorPoint = Vector2.new(0.5, 0.5)
	bell.Position = UDim2.fromScale(0.5, 0.5)
	bell.Parent = bellHolder
	local titleLabel = Util.text({ Text = "Price alert", Size = 22, Font = Fonts.Bold, Order = 2, Parent = titleGroup })
	local close: TextButton = create("TextButton", {
		Name = "Close",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(32, 32),
		BackgroundColor3 = Colors.Elevated,
		Text = "",
		Parent = header,
	}, { Util.round() })
	local closeIcon = Icons.close(12, Colors.TextMuted)
	closeIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	closeIcon.Position = UDim2.fromScale(0.5, 0.5)
	closeIcon.Parent = close
	Util.hoverBackground(close, Colors.Elevated, Colors.Border)

	local currentLabel = Util.text({ Text = "", Size = 14, Color = Colors.TextMuted, Order = 2, Parent = dialog })

	-- Rodzaj alertu
	local kinds = create("Frame", {
		Name = "Kinds",
		Size = UDim2.new(1, 0, 0, 38),
		BackgroundColor3 = Colors.Elevated,
		LayoutOrder = 3,
		Parent = dialog,
	}, {
		Util.corner(10),
		Util.padding(3),
		create("UIGridLayout", { CellSize = UDim2.new(0.25, -2, 1, 0), CellPadding = UDim2.fromOffset(2, 0), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local kindButtons: { [Kind]: TextButton } = {}
	for i, k in KINDS do
		kindButtons[k.Kind] = create("TextButton", {
			Name = k.Kind,
			AutoButtonColor = false,
			BackgroundColor3 = Colors.Primary,
			BackgroundTransparency = 1,
			Text = k.Label,
			TextSize = 14,
			FontFace = Fonts.SemiBold,
			TextColor3 = Colors.TextMuted,
			LayoutOrder = i,
			Parent = kinds,
		}, { Util.corner(8) })
	end

	-- Wartość
	local box = create("Frame", {
		Name = "Value",
		Size = UDim2.new(1, 0, 0, 54),
		BackgroundColor3 = INPUT_BG,
		LayoutOrder = 4,
		Parent = dialog,
	}, { Util.corner(10), Util.stroke(Colors.Border), Util.padding(0, 14) })
	local input: TextBox = create("TextBox", {
		Name = "Input",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -40, 1, 0),
		ClearTextOnFocus = false,
		Text = "",
		PlaceholderText = "",
		PlaceholderColor3 = Colors.TextDim,
		TextColor3 = Colors.Text,
		TextSize = 22,
		FontFace = Fonts.Bold,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = box,
	})
	local unit = Util.label({
		Text = "$",
		Size = 18,
		Font = Fonts.SemiBold,
		Color = Colors.TextMuted,
		AlignX = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		FrameSize = UDim2.new(0, 40, 1, 0),
		Parent = box,
	})

	local chipsRow = create("Frame", {
		Name = "Chips",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 30),
		LayoutOrder = 5,
		Parent = dialog,
	}, { create("UIGridLayout", { CellSize = UDim2.new(0.25, -6, 1, 0), CellPadding = UDim2.fromOffset(8, 0), SortOrder = Enum.SortOrder.LayoutOrder }) })
	local chipButtons: { TextButton } = {}
	for i = 1, 4 do
		local chip: TextButton = create("TextButton", {
			Name = "Chip" .. i,
			AutoButtonColor = false,
			BackgroundColor3 = Colors.Elevated,
			Text = "",
			TextSize = 14,
			FontFace = Fonts.SemiBold,
			TextColor3 = Colors.Text,
			LayoutOrder = i,
			Parent = chipsRow,
		}, { Util.round() })
		Util.hoverBackground(chip, Colors.Elevated, Colors.Border)
		chipButtons[i] = chip
	end

	local previewLabel = Util.text({ Text = "", Size = 15, Font = Fonts.SemiBold, Order = 6, Parent = dialog })
	local errorLabel = Util.text({ Text = "", Size = 14, Color = Colors.Red, Order = 7, Parent = dialog })
	errorLabel.Visible = false

	local submit: TextButton = create("TextButton", {
		Name = "Create",
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, 50),
		BackgroundColor3 = Colors.Primary,
		Text = "Set alert",
		TextSize = 17,
		FontFace = Fonts.Bold,
		TextColor3 = Colors.OnPrimary,
		LayoutOrder = 8,
		Parent = dialog,
	}, { Util.round() })
	Util.hoverBackground(submit, Colors.Primary, Colors.PrimaryHover)

	-- Lista alertów na tym coinie
	local listTitle = Util.text({ Text = "", Size = 13, Font = Fonts.SemiBold, Color = Colors.TextMuted, Order = 9, Parent = dialog })
	local list = create("Frame", {
		Name = "List",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 10,
		Parent = dialog,
	}, { Util.vlist(6) })

	------------------------------------------------------------------

	local function currentMc(): number?
		local coin = if ticker then Market.coin(ticker) else nil
		return if coin then coin.MarketCap else nil
	end

	local function showError(message: string?)
		errorLabel.Text = message or ""
		errorLabel.Visible = message ~= nil
	end

	local function isPercent(): boolean
		return kind == "Rise" or kind == "Drop"
	end

	local function refreshPreview()
		local mc = currentMc()
		local value = parseAmount(input.Text)
		currentLabel.Text = if mc then `Current market cap: {Format.usd(mc)}` else ""
		if not ticker or not value or not mc then
			previewLabel.Text = "Enter a value"
			previewLabel.TextColor3 = Colors.TextMuted
			return
		end
		local text
		if kind == "Above" then
			text = `Notify me when {ticker} MC goes above {Format.usd(value)}`
		elseif kind == "Below" then
			text = `Notify me when {ticker} MC drops below {Format.usd(value)}`
		elseif kind == "Rise" then
			text = `Notify me when {ticker} is up {Format.decimal(value)}% (MC {Format.usd(mc * (1 + value / 100))})`
		else
			text = `Notify me when {ticker} is down {Format.decimal(value)}% (MC {Format.usd(mc * (1 - value / 100))})`
		end
		previewLabel.Text = text
		previewLabel.TextColor3 = if kind == "Above" or kind == "Rise" then Colors.Green else Colors.Red
	end

	local function refreshList()
		for _, child in list:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		if not ticker then
			return
		end
		local alerts = Alerts.list(ticker)
		listTitle.Text = if #alerts > 0 then `YOUR {ticker} ALERTS ({#alerts})` else ""
		listTitle.Visible = #alerts > 0
		for i, alert in alerts do
			local row = create("Frame", {
				Name = "Alert" .. i,
				Size = UDim2.new(1, 0, 0, 38),
				BackgroundColor3 = Colors.Elevated,
				LayoutOrder = i,
				Parent = list,
			}, { Util.corner(8), Util.padding(0, 8, 0, 14) })
			local up = alert.Direction == "Above"
			Util.label({
				Text = Alerts.describe(alert),
				Size = 14,
				Color = if up then Colors.Green else Colors.Red,
				FrameSize = UDim2.new(1, -36, 1, 0),
				Parent = row,
			})
			local remove: TextButton = create("TextButton", {
				Name = "Remove",
				AutoButtonColor = false,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.fromScale(1, 0.5),
				Size = UDim2.fromOffset(26, 26),
				BackgroundColor3 = Colors.Border,
				BackgroundTransparency = 1,
				Text = "",
				Parent = row,
			}, { Util.round() })
			local x = Icons.close(10, Colors.TextMuted)
			x.AnchorPoint = Vector2.new(0.5, 0.5)
			x.Position = UDim2.fromScale(0.5, 0.5)
			x.Parent = remove
			Util.hoverBackground(remove, Colors.Border, Colors.Border, 1)
			local id = alert.Id
			remove.Activated:Connect(function()
				task.spawn(Alerts.delete, id)
			end)
		end
	end

	local function setKind(k: Kind)
		kind = k
		for key, button in kindButtons do
			local selected = key == k
			tween(button, 0.15, {
				BackgroundTransparency = if selected then 0 else 1,
				TextColor3 = if selected then Colors.OnPrimary else Colors.TextMuted,
			})
		end
		unit.Text = if isPercent() then "%" else "$"
		input.PlaceholderText = if isPercent() then "20" else "200K"
		for i, chip in chipButtons do
			local v = CHIPS[k][i]
			chip.Text = if isPercent() then `{v}%` else `{v}x`
		end
		input.Text = ""
		showError(nil)
		refreshPreview()
	end

	local function hide()
		tween(dialog, 0.2, { GroupTransparency = 1 }, Enum.EasingStyle.Quad)
		tween(dialogScale, 0.2, { Scale = 0.96 }, Enum.EasingStyle.Quad)
		tween(overlay, 0.2, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
		task.delay(0.2, function()
			if dialog.GroupTransparency > 0.99 then
				overlay.Visible = false
			end
		end)
	end

	local function onSubmit()
		if busy or not ticker then
			return
		end
		local value = parseAmount(input.Text)
		if not value then
			showError(if isPercent() then "Enter a percentage" else "Enter a market cap, e.g. 200K")
			return
		end
		showError(nil)
		busy = true
		submit.Text = "Setting..."
		local current = ticker
		task.spawn(function()
			local ok = Alerts.create(current, kind, value)
			busy = false
			submit.Text = "Set alert"
			if ok then
				input.Text = ""
				-- Krótkie "dzwonienie" ikonką na potwierdzenie.
				for i = 1, 4 do
					tween(bell, 0.08, { Rotation = if i % 2 == 1 then 18 else -18 }, Enum.EasingStyle.Sine)
					task.wait(0.08)
				end
				tween(bell, 0.1, { Rotation = 0 })
			end
		end)
	end

	for k, button in kindButtons do
		button.Activated:Connect(function()
			setKind(k :: Kind)
		end)
	end
	for i, chip in chipButtons do
		chip.Activated:Connect(function()
			local v = CHIPS[kind][i]
			if isPercent() then
				input.Text = tostring(v)
			else
				local mc = currentMc()
				if mc then
					input.Text = Format.compact(mc * v)
				end
			end
		end)
	end
	input:GetPropertyChangedSignal("Text"):Connect(function()
		showError(nil)
		refreshPreview()
	end)
	input.FocusLost:Connect(function(enter: boolean)
		if enter then
			onSubmit()
		end
	end)
	submit.Activated:Connect(onSubmit)
	close.Activated:Connect(hide)
	overlay.Activated:Connect(hide)
	Portfolio.Changed:Connect(function()
		if overlay.Visible then
			refreshList()
		end
	end)
	Market.Changed:Connect(function()
		if overlay.Visible then
			refreshPreview()
		end
	end)

	return {
		Open = function(newTicker: string)
			ticker = newTicker
			local def = Coins.get(newTicker)
			titleLabel.Text = if def then `{newTicker} price alert` else "Price alert"
			setKind("Above")
			refreshList()
			overlay.Visible = true
			dialog.GroupTransparency = 1
			dialogScale.Scale = 0.94
			tween(overlay, 0.25, { BackgroundTransparency = 0.35 }, Enum.EasingStyle.Quad)
			tween(dialog, 0.3, { GroupTransparency = 0 })
			tween(dialogScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
			input:CaptureFocus()
		end,
	}
end

return AlertDialog
