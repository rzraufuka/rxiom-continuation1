--!strict
-- Ekran logowania na rxiom.pro: "Login with Ghostbox" (portfel w stylu Phantoma), wybór konta Roblox
-- w okienku portfela i nadanie adresu portfela (24 znaki). Czarno-biały, z animacjami.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)

local Icons = require(script.Parent.Icons)
local Theme = require(script.Parent.Theme)
local Util = require(script.Parent.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local WALLET_LENGTH = 24
local BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
local PARTICLES = 46
local CARD_WIDTH = 440
local CARD_PAD = 16
local FIELD_BG = Color3.fromHex("0E0E0E")
local PANEL_BG = Color3.fromHex("0F0F0F")
local ROW_BG = Color3.fromHex("161616")
local ROW_HOVER = Color3.fromHex("1F1F1F")

export type Host = {
	Root: Frame,
	Lock: (path: string) -> (),
	Unlock: () -> (),
}

local Login = {}

local function tween(
	instance: Instance,
	seconds: number,
	props: { [string]: any },
	style: Enum.EasingStyle?,
	direction: Enum.EasingDirection?,
	delay: number?
)
	local info = TweenInfo.new(
		seconds,
		style or Enum.EasingStyle.Quint,
		direction or Enum.EasingDirection.Out,
		0,
		false,
		delay or 0
	)
	TweenService:Create(instance, info, props):Play()
end

-- Kręcący się pierścień (łuk z gradientu na obrysie). Zwraca ramkę i funkcję zatrzymującą.
local function spinner(size: number, color: Color3): (Frame, () -> ())
	local ring: Frame = create("Frame", {
		Name = "Spinner",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
	}, { Util.round() })
	local stroke = create("UIStroke", { Color = color, Thickness = 2, Parent = ring })
	local gradient: UIGradient = create("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.5, 0),
			NumberSequenceKeypoint.new(0.501, 1),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = stroke,
	})
	local connection = RunService.RenderStepped:Connect(function(dt: number)
		gradient.Rotation = (gradient.Rotation + dt * 420) % 360
	end)
	return ring, function()
		connection:Disconnect()
	end
end

local function scaled(instance: GuiObject, value: number): UIScale
	return create("UIScale", { Scale = value, Parent = instance })
end

local function shortWallet(wallet: string): string
	return string.sub(wallet, 1, 4) .. "..." .. string.sub(wallet, -4)
end

