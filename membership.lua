#!/usr/bin/env tarantool

local log = require('log')
local uri_tools = require('uri')
local json = require('json')
local fiber = require('fiber')
local checks = require('checks')
local socket = require('socket')
local msgpack = require('msgpack')

local opts = require('membership.options')
local events = require('membership.events')
local members = require('membership.members')

local _sock = nil
local _sync_trigger = fiber.cond()
local _ack_trigger = fiber.cond()
local _ack_cache = {}

local _resolve_cache = {}
local function resolve(uri)
    checks("string")
    
    local _cached = _resolve_cache[uri]
    if _cached then
        return unpack(_cached)
    end

    local parts = uri_tools.parse(uri)
    if not parts then
        return nil, nil, 'parse error'
    end

    local hosts = socket.getaddrinfo(parts.host, parts.service, {family='AF_INET', type='SOCK_DGRAM'})
    if hosts == nil or #hosts == 0 then
        return nil, nil, 'getaddrinfo failed'
    end

    local _cached = {hosts[1].host, hosts[1].port}
    _resolve_cache[uri] = _cached
    return unpack(_cached)
end

--
-- SEND FUNCTIONS
--

local function send_message(uri, msg_type, msg_data)
    checks("string", "string", "table")
    local host, port = resolve(uri)
    if not host then
        return false
    end

    local events_to_send = {}

    if members.get(uri) then
        local extra_event = events.get(uri) or {
            uri = uri,
            status = members.get(uri).status,
            incarnation = members.get(uri).incarnation,
            ttl = 1,
        }
        table.insert(events_to_send, events.pack(extra_event))
    end

    local extra_event = events.get(opts.advertise_uri) or {
        uri = opts.advertise_uri,
        status = opts.ALIVE,
        incarnation = members.myself().incarnation,
        payload = members.myself().payload,
        ttl = 1,
    }
    table.insert(events_to_send, events.pack(extra_event))

    for _, event in events.pairs() do
        if #events_to_send > opts.EVENT_PIGGYBACK_LIMIT then
            break
        end

        if event.uri == uri or event.uri == opts.advertise_uri then
            -- already packed
        else
            table.insert(events_to_send, events.pack(event))
        end
    end

    events.gc()

    local msg = msgpack.encode({opts.advertise_uri, msg_type, msg_data, events_to_send})
    local ret = _sock:sendto(host, port, msg)
    return ret and ret > 0
end

local function send_anti_entropy(uri, msg_type, remote_tbl)
    -- send to `uri` all local members that are not in `remote_tbl`
    checks("string", "string", "table")
    local host, port = resolve(uri)
    if not host then
        return false
    end

    local msg_data = {}
    for uri, member in members.pairs() do
        if events.should_overwrite(member, remote_tbl[uri]) then
            msg_data[uri] = {
                status = member.status,
                incarnation = member.incarnation,
                payload = member.payload,
            }
        end
    end

    local msg = msgpack.encode({opts.advertise_uri, msg_type, msg_data, {}})
    local ret = _sock:sendto(host, port, msg)
    return ret and ret > 0
end

--
-- RECEIVE FUNCTIONS
--

local function handle_message(msg)
    local msg, _ = msgpack.decode(msg)
    local sender_uri, msg_type, msg_data, new_events = unpack(msg)
    -- log.warn('FROM: %s', tostring(sender_uri))

    -- log.warn('Got: %s', json.encode(msgpack.decode(msg) or 'nothing'))
    for _, event in ipairs(new_events or {}) do
        local event = events.unpack(event)

        if event.uri == opts.advertise_uri then
            -- this is a rumor about ourselves
            local myself = members.myself()

            if event.status ~= opts.ALIVE and event.incarnation >= myself.incarnation then
                -- someone thinks that we are dead
                log.info('Refuting the rumor that we are dead')
                event.incarnation = event.incarnation + 1
                event.status = opts.ALIVE
                event.payload = myself.payload
                event.ttl = members.count()
            elseif event.incarnation > myself.incarnation then
                -- this branch can be called after quick restart
                -- when the member who PINGs us does not know we were dead
                -- so we increment incarnation and start spreading
                -- the rumor with our current payload
                
                event.ttl = members.count()
                event.incarnation = event.incarnation + 1
                event.payload = myself.payload
            end
        end

        events.handle(event)
    end

    if msg_type == 'PING' then
        if msg_data.dst == opts.advertise_uri then
            send_message(sender_uri, 'ACK', msg_data)
        elseif msg_data.dst ~= nil then
            -- forward
            send_message(msg_data.dst, 'PING', msg_data)
        else
            log.error('Message PING without destination uri')
        end
    elseif msg_type == 'ACK' then
        if msg_data.src == opts.advertise_uri then
            table.insert(_ack_cache, msg_data)
            _ack_trigger:broadcast()
        elseif msg_data.src ~= nil then
            -- forward
            send_message(msg_data.src, 'ACK', msg_data)
        else
            log.error('Message ACK without source uri')
        end
    elseif msg_type == 'SYNC_REQ' or msg_type == 'SYNC_ACK' then
        local remote_tbl = msg_data
        for uri, member in pairs(remote_tbl) do
            if events.should_overwrite(member, members.get(uri)) then
                events.generate(uri, member.status, member.incarnation, member.payload)
            end
        end
        if msg_type == 'SYNC_REQ' then
            send_anti_entropy(sender_uri, 'SYNC_ACK', msg_data)
        else
            _sync_trigger:broadcast()
        end
    elseif msg_type == 'LEAVE' then
        -- just handle the event
        -- do nothing more
    else
        log.error('Unknown message %s', msg_type)
    end
