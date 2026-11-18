--!strict
-- Baner alertu cenowego: wjeżdża z góry ekranu z dźwiękiem i bujającym się dzwonkiem, niezależnie
-- od otwartej zakładki. Kliknięcie otwiera coina; po kilku sekundach baner sam odjeżdża.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Types = require(ReplicatedStorage.Shared.Types)

local Alerts = require(script.Parent.Parent.State.Alerts)
local Icons = require(script.Parent.Icons)
local Theme = require(script.Parent.Theme)
local Util = require(script.Parent.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local WIDTH = 440
local LIFETIME = 7
local MAX_VISIBLE = 3
-- Dźwięk wbudowany w Roblox (bez wgrywania).
local SOUND_ID = "rbxasset://sounds/electronicpingshort.wav"

local AlertBanner = {}

local container: Frame? = nil
local sound: Sound? = nil
local order = 0

local function tween(instance: Instance, seconds: number, props: { [string]: any }, style: Enum.EasingStyle?, direction: Enum.EasingDirection?)
	TweenService:Create(instance, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), props):Play()
end

function AlertBanner.mount(parent: Instance)
	container = create("Frame", {
		Name = "AlertBanners",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.fromOffset(WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 90,
		Parent = parent,
	}, { Util.vlist(8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top) })
	sound = create("Sound", { Name = "AlertSound", SoundId = SOUND_ID, Volume = 0.7, Parent = SoundService })
end

type Banner = { Ticker: string, Title: string, Text: string, Accent: Color3, Action: string }

local function present(info: Banner, onOpen: (ticker: string) -> ())
	local parent = container
	if not parent then
		return
	end
	if sound then
		SoundService:PlayLocalSound(sound)
	end
	order += 1
	local accent = info.Accent

	-- Zewnętrzna ramka trzyma miejsce w liście; karta w środku wjeżdża z góry.
	local slot: Frame = create("Frame", {
		Name = "Alert",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(WIDTH, 0),
		ClipsDescendants = false,
		LayoutOrder = order,
		ZIndex = 90,
		Parent = parent,
	})
	local card: CanvasGroup = create("CanvasGroup", {
		Name = "Card",
		Position = UDim2.fromOffset(0, -90),
		Size = UDim2.fromOffset(WIDTH, 72),
		BackgroundColor3 = Colors.Elevated,
		GroupTransparency = 1,
		ZIndex = 90,
		Parent = slot,
	}, {
		Util.corner(14),
		create("UIStroke", {
			Color = accent,
			Transparency = 0.3,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			BorderStrokePosition = Enum.BorderStrokePosition.Inner,
		}),
	})
	local button: TextButton = create("TextButton", {
		Name = "Open",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.fromScale(1, 1),
		Parent = card,
	})

	local bellHolder: Frame = create("Frame", {
		Name = "Bell",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 16, 0.5, 0),
		Size = UDim2.fromOffset(40, 40),
		BackgroundColor3 = accent,
		BackgroundTransparency = 0.82,
		Parent = card,
	}, { Util.round() })
	local bell = Icons.bell(22, accent, true)
	bell.AnchorPoint = Vector2.new(0.5, 0.5)
	bell.Position = UDim2.fromScale(0.5, 0.5)
	bell.Parent = bellHolder

	local def = Coins.get(info.Ticker)
	local title = Util.group("Title", 0, Util.hlist(8))
	title.Position = UDim2.fromOffset(70, 14)
	title.Parent = card
	if def then
		Icons.token(def.Color, def.Ticker, 18, 1, true).Parent = title
	end
	Util.text({ Text = info.Title, Size = 17, Font = Fonts.Bold, Order = 2, Parent = title })
	Util.label({
		Text = info.Text,
		Size = 14,
		Color = Colors.TextMuted,
		Position = UDim2.fromOffset(70, 38),
		FrameSize = UDim2.new(1, -150, 0, 20),
		Parent = card,
	})
	local view = Util.text({ Text = info.Action, Size = 14, Font = Fonts.Bold, Color = accent, Parent = card })
	view.AnchorPoint = Vector2.new(1, 0.5)
	view.Position = UDim2.new(1, -18, 0.5, 0)

	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		tween(card, 0.3, { GroupTransparency = 1, Position = UDim2.fromOffset(0, -40) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tween(slot, 0.3, { Size = UDim2.fromOffset(WIDTH, 0) })
		task.delay(0.32, function()
			slot:Destroy()
		end)
	end
	button.Activated:Connect(function()
		close()
		onOpen(info.Ticker)
	end)

	-- Wjazd, potem bujanie dzwonkiem jak przy dzwonieniu.
	tween(slot, 0.35, { Size = UDim2.fromOffset(WIDTH, 72) })
	tween(card, 0.5, { GroupTransparency = 0, Position = UDim2.fromOffset(0, 0) }, Enum.EasingStyle.Back)
	task.spawn(function()
		task.wait(0.3)
		for i = 1, 6 do
			if closed then
				return
			end
			local angle = (if i % 2 == 1 then 22 else -22) * (1 - i / 7)
			tween(bell, 0.09, { Rotation = angle }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
			task.wait(0.09)
		end
		tween(bell, 0.1, { Rotation = 0 })
	end)
	task.delay(LIFETIME, close)

	local banners = {}
	for _, child in parent:GetChildren() do
		if child:IsA("Frame") and child.Name == "Alert" then
			table.insert(banners, child)
		end
	end
	table.sort(banners, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i = 1, #banners - MAX_VISIBLE do
		banners[i]:Destroy()
	end
end


function AlertBanner.show(notice: Types.AlertNotice, onOpen: (ticker: string) -> ())
	local rising = notice.Kind == "Above" or notice.Kind == "Rise"
	present({
		Ticker = notice.Ticker,
		Title = `{notice.Ticker} alert`,
		Text = Alerts.noticeText(notice),
		Accent = if rising then Colors.Green else Colors.Red,
		Action = "View",
	}, onOpen)
end

-- Pulse Radar: nowy coin na Pulse; kliknięcie otwiera coina, żeby kupić przed snajperami.
function AlertBanner.showRadar(ticker: string, name: string, creator: string, onOpen: (ticker: string) -> ())
	present({
		Ticker = ticker,
		Title = `New on Pulse: {ticker}`,
		Text = `{name} by {creator}. Snipers incoming!`,
		Accent = Colors.Yellow,
		Action = "Buy",
	}, onOpen)
end

return AlertBanner
