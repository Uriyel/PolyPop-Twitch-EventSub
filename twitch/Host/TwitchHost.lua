require "util"
require "fetch"


client_id = "hawpk393w7ctms9j5ex5jie3142yy0"
twitch_scope = "chat:read+channel:read:stream_key+user:read:email+channel:read:subscriptions+channel:read:redemptions+channel:manage:redemptions+bits:read+channel:edit:commercial+moderator:read:chatters+moderator:read:followers+moderation:read+channel:read:vips"

Instance.host = nil
Instance.isAuthenticating = false
Instance.access_token = ""
Instance.userinfo = {
	id = 0,
	login = nil,
	broadcaster_type = nil
}
-- Emitted when we have login details
Instance.emitStatusUpdate = event("onStatusUpdate")

function Instance:onInit()
	self.host = getNetwork():getHost("api.twitch.tv")
	self.host:setName("Twitch")
	self.host.twitch = self
	self.host:setRateLimiterMode("TimeWindowWithSteadyState", "Global")
	self.host:setRequiresAuthentication(true)
	self.host:addEventListener("onAuthenticateRequest()", self, self.onAuthenticateRequest)
	self.host:addEventListener("onUnauthorizedRequest()", self, self.onUnauthorizedRequest)
	self.host:addEventListener("onRequestOAuthToken()", self, self.onRequestOAuthToken)
	self.host:addEventListener("onRevokeOAuthToken()", self, self.onRevokeOAuthToken)

	local cached_scope = self.host:readHostCache("scope", "")
	if (cached_scope == twitch_scope) then
		self.access_token = self.host:readHostCache("access_token", "")
	end
		
	if (self.access_token ~= "") then
		self:setAsAuthorized(true)
	else
		self:setAsAuthorized(false)
	end

	local button_img = getEditor():createNewFromFile(self:getObjectKit(), "Static2DTexture", getLocalFolder() .. "TwitchSignIn.png")
	self:addCast(button_img)

end

function Instance:updateUtilities()

	local utilStreamInfo = self:getObjectKit():findObjectByName("Edit Twitch Stream Info")
	local utilStartCommercial = self:getObjectKit():findObjectByName("Start Twitch Commercial")

	if (self:isUserLoggedIn()) then

		if (not utilStreamInfo) then
			getEditor():createUIX(self:getObjectKit(), "Edit Twitch Stream Info")
		end
		if (not utilStartCommercial and self:getUserInfo().broadcaster_type ~= "") then
			getEditor():createUIX(self:getObjectKit(), "Start Twitch Commercial")
		end
	
	else
		if (not self.isAuthenticating) then
			if (utilStreamInfo) then
				getEditor():removeFromLibrary(utilStreamInfo)
			end
			if (utilStartCommercial) then
				getEditor():removeFromLibrary(utilStartCommercial)
			end
		end
	end

end


function Instance:getUserInfo()
	return self.userinfo
end

function Instance:isUserLoggedIn()
	if (self.userinfo.id == 0) then
		return false
	else
		return true
	end
end

function Instance:setAsAuthorized(bAuthorized)
	self.host:setAsAuthorized(bAuthorized)
	
	if (not bAuthorized) then
		self:_WsReset()
		self:_ChatReset()
		self.userinfo.id = 0
		self.userinfo.login = nil
		self:emitStatusUpdate()
		self:updateUtilities()	
	else

		fetch(self, self.host, "/helix/users"):next(jsonify):next(
			function(obj)
				self.userinfo.id = obj["data"][1].id
				self.userinfo.login = obj["data"][1].login
				self.userinfo.broadcaster_type = obj["data"][1].broadcaster_type
				self:emitStatusUpdate()
				self:updateUtilities()	
			end
		)

	end

end

function Instance:onAuthenticateRequest(http)

	if (not self.host:isAuthorized()) then
		http:setAuthenticated(false)
		return
	end
	
--	http:clearRequestHeaders()
	http:addRequestHeader("Client-ID: " .. client_id)
	http:addRequestHeader("Authorization: Bearer " .. self.access_token)
	http:setAuthenticated(true)
end

function Instance:tryRefreshToken()
	
	if (self.isAuthenticating) then
		return
	end

	local refresh_token = self.host:readHostCache("refresh_token", "")
	if (refresh_token) then
		log("[OAuth] Refreshing Token")
		self.isAuthenticating = true
		self.host:refreshOAuthToken("twitch", refresh_token, self, self.onOAuthToken)
	end	

	self:setAsAuthorized(false)

end

function Instance:onUnauthorizedRequest()
	self:tryRefreshToken()
