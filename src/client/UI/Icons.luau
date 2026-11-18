--!strict
-- Ikony: proste kształty rysowane z ramek oraz grafiki marki (logo RXIOM i moneta RXI).

local Theme = require(script.Parent.Theme)
local Util = require(script.Parent.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local Icons = {}

local function bar(parent: Instance, center: Vector2, length: number, thickness: number, angle: number, color: Color3)
	create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset(center.X, center.Y),
		Size = UDim2.fromOffset(length, thickness),
		Rotation = angle,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = parent,
	})
end

-- Odcinek od a do b.
local function line(parent: Instance, a: Vector2, b: Vector2, thickness: number, color: Color3)
	local d = b - a
	bar(parent, (a + b) / 2, d.Magnitude + thickness * 0.5, thickness, math.deg(math.atan2(d.Y, d.X)), color)
end

local function box(name: string, size: number, order: number?): Frame
	return create("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		LayoutOrder = order or 0,
	})
end

local function outline(parent: Instance, pos: Vector2, size: Vector2, color: Color3, radius: number, thickness: number?)
	return create("Frame", {
		Position = UDim2.fromOffset(pos.X, pos.Y),
		Size = UDim2.fromOffset(size.X, size.Y),
		BackgroundTransparency = 1,
		Parent = parent,
	}, { Util.corner(radius), Util.stroke(color, thickness or 1.5) })
end

local function triangle(frame: Frame, size: number, thickness: number, color: Color3, closed: boolean)
	local h = size * math.sqrt(3) / 2
	local top = (size - h) / 2
	local left = Vector2.new(thickness / 2, top + h - thickness / 2)
	local right = Vector2.new(size - thickness / 2, top + h - thickness / 2)
	local apex = Vector2.new(size / 2, top + thickness / 2)
	line(frame, left, apex, thickness, color)
	line(frame, right, apex, thickness, color)
	if closed then
		line(frame, left, right, thickness, color)
	end
end

-- Logo RXIOM: pochylone "R" z grafiki marki, rysowane na przezroczystym tle. Kontur (w pikselach
-- grafiki 1254x1254) wypełniany poziomymi paskami, bo Roblox nie ma kształtów wektorowych.
local LOGO_BOUNDS = Rect.new(198, 368, 1047, 854)
local LOGO_OUTER = {
	Vector2.new(405, 368),
	Vector2.new(955, 368),
	Vector2.new(1000, 375),
	Vector2.new(1030, 395),
	Vector2.new(1045, 420),
	Vector2.new(1047, 445),
	Vector2.new(1040, 470),
	Vector2.new(1000, 563),
	Vector2.new(980, 595),
	Vector2.new(950, 625),
	Vector2.new(912, 648),
	Vector2.new(870, 660),
	Vector2.new(812, 663),
	Vector2.new(1000, 854),
	Vector2.new(781, 854),
	Vector2.new(617, 663),
	Vector2.new(445, 663),
	Vector2.new(378, 821),
	Vector2.new(198, 821),
}
local LOGO_HOLE = {
	Vector2.new(525, 479),
	Vector2.new(855, 479),
	Vector2.new(870, 485),
	Vector2.new(875, 497),
	Vector2.new(860, 532),
	Vector2.new(845, 548),
	Vector2.new(820, 557),
	Vector2.new(490, 557),
}

