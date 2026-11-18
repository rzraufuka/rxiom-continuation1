--!strict
-- Mini wykres ceny w wierszu tabeli. Odcinki są tworzone raz i tylko przesuwane przy aktualizacji.

local Util = require(script.Parent.Util)

local create = Util.create

export type Sparkline = {
	Frame: Frame,
	Set: (points: { number }, color: Color3) -> (),
}

local Sparkline = {}

function Sparkline.new(segments: number, size: Vector2): Sparkline
	local frame: Frame = create("Frame", {
		Name = "Sparkline",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size.X, size.Y),
	})
	local lines: { Frame } = {}
	local fills: { Frame } = {}
	local gradients: { UIGradient } = {}
	for i = 1, segments do
		local fill = create("Frame", { BorderSizePixel = 0, Visible = false, Parent = frame })
		gradients[i] = create("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new(0.8, 1),
			Parent = fill,
		})
		fills[i] = fill
		lines[i] = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			BorderSizePixel = 0,
			Visible = false,
			ZIndex = 2,
			Parent = frame,
		})
	end

	local function set(points: { number }, color: Color3)
		local n = math.min(#points, segments + 1)
		local offset = #points - n
		local lo, hi = math.huge, -math.huge
		for i = offset + 1, #points do
			lo = math.min(lo, points[i])
			hi = math.max(hi, points[i])
		end
		local range = if hi > lo then hi - lo else 1
		local function at(i: number): Vector2
			local v = points[offset + i]
			local y = if hi > lo then size.Y - (v - lo) / range * size.Y else size.Y / 2
			return Vector2.new((i - 1) / math.max(1, n - 1) * size.X, y)
		end
		for i = 1, segments do
			local visible = i < n
			lines[i].Visible = visible
			fills[i].Visible = visible
			if visible then
				local a, b = at(i), at(i + 1)
				local d = b - a
				local top = math.min(a.Y, b.Y)
				local fill = fills[i]
				fill.Position = UDim2.fromOffset(a.X, top)
				fill.Size = UDim2.fromOffset(d.X + 0.5, size.Y - top)
				fill.BackgroundColor3 = color
				local line = lines[i]
				line.Position = UDim2.fromOffset((a.X + b.X) / 2, (a.Y + b.Y) / 2)
				line.Size = UDim2.fromOffset(d.Magnitude + 1, 2)
				line.Rotation = math.deg(math.atan2(d.Y, d.X))
				line.BackgroundColor3 = color
			end
		end
	end

	return { Frame = frame, Set = set }
end

return Sparkline