end

function Instance:onRequestOAuthToken()

	self.isAuthenticating = true

	local strState = generateGUID()
	local strURL = "https://id.twitch.tv/oauth2/authorize?client_id=" .. client_id .. "&redirect_uri=https://oauth.polypoplive.com/twitch.php&state=" .. strState .. "&response_type=code&scope=" .. twitch_scope .. "&force_verify=true"

	self.host:requestOAuthToken(strURL, strState, self, self.onOAuthToken)

end

function Instance:onOAuthToken(response)

	self.isAuthenticating = false

	local obj = json.decode(response)
	if (obj and type(obj["access_token"]) == "string") then

		self.access_token = obj["access_token"]
		self.host:writeHostCache("access_token", self.access_token)
		self.host:writeHostCache("scope", twitch_scope)

		if (type(obj["refresh_token"]) == "string") then
			self.host:writeHostCache("refresh_token", obj["refresh_token"])
		end

		log("[OAuth] Token acquired")
		self:setAsAuthorized(true)
	end

end

function Instance:onRevokeOAuthToken()

	local id_host = getNetwork():getHost("id.twitch.tv")
	id_host:setRateLimiterMode("TimeWindowWithSteadyState", "Global")
	id_host:setAsAuthorized(true)
	
	fetch(self, id_host, "/oauth2/revoke", {
		body="client_id=" .. client_id .. "&token=" .. self.access_token
	}):next(function(resp)
		log("[OAuth] Token revoked")
	end)

	self:setAsAuthorized(false)
	self.host:deleteHostCache()

end

--------------------------------------------------------------------------------
-- EventSub stuff       
--------------------------------------------------------------------------------

Instance.tblEventSubListen = {}
Instance.EventSubWebSocket = nil
Instance.broadcaster_id = nil

function Instance:eventSubListen(topic, user_id, inst, fn)

	self.broadcaster_id = user_id

	-- Gets list of current subscriptions
	--[[log("[EventSub] Getting list of current subscriptions")
	fetch(self, self.host, "/helix/eventsub/subscriptions",
		{
			method="GET",
			headers={'Content-Type: application/json', 'Client-ID: '.. client_id, 'Authorization: Bearer '.. self.access_token}
		}):next(jsonify):next(function (obj)
			log("[EventSub] Parse this list for an existing session id: " .. json.encode(obj))
		end) ]]--
	
	-- Twitch Discord says it isn't necessary to manually remove disconnected sessions
	
	-- Skip if we already have this topic
	if (self.tblEventSubListen[topic]) then
		return
	end

	self.tblEventSubListen[topic] = { inst=inst, fn=fn }




	if (not self.EventSubWebSocket) then
		log("[EventSub] Connecting")
		self:_eventSubConnect()		-- Connect on first listen
	elseif (self.EventSubWebSocket:isConnected()) then
		log("[EventSub] Sending Sub Request")
		-- This condition can probably be removed, but I'm leaving it in for now.
		-- WebSocket can't be reconnected to unless explicitly receiving a reconnect message, so a new connection will be made
		-- each time Polypop is restarted.
		-- self.EventSubWebSocket:send('{ "type":"' .. topic .. '", "version": "2", "condition":{"broadcaster_user_id":' .. self.broadcaster_id .. '}, "transport": { "method": "websocket" }}')
	end
	
end


function Instance:_eventSubConnect()
	log("[EventSub] Opening websocket")
	self.EventSubWebSocket = self.host:openWebSocket("wss://eventsub.wss.twitch.tv/ws")
	self.EventSubWebSocket:setAutoReconnect(true)
	self.EventSubWebSocket:addEventListener("onConnected", self, self._eventSubConnected)
	self.EventSubWebSocket:addEventListener("onDisconnected", self, self._eventSubDisconnected)
	self.EventSubWebSocket:addEventListener("onMessage", self, self._eventSubMessage)
end	

function Instance:_eventSubConnected()
		
	log("[EventSub] Websocket connected")
	-- log("[EventSub] broadcaster id: ".. )

	-- log("[EventSub] We need to handle the response here.")
	if (self.eventSubSessionId) then
		log("[EventSub] Session ID: ".. self.eventSubSessionId)
	else
		log("[EventSub] Session ID not yet available.")
	end  
		
	-- self:_eventSubCreatePingTimer()

end

function Instance:_eventSubCreatePingTimer()
	getAnimator():createTimer(self, self._eventSubPingServer, seconds(60*(4.5+math.random()*0.4)))
end

