--!strict
-- Okno "Send RXI": odbiorca (nazwa użytkownika albo adres portfela) z podglądem na żywo, kwota
-- z szybkimi procentami, a po wysłaniu animacja z kręcącą się monetą.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Types = require(ReplicatedStorage.Shared.Types)

local State = script.Parent.Parent.Parent.State
local Portfolio = require(State.Portfolio)
local Transfer = require(State.Transfer)

local UI = script.Parent.Parent
local CoinBurst = require(UI.CoinBurst)
local Icons = require(UI.Icons)
local Theme = require(UI.Theme)
local Util = require(UI.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local WIDTH = 440
local INPUT_BG = Color3.fromHex("101010")
local LOOKUP_DELAY = 0.5
local PERCENTS = { 25, 50, 75, 100 }

export type SendPanel = {
	Open: () -> (),
}

local SendPanel = {}

local function tween(instance: Instance, seconds: number, props: { [string]: any }, style: Enum.EasingStyle?)
	TweenService:Create(instance, TweenInfo.new(seconds, style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props):Play()
end

local function shortWallet(wallet: string): string
	return string.sub(wallet, 1, 4) .. "..." .. string.sub(wallet, -4)
end

local function inputBox(parent: Instance, order: number, height: number): Frame
	return create("Frame", {
		Name = "Box",
		Size = UDim2.new(1, 0, 0, height),
		BackgroundColor3 = INPUT_BG,
		LayoutOrder = order,
		Parent = parent,
	}, { Util.corner(10), Util.stroke(Colors.Border), Util.padding(0, 14) })
end

local function textInput(parent: Instance, placeholder: string, size: number): TextBox
	return create("TextBox", {
		Name = "Input",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ClearTextOnFocus = false,
		Text = "",
		PlaceholderText = placeholder,
		PlaceholderColor3 = Colors.TextDim,
		TextColor3 = Colors.Text,
		TextSize = size,
		FontFace = Fonts.Medium,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = parent,
	})
end

local function sectionTitle(parent: Instance, text: string, order: number)
	Util.text({ Text = text, Size = 13, Font = Fonts.SemiBold, Color = Colors.TextMuted, Order = order, Parent = parent })
end

-- `parent`: cała strona; okno i animacja przykrywają ją w całości.
function SendPanel.new(parent: GuiObject): SendPanel
	local busy = false
	local recipient: Types.RecipientInfo? = nil
	local lookup = 0

	local overlay: TextButton = create("TextButton", {
		Name = "SendRxi",
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 40,
		Parent = parent,
	})
	-- Active: kliknięcia w okno nie zamykają go przez tło.
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
	local header = create("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 36),
		LayoutOrder = 1,
		Parent = dialog,
	})
	local titleGroup = Util.group("Title", 0, Util.hlist(10))
	titleGroup.AnchorPoint = Vector2.new(0, 0.5)
	titleGroup.Position = UDim2.fromScale(0, 0.5)
	titleGroup.Parent = header
	Icons.currency(26, 1).Parent = titleGroup
	Util.text({ Text = `Send {Config.Currency}`, Size = 22, Font = Fonts.Bold, Order = 2, Parent = titleGroup })
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

	-- Odbiorca
	sectionTitle(dialog, "TO", 2)
	local toBox = inputBox(dialog, 3, 50)
	local toInput = textInput(toBox, "Roblox username or Ghostbox wallet", 16)
	local preview: Frame = create("Frame", {
		Name = "Recipient",
		Size = UDim2.new(1, 0, 0, 58),
		BackgroundColor3 = Colors.Elevated,
		BackgroundTransparency = 1,
		LayoutOrder = 4,
		Parent = dialog,
	}, { Util.corner(12), Util.padding(0, 12) })
	local previewAvatar: ImageLabel = create("ImageLabel", {
		Name = "Avatar",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(38, 38),
		BackgroundColor3 = Colors.Border,
		Image = "",
		Parent = preview,
	}, { Util.round() })
	local previewWallet = Icons.wallet(18, Colors.Text)
	previewWallet.AnchorPoint = Vector2.new(0.5, 0.5)
	previewWallet.Position = UDim2.fromScale(0.5, 0.5)
	previewWallet.Parent = previewAvatar
	local previewName = Util.label({
		Name = "Name",
		Text = "",
		Size = 16,
		Font = Fonts.SemiBold,
		Position = UDim2.fromOffset(50, 10),
		FrameSize = UDim2.new(1, -50, 0, 20),
		Parent = preview,
	})
	local previewSub = Util.label({
		Name = "Sub",
		Text = "",
		Size = 13,
		Color = Colors.TextMuted,
		Position = UDim2.fromOffset(50, 31),
		FrameSize = UDim2.new(1, -50, 0, 16),
		Parent = preview,
	})

	-- Kwota
	sectionTitle(dialog, "AMOUNT", 5)
	local amountBox = inputBox(dialog, 6, 58)
	local amountInput = textInput(amountBox, "0.0", 24)
	amountInput.FontFace = Fonts.Bold
	amountInput.Size = UDim2.new(1, -36, 1, 0)
	local amountIcon = Icons.currency(24)
	amountIcon.AnchorPoint = Vector2.new(1, 0.5)
	amountIcon.Position = UDim2.fromScale(1, 0.5)
	amountIcon.Parent = amountBox

	local chips = create("Frame", {
		Name = "Percents",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 32),
		LayoutOrder = 7,
		Parent = dialog,
	}, {
		create("UIGridLayout", {
			CellSize = UDim2.new(0.25, -6, 1, 0),
			CellPadding = UDim2.fromOffset(8, 0),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local chipButtons: { TextButton } = {}
	for i, percent in PERCENTS do
		local chip: TextButton = create("TextButton", {
			Name = "P" .. percent,
			AutoButtonColor = false,
			BackgroundColor3 = Colors.Elevated,
			Text = if percent == 100 then "MAX" else percent .. "%",
			TextSize = 14,
			FontFace = Fonts.SemiBold,
			TextColor3 = Colors.Text,
			LayoutOrder = i,
			Parent = chips,
		}, { Util.round() })
		Util.hoverBackground(chip, Colors.Elevated, Colors.Border)
		chipButtons[i] = chip
	end
	local balanceLabel = Util.text({ Text = "", Size = 14, Color = Colors.TextMuted, Order = 8, Parent = dialog })
	local errorLabel = Util.text({ Text = "", Size = 14, Color = Colors.Red, Order = 9, Parent = dialog })
	errorLabel.Visible = false

	local submit: TextButton = create("TextButton", {
		Name = "Send",
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, 54),
		BackgroundColor3 = Colors.Primary,
		Text = "Send",
		TextSize = 18,
		FontFace = Fonts.Bold,
		TextColor3 = Colors.OnPrimary,
		LayoutOrder = 10,
		Parent = dialog,
	}, { Util.round() })

	------------------------------------------------------------------

	local function amount(): number?
		local n = tonumber((string.gsub(amountInput.Text, "[%s,]", "")))
		if n and n == n and n > 0 and n ~= math.huge then
			return math.floor(n * 1e6) / 1e6
		end
		return nil
	end

	local function showError(message: string?)
		errorLabel.Text = message or ""
		errorLabel.Visible = message ~= nil
	end

	local function setPreview(state: "Empty" | "Loading" | "Found" | "Missing", info: Types.RecipientInfo?)
		preview.BackgroundTransparency = if state == "Empty" then 1 else 0
		previewAvatar.Visible = state ~= "Empty"
		previewName.Visible = state ~= "Empty"
		previewSub.Visible = state ~= "Empty"
		previewAvatar.Image = ""
		previewWallet.Visible = true
		previewName.TextColor3 = Colors.Text
		if state == "Loading" then
			previewName.Text = "Looking up..."
			previewSub.Text = ""
		elseif state == "Missing" then
			previewName.Text = if info then info.Error or "Not found" else "Not found"
			previewName.TextColor3 = Colors.Red
			previewSub.Text = "Check the username or wallet address"
		elseif state == "Found" and info then
			if info.DisplayName then
				previewName.Text = info.DisplayName
				local sub = `@{info.Name or ""}`
				if info.Wallet then
					sub ..= "  ·  " .. shortWallet(info.Wallet)
				end
				sub ..= if info.Self
					then "  ·  that's you (preview, no RXI moves)"
					elseif info.Online then "  ·  online now"
					else "  ·  gets it next time they play"
				previewSub.Text = sub
			else
				previewName.Text = shortWallet(info.Wallet or "")
				previewSub.Text = "Ghostbox wallet"
			end
			local userId = info.UserId
			if userId then
				task.spawn(function()
					local ok, content = pcall(
						Players.GetUserThumbnailAsync,
						Players,
						userId,
						Enum.ThumbnailType.HeadShot,
						Enum.ThumbnailSize.Size100x100
					)
					if ok and recipient == info then
						previewAvatar.Image = content
						previewWallet.Visible = false
					end
				end)
			end
		end
	end

	local function refreshSubmit()
		local value = amount()
		local balance = Portfolio.State.Balance
		balanceLabel.Text = `Balance: {Format.rx(balance)}  ·  no fee`
		local ready = recipient ~= nil and value ~= nil and value >= Config.MinTradeRx and value <= balance + 1e-9
		if busy then
			submit.Text = "Sending..."
		elseif value and recipient then
			submit.Text = `Send {Format.rx(value)}`
		else
			submit.Text = "Send"
		end
		submit.BackgroundTransparency = if ready and not busy then 0 else 0.6
	end

	local function lookupRecipient()
		lookup += 1
		local mine = lookup
		recipient = nil
		local query = toInput.Text
		if #(string.gsub(query, "%s", "")) < 3 then
			setPreview("Empty", nil)
			refreshSubmit()
			return
		end
		setPreview("Loading", nil)
		refreshSubmit()
		task.delay(LOOKUP_DELAY, function()
			if mine ~= lookup then
				return
			end
			local info = Transfer.find(query)
			if mine ~= lookup then
				return
			end
			if info.Ok then
				recipient = info
				setPreview("Found", info)
			else
				setPreview("Missing", info)
			end
			refreshSubmit()
		end)
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
		local value = amount()
		local who = recipient
		if busy then
			return
		end
		if not who then
			showError("Enter who to send to")
			return
		end
		if not value or value < Config.MinTradeRx then
			showError(`Minimum is {Config.MinTradeRx} {Config.Currency}`)
			return
		end
		if value > Portfolio.State.Balance + 1e-9 then
			showError("Insufficient balance")
			return
		end
		showError(nil)
		busy = true
		refreshSubmit()
		task.spawn(function()
			local result = Transfer.send(toInput.Text, value)
			busy = false
			refreshSubmit()
			if not result.Ok then
				showError(result.Error or "Couldn't send, try again")
				return
			end
			hide()
			toInput.Text = ""
			amountInput.Text = ""
			local sent = result.Rx or value
			CoinBurst.play(parent, {
				Title = "Sent",
				Amount = sent,
				Line = `to {result.To or "recipient"}`,
				-- Do siebie: po "Sent" od razu pokaz drugiej animacji, którą widzi odbiorca.
				OnClosed = if result.Self
					then function()
						CoinBurst.play(parent, { Title = "Received", Amount = sent, Line = "from yourself" })
					end
					else nil,
			})
		end)
	end

	toInput:GetPropertyChangedSignal("Text"):Connect(lookupRecipient)
	amountInput:GetPropertyChangedSignal("Text"):Connect(function()
		showError(nil)
		refreshSubmit()
	end)
	for i, chip in chipButtons do
		chip.Activated:Connect(function()
			local balance = Portfolio.State.Balance
			local value = if PERCENTS[i] == 100 then balance else balance * PERCENTS[i] / 100
			amountInput.Text = Format.plain(math.floor(value * 1e6) / 1e6, 8)
		end)
	end
	submit.Activated:Connect(onSubmit)
	amountInput.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			onSubmit()
		end
	end)
	close.Activated:Connect(hide)
	overlay.Activated:Connect(hide)
	Portfolio.Changed:Connect(refreshSubmit)
	submit.MouseEnter:Connect(function()
		if submit.BackgroundTransparency == 0 then
			Util.tween(submit, { BackgroundColor3 = Colors.PrimaryHover })
		end
	end)
	submit.MouseLeave:Connect(function()
		Util.tween(submit, { BackgroundColor3 = Colors.Primary })
	end)

	setPreview("Empty", nil)
	refreshSubmit()

	return {
		Open = function()
			showError(nil)
			overlay.Visible = true
			dialog.GroupTransparency = 1
			dialogScale.Scale = 0.94
			tween(overlay, 0.25, { BackgroundTransparency = 0.35 }, Enum.EasingStyle.Quad)
			tween(dialog, 0.3, { GroupTransparency = 0 })
			tween(dialogScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
			refreshSubmit()
			toInput:CaptureFocus()
		end,
	}
end

return SendPanel