local function crossings(polygon: { Vector2 }, y: number, out: { number })
	for i, a in polygon do
		local b = polygon[i % #polygon + 1]
		if (a.Y <= y and b.Y > y) or (b.Y <= y and a.Y > y) then
			table.insert(out, a.X + (y - a.Y) / (b.Y - a.Y) * (b.X - a.X))
		end
	end
end

-- Wypełnia wielokąty (reguła parzystości, więc wielokąt w środku drugiego robi dziurę) poziomymi
-- paskami. Współrzędne w `bounds`; `color(t)` dostaje pozycję wiersza od 0 (góra) do 1 (dół).
local function fillPolygons(
	parent: GuiObject,
	polygons: { { Vector2 } },
	bounds: Rect,
	rows: number,
	color: (t: number) -> Color3,
	zIndex: number?
)
	local w, h = bounds.Width, bounds.Height
	for row = 0, rows - 1 do
		local t = (row + 0.5) / rows
		local y = bounds.Min.Y + t * h
		local xs = {}
		for _, polygon in polygons do
			crossings(polygon, y, xs)
		end
		table.sort(xs)
		for i = 1, #xs - 1, 2 do
			create("Frame", {
				Position = UDim2.fromScale((xs[i] - bounds.Min.X) / w, row / rows),
				-- +1 px wysokości, żeby między paskami nie było szpar po skalowaniu.
				Size = UDim2.new((xs[i + 1] - xs[i]) / w, 0, 1 / rows, 1),
				BackgroundColor3 = color(t),
				BorderSizePixel = 0,
				ZIndex = zIndex or 1,
				Parent = parent,
			})
		end
	end
end

Icons.LogoAspect = LOGO_BOUNDS.Width / LOGO_BOUNDS.Height

-- Rysuje wielokąty poziomymi paskami po jednym na piksel wysokości, z pozycjami w Scale, więc kształt
-- skaluje się razem z UI. Dawniej paski miały po pół piksela i +1 px zapasu: po zaokrągleniu przez
-- Robloxa nachodziły na siebie, zalewały dziurkę "R" i rozjeżdżały krawędzie. Szpary z zaokrągleń
-- łatają łączniki na styku wierszy, położone tylko tam, gdzie oba wiersze są wypełnione.
local function rasterize(
	parent: GuiObject,
	polygons: { { Vector2 } },
	bounds: Rect,
	rows: number,
	fill: Color3 | (t: number) -> Color3
)
	local spans: { { number } } = {}
	for row = 0, rows - 1 do
		local xs = {}
		for _, polygon in polygons do
			crossings(polygon, bounds.Min.Y + (row + 0.5) / rows * bounds.Height, xs)
		end
		table.sort(xs)
		for i = 1, #xs do
			xs[i] = (xs[i] - bounds.Min.X) / bounds.Width
		end
		spans[row + 1] = xs
	end

	local function strip(x0: number, x1: number, y: number)
		create("Frame", {
			Position = UDim2.fromScale(x0, y / rows),
			Size = UDim2.fromScale(x1 - x0, 1 / rows),
			-- `fill` jako funkcja: kolor zależny od wysokości (0 = góra, 1 = dół), np. gradient.
			BackgroundColor3 = if typeof(fill) == "function" then fill((y + 0.5) / rows) else fill,
			BorderSizePixel = 0,
			Parent = parent,
		})
	end

	for row = 1, rows do
		local xs, below = spans[row], spans[row + 1]
		for i = 1, #xs - 1, 2 do
			strip(xs[i], xs[i + 1], row - 1)
			if below then
				for j = 1, #below - 1, 2 do
					local x0, x1 = math.max(xs[i], below[j]), math.min(xs[i + 1], below[j + 1])
					if x1 > x0 then
						strip(x0, x1, row - 0.5)
					end
				end
			end
		end
	end
end

-- `height` to wysokość litery w pikselach; szerokość wynika z proporcji logo.
function Icons.logo(height: number, order: number?, color: Color3?): Frame
	local frame: Frame = create("Frame", {
		Name = "LogoIcon",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(math.round(height * Icons.LogoAspect), height),
		LayoutOrder = order or 0,
	})
	rasterize(frame, { LOGO_OUTER, LOGO_HOLE }, LOGO_BOUNDS, math.max(8, height), color or Colors.Text)
	return frame
end

-- Srebrna tarcza z logo RXIOM (karta doładowania portfela). Kształt w jednostkach 0..1 ramki.
local SHIELD = {
	Vector2.new(0.5, 0),
	Vector2.new(0.93, 0.13),
	Vector2.new(0.93, 0.5),
	Vector2.new(0.89, 0.66),
	Vector2.new(0.8, 0.8),
	Vector2.new(0.67, 0.91),
	Vector2.new(0.5, 1),
	Vector2.new(0.33, 0.91),
	Vector2.new(0.2, 0.8),
	Vector2.new(0.11, 0.66),
	Vector2.new(0.07, 0.5),
	Vector2.new(0.07, 0.13),
}
local UNIT = Rect.new(0, 0, 1, 1)

function Icons.shieldBadge(height: number, order: number?): Frame
	local frame: Frame = create("Frame", {
		Name = "ShieldBadge",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(math.round(height * 0.86), height),
		LayoutOrder = order or 0,
	})
	local inner = {}
	for i, p in SHIELD do
		inner[i] = Vector2.new(0.5 + (p.X - 0.5) * 0.76, 0.47 + (p.Y - 0.5) * 0.78)
	end
	local rows = math.max(24, math.ceil(height * 1.2))
	local silverTop, silverBottom = Color3.fromHex("F4F4F4"), Color3.fromHex("7A7A7A")
	local faceTop, faceBottom = Color3.fromHex("222222"), Color3.fromHex("050505")
	fillPolygons(frame, { SHIELD }, UNIT, rows, function(t)
		return silverTop:Lerp(silverBottom, t)
	end, 1)
	fillPolygons(frame, { inner }, UNIT, rows, function(t)
		return faceTop:Lerp(faceBottom, t)
	end, 2)
	local logo = Icons.logo(math.round(height * 0.24))
	logo.AnchorPoint = Vector2.new(0.5, 0.5)
	logo.Position = UDim2.fromScale(0.5, 0.46)
	logo.ZIndex = 3
	logo.Parent = frame
	return frame
end

export type Direction = "Down" | "Up" | "Left" | "Right"

function Icons.chevron(size: number, color: Color3, direction: Direction?, order: number?): Frame
	local frame = box("Chevron", size, order)
	local t = math.max(1.5, size * 0.14)
	local s = size
	local points: { Vector2 }
	local dir = direction or "Down"
	if dir == "Down" then
		points = { Vector2.new(s * 0.2, s * 0.35), Vector2.new(s * 0.5, s * 0.65), Vector2.new(s * 0.8, s * 0.35) }
	elseif dir == "Up" then
		points = { Vector2.new(s * 0.2, s * 0.65), Vector2.new(s * 0.5, s * 0.35), Vector2.new(s * 0.8, s * 0.65) }
	elseif dir == "Left" then
		points = { Vector2.new(s * 0.65, s * 0.2), Vector2.new(s * 0.35, s * 0.5), Vector2.new(s * 0.65, s * 0.8) }
	else
		points = { Vector2.new(s * 0.35, s * 0.2), Vector2.new(s * 0.65, s * 0.5), Vector2.new(s * 0.35, s * 0.8) }
	end
	line(frame, points[1], points[2], t, color)
	line(frame, points[2], points[3], t, color)
	return frame
end

function Icons.chevronDown(size: number, color: Color3, order: number?): Frame
	return Icons.chevron(size, color, "Down", order)
end

function Icons.search(size: number, color: Color3, order: number?): Frame
	local frame = box("SearchIcon", size, order)
	local r = size * 0.62
	create("Frame", {
		Size = UDim2.fromOffset(r, r),
		BackgroundTransparency = 1,
		Parent = frame,
	}, { Util.round(), Util.stroke(color, 2) })
	bar(frame, Vector2.new(size * 0.74, size * 0.74), size * 0.38, 2, 45, color)
	return frame
end

function Icons.star(size: number, color: Color3, order: number?): Frame
	local frame = box("StarIcon", size, order)
	local c = Vector2.new(size / 2, size * 0.54)
	local vertices = {}
	for i = 0, 4 do
		local rad = math.rad(i * 72 - 90)
		vertices[i] = c + Vector2.new(math.cos(rad), math.sin(rad)) * size * 0.48
	end
	-- Pentagram: każdy wierzchołek łączony z co drugim.
	for i = 0, 4 do
		line(frame, vertices[i], vertices[(i + 2) % 5], 2, color)
	end
	return frame
end

-- Moneta RXI: kontury obrysowane z grafiki marki (współrzędne 0-1). Rysowana z ramek, więc tło
-- jest przezroczyste (wgrana grafika miała czarne tło, którego Roblox nie umie wyciąć).
local COIN_OUTER = {
	Vector2.new(0.0104, 0.5000),
	Vector2.new(0.2917, 0.1458),
	Vector2.new(0.7292, 0.0521),
	Vector2.new(0.9479, 0.2500),
	Vector2.new(0.9896, 0.3958),
	Vector2.new(0.8750, 0.7292),
	Vector2.new(0.5625, 0.9479),
	Vector2.new(0.1875, 0.8958),
}
local COIN_FACE = {
	Vector2.new(0.0208, 0.4896),
	Vector2.new(0.3021, 0.1458),
	Vector2.new(0.6771, 0.0521),
	Vector2.new(0.9375, 0.2396),
	Vector2.new(0.8229, 0.6250),
	Vector2.new(0.5000, 0.8646),
	Vector2.new(0.1250, 0.8125),
	Vector2.new(0.0104, 0.5521),
}
local COIN_INNER = {
	Vector2.new(0.1042, 0.4688),
	Vector2.new(0.3333, 0.1979),
	Vector2.new(0.6354, 0.1250),
	Vector2.new(0.8438, 0.2812),
	Vector2.new(0.7292, 0.6146),
	Vector2.new(0.4688, 0.7812),
	Vector2.new(0.1875, 0.7292),
	Vector2.new(0.0938, 0.5208),
}
local COIN_SQUARE = {
	Vector2.new(0.3542, 0.2812),
	Vector2.new(0.6979, 0.3021),
	Vector2.new(0.5625, 0.6667),
	Vector2.new(0.2083, 0.6042),
}
local COIN_HOLE = {
	Vector2.new(0.4271, 0.4062),
	Vector2.new(0.5417, 0.4271),
	Vector2.new(0.5000, 0.5104),
	Vector2.new(0.3958, 0.5000),
}
local COIN_LAYERS: { { Polygons: { { Vector2 } }, Fill: Color3 | (t: number) -> Color3 } } = {
	-- Bok monety (widoczny pod frontem po prawej i u dołu).
	{
		Polygons = { COIN_OUTER },
		Fill = function(t: number): Color3
			return Color3.fromHex("C9C9C9"):Lerp(Color3.fromHex("6E6E6E"), t)
		end,
	},
	{
		Polygons = { COIN_FACE },
		Fill = function(t: number): Color3
			return Color3.fromHex("FFFFFF"):Lerp(Color3.fromHex("D0D0D0"), t)
		end,
	},
	{ Polygons = { COIN_INNER }, Fill = Color3.fromHex("0A0A0A") },
	-- Kwadrat z dziurą (reguła parzystości).
	{ Polygons = { COIN_SQUARE, COIN_HOLE }, Fill = Color3.fromHex("F2F2F2") },
}
local COIN_UNIT = Rect.new(0, 0, 1, 1)
-- Gotowe monety w danym rozmiarze, klonowane zamiast rysowania od nowa (każda to ~100 ramek).
local coinTemplates: { [number]: Frame } = {}

-- Ikona waluty RXI.
function Icons.currency(size: number, order: number?): Frame
	local template = coinTemplates[size]
	if not template then
		template = box("CurrencyIcon", size)
		local rows = math.max(10, math.ceil(size))
		for i, layer in COIN_LAYERS do
			local container: Frame = create("Frame", {
				Name = "Layer" .. i,
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 1),
				ZIndex = i,
				Parent = template,
			})
			rasterize(container, layer.Polygons, COIN_UNIT, rows, layer.Fill)
		end
		coinTemplates[size] = template
	end
	local icon = template:Clone()
	icon.LayoutOrder = order or 0
	return icon