end

local function handle_message_loop()
    local sock = _sock
    while sock == _sock do
        if _sock:readable(opts.PROTOCOL_PERIOD_SECONDS) then
            local ok, err = xpcall(handle_message, debug.traceback, _sock:recvfrom())
            if not ok then
                log.error(err)
            end
        end
    end
end

--
-- PROTOCOL LOOP
--

local function wait_ack(uri, ts, timeout)
    local now
    local deadline = ts + timeout
    repeat
        now = fiber.time64()

        for _, ack in ipairs(_ack_cache) do
            if ack.dst == uri and ack.ts == ts then
                return true
            end
        end
    until (now >= deadline) or not _ack_trigger:wait(tonumber(deadline - now) / 1.0e6)

    return false
end

local function protocol_step()
    local loop_now = fiber.time64()

    -- expire suspected members
    local expiry = loop_now - opts.SUSPECT_TIMEOUT_SECONDS * 1.0e6
    for uri, member in members.pairs() do
        if member.status == opts.SUSPECT and member.timestamp < expiry then
            log.info('Suspected node timeout.')
            events.generate(uri, opts.DEAD)
        end
    end

    -- cleanup ack cache
    _ack_cache = {}

    -- prepare to send ping
    local uri = members.next_shuffled_uri()
    if uri == nil then
        return
    end

    local msg_data = {
        ts = loop_now,
        src = opts.advertise_uri,
        dst = uri,
    }

    -- try direct ping
    local ok = send_message(uri, 'PING', msg_data)
    if ok and wait_ack(uri, loop_now, opts.ACK_TIMEOUT_SECONDS * 1.0e6) then
        local member = members.get(uri)
        members.set(uri, member.status, member.incarnation)
        return
    else
        _resolve_cache[uri] = nil
    end
    if members.get(uri).status >= opts.DEAD then
        -- still dead, do nothing
        return
    end

    -- try indirect ping
    local through_uri_list = members.random_alive_uri_list(opts.NUM_FAILURE_DETECTION_SUBGROUPS, uri)
    for _, through_uri in ipairs(through_uri_list) do
        send_message(through_uri, 'PING', msg_data)
    end

    if wait_ack(uri, loop_now, opts.PROTOCOL_PERIOD_SECONDS * 1.0e6) then
        local member = members.get(uri)
        members.set(uri, member.status, member.incarnation)
        return
    elseif members.get(uri).status == opts.ALIVE then
        log.info("Couldn't reach node: %s", uri)
        events.generate(uri, opts.SUSPECT)
        return
    end
end

local function protocol_loop()
    local sock = _sock
    while sock == _sock do
        local t1 = fiber.time()
        local ok, res = xpcall(protocol_step, debug.traceback)

        if not ok then
            log.error(res)
        end

        local t2 = fiber.time()
        fiber.sleep(t1 + opts.PROTOCOL_PERIOD_SECONDS - t2)
    end
end

--
-- ANTI ENTROPY SYNC
--

local function wait_sync(uri, timeout)
    local now
    local deadline = ts + timeout
    repeat
        now = fiber.time64()

        for _, ack in ipairs(_ack_cache) do
            if ack.dst == uri and ack.ts == ts then
                return true
            end
        end
    until (now >= deadline) or not _ack_trigger:wait(tonumber(deadline - now) / 1.0e6)

    return false
