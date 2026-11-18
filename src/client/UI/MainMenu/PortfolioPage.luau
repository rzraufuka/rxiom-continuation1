--!strict
-- Strona Portfolio: saldo, wartość pozycji, łączny PnL i lista posiadanych coinów.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)

local State = script.Parent.Parent.Parent.State
local Actions = require(State.Actions)
local Market = require(State.Market)
local Portfolio = require(State.Portfolio)

local UI = script.Parent.Parent
local Icons = require(UI.Icons)
local Theme = require(UI.Theme)
local Util = require(UI.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local COLUMNS: { { Title: string, Width: number } } = {
	{ Title = "Token", Width = 0.26 },
	{ Title = "Holding", Width = 0.16 },
	{ Title = "Value", Width = 0.16 },
	{ Title = "Bought", Width = 0.12 },
	{ Title = "Sold", Width = 0.12 },
	{ Title = "PnL", Width = 0.18 },
}

export type PortfolioPage = {
	Frame: Frame,
	Refresh: () -> (),
}

local PortfolioPage = {}

local function summaryCard(parent: Instance, title: string, order: number): (TextLabel, TextLabel)
	local frame = create("Frame", {
		Name = title,
		BackgroundColor3 = Colors.Surface,
		Size = UDim2.new(0.25, -12, 1, 0),
		LayoutOrder = order,
		Parent = parent,
	}, {
		Util.corner(8),
		Util.stroke(Colors.Border),
		Util.padding(16, 20),
		Util.vlist(6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center),
	})
	Util.text({ Text = title, Size = 14, Color = Colors.TextMuted, Order = 1, Parent = frame })
	local value = Util.text({ Text = "0", Size = 26, Font = Fonts.Bold, Order = 2, Parent = frame })
	local sub = Util.text({ Text = "", Size = 14, Color = Colors.TextMuted, Order = 3, Parent = frame })
	return value, sub
end

local function cells(_parent: Instance, build: (x: number, width: number, index: number) -> ())
	local x = 0
	for i, column in COLUMNS do
		local width = column.Width
		build(x, width, i)
		x += width
	end
end

function PortfolioPage.new(openCoin: (ticker: string) -> ()): PortfolioPage
	local frame: Frame = create("Frame", {
		Name = "Portfolio",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
	})

	local title = Util.text({ Text = "Portfolio", Size = 28, Font = Fonts.Bold, Parent = frame })
	title.Position = UDim2.fromOffset(0, 8)

	-- Adres portfela Ghostbox obok tytułu.
	local walletPill = create("Frame", {
		Name = "WalletAddress",
		Position = UDim2.fromOffset(150, 12),
		Size = UDim2.fromOffset(0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Colors.Elevated,
		Visible = false,
		Parent = frame,
	}, { Util.round(), Util.stroke(Colors.Border), Util.padding(0, 12), Util.hlist(8) })
	Icons.wallet(14, Colors.TextMuted, 1).Parent = walletPill
	local walletLabel = Util.text({ Text = "", Size = 14, Font = Fonts.Mono, Order = 2, Parent = walletPill })
	local function refreshWallet()
		local wallet = Portfolio.State.Wallet
		walletPill.Visible = wallet ~= nil
		if wallet then
			walletLabel.Text = string.sub(wallet, 1, 6) .. "..." .. string.sub(wallet, -6)
		end
	end
	Portfolio.Changed:Connect(refreshWallet)
	refreshWallet()

	local summary = create("Frame", {
		Name = "Summary",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 60),
		Size = UDim2.new(1, 0, 0, 110),
		Parent = frame,
	}, { Util.hlist(16) })
	local balanceValue, balanceSub = summaryCard(summary, "Balance", 1)
	local holdingsValue, holdingsSub = summaryCard(summary, "Holdings value", 2)
	local pnlValue, pnlSub = summaryCard(summary, "Total PnL", 3)
	local ordersValue, ordersSub = summaryCard(summary, "Open orders", 4)

	local tableFrame = create("Frame", {
		Name = "Positions",
		BackgroundColor3 = Colors.Surface,
		Position = UDim2.fromOffset(0, 186),
		Size = UDim2.new(1, 0, 1, -186),
		ClipsDescendants = true,
		Parent = frame,
	}, { Util.corner(8), Util.stroke(Colors.Border) })
	local headerRow = create("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 46),
		Parent = tableFrame,
	}, { Util.padding(0, 24) })
	cells(headerRow, function(x, width, i)
		Util.label({
			Text = COLUMNS[i].Title,
			Size = 14,
			Color = Colors.TextMuted,
			Position = UDim2.fromScale(x, 0),
			FrameSize = UDim2.fromScale(width, 1),
			Parent = headerRow,
		})
	end)
	local headerDivider = Util.divider()
	headerDivider.Position = UDim2.fromOffset(0, 46)
	headerDivider.Parent = tableFrame
	local list: ScrollingFrame = create("ScrollingFrame", {
		Name = "Rows",
		Position = UDim2.fromOffset(0, 47),
		Size = UDim2.new(1, 0, 1, -47),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = Colors.Border,
		Parent = tableFrame,
	}, { Util.vlist(0, nil, Enum.VerticalAlignment.Top) })
	local empty = Util.label({
		Name = "Empty",
		Text = "No positions yet. Pick a coin on Discover and buy it.",
		Size = 16,
		Color = Colors.TextMuted,
		AlignX = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(0, 47),
		FrameSize = UDim2.new(1, 0, 0, 120),
		Parent = tableFrame,
	})

	local function refresh()
		if not frame.Visible then
			return
		end
		for _, child in list:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end

		local state = Portfolio.State
		local totalValue, totalPnl, count = 0, 0, 0
		for order, def in Coins.all() do
			local p = state.Positions[def.Ticker]
			local coin = Market.coin(def.Ticker)
			if not p or not coin then
				continue
			end
			local tokens = Portfolio.totalTokens(def.Ticker)
			local value = tokens * coin.Price
			local pnl = p.SoldRx + value - p.BoughtRx
			totalValue += value
			totalPnl += pnl
			count += 1

			local row: TextButton = create("TextButton", {
				Name = def.Ticker,
				AutoButtonColor = false,
				Size = UDim2.new(1, 0, 0, 64),
				BackgroundColor3 = Colors.Surface,
				BorderSizePixel = 0,
				Text = "",
				LayoutOrder = order,
				Parent = list,
			})
			local divider = Util.divider(false, Colors.Divider)
			divider.AnchorPoint = Vector2.new(0, 1)
			divider.Position = UDim2.fromScale(0, 1)
			divider.Parent = row
			local content = create("Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 1),
				Parent = row,
			}, { Util.padding(0, 24) })
			local texts: { { Text: string, Sub: string?, Color: Color3? } } = {
				{ Text = def.Ticker, Sub = def.Name },
				{ Text = Format.compact(tokens), Sub = def.Ticker },
				{ Text = Format.rx(value), Sub = Format.usd(value * Config.UsdPerRx) },
				{ Text = Format.decimal(p.BoughtRx), Sub = Config.Currency },
				{ Text = Format.decimal(p.SoldRx), Sub = Config.Currency },
				{
					Text = (if pnl > 0 then "+" else "") .. Format.rx(pnl),
					Sub = if p.BoughtRx > 0 then Format.percent(pnl / p.BoughtRx * 100) else "",
					Color = Util.changeColor(pnl),
				},
			}
			cells(content, function(x, width, i)
				local item = texts[i]
				local offset = if i == 1 then 50 else 0
				if i == 1 then
					local icon = Icons.token(def.Color, def.Ticker, 38)
					icon.AnchorPoint = Vector2.new(0, 0.5)
					icon.Position = UDim2.fromScale(x, 0.5)
					icon.Parent = content
				end
				Util.label({
					Text = item.Text,
					Size = 16,
					Font = Fonts.SemiBold,
					Color = item.Color,
					Position = UDim2.new(x, offset, 0, 12),
					FrameSize = UDim2.new(width, -offset, 0, 20),
					Parent = content,
				})
				Util.label({
					Text = item.Sub or "",
					Size = 13,
					Color = if i == 6 then item.Color else Colors.TextMuted,
					Position = UDim2.new(x, offset, 0, 34),
					FrameSize = UDim2.new(width, -offset, 0, 16),
					Parent = content,
				})
			end)
			Util.hoverBackground(row, Colors.Surface, Colors.SurfaceHover)
			row.Activated:Connect(function()
				openCoin(def.Ticker)
			end)
		end
		empty.Visible = count == 0

		balanceValue.Text = Format.rx(state.Balance)
		balanceSub.Text = Format.usd(state.Balance * Config.UsdPerRx)
		holdingsValue.Text = Format.rx(totalValue)
		holdingsSub.Text = `{count} coin{if count == 1 then "" else "s"}`
		pnlValue.Text = (if totalPnl > 0 then "+" else "") .. Format.rx(totalPnl)
		pnlValue.TextColor3 = if math.abs(totalPnl) < 1e-9 then Colors.Text else Util.changeColor(totalPnl)
		pnlSub.Text = Format.usd(totalPnl * Config.UsdPerRx)
		ordersValue.Text = tostring(#state.Orders + #state.Triggers)
		ordersSub.Text = "limit, TP and SL"
	end

	Portfolio.Changed:Connect(refresh)
	Market.Changed:Connect(refresh)

	local deposit: TextButton = create("TextButton", {
		Name = "Deposit",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 6),
		Size = UDim2.fromOffset(0, 40),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = Colors.Primary,
		Text = `Claim {Config.Faucet.Amount} {Config.Currency}`,
		TextSize = 16,
		FontFace = Fonts.SemiBold,
		TextColor3 = Colors.OnPrimary,
		Parent = frame,
	}, { Util.round(), Util.padding(0, 18) })
	Util.hoverBackground(deposit, Colors.Primary, Colors.PrimaryHover)
	deposit.Activated:Connect(Actions.claimFaucet)

	return { Frame = frame, Refresh = refresh }
end

return PortfolioPage
