--!strict
-- Wzory perpetuals wspólne dla serwera i klienta (podgląd w panelu = to, co policzy serwer).
-- Ceny w $, Margin/PnL w RXI (przeliczane przez Config.UsdPerRx), Size w jednostkach aktywa.

local Config = require(script.Parent.Config)
local Types = require(script.Parent.Types)

type PerpPosition = Types.PerpPosition
type PerpSide = Types.PerpSide

local U = Config.UsdPerRx

local PerpMath = {}

local bySymbol: { [string]: Config.PerpMarketDef } = {}
for _, def in Config.Perps.Markets do
	bySymbol[def.Symbol] = def
end

function PerpMath.market(symbol: any): Config.PerpMarketDef?
	return if typeof(symbol) == "string" then bySymbol[symbol] else nil
end

-- Dawne nazwy rynków -> obecne (te same krzywe cen), do wczytywania starszych zapisów.
local RENAMED: { [string]: string } = { BTC = "GHST", ETH = "OBBY", SOL = "BACON" }

function PerpMath.rename(symbol: any): any
	return if typeof(symbol) == "string" then RENAMED[symbol] or symbol else symbol
end

-- Margin utrzymania jako ułamek wartości pozycji: połowa marginu początkowego przy max dźwigni.
function PerpMath.mmr(symbol: string): number
	local def = bySymbol[symbol]
	return if def then 1 / (2 * def.MaxLeverage) else 0.05
end

function PerpMath.dir(side: PerpSide): number
	return if side == "Long" then 1 else -1
end

-- Wielkość pozycji (w aktywie) za `margin` RXI z dźwignią `leverage` po cenie `price`.
function PerpMath.sizeFor(margin: number, leverage: number, price: number): number
	return margin * leverage * U / price
end

-- Wartość `size` aktywa w RXI.
function PerpMath.notionalRx(size: number, price: number): number
	return size * price / U
end

-- Niezrealizowany PnL w RXI.
function PerpMath.pnl(pos: PerpPosition, price: number): number
	return pos.Size * (price - pos.Entry) * PerpMath.dir(pos.Side) / U
end

-- Cena, przy której margin + PnL spada do marginu utrzymania. Long: 0, gdy nie da się zlikwidować.
function PerpMath.liqPriceFor(side: PerpSide, size: number, entry: number, margin: number, mmr: number): number
	if size <= 0 then
		return 0
	end
	local cushion = margin * U / size
	if side == "Long" then
		return math.max(0, (entry - cushion) / (1 - mmr))
	end
	return (entry + cushion) / (1 + mmr)
end

function PerpMath.liqPrice(pos: PerpPosition): number
	return PerpMath.liqPriceFor(pos.Side, pos.Size, pos.Entry, pos.Margin, PerpMath.mmr(pos.Symbol))
end

-- Czy cena `price` likwiduje pozycję.
function PerpMath.liquidates(pos: PerpPosition, price: number): boolean
	local liq = PerpMath.liqPrice(pos)
	if pos.Side == "Long" then
		return price <= liq
	end
	return price >= liq
end

-- Efektywna dźwignia: wartość pozycji po cenie wejścia / margin.
function PerpMath.leverage(pos: PerpPosition): number
	if pos.Margin <= 0 then
		return math.huge
	end
	return PerpMath.notionalRx(pos.Size, pos.Entry) / pos.Margin
end

return PerpMath
