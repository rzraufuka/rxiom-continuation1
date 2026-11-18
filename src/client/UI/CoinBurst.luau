--!strict
-- Animacja przelewu: czarne tło, na środku kręcąca się moneta RXI (wgrana grafika) z falami
-- i iskrami, a pod nią licznik kwoty i informacja, do kogo / od kogo.

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Format = require(game:GetService("ReplicatedStorage").Shared.Format)

local Theme = require(script.Parent.Theme)
local Util = require(script.Parent.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local COIN_SIZE = 220
local AUTO_CLOSE = 6
local SPARKS = 16

export type Options = {
	Title: string,
	Amount: number,
	Line: string,
	-- Po zamknięciu przez gracza albo automatycznie (nie gdy zastąpi ją inna animacja).
	OnClosed: (() -> ())?,
}

local CoinBurst = {}

-- Zamyka bieżącą animację bez OnClosed (gdy zastępuje ją nowa).
local current: (() -> ())? = nil

local function tween(instance: Instance, seconds: number, props: { [string]: any }, style: Enum.EasingStyle?, direction: Enum.EasingDirection?, delay: number?)
	local info = TweenInfo.new(seconds, style or Enum.EasingStyle.Quint, direction or Enum.EasingDirection.Out, 0, false, delay or 0)
	TweenService:Create(instance, info, props):Play()
end

-- Moneta z wgranej grafiki przycięta do `Crop`. Przycięcie robi ramka z ClipsDescendants i powiększony
-- obrazek w środku (w Scale), więc działa przy każdej rozdzielczości, do jakiej Roblox zeskalował plik,
-- i ściska się razem z ramką przy obrocie.
local function coinImage(): Frame
	local spec = Theme.CoinImage
	local frame: Frame = create("Frame", {
		Name = "Coin",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
	})
	local crop, size = spec.Crop, spec.Size
	create("ImageLabel", {
		Name = "Image",
		BackgroundTransparency = 1,
		Image = "rbxassetid://" .. spec.Id,
		Position = UDim2.fromScale(-crop.Min.X / crop.Width, -crop.Min.Y / crop.Height),
		Size = UDim2.fromScale(size.X / crop.Width, size.Y / crop.Height),
		Parent = frame,
	})
	return frame
end

-- Pokazuje animację nad `parent` (cała jego powierzchnia). Poprzednia animacja jest zamykana.
function CoinBurst.play(parent: GuiObject, options: Options)
	if current then
		current()
	end

	-- Czarne, a nie półprzezroczyste tło: grafika monety ma czarne tło, które wtedy znika.
	local overlay: TextButton = create("TextButton", {
		Name = "CoinBurst",
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1,
		ZIndex = 60,
		Parent = parent,
	})
	local content: CanvasGroup = create("CanvasGroup", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		GroupTransparency = 1,
		Parent = overlay,
	})

	-- Fale rozchodzące się od monety
	local stage = create("Frame", {
		Name = "Stage",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.5, -70),
		Size = UDim2.fromOffset(COIN_SIZE, COIN_SIZE),
		BackgroundTransparency = 1,
		Parent = content,
	})
	-- Fale i iskry startują poza kwadratem grafiki (jego przekątna to ~1.42 boku), bo czarne rogi
	-- grafiki zasłoniłyby wszystko, co przechodzi za monetą.
	local function wave(delay: number)
		local ring: Frame = create("Frame", {
			Name = "Wave",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1.45, 1.45),
			BackgroundTransparency = 1,
			Parent = stage,
		}, { Util.round() })
		local stroke: UIStroke = create("UIStroke", {
			Color = Colors.Text,
			Thickness = 2,
			Transparency = 1,
			Parent = ring,
		})
		task.delay(delay, function()
			if not ring.Parent then
				return
			end
			stroke.Transparency = 0.25
			tween(ring, 1.4, { Size = UDim2.fromScale(3.2, 3.2) }, Enum.EasingStyle.Quart)
			tween(stroke, 1.4, { Transparency = 1, Thickness = 0.5 }, Enum.EasingStyle.Quad)
		end)
	end
	for i = 0, 2 do
		wave(0.25 + i * 0.35)
	end

	-- Moneta: wyskakuje z zera, potem obraca się wokół pionowej osi (ściskanie szerokości).
	local holder: Frame = create("Frame", {
		Name = "CoinHolder",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		ZIndex = 2,
		Parent = stage,
	})
	local spinner: Frame = create("Frame", {
		Name = "Spinner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = holder,
	})
	coinImage().Parent = spinner
	tween(holder, 0.7, { Size = UDim2.fromOffset(COIN_SIZE, COIN_SIZE) }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.1)

	-- Iskry wylatujące z monety
	local rng = Random.new()
	for i = 1, SPARKS do
		local angle = (i / SPARKS) * math.pi * 2 + rng:NextNumber(-0.2, 0.2)
		local start = COIN_SIZE * 0.74
		local distance = start + rng:NextNumber(90, 200)
		local size = rng:NextInteger(4, 9)
		local spark: Frame = create("Frame", {
			Name = "Spark",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, math.cos(angle) * start, 0.5, math.sin(angle) * start),
			Size = UDim2.fromOffset(size, size),
			BackgroundColor3 = if i % 3 == 0 then Color3.fromHex("BDBDBD") else Colors.Text,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = stage,
		}, { Util.round() })
		local delay = 0.35 + rng:NextNumber(0, 0.25)
		task.delay(delay, function()
			if not spark.Parent then
				return
			end
			spark.BackgroundTransparency = 0
			tween(spark, 1.1, {
				Position = UDim2.new(0.5, math.cos(angle) * distance, 0.5, math.sin(angle) * distance),
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(2, 2),
			}, Enum.EasingStyle.Quart)
		end)
	end

	-- Napisy pod monetą
	local texts = create("Frame", {
		Name = "Texts",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, COIN_SIZE / 2 - 30),
		Size = UDim2.fromOffset(700, 200),
		BackgroundTransparency = 1,
		Parent = content,
	}, { Util.vlist(8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top) })
	local function line(text: string, size: number, font: Font, color: Color3, order: number): TextLabel
		local label = Util.text({ Text = text, Size = size, Font = font, Color = color, Order = order, Parent = texts })
		label.TextTransparency = 1
		return label
	end
	local title = line(string.upper(options.Title), 15, Fonts.SemiBold, Colors.TextMuted, 1)
	local amount = line("0 " .. Theme.Currency, 52, Fonts.Bold, Colors.Text, 2)
	local detail = line(options.Line, 19, Fonts.Medium, Colors.TextMuted, 3)
	local done: TextButton = create("TextButton", {
		Name = "Done",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(150, 44),
		BackgroundColor3 = Colors.Primary,
		BackgroundTransparency = 1,
		Text = "Done",
		TextSize = 16,
		FontFace = Fonts.Bold,
		TextColor3 = Colors.OnPrimary,
		TextTransparency = 1,
		LayoutOrder = 5,
		Parent = texts,
	}, { Util.round() })
	create("Frame", { Name = "Spacer", BackgroundTransparency = 1, Size = UDim2.fromOffset(1, 10), LayoutOrder = 4, Parent = texts })
	for i, label in { title, amount, detail } do
		tween(label, 0.5, { TextTransparency = 0 }, Enum.EasingStyle.Quad, nil, 0.45 + i * 0.12)
	end
	tween(done, 0.4, { BackgroundTransparency = 0, TextTransparency = 0 }, Enum.EasingStyle.Quad, nil, 1.1)

	tween(overlay, 0.35, { BackgroundTransparency = 0 }, Enum.EasingStyle.Quad)
	tween(content, 0.35, { GroupTransparency = 0 }, Enum.EasingStyle.Quad)

	-- Obrót: szybki na starcie, potem zwalnia do spokojnego tempa. Kwota liczy się od zera.
	local started = os.clock()
	local angle = 0
	local closed = false
	local connection = RunService.RenderStepped:Connect(function(dt: number)
		local t = os.clock() - started
		local speed = 4 + 16 * math.exp(-t * 2.2)
		angle += speed * dt
		local width = math.abs(math.cos(angle))
		spinner.Size = UDim2.fromScale(math.max(0.04, width), 1)
		spinner.Position = UDim2.new(0.5, 0, 0.5, math.sin(t * 2.4) * 6)
		local progress = math.clamp((t - 0.5) / 0.9, 0, 1)
		local eased = 1 - (1 - progress) ^ 3
		amount.Text = Format.decimal(options.Amount * eased) .. " " .. Theme.Currency
	end)

	local function close()
		if closed then
			return
		end
		closed = true
		if current == close then
			current = nil
		end
		tween(overlay, 0.3, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
		tween(content, 0.3, { GroupTransparency = 1 }, Enum.EasingStyle.Quad)
		task.delay(0.35, function()
			connection:Disconnect()
			overlay:Destroy()
		end)
	end
	current = close
	-- Zamknięcie przez gracza albo czas: dopiero wtedy OnClosed, gdy ta animacja już zniknie.
	local function dismiss()
		if closed then
			return
		end
		close()
		if options.OnClosed then
			task.delay(0.35, options.OnClosed)
		end
	end
	overlay.Activated:Connect(dismiss)
	done.Activated:Connect(dismiss)
	task.delay(AUTO_CLOSE, dismiss)
end

return CoinBurst
