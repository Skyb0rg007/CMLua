
local Sched = require('cml.prim.sched')
local Event = require('cml.prim.event')
local CVar  = require('cml.prim.cvar')
local Chan  = require('cml.prim.chan')

local M = {}

local event_meta = {
    __tostring = function(self)
        return self.name or 'Event'
    end
}

local tid_meta = {
    __tostring = function(self)
        return 'ThreadID'
    end
}

-- 'a prim_event -> 'a event
function M.primitive(prim_evt)
    return setmetatable({
            func = function()
                return nil, Event.wrap(prim_evt, function(x)
                    return {
                        cvars = nil,
                        thunk = function() return x end
                    }
                end)
            end
        }, event_meta)
end

function M.spawn(f)
    local dead = CVar.new()
    Sched.spawn(function()
        xpcall(f, function(e, ...)
            print('Thread raised error', e)
        end)
        CVar.set(dead)
    end)
    return setmetatable({ dead = dead }, tid_meta)
end

function M.joinEvt(tid)
    return M.primitive(CVar.waitEvt(tid.dead))
end

function M.exit()
    Sched.exit()
end

function M.run(f)
    Sched.run(f)
end

function M.channel(chan)
    return Chan.new()
end

function M.send(chan, value)
    Chan.send(chan, value)
end

function M.recv(chan)
    return Chan.recv(chan)
end

function M.sendEvt(chan, value)
    return M.primitive(Chan.sendEvt(chan, value))
end

function M.recvEvt(chan)
    return M.primitive(Chan.recvEvt(chan))
end

M.never = M.primitive(Event.never)

function M.always(value)
    return M.primitive(Event.always(value))
end

function M.wrap(evt, f)
    return setmetatable({
            name = 'wrap',
            func = function()
                local cvars, prim_evt = evt.func()
                return cvars, Event.wrap(prim_evt, function(x)
                    return {
                        cvars = x.cvars,
                        thunk = function()
                            return f(x.thunk())
                        end
                    }
                end)
            end
        }, event_meta)
end

function M.sync(evt)
    local _, prim_evt = evt.func()
    local x = Event.sync(prim_evt)
    local function loop(obj)
        if CVar.is(obj) then
            CVar.set(obj)
        elseif obj then
            loop(obj[1])
            loop(obj[2])
        end
    end
    loop(x.cvars)
    return x.thunk()
end

function M.withNack(f)
    return setmetatable({
            name = 'withNack',
            func = function()
                local nack = CVar.new()
                local cvars, prim_evt = f(M.primitive(CVar.waitEvt(nack))).func()
                return { nack, cvars }, prim_evt
            end
        }, event_meta)
end

function M.guard(f)
    return setmetatable({
            name = 'guard',
            func = function()
                return f().func()
            end
        }, event_meta)
end

function M.choose(evt1, evt2)
    return setmetatable({
            name = 'choose',
            func = function()
                local cvars1, prim_evt1 = evt1.func()
                local cvars2, prim_evt2 = evt2.func()

                -- If this event is not synchronized, set these cvars
                local nacks = { cvars1, cvars2 }

                -- Pass down the other events' cvars
                prim_evt1 = Event.wrap(prim_evt1, function(x)
                    local cvars = { x.cvars, cvars2 }
                    return {
                        cvars = cvars,
                        thunk = x.thunk
                    }
                end)
                prim_evt2 = Event.wrap(prim_evt2, function(x)
                    local cvars = { x.cvars, cvars1 }
                    return {
                        cvars = cvars,
                        thunk = x.thunk
                    }
                end)

                return nacks, Event.choose(prim_evt1, prim_evt2)
            end
        }, event_meta)
end

return M