-- `onDone`: gdy ekran logowania już zjechał i widać terminal.
function Login.show(host: Host, onDone: (() -> ())?)
	local player = Players.LocalPlayer
	local connections: { RBXScriptConnection } = {}
	local state: "idle" | "choosing" | "connecting" | "revealing" | "done" = "idle"

	host.Lock("/login")

	-- Cały ekran; jako przycisk, żeby kliknięcia nie przechodziły do strony pod spodem.
	local screen: TextButton = create("TextButton", {
		Name = "LoginScreen",
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Colors.Background,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		ZIndex = 20,
		Parent = host.Root,
	})

	-- Tło: miękka poświata i unoszące się drobinki.
	for i, glow in { { 900, 0.985 }, { 640, 0.975 }, { 400, 0.965 } } do
		local circle = create("Frame", {
			Name = "Glow" .. i,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.46),
			Size = UDim2.fromOffset(glow[1], glow[1]),
			BackgroundColor3 = Colors.Text,
			BackgroundTransparency = glow[2],
			BorderSizePixel = 0,
			Parent = screen,
		}, { Util.round() })
		TweenService:Create(
			circle,
			TweenInfo.new(3 + i, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ BackgroundTransparency = math.min(1, glow[2] + 0.012) }
		):Play()
	end

	local rng = Random.new()
	type Particle = { Frame: Frame, X: number, Y: number, Speed: number, Drift: number }
	local particles: { Particle } = {}
	for i = 1, PARTICLES do
		local size = rng:NextInteger(1, 3)
		local p: Particle = {
			Frame = create("Frame", {
				Name = "Particle" .. i,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Size = UDim2.fromOffset(size, size),
				BackgroundColor3 = Colors.Text,
				BackgroundTransparency = rng:NextNumber(0.55, 0.9),
				BorderSizePixel = 0,
				Parent = screen,
			}, { Util.round() }),
			X = rng:NextNumber(),
			Y = rng:NextNumber(),
			Speed = rng:NextNumber(0.008, 0.03),
			Drift = rng:NextNumber(-0.004, 0.004),
		}
		p.Frame.Position = UDim2.fromScale(p.X, p.Y)
		particles[i] = p
	end
	table.insert(
		connections,
		RunService.RenderStepped:Connect(function(dt: number)
			for _, p in particles do
				p.Y -= p.Speed * dt
				p.X += p.Drift * dt
				if p.Y < -0.02 then
					p.Y = 1.02
					p.X = rng:NextNumber()
				end
				p.Frame.Position = UDim2.fromScale(p.X % 1, p.Y)
			end
		end)
	)

	-- Karta logowania (CanvasGroup, żeby wjechała jednym płynnym zanikaniem). CanvasGroup przycina
	-- wszystko poza swoimi granicami, więc margines CARD_PAD zostawia miejsce na obrysy pól
	-- i powiększające się przyciski.
	local card: CanvasGroup = create("CanvasGroup", {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 28),
		Size = UDim2.fromOffset(CARD_WIDTH + CARD_PAD * 2, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		ZIndex = 2,
		Parent = screen,
	}, {
		Util.padding(CARD_PAD),
		Util.vlist(14, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top),
	})

	local brand = Util.group("Brand", 1, Util.hlist(14))
	brand.Parent = card
	local logo = Icons.logo(44, 1)
	logo.Parent = brand
	local logoScale = scaled(logo, 0.6)
	Util.text({ Text = "RXIOM", Size = 44, Font = Fonts.Bold, Order = 2, Parent = brand })

	Util.text({
		Text = "Trade every coin on Roblox at lightning speed.",
		Size = 17,
		Color = Colors.TextMuted,
		Order = 2,
		Parent = card,
	})
	create(
		"Frame",
		{ Name = "Spacer", BackgroundTransparency = 1, Size = UDim2.fromOffset(1, 18), LayoutOrder = 3, Parent = card }
	)

	-- Pole z adresem portfela
	local fieldBlock = create("Frame", {
		Name = "WalletBlock",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(CARD_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 4,
		Parent = card,
	}, { Util.vlist(8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top) })
	Util.text({
		Text = "WALLET",
		Size = 13,
		Font = Fonts.SemiBold,
		Color = Colors.TextMuted,
		Order = 1,
		Parent = fieldBlock,
	})
	local field: Frame = create("Frame", {
		Name = "WalletField",
		Size = UDim2.new(1, 0, 0, 54),
		BackgroundColor3 = FIELD_BG,
		LayoutOrder = 2,
		Parent = fieldBlock,
	}, { Util.corner(12), Util.padding(0, 16) })
	local fieldStroke: UIStroke = create("UIStroke", {
		Color = Colors.Border,
		Thickness = 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = field,
	})
	local walletIcon = Icons.wallet(18, Colors.TextMuted)
	walletIcon.AnchorPoint = Vector2.new(0, 0.5)
	walletIcon.Position = UDim2.fromScale(0, 0.5)
	walletIcon.Parent = field
	local walletText: TextLabel = create("TextLabel", {
		Name = "Address",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(32, 0),
		Size = UDim2.new(1, -64, 1, 0),
		RichText = true,
		Text = "Not connected",
		TextSize = 17,
		FontFace = Fonts.Mono,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = field,
	})
	local statusSlot = create("Frame", {
		Name = "Status",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(22, 22),
		BackgroundColor3 = Colors.Text,
		BackgroundTransparency = 1,
		Parent = field,
	}, { Util.round() })
	local statusScale = scaled(statusSlot, 0)
	local check = Icons.check(14, Colors.Background)
	check.AnchorPoint = Vector2.new(0.5, 0.5)
	check.Position = UDim2.fromScale(0.5, 0.5)
	check.Parent = statusSlot
	local caption = Util.text({ Text = " ", Size = 14, Color = Colors.TextMuted, Order = 3, Parent = fieldBlock })

	-- Przycisk "Login with Ghostbox"
	local button: TextButton = create("TextButton", {
		Name = "LoginButton",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(CARD_WIDTH, 56),
		BackgroundColor3 = Colors.Primary,
		Text = "",
		ClipsDescendants = true,
		LayoutOrder = 5,
		Parent = card,
	}, { Util.round() })
	local buttonScale = scaled(button, 1)
	local buttonContent = Util.group("Content", 0, Util.hlist(10))
	buttonContent.AnchorPoint = Vector2.new(0.5, 0.5)
	buttonContent.Position = UDim2.fromScale(0.5, 0.5)
	buttonContent.ZIndex = 3
	buttonContent.Parent = button
	local buttonGhost = Icons.ghost(28, Colors.OnPrimary, Colors.Primary)
	buttonGhost.LayoutOrder = 1
	buttonGhost.Parent = buttonContent
	local buttonLabel = Util.text({
		Text = "Login with Ghostbox",
		Size = 18,
		Font = Fonts.Bold,
		Color = Colors.OnPrimary,
		Order = 2,
		Parent = buttonContent,
	})
	-- Błysk przelatujący przez przycisk po najechaniu.
	local shine: Frame = create("Frame", {
		Name = "Shine",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(-0.2, 0.5),
		Size = UDim2.new(0, 60, 2, 0),
		Rotation = 20,
		BackgroundColor3 = Colors.Background,
		BackgroundTransparency = 0.93,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = button,
	})

	local errorLabel = Util.text({ Text = "", Size = 14, Color = Colors.Red, Order = 6, Parent = card })
	errorLabel.Visible = false
	Util.text({
		Text = "Secured by Ghostbox  ·  " .. Theme.Site,
		Size = 13,
		Color = Colors.TextDim,
		Order = 7,
		Parent = card,
	})

	-- Okienko portfela Ghostbox
	local backdrop: TextButton = create("TextButton", {
		Name = "Backdrop",
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 30,
		Parent = screen,
	})
	local panel: CanvasGroup = create("CanvasGroup", {
		Name = "GhostboxPopup",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, 30),
		Size = UDim2.fromOffset(380, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = PANEL_BG,
		GroupTransparency = 1,
		Visible = false,
		ZIndex = 31,
		Parent = screen,
	}, {
		Util.corner(16),
		-- Obrys do środka: zewnętrzny CanvasGroup by przyciął.
		create("UIStroke", {
			Color = Colors.Border,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			BorderStrokePosition = Enum.BorderStrokePosition.Inner,
		}),
		Util.padding(18, 20, 20, 20),
		Util.vlist(14, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top),
	})
	local panelScale = scaled(panel, 0.94)

	local header = create("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 32),
		LayoutOrder = 1,
		Parent = panel,
	})
	local headerLeft = Util.group("Brand", 0, Util.hlist(10))
	headerLeft.AnchorPoint = Vector2.new(0, 0.5)
	headerLeft.Position = UDim2.fromScale(0, 0.5)
	headerLeft.Parent = header
	local ghostTile = create("Frame", {
		Name = "GhostTile",
		Size = UDim2.fromOffset(32, 32),
		BackgroundColor3 = Colors.Text,
		LayoutOrder = 1,
		Parent = headerLeft,
	}, { Util.corner(9) })
	local tileGhost = Icons.ghost(26, Colors.Background, Colors.Text)
	tileGhost.AnchorPoint = Vector2.new(0.5, 0.5)
	tileGhost.Position = UDim2.fromScale(0.5, 0.5)
	tileGhost.Parent = ghostTile
	Util.text({ Text = "Ghostbox", Size = 19, Font = Fonts.Bold, Order = 2, Parent = headerLeft })
	local closeButton: TextButton = create("TextButton", {
		Name = "Close",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(30, 30),
		BackgroundColor3 = ROW_BG,
		Text = "",
		Parent = header,
	}, { Util.round() })
	local closeIcon = Icons.close(12, Colors.TextMuted)
	closeIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	closeIcon.Position = UDim2.fromScale(0.5, 0.5)
	closeIcon.Parent = closeButton

	local divider = Util.divider()
	divider.LayoutOrder = 2
	divider.Parent = panel

	local site = Util.group("Site", 3, Util.vlist(6, Enum.HorizontalAlignment.Center))
	site.Parent = panel
	local favicon = create("Frame", {
		Name = "Favicon",
		Size = UDim2.fromOffset(52, 52),
		BackgroundColor3 = Colors.Background,
		LayoutOrder = 1,
		Parent = site,
	}, { Util.corner(14), Util.stroke(Colors.Border) })
	local faviconLogo = Icons.logo(18)
	faviconLogo.AnchorPoint = Vector2.new(0.5, 0.5)
	faviconLogo.Position = UDim2.fromScale(0.5, 0.5)
	faviconLogo.Parent = favicon
	Util.text({ Text = Theme.Site, Size = 19, Font = Fonts.Bold, Order = 2, Parent = site })
	Util.text({
		Text = "wants to connect to your wallet",
		Size = 14,
		Color = Colors.TextMuted,
		Order = 3,
		Parent = site,
	})

	Util.label({
		Text = "SELECT ACCOUNT",
		Size = 12,
		Font = Fonts.SemiBold,
		Color = Colors.TextMuted,
		FrameSize = UDim2.new(1, 0, 0, 16),
		Order = 4,
		Parent = panel,
	})

	local account: TextButton = create("TextButton", {
		Name = "Account",
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, 68),
		BackgroundColor3 = ROW_BG,
		Text = "",
		LayoutOrder = 5,
		Parent = panel,
	}, { Util.corner(12), Util.padding(0, 14) })
	local accountStroke: UIStroke = create("UIStroke", {
		Color = Colors.Border,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = account,
	})
	local avatar: ImageLabel = create("ImageLabel", {
		Name = "Avatar",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.fromOffset(42, 42),
		BackgroundColor3 = Colors.Elevated,
		Parent = account,
	}, { Util.round() })
	task.spawn(function()
		local ok, content = pcall(
			Players.GetUserThumbnailAsync,
			Players,
			player.UserId,
			Enum.ThumbnailType.HeadShot,
			Enum.ThumbnailSize.Size100x100
		)
		if ok then
			avatar.Image = content
		end
	end)
	Util.label({
		Name = "DisplayName",
		Text = player.DisplayName,
		Size = 16,
		Font = Fonts.SemiBold,
		Position = UDim2.fromOffset(56, 14),
		FrameSize = UDim2.new(1, -96, 0, 20),
		Parent = account,
	})
	local accountSub = Util.label({
		Name = "Username",
		Text = "@" .. player.Name,
		Size = 13,
		Color = Colors.TextMuted,
		Position = UDim2.fromOffset(56, 36),
		FrameSize = UDim2.new(1, -96, 0, 18),
		Parent = account,
	})
	local accountRight = create("Frame", {
		Name = "Right",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(22, 22),
		BackgroundTransparency = 1,
		Parent = account,
	})
	local chevron = Icons.chevron(16, Colors.TextMuted, "Right")
	chevron.AnchorPoint = Vector2.new(0.5, 0.5)
	chevron.Position = UDim2.fromScale(0.5, 0.5)
	chevron.Parent = accountRight

	local cancel: TextButton = create("TextButton", {
		Name = "Cancel",
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, 44),
		BackgroundColor3 = PANEL_BG,
		Text = "Cancel",
		TextSize = 15,
		FontFace = Fonts.SemiBold,
		TextColor3 = Colors.Text,
		LayoutOrder = 6,
		Parent = panel,
	}, { Util.round(), Util.stroke(Colors.Border) })
	Util.label({
		Text = "Only connect to sites you trust.",
		Size = 12,
		Color = Colors.TextDim,
		AlignX = Enum.TextXAlignment.Center,
		FrameSize = UDim2.new(1, 0, 0, 14),
		Order = 7,
		Parent = panel,
	})

	------------------------------------------------------------------

	local function openPopup()
		state = "choosing"
		errorLabel.Visible = false
		backdrop.Visible = true
		panel.Visible = true
		panel.Position = UDim2.new(0.5, 0, 0.5, 30)
		panelScale.Scale = 0.94
		tween(backdrop, 0.25, { BackgroundTransparency = 0.35 })
		tween(panel, 0.35, { GroupTransparency = 0, Position = UDim2.fromScale(0.5, 0.5) })
		tween(panelScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
	end

	local function closePopup()
		tween(backdrop, 0.2, { BackgroundTransparency = 1 })
		tween(panel, 0.2, { GroupTransparency = 1, Position = UDim2.new(0.5, 0, 0.5, 20) }, Enum.EasingStyle.Quad)
		tween(panelScale, 0.2, { Scale = 0.96 }, Enum.EasingStyle.Quad)
		task.delay(0.22, function()
			if state ~= "choosing" then
				backdrop.Visible = false
				panel.Visible = false
			end
		end)
	end

	local function cancelPopup()
		if state ~= "choosing" then
			return
		end
		state = "idle"
		closePopup()
	end

	-- Adres "rozszyfrowuje się" znak po znaku; nieodkryte znaki migają losowo.
	local function revealWallet(wallet: string)
		tween(fieldStroke, 0.4, { Color = Colors.Text })
		walletText.TextColor3 = Colors.Text
		local started = os.clock()
		local revealed = 0
		while revealed < WALLET_LENGTH do
			revealed = math.min(WALLET_LENGTH, math.floor((os.clock() - started) / 0.05))
			local chars = table.create(WALLET_LENGTH)
			for i = 1, WALLET_LENGTH do
				if i <= revealed then
					chars[i] = string.sub(wallet, i, i)
				else
					local k = rng:NextInteger(1, #BASE58)
					chars[i] = string.sub(BASE58, k, k)
				end
			end
			walletText.Text = table.concat(chars, "", 1, revealed)
				.. '<font color="#575757">'
				.. table.concat(chars, "", revealed + 1, WALLET_LENGTH)
				.. "</font>"
			task.wait(0.03)
		end
		walletText.Text = wallet
	end

	local function finish()
		state = "done"
		for _, connection in connections do
			connection:Disconnect()
		end
		host.Unlock()
		-- Ekran odjeżdża w górę jak kurtyna, odsłaniając terminal.
		tween(card, 0.45, { GroupTransparency = 1, Position = UDim2.new(0.5, 0, 0.5, -30) }, Enum.EasingStyle.Quad)
		tween(
			screen,
			0.8,
			{ Position = UDim2.fromScale(0, -1) },
			Enum.EasingStyle.Quint,
			Enum.EasingDirection.InOut,
			0.15
		)
		task.delay(1.05, function()
			screen:Destroy()
			if onDone then
				onDone()
			end
		end)
	end

	local function connect()
		state = "connecting"
		chevron.Visible = false
		local spin, stopSpin = spinner(18, Colors.Text)
		spin.AnchorPoint = Vector2.new(0.5, 0.5)
		spin.Position = UDim2.fromScale(0.5, 0.5)
		spin.Parent = accountRight
		accountSub.Text = "Connecting..."
		tween(accountStroke, 0.2, { Color = Colors.Text })

		local started = os.clock()
		local ok, result = pcall(Remotes.Login.InvokeServer, Remotes.Login)
		local remaining = 0.9 - (os.clock() - started)
		if remaining > 0 then
			task.wait(remaining)
		end
		stopSpin()
		spin:Destroy()

		local response: Types.LoginResult? = if ok and typeof(result) == "table" then result else nil
		if not response or not response.Ok or not response.Wallet then
			state = "choosing"
			chevron.Visible = true
			accountSub.Text = "@" .. player.Name
			tween(accountStroke, 0.2, { Color = Colors.Border })
			cancelPopup()
			errorLabel.Text = if response and response.Error then response.Error else "Connection failed, try again"
			errorLabel.Visible = true
			return
		end

		state = "revealing"
		closePopup()
		buttonLabel.Text = "Connecting wallet..."
		task.wait(0.3)
		local wallet = response.Wallet :: string
		revealWallet(wallet)

		statusSlot.BackgroundTransparency = 0
		tween(statusScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
		caption.Text = if response.New
			then "New wallet created  ·  " .. shortWallet(wallet)
			else "Welcome back, " .. player.DisplayName
		caption.TextColor3 = Colors.Text
		buttonLabel.Text = "Connected"
		task.wait(1)
		finish()
	end

	button.MouseEnter:Connect(function()
		if state == "idle" then
			tween(buttonScale, 0.2, { Scale = 1.03 })
			shine.Position = UDim2.fromScale(-0.2, 0.5)
			tween(shine, 0.6, { Position = UDim2.fromScale(1.2, 0.5) }, Enum.EasingStyle.Quad)
		end
	end)
	button.MouseLeave:Connect(function()
		tween(buttonScale, 0.2, { Scale = 1 })
	end)
	button.MouseButton1Down:Connect(function()
		if state == "idle" then
			tween(buttonScale, 0.1, { Scale = 0.97 })
		end
	end)
	button.Activated:Connect(function()
		tween(buttonScale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
		if state == "idle" then
			openPopup()
		end
	end)
	backdrop.Activated:Connect(cancelPopup)
	closeButton.Activated:Connect(cancelPopup)
	cancel.Activated:Connect(cancelPopup)
	Util.hoverBackground(cancel, PANEL_BG, ROW_BG)
	Util.hoverBackground(closeButton, ROW_BG, ROW_HOVER)
	account.MouseEnter:Connect(function()
		if state == "choosing" then
			tween(account, 0.15, { BackgroundColor3 = ROW_HOVER })
			tween(accountStroke, 0.15, { Color = Color3.fromHex("3A3A3A") })
		end
	end)
	account.MouseLeave:Connect(function()
		tween(account, 0.15, { BackgroundColor3 = ROW_BG })
		if state == "choosing" then
			tween(accountStroke, 0.15, { Color = Colors.Border })
		end
	end)
	account.Activated:Connect(function()
		if state == "choosing" then
			task.spawn(connect)
		end
	end)

	-- Wejście: karta wjeżdża i pojawia się, logo "wskakuje".
	tween(card, 0.8, { GroupTransparency = 0, Position = UDim2.fromScale(0.5, 0.5) }, nil, nil, 0.1)
	tween(logoScale, 0.7, { Scale = 1 }, Enum.EasingStyle.Back, nil, 0.25)
end

return Login