function Instance:_eventSubPingServer()
	log("[EventSub] Pinging Twitch")
	self.EventSubWebSocket:send('{ "type":"PING" }')
	getAnimator():createTimer(self, self._eventSubReconnect, seconds(10))
end

function Instance:_eventSubReconnect(reconnect_url)
	log("[EventSub] Attempting to reconnect")
	self.EventSubWebSocket:reconnect('{ "reconnect":'.. reconnect_url..'}')
end

function Instance:_eventSubMessage(msg)
	
	local obj, decodeError = json.decode(msg)

	if obj then
		
		if obj.metadata.message_type == "session_welcome" then
			log("[EventSub] Session welcome received")
			-- Access the session ID from the payload
			self.eventSubSessionId = obj.payload.session.id
						
			-- log("[EventSub] sending Fetch with Session ID: ".. self.eventSubSessionId)
			fetch(self, self.host, "/helix/eventsub/subscriptions", 
			{
				method="POST",
				headers={'Content-Type: application/json', 'Client-ID: '.. client_id, 'Authorization: Bearer '.. self.access_token},
				body = json.encode({
					type="channel.follow",
					version="2",
					condition={
						broadcaster_user_id=self.broadcaster_id,
						moderator_user_id=self.broadcaster_id,
					},
					transport={
						method="websocket",
						session_id=self.eventSubSessionId
					}
				})
			}):next(jsonify)

		elseif obj.metadata.message_type == "notification" then
			log("[EventSub] Notification received")
			-- log("[EventSub] Notification payload: ".. json.encode(obj.payload))

			local elem = self.tblEventSubListen[obj.payload.subscription.type]
			
			if (elem) then
				-- log("[EventSub] Calling Alert Function with payload: ".. json.encode(obj.payload.event))
				elem.fn(elem.inst, json.encode(obj.payload.event))
			end

			self.newFollower = obj.payload.event.user_name
			-- log("[EventSub] Follower: ".. self.newFollower)
		
			
		elseif obj.metadata.message_type == "reconnect" then
			log("[EventSub] Reconnect received")
			local reconnect_url = obj.payload.session.reconnect_url
			self._eventSubReconnect(reconnect_url)
		else
			-- log("[EventSub] Message type is not a welcome: " .. obj.metadata.message_type)
		end
	else
		log("[EventSub] Error decoding message: " .. decodeError)
	end

end

function Instance:_eventSubDisconnected()
	getAnimator():stopTimer(self, self._eventSubPingServer)
	getAnimator():stopTimer(self, self._eventSubReconnect)
end

function Instance:_eventSubReset()

	if (exists(self.EventSubWebSocket)) then
		log("[EventSub] Closing EventSub websocket")
		self.EventSubWebSocket:removeEventListener("onConnected", self, self._eventSubConnected)
		self.EventSubWebSocket:removeEventListener("onDisconnected", self, self._eventSubDisconnected)
		self.EventSubWebSocket:removeEventListener("onMessage", self, self._eventSubMessage)
		self.EventSubWebSocket:disconnect()
		self:_onEventSubDisconnected()
	end
	self.EventTblListen = {}
	self.EventSubWebSocket = nil

end






--------------------------------------------------------------------------------
-- PubSub stuff
--------------------------------------------------------------------------------

Instance.tblListen = {}
Instance.webSocket = nil


function Instance:pubSubListen(topic, inst, fn)

	-- Skip if already listening
	-- We presume only one user of this host for now
	if (self.tblListen[topic]) then
		return
	end

	self.tblListen[topic] = { inst=inst, fn=fn }

	if (not self.webSocket) then
		self:_WsConnect()		-- Connect on first listen
	elseif (self.webSocket:isConnected()) then
		self.webSocket:send('{ "type":"LISTEN", "data": { "topics": ["' .. topic .. '"], "auth_token": "' .. self.access_token .. '" } }')
	end
	
end

function Instance:pubSubUnlistenAll()

	if (self.webSocket and self.webSocket:isConnected()) then
		for k,v in pairs(self.tblListen) do
			self.webSocket:send('{ "type":"UNLISTEN", "data": { "topics": ["' .. k .. '"], "auth_token": "' .. self.access_token .. '" } }')
		end
	end

	self.tblListen = {}
	self:_WsReset()

end

function Instance:_WsConnect()
	log("[PubSub] Opening websocket")

	self.webSocket = self.host:openWebSocket("wss://pubsub-edge.twitch.tv")
	self.webSocket:setAutoReconnect(true)
	self.webSocket:addEventListener("onConnected", self, self._onWsConnected)
	self.webSocket:addEventListener("onDisconnected", self, self._onWsDisconnected)
	self.webSocket:addEventListener("onMessage", self, self._onWsMessage)


