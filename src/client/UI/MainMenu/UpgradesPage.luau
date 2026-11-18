--!strict
-- Zakładka Upgrades: stałe ulepszenia kupowane za RXI (Upgrades.luau). Każda karta pokazuje
-- poziom, obecny i następny efekt oraz cenę; po zakupie karta "podskakuje", a kreski poziomu się zapalają.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local Upgrades = require(ReplicatedStorage.Shared.Upgrades)

local State = script.Parent.Parent.Parent.State
local Portfolio = require(State.Portfolio)

local UI = script.Parent.Parent
local Icons = require(UI.Icons)
local Theme = require(UI.Theme)
local Toast = require(UI.Toast)
local Util = require(UI.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local CARD_HEIGHT = 250
local GAP = 16

export type UpgradesPage = {
	Frame: Frame,
	Refresh: () -> (),
}

local UpgradesPage = {}

local function icon(id: Upgrades.Id): Frame
	if id == "FaucetAmount" then
		return Icons.currency(28)
	elseif id == "FaucetSpeed" then
		return Icons.gas(26, Colors.Text)
	elseif id == "Cashback" then
		return Icons.coin(26, Colors.Text)
	elseif id == "LaunchDiscount" then
		return Icons.plus(24, Colors.Text)
	end
	return Icons.bell(26, Colors.Text, true)
end

local function tween(instance: Instance, seconds: number, props: { [string]: any }, style: Enum.EasingStyle?)
	TweenService:Create(instance, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

type Card = {
	Def: Upgrades.UpgradeDef,
	Frame: Frame,
	Scale: UIScale,
	Stroke: UIStroke,
	Pips: { Frame },
	Level: TextLabel,
	Effect: TextLabel,
	Button: TextButton,
}

function UpgradesPage.new(): UpgradesPage
	local frame: ScrollingFrame = create("ScrollingFrame", {
		Name = "UpgradesPage",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Colors.Border,
		Visible = false,
	}, { Util.vlist(GAP, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top), Util.padding(2, 4, 2, 2) })

	-- Nagłówek z saldem
	local header = create("Frame", {
		Name = "Header",
		Size = UDim2.new(1, 0, 0, 88),
		BackgroundColor3 = Colors.Surface,
		LayoutOrder = 1,
		Parent = frame,
	}, { Util.corner(8), Util.stroke(Colors.Border), Util.padding(0, 24) })
	local titles = Util.group("Titles", 0, Util.vlist(4))
	titles.AnchorPoint = Vector2.new(0, 0.5)
	titles.Position = UDim2.fromScale(0, 0.5)
	titles.Parent = header
	Util.text({ Text = "Upgrades", Size = 26, Font = Fonts.Bold, Order = 1, Parent = titles })
	Util.text({
		Text = `Spend {Config.Currency} on permanent boosts. Upgrades stay with your wallet forever.`,
		Size = 15,
		Color = Colors.TextMuted,
		Order = 2,
		Parent = titles,
	})
	local balanceGroup = Util.group("Balance", 0, Util.hlist(8))
	balanceGroup.AnchorPoint = Vector2.new(1, 0.5)
	balanceGroup.Position = UDim2.fromScale(1, 0.5)
	balanceGroup.Parent = header
	Util.text({ Text = "Balance", Size = 15, Color = Colors.TextMuted, Order = 1, Parent = balanceGroup })
	Icons.currency(22, 2).Parent = balanceGroup
	local balanceLabel = Util.text({ Text = "0", Size = 24, Font = Fonts.Bold, Order = 3, Parent = balanceGroup })

	local grid = create("Frame", {
		Name = "Grid",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = frame,
	}, {
		create("UIGridLayout", {
			CellSize = UDim2.new(1 / 3, -GAP * 2 / 3, 0, CARD_HEIGHT),
			CellPadding = UDim2.fromOffset(GAP, GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	local cards: { Card } = {}
	local busy = false

	local function refresh()
		local state: Types.PortfolioState = Portfolio.State
		local levels = state.Upgrades or {}
		balanceLabel.Text = Format.decimal(state.Balance)
		for _, c in cards do
			local def = c.Def
			local level = Upgrades.level(levels, def.Id)
			local max = Upgrades.maxLevel(def)
			local cost = Upgrades.nextCost(levels, def.Id)
			for i, pip in c.Pips do
				pip.BackgroundColor3 = if i <= level then Colors.Green else Colors.Border
			end
			c.Level.Text = if max == 1 then (if level > 0 then "OWNED" else "ONE-TIME") else `LEVEL {level} / {max}`
			local now = def.Show(def.Values[level + 1])
			if cost then
				c.Effect.Text = `{now}  →  {def.Show(def.Values[level + 2])}`
				local affordable = cost <= state.Balance + 1e-9
				c.Button.Text = `{if level == 0 then "Buy" else "Upgrade"} · {Format.decimal(cost)} {Config.Currency}`
				c.Button.BackgroundColor3 = Colors.Primary
				c.Button.TextColor3 = Colors.OnPrimary
				c.Button.BackgroundTransparency = if affordable then 0 else 0.7
				c.Button.AutoButtonColor = false
			else
				c.Effect.Text = now
				c.Button.Text = "Maxed"
				c.Button.BackgroundColor3 = Colors.Elevated
				c.Button.TextColor3 = Colors.Green
				c.Button.BackgroundTransparency = 0
			end
			c.Stroke.Color = if not cost then Colors.Green else Colors.Border
			c.Stroke.Transparency = if not cost then 0.5 else 0
		end
	end

	local function celebrate(c: Card)
		c.Scale.Scale = 0.95
		tween(c.Scale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
		c.Stroke.Color = Colors.Green
		c.Stroke.Transparency = 0
		local level = Upgrades.level(Portfolio.State.Upgrades, c.Def.Id)
		local pip = c.Pips[level]
		if pip then
			pip.Size = UDim2.new(pip.Size.X.Scale, pip.Size.X.Offset, 0, 14)
			tween(pip, 0.35, { Size = UDim2.new(pip.Size.X.Scale, pip.Size.X.Offset, 0, 6) }, Enum.EasingStyle.Back)
		end
	end

	for i, def in Upgrades.List do
		local card: Frame = create("Frame", {
			Name = def.Id,
			BackgroundColor3 = Colors.Surface,
			LayoutOrder = i,
			Parent = grid,
		}, { Util.corner(12), Util.padding(20) })
		local stroke: UIStroke = create("UIStroke", { Color = Colors.Border, Parent = card })
		local scale: UIScale = create("UIScale", { Parent = card })
		local iconHolder = create("Frame", {
			Name = "Icon",
			Size = UDim2.fromOffset(48, 48),
			BackgroundColor3 = Colors.Elevated,
			Parent = card,
		}, { Util.corner(12) })
		local glyph = icon(def.Id)
		glyph.AnchorPoint = Vector2.new(0.5, 0.5)
		glyph.Position = UDim2.fromScale(0.5, 0.5)
		glyph.Parent = iconHolder
		local levelLabel = Util.label({
			Text = "",
			Size = 12,
			Font = Fonts.SemiBold,
			Color = Colors.TextMuted,
			AlignX = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			FrameSize = UDim2.fromOffset(120, 18),
			Parent = card,
		})
		local pips = {}
		local maxLevel = Upgrades.maxLevel(def)
		local pipRow = create("Frame", {
			Name = "Pips",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromOffset(0, 24),
			Size = UDim2.fromOffset(0, 14),
			BackgroundTransparency = 1,
			Parent = card,
		})
		pipRow.Position = UDim2.new(1, 0, 0, 24)
		pipRow.Size = UDim2.fromOffset(maxLevel * 22 - 4, 14)
		for p = 1, maxLevel do
			pips[p] = create("Frame", {
				Name = "Pip" .. p,
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, (p - 1) * 22, 0.5, 0),
				Size = UDim2.fromOffset(18, 6),
				BackgroundColor3 = Colors.Border,
				BorderSizePixel = 0,
				Parent = pipRow,
			}, { Util.round() })
		end
		Util.label({
			Text = def.Name,
			Size = 20,
			Font = Fonts.Bold,
			Position = UDim2.fromOffset(0, 62),
			FrameSize = UDim2.new(1, 0, 0, 26),
			Parent = card,
		})
		local desc = Util.label({
			Text = def.Description,
			Size = 14,
			Color = Colors.TextMuted,
			Position = UDim2.fromOffset(0, 90),
			FrameSize = UDim2.new(1, 0, 0, 40),
			Parent = card,
		})
		desc.TextWrapped = true
		desc.TextTruncate = Enum.TextTruncate.None
		desc.TextYAlignment = Enum.TextYAlignment.Top
		local effect = Util.label({
			Text = "",
			Size = 16,
			Font = Fonts.SemiBold,
			Color = Colors.Green,
			Position = UDim2.new(0, 0, 1, -82),
			FrameSize = UDim2.new(1, 0, 0, 22),
			Parent = card,
		})
		local button: TextButton = create("TextButton", {
			Name = "Buy",
			AutoButtonColor = false,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 44),
			BackgroundColor3 = Colors.Primary,
			Text = "",
			TextSize = 16,
			FontFace = Fonts.Bold,
			TextColor3 = Colors.OnPrimary,
			Parent = card,
		}, { Util.round() })
		local c: Card = {
			Def = def,
			Frame = card,
			Scale = scale,
			Stroke = stroke,
			Pips = pips,
			Level = levelLabel,
			Effect = effect,
			Button = button,
		}
		table.insert(cards, c)
		button.Activated:Connect(function()
			if busy or not Upgrades.nextCost(Portfolio.State.Upgrades, def.Id) then
				return
			end
			busy = true
			task.spawn(function()
				local ok, result = pcall(Remotes.BuyUpgrade.InvokeServer, Remotes.BuyUpgrade, def.Id)
				busy = false
				if ok and typeof(result) == "table" and result.Ok then
					Toast.show(`{def.Name} upgraded!`, "Success")
					-- Portfel z serwera mógł już dojść; animacja po odświeżeniu.
					task.wait()
					refresh()
					celebrate(c)
				else
					Toast.show(if ok and typeof(result) == "table" then result.Error or "Couldn't buy" else "Connection problem, try again", "Error")
				end
			end)
		end)
	end

	Portfolio.Changed:Connect(function()
		if frame.Visible then
			refresh()
		end
	end)
	refresh()

	return {
		Frame = frame :: any,
		Refresh = refresh,
	}
end

return UpgradesPage
