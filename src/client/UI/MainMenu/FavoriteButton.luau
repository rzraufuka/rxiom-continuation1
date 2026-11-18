--!strict

local UI = script.Parent.Parent
local Favorites = require(UI.Parent.State.Favorites)
local Icons = require(UI.Icons)
local Theme = require(UI.Theme)
local Toast = require(UI.Toast)
local Util = require(UI.Util)

local Colors = Theme.Colors
local FavoriteButton = {}

function FavoriteButton.new(ticker: string): TextButton
	local button: TextButton = Util.create("TextButton", {
		Name = "Favorite",
		AutoButtonColor = false,
		Size = UDim2.fromOffset(36, 36),
		BackgroundColor3 = Colors.Elevated,
		Text = "",
	}, { Util.round() })
	Util.hoverBackground(button, Colors.Elevated, Colors.Border)

	local icon: ImageLabel? = nil
	local selected: boolean? = nil
	local function refresh()
		local saved = Favorites.has(ticker)
		if saved == selected then
			return
		end
		selected = saved
		button.Name = if saved then "RemoveFromFavorites" else "AddToFavorites"
		if icon then
			icon:Destroy()
		end
		local star = Icons.star(18, if saved then Colors.Yellow else Colors.TextMuted, nil, saved)
		star.AnchorPoint = Vector2.new(0.5, 0.5)
		star.Position = UDim2.fromScale(0.5, 0.5)
		star.Parent = button
		icon = star
	end
	refresh()
	local disconnect = Favorites.Changed:Connect(function(changedTicker: string?)
		if button.Parent and (not changedTicker or changedTicker == ticker) then
			refresh()
		end
	end)
	button.Destroying:Connect(disconnect)

	local busy = false
	button.Activated:Connect(function()
		if busy then
			return
		end
		busy = true
		local save = not Favorites.has(ticker)
		local ok, message = Favorites.set(ticker, save)
		busy = false
		if not ok then
			Toast.show(message or "Could not update favorites. Try again.", "Error")
		end
	end)
	return button
end

return FavoriteButton
