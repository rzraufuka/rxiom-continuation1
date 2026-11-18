--!strict
-- Górny pasek: logo, nawigacja, wyszukiwarka, Deposit (faucet), portfel, avatar.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Format = require(ReplicatedStorage.Shared.Format)

local State = script.Parent.Parent.Parent.State
local Actions = require(State.Actions)
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

local NAV_ITEMS = { "Discover", "Pulse", "Trackers", "Perpetuals", "Portfolio", "Upgrades" }

export type Navigation = {
	Discover: () -> (),
	Pulse: () -> (),
	Trackers: () -> (),
	Perpetuals: () -> (),
	Upgrades: () -> (),
	Portfolio: () -> (),
	-- Otwiera okno przelewu RXI.
	Send: () -> (),
	-- Pokazuje samouczek od nowa.
	Tutorial: () -> (),
}

local TopBar = {}
TopBar.Height = 64

local function logo(onClick: () -> ()): TextButton
	local button: TextButton = create("TextButton", {
		Name = "Logo",
		AutoButtonColor = false,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.new(),
		BackgroundTransparency = 1,
		Text = "",
		LayoutOrder = 1,
	}, { Util.hlist(10) })
	Icons.logo(22, 1).Parent = button
	Util.text({ Text = "RXIOM", Size = 26, Font = Fonts.Bold, Order = 2, Parent = button })
	button.Activated:Connect(onClick)
	return button
end

local function searchBox(): (Frame, TextBox)
	local box = create("Frame", {
		Name = "Search",
		Size = UDim2.fromOffset(206, 40),
		BackgroundColor3 = Colors.Background,
		LayoutOrder = 1,
	}, { Util.round(), Util.stroke(Colors.Border), Util.padding(0, 10, 0, 14) })
	local icon = Icons.search(16, Colors.Text)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.fromScale(0, 0.5)
	icon.Parent = box
	local input: TextBox = create("TextBox", {
		Name = "Input",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(26, 0),
		Size = UDim2.new(1, -56, 1, 0),
		ClearTextOnFocus = false,
		Text = "",
		PlaceholderText = "Search by token or CA",
		PlaceholderColor3 = Colors.TextMuted,
		TextColor3 = Colors.Text,
		TextSize = 15,
		FontFace = Fonts.Regular,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = box,
	})
	create("TextLabel", {
		Name = "Shortcut",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(22, 22),
		BackgroundTransparency = 1,
		Text = "/",
		TextSize = 13,
		FontFace = Fonts.Medium,
		TextColor3 = Colors.Text,
		Parent = box,
	}, { Util.corner(6), Util.stroke(Colors.Border) })
	box.MouseEnter:Connect(function()
		Util.tween(box, { BackgroundColor3 = Colors.Surface })
	end)
	box.MouseLeave:Connect(function()
		Util.tween(box, { BackgroundColor3 = Colors.Background })
	end)
	return box, input
end

local function pillButton(name: string, order: number, width: number?): TextButton
	return create("TextButton", {
		Name = name,
		AutoButtonColor = false,
		AutomaticSize = if width then Enum.AutomaticSize.None else Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(width or 0, 40),
		BackgroundColor3 = Colors.Elevated,
		Text = "",
		LayoutOrder = order,
	}, { Util.round() })
end

local function avatar(): ImageLabel
	local image: ImageLabel = create("ImageLabel", {
		Name = "Avatar",
		Size = UDim2.fromOffset(36, 36),
		BackgroundColor3 = Colors.Elevated,
		LayoutOrder = 7,
	}, { Util.round() })
	task.spawn(function()
		local ok, content = pcall(
			Players.GetUserThumbnailAsync,
			Players,
			Players.LocalPlayer.UserId,
			Enum.ThumbnailType.HeadShot,
			Enum.ThumbnailSize.Size100x100
		)
		if ok then
			image.Image = content
		end
	end)
	return image
end

export type TopBar = {
	Frame: Frame,
	SetActive: (name: string) -> (),
	-- Elementy pokazywane w samouczku.
	Targets: { [string]: GuiObject },
}

