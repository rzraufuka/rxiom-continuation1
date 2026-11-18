--!strict
-- Minimalny sygnał (event) do komunikacji między modułami.

export type Signal = {
	Connect: (self: Signal, handler: (...any) -> ()) -> () -> (),
	Fire: (self: Signal, ...any) -> (),
	_handlers: { (...any) -> () },
}

local Signal = {}

local function connect(self: Signal, handler: (...any) -> ()): () -> ()
	table.insert(self._handlers, handler)
	return function()
		local index = table.find(self._handlers, handler)
		if index then
			table.remove(self._handlers, index)
		end
	end
end

local function fire(self: Signal, ...: any)
	-- Kopia listy, bo handler może się rozłączyć w trakcie; task.spawn izoluje błędy handlerów.
	for _, handler in table.clone(self._handlers) do
		task.spawn(handler, ...)
	end
end

function Signal.new(): Signal
	return { Connect = connect, Fire = fire, _handlers = {} }
end

return table.freeze(Signal)