end

local function anti_entropy_step()
    local uri = members.random_alive_uri_list(1)[1]
    if uri == nil then
        return false
    end

    send_anti_entropy(uri, 'SYNC_REQ', {})
    return _sync_trigger:wait(opts.PROTOCOL_PERIOD_SECONDS)
end

local function anti_entropy_loop()
    local sock = _sock
    while sock == _sock do
        local ok, res = xpcall(anti_entropy_step, debug.traceback)

        if not ok then
            log.error(res)
            fiber.sleep(opts.PROTOCOL_PERIOD_SECONDS)
        elseif not res then
            fiber.sleep(opts.PROTOCOL_PERIOD_SECONDS)
        else
            fiber.sleep(opts.ANTI_ENTROPY_PERIOD_SECONDS)
        end
    end
end

--
-- BASIC FUNCTIONS
--

local function init(advertise_host, port)
    checks("string", "number")

    _sock = socket('AF_INET', 'SOCK_DGRAM', 'udp')
    local ok, status, errno, errstr = _sock:bind('0.0.0.0', port)
    if not ok then
        log.error('%s: %s', status, errstr)
        error('Socket bind error')
    end
    _sock:nonblock(true)

    local advertise_uri = uri_tools.format({host = advertise_host, service = tostring(port)})
    opts.set_advertise_uri(advertise_uri)
    events.generate(advertise_uri, opts.ALIVE, 1, {})

    fiber.create(protocol_loop)
    fiber.create(handle_message_loop)
    fiber.create(anti_entropy_loop)
    return true
end

local function leave()
    -- First, we need to stop all fibers
    local sock = _sock
    _sock = nil

    -- Perform artificial events.generate() and instantly send it
    local event = events.pack({
        uri = opts.advertise_uri,
        status = opts.LEFT,
        incarnation = members.myself().incarnation,
        ttl = members.count(),
    })
    local msg = msgpack.encode({opts.advertise_uri, 'LEAVE', msgpack.NULL, {event}})
    for _, uri in ipairs(members.random_alive_uri_list(members.count())) do
        local host, port = resolve(uri)
        sock:sendto(host, port, msg)
    end
    
    sock:close()
    members.clear()
    events.clear()
    return true
end

function get_members()
    local ret = {}
    for uri, member in members.pairs() do
        ret[uri] = {
            uri = uri,
            status = opts.STATUS_NAMES[member.status] or tostring(member.status),
            payload = member.payload or {},
            incarnation = member.incarnation,
            timestamp = member.timestamp,
        }
    end
    return ret
end

local function get_myself()
    local myself = members.myself()
    return {
        uri = opts.advertise_uri,
        status = opts.STATUS_NAMES[myself.status] or tostring(myself.status),
        payload = myself.payload,
        incarnation = myself.incarnation,
        timestamp = myself.timestamp,
    }
end

local function add_member(uri)
    checks("string")
    local parts = uri_tools.parse(uri)
    if not parts then
        return nil, 'parse error'
    end

    local uri = uri_tools.format({host = parts.host, service = parts.service})
    local member = members.get(uri)
    local incarnation = nil
    if member and member.status == opts.LEFT then
        incarnation = member.incarnation + 1
    end
    
    events.generate(uri, opts.ALIVE, incarnation)

    return true
end

local function probe_uri(uri)
    checks("string")
    local parts = uri_tools.parse(uri)
    if not parts then
        return nil, 'parse error'
    end

    local uri = uri_tools.format({host = parts.host, service = parts.service})

    local loop_now = fiber.time64()
    local msg_data = {
        ts = loop_now,
        src = opts.advertise_uri,
        dst = uri,
    }

    local ok = send_message(uri, 'PING', msg_data)

    return ok and wait_ack(uri, loop_now, opts.ACK_TIMEOUT_SECONDS * 1.0e6)
end

local function set_payload(key, value)
    checks("string", "?")
    local myself = members.myself()
    local payload = myself.payload
    if payload[key] == value then
        return true
    end
    
    payload[key] = value
    events.generate(
        opts.advertise_uri,
        myself.status,
        myself.incarnation + 1,
        payload
    )
    return true
end

return {
    init = init,
    leave = leave,
    members = get_members,
    pairs = function() return pairs(get_members()) end,
    myself = get_myself,
    probe_uri = probe_uri,
    add_member = add_member,
    set_payload = set_payload,
}