end

function Icons.dot(size: number, color: Color3, order: number?): Frame
	return create("Frame", {
		Name = "Dot",
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		LayoutOrder = order or 0,
	}, { Util.round() })
end

-- Kółko ze znakiem zapytania.
function Icons.help(size: number, color: Color3, order: number?): Frame
	local frame = box("HelpIcon", size, order)
	outline(frame, Vector2.zero, Vector2.new(size, size), color, size, 1.5)
	create("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = "?",
		TextSize = size * 0.7,
		FontFace = Fonts.Bold,
		TextColor3 = color,
		Parent = frame,
	})
	return frame
end

function Icons.wallet(size: number, color: Color3, order: number?): Frame
	local frame = box("WalletIcon", size, order)
	outline(frame, Vector2.new(0, size * 0.18), Vector2.new(size, size * 0.72), color, 3)
	outline(frame, Vector2.new(size * 0.55, size * 0.4), Vector2.new(size * 0.45, size * 0.28), color, 2)
	return frame
end

function Icons.pencil(size: number, color: Color3, order: number?): Frame
	local frame = box("PencilIcon", size, order)
	line(frame, Vector2.new(size * 0.2, size * 0.75), Vector2.new(size * 0.8, size * 0.15), 2, color)
	line(frame, Vector2.new(size * 0.1, size * 0.95), Vector2.new(size * 0.95, size * 0.95), 1.5, color)
	return frame
