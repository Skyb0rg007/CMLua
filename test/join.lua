
local cml = require('cml')

cml.run(function()

    local chan = cml.channel()

    local tid1 = cml.spawn(function()
        print('Thread 1!')
        for i = 1, 10 do
            print('sending', i)
            cml.send(chan, i)
            print('sent', i)
        end
        -- cml.send(chan, nil)
    end)
    local tid2 = cml.spawn(function()
        print('Thread 2!')
        local x
        repeat
            x = cml.sync(cml.choose(
                    cml.recvEvt(chan),
                    cml.always(nil)
                ))
            -- x = cml.recv(chan)
            print('x', x)
        until not x
    end)
    cml.spawn(function()
        cml.sync(cml.joinEvt(tid1))
        cml.sync(cml.joinEvt(tid2))
        cml.exit()
    end)
end)

