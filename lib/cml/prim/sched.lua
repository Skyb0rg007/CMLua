
local M = {}

local task_queue = {}
local exit = false

-- pause : unit -> unit
function M.pause()
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

-- is_resume : 'a -> boolean
function M.is_resume(x)
    return getmetatable(x) == resume_meta
end

-- suspend : (('a -> unit) -> unit) -> 'a
function M.suspend(callback)
    local co = coroutine.running()
    local resume = setmetatable({ resumed = false, co = co }, resume_meta)
    table.insert(task_queue, 1, function()
        callback(resume)
    end)
    return coroutine.yield()
end

-- spawn : (unit -> unit) -> unit
function M.spawn(f)
    local co = coroutine.create(f)
    table.insert(task_queue, function()
        assert(coroutine.resume(co))
    end)
end

-- exit : unit -> unit
function M.exit()
    exit = true
    coroutine.yield()
end

-- run : (unit -> unit) -> void
function M.run(main)
    local tasks
    exit = false

    M.spawn(main)

    while true do
        tasks, task_queue = task_queue, {}
        for _, task in ipairs(tasks) do
            task()
            if exit then goto exit end
        end
        if exit then goto exit end
    end
    ::exit::
    task_queue = {}
end

return M