function TopBar.new(nav: Navigation): TopBar
	local frame: Frame = create("Frame", {
		Name = "TopBar",
		Size = UDim2.new(1, 0, 0, TopBar.Height),
		BackgroundColor3 = Colors.Background,
		BorderSizePixel = 0,
	})
	local divider = Util.divider()
	divider.AnchorPoint = Vector2.new(0, 1)
	divider.Position = UDim2.fromScale(0, 1)
	divider.Parent = frame
	local inner: Frame = create("Frame", {
		Name = "Inner",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	}, { Util.padding(0, 24) })

	local left = Util.group("Left", 0, Util.hlist(32))
	left.AnchorPoint = Vector2.new(0, 0.5)
	left.Position = UDim2.fromScale(0, 0.5)
	left.Parent = inner
	logo(nav.Discover).Parent = left

	local navFrame = Util.group("Nav", 2, Util.hlist(4))
	navFrame.Parent = left
	local navButtons: { [string]: TextButton } = {}
	local active = "Discover"
	-- Aktywna zakładka ma podświetlone tło (pigułkę), pozostałe tylko tekst.
	local function setActive(name: string)
		active = name
		for itemName, b in navButtons do
			local isActive = itemName == active
			Util.tween(b, {
				TextColor3 = if isActive then Colors.Text else Colors.TextMuted,
				BackgroundTransparency = if isActive then 0 else 1,
			})
		end
	end
	for i, name in NAV_ITEMS do
		local button: TextButton = create("TextButton", {
			Name = name,
			AutoButtonColor = false,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 36),
			BackgroundColor3 = Colors.Elevated,
			BackgroundTransparency = if name == active then 0 else 1,
			Text = name,
			TextSize = 16,
			FontFace = Fonts.SemiBold,
			TextColor3 = if name == active then Colors.Text else Colors.TextMuted,
			LayoutOrder = i,
			Parent = navFrame,
		}, { Util.padding(0, 14), Util.round() })
		button.MouseEnter:Connect(function()
			if name ~= active then
				Util.tween(button, { BackgroundTransparency = 0.5, TextColor3 = Colors.Text })
			end
		end)
		button.MouseLeave:Connect(function()
			if name ~= active then
				Util.tween(button, { BackgroundTransparency = 1, TextColor3 = Colors.TextMuted })
			end
		end)
		button.Activated:Connect(function()
			if name == "Discover" then
				nav.Discover()
			elseif name == "Pulse" then
				nav.Pulse()
			elseif name == "Upgrades" then
				nav.Upgrades()
			elseif name == "Perpetuals" then
				nav.Perpetuals()
			elseif name == "Trackers" then
				nav.Trackers()
			elseif name == "Portfolio" then
				nav.Portfolio()
			else
				Toast.show(`{name} is coming soon`, "Info")
			end
		end)
		navButtons[name] = button
	end

	local right = Util.group("Right", 0, Util.hlist(12, nil, Enum.HorizontalAlignment.Right))
	right.AnchorPoint = Vector2.new(1, 0.5)
	right.Position = UDim2.fromScale(1, 0.5)
	right.Parent = inner

	local search, input = searchBox()
	search.Parent = right
	input:GetPropertyChangedSignal("Text"):Connect(function()
		Settings.set("Search", input.Text)
		if input.Text ~= "" and active ~= "Discover" then
			nav.Discover()
		end
	end)
	UserInputService.InputBegan:Connect(function(io, processed)
		if not processed and io.KeyCode == Enum.KeyCode.Slash then
			task.defer(function()
				input:CaptureFocus()
			end)
		end
	end)

	local deposit = pillButton("Deposit", 2)
	deposit.BackgroundColor3 = Colors.Primary
	deposit.Text = "Deposit"
	deposit.TextSize = 16
	deposit.FontFace = Fonts.SemiBold
	deposit.TextColor3 = Colors.OnPrimary
	Util.padding(0, 18).Parent = deposit
	Util.hoverBackground(deposit, Colors.Primary, Colors.PrimaryHover)
	deposit.Parent = right
	deposit.Activated:Connect(Actions.claimFaucet)

	-- Przelew RXI do innego gracza.
	local send = pillButton("Send", 3)
	Util.padding(0, 16, 0, 14).Parent = send
	Util.hlist(8).Parent = send
	Icons.arrow(18, Colors.Text, "Right", 2).Parent = send
	Util.text({ Text = "Send", Size = 16, Font = Fonts.SemiBold, Order = 1, Parent = send })
	Util.hoverBackground(send, Colors.Elevated, Colors.Border)
	send.Parent = right
	send.Activated:Connect(nav.Send)

	-- Ponowne uruchomienie samouczka.
	local help = pillButton("Help", 4, 40)
	local helpIcon = Icons.help(18, Colors.Text)
	helpIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	helpIcon.Position = UDim2.fromScale(0.5, 0.5)
	helpIcon.Parent = help
	Util.hoverBackground(help, Colors.Elevated, Colors.Border)
	help.Parent = right
	help.Activated:Connect(nav.Tutorial)

	local favorites = pillButton("Favorites", 5, 40)
	local star = Icons.star(18, Colors.Text)
	star.AnchorPoint = Vector2.new(0.5, 0.5)
	star.Position = UDim2.fromScale(0.5, 0.5)
	star.Parent = favorites
	Util.hoverBackground(favorites, Colors.Elevated, Colors.Border)
	favorites.Parent = right
	favorites.Activated:Connect(function()
		Toast.show("Favorites are coming soon", "Info")
	end)

	local wallet = pillButton("Wallet", 6)
	Util.padding(0, 14).Parent = wallet
	Util.hlist(8).Parent = wallet
	Icons.wallet(16, Colors.Text, 1).Parent = wallet
	Icons.currency(16, 2).Parent = wallet
	local balance = Util.text({ Text = "0", Size = 17, Font = Fonts.SemiBold, Order = 3, Parent = wallet })
	Icons.chevronDown(12, Colors.TextMuted, 4).Parent = wallet
	Util.hoverBackground(wallet, Colors.Elevated, Colors.Border)
	wallet.Parent = right
	wallet.Activated:Connect(nav.Portfolio)
	Portfolio.Changed:Connect(function()
		balance.Text = Format.decimal(Portfolio.State.Balance)
	end)
	balance.Text = Format.decimal(Portfolio.State.Balance)

	avatar().Parent = right

	return {
		Frame = frame,
		SetActive = setActive,
		Targets = {
			Deposit = deposit,
			Send = send,
			Help = help,
			Wallet = wallet,
			Pulse = navButtons.Pulse,
			Trackers = navButtons.Trackers,
			Perpetuals = navButtons.Perpetuals,
			Portfolio = navButtons.Portfolio,
			Upgrades = navButtons.Upgrades,
		},
	}
end

return TopBar
