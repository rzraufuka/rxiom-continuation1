--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)

local State = script.Parent.Parent.Parent.State
local Favorites = require(State.Favorites)
local Market = require(State.Market)

local UI = script.Parent.Parent
local FavoriteButton = require(script.Parent.FavoriteButton)
local Icons = require(UI.Icons)
local Theme = require(UI.Theme)
local Util = require(UI.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

export type FavoritesPage = {
	Frame: Frame,
	Refresh: () -> (),
}

type FavoriteRow = {
	Container: Frame,
	OpenButton: TextButton,
	Icon: Frame,
	Name: TextLabel,
	Detail: TextLabel,
	Price: TextLabel,
	PriceDetail: TextLabel,
}

local FavoritesPage = {}

function FavoritesPage.new(openCoin: (ticker: string) -> (), openDiscover: () -> ()): FavoritesPage
	local frame: Frame = create("Frame", {
		Name = "Favorites",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
	})

	local title = Util.text({ Text = "Favorites", Size = 28, Font = Fonts.Bold, Parent = frame })
	title.Position = UDim2.fromOffset(0, 6)
	Util.label({
		Text = "Follow saved coins with live market prices.",
		Size = 14,
		Color = Colors.TextMuted,
		Position = UDim2.fromOffset(0, 42),
		FrameSize = UDim2.new(1, 0, 0, 22),
		Parent = frame,
	})

	local panel: Frame = create("Frame", {
		Name = "SavedCoins",
		BackgroundColor3 = Colors.Surface,
		Position = UDim2.fromOffset(0, 78),
		Size = UDim2.new(1, 0, 1, -78),
		ClipsDescendants = true,
		Parent = frame,
	}, { Util.corner(8), Util.stroke(Colors.Border) })
	local panelHeader: Frame = create("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 48),
		Parent = panel,
	}, { Util.padding(0, 20) })
	Util.label({
		Text = "SAVED COINS",
		Size = 12,
		Font = Fonts.SemiBold,
		Color = Colors.TextMuted,
		Parent = panelHeader,
	})
	local countLabel = Util.label({
		Text = "0 saved",
		Size = 12,
		Color = Colors.TextDim,
		AlignX = Enum.TextXAlignment.Right,
		Position = UDim2.new(1, -120, 0, 0),
		FrameSize = UDim2.fromOffset(100, 48),
		Parent = panelHeader,
	})
	local headerDivider = Util.divider()
	headerDivider.Position = UDim2.fromOffset(0, 47)
	headerDivider.Parent = panel

	local list: ScrollingFrame = create("ScrollingFrame", {
		Name = "Rows",
		Position = UDim2.fromOffset(0, 48),
		Size = UDim2.new(1, 0, 1, -48),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Colors.Border,
		Visible = false,
		Parent = panel,
	}, { Util.padding(10, 12), Util.vlist(8, nil, Enum.VerticalAlignment.Top) })

	local empty: Frame = create("Frame", {
		Name = "EmptyState",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 48),
		Size = UDim2.new(1, 0, 1, -48),
		Parent = panel,
	})
	local emptyContent: Frame = create("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(380, 150),
		Parent = empty,
	}, { Util.vlist(10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center) })
	Util.label({
		Text = "No favorites yet",
		Size = 20,
		Font = Fonts.SemiBold,
		AlignX = Enum.TextXAlignment.Center,
		FrameSize = UDim2.fromOffset(380, 28),
		Parent = emptyContent,
	})
	Util.label({
		Text = "Save a coin with the star button to keep it close.",
		Size = 14,
		Color = Colors.TextMuted,
		AlignX = Enum.TextXAlignment.Center,
		FrameSize = UDim2.fromOffset(380, 22),
		Parent = emptyContent,
	})
	local discoverButton: TextButton = create("TextButton", {
		Name = "DiscoverCoins",
		AutoButtonColor = false,
		BackgroundColor3 = Colors.Primary,
		Size = UDim2.fromOffset(160, 40),
		Text = "Discover coins",
		TextColor3 = Colors.OnPrimary,
		TextSize = 14,
		FontFace = Fonts.SemiBold,
		Parent = emptyContent,
	}, { Util.corner(6) })
	Util.hoverBackground(discoverButton, Colors.Primary, Colors.PrimaryHover)
	discoverButton.Activated:Connect(openDiscover)

	local rows: { [string]: FavoriteRow } = {}
	local function createRow(ticker: string, order: number): FavoriteRow
		local container: Frame = create("Frame", {
			Name = ticker,
			BackgroundColor3 = Colors.Surface,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 72),
			LayoutOrder = order,
			Parent = list,
		}, { Util.corner(8), Util.stroke(Colors.Border) })
		local openButton: TextButton = create("TextButton", {
			Name = "OpenCoin",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, -56, 1, 0),
			Text = "",
			Parent = container,
		})
		Util.hoverBackground(openButton, Colors.Surface, Colors.SurfaceHover, 1)

		local icon = Icons.token(Colors.BadgeBackground, ticker, 38)
		icon.Position = UDim2.fromOffset(14, 17)
		icon.Parent = openButton
		local name = Util.label({
			Text = ticker,
			Size = 15,
			Font = Fonts.SemiBold,
			Position = UDim2.fromOffset(64, 9),
			FrameSize = UDim2.new(1, -250, 0, 22),
			Parent = openButton,
		})
		local detail = Util.label({
			Text = "",
			Size = 12,
			Color = Colors.TextMuted,
			Position = UDim2.fromOffset(64, 36),
			FrameSize = UDim2.new(1, -250, 0, 20),
			Parent = openButton,
		})
		local price = Util.label({
			Text = "—",
			Size = 14,
			Font = Fonts.Mono,
			AlignX = Enum.TextXAlignment.Right,
			Position = UDim2.new(1, -166, 0, 10),
			FrameSize = UDim2.fromOffset(146, 22),
			Parent = openButton,
		})
		local priceDetail = Util.label({
			Text = "",
			Size = 12,
			Color = Colors.TextMuted,
			Font = Fonts.Mono,
			AlignX = Enum.TextXAlignment.Right,
			Position = UDim2.new(1, -166, 0, 37),
			FrameSize = UDim2.fromOffset(146, 18),
			Parent = openButton,
		})
		local favoriteButton: TextButton = FavoriteButton.new(ticker)
		favoriteButton.AnchorPoint = Vector2.new(1, 0.5)
		favoriteButton.Position = UDim2.new(1, -10, 0.5, 0)
		favoriteButton.Parent = container

		local row: FavoriteRow = {
			Container = container,
			OpenButton = openButton,
			Icon = icon,
			Name = name,
			Detail = detail,
			Price = price,
			PriceDetail = priceDetail,
		}
		openButton.Activated:Connect(function()
			if Market.coin(ticker) then
				openCoin(ticker)
			end
		end)
		return row
	end

	local function refreshRow(ticker: string, row: FavoriteRow)
		local def = Coins.get(ticker)
		local coin = Market.coin(ticker)
		local available = def ~= nil or coin ~= nil
		row.Name.Text = if def then def.Name else ticker
		row.Detail.Text = if not available
			then "This coin is no longer available"
			elseif def and def.Creator
			then "Created by " .. def.Creator .. " · Pulse"
			else ticker .. " · Live market"
		row.Detail.TextColor3 = if available then Colors.TextMuted else Colors.TextDim
		row.Icon.BackgroundColor3 = if def then def.Color else Colors.BadgeBackground
		row.OpenButton.Active = coin ~= nil
		row.OpenButton.Selectable = coin ~= nil
		if coin then
			row.Price.Text = Format.rx(coin.Price)
			row.PriceDetail.Text = Format.usd(coin.Price * Config.UsdPerRx)
		else
			row.Price.Text = "—"
			row.PriceDetail.Text = if def then "Waiting for market data" else "Unavailable"
		end
	end

	local function refresh()
		if not frame.Visible then
			return
		end

		local tickers = Favorites.list()
		local seen: { [string]: boolean } = {}
		for order, ticker in tickers do
			if seen[ticker] then
				continue
			end
			seen[ticker] = true
			local row = rows[ticker]
			if not row then
				row = createRow(ticker, order)
				rows[ticker] = row
			end
			row.Container.LayoutOrder = order
			refreshRow(ticker, row)
		end
		for ticker, row in rows do
			if not seen[ticker] then
				row.Container:Destroy()
				rows[ticker] = nil
			end
		end

		local count = 0
		for _ in seen do
			count += 1
		end
		countLabel.Text = `{count} {if count == 1 then "saved coin" else "saved coins"}`
		list.Visible = count > 0
		empty.Visible = count == 0
	end

	Favorites.Changed:Connect(refresh)
	Market.Changed:Connect(refresh)

	return {
		Frame = frame,
		Refresh = refresh,
	}
end

return FavoritesPage