end

function Instance:_onWsConnected()
	log("[PubSub] Websocket connected")
		
	-- Connect to all listen
	local topics = ""
	for k,v in pairs(self.tblListen) do
		if (topics ~= "") then
			topics = topics .. ","
		end
		topics = topics .. '"' .. k .. '"'
	end

	self.webSocket:send('{ "type":"LISTEN", "data": { "topics": [' .. topics .. '], "auth_token": "' .. self.access_token .. '" } }')
	self:_WsCreatePingTimer()

end


function Instance:_WsCreatePingTimer()
	getAnimator():createTimer(self, self._WsPingServer, seconds(60*(4.5+math.random()*0.4)))
end

function Instance:_WsPingServer()
	log("[PubSub] Pinging Twitch")
	self.webSocket:send('{ "type":"PING" }')
	getAnimator():createTimer(self, self._WsReconnect, seconds(10))
end

function Instance:_WsReconnect()
	log("[PubSub] No ping response, reconnecting")
	self.webSocket:reconnect()
end

function Instance:_onWsMessage(msg)

	local obj = json.decode(msg)

	if (obj.type == "PONG") then
		log("[PubSub] Twitch responded to PING")
		getAnimator():stopTimer(self, self._WsReconnect)
		self:_WsCreatePingTimer()
	elseif (obj.type == "RECONNECT") then
		log("[PubSub] Twitch requiring Reconnect")
		self:_WsReconnect()
	elseif (obj.type == "MESSAGE") then
		if (obj.data.topic) then
			local elem = self.tblListen[obj.data.topic]
			if (elem) then
				elem.fn(elem.inst, json.decode(obj.data.message))
			end
		end
	elseif (obj.type == "RESPONSE") then
		if (obj.error == "ERR_BADAUTH") then
			log("[PubSub] Bad OAuth")
			self:tryRefreshToken()
		end
	end
end

function Instance:_onWsDisconnected()
	getAnimator():stopTimer(self, self._WsPingServer)
	getAnimator():stopTimer(self, self._WsReconnect)
end

function Instance:_WsReset()

	if (exists(self.webSocket)) then
		log("[PubSub] Closing websocket")
		self.webSocket:removeEventListener("onConnected", self, self._onWsConnected)
		self.webSocket:removeEventListener("onDisconnected", self, self._onWsDisconnected)
		self.webSocket:removeEventListener("onMessage", self, self._onWsMessage)
		self.webSocket:disconnect()
		self:_onWsDisconnected()
	end
	self.tblListen = {}
	self.webSocket = nil

end

--------------------------------------------------------------------------------
-- Chat stuff
--------------------------------------------------------------------------------

Instance.tblChat = {}
Instance.chatWebSocket = nil
Instance.chatAuthorized = false

function Instance:_ChatConnect()

	log("[Chat] Opening websocket")
	self.chatWebSocket = self.host:openWebSocket("wss://irc-ws.chat.twitch.tv")
	self.chatWebSocket:setAutoReconnect(true)
	self.chatWebSocket:addEventListener("onConnected", self, self._onChatConnected)
	self.chatWebSocket:addEventListener("onDisconnected", self, self._onChatDisconnected)
	self.chatWebSocket:addEventListener("onMessage", self, self._onChatMessage)

end

function Instance:connectToChat(inst, fn)

	if (not self.chatWebSocket) then
		self:_ChatConnect()
	end

	self.tblChat[inst] = fn

end

