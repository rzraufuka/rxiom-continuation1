--!strict
-- Krótkie powiadomienia w prawym dolnym rogu.

local Theme = require(script.Parent.Theme)
local Util = require(script.Parent.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

export type Kind = "Success" | "Error" | "Info"

local LIFETIME = 3.5
local MAX_VISIBLE = 4

local Toast = {}

local container: Frame? = nil
local order = 0

local ACCENT: { [Kind]: Color3 } = {
	Success = Colors.Green,
	Error = Colors.Red,
	Info = Colors.Primary,
}

function Toast.mount(parent: Instance, bottomOffset: number)
	container = create("Frame", {
		Name = "Toasts",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -24, 1, -bottomOffset),
		Size = UDim2.fromOffset(360, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		ZIndex = 50,
		Parent = parent,
	}, { Util.vlist(8, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Bottom) })
end

function Toast.show(text: string, kind: Kind?)
	local parent = container
	if not parent then
		print("[RXIOM]", text)
		return
	end
	local resolved: Kind = kind or "Info"
	local accent = ACCENT[resolved]
	order += 1
	local toast: Frame = create("Frame", {
		Name = "Toast",
		Size = UDim2.fromOffset(360, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Colors.Elevated,
		LayoutOrder = order,
		ZIndex = 50,
		Parent = parent,
	}, {
		Util.corner(8),
		Util.stroke(accent, 1, 0.4),
		Util.padding(12, 14, 12, 18),
		create("Frame", {
			Name = "Accent",
			Position = UDim2.fromOffset(-10, 0),
			Size = UDim2.new(0, 3, 1, 0),
			BackgroundColor3 = accent,
			BorderSizePixel = 0,
			ZIndex = 51,
		}, { Util.round() }),
		create("TextLabel", {
			Name = "Text",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Text = text,
			TextWrapped = true,
			TextSize = 15,
			FontFace = Fonts.Medium,
			TextColor3 = Colors.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			ZIndex = 51,
		}),
	})

	local toasts = {}
	for _, child in parent:GetChildren() do
		if child:IsA("Frame") then
			table.insert(toasts, child)
		end
	end
	table.sort(toasts, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i = 1, #toasts - MAX_VISIBLE do
		toasts[i]:Destroy()
	end

	task.delay(LIFETIME, function()
		if toast.Parent then
			toast:Destroy()
		end
	end)
end

return Toast
