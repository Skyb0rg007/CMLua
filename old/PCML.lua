-- Primitive CML

local Scheduler = {}
do
    -- task_queue : (unit -> unit) list
    local task_queue = {}

    -- pause : unit -> unit
    -- Pause the current coroutine so that other threads can run
    function Scheduler.pause()
        local co = coroutine.running()
        table.insert(task_queue, function()
            assert(coroutine.resume(co))
        end)
        coroutine.yield()
    end

    local resume_meta = {
        __tostring = function(self)
            return string.format('Resume { .resumed = %s }', self.resumed)
        end,
        __call = function(self, ...)
            assert(not self.resumed, 'Attempted to resume suspended thread twice!')
            local co = self.co
            local args = { ... }
            self.resumed = true
            self.co = nil
            table.insert(task_queue, 1, function()
                assert(coroutine.resume(co, table.unpack(args)))
            end)
        end
    }

    function Scheduler.is_resume(x)
        return getmetatable(x) == resume_meta
    end

    -- suspend : (('a -> unit) -> unit) -> 'a
    -- Suspend the current coroutine
    -- In a non-coroutine context, call the callback
    -- The callback is passed a resume object which re-queues the suspended coroutine when called
    -- One can query whether the resume object has been called via resume.resumed field
    function Scheduler.suspend(callback)
        local co = coroutine.running()
        local resume = setmetatable({ resumed = false, co = co }, resume_meta)
        table.insert(task_queue, 1, function()
            callback(resume)
        end)
        return coroutine.yield()
    end

    -- spawn : (unit -> unit) -> unit
    -- Spawn a thread. It begins running at the next cycle.
    function Scheduler.spawn(f)
        local co = coroutine.create(f)
        table.insert(task_queue, function()
            assert(coroutine.resume(co))
        end)
    end

    -- exit : unit -> unit
    -- Exit the CML system
    function Scheduler.exit()
        task_queue = {}
        coroutine.yield()
    end

    -- run : (unit -> unit) -> void
    -- Run a CML program. This function doesn't return;
    -- call Scheduler.exit() to stop
    function Scheduler.run(main)
        Scheduler.spawn(main)
        local task = table.remove(task_queue, 1)
        while task do
            task()
            task = table.remove(task_queue, 1)
        end
    end
end

local Event = {}
do
    local event_meta = {
        __tostring = function(self)
            return self.name or '<Event>'
        end
    }

    function Event.is_event(x)
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
    function Event.base(t)
        t.tag = 'BASE'
        t.name = t.name or '<BaseEvent>'
        return setmetatable(t, event_meta)
    end

    -- never : 'a event
    -- An event that never synchonizes
    Event.never = setmetatable({
            tag = 'BASE',
            name = 'never',
            pollFn = function() return false end,
            doFn = function() error('Event.never.doFn was called!', 2) end,
            blockFn = function(cont, wrap) end
        }, event_meta)

    -- always : 'a -> 'a event
    -- An event that always synchronizes with the given value
    function Event.always(x)
        return setmetatable({
                tag = 'BASE',
                name = string.format('always(%s)', tostring(x)),
                pollFn = function() return true end,
                doFn = function() return true, x, function(x) return x end end,
                blockFn = function() error('Event.always.blockFn was called!', 2) end
            }, event_meta)
    end

    -- choose : 'a event * 'a event -> 'a event
    -- An event that synchronizes one of the two events
    function Event.choose(a, b)
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
    function Event.wrap(evt, f)
        if evt.tag == 'BASE' then
            return Event.base {
                name = string.format('wrap(%s, %s)', evt.name, tostring(f)),
                pollFn = evt.pollFn,
                doFn = function()
                    local ok, ret, wrap = evt.doFn()
                    if ok then
                        return true, ret, function(x) return wrap(f(x)) end
                    else
                        return false
                    end
                end,
                blockFn = function(cont, wrap)
                    evt.blockFn(cont, function(x) return wrap(f(x)) end)
                end
            }
        else
            assert(evt.tag == 'CHOOSE')
            return Event.choose(Event.wrap(evt[1], f), Event.wrap(evt[2], f))
        end
    end

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
    -- Synchronize an event
    function Event.sync(evt)
        return Scheduler.suspend(function(returnK)
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
            Scheduler.spawn(function()
                local ret, wrap = Scheduler.suspend(function(resume)
                    visit(evt, function(base_evt)
                        if resume.resumed then return end
                        base_evt.blockFn(resume, function(x) return x end)
                    end)
                end)
                returnK(wrap(ret))
            end)
        end)
    end
end

local CVar = {}
do
    local cvar_meta = {
        __tostring = function(self)
            return string.format('CVar { .set = %s }', tostring(self.set))
        end
    }

    function CVar.is_cvar(x)
        return getmetatable(x) == cvar_meta
    end

    -- cvar : unit -> cvar
    -- Construct a condition variable
    function CVar.cvar()
        return setmetatable({ set = false, waiting = {} }, cvar_meta)
    end

    -- cvar_set : cvar -> unit
    -- Set an unset condition variable
    function CVar.cvar_set(cvar)
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

    -- cvar_waitEvt : cvar -> unit event
    -- Event that synchonizes when the cvar is set
    function CVar.cvar_waitEvt(cvar)
        return Event.base {
            name = 'CVar.cvar_waitEvt',
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
end

local Chan = {}
do
    local chan_meta = {
        __tostring = function(self)
            return 'Chan'
        end,
        __metatable = false
    }

    function Chan.is_chan(x)
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
    function Chan.channel()
        return setmetatable({ sendq = {}, recvq = {} }, chan_meta)
    end

    -- recvEvt : 'a chan -> 'a event
    function Chan.recvEvt(chan)
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
    function Chan.sendEvt(chan, value)
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
    function Chan.send(chan, value)
        return Event.sync(Chan.sendEvt(chan, value))
    end

    -- recv : 'a chan -> 'a
    function Chan.recv(chan)
        return Event.sync(Chan.recvEvt(chan))
    end
end

local CML = {}
for _, mod in ipairs({ Scheduler, Event, CVar, Chan }) do
    for k, v in pairs(mod) do
        CML[k] = v
    end
end

return CML

