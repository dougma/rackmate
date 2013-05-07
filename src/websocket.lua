local c = require'websocket.c'
local ipairs, table, string, print, type, require, pairs, WebSocketClient = ipairs, table, string, print, type, require, pairs, WebSocketClient
local JSON = require'JSON'
local _ = require'underscore'
-- because LUA arrays are the same as LUA tables, this sets a flag so that
-- if/when we re-encode the types are (for sure) preserved.
JSON.strictTypes = true

module(...)

clients = {}

function bind()
   c.bind()
end

local function send_json(sock, data)
   data = JSON:encode(data)
   sock:write(c.frame_header(#data)..data)
end

function broadcast(data)
   data = JSON:encode(data)
   data = c.frame_header(#data)..data
   for i, client in ipairs(clients) do
      client:write(data)
   end
end

local function handle_message(sock, rawdata, callback)
   local json = JSON:decode(c.unmask(rawdata))
   if type(json) == 'string' then
      callback(json, nil, function(data)
         send_json(sock, data)
      end)
   else
      for method, data in pairs(json) do
         if method ~= 'callbackId' then
            callback(method, data, function(data)
               data.callbackId = json.callbackId
               send_json(sock, data)
            end)
         end
      end
   end
end

function listen(callbacks)
   c.listen()
   repeat until c.select(function(sock, handshake)
      local key = _.chain(handshake):split("\r\n"):map(function(line)
         return _.split(line, ':')
      end):find(function(parts)
         return parts[1] == 'Sec-WebSocket-Key'
      end):value()[2]:trim()

      key = c.sha1base64(key..'258EAFA5-E914-47DA-95CA-C5AB0DC85B11')

      sock:write("HTTP/1.1 101 Web Socket Protocol Handshake\r\n"..
                 "Upgrade: websocket\r\n"..
                 "Connection: Upgrade\r\n"..
                 "Sec-WebSocket-Accept: "..key.."\r\n\r\n")

      clients[sock.sockfd] = sock; --TODO do in the C

      send_json(sock, callbacks.onconnect())
   end,
   function(sock)
      opcode, N = sock:read_header()
      if opcode == 1 or opcode == 2 then
         if N == 126 then
            N = c.ntohs(sock:read(2))
         elseif N == 127 then
            N = c.ntohll(sock:read(8))
         end
         handle_message(sock, sock:read(N + 4), callbacks.onmessage)
      elseif opcode == 8 then --CLOSE
         sock:write(string.char(0x88)..sock:read(N + 4):sub(1, 2))
         sock:close()
      elseif opcode == 9 then --PING
         local data = c.unmask(sock:read(N + 4))
         sock:write(string.char(0x8a)..c.frame_header(#data)..data)
      end
   end)
end