function Instance:disconnectFromChat(inst)
	self.tblChat[inst] = nil
	if (#self.tblChat == 0) then
		self:_ChatReset()
	end
end

function Instance:_onChatDisconnected()
	log("[Chat] Disconnected")
	self.chatAuthorized = false
	getAnimator():stopTimer(self, self._ChatOnPingServer)
	getAnimator():stopTimer(self, self._ChatOnNoPongResponse)
end

function Instance:_onChatConnected()
	log("[Chat] Websocket connected")
	self.chatWebSocket:send("PASS oauth:" .. self.access_token .. "\r\n")
	self.chatWebSocket:send("NICK " .. self.userinfo.login:lower() .. "\r\n")
end

function Instance:handleChatAuthorization(msg)

	if (msg:find(":tmi.twitch.tv NOTICE * :Login authentication failed", 1, true)) then
		log("[Chat] Authentication failed")
		self:tryRefreshToken()
	elseif (msg:find(":tmi.twitch.tv 001", 1, true)) then
		log("[Chat] Authentication succeeded")
		self.chatWebSocket:send("CAP REQ :twitch.tv/tags\r\n")
		self.chatWebSocket:send("CAP REQ :twitch.tv/commands\r\n")
		self.chatWebSocket:send("JOIN #" .. self.userinfo.login:lower() .. "\r\n")
		self.chatAuthorized = true
		self:_ChatCreatePingServer()
	end

end

function Instance:_ChatCreatePingServer()
	getAnimator():createTimer(self, self._ChatOnPingServer, seconds(60*(4.5+math.random()*0.4)))
end

function Instance:_ChatOnPingServer()
	log("[Chat] Pinging Twitch")
	self.chatWebSocket:send("PING :tmi.twitch.tv\r\n\r\n")
	getAnimator():createTimer(self, self._ChatOnNoPongResponse, seconds(10))
end

function Instance:_ChatOnNoPongResponse()
	log("[Chat] No ping response, reconnecting...")
	self.chatWebSocket:reconnect()	
end

function Instance:handlePONG(msg)
	
	local cmd = ":tmi.twitch.tv PONG"
	if (msg:sub(1, #cmd) == cmd) then
		log("[Chat] Twitch replied with PONG")
		getAnimator():stopTimer(self, self._ChatOnNoPongResponse)
		self:_ChatCreatePingServer()
	end

end

function Instance:handlePING(msg)
    
 	if (msg:sub(1, 4) == "PING") then
		log("[Chat] Responding to Twitch PING")
		self.chatWebSocket:send("PONG" .. msg:sub(5))
        return true
    else
        return false
    end
      
end

function parseBadges(badge_str)

    local tblBadges = {}
	if (badge_str) then
		local badges = split(badge_str, ",")    
		
		for i=1, #badges do
			
			local t = split(badges[i], "/")  
			table.insert(tblBadges, t[1])
			-- Founders are also subscribers
			if (t[1] == "founder") then
				table.insert(tblBadges, "subscriber")
			end

		end
	end
	
    return tblBadges
    
end

function parseTaggedMsg(msg)

	local tblTags = split(msg, ";")

	local tags = {}
    for i=1,#tblTags do
    
        local tag = tblTags[i]    
        local tblTag = split(tag, "=")
        if(tblTag[1]=="badges") then
            tags[tblTag[1]] = parseBadges(tblTag[2])
        else
            tags[tblTag[1]] = tblTag[2]
        end
    end	

	return tags

end

function Instance:handlePRIVMSG(msg)

    local cmd = "PRIVMSG #" .. self.userinfo.login .. " :"
    local i = msg:find(cmd, 1, true)
    if (not i) then
        return false
    end 
    
    local tbl = {}  
    tbl.msg = msg:sub(i+#cmd)

    local iUserStart = msg:find(" :", 1, true)
    local iUserEnd = msg:find("!", iUserStart+2, 1, true)
    tbl.user = msg:sub(iUserStart+2, iUserEnd-1)
	tbl.tags = parseTaggedMsg(msg:sub(1,iUserStart-1))

	-- Dispatch messages
	for k,v in pairs(self.tblChat) do
		v(k, tbl)
	end

    return true
    
end


function Instance:handleUSERNOTICE(msg)

    local cmd = ":tmi.twitch.tv USERNOTICE #" .. self.userinfo.login
    local i = msg:find(cmd, 1, true)
    if (not i) then
        return false
    end 
    
    local tags = msg:sub(1,i-1)
    local tblTags = split(tags, ";")

	local tbl = {}
	tbl.tags = parseTaggedMsg(msg:sub(1,i-1))

	-- Dispatch messages
	for k,v in pairs(self.tblChat) do
		v(k, tbl)
	end

    return true
    
end

function Instance:_onChatMessage(msg)

	if (not self.chatAuthorized) then
		self:handleChatAuthorization(msg)
		return
	end

	if (self:handlePING(msg)) then
		return
	end

	if (self:handlePONG(msg)) then
		return
	end

	if (self:handlePRIVMSG(msg)) then
		return
	end
	
	if (self:handleUSERNOTICE(msg)) then
		return
	end

end

function Instance:_ChatReset()

	if (exists(self.chatWebSocket)) then
		log("[Chat] Closing websocket")
		self.chatWebSocket:removeEventListener("onConnected", self, self._onChatConnected)
		self.chatWebSocket:removeEventListener("onDisconnected", self, self._onChatDisconnected)
		self.chatWebSocket:removeEventListener("onMessage", self, self._onChatMessage)
		self.chatWebSocket:disconnect()
		self:_onChatDisconnected()
	end
	self.tblChat = {}
	self.chatWebSocket = nil

end

