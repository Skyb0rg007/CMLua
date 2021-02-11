
local CML = {}
local PCML = require('PCML')

-- type 'a binary_tree = nil | 'a | { 'a binary_tree, 'a binary_tree }
-- type 'a event = unit -> cvar list * { cvars: cvar binary_tree, thunk: unit -> 'a } PCML.event

-- 'a PCML.event -> 'a event
local function baseEvt(evt)
    return function()
        return {}, PCML.wrap(evt, function(x)
            return {
                cvars = nil,
                thunk = function() return x end
            }
        end)
    end
end

CML.spawn = PCML.spawn
CML.exit = PCML.exit
CML.run = PCML.run
CML.channel = PCML.channel
function CML.recv(chan)
    return CML.sync(CML.recvEvt(chan))
end
function CML.send(chan, value)
    return CML.sync(CML.sendEvt(chan, value))
end
function CML.recvEvt(chan)
    return baseEvt(PCML.recvEvt(chan))
end
function CML.sendEvt(chan, value)
    return baseEvt(PCML.sendEvt(chan, value))
end
CML.never = baseEvt(PCML.never)
function CML.always(value)
    return baseEvt(PCML.always(value))
end
function CML.wrap(thunk, f)
    return function()
        local cvars, evt = thunk()
        return cvars, PCML.wrap(evt, function(x)
            return {
                cvars = x.cvars,
                thunk = function()
                    return f(x.thunk())
                end
            }
        end, 'CML.wrap')
    end
end

function CML.sync(thunk)
    -- Run all the guards
    local _, evt = thunk()
    -- Synchonize
    local x = PCML.sync(evt)
    -- Signal the cvars for events that were not synchonized
    local function loop(obj)
        if PCML.is_cvar(obj) then
            PCML.cvar_set(obj)
        elseif obj then
            loop(obj[1])
            loop(obj[2])
        end
    end
    loop(x.cvars)
    return x.thunk()
end

-- (unit event -> 'a event) -> 'a event
function CML.withNack(f)
    return function()
        local nack = PCML.cvar()
        local thunk = f(baseEvt(PCML.cvar_waitEvt(nack)))
        local cvars, ev = thunk()

        return { nack, cvars }, ev
    end
end

-- (unit -> 'a event) -> 'a event
function CML.guard(f)
    return function()
        return f()()
    end
end

-- 'a event * 'a event -> 'a event
function CML.choose(thunk1, thunk2)
    return function()
        local cvars1, ev1 = thunk1()
        local cvars2, ev2 = thunk2()

        local nacks = { cvars1, cvars2 }

        local w1 = PCML.wrap(ev1, function(x)
            local cvars = { x.cvars, cvars2 }
            return { cvars = cvars, thunk = x.thunk }
        end)
        local w2 = PCML.wrap(ev2, function(x)
            local cvars = { x.cvars, cvars1 }
            return { cvars = cvars, thunk = x.thunk }
        end)

        return nacks, PCML.choose(w1, w2)
    end
end

return CML