end

-- Dystrybutor paliwa (priority fee).
function Icons.gas(size: number, color: Color3, order: number?): Frame
	local frame = box("GasIcon", size, order)
	outline(frame, Vector2.new(size * 0.1, size * 0.1), Vector2.new(size * 0.5, size * 0.85), color, 2)
	line(frame, Vector2.new(size * 0.6, size * 0.3), Vector2.new(size * 0.85, size * 0.45), 1.5, color)
	line(frame, Vector2.new(size * 0.85, size * 0.45), Vector2.new(size * 0.85, size * 0.85), 1.5, color)
	return frame
end

-- Moneta (tip).
function Icons.coin(size: number, color: Color3, order: number?): Frame
	local frame = box("CoinIcon", size, order)
	create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size, size * 0.62),
		BackgroundTransparency = 1,
		Parent = frame,
	}, { Util.round(), Util.stroke(color, 1.5) })
	return frame
end

function Icons.warning(size: number, color: Color3, order: number?): Frame
	local frame = box("WarningIcon", size, order)
	triangle(frame, size, 1.5, color, true)
	bar(frame, Vector2.new(size / 2, size * 0.55), size * 0.28, 1.5, 90, color)
	return frame
end

function Icons.shield(size: number, color: Color3, order: number?): Frame
	local frame = box("ShieldIcon", size, order)
	local w = size * 0.8
	line(frame, Vector2.new((size - w) / 2, size * 0.15), Vector2.new((size + w) / 2, size * 0.15), 1.5, color)
	line(frame, Vector2.new((size - w) / 2, size * 0.15), Vector2.new((size - w) / 2, size * 0.5), 1.5, color)
	line(frame, Vector2.new((size + w) / 2, size * 0.15), Vector2.new((size + w) / 2, size * 0.5), 1.5, color)
	line(frame, Vector2.new((size - w) / 2, size * 0.5), Vector2.new(size / 2, size * 0.92), 1.5, color)
	line(frame, Vector2.new((size + w) / 2, size * 0.5), Vector2.new(size / 2, size * 0.92), 1.5, color)
	return frame
