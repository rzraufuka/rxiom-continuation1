--!strict
-- Okno tworzenia coina na Pulse: nazwa, ticker, kolor i opcjonalny zakup na start (dev buy).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Upgrades = require(ReplicatedStorage.Shared.Upgrades)

local State = script.Parent.Parent.Parent.State
local Actions = require(State.Actions)
local Portfolio = require(State.Portfolio)

local UI = script.Parent.Parent
local Icons = require(UI.Icons)
local Theme = require(UI.Theme)
local Util = require(UI.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local LAUNCH = Config.Launch
-- Koszt stworzenia coina dla tego gracza (z ulepszeniem Cheaper Launch).
local function launchFee(): number
	return Upgrades.value(Portfolio.State.Upgrades, "LaunchDiscount")
end

local function createLabel(): string
	return `Create coin · {Format.decimal(launchFee())} {Config.Currency}`
end
local INPUT_BG = Color3.fromHex("101010")
local WIDTH = 460

export type CreateCoin = {
	Open: () -> (),
}

local CreateCoin = {}

local function field(parent: Instance, title: string, order: number, placeholder: string): (Frame, TextBox)
	local group: Frame = create("Frame", {
		Name = title,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	}, { Util.vlist(6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top) })
	Util.text({ Text = title, Size = 13, Font = Fonts.SemiBold, Color = Colors.TextMuted, Order = 1, Parent = group })
	local box: Frame = create("Frame", {
		Name = "Box",
		Size = UDim2.new(1, 0, 0, 46),
		BackgroundColor3 = INPUT_BG,
		LayoutOrder = 2,
		Parent = group,
	}, { Util.corner(8), Util.stroke(Colors.Border), Util.padding(0, 14) })
	local input: TextBox = create("TextBox", {
		Name = "Input",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ClearTextOnFocus = false,
		Text = "",
		PlaceholderText = placeholder,
		PlaceholderColor3 = Colors.TextDim,
		TextColor3 = Colors.Text,
		TextSize = 16,
		FontFace = Fonts.Medium,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = box,
	})
	return box, input
end

-- Okno wisi nad stroną `parent` (cała jej powierzchnia przyciemniona).
function CreateCoin.new(parent: GuiObject, onCreated: (ticker: string) -> ()): CreateCoin
	local colorIndex = 1
	local busy = false

	local overlay: TextButton = create("TextButton", {
		Name = "CreateCoin",
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.35,
		Visible = false,
		ZIndex = 20,
		Parent = parent,
	})
	-- Active: kliknięcia w okno nie przechodzą do tła (które zamyka okno).
	local dialog: Frame = create("Frame", {
		Name = "Dialog",
		Active = true,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Colors.Surface,
		Parent = overlay,
	}, {
		Util.corner(16),
		create("UIStroke", {
			Color = Colors.Border,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			BorderStrokePosition = Enum.BorderStrokePosition.Inner,
		}),
		Util.padding(24),
		Util.vlist(16, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top),
	})

	-- Nagłówek z podglądem ikony
	local header = Util.group("Header", 1, Util.hlist(14))
	header.Parent = dialog
	local preview = create("Frame", {
		Name = "Preview",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(52, 52),
		LayoutOrder = 1,
		Parent = header,
	})
	local titles = Util.group("Titles", 2, Util.vlist(4))
	titles.Parent = header
	Util.text({ Text = "Create a coin", Size = 22, Font = Fonts.Bold, Order = 1, Parent = titles })
	Util.text({
		Text = "Launch it on Pulse. Everyone on RXIOM can trade it.",
		Size = 14,
		Color = Colors.TextMuted,
		Order = 2,
		Parent = titles,
	})

	local _, nameInput = field(dialog, "Name", 2, "e.g. Moon Cat")
	local _, tickerInput = field(dialog, "Ticker", 3, "e.g. MCAT")

	-- Kolor
	local colorGroup: Frame = create("Frame", {
		Name = "Color",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 4,
		Parent = dialog,
	}, { Util.vlist(8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top) })
	Util.text({ Text = "Color", Size = 13, Font = Fonts.SemiBold, Color = Colors.TextMuted, Order = 1, Parent = colorGroup })
	local swatches = Util.group("Swatches", 2, Util.hlist(10))
	swatches.Parent = colorGroup
	local swatchStrokes: { UIStroke } = {}
	local swatchButtons: { TextButton } = {}
	for i, hex in LAUNCH.Colors do
		local stroke: UIStroke = create("UIStroke", {
			Color = Colors.Text,
			Thickness = 2,
			Transparency = 1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		})
		swatchButtons[i] = create("TextButton", {
			Name = "Swatch" .. i,
			AutoButtonColor = false,
			Text = "",
			Size = UDim2.fromOffset(30, 30),
			BackgroundColor3 = Color3.fromHex(hex),
			LayoutOrder = i,
			Parent = swatches,
		}, { Util.round(), stroke })
		swatchStrokes[i] = stroke
	end

	local devBox, devInput = field(dialog, `Dev buy (optional, {Config.Currency})`, 5, "0")
	local devIcon = Icons.currency(18)
	devIcon.AnchorPoint = Vector2.new(1, 0.5)
	devIcon.Position = UDim2.fromScale(1, 0.5)
	devIcon.Parent = devBox
	devInput.Size = UDim2.new(1, -28, 1, 0)

	local costLabel = Util.text({
		Text = "",
		Size = 13,
		Color = Colors.TextMuted,
		Order = 6,
		Parent = dialog,
	})
	local errorLabel = Util.text({ Text = "", Size = 14, Color = Colors.Red, Order = 7, Parent = dialog })
	errorLabel.Visible = false

	-- Przyciski
	local buttons: Frame = create("Frame", {
		Name = "Buttons",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 46),
		LayoutOrder = 8,
		Parent = dialog,
	})
	local cancel: TextButton = create("TextButton", {
		Name = "Cancel",
		AutoButtonColor = false,
		Size = UDim2.new(0, 130, 1, 0),
		BackgroundColor3 = Colors.Elevated,
		Text = "Cancel",
		TextSize = 16,
		FontFace = Fonts.SemiBold,
		TextColor3 = Colors.Text,
		Parent = buttons,
	}, { Util.round() })
	Util.hoverBackground(cancel, Colors.Elevated, Colors.Border)
	local submit: TextButton = create("TextButton", {
		Name = "Create",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(1, -142, 1, 0),
		BackgroundColor3 = Colors.Primary,
		Text = createLabel(),
		TextSize = 16,
		FontFace = Fonts.Bold,
		TextColor3 = Colors.OnPrimary,
		Parent = buttons,
	}, { Util.round() })
	Util.hoverBackground(submit, Colors.Primary, Colors.PrimaryHover)

	------------------------------------------------------------------

	local function refreshPreview()
		for _, child in preview:GetChildren() do
			child:Destroy()
		end
		local ticker = if tickerInput.Text ~= "" then tickerInput.Text else "??"
		Icons.token(Color3.fromHex(LAUNCH.Colors[colorIndex]), ticker, 52).Parent = preview
		for i, stroke in swatchStrokes do
			stroke.Transparency = if i == colorIndex then 0 else 1
		end
	end

	local function showError(message: string?)
		errorLabel.Text = message or ""
		errorLabel.Visible = message ~= nil
	end

	local function close()
		if not busy then
			overlay.Visible = false
		end
	end

	local function reset()
		nameInput.Text = ""
		tickerInput.Text = ""
		devInput.Text = ""
		colorIndex = math.random(#LAUNCH.Colors)
		showError(nil)
		refreshPreview()
	end

	local function onSubmit()
		if busy then
			return
		end
		local name = string.gsub(string.gsub(nameInput.Text, "^%s+", ""), "%s+$", "")
		name = string.gsub(name, "%s+", " ")
		local ticker = tickerInput.Text
		local devText = string.gsub(devInput.Text, "%s", "")
		local devBuy = if devText == "" then 0 else tonumber(devText)
		if not Coins.validName(name) then
			showError("Name must be 2-24 letters, digits or spaces")
			return
		end
		if not Coins.validTicker(ticker) then
			showError("Ticker must be 2-8 letters or digits")
			return
		end
		if Coins.get(ticker) then
			showError(`{ticker} is already taken`)
			return
		end
		if not devBuy or devBuy ~= devBuy or devBuy < 0 or devBuy == math.huge then
			showError("Enter a valid dev buy amount")
			return
		end
		local amount = devBuy :: number
		if amount > 0 and amount < Config.MinTradeRx then
			showError(`Minimum dev buy is {Config.MinTradeRx} {Config.Currency}`)
			return
		end
		local balance = Portfolio.State.Balance
		local fee = launchFee()
		if fee > balance + 1e-9 then
			showError(`Creating a coin costs {Format.decimal(fee)} {Config.Currency}, you have {Format.decimal(balance)}`)
			return
		end
		if fee + amount > balance + 1e-9 then
			showError(`Fee + dev buy is more than your balance ({Format.decimal(balance)} {Config.Currency})`)
			return
		end
		showError(nil)
		busy = true
		submit.Text = "Creating..."
		submit.BackgroundTransparency = 0.4
		task.spawn(function()
			local created = Actions.createCoin(name, ticker, colorIndex, amount)
			busy = false
			submit.Text = createLabel()
			submit.BackgroundTransparency = 0
			if created then
				overlay.Visible = false
				reset()
				onCreated(created)
			end
		end)
	end

	tickerInput:GetPropertyChangedSignal("Text"):Connect(function()
		local clean = string.sub((string.gsub(string.upper(tickerInput.Text), "[^A-Z0-9]", "")), 1, 8)
		if clean ~= tickerInput.Text then
			tickerInput.Text = clean
			return
		end
		refreshPreview()
	end)
	nameInput:GetPropertyChangedSignal("Text"):Connect(function()
		if #nameInput.Text > 24 then
			nameInput.Text = string.sub(nameInput.Text, 1, 24)
		end
	end)
	for i, button in swatchButtons do
		button.Activated:Connect(function()
			colorIndex = i
			refreshPreview()
		end)
	end
	overlay.Activated:Connect(close)
	cancel.Activated:Connect(close)
	submit.Activated:Connect(onSubmit)
	devInput.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			onSubmit()
		end
	end)

	reset()

	return {
		Open = function()
			costLabel.Text = `Costs {Format.decimal(launchFee())} {Config.Currency}  ·  starts at {Format.usd(LAUNCH.StartMarketCap)} MC  ·  migrates at {Format.usd(LAUNCH.MigrationMarketCap)} MC`
			submit.Text = createLabel()
			showError(nil)
			overlay.Visible = true
			nameInput:CaptureFocus()
		end,
	}
end

return CreateCoin
