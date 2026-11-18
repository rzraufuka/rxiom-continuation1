--!strict
-- Okno "przeglądarki", w którym gracz ogląda rxiom.pro: sam pasek adresu jak w Chrome, bez kart.
-- Rysowane w pikselach ekranu (bez UIScale). Przyciski Robloxa leżą na nim w lewym górnym rogu.

local Icons = require(script.Parent.Icons)
local Theme = require(script.Parent.Theme)
local Util = require(script.Parent.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local TOOLBAR_HEIGHT = 38

export type Callbacks = {
	Back: () -> (),
	Forward: () -> (),
}

export type Browser = {
	Frame: Frame,
	-- Ścieżka strony, np. "/discover"; w pasku adresu poprzedzona domeną.
	SetPath: (path: string) -> (),
	SetHistory: (canBack: boolean, canForward: boolean) -> (),
	-- `left`: gdzie kończą się przyciski Robloxa, `topbarHeight`: ich obszar w pionie (piksele ekranu).
	-- Zwraca wysokość całego okna przeglądarki.
	Layout: (left: number, topbarHeight: number) -> number,
}

local Browser = {}

local DISABLED_ICON = Color3.fromHex("6B6B6B")

local function toolButton(name: string, order: number): TextButton
	local button: TextButton = create("TextButton", {
		Name = name,
		AutoButtonColor = false,
		Size = UDim2.fromOffset(28, 28),
		BackgroundColor3 = Colors.ChromeField,
		BackgroundTransparency = 1,
		Text = "",
		LayoutOrder = order,
	}, { Util.round() })
	Util.hoverBackground(button, Colors.ChromeField, Colors.ChromeField, 1)
	return button
end

local function center(icon: Frame, parent: Instance)
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Parent = parent
end

function Browser.new(callbacks: Callbacks): Browser
	-- Jeden pasek na całą szerokość: strzałki i pole adresu.
	local toolbar: Frame = create("Frame", {
		Name = "Browser",
		Size = UDim2.new(1, 0, 0, TOOLBAR_HEIGHT),
		BackgroundColor3 = Colors.ChromeBar,
		BorderSizePixel = 0,
		ZIndex = 10,
	})
	local frame = toolbar
	local divider = Util.divider(false, nil, true)
	divider.AnchorPoint = Vector2.new(0, 1)
	divider.Position = UDim2.fromScale(0, 1)
	divider.Parent = toolbar

	local nav = Util.group("Nav", 0, Util.hlist(4))
	nav.AnchorPoint = Vector2.new(0, 0.5)
	nav.Position = UDim2.new(0, 10, 0.5, 0)
	nav.Parent = toolbar
	local backButton = toolButton("Back", 1)
	local backIcon = Icons.arrow(20, Colors.Text, "Left")
	center(backIcon, backButton)
	backButton.Parent = nav
	local forwardButton = toolButton("Forward", 2)
	local forwardIcon = Icons.arrow(20, Colors.Text, "Right")
	center(forwardIcon, forwardButton)
	forwardButton.Parent = nav

	local address: Frame = create("Frame", {
		Name = "Address",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 76, 0.5, 0),
		Size = UDim2.new(1, -84, 0, 32),
		BackgroundColor3 = Colors.ChromeField,
		Parent = toolbar,
	}, { Util.round(), Util.padding(0, 16) })
	local lock = Icons.lock(11, Colors.TextMuted)
	lock.AnchorPoint = Vector2.new(0, 0.5)
	lock.Position = UDim2.fromScale(0, 0.5)
	lock.Parent = address
	local url: TextLabel = create("TextLabel", {
		Name = "Url",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(24, 0),
		Size = UDim2.new(1, -24, 1, 0),
		RichText = true,
		Text = "",
		TextSize = 14,
		FontFace = Fonts.Regular,
		TextColor3 = Colors.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = address,
	})

	backButton.Activated:Connect(callbacks.Back)
	forwardButton.Activated:Connect(callbacks.Forward)

	local function setIconColor(icon: Frame, enabled: boolean)
		for _, part in icon:GetChildren() do
			if part:IsA("Frame") then
				-- Nieaktywna strzałka jak w Chrome: przygaszona, ale wciąż czytelna.
				part.BackgroundColor3 = if enabled then Colors.Text else DISABLED_ICON
			end
		end
	end

	return {
		Frame = frame,
		SetPath = function(path: string)
			url.Text = `<font color="#FFFFFF">{Theme.Site}</font>{path}`
		end,
		SetHistory = function(canBack: boolean, canForward: boolean)
			setIconColor(backIcon, canBack)
			setIconColor(forwardIcon, canForward)
			backButton.Active = canBack
			forwardButton.Active = canForward
		end,
		-- Pasek jest co najmniej tak wysoki jak przyciski Robloxa, które leżą w jego lewym górnym rogu,
		-- więc strzałki i pole adresu zaczynają się za nimi.
		Layout = function(left: number, topbarHeight: number): number
			local height = math.max(TOOLBAR_HEIGHT, math.ceil(topbarHeight))
			local toolbarLeft = math.max(10, math.ceil(left))
			frame.Size = UDim2.new(1, 0, 0, height)
			nav.Position = UDim2.new(0, toolbarLeft, 0.5, 0)
			-- Dwa przyciski po 28 px z odstępem 4 px, potem 6 px przerwy przed polem adresu.
			address.Position = UDim2.new(0, toolbarLeft + 66, 0.5, 0)
			address.Size = UDim2.new(1, -(toolbarLeft + 74), 0, 32)
			return height
		end,
	}
end

return Browser