end

-- Slippage: ukośna kreska między dwiema kropkami (jak znak %).
function Icons.slippage(size: number, color: Color3, order: number?): Frame
	local frame = box("SlippageIcon", size, order)
	line(frame, Vector2.new(size * 0.2, size * 0.85), Vector2.new(size * 0.8, size * 0.15), 1.5, color)
	outline(frame, Vector2.new(0, 0), Vector2.new(size * 0.35, size * 0.35), color, size, 1.5)
	outline(frame, Vector2.new(size * 0.65, size * 0.65), Vector2.new(size * 0.35, size * 0.35), color, size, 1.5)
	return frame
end

function Icons.check(size: number, color: Color3, order: number?): Frame
	local frame = box("CheckIcon", size, order)
	line(frame, Vector2.new(size * 0.18, size * 0.52), Vector2.new(size * 0.42, size * 0.75), 2, color)
	line(frame, Vector2.new(size * 0.42, size * 0.75), Vector2.new(size * 0.85, size * 0.25), 2, color)
	return frame
end

function Icons.close(size: number, color: Color3, order: number?): Frame
	local frame = box("CloseIcon", size, order)
	line(frame, Vector2.new(size * 0.2, size * 0.2), Vector2.new(size * 0.8, size * 0.8), 1.5, color)
	line(frame, Vector2.new(size * 0.8, size * 0.2), Vector2.new(size * 0.2, size * 0.8), 1.5, color)
	return frame
