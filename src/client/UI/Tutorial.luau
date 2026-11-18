--!strict
-- Samouczek po pierwszym zalogowaniu: przyciemniony ekran z "reflektorem" przesuwającym się po
-- kolejnych elementach strony, karta z opisem obok, kropki postępu, na starcie kręcąca się moneta
-- RXI, a na końcu konfetti. Strzałki / Enter / Esc działają jak przyciski.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local Icons = require(script.Parent.Icons)
local Theme = require(script.Parent.Theme)
local Util = require(script.Parent.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local CARD_WIDTH = 380
local MARGIN = 16
-- Odstęp reflektora od krawędzi elementu.
local PAD = 6
local DIM = 0.3
local MOVE = TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local CONFETTI = 70
local CONFETTI_COLORS = { "2FE3AC", "EC397A", "F5C542", "526FFF", "A855F7", "FFFFFF", "38BDF8" }

export type Host = {
	Root: Frame,
	Targets: { [string]: GuiObject },
	ShowDiscover: () -> (),
}

type Step = { Target: string?, Title: string, Body: string }

local STEPS: { Step } = {
	{
		Title = "Welcome to RXIOM",
		Body = "A memecoin trading terminal inside Roblox. Take a one-minute tour to see how everything works.",
	},
	{
		Target = "Wallet",
		Title = "Your balance",
		Body = `This is your wallet. {Config.Currency} is the in-game currency: every coin you buy is paid in {Config.Currency}, and every sale pays you back in {Config.Currency}.`,
	},
	{
		Target = "Deposit",
		Title = "Free RXI",
		Body = `Running low? Claim {Config.Faucet.Amount} {Config.Currency} for free here every {math.floor(Config.Faucet.Cooldown / 60)} minutes.`,
	},
	{
		Target = "Prices",
		Title = "Live prices",
		Body = "All coins with their price, market cap and change. Click any row to open its chart, order book and Buy / Sell panel.",
	},
	{
		Target = "QuickBuy",
		Title = "Quick Buy",
		Body = "Set an amount here, then press Buy on any row to buy instantly without leaving the list.",
	},
	{
		Target = "Movers",
		Title = "Top Movers",
		Body = "The biggest gainers right now. A good place to spot coins with momentum.",
	},
	{
		Target = "Pulse",
		Title = "Pulse",
		Body = `Coins launched by players. Catch them early, or launch your own for {Config.Launch.Fee} {Config.Currency}.`,
	},
	{
		Target = "Trackers",
		Title = "Trackers",
		Body = "Look up other traders, their PnL and the leaderboard. Your profile stays private until you make it public.",
	},
	{
		Target = "Perpetuals",
		Title = "Perpetuals",
		Body = "Go Long or Short with leverage. Bigger wins, bigger risk: keep an eye on your liquidation price.",
	},
	{
		Target = "Upgrades",
		Title = "Upgrades",
		Body = "Spend RXI on permanent boosts: bigger and faster Deposit, fee cashback, cheaper launches and Pulse Radar.",
	},
	{
		Target = "Send",
		Title = "Send RXI",
		Body = "Send RXI to a friend by their username or wallet address.",
	},
	{
		Target = "Portfolio",
		Title = "Portfolio",
		Body = "Your positions, profit and loss, and trade history.",
	},
	{
		Target = "Help",
		Title = "Need this again?",
		Body = "Press ? any time to replay this tour.",
	},
	{
		Title = "You're ready!",
		Body = "Tip: start small, take profits along the way, and never go all in on one coin. Good luck!",
	},
}

local Tutorial = {}

local active = false

local function tween(instance: Instance, info: TweenInfo, props: { [string]: any })
	TweenService:Create(instance, info, props):Play()
end

local function quick(seconds: number, style: Enum.EasingStyle?): TweenInfo
	return TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
end

function Tutorial.isActive(): boolean
	return active
end

-- `onClose` po zakończeniu albo pominięciu.
function Tutorial.start(host: Host, onClose: (() -> ())?)
	if active then
		return
	end
	active = true
	host.ShowDiscover()

	local root = host.Root
	local index = 1
	local closed = false
	local connections: { RBXScriptConnection } = {}

	-- Klikalna warstwa, żeby kliknięcia nie trafiały w stronę pod spodem.
	local overlay: TextButton = create("TextButton", {
		Name = "Tutorial",
		AutoButtonColor = false,
		Text = "",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 100,
		Parent = root,
	})
	local function dim(name: string): Frame
		return create("Frame", {
			Name = name,
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ZIndex = 100,
			Parent = overlay,
		})
	end
	local top, bottom, left, right = dim("Top"), dim("Bottom"), dim("Left"), dim("Right")
	local dims = { top, bottom, left, right }

	local ring: Frame = create("Frame", {
		Name = "Spotlight",
		BackgroundTransparency = 1,
		ZIndex = 101,
		Parent = overlay,
	}, { Util.corner(12) })
	local ringStroke: UIStroke = create("UIStroke", { Color = Colors.Text, Thickness = 2, Transparency = 1, Parent = ring })
	-- Fala rozchodząca się od podświetlonego elementu.
	local pulse: Frame = create("Frame", {
		Name = "Pulse",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 101,
		Parent = ring,
	}, { Util.corner(14) })
	local pulseStroke: UIStroke = create("UIStroke", { Color = Colors.Text, Thickness = 2, Transparency = 1, Parent = pulse })

	-- Karta z opisem
	local card: CanvasGroup = create("CanvasGroup", {
		Name = "Card",
		Size = UDim2.fromOffset(CARD_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Colors.Surface,
		GroupTransparency = 1,
		ZIndex = 102,
		Parent = overlay,
	}, {
		Util.corner(14),
		create("UIStroke", {
			Color = Colors.Border,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			BorderStrokePosition = Enum.BorderStrokePosition.Inner,
		}),
		Util.padding(20, 22, 18, 22),
		Util.vlist(10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top),
	})
	-- Moneta na pierwszym ekranie: wpada, kręci się i lekko unosi.
	local coinSlot = create("Frame", {
		Name = "CoinSlot",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 84),
		LayoutOrder = 0,
		Visible = false,
		Parent = card,
	})
	local coinHolder: Frame = create("Frame", {
		Name = "Holder",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 72),
		BackgroundTransparency = 1,
		Parent = coinSlot,
	})
	local coin = Icons.currency(72)
	coin.AnchorPoint = Vector2.new(0.5, 0.5)
	coin.Position = UDim2.fromScale(0.5, 0.5)
	coin.Size = UDim2.fromScale(1, 1)
	coin.Parent = coinHolder

	local counter = Util.text({ Text = "", Size = 13, Font = Fonts.SemiBold, Color = Colors.TextMuted, Order = 1, Parent = card })
	local title = Util.text({ Text = "", Size = 22, Font = Fonts.Bold, Order = 2, Parent = card })
	local body: TextLabel = create("TextLabel", {
		Name = "Body",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Text = "",
		TextSize = 16,
		FontFace = Fonts.Medium,
		TextColor3 = Colors.TextMuted,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = 3,
		Parent = card,
	})

	local dotsRow = Util.group("Dots", 4, Util.hlist(5))
	dotsRow.Parent = card
	local dots: { Frame } = {}
	for i = 1, #STEPS do
		dots[i] = create("Frame", {
			Name = "Dot" .. i,
			Size = UDim2.fromOffset(6, 6),
			BackgroundColor3 = Colors.Border,
			LayoutOrder = i,
			Parent = dotsRow,
		}, { Util.round() })
	end

	local buttons = create("Frame", {
		Name = "Buttons",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 40),
		LayoutOrder = 5,
		Parent = card,
	})
	local skip: TextButton = create("TextButton", {
		Name = "Skip",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 32),
		BackgroundTransparency = 1,
		Text = "Skip tour",
		TextSize = 15,
		FontFace = Fonts.SemiBold,
		TextColor3 = Colors.TextMuted,
		Parent = buttons,
	})
	local navGroup = Util.group("Nav", 0, Util.hlist(8, nil, Enum.HorizontalAlignment.Right))
	navGroup.AnchorPoint = Vector2.new(1, 0.5)
	navGroup.Position = UDim2.fromScale(1, 0.5)
	navGroup.Parent = buttons
	local back: TextButton = create("TextButton", {
		Name = "Back",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(80, 40),
		BackgroundColor3 = Colors.Elevated,
		Text = "Back",
		TextSize = 15,
		FontFace = Fonts.SemiBold,
		TextColor3 = Colors.Text,
		LayoutOrder = 1,
		Parent = navGroup,
	}, { Util.round(), Util.stroke(Colors.Border) })
	Util.hoverBackground(back, Colors.Elevated, Colors.Border)
	local nextButton: TextButton = create("TextButton", {
		Name = "Next",
		AutoButtonColor = false,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(96, 40),
		BackgroundColor3 = Colors.Primary,
		Text = "",
		TextSize = 15,
		FontFace = Fonts.Bold,
		TextColor3 = Colors.OnPrimary,
		LayoutOrder = 2,
		Parent = navGroup,
	}, { Util.round(), Util.padding(0, 20) })
	Util.hoverBackground(nextButton, Colors.Primary, Colors.PrimaryHover)

	------------------------------------------------------------------

	-- Rozmiar strony w jej własnych jednostkach (przed UIScale) i skala ekranu.
	local function space(): (Vector2, number)
		local size = Vector2.new(root.Size.X.Offset, root.Size.Y.Offset)
		if size.X <= 0 or size.Y <= 0 then
			size = root.AbsoluteSize
		end
		local scale = if size.X > 0 then root.AbsoluteSize.X / size.X else 1
		return size, if scale > 0 then scale else 1
	end

	-- Prostokąt reflektora w jednostkach strony; nil = brak (środek ekranu, wszystko przyciemnione).
	local function targetRect(step: Step): (Vector2?, Vector2?)
		local target = if step.Target then host.Targets[step.Target] else nil
		if not target or not target.Visible or target.AbsoluteSize.X <= 0 then
			return nil, nil
		end
		local _, scale = space()
		local pos = (target.AbsolutePosition - root.AbsolutePosition) / scale - Vector2.new(PAD, PAD)
		local size = target.AbsoluteSize / scale + Vector2.new(PAD * 2, PAD * 2)
		return pos, size
	end

	local function placeSpotlight(pos: Vector2, size: Vector2, animate: boolean)
		local x, y, w, h = pos.X, pos.Y, size.X, size.Y
		local goals: { [Frame]: { [string]: any } } = {
			[top] = { Position = UDim2.new(), Size = UDim2.new(1, 0, 0, y) },
			[bottom] = { Position = UDim2.fromOffset(0, y + h), Size = UDim2.new(1, 0, 1, -(y + h)) },
			[left] = { Position = UDim2.fromOffset(0, y), Size = UDim2.fromOffset(x, h) },
			[right] = { Position = UDim2.fromOffset(x + w, y), Size = UDim2.new(1, -(x + w), 0, h) },
			[ring] = { Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h) },
		}
		for frame, goal in goals do
			if animate then
				tween(frame, MOVE, goal)
			else
				for k, v in goal do
					(frame :: any)[k] = v
				end
			end
		end
	end

	local function cardPosition(rect: Vector2?, rectSize: Vector2?, cardSize: Vector2): Vector2
		local page = space()
		if not rect or not rectSize then
			return (page - cardSize) / 2
		end
		local cx = math.clamp(rect.X + rectSize.X / 2 - cardSize.X / 2, MARGIN, page.X - cardSize.X - MARGIN)
		local below = rect.Y + rectSize.Y + 14
		if below + cardSize.Y <= page.Y - MARGIN then
			return Vector2.new(cx, below)
		end
		local above = rect.Y - 14 - cardSize.Y
		if above >= MARGIN then
			return Vector2.new(cx, above)
		end
		-- Wysoki element (np. kolumna z boku): karta obok niego.
		local cy = math.clamp(rect.Y + rectSize.Y / 2 - cardSize.Y / 2, MARGIN, page.Y - cardSize.Y - MARGIN)
		local leftX = rect.X - 14 - cardSize.X
		if leftX >= MARGIN then
			return Vector2.new(leftX, cy)
		end
		return Vector2.new(math.min(rect.X + rectSize.X + 14, page.X - cardSize.X - MARGIN), cy)
	end

	-- Moneta na ekranie powitalnym
	local coinStarted = os.clock()
	local coinConnection = RunService.RenderStepped:Connect(function()
		if not coinSlot.Visible then
			return
		end
		local t = os.clock() - coinStarted
		coin.Size = UDim2.fromScale(math.max(0.05, math.abs(math.cos(t * 2.2))), 1)
		coin.Position = UDim2.new(0.5, 0, 0.5, math.sin(t * 2.6) * 4)
	end)
	table.insert(connections, coinConnection)

	local pulseRunning = true
	task.spawn(function()
		while pulseRunning do
			pulse.Size = UDim2.fromScale(1, 1)
			pulseStroke.Transparency = if ring.Visible then 0.3 else 1
			tween(pulse, quick(1.1, Enum.EasingStyle.Quart), { Size = UDim2.new(1, 22, 1, 22) })
			tween(pulseStroke, quick(1.1), { Transparency = 1 })
			task.wait(1.3)
		end
	end)

	local function confetti()
		local page = space()
		local rng = Random.new()
		for _ = 1, CONFETTI do
			local w = rng:NextInteger(6, 12)
			local piece: Frame = create("Frame", {
				Name = "Confetti",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(page.X / 2 + rng:NextNumber(-120, 120), page.Y / 2 + rng:NextNumber(-60, 20)),
				Size = UDim2.fromOffset(w, math.floor(w * rng:NextNumber(0.4, 1))),
				BackgroundColor3 = Color3.fromHex(CONFETTI_COLORS[rng:NextInteger(1, #CONFETTI_COLORS)]),
				BorderSizePixel = 0,
				Rotation = rng:NextNumber(0, 360),
				ZIndex = 104,
				Parent = overlay,
			})
			local burst = Vector2.new(rng:NextNumber(-1, 1) * page.X * 0.45, rng:NextNumber(-0.55, -0.15) * page.Y)
			local peak = piece.Position + UDim2.fromOffset(burst.X, burst.Y)
			local up = rng:NextNumber(0.45, 0.7)
			tween(piece, TweenInfo.new(up, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = peak, Rotation = piece.Rotation + rng:NextNumber(-180, 180) })
			task.delay(up, function()
				if piece.Parent then
					local fall = rng:NextNumber(1.6, 2.6)
					tween(piece, TweenInfo.new(fall, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
						Position = UDim2.fromOffset(peak.X.Offset + rng:NextNumber(-80, 80), page.Y + 40),
						Rotation = piece.Rotation + rng:NextNumber(-540, 540),
						BackgroundTransparency = 0.3,
					})
					task.delay(fall, function()
						piece:Destroy()
					end)
				end
			end)
		end
	end

	local function finish()
		if closed then
			return
		end
		closed = true
		pulseRunning = false
		Remotes.CompleteTutorial:FireServer()
		for _, c in connections do
			c:Disconnect()
		end
		tween(card, quick(0.3), { GroupTransparency = 1 })
		tween(ringStroke, quick(0.3), { Transparency = 1 })
		for _, d in dims do
			tween(d, quick(0.4), { BackgroundTransparency = 1 })
		end
		task.delay(0.45, function()
			overlay.Active = false
			-- Konfetti może jeszcze spadać; reszta znika od razu.
			task.delay(2.6, function()
				overlay:Destroy()
			end)
			card:Destroy()
			for _, d in dims do
				d:Destroy()
			end
			ring:Destroy()
			active = false
			if onClose then
				onClose()
			end
		end)
	end

	local showing = 0
	local function show(i: number, first: boolean)
		index = math.clamp(i, 1, #STEPS)
		showing += 1
		local token = showing
		local step = STEPS[index]
		local last = index == #STEPS

		task.spawn(function()
			-- Stara karta znika, reflektor jedzie do nowego miejsca, nowa karta wjeżdża.
			if not first then
				tween(card, quick(0.15), { GroupTransparency = 1 })
				task.wait(0.15)
				if token ~= showing or closed then
					return
				end
			end
			counter.Text = if index == 1 or last then "" else `STEP {index - 1} OF {#STEPS - 2}`
			counter.Visible = counter.Text ~= ""
			title.Text = step.Title
			body.Text = step.Body
			coinSlot.Visible = index == 1
			back.Visible = index > 1 and not last
			skip.Visible = not last
			nextButton.Text = if index == 1 then "Start tour" elseif last then "Start trading" else "Next"
			for d, dot in dots do
				tween(dot, quick(0.25), {
					Size = UDim2.fromOffset(if d == index then 18 else 6, 6),
					BackgroundColor3 = if d == index then Colors.Text elseif d < index then Colors.TextMuted else Colors.Border,
				})
			end
			if index == 1 then
				coinStarted = os.clock()
				coinHolder.Size = UDim2.fromOffset(0, 0)
				tween(coinHolder, TweenInfo.new(0.6, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(72, 72) })
			end

			local pos, size = targetRect(step)
			local page = space()
			if pos and size then
				ring.Visible = true
				tween(ringStroke, quick(0.3), { Transparency = 0 })
				placeSpotlight(pos, size, not first)
			else
				tween(ringStroke, quick(0.2), { Transparency = 1 })
				placeSpotlight(page / 2, Vector2.zero, not first)
				task.delay(0.2, function()
					if token == showing then
						ring.Visible = false
					end
				end)
			end

			-- Rozmiar karty znany po przeliczeniu układu.
			RunService.Heartbeat:Wait()
			if token ~= showing or closed then
				return
			end
			local _, scale = space()
			local cardSize = card.AbsoluteSize / scale
			local at = cardPosition(pos, size, cardSize)
			local fromBelow = if pos and at.Y < pos.Y then -12 else 12
			card.Position = UDim2.fromOffset(at.X, at.Y + fromBelow)
			if not first then
				task.wait(0.2)
				if token ~= showing or closed then
					return
				end
			end
			tween(card, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				GroupTransparency = 0,
				Position = UDim2.fromOffset(at.X, at.Y),
			})
			if last then
				confetti()
			end
		end)
	end

	local function nextStep()
		if index >= #STEPS then
			finish()
		else
			show(index + 1, false)
		end
	end
	local function previous()
		if index > 1 then
			show(index - 1, false)
		end
	end

	table.insert(connections, nextButton.Activated:Connect(nextStep))
	table.insert(connections, back.Activated:Connect(previous))
	table.insert(connections, skip.Activated:Connect(finish))
	table.insert(connections, UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		local key = input.KeyCode
		if key == Enum.KeyCode.Right or key == Enum.KeyCode.Return or key == Enum.KeyCode.Space then
			nextStep()
		elseif key == Enum.KeyCode.Left then
			previous()
		elseif key == Enum.KeyCode.Escape then
			finish()
		end
	end))
	-- Zmiana rozmiaru okna: reflektor i karta wracają na miejsce.
	table.insert(connections, root:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		show(index, true)
	end))

	-- Start: przyciemnienie, potem pierwszy ekran.
	placeSpotlight(space() / 2, Vector2.zero, false)
	ring.Visible = false
	for _, d in dims do
		tween(d, quick(0.5), { BackgroundTransparency = DIM })
	end
	show(1, true)
end

return Tutorial
