--!strict
-- Pole "Quick Buy": kwota RXI kupowana jednym kliknięciem na listach coinów (Discover, Pulse).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Format = require(ReplicatedStorage.Shared.Format)

local Settings = require(script.Parent.Parent.Parent.State.Settings)

local UI = script.Parent.Parent
local Icons = require(UI.Icons)
local Theme = require(UI.Theme)
local Util = require(UI.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local QuickBuy = {}

function QuickBuy.new(order: number): Frame
	local box: Frame = create("Frame", {
		Name = "QuickBuy",
		Size = UDim2.fromOffset(196, 36),
		BackgroundColor3 = Colors.Elevated,
		LayoutOrder = order,
	}, { Util.round(), Util.padding(0, 14) })
	Util.label({
		Text = "Quick Buy",
		Size = 14,
		Color = Colors.TextMuted,
		FrameSize = UDim2.new(0, 72, 1, 0),
		Parent = box,
	})
	local input: TextBox = create("TextBox", {
		Name = "Amount",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(76, 0),
		Size = UDim2.new(1, -100, 1, 0),
		ClearTextOnFocus = false,
		Text = Format.decimal(Settings.State.QuickBuy),
		TextSize = 15,
		FontFace = Fonts.SemiBold,
		TextColor3 = Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = box,
	})
	local icon = Icons.currency(18)
	icon.AnchorPoint = Vector2.new(1, 0.5)
	icon.Position = UDim2.fromScale(1, 0.5)
	icon.Parent = box
	input.FocusLost:Connect(function()
		local amount = tonumber(input.Text)
		if not amount or amount ~= amount or amount < 0 or amount == math.huge then
			amount = Settings.State.QuickBuy
		end
		local value = amount :: number
		input.Text = Format.decimal(value)
		Settings.set("QuickBuy", value)
	end)
	-- Ta sama kwota jest na kilku stronach; zmiana w jednym polu odświeża pozostałe.
	Settings.Changed:Connect(function(key: string)
		if key == "QuickBuy" and not input:IsFocused() then
			input.Text = Format.decimal(Settings.State.QuickBuy)
		end
	end)
	return box
end

return QuickBuy