end

-- Strzałka (wstecz / dalej w pasku przeglądarki, przycisk Send): długi trzon i dwa ramiona pod 45°
-- schodzące się w grocie, z zaokrąglonymi końcami. Ramiona są z nachodzących na siebie kropek, a nie
-- z obróconej ramki: cienka obrócona ramka renderuje się w Robloxie jako poszarpane schodki.
function Icons.arrow(size: number, color: Color3, direction: "Left" | "Right", order: number?): Frame
	local frame = box("ArrowIcon", size, order)
	local f = size / 24
	local t = math.max(2, size / 8)
	local flip = direction == "Right"
	local function at(x: number, y: number): Vector2
		return Vector2.new(if flip then x * f else size - x * f, y * f)
	end
	local tip = at(20.5, 12)
	-- Trzon: pozioma ramka z zaokrąglonymi końcami.
	local tail = at(3.5, 12)
	create("Frame", {
		Name = "Shaft",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromOffset((tail.X + tip.X) / 2, tip.Y),
		Size = UDim2.fromOffset(math.abs(tip.X - tail.X) + t, t),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = frame,
	}, { Util.round() })
	for _, wing in { at(14.5, 6), at(14.5, 18) } do
		local d = wing - tip
		local steps = math.max(2, math.ceil(d.Magnitude / (t * 0.25)))
		for i = 0, steps do
			local p = tip + d * (i / steps)
			create("Frame", {
				Name = "Wing",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromOffset(p.X, p.Y),
				Size = UDim2.fromOffset(t, t),
				BackgroundColor3 = color,
				BorderSizePixel = 0,
				Parent = frame,
			}, { Util.round() })
		end
	end
	return frame
end

-- Duszek Ghostbox (portfel w grze): ręce w górę, jedno oko większe, uśmiech z różowym językiem.
-- Własny rysunek z ramek, skaluje się do każdego rozmiaru. `body`: kolor duszka, `face`: oczy i usta.
local GHOST_TONGUE = Color3.fromHex("FF5C8A")

function Icons.ghost(size: number, body: Color3, face: Color3, order: number?): Frame
	local frame = box("Ghostbox", size, order)
	local function part(name: string, center: Vector2, extent: Vector2, color: Color3, z: number, parent: Instance?): Frame
		return create("Frame", {
			Name = name,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(center.X, center.Y),
			Size = UDim2.fromScale(extent.X, extent.Y),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			ZIndex = z,
			Parent = parent or frame,
		}, { Util.round() })
	end

	for _, side in { -1, 1 } do
		local arm = part("Arm", Vector2.new(0.5 + side * 0.31, 0.43), Vector2.new(0.17, 0.32), body, 1)
		arm.Rotation = side * 35
	end
	part("Head", Vector2.new(0.5, 0.37), Vector2.new(0.6, 0.6), body, 2)
	create("Frame", {
		Name = "Body",
		Position = UDim2.fromScale(0.2, 0.37),
		Size = UDim2.fromScale(0.6, 0.45),
		BackgroundColor3 = body,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = frame,
	})
	-- Falisty dół z trzech półkoli.
	for _, x in { 0.3, 0.5, 0.7 } do
		part("Hem", Vector2.new(x, 0.82), Vector2.new(0.2, 0.2), body, 2)
	end

	part("EyeLeft", Vector2.new(0.39, 0.36), Vector2.new(0.09, 0.09), face, 3)
	part("EyeRight", Vector2.new(0.61, 0.35), Vector2.new(0.15, 0.15), face, 3)
	-- Usta: dolna połowa elipsy, przycięta ramką.
	local mouth = create("Frame", {
		Name = "Mouth",
		Position = UDim2.fromScale(0.35, 0.47),
		Size = UDim2.fromScale(0.3, 0.1),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		ZIndex = 3,
		Parent = frame,
	})
	part("Smile", Vector2.new(0.5, 0), Vector2.new(1, 2), face, 1, mouth)
	part("Tongue", Vector2.new(0.5, 0.6), Vector2.new(0.14, 0.17), GHOST_TONGUE, 4)
	return frame
