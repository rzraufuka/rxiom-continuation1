--!strict
-- Czarno-biały motyw RXIOM. Zielony i czerwony zostają tylko dla danych (zmiany cen, kupno/sprzedaż).

local Theme = {}

Theme.Colors = table.freeze({
	Background = Color3.fromHex("050505"),
	Surface = Color3.fromHex("0B0B0B"),
	SurfaceHover = Color3.fromHex("151515"),
	Elevated = Color3.fromHex("181818"),
	Border = Color3.fromHex("242424"),
	Divider = Color3.fromHex("161616"),

	Text = Color3.fromHex("FFFFFF"),
	TextMuted = Color3.fromHex("8C8C8C"),
	TextDim = Color3.fromHex("575757"),

	-- Akcent: białe przyciski z czarnym tekstem.
	Primary = Color3.fromHex("FFFFFF"),
	PrimaryHover = Color3.fromHex("D6D6D6"),
	OnPrimary = Color3.fromHex("050505"),

	BadgeBackground = Color3.fromHex("242424"),
	BadgeText = Color3.fromHex("FFFFFF"),

	-- Okno "przeglądarki" z rxiom.pro.
	ChromeStrip = Color3.fromHex("000000"),
	ChromeBar = Color3.fromHex("121212"),
	ChromeField = Color3.fromHex("1E1E1E"),

	Green = Color3.fromHex("2FE3AC"),
	Red = Color3.fromHex("EC397A"),
	Yellow = Color3.fromHex("F5C542"),
})

local FAMILY = "rbxasset://fonts/families/BuilderSans.json"

Theme.Fonts = table.freeze({
	Regular = Font.new(FAMILY, Enum.FontWeight.Regular),
	Medium = Font.new(FAMILY, Enum.FontWeight.Medium),
	SemiBold = Font.new(FAMILY, Enum.FontWeight.SemiBold),
	Bold = Font.new(FAMILY, Enum.FontWeight.Bold),
	Mono = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Medium),
})

-- Rozdzielczość, pod którą projektowany jest layout; UI skaluje się względem niej.
Theme.DesignSize = Vector2.new(1600, 820)

Theme.Site = "rxiom.pro"

-- Grafika monety RXI wgrana na Roblox (ma czarne tło, więc tylko na czarnym tle, np. animacja
-- przelewu). Size to rozmiar wgranego pliku, Crop to kwadrat z samą monetą w pikselach tego pliku.
export type ImageSpec = { Id: number, Size: Vector2, Crop: Rect }
Theme.CoinImage = table.freeze({
	Id = 126450260339769,
	Size = Vector2.new(1672, 941),
	Crop = Rect.new(478, 90, 1224, 836),
}) :: ImageSpec

-- Waluta w grze (odpowiednik SOL na Axiom).
Theme.Currency = require(game:GetService("ReplicatedStorage").Shared.Config).Currency

return table.freeze(Theme)
