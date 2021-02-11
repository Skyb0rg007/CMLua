#!/usr/bin/env lua

-- local CML = require('PCML')
local CML = require('cml')

CML.run(function()
    local a, b, c = CML.channel(), CML.channel(), CML.channel()

    CML.spawn(function()
        while true do
            local z = CML.sync(CML.choose(
                    CML.wrap(CML.recvEvt(a),function(x)
                        local y = CML.recv(b)
                        return x + y
                    end),
                    CML.wrap(CML.recvEvt(b),function(y)
                        local x = CML.recv(a)
                        return x + y
                    end)
                ))
            CML.send(c, z)
        end
    end)
    CML.spawn(function()
        CML.send(b, 2)
    end)
    CML.spawn(function()
        CML.send(a, 1)
    end)
    CML.spawn(function()
        assert(1 + 2 == CML.recv(c))
        CML.exit()
    end)
end)

CML.run(function()
    local chan = CML.channel()

    local function named_fun(name, f)
        return setmetatable({}, {
                __tostring = function() return name end,
                __call = function(_, ...) return f(...) end
            })
    end

    CML.spawn(function()
        local counter = 0
        local mul10 = named_fun('mul10', function(n)
            assert(counter == 0)
            counter = counter + 1
            return n * 10
        end)
        local add10 = named_fun('add10', function(n)
            assert(counter == 1)
            counter = counter + 1
            return n + 10
        end)
        assert((123*10)+10 == CML.sync(CML.wrap(CML.wrap(CML.recvEvt(chan), mul10), add10)))
        assert(counter == 2)
        CML.exit()
    end)

    CML.spawn(function()
        CML.send(chan, 123)
    end)
end)
