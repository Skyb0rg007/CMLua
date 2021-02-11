
# CMLua

## A Lua concurrency framework

This library is a port of the ConcurrentML system.
Its implementation is interesting but not too complex, and I'll include a section
on its design when I get around to it.

### Why CMLua?

The ConcurrentML framework allows for easy design and extension of concurrent systems
through common synchonization primitives.

The API is presented here, albeit using ML a signature instead of Lua code

    signature CML =
    sig
        type 'a event
        type 'a chan
        type thread_id

        (* Threads *)
        val spawn : (unit -> unit) -> thread_id
        val exit : unit -> 'a
        val run : (unit -> unit) -> unit

        (* Channels *)
        val channel : unit -> 'a chan
        val recv : 'a chan -> 'a
        val send : 'a chan * 'a -> unit

        (* Channel and Thread Event api *)
        val recvEvt : 'a chan -> 'a event
        val sendEvt : 'a chan * 'a -> unit event
        val joinEvt : thread_id -> unit event

        (* Event combinators *)
        val sync : 'a event -> 'a
        val never : 'a event
        val always : 'a -> 'a event
        val choose : 'a event * 'a event -> 'a event
        val wrap : 'a event * ('a -> 'b) -> 'b event
        val guard : (unit -> 'a event) -> 'a event
        val withNack : (unit event -> 'a event) -> 'a event
    end

Each of these functions is implemented exactly as shown in Lua.
The `unit` type is `nil`, ML functions with tuple arguments are multi-argument
Lua functions. The `event` and `chan` types are objects with `__tostring` methods,
and can be compared for equality (delegates to table equality).

The official CML structure is *sleightly* different, so I will not simply link to it.
However there are a bunch of YouTube talks that explain it better than I could so
just watch those if my explanation is confusing.

### Tutorial/Motivation

Let's say you want to model an authentication server. This server may talk
to a backend hosted on some website, but you can access this server through Lua.

#### Attempt: Straight-forward code

For attempt 1, let's try the normal setup. The server interface may be:

    function auth(username, password_hash)
        -- call out to server, wait for a response, parse the response
        -- on success
        return auth_info
        -- on failure
        return false, reason
    end

    function login(username, password)
        local pw_hash = hash(password)
        local info = assert(auth(username, pw_hash))
        -- ...
    end

    function main()
        while true do
            local username, password = getline()
            login(username, password)
        end
    end

This works, however it doesn't scale to multiple concurrent users. If it takes
1 second for the server to respond, then 100 users trying to log in would take
100 seconds before the last user gets served.

#### Fixed: CMLua attempt 1

Using CMLua, we can fix this issue without changing the user code.

    function auth(username, password_hash)
        local curl_evt = cml_curl('http://www.website.com/endpoint?username=' .. username .. '&password=' .. password_hash)
        local parsed_evt = cml.wrap(curl_evt, function(response)
            -- parse
            if ok then
                return auth_info
            else
                return false, reason
            end
        end)
        return cml.sync(parsed_evt)
    end

    function login(username, password)
        local pw_hash = hash(password)
        local info = assert(auth(username, pw_hash))
        -- ...
    end

    function main()
        while true do
            local username, password = getline()
            cml.spawn(function()
                login(username, password)
            end)
        end
    end

Wait so what happened?

I'm assuming the `cml_curl` function takes a url, and returns a `response event` object.
This object is something that can be synchonized on.

The call to `cml.wrap` converts the event from returning responses to returning parsed data from the response,
just like the first attempt.

Finally, the call to `cml.sync` causes the calling thread to suspend itself until the
event resolves. This will happen once the `cml_curl` event does - when the server responds.
The `login` code doesn't have to change to deal with cml. The main function runs
each login attempt in its own thread, so when it one thread blocks on the server response
it can queue the others.

#### Fixed: CMLua attempt 2

What if we want to call out to two different authentication servers, and want to
log in using the first one that succeeds? We can use cml!

    -- auth1 : username * password_hash -> auth_info
    -- auth2 : username * password_hash -> auth_info
    function auth1(username, password_hash)
        -- Authenticate with server 1
    end
    function auth2(username, password_hash)
        -- Authenticate with server 1
    end

    function login(username, password)
        local pw_hash = hash(password)

        local info_chan = cml.channel()
        local tid1 = cml.spawn(function()
            local info, errmsg = auth1(username, password_hash)
            if info then cml.send(info_chan, info) end
        end)
        local tid2 = cml.spawn(function()
            local info, errmsg = auth2(username, password_hash)
            if info then cml.send(info_chan, info) end
            cml.sync(cml.joinEvt(tid1))
        end)

        local info, errmsg = cml.sync(cml.choice(
            cml.recvEvt(info_chan),
            cml.wrap(cml.joinEvt(tid2), function(_)
                return false, 'Neither authentication method worked'
            end)))
        ))
        -- ...
    end

    function main()
        while true do
            local username, password = getline()
            cml.spawn(function()
                login(username, password)
            end)
        end
    end

Here, we see the usage of channel communication.

