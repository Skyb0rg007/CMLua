
local Sched = require('cml.prim.sched')

local M = {}

local event_meta = {
    __tostring = function(self)
        return self.name or '<Event>'
    end
}

-- is_event : 'a -> boolean
function M.is(x)
    return getmetatable(x) == event_meta
end

-- base : {
--   name : string | nil,
--   pollFn : unit -> boolean,
--   doFn : unit -> 'a,
--   blockFn : 'b cont * ('b -> 'a) -> unit
-- } -> 'a event
--
-- Construct a base event
function M.base(t)
    t.tag = 'BASE'
    t.name = t.name or '<BaseEvent>'
    return setmetatable(t, event_meta)
end

-- never : 'a event
-- An event that never synchonizes
M.never = setmetatable({
        tag = 'BASE',
        name = 'never',
        pollFn = function() return false end,
        doFn = function() error('M.never.doFn was called!', 2) end,
        blockFn = function(cont, wrap) end
    }, event_meta)

-- always : 'a -> 'a event
-- An event that always synchronizes with the given value
function M.always(x)
    return setmetatable({
            tag = 'BASE',
            name = string.format('always(%s)', tostring(x)),
            pollFn = function() return true end,
            doFn = function() return true, x, function(x) return x end end,
            blockFn = function() error('M.always.blockFn was called!', 2) end
        }, event_meta)
end

-- choose : 'a event * 'a event -> 'a event
-- An event that synchronizes one of the two events
function M.choose(a, b)
    return setmetatable({
            tag = 'CHOOSE',
            name = string.format('choose(%s, %s)', tostring(a), tostring(b)),
            [1] = a,
            [2] = b
        }, choose_meta)
end

-- wrap : 'a event * ('a -> 'b) -> 'b event
-- When the given event synchonizes, call the function
-- The event returns the function return value
function M.wrap(evt, f)
    if evt.tag == 'BASE' then
        return M.base {
            name = string.format('wrap(%s, %s)', evt.name, tostring(f)),
            pollFn = evt.pollFn,
            doFn = function()
                local ok, ret, wrap = evt.doFn()
                if ok then
                    return true, ret, function(x) return f(wrap(x)) end
                else
                    return false
                end
            end,
            blockFn = function(cont, wrap)
                evt.blockFn(cont, function(x) return f(wrap(x)) end)
            end
        }
    else
        assert(evt.tag == 'CHOOSE')
        return M.choose(M.wrap(evt[1], f), M.wrap(evt[2], f))
    end
end

-- visit : 'a event * ('a event -> unit) -> unit
local function visit(evt, f)
    if evt.tag == 'BASE' then
        f(evt)
    else
        assert(evt.tag == 'CHOOSE')
        visit(evt[1], f)
        visit(evt[2], f)
    end
end

-- sync : 'a event -> 'a
function M.sync(evt)
    return Sched.suspend(function(returnK)
        -- Grab all events that polled true
        local enabled = {}
        visit(evt, function(base_evt)
            if base_evt.pollFn() then
                table.insert(enabled, base_evt.doFn)
            end
        end)

        -- Attempt each event that polled true
        for _, doFn in ipairs(enabled) do
            local ok, ret, wrap = doFn()
            if ok then
                returnK(wrap(ret))
                return
            end
        end

        -- Slow path: suspend thread until an event resolves
        Sched.spawn(function()
            local ret, wrap = Sched.suspend(function(resume)
                visit(evt, function(base_evt)
                    if resume.resumed then return end
                    base_evt.blockFn(resume, function(x) return x end)
                end)
            end)
            returnK(wrap(ret))
        end)
    end)
end

return M
