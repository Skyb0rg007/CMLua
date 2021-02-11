
local Event = require('cml.prim.event')

local M = {}

local cvar_meta = {
    __tostring = function(self)
        return string.format('CVar { .set = %s }', tostring(self.set))
    end
}

function M.is(x)
    return getmetatable(x) == cvar_meta
end

-- new : unit -> cvar
-- Construct a condition variable
function M.new()
    return setmetatable({ set = false, waiting = {} }, cvar_meta)
end

-- set : cvar -> unit
-- Set an unset condition variable
function M.set(cvar)
    if cvar.set then
        error('Condition variable is already set')
    else
        cvar.set = true
        for _, item in ipairs(cvar.waiting) do
            if not item.resume.resumed then
                item.resume(nil, item.wrap)
            end
        end
        cvar.waiting = nil
    end
end

-- waitEvt : cvar -> unit event
-- Event that synchonizes when the cvar is set
function M.waitEvt(cvar)
    return Event.base {
        name = 'M.cvar_waitEvt',
        pollFn = function()
            return cvar.set
        end,
        doFn = function()
            return true, nil, function(x) return x end
        end,
        blockFn = function(resume, wrap)
            if resume.resumed then return end
            if cvar.set then
                resume(nil, wrap)
            else
                table.insert(cvar.waiting, { resume = resume, wrap = wrap })
            end
        end
    }
end

return M
