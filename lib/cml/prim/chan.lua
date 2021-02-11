-- Channels

local Event = require('cml.prim.event')

local M = {}

local chan_meta = {
    __tostring = function(self)
        return 'Chan'
    end,
    __metatable = false
}

function M.is(x)
    return getmetatable(x) == chan_meta
end

local function filterResumed(q)
    local i = 1
    while i <= #q do
        if q[i].resume.resumed then
            table.remove(q, i)
        else
            i = i + 1
        end
    end
end

-- channel : unit -> 'a chan
function M.new()
    return setmetatable({ sendq = {}, recvq = {} }, chan_meta)
end

-- recvEvt : 'a chan -> 'a event
function M.recvEvt(chan)
    return Event.base {
        pollFn = function()
            filterResumed(chan.sendq)
            return #chan.sendq ~= 0
        end,
        doFn = function()
            filterResumed(chan.sendq)
            local item = table.remove(chan.sendq, 1)
            if item then
                item.resume(nil, item.wrap)
                return true, item.value, function(x) return x end
            else
                return false
            end
        end,
        blockFn = function(resume, wrap)
            if resume.resumed then return end
            filterResumed(chan.sendq)
            local item = table.remove(chan.sendq, 1)
            if item then
                item.resume(nil, item.wrap)
                resume(item.value, item.wrap)
            else
                filterResumed(chan.recvq)
                table.insert(chan.recvq, {
                        resume = resume,
                        wrap = wrap
                    })
            end
        end
    }
end

-- sendEvt : 'a chan * 'a -> unit event
function M.sendEvt(chan, value)
    return Event.base {
        pollFn = function()
            filterResumed(chan.recvq)
            return #chan.recvq ~= 0
        end,
        doFn = function()
            filterResumed(chan.recvq)
            local item = table.remove(chan.recvq, 1)
            if item then
                item.resume(value, item.wrap)
                return true, nil, function(x) return x end
            else
                return false
            end
        end,
        blockFn = function(resume, wrap)
            if resume.resumed then return end
            filterResumed(chan.recvq)
            local item = table.remove(chan.recvq, 1)
            if item then
                item.resume(value, item.wrap)
                resume(nil, wrap)
            else
                filterResumed(chan.sendq)
                table.insert(chan.sendq, {
                        resume = resume,
                        wrap = wrap,
                        value = value
                    })
            end
        end
    }
end

-- send : 'a chan * 'a -> unit
function M.send(chan, value)
    return Event.sync(M.sendEvt(chan, value))
end

-- recv : 'a chan -> 'a
function M.recv(chan)
    return Event.sync(M.recvEvt(chan))
end


return M
