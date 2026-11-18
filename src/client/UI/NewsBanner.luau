--!strict
-- Breaking News: wide banner dropping from behind the top edge of the site, which after a few
-- seconds morphs into a compact pill under the top bar and, once the news resolves, back into a
-- result banner. One card is reused for every state, so the morphs are plain Size/Position tweens.
-- No CanvasGroup anywhere: it would resample the text.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Types = require(ReplicatedStorage.Shared.Types)

local Market = require(script.Parent.Parent.State.Market)
local AlertBanner = require(script.Parent.AlertBanner)
local Icons = require(script.Parent.Icons)
local TopBar = require(script.Parent.MainMenu.TopBar)
local Theme = require(script.Parent.Theme)
local Util = require(script.Parent.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local FULL_W = 560
local FULL_H = 88
local FULL_Y = 12
local PILL_W = 300
local PILL_H = 36
local PILL_Y = TopBar.Height + 8
local FULL_TIME = 10
local RESULT_TIME = 7
local SOUND_ID = "rbxasset://sounds/electronicpingshort.wav"

-- Content columns of the full banner.
local TEXT_X = 72
local TRADE_W = 64
local BELL_SIZE = 32
local TEXT_W = FULL_W - 16 - TRADE_W - 8 - BELL_SIZE - 12 - TEXT_X

export type Actions = {
	OpenCoin: (ticker: string) -> (),
	OpenAlert: (ticker: string) -> (),
}

type Mode = "hidden" | "full" | "pill" | "result"

local NewsBanner = {}

local mounted = false
local actions: Actions
local holder: Frame
local card: Frame
local pop: UIScale
local corner: UICorner
local stroke: UIStroke
local sweep: UIGradient
local sound: Sound
local fullContent: Frame
local compactContent: Frame
local tag: Frame
local tagDot: Frame
local tagText: TextLabel
local headline: TextLabel
local subline: TextLabel
local barFill: Frame
local bell: TextButton
local tokenSlot: Frame
local pillRow: Frame
local pillDot: Frame
local pillTicker: TextLabel
local pillTime: TextLabel
local fullToken: Frame? = nil
local pillToken: Frame? = nil

local current: Types.NewsEvent? = nil
local mode: Mode = "hidden"
local lastAnnouncedId = -math.huge
local lastResolvedId = -math.huge
local generation = 0
local fullElapsed = 0
local resultElapsed = 0
local heartbeat: RBXScriptConnection? = nil
local loops: { Tween } = {}
local suppressed: () -> boolean = function()
	return false
end

local function tween(
	instance: Instance,
	seconds: number,
	props: { [string]: any },
	style: Enum.EasingStyle?,
	direction: Enum.EasingDirection?
): Tween
	local t =
		TweenService:Create(instance, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

-- Runs `fn` unless another transition has started in the meantime.
local function later(seconds: number, fn: () -> ())
	local expected = generation
	task.delay(seconds, function()
		if expected == generation then
			fn()
		end
	end)
end

local function clock(seconds: number): string
	local total = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", total // 60, total % 60)
end

local function setText(target: TextLabel, text: string)
	if target.Text ~= text then
		target.Text = text
	end
end

local function ping(speed: number)
	sound.PlaybackSpeed = speed
	SoundService:PlayLocalSound(sound)
end

local function startLoops()
	for _, loop in loops do
		loop:Play()
	end
end

local function stopLoops()
	for _, loop in loops do
		loop:Cancel()
	end
	tagDot.BackgroundTransparency = 0
	pillDot.BackgroundTransparency = 0
end

local function pointerOverCard(): boolean
	local pointer = UserInputService:GetMouseLocation()
	local position = card.AbsolutePosition
	local size = card.AbsoluteSize
	return pointer.X >= position.X
		and pointer.X <= position.X + size.X
		and pointer.Y >= position.Y
		and pointer.Y <= position.Y + size.Y
end

local function fullTopOffset(): number
	return FULL_Y + FULL_H + 8
end

local function pillTopOffset(): number
	return PILL_Y + PILL_H + 8
end

-- Fills in the text and colours for the event; `result` selects the closing banner.
local function populate(event: Types.NewsEvent, result: boolean)
	local def = Coins.get(event.Ticker)
	local coinColor = if def then def.Color else Colors.TextMuted
	local accent = if event.Direction > 0 then Colors.Green else Colors.Red
	if result then
		local change = event.Change or 0
		accent = if change >= 0 then Colors.Green else Colors.Red
		local happened = event.Happened == true
		local verdict = if event.Source == "Rumor"
			then (if happened then "Rumor turned out true" else "Rumor turned out false")
			else (if happened then "News played out" else "News fizzled")
		tag.BackgroundColor3 = accent
		tagText.TextColor3 = Colors.OnPrimary
		tagText.Text = "RESULT"
		tagDot.Visible = false
		headline.Text = event.Result or event.Headline
		subline.Text = `{string.format("%+.1f", change)}% since the news · {verdict}`
	else
		tag.BackgroundColor3 = Colors.Red
		tagText.TextColor3 = Colors.Text
		tagText.Text = "BREAKING"
		tagDot.Visible = true
		headline.Text = event.Headline
		subline.Text = ""
	end
	bell.Visible = not result
	stroke.Color = accent
	barFill.BackgroundColor3 = accent
	pillTicker.Text = event.Ticker

	if fullToken then
		fullToken:Destroy()
	end
	local big = Icons.token(coinColor, event.Ticker, 44, 0, true)
	big.Parent = tokenSlot
	fullToken = big
	if pillToken then
		pillToken:Destroy()
	end
	local small = Icons.token(coinColor, event.Ticker, 16, 3, true)
	small.Parent = pillRow
	pillToken = small
end

-- Types the headline out by tweening how many graphemes are visible.
local function typeHeadline(delay: number)
	local count = utf8.len(headline.Text) or #headline.Text
	headline.MaxVisibleGraphemes = 0
	later(delay, function()
		tween(headline, 0.6, { MaxVisibleGraphemes = count }, Enum.EasingStyle.Linear)
	end)
end

local function popToken()
	local token = fullToken
	if not token then
		return
	end
	local scale: UIScale = create("UIScale", { Scale = 0.5, Parent = token })
	later(0.25, function()
		tween(scale, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
	end)
end

-- Per-frame refresh of countdowns and the progress bar of the current phase.
local function refresh()
	local event = current
	if not event then
		return
	end
	if mode == "result" then
		barFill.Size = UDim2.fromScale(math.clamp(1 - resultElapsed / RESULT_TIME, 0, 1), 1)
		return
	end
	local now = Market.now()
	local fraction: number
	local fullText: string
	local pillText: string
	if now < event.StartsAt then
		fraction = (event.StartsAt - now) / math.max(1, event.StartsAt - event.AnnouncedAt)
		fullText = `{event.Source} · move expected in {clock(event.StartsAt - now)}`
		pillText = clock(event.StartsAt - now)
	elseif now < event.EndsAt then
		fraction = (event.EndsAt - now) / math.max(1, event.EndsAt - event.StartsAt)
		fullText = `{event.Source} · happening now · {clock(event.EndsAt - now)} left`
		pillText = `LIVE {clock(event.EndsAt - now)}`
	else
		fraction = 0
		fullText = `{event.Source} · settling...`
		pillText = "SETTLING"
	end
	barFill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
	setText(subline, fullText)
	setText(pillTime, pillText)
end

local function stopTick()
	if heartbeat then
		heartbeat:Disconnect()
		heartbeat = nil
	end
end

local morphToPill: () -> ()
local exit: () -> ()

local function onFrame(dt: number)
	if not current then
		stopTick()
		return
	end
	if mode == "full" then
		if not pointerOverCard() then
			fullElapsed += dt
			if fullElapsed >= FULL_TIME then
				morphToPill()
			end
		end
	elseif mode == "result" then
		if not pointerOverCard() then
			resultElapsed += dt
			if resultElapsed >= RESULT_TIME then
				exit()
				return
			end
		end
	end
	refresh()
end

local function startTick()
	if not heartbeat then
		heartbeat = RunService.Heartbeat:Connect(onFrame)
	end
end

local function setFullLook()
	card.Size = UDim2.fromOffset(FULL_W, FULL_H)
	corner.CornerRadius = UDim.new(0, 16)
	stroke.Thickness = 1.5
end

-- Drops the full banner in from behind the top edge of the site.
local function enterFull(result: boolean)
	generation += 1
	populate(current :: Types.NewsEvent, result)
	card.Visible = true
	setFullLook()
	fullContent.Visible = true
	compactContent.Visible = false
	card.Position = UDim2.new(0.5, 0, 0, -FULL_H - 16)
	pop.Scale = 0.96
	tween(card, 0.55, { Position = UDim2.new(0.5, 0, 0, FULL_Y) }, Enum.EasingStyle.Back)
	tween(pop, 0.55, { Scale = 1 })
	ping(if result then 1.15 else 0.85)
	typeHeadline(0.4)
	popToken()
	refresh()
	startLoops()
	startTick()
	AlertBanner.setTopOffset(fullTopOffset())
end

-- Grows the pill (or the already full card) into the result banner.
local function morphToResult()
	generation += 1
	populate(current :: Types.NewsEvent, true)
	fullContent.Visible = false
	compactContent.Visible = false
	tween(card, 0.4, { Size = UDim2.fromOffset(FULL_W, FULL_H), Position = UDim2.new(0.5, 0, 0, FULL_Y) }, Enum.EasingStyle.Quint)
	tween(corner, 0.4, { CornerRadius = UDim.new(0, 16) }, Enum.EasingStyle.Quint)
	tween(stroke, 0.4, { Thickness = 1.5 })
	tween(pop, 0.4, { Scale = 1 })
	AlertBanner.setTopOffset(fullTopOffset())
	ping(1.15)
	refresh()
	startLoops()
	startTick()
	later(0.22, function()
		fullContent.Visible = true
		typeHeadline(0)
		popToken()
	end)
end

local function enterPill()
	generation += 1
	populate(current :: Types.NewsEvent, false)
	card.Visible = true
	card.Size = UDim2.fromOffset(PILL_W, PILL_H)
	corner.CornerRadius = UDim.new(0, PILL_H // 2)
	stroke.Thickness = 1
	fullContent.Visible = false
	compactContent.Visible = true
	pop.Scale = 1
	card.Position = UDim2.new(0.5, 0, 0, -PILL_H - 16)
	tween(card, 0.45, { Position = UDim2.new(0.5, 0, 0, PILL_Y) }, Enum.EasingStyle.Back)
	refresh()
	startLoops()
	startTick()
	AlertBanner.setTopOffset(pillTopOffset())
end

function morphToPill()
	mode = "pill"
	generation += 1
	fullContent.Visible = false
	compactContent.Visible = false
	tween(card, 0.35, { Size = UDim2.fromOffset(PILL_W, PILL_H), Position = UDim2.new(0.5, 0, 0, PILL_Y) }, Enum.EasingStyle.Quint)
	tween(corner, 0.35, { CornerRadius = UDim.new(0, PILL_H // 2) }, Enum.EasingStyle.Quint)
	tween(stroke, 0.35, { Thickness = 1 })
	tween(pop, 0.35, { Scale = 1 })
	AlertBanner.setTopOffset(pillTopOffset())
	refresh()
	later(0.28, function()
		compactContent.Visible = true
	end)
end

-- Slides the card back up behind the top edge. `keepEvent` keeps the event for a later result.
local function slideOut(keepEvent: boolean)
	generation += 1
	local height = card.Size.Y.Offset
	mode = "hidden"
	tween(card, 0.35, { Position = UDim2.new(0.5, 0, 0, -height - 16) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	AlertBanner.setTopOffset(FULL_Y)
	stopTick()
	if not keepEvent then
		current = nil
	end
	later(0.37, function()
		card.Visible = false
		stopLoops()
	end)
end

function exit()
	slideOut(false)
end

local function openCoin()
	local event = current
	if not event then
		return
	end
	actions.OpenCoin(event.Ticker)
	if mode == "full" then
		morphToPill()
	elseif mode == "result" then
		exit()
	end
end

local function dismissPill()
	slideOut(true)
end

local function onAnnounce(event: Types.NewsEvent)
	if event.Id <= lastAnnouncedId then
		return
	end
	lastAnnouncedId = event.Id
	current = event
	fullElapsed = 0
	if suppressed() then
		mode = "pill"
		enterPill()
	else
		mode = "full"
		enterFull(false)
	end
end

local function onResolve(event: Types.NewsEvent)
	if event.Id <= lastResolvedId then
		return
	end
	local open = current
	if open and event.Id < open.Id then
		return
	end
	lastResolvedId = event.Id
	lastAnnouncedId = math.max(lastAnnouncedId, event.Id)
	if suppressed() then
		if mode ~= "hidden" then
			exit()
		end
		current = nil
		return
	end
	current = event
	resultElapsed = 0
	if mode == "hidden" then
		mode = "result"
		enterFull(true)
	else
		mode = "result"
		morphToResult()
	end
end

function NewsBanner.show(event: Types.NewsEvent)
	if not mounted then
		return
	end
	if event.Resolved then
		onResolve(event)
	else
		onAnnounce(event)
	end
end

-- The big pop is skipped (pill only, no sound) while this returns true.
function NewsBanner.setSuppressed(fn: () -> boolean)
	suppressed = fn
end

local function button(name: string, props: { [string]: any }, children: { any }?): TextButton
	local base: { [string]: any } = {
		Name = name,
		AutoButtonColor = false,
		Text = "",
		BorderSizePixel = 0,
	}
	for key, value in props do
		base[key] = value
	end
	return create("TextButton", base, children)
end

local function buildFull()
	fullContent = create("Frame", {
		Name = "Full",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = card,
	})

	tokenSlot = create("Frame", {
		Name = "Coin",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(16, 18),
		Size = UDim2.fromOffset(44, 44),
		Parent = fullContent,
	})

	tag = create("Frame", {
		Name = "Tag",
		Position = UDim2.fromOffset(TEXT_X, 11),
		Size = UDim2.fromOffset(0, 18),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Colors.Red,
		BorderSizePixel = 0,
		Parent = fullContent,
	}, { Util.round(), Util.hlist(5), Util.padding(0, 8, 0, 8) })
	tagDot = Icons.dot(6, Colors.Text, 1)
	tagDot.Parent = tag
	tagText = Util.text({ Text = "BREAKING", Size = 11, Font = Fonts.Bold, Order = 2, Parent = tag })

	headline = Util.label({
		Name = "Headline",
		Text = "",
		Size = 16,
		Font = Fonts.Bold,
		Position = UDim2.fromOffset(TEXT_X, 33),
		FrameSize = UDim2.fromOffset(TEXT_W, 22),
		Parent = fullContent,
	})
	subline = Util.label({
		Name = "Subline",
		Text = "",
		Size = 13,
		Color = Colors.TextMuted,
		Position = UDim2.fromOffset(TEXT_X, 56),
		FrameSize = UDim2.fromOffset(TEXT_W, 16),
		Parent = fullContent,
	})

	local track: Frame = create("Frame", {
		Name = "ProgressTrack",
		Position = UDim2.new(0, 16, 1, -7),
		Size = UDim2.new(1, -32, 0, 2),
		BackgroundColor3 = Colors.Border,
		BorderSizePixel = 0,
		Parent = fullContent,
	}, { Util.round() })
	barFill = create("Frame", {
		Name = "ProgressFill",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Colors.Green,
		BorderSizePixel = 0,
		Parent = track,
	}, { Util.round() })

	local trade = button("Trade", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16, 0.5, -2),
		Size = UDim2.fromOffset(TRADE_W, 32),
		BackgroundColor3 = Colors.Primary,
		Text = "Trade",
		TextSize = 14,
		FontFace = Fonts.Bold,
		TextColor3 = Colors.OnPrimary,
		Parent = fullContent,
	}, { Util.round() })
	Util.hoverBackground(trade, Colors.Primary, Colors.PrimaryHover)
	trade.Activated:Connect(openCoin)

	bell = button("Bell", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16 - TRADE_W - 8, 0.5, -2),
		Size = UDim2.fromOffset(BELL_SIZE, BELL_SIZE),
		BackgroundColor3 = Colors.Surface,
		Parent = fullContent,
	}, { Util.round(), Util.stroke(Colors.Border, 1) })
	Util.hoverBackground(bell, Colors.Surface, Colors.Border)
	local bellIcon = Icons.bell(16, Colors.Text, false)
	bellIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	bellIcon.Position = UDim2.fromScale(0.5, 0.5)
	bellIcon.Parent = bell
	bell.Activated:Connect(function()
		local event = current
		if event then
			actions.OpenAlert(event.Ticker)
		end
	end)
end

local function buildCompact()
	compactContent = create("Frame", {
		Name = "Compact",
		BackgroundTransparency = 1,
		Visible = false,
		Size = UDim2.fromScale(1, 1),
		Parent = card,
	})
	pillRow = create("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 14, 0.5, 0),
		Size = UDim2.new(1, -48, 1, 0),
		Parent = compactContent,
	}, { Util.hlist(7) })
	pillDot = Icons.dot(8, Colors.Red, 1)
	pillDot.Parent = pillRow
	Util.text({ Text = "BREAKING", Size = 11, Font = Fonts.Bold, Color = Colors.Red, Order = 2, Parent = pillRow })
	pillTicker = Util.text({ Text = "", Size = 13, Font = Fonts.Bold, Order = 4, Parent = pillRow })
	pillTime = Util.text({ Text = "", Size = 13, Color = Colors.TextMuted, Order = 5, Parent = pillRow })

	local dismiss = button("Dismiss", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(22, 22),
		BackgroundColor3 = Colors.Border,
		BackgroundTransparency = 1,
		Text = "×",
		TextSize = 18,
		FontFace = Fonts.Medium,
		TextColor3 = Colors.TextMuted,
		Parent = compactContent,
	}, { Util.round() })
	Util.hoverBackground(dismiss, Colors.Border, Colors.Border, 1)
	dismiss.Activated:Connect(dismissPill)
end

function NewsBanner.mount(parent: GuiObject, newsActions: Actions)
	if mounted then
		return
	end
	actions = newsActions
	sound = create("Sound", { Name = "NewsSound", SoundId = SOUND_ID, Volume = 0.7, Parent = SoundService })

	-- The clipping holder starts at the top edge of the site, so the card appears from under it.
	holder = create("Frame", {
		Name = "NewsBanner",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Size = UDim2.new(1, 0, 0, FULL_Y + FULL_H + 40),
		ZIndex = 95,
		Parent = parent,
	})
	corner = create("UICorner", { CornerRadius = UDim.new(0, 16) })
	pop = create("UIScale", { Scale = 1 })
	stroke = create("UIStroke", {
		Color = Colors.Green,
		Thickness = 1.5,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
	-- The bright spot slides along the border; the rest of it stays faint.
	sweep = create("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.8),
			NumberSequenceKeypoint.new(0.5, 0),
			NumberSequenceKeypoint.new(1, 0.8),
		}),
		Offset = Vector2.new(-1, 0),
		Parent = stroke,
	})
	card = create("Frame", {
		Name = "Card",
		Visible = false,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, -FULL_H - 16),
		Size = UDim2.fromOffset(FULL_W, FULL_H),
		BackgroundColor3 = Colors.Elevated,
		BorderSizePixel = 0,
		Parent = holder,
	}, { corner, pop, stroke })

	button("Body", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = card,
	}).Activated:Connect(openCoin)

	buildFull()
	buildCompact()

	local function pulse(dot: Frame): Tween
		return TweenService:Create(
			dot,
			TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ BackgroundTransparency = 0.75 }
		)
	end
	loops = {
		TweenService:Create(
			sweep,
			TweenInfo.new(2.2, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, false),
			{ Offset = Vector2.new(1, 0) }
		),
		pulse(tagDot),
		pulse(pillDot),
	}
	mounted = true
end

return NewsBanner
