--!strict
-- Panel kupna/sprzedaży coina wzorowany na panelu z axiom.trade:
-- Buy/Sell, zakładki Market/Limit/Adv., kwota z presetami, ustawienia transakcji, TP/SL i duży przycisk.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Amm = require(ReplicatedStorage.Shared.Amm)
local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Upgrades = require(ReplicatedStorage.Shared.Upgrades)
local Types = require(ReplicatedStorage.Shared.Types)

local State = script.Parent.Parent.Parent.State
local Actions = require(State.Actions)
local Market = require(State.Market)
local Portfolio = require(State.Portfolio)
local Settings = require(State.Settings)

local UI = script.Parent.Parent
local Icons = require(UI.Icons)
local Theme = require(UI.Theme)
local Toast = require(UI.Toast)
local Util = require(UI.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

-- "Market" | "Limit" | "Adv."
type Tab = string

local TABS: { Tab } = { "Market", "Limit", "Adv." }
local BUY_TEXT = Colors.OnPrimary
local INPUT_BG = Color3.fromHex("101010")

export type TradePanel = {
	Frame: Frame,
	SetCoin: (ticker: string) -> (),
	-- Przełącza na zakładkę Limit z podaną ceną w $ (np. po kliknięciu poziomu w księdze).
	SetLimitPrice: (usd: number) -> (),
}

local TradePanel = {}

local FEE = Config.FeeBps / 10_000

local function textBox(props: { [string]: any }): TextBox
	local defaults = {
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		Text = "",
		TextSize = 17,
		FontFace = Fonts.Medium,
		TextColor3 = Colors.Text,
		PlaceholderColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
	}
	for k, v in props do
		defaults[k] = v
	end
	return create("TextBox", defaults)
end

local function parseNumber(text: string): number?
	local n = tonumber((string.gsub(text, "[%s,$%%]", "")))
	if n and n == n and math.abs(n) ~= math.huge and n > 0 then
		return n
	end
	return nil
end

-- "20K", "1.5M" -> liczba; pozwala wpisywać market cap w skrócie.
local function parseMarketCap(text: string): number?
	local cleaned = string.upper((string.gsub(text, "[%s,$]", "")))
	local multiplier = 1
	local suffix = string.sub(cleaned, -1)
	if suffix == "K" then
		multiplier = 1e3
	elseif suffix == "M" then
		multiplier = 1e6
	elseif suffix == "B" then
		multiplier = 1e9
	end
	if multiplier > 1 then
		cleaned = string.sub(cleaned, 1, -2)
	end
	local n = parseNumber(cleaned)
	return if n then n * multiplier else nil
end

function TradePanel.new(): TradePanel
	local ticker: string? = nil
	local side: Types.Side = "Buy"
	local tab: Tab = "Market"
	local advanced = false
	local collapsed = false
	local editingPresets = false
	local busy = false

	local frame: Frame = create("Frame", {
		Name = "TradePanel",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, { Util.vlist(14, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top) })

	-- 1. Buy / Sell + zwijanie panelu
	local sideRow = create("Frame", {
		Name = "SideRow",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 56),
		LayoutOrder = 1,
		Parent = frame,
	})
	local toggle = create("Frame", {
		Name = "Toggle",
		Size = UDim2.new(1, -58, 1, 0),
		BackgroundColor3 = Colors.Background,
		Parent = sideRow,
	}, { Util.corner(10), Util.stroke(Colors.Border), Util.padding(5) })
	local function sideButton(name: string, x: number): TextButton
		return create("TextButton", {
			Name = name,
			AutoButtonColor = false,
			Position = UDim2.new(x, if x > 0 then 3 else 0, 0, 0),
			Size = UDim2.new(0.5, -3, 1, 0),
			BackgroundTransparency = 1,
			Text = name,
			TextSize = 17,
			FontFace = Fonts.SemiBold,
			TextColor3 = Colors.Text,
			Parent = toggle,
		}, { Util.corner(8) })
	end
	local buyButton = sideButton("Buy", 0)
	local sellButton = sideButton("Sell", 0.5)
	local collapseButton: TextButton = create("TextButton", {
		Name = "Collapse",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(40, 40),
		BackgroundColor3 = Colors.Background,
		Text = "",
		Parent = sideRow,
	}, { Util.round(), Util.stroke(Colors.Border) })
	local chevron: Frame? = nil
	local function setChevron()
		if chevron then
			chevron:Destroy()
		end
		local c = Icons.chevron(16, Colors.Text, if collapsed then "Up" else "Down")
		c.AnchorPoint = Vector2.new(0.5, 0.5)
		c.Position = UDim2.fromScale(0.5, 0.5)
		c.Parent = collapseButton
		chevron = c
	end
	setChevron()
	Util.hoverBackground(collapseButton, Colors.Background, Colors.Elevated)

	local body = create("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = frame,
	}, { Util.vlist(14, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top) })

	-- 2. Zakładki Market / Limit / Adv. + pomoc + portfel
	local tabsRow = create("Frame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 44),
		LayoutOrder = 1,
		Parent = body,
	})
	local tabsDivider = Util.divider()
	tabsDivider.AnchorPoint = Vector2.new(0, 1)
	tabsDivider.Position = UDim2.fromScale(0, 1)
	tabsDivider.Parent = tabsRow
	local tabList = Util.group("TabList", 0, Util.hlist(30))
	tabList.Size = UDim2.fromScale(0, 1)
	tabList.AutomaticSize = Enum.AutomaticSize.X
	tabList.Parent = tabsRow
	local tabButtons: { [Tab]: TextButton } = {}
	for i, name in TABS do
		local button: TextButton = create("TextButton", {
			Name = name,
			AutoButtonColor = false,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromScale(0, 1),
			BackgroundTransparency = 1,
			Text = name,
			TextSize = 17,
			FontFace = Fonts.Medium,
			TextColor3 = Colors.TextMuted,
			LayoutOrder = i,
			Parent = tabList,
		})
		create("Frame", {
			Name = "Underline",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 2),
			BackgroundColor3 = Colors.Text,
			BorderSizePixel = 0,
			Visible = false,
			ZIndex = 2,
			Parent = button,
		})
		if name == "Adv." then
			create("TextLabel", {
				Name = "Badge",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0),
				AutomaticSize = Enum.AutomaticSize.XY,
				Size = UDim2.new(),
				BackgroundColor3 = Colors.BadgeBackground,
				Text = "NEW",
				TextSize = 10,
				FontFace = Fonts.Bold,
				TextColor3 = Colors.BadgeText,
				Parent = button,
			}, { Util.corner(4), Util.padding(1, 5) })
		end
		tabButtons[name] = button
	end

	local tabsRight = Util.group("Right", 0, Util.hlist(12, nil, Enum.HorizontalAlignment.Right))
	tabsRight.AnchorPoint = Vector2.new(1, 0.5)
	tabsRight.Position = UDim2.new(1, 0, 0.5, -1)
	tabsRight.Parent = tabsRow
	local helpButton: TextButton = create("TextButton", {
		Name = "Help",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(22, 22),
		BackgroundTransparency = 1,
		Text = "",
		LayoutOrder = 1,
		Parent = tabsRight,
	})
	Icons.help(20, Colors.TextMuted).Parent = helpButton
	local walletPill = create("Frame", {
		Name = "Wallet",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 32),
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = tabsRight,
	}, { Util.round(), Util.stroke(Colors.Border), Util.padding(0, 12), Util.hlist(6) })
	Icons.wallet(14, Colors.Text, 1).Parent = walletPill
	Util.text({ Text = "1", Size = 15, Order = 2, Parent = walletPill })
	Icons.currency(13, 3).Parent = walletPill
	local walletBalance = Util.text({ Text = "0", Size = 15, Order = 4, Parent = walletPill })

	-- 3. Kwota + presety
	local amountBox = create("Frame", {
		Name = "Amount",
		Size = UDim2.new(1, 0, 0, 104),
		BackgroundColor3 = INPUT_BG,
		LayoutOrder = 2,
		Parent = body,
	}, { Util.corner(8), Util.stroke(Colors.Border) })
	local amountTop = create("Frame", {
		Name = "Input",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0.5),
		Parent = amountBox,
	}, { Util.padding(0, 14) })
	Util.label({
		Text = "AMOUNT",
		Size = 16,
		Color = Colors.TextMuted,
		FrameSize = UDim2.new(0, 80, 1, 0),
		Parent = amountTop,
	})
	local amountInput = textBox({
		Name = "Value",
		Position = UDim2.fromOffset(86, 0),
		Size = UDim2.new(1, -116, 1, 0),
		PlaceholderText = "0.0",
		Parent = amountTop,
	})
	local unitIcon = Icons.currency(18)
	unitIcon.AnchorPoint = Vector2.new(1, 0.5)
	unitIcon.Position = UDim2.fromScale(1, 0.5)
	unitIcon.Parent = amountTop
	local unitPercent = Util.label({
		Text = "%",
		Size = 17,
		Font = Fonts.SemiBold,
		Color = Colors.TextMuted,
		AlignX = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		FrameSize = UDim2.new(0, 20, 1, 0),
		Parent = amountTop,
	})
	local amountDivider = Util.divider()
	amountDivider.Position = UDim2.fromScale(0, 0.5)
	amountDivider.Parent = amountBox

	local presetArea = create("Frame", {
		Name = "Presets",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 0, 0.5, 1),
		Size = UDim2.new(1, -46, 0.5, -1),
		Parent = amountBox,
	})
	type PresetCell = { Button: TextButton, Box: TextBox }
	local presetCells: { PresetCell } = {}
	for i = 1, 4 do
		local cell = create("Frame", {
			Name = "Preset" .. i,
			BackgroundTransparency = 1,
			Position = UDim2.fromScale((i - 1) / 4, 0),
			Size = UDim2.fromScale(0.25, 1),
			Parent = presetArea,
		})
		local divider = Util.divider(true)
		divider.AnchorPoint = Vector2.new(1, 0)
		divider.Position = UDim2.fromScale(1, 0)
		divider.Parent = cell
		local button: TextButton = create("TextButton", {
			Name = "Button",
			AutoButtonColor = false,
			Size = UDim2.new(1, -1, 1, 0),
			BackgroundColor3 = Colors.Elevated,
			BackgroundTransparency = 1,
			Text = "",
			TextSize = 17,
			FontFace = Fonts.Medium,
			TextColor3 = Colors.Text,
			Parent = cell,
		})
		Util.hoverBackground(button, Colors.Elevated, Colors.Elevated, 1)
		local box = textBox({
			Name = "Edit",
			Size = UDim2.new(1, -1, 1, 0),
			BackgroundTransparency = 0,
			BackgroundColor3 = Colors.Elevated,
			TextXAlignment = Enum.TextXAlignment.Center,
			Visible = false,
			Parent = cell,
		})
		presetCells[i] = { Button = button, Box = box }
	end
	local editButton: TextButton = create("TextButton", {
		Name = "EditPresets",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(1, 1),
		Size = UDim2.new(0, 46, 0.5, -1),
		BackgroundColor3 = Colors.Border,
		BackgroundTransparency = 1,
		Text = "",
		Parent = amountBox,
	}, { Util.corner(8) })
	local pencil = Icons.pencil(16, Colors.Text)
	pencil.AnchorPoint = Vector2.new(0.5, 0.5)
	pencil.Position = UDim2.fromScale(0.5, 0.5)
	pencil.Parent = editButton

	-- 4. Cena zlecenia limit w $ (tylko Limit)
	local triggerBox = create("Frame", {
		Name = "LimitPrice",
		Size = UDim2.new(1, 0, 0, 52),
		BackgroundColor3 = INPUT_BG,
		LayoutOrder = 3,
		Visible = false,
		Parent = body,
	}, { Util.corner(8), Util.stroke(Colors.Border), Util.padding(0, 14) })
	Util.label({
		Text = "Price  $",
		Size = 16,
		Color = Colors.TextMuted,
		FrameSize = UDim2.new(0, 70, 1, 0),
		Parent = triggerBox,
	})
	local triggerInput = textBox({
		Name = "Value",
		Position = UDim2.fromOffset(70, 0),
		Size = UDim2.new(1, -190, 1, 0),
		PlaceholderText = "0.0",
		Parent = triggerBox,
	})
	local triggerHint = Util.label({
		Text = "",
		Size = 14,
		Color = Colors.TextDim,
		AlignX = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		FrameSize = UDim2.new(0, 120, 1, 0),
		Parent = triggerBox,
	})

	-- 5. Ustawienia: slippage, priority fee, tip, ochrona MEV
	local settingsRow = Util.group("Settings", 4, Util.hlist(8))
	settingsRow.Parent = body
	local function settingItem(order: number, icon: Frame, color: Color3): (TextButton, TextLabel)
		local button: TextButton = create("TextButton", {
			Name = "Setting" .. order,
			AutoButtonColor = false,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 22),
			BackgroundTransparency = 1,
			Text = "",
			LayoutOrder = order * 2,
			Parent = settingsRow,
		}, { Util.hlist(5) })
		icon.LayoutOrder = 1
		icon.Parent = button
		local label = Util.text({ Text = "", Size = 15, Color = color, Order = 2, Parent = button })
		if order < 4 then
			local separator = Util.divider(true)
			separator.Size = UDim2.fromOffset(1, 14)
			separator.LayoutOrder = order * 2 + 1
			separator.Parent = settingsRow
		end
		return button, label
	end
	local slipButton, slipLabel = settingItem(1, Icons.slippage(13, Colors.TextMuted), Colors.Text)
	local gasButton, gasLabel = settingItem(2, Icons.gas(13, Colors.TextMuted), Colors.Text)
	local tipButton, tipLabel = settingItem(3, Icons.coin(14, Colors.TextMuted), Colors.Text)
	local tipWarning = Icons.warning(14, Colors.Yellow, 3)
	tipWarning.Parent = tipButton
	local mevButton, mevLabel = settingItem(4, Icons.shield(13, Colors.TextMuted), Colors.Text)

	-- 6. Podgląd transakcji
	local quoteLabel = Util.label({
		Name = "Quote",
		Text = "",
		Size = 14,
		Color = Colors.TextMuted,
		FrameSize = UDim2.new(1, 0, 0, 18),
		Order = 5,
		Parent = body,
	})

	-- 7. Advanced Trading Strategy (TP/SL po kupnie)
	local advancedRow: TextButton = create("TextButton", {
		Name = "Advanced",
		AutoButtonColor = false,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 28),
		BackgroundTransparency = 1,
		Text = "",
		LayoutOrder = 6,
		Parent = body,
	}, { Util.hlist(12) })
	local checkbox = create("Frame", {
		Name = "Checkbox",
		Size = UDim2.fromOffset(22, 22),
		BackgroundColor3 = Colors.Primary,
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = advancedRow,
	}, { Util.corner(5), Util.stroke(Colors.Border, 1.5) })
	local checkmark = Icons.check(16, BUY_TEXT)
	checkmark.AnchorPoint = Vector2.new(0.5, 0.5)
	checkmark.Position = UDim2.fromScale(0.5, 0.5)
	checkmark.Visible = false
	checkmark.Parent = checkbox
	Util.text({ Text = "Advanced Trading Strategy", Size = 16, Order = 2, Parent = advancedRow })

	local bracketRow = create("Frame", {
		Name = "Bracket",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 46),
		LayoutOrder = 7,
		Visible = false,
		Parent = body,
	})
	local function bracketInput(label: string, x: number, default: string, color: Color3): TextBox
		local box = create("Frame", {
			Name = label,
			Position = UDim2.new(x, if x > 0 then 6 else 0, 0, 0),
			Size = UDim2.new(0.5, -6, 1, 0),
			BackgroundColor3 = INPUT_BG,
			Parent = bracketRow,
		}, { Util.corner(8), Util.stroke(Colors.Border), Util.padding(0, 12) })
		Util.label({ Text = label, Size = 14, Color = color, FrameSize = UDim2.new(0, 60, 1, 0), Parent = box })
		local input = textBox({
			Position = UDim2.fromOffset(60, 0),
			Size = UDim2.new(1, -80, 1, 0),
			Text = default,
			TextSize = 16,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = box,
		})
		Util.label({
			Text = "%",
			Size = 15,
			Color = Colors.TextMuted,
			AlignX = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			FrameSize = UDim2.new(0, 16, 1, 0),
			Parent = box,
		})
		return input
	end
	local takeProfitInput = bracketInput("TP  +", 0, "100", Colors.Green)
	local stopLossInput = bracketInput("SL  -", 0.5, "50", Colors.Red)

	-- 8. Główny przycisk
	create("Frame", {
		Name = "Spacer",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 10),
		LayoutOrder = 8,
		Parent = body,
	})
	local submitButton: TextButton = create("TextButton", {
		Name = "Submit",
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, 54),
		BackgroundColor3 = Colors.Primary,
		Text = "Buy",
		TextSize = 19,
		FontFace = Fonts.Bold,
		TextColor3 = BUY_TEXT,
		LayoutOrder = 9,
		Parent = body,
	}, { Util.round() })

	------------------------------------------------------------------

	local function presets(): { number }
		return if side == "Buy" then Settings.State.BuyPresets else Settings.State.SellPresets
	end

	local function presetText(value: number): string
		return if side == "Buy" then Format.decimal(value) else Format.decimal(value) .. "%"
	end

	local function amount(): number?
		local n = parseNumber(amountInput.Text)
		if n and side == "Sell" then
			return math.min(n, 100)
		end
		return n
	end

	-- Cena limit w RX za token (pole przyjmuje $).
	local function limitPrice(): number?
		local usd = parseMarketCap(triggerInput.Text)
		return if usd then usd / Config.UsdPerRx else nil
	end

	local function refreshQuote()
		local coin = if ticker then Market.coin(ticker) else nil
		local pool = if ticker then Market.pool(ticker) else nil
		if not ticker or not coin or not pool then
			quoteLabel.Text = ""
			return
		end
		local value = amount()
		local s = Settings.State
		local fees = s.PriorityFee + s.Tip

		if tab == "Limit" then
			triggerInput.PlaceholderText = Format.decimal(coin.Price * Config.UsdPerRx)
			local price = limitPrice()
			if not price then
				triggerHint.Text = "now $" .. Format.decimal(coin.Price * Config.UsdPerRx)
				quoteLabel.Text = "Set a price or click a level in the order book"
				return
			end
			triggerHint.Text = "MC " .. Format.usd(Market.toMarketCap(price))
			local at = "$" .. Format.decimal(price * Config.UsdPerRx)
			local tokens = if side == "Buy"
				then (value or 0) * (1 - FEE) / price
				else Actions.sellTokens(ticker, value or 0)
			-- Zlecenie po drugiej stronie ceny rynkowej wykona się od razu (przynajmniej częściowo).
			local instant = if side == "Buy" then price >= coin.Price else price <= coin.Price
			local suffix = if instant then "  ·  fills now" else ""
			if not value or tokens <= 0 then
				quoteLabel.Text = `{side} at {at}{suffix}`
			elseif side == "Buy" then
				quoteLabel.Text = `~ {Format.compact(tokens)} {ticker} at {at}{suffix}`
			else
				quoteLabel.Text = `{Format.compact(tokens)} {ticker} for ~ {Format.rx(tokens * price)}{suffix}`
			end
			return
		end

		if side == "Buy" then
			if not value then
				local back = Upgrades.value(Portfolio.State.Upgrades, "Cashback")
				local rebate = if back > 0 then ` ({math.round(back * 100)}% back)` else ""
				quoteLabel.Text = `Fee {Config.FeeBps / 100}%{rebate} + {Format.decimal(fees)} {Config.Currency} network`
				return
			end
			local tokens = Amm.buyQuote(pool, value)
			local impact = Amm.priceImpact(pool, "Buy", value)
			quoteLabel.Text = `~ {Format.compact(tokens)} {ticker}  ·  Impact {string.format("%.2f", impact)}%`
		else
			local held = Actions.sellTokens(ticker, 100)
			if held <= Config.DustTokens then
				quoteLabel.Text = `You don't hold any {ticker}`
				return
			end
			if not value then
				quoteLabel.Text = `You hold {Format.compact(held)} {ticker}`
				return
			end
			local tokens = Actions.sellTokens(ticker, value)
			local rx = math.max(0, Amm.sellQuote(pool, tokens) - fees)
			quoteLabel.Text = `~ {Format.rx(rx)} for {Format.compact(tokens)} {ticker}`
		end
	end

	local function refreshPresets()
		for i, cell in presetCells do
			local value = presets()[i]
			cell.Button.Text = presetText(value)
			cell.Button.Visible = not editingPresets
			cell.Box.Visible = editingPresets
			cell.Box.Text = Format.decimal(value)
		end
		editButton.BackgroundTransparency = if editingPresets then 0 else 1
	end

	local function refreshSettings()
		local s = Settings.State
		slipLabel.Text = s.Slippage .. "%"
		gasLabel.Text = Format.decimal(s.PriorityFee)
		tipLabel.Text = Format.decimal(s.Tip)
		tipWarning.Visible = s.Tip >= 0.01
		mevLabel.Text = if s.Mev then "On" else "Off"
		walletBalance.Text = Format.decimal(Portfolio.State.Balance)
	end

	local function refreshSubmit()
		local label = if tab == "Limit" then `{side} Limit` else side
		submitButton.Text = if busy then "Sending..." else `{label} {ticker or ""}`
		local color = if side == "Buy" then Colors.Primary else Colors.Red
		submitButton.BackgroundColor3 = color
		submitButton.TextColor3 = if side == "Buy" then BUY_TEXT else Colors.Text
		submitButton.BackgroundTransparency = if busy then 0.4 else 0
	end

	local function refreshLayout()
		buyButton.BackgroundColor3 = Colors.Primary
		buyButton.BackgroundTransparency = if side == "Buy" then 0 else 1
		buyButton.TextColor3 = if side == "Buy" then BUY_TEXT else Colors.Text
		sellButton.BackgroundColor3 = Colors.Red
		sellButton.BackgroundTransparency = if side == "Sell" then 0 else 1
		sellButton.TextColor3 = Colors.Text
		for name, button in tabButtons do
			local active = name == tab
			button.TextColor3 = if active then Colors.Text else Colors.TextMuted
			local underline = button:FindFirstChild("Underline") :: Frame
			underline.Visible = active
		end
		unitIcon.Visible = side == "Buy"
		unitPercent.Visible = side == "Sell"
		amountInput.PlaceholderText = if side == "Buy" then "0.0" else "0 %"
		triggerBox.Visible = tab == "Limit"
		local canBracket = side == "Buy" and tab == "Market"
		advancedRow.Visible = canBracket
		bracketRow.Visible = canBracket and advanced
		checkbox.BackgroundTransparency = if advanced then 0 else 1
		checkmark.Visible = advanced
		body.Visible = not collapsed
		refreshPresets()
		refreshSettings()
		refreshSubmit()
		refreshQuote()
	end

	local function submit()
		local current = ticker
		if busy or not current then
			return
		end
		local value = amount()
		if not value then
			Toast.show(
				if side == "Buy" then `Enter an amount in {Config.Currency}` else "Enter a percentage to sell",
				"Error"
			)
			return
		end
		local price: number? = nil
		if tab == "Limit" then
			price = limitPrice()
			if not price then
				Toast.show("Enter a limit price in $", "Error")
				return
			end
		end
		local bracket: Actions.Bracket? = nil
		if side == "Buy" and tab == "Market" and advanced then
			local tp, sl = parseNumber(takeProfitInput.Text), parseNumber(stopLossInput.Text)
			if not tp or not sl or sl >= 100 then
				Toast.show("Set take profit and stop loss (stop loss below 100%)", "Error")
				return
			end
			bracket = { TakeProfit = tp, StopLoss = sl }
		end

		busy = true
		refreshSubmit()
		task.spawn(function()
			if price then
				Actions.placeLimit(current, side, value, price)
			elseif side == "Buy" then
				Actions.buy(current, value, bracket)
			else
				Actions.sell(current, value)
			end
			busy = false
			refreshSubmit()
		end)
	end

	buyButton.Activated:Connect(function()
		side = "Buy"
		amountInput.Text = ""
		refreshLayout()
	end)
	sellButton.Activated:Connect(function()
		side = "Sell"
		amountInput.Text = ""
		refreshLayout()
	end)
	collapseButton.Activated:Connect(function()
		collapsed = not collapsed
		setChevron()
		refreshLayout()
	end)
	for name, button in tabButtons do
		button.Activated:Connect(function()
			if name == "Adv." then
				Toast.show("Advanced orders are coming soon. Use TP/SL below for now.", "Info")
				return
			end
			tab = name
			refreshLayout()
		end)
	end
	helpButton.Activated:Connect(function()
		Toast.show(
			"Market: trade instantly at the current price. Limit: post an order on the book at your price; it stays until it fills or you cancel it.",
			"Info"
		)
	end)
	for i, cell in presetCells do
		cell.Button.Activated:Connect(function()
			amountInput.Text = Format.decimal(presets()[i])
			refreshQuote()
		end)
		cell.Box.FocusLost:Connect(function()
			local value = parseNumber(cell.Box.Text)
			if value then
				local list = table.clone(presets())
				list[i] = if side == "Sell" then math.min(value, 100) else value
				Settings.set(if side == "Buy" then "BuyPresets" else "SellPresets", list)
			end
			refreshPresets()
		end)
	end
	editButton.Activated:Connect(function()
		editingPresets = not editingPresets
		refreshPresets()
	end)
	slipButton.Activated:Connect(function()
		Settings.cycle("Slippage", Config.SlippageOptions)
	end)
	gasButton.Activated:Connect(function()
		Settings.cycle("PriorityFee", Config.PriorityFeeOptions)
	end)
	tipButton.Activated:Connect(function()
		Settings.cycle("Tip", Config.TipOptions)
	end)
	mevButton.Activated:Connect(function()
		Settings.set("Mev", not Settings.State.Mev)
	end)
	advancedRow.Activated:Connect(function()
		advanced = not advanced
		refreshLayout()
	end)
	submitButton.Activated:Connect(submit)
	submitButton.MouseEnter:Connect(function()
		if not busy then
			Util.tween(submitButton, { BackgroundTransparency = 0.12 })
		end
	end)
	submitButton.MouseLeave:Connect(function()
		if not busy then
			Util.tween(submitButton, { BackgroundTransparency = 0 })
		end
	end)
	amountInput:GetPropertyChangedSignal("Text"):Connect(refreshQuote)
	triggerInput:GetPropertyChangedSignal("Text"):Connect(refreshQuote)
	amountInput.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			submit()
		end
	end)

	Settings.Changed:Connect(function()
		refreshSettings()
		refreshPresets()
		refreshQuote()
	end)
	Portfolio.Changed:Connect(function()
		refreshSettings()
		refreshQuote()
	end)
	Market.Changed:Connect(refreshQuote)

	refreshLayout()

	return {
		Frame = frame,
		SetCoin = function(newTicker: string)
			if newTicker ~= ticker then
				ticker = newTicker
				triggerInput.Text = ""
			end
			refreshLayout()
		end,
		SetLimitPrice = function(usd: number)
			tab = "Limit"
			triggerInput.Text = Format.plain(usd, 6)
			refreshLayout()
		end,
	}
end

return TradePanel