end

-- Kłódka przed adresem strony.
function Icons.lock(size: number, color: Color3, order: number?): Frame
	local frame = box("LockIcon", size, order)
	outline(frame, Vector2.new(size * 0.28, size * 0.05), Vector2.new(size * 0.44, size * 0.55), color, size, 1.5)
	create("Frame", {
		Position = UDim2.fromOffset(size * 0.15, size * 0.42),
		Size = UDim2.fromOffset(size * 0.7, size * 0.55),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = frame,
	}, { Util.corner(2) })
	return frame
end

function Icons.plus(size: number, color: Color3, order: number?): Frame
	local frame = box("PlusIcon", size, order)
	line(frame, Vector2.new(size * 0.5, size * 0.15), Vector2.new(size * 0.5, size * 0.85), 1.8, color)
	line(frame, Vector2.new(size * 0.15, size * 0.5), Vector2.new(size * 0.85, size * 0.5), 1.8, color)
	return frame
end

-- Dzwonek (alerty cenowe): kopuła z zaokrągloną górą, rondo na dole i serce dzwonu.
-- `filled`: pełny (są ustawione alerty) albo tylko kontur.
function Icons.bell(size: number, color: Color3, filled: boolean?, order: number?): Frame
	local frame = box("BellIcon", size, order)
	local function part(pos: Vector2, extent: Vector2, radius: UDim, solid: boolean)
		local p: Frame = create("Frame", {
			Position = UDim2.fromScale(pos.X, pos.Y),
			Size = UDim2.fromScale(extent.X, extent.Y),
			BackgroundColor3 = color,
			BackgroundTransparency = if solid then 0 else 1,
			BorderSizePixel = 0,
			Parent = frame,
		}, { create("UICorner", { CornerRadius = radius }) })
		if not solid then
			create("UIStroke", { Color = color, Thickness = 1.6, Parent = p })
		end
	end
	part(Vector2.new(0.22, 0.12), Vector2.new(0.56, 0.62), UDim.new(0.5, 0), filled == true)
	part(Vector2.new(0.1, 0.62), Vector2.new(0.8, 0.12), UDim.new(1, 0), true)
	part(Vector2.new(0.41, 0.78), Vector2.new(0.18, 0.16), UDim.new(1, 0), true)
	return frame
end

-- Ikonka coina z inicjałami, w kolorze coina (kwadratowa albo okrągła).
function Icons.token(color: Color3, ticker: string, size: number, order: number?, rounded: boolean?): Frame
	local initials = string.sub(ticker, 1, 1) .. string.sub(ticker, -1)
	local frame: Frame = create("Frame", {
		Name = "TokenIcon",
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = color,
		LayoutOrder = order or 0,
	}, { if rounded then Util.round() else Util.corner(math.max(4, size // 10)), Util.stroke(color, 2) })
	create("UIGradient", {
		Rotation = 45,
		Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(90, 90, 90)),
		Parent = frame,
	})
	create("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = initials,
		TextSize = math.floor(size * 0.4),
		FontFace = Fonts.Bold,
		TextColor3 = Colors.Background,
		Parent = frame,
	})
	return frame
end

return table.freeze(Icons)
