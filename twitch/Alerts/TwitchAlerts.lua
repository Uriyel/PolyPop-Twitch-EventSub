require "polltimer"
require "requestqueue"
require "requestpool"

Instance.properties = properties({
	{ name="Stats", type="PropertyGroup", ui={expand=false}, items={
		{ name="UserName", type="Alert", args={name="[user_name]"} },
		{ name="FollowerCount", type="Alert", args={count=0} },
		{ name="SubscriberCount", type="Alert", args={total_sub_count=0, today_sub_count=0} },
		{ name="BitsTally", type="Alert", args={count=0} }
	}},
	{ name="Alerts", type="PropertyGroup", items={
		{ name="onNewFollower", type="Alert", args={ user_name="[user_name]", profile_url="[profile_url]" } },
		{ name="onChatMessage", type="Alert", args={ user_name="[user_name]", msg="[msg]"} },
		{ name="Subscriptions", type="PropertyGroup", items={
			{ name="onNewSubscription", type="Alert", args={ user_name="[user_name]", profile_url="[profile_url]", cumulative_months=0, streak_months=0 } },
			{ name="onReSubscription", type="Alert", args={ user_name="[user_name]", profile_url="[profile_url]", cumulative_months=0, streak_months=0 } },
			{ name="onGiftSubscription", type="Alert", args={ from_user_name="[from_user_name]", from_profile_url="[from_profile_url]", to_user_name="[to_user_name]", to_profile_url="[to_profile_url]", months=0 } },
			{ name="onRegiftSubscription", type="Alert", args={ from_user_name="[from_user_name]", from_profile_url="[from_profile_url]", to_user_name="[to_user_name]", to_profile_url="[to_profile_url]", months=0 } },
		}},
		{ name="Bits", type="PropertyGroup", items={
			{ name="GainAmount", type="Int", range={min=1}, units="bits", value=500 },
			{ name="onBitsGained", type="Alert", args={ gain_level=0 } },
		}},
		{ name="Raids", type="PropertyGroup", items={
			{ name="onCountdownStart", type="Alert", args={ user_name="[user_name]", profile_url="[profile_url]", seconds_remaining=90 } },
			{ name="onCountdownTick", type="Alert", args={ user_name="[user_name]", seconds_remaining=90 } },
			{ name="onGo", type="Alert", args={ user_name="[user_name]" } },
			{ name="onCancelled", type="Alert", args={ user_name="[user_name]"} },
			{ name="onIncomingRaid", type="Alert", args={ user_name="[user_name]", profile_url="[profile_url]", viewers=0 } }
		}}
	}},
	{ name="CheerAlerts", type="ObjectSet", index="CheerAlerts" },
	{ name="ChannelPoints", type="ObjectSet", index="ChannelPoints" },
	{ name="AppChannelPoints", type="ObjectSet", index="AppChannelPoints" },
	{ name="ChatAlerts", type="ObjectSet", index="ChatAlerts" },
})

Instance.host = nil
Instance.ptFollows = nil
Instance.ptSubscribers = nil
Instance.userID = nil
Instance.login = nil
Instance.total_subs = 0
Instance.today_subs = 0
Instance.bitsTally = 0
Instance.gainLevel = 0
Instance.rqViewers = nil
Instance.rqChatSubs = nil
Instance.rqSubs = nil
Instance.rqFollowers = nil
Instance.rqLeaderboards = {
	day={},
	week={},
	month={},
	year={},
	all={}
}
Instance.rpUserInfo = nil
Instance.bIsChatEnabled = false
Instance.tblNewFollowers = {}
Instance.texProfile = nil

function Instance:onInit(constructor_type)
	self.host = getNetwork():getHost("api.twitch.tv")
	self:addCast(self.host)

	self.texProfile = getEditor():createNew(self:getObjectKit(), "Remote2DTexture")
	self.texProfile:setName("Profile Image")

	self.ptFollows = polltimer(self, self.onPollFollowers, seconds(1))
	self.ptFollows:setEnabled(false)
	self.ptFollows:setDependencies({ self.host, self.properties.Stats.FollowerCount })

	self.ptSubscribers = polltimer(self, self.onPollSubscribers, seconds(1))
	self.ptSubscribers:setEnabled(false)
	self.ptSubscribers:setDependencies({ self.host, self.properties.Stats.SubscriberCount })

	self.rqViewers = requestqueue(self, function()
		self:requestUsers("viewer", self.rqViewers)
	end, self.host)
	self.rqViewers:setEnabled(false)

	self.rqMods = requestqueue(self, function()
		self:requestUsers("mod", self.rqMods)
	end, self.host)
	self.rqMods:setEnabled(false)

	self.rqVIPs = requestqueue(self, function()
		self:requestUsers("vip", self.rqVIPs)
	end, self.host)
	self.rqVIPs:setEnabled(false)

	self.rqChatSubs = requestqueue(self, self.onRequestChatSubs, self.host)
	self.rqChatSubs:setEnabled(false)

	self.rqSubs = requestqueue(self, self.onRequestSubs, self.host)
	self.rqSubs:setEnabled(false)

	self.rqFollowers  = requestqueue(self, self.onRequestFollowers, self.host)
	self.rqFollowers:setEnabled(false)

	for k,v in pairs(self.rqLeaderboards) do
		self.rqLeaderboards[k] = requestqueue(self, function()
			self:requestLeaderboards(k)
		end, self.host)
	end
	
	self.rpUserInfo = requestpool(self, self.onRequestUserInfo, self.host)

	self.host.twitch:addEventListener("onStatusUpdate", self, function(self)
		self:updateState()
	end)

	self:updateState()

--	if (constructor_type == "Default") then
--		getEditor():createUIX(self.properties.CheerAlerts:getKit(), "Cheer Level")
--	end

end

function Instance:findHighestCheerAlert(bits_used)

	local alert = nil	
	local highest_threshold = 0
	local kit = self.properties.CheerAlerts:getKit()
	for i=1, kit:getObjectCount() do
		local cheer = kit:getObjectByIndex(i)
		local threshold = cheer.properties.Threshold
		if (bits_used >= threshold and threshold > highest_threshold) then
			highest_threshold = threshold
			alert = cheer.properties.onCheer
		end
	end

	return alert

end

function Instance:accrueBits(bit_count)

	self.bitsTally = self.bitsTally + bit_count
	self.properties.Stats.BitsTally:raise({count=self.bitsTally})

	local newGainLevel = math.floor(self.bitsTally / self.properties.Alerts.Bits.GainAmount)
	for i=self.gainLevel+1, newGainLevel do
		self.properties.Alerts.Bits.onBitsGained:raise({gain_level=i})
	end
	self.gainLevel = newGainLevel

end

function Instance:onSimulateAlert(alert)

	local test_profile_url = "https://upload.wikimedia.org/wikipedia/commons/e/ed/Ara_macao_-on_a_small_bicycle-8.jpg"

	if (alert == self.properties.Alerts.Bits.onBitsGained) then

		local testBits = math.random(1,1000)
		self:accrueBits(testBits)
		print("(Test) Received " .. tostring(testBits) .. " bits. Total received " .. self.bitsTally, 213)

	elseif (alert == self.properties.Alerts.Subscriptions.onNewSubscription) then

		local test_user = "testuserPOP" .. tostring(math.random(100,100000))

		print("(Test) User " .. test_user .. " has subscribed", 213)
		self.properties.Alerts.Subscriptions.onNewSubscription:raise(
		{
			user_name=test_user,
			profile_url = test_profile_url,
			cumulative_months=math.random(1,100),
			streak_months=math.random(1,10)
		})	

	elseif (alert == self.properties.Alerts.Subscriptions.onReSubscription) then

		local test_user = "testuserPOP" .. tostring(math.random(100,100000))

		print("(Test) User " .. test_user .. " has resubscribed", 213)
		self.properties.Alerts.Subscriptions.onReSubscription:raise(
		{
			user_name=test_user,
			profile_url = test_profile_url,
			cumulative_months=math.random(1,100),
			streak_months=math.random(1,10)
		})	

	elseif (alert == self.properties.Alerts.Subscriptions.onGiftSubscription) then
		
		local from_test_user = "testuserPOP" .. tostring(math.random(100,100000))
		local to_test_user = "testuserPOP" .. tostring(math.random(100,100000))

		print("(Test) User " .. from_test_user .. " is gifting " .. to_test_user, 213)
		self.properties.Alerts.Subscriptions.onGiftSubscription:raise(
		{
			from_user_name=from_test_user,
			to_user_name=to_test_user,
			from_profile_url = test_profile_url,
			to_profile_url = "https://upload.wikimedia.org/wikipedia/commons/7/7e/Sunconurepuzzle.jpg",
			months=math.random(1,10)
		})	

	elseif (alert == self.properties.Alerts.Subscriptions.onRegiftSubscription) then
		
		local from_test_user = "testuserPOP" .. tostring(math.random(100,100000))
		local to_test_user = "testuserPOP" .. tostring(math.random(100,100000))

		print("(Test) User " .. from_test_user .. " is regifting " .. to_test_user, 213)
		self.properties.Alerts.Subscriptions.onRegiftSubscription:raise(
		{
			from_user_name=from_test_user,
			to_user_name=to_test_user,
			from_profile_url = test_profile_url,
			to_profile_url = "https://upload.wikimedia.org/wikipedia/commons/7/7e/Sunconurepuzzle.jpg",
			months=math.random(1,10)
		})	

	elseif (alert == self.properties.Alerts.onChatMessage) then
		self.properties.Alerts.onChatMessage:raise({user_name="testuser" .. tostring(math.random(100,1000)),msg="This is example chat message #" .. tostring(math.random(1,1000))})
	elseif (alert == self.properties.Alerts.onNewFollower) then

		local test_user = "testuserPOP" .. tostring(math.random(100,100000))

		print("(Test) User " .. test_user .. " is now following you", 213)
		self.properties.Alerts.onNewFollower:raise(
		{
			user_name=test_user,
			profile_url = test_profile_url,
		})	
		
	elseif (alert == self.properties.Alerts.Raids.onIncomingRaid) then
		local test_user = "testuserPOP" .. tostring(math.random(100,100000))
		self.properties.Alerts.Raids.onIncomingRaid:raise({user_name=test_user, profile_url=test_profile_url, viewers=math.random(10,1000)})
		print("(Test) User " .. test_user .. " is raiding you.", 324)

	elseif (alert == self.properties.Alerts.Raids.onCountdownStart) then
		local test_user = "testuserPOP" .. tostring(math.random(100,100000))

		print("(Test) User " .. test_user .. " being raided in 5 seconds", 324)
		
		local obj = {}
		obj.type = "raid_update_v2"
		obj.raid = {
			target_login=test_user,
			force_raid_now_seconds=6
		}
		self.isTestRaid = true
		self:onRaid(obj)
	elseif (alert == self.properties.Alerts.Raids.onGo or alert==self.properties.Alerts.Raids.onCountdownTick) then
		print("Use the 'on Countdown Start' alert to test.")
	elseif (alert == self.properties.Alerts.Raids.onCancelled) then
		
		if (not self.isTestRaid) then
			print("First, use the 'on Countdown Start' alert to start test.")
			return
		end

		local obj = {}
		obj.type = "raid_cancel_v2"
		obj.raid = {
			target_login=self.user_to_raid
		}
		self:onRaid(obj)
		self.isTestRaid = false
		print("(Test) Raid cancelled")
	else
		alert:raise(alert:getLastArgs())
	end

end

function Instance:onCheer(obj)

	local cheer_alert = self:findHighestCheerAlert(obj.data.bits_used)
	if (cheer_alert) then

		if (obj.data.is_anonymous) then
			obj.data.user_name = "Anonymous"
		end

		self:raiseAlertWithProfileUrl(cheer_alert, obj.data.user_name, {
			user_name=obj.data.user_name,
			chat_message=obj.data.chat_message,
			bits_used=obj.data.bits_used,
			total_bits_used=obj.data.total_bits_used,
		})

	end

	self:accrueBits(obj.data.bits_used)

end

function Instance:checkChannelPoints(kit, obj)

	for i=1, kit:getObjectCount() do
		local cp = kit:getObjectByIndex(i)

		local title
		if (cp.properties.CustomReward) then
			title = cp.properties.CustomReward
		else
			title = cp.properties.Title
		end

		if (title == obj.data.redemption.reward.title) then

			self:raiseAlertWithProfileUrl(cp.properties.onRedeemed, obj.data.redemption.user.login, {
				user_name=obj.data.redemption.user.login, 
				user_input=obj.data.redemption.user_input,
				reward_name=title
			})	

			return true
		end

	end

	return false

end

function Instance:onChannelPoints(obj)
	
	if (not self:checkChannelPoints(self.properties.ChannelPoints:getKit(), obj)) then
		self:checkChannelPoints(self.properties.AppChannelPoints:getKit(), obj)
	end

end

function Instance:onReset()

	if (self.bitsTally > 0) then
		self.bitsTally = 0
		self.gainLevel = 0
		self.properties.Stats.BitsTally:raise({count=0})
	end

	self.tblNewFollowers = {}

end

function Instance:onNewSubscription(obj)

	self.total_subs = self.total_subs + 1
	self.today_subs = self.today_subs + 1
	self.properties.Stats.SubscriberCount:raise({total_sub_count=self.total_subs, today_sub_count=self.today_subs})

	if (obj.context == "sub" or obj.context=="resub") then
		
		if (not obj.streak_months) then
			obj.streak_months = 0
		end

		local args = {
			user_name=obj.user_name,
			cumulative_months=obj.cumulative_months,
			streak_months=obj.streak_months
		}

		local alert
		if (obj.context == "sub") then
			alert = self.properties.Alerts.Subscriptions.onNewSubscription
		else 
			alert = self.properties.Alerts.Subscriptions.onReSubscription
		end

		self:raiseAlertWithProfileUrl(alert, obj.user_name, args)

	else

		if (not obj.user_name) then
			obj.user_name = "Anonymous"
		end

		local args = {
			from_user_name=obj.user_name,
			to_user_name=obj.recipient_user_name,
			months=obj.months,
		}

		local alert
		if (obj.context == "subgift" or obj.context == "anonsubgift") then
			alert = self.properties.Alerts.Subscriptions.onGiftSubscription
		else
			alert = self.properties.Alerts.Subscriptions.onRegiftSubscription
		end

		self:queryUserInfo(obj.user_name, function (info)
			if (info) then
				args.from_profile_url = info.profile_image_url
			end
			self:queryUserInfo(obj.recipient_user_name, function (info)
				if (info) then
					args.to_profile_url = info.profile_image_url
				end
				alert:raise(args)
			end)
		end)	

	end

end

function Instance:raiseAlertWithUsername(alert, args)
	-- Need to get args for the profile_url.
	-- Hoping the Query will work with live followers.
	alert:raise(args)
end

function Instance:raiseAlertWithProfileUrl(alert, user_name, args)

	self:queryUserInfo(user_name, function (info)
		if (info) then
			args.profile_url = info.profile_image_url
		end
		alert:raise(args)
	end)	

end

function Instance:raiseFollowAlertWithProfileUrl(alert, user_name, args)
	
	-- Attempting new method to fetch the profile image.
	-- fetch() isn't forming the proper URL for this request.  Need to append args.
	
	fetch(self, self.host, "/helix/users", {
		login = user_name
	}):next(jsonify):next(function(obj)

		if (obj.data) then
			
			log("[EventSub] We got Data back!")
			args.profile_url = obj.data[1].profile_image_url
			args.user_name = obj.data[1].display_name
			
			log("[EventSub] user: " .. args.user_name .. " profile_url: " .. args.profile_url)
			
			self.properties.Alerts.onNewFollower:raise(
				{
					user_name=args.user_name,
					profile_url = args.profile_url,
				})	

		end
	end)
		
end


function Instance:onNewEventFollower(obj)

	-- The decode and username assignment is a bit messy.
	-- I was getting errors about a table being expected.
	-- Maybe revisit to clean it up.	
	 
	local obj = json.decode(obj)

	--log("[EventSub] New Follower triggered " .. obj['user_name'])
	
	-- local username = obj['user_name']

	-- Query is run on the user name when function is called
	-- but doesn't work with the Twitch CLI server simulation.
	-- log("[EventSub] Attempting to query user info: " .. obj['user_name'])
	self:raiseFollowAlertWithProfileUrl(self.properties.Alerts.onNewFollower, obj['user_name'], {
		user_name=obj['user_name']
	})
end

function Instance:onNewFollower(obj)

	log("[OLD PubSub] Follower triggered " 
)

	-- Suppress re-follows during this session
	if (self.tblNewFollowers[obj.username]) then
		return
	end
	self.tblNewFollowers[obj.username] = true

	self:raiseAlertWithProfileUrl(self.properties.Alerts.onNewFollower, obj.username, {
		user_name=obj.username
	})

end

Instance.user_to_raid = nil
Instance.raidSecsToGo = seconds(0)
Instance.isTestRaid = false

function Instance:onRaidCountdown()
	self.raidSecsToGo = self.raidSecsToGo - 1

	self.properties.Alerts.Raids.onCountdownTick:raise(
	{
		user_name=self.user_to_raid,
		seconds_remaining=self.raidSecsToGo
	})

	if (self.raidSecsToGo <= 0) then
		getAnimator():stopTimer(self, self.onRaidCountdown)
	
		if (self.isTestRaid) then
			
			print("(Test) User " .. self.user_to_raid .. " raided", 324)

			local obj = {}
			obj.type = "raid_go_v2"
			obj.raid = {
				target_login=self.user_to_raid
			}

			self:onRaid(obj)
			self.isTestRaid = false

		end

	end

	if (self.isTestRaid) then
		print("(Test) User " .. self.user_to_raid .. " being raided in " .. tostring(self.raidSecsToGo) .. " seconds", 324)
	end

end

function Instance:onRaid(obj)

	if (obj.type == "raid_update_v2") then

		if (obj.raid.target_login ~= self.user_to_raid) then
			self.user_to_raid = obj.raid.target_login
			local timeToGo = tonumber(obj.raid.force_raid_now_seconds)
			self.raidSecsToGo = timeToGo - 1
			getAnimator():createTimer(self, self.onRaidCountdown, seconds(1), true)

			self:raiseAlertWithProfileUrl(self.properties.Alerts.Raids.onCountdownStart, obj.raid.target_login, {
				user_name=obj.raid.target_login,
				seconds_remaining=timeToGo
			})

		end

	elseif (obj.type == "raid_go_v2") then
	
		if (obj.raid.target_login == self.user_to_raid) then
	
			getAnimator():stopTimer(self, self.onRaidCountdown)

			self.properties.Alerts.Raids.onGo:raise(
			{
				user_name=obj.raid.target_login
			})
			
			self.user_to_raid = nil

		end

	elseif (obj.type == "raid_cancel_v2") then

		if (obj.raid.target_login == self.user_to_raid) then
			getAnimator():stopTimer(self, self.onRaidCountdown)

			self.properties.Alerts.Raids.onCancelled:raise(
			{
				user_name=obj.raid.target_login
			})
		
			self.user_to_raid = nil
		end

	end

end

function Instance:updateState()

	if (self.host.twitch:isUserLoggedIn()) then
		local ui = self.host.twitch:getUserInfo()
		self:setUserID(ui.id, ui.login)
	else
		self:setUserID(nil)
	end

end

function Instance:onDelete()
	self:setUserID(nil)
end

Instance.emitLoginStatusUpdate = event("onLoginInStatusUpdate")

function Instance:isLoggedIn() 
	if (self.userID ~= nil) then
		return true
	else
		return false
	end
end

function Instance:setUserID(user_id, login)
	if (user_id == self.userID) then
		return
	end

	local last_user_id = self.userID

	self.userID = user_id
	self.login = login

	if (user_id) then
		self.host.twitch:pubSubListen("channel-bits-events-v2." .. user_id, self, self.onCheer)
		self.host.twitch:pubSubListen("channel-subscribe-events-v1." .. user_id, self, self.onNewSubscription)
		self.host.twitch:pubSubListen("channel-points-channel-v1." .. user_id, self, self.onChannelPoints)
		self.host.twitch:eventSubListen("channel.follow", user_id, self, self.onNewEventFollower)
		self.host.twitch:pubSubListen("raid." .. user_id, self, self.onRaid)
		self:enableChat(true)
			
		self.ptFollows:setEnabled(true)
		self.ptSubscribers:setEnabled(true)
	
		self.rqViewers:setEnabled(true)
		self.rqMods:setEnabled(true)
		self.rqVIPs:setEnabled(true)
		self.rqChatSubs:setEnabled(true)
		self.rqSubs:setEnabled(true)
		self.rqFollowers:setEnabled(true)

		self.properties.Stats.UserName:raise({name=login})
	
		-- Update profile images
		fetch(self, self.host, "/helix/users"):next(jsonify):next(function(obj)
			self.texProfile:setURL(obj["data"][1].profile_image_url)
		end)

		self:updateCustomRewards(true)

	elseif (last_user_id) then

		self:enableChat(false)
		self.host.twitch:pubSubUnlistenAll()
		self.texProfile:setURL("")
		self.ptFollows:setEnabled(false)
		self.ptSubscribers:setEnabled(false)
		self.rqViewers:setEnabled(false)
		self.rqMods:setEnabled(false)
		self.rqVIPs:setEnabled(false)
		self.rqChatSubs:setEnabled(false)
		self.rqSubs:setEnabled(false)
		self.rqFollowers:setEnabled(false)

	end

	self:emitLoginStatusUpdate()

end

function Instance:onPollSubscribers()

	self.total_subs = 0

	-- Adjust poll time
	self.ptSubscribers:setTime(seconds(60))

	-- Get upcoming broadcasts
	return fetch(self, self.host, "/helix/subscriptions", {
		query={
			broadcaster_id = self.userID,
			first = "100"
		}
	}):next(jsonify):next(function(obj)
		self.total_subs = obj.total
		self.properties.Stats.SubscriberCount:raise({total_sub_count=self.total_subs, today_sub_count=self.today_subs})
		self.ptSubscribers:setEnabled(false)
	end)

end

function Instance:getFollowerCount(user_id, fn)

	-- Get upcoming broadcasts
	return fetch(self, self.host, "/helix/channels/followers", {
		query={
			broadcaster_id = user_id
		}
	}):next(jsonify):next(function(obj)
		fn(obj.total)
	end)

end

function Instance:onPollFollowers()

	-- Adjust poll time
	self.ptFollows:setTime(seconds(60))

	return self:getFollowerCount(self.userID, function(count)
		self.properties.Stats.FollowerCount:raise({count=count})
	end)

end

Instance.tblCustomRewards = {}
Instance.emitCustomRewardsUpdate = event("onCustomRewardsUpdate")

function Instance:updateCustomRewards(app_only)
	
	fetch(self, self.host, "/helix/channel_points/custom_rewards", {
		query={
			broadcaster_id = self.userID,
			only_manageable_rewards = app_only
		}
	}):next(jsonify):next(function(obj)

		if (not obj.data) then
			return
		end

		if (app_only) then

			for i=1, #obj["data"] do

				local existing_cp = self.properties.AppChannelPoints:getKit():findObjectByName(obj["data"][i].title)
				if (existing_cp) then
					existing_cp:setID(obj.data[i].id)
				else
					self:deleteAppCustomReward(obj.data[i].id)
				end

			end

		else 

			self.tblCustomRewards = {}
			for i=1, #obj["data"] do
				self.tblCustomRewards[#self.tblCustomRewards + 1] = obj["data"][i].title
			end

			self:emitCustomRewardsUpdate()

		end

	end)

end

function Instance:createAppCustomReward(cp, title, cost)

	fetch(self, self.host, "/helix/channel_points/custom_rewards", {
		method="POST",
		query={
			broadcaster_id = self.userID,
		},
		headers= {'Content-Type: application/json'},
		body = json.encode({ title=title, cost=cost })
	}):next(jsonify):next(function(obj)
		cp:setID(obj.data[1].id)
	end)

end

function Instance:updateAppCustomReward(id, update_tbl)

	if (not self:isLoggedIn()) then
		return
	end

	fetch(self, self.host, "/helix/channel_points/custom_rewards", {
		method = "PATCH",
		query={
			broadcaster_id = self.userID,
			id = id,
		},
		headers= {'Content-Type: application/json'},
		body = json.encode(update_tbl)
	}):next(jsonify):next(function(obj)

	end)

end

function Instance:deleteAppCustomReward(id)

	if (not self:isLoggedIn()) then
		return
	end

	fetch(self, self.host, "/helix/channel_points/custom_rewards", {
		method = "DELETE",
		query={
			broadcaster_id = self.userID,
			id = id,
		}

	}):next(jsonify):next(function(obj)

	end)

end

function Instance:getCustomRewards()
	return self.tblCustomRewards
end

Instance.user_cache = {}
Instance.user_ids = {}
Instance.tid = 0

--[[
user_cache = {
	user1={
		id=2345
		profile_pic_url={nil,"url"}		-- updated in delayed batches when user info is queried
		viewer={nil, true}
		vip={nil, true}
		mod={nil, true}
		test={nil,true}
		follow={nil, true}
		sub_tier={nil,0,1,2,3}			-- Updated when subscriber lists are queried
	}
}

user_ids = {
	id = login
}
]]

user_lists = {
	"Followers",
	"Followers in Chat",
	"Viewers in Chat",
	"VIPs",
	"Moderators",
	"Subscribers",
	"Subscribers in Chat",
	"Tier 1 Subscribers",
	"Tier 1 Subscribers in Chat",
	"Tier 2 Subscribers",
	"Tier 2 Subscribers in Chat",
	"Tier 3 Subscribers",
	"Tier 3 Subscribers in Chat",
	"Top 100 Bits Leaders (Day)",
	"Top 100 Bits Leaders (Week)",
	"Top 100 Bits Leaders (Month)",
	"Top 100 Bits Leaders (Year)",
	"Top 100 Bits Leaders (All-time)"
}

function Instance:getUserLists()
	return user_lists
end

function Instance:updateUserCache(current_viewers, type)

	-- This enables removing people who have left the chat
	self.tid = self.tid + 1

	-- Add/update viewers
	for i=1, #current_viewers do
		local login = current_viewers[i]
		if (not self.user_cache[login]) then 
			self.user_cache[login] = {}
		end

		self.user_cache[login][type] = true
		self.user_cache[login].tid = self.tid
	end

	-- Update viewers that are gone
	for k,v in pairs(self.user_cache) do
		if (v.tid ~= self.tid) then
			v[type] = nil
		end
	end

end

function Instance:_getUsers(type, inChatOnly)

	local tbl = {}
	for k,v in pairs(self.user_cache) do
		if (not inChatOnly or v["viewer"]) then
			if (v[type]==true) then
				tbl[#tbl+1] = k
			end
		end
	end

	return tbl

end

function Instance:_getSubscribers(tier, inChatOnly)

	local tbl = {}
	for k,v in pairs(self.user_cache) do

		if (not inChatOnly or v["viewer"]) then

			if (v.sub_tier) then
				if ((tier>0 and v.sub_tier==tier) or (tier==0 and v.sub_tier>0)) then
					tbl[#tbl+1] = k
				end
			end

		end
	end

	return tbl

end

function Instance:requestUsers(type, rq)

	local endpoint
	local tblQuery = {
		broadcaster_id=self.userID,
		first=100
	}
	if (type == "viewer") then
		endpoint = "/helix/chat/chatters"
		tblQuery.moderator_id=self.userID
		tblQuery.first = 1000
	elseif (type == "mod") then
		endpoint = "/helix/moderation/moderators"
	elseif (type == "vip") then
		endpoint = "/helix/channels/vips"
	end

	local total_requests = 0
	local users = {}

	fetch(self, self.host, endpoint, {
		query=tblQuery
	}):next(jsonify):next(function(obj, resp)
		
		for i=1,#obj.data do
			if (obj.data[i].user_login ~= self.login) then
				table.insert(users, obj.data[i].user_login)
			end
		end

		total_requests = total_requests + 1
		if (#obj.data>=tblQuery.first and obj.pagination.cursor and total_requests < 10) then
			tblQuery.after = obj.pagination.cursor
			return refetch(resp, {query=tblQuery})
		else
			self:updateUserCache(users, type)
			rq:complete({})
		end

	end):catch(function()
		rq:fail()
	end)

end

function makeUserQuery(list, max, var, active_list)

	if (not active_list) then
		active_list = {}
	end

	local query = ""
	local i = 1
	repeat

		local user = list[#list]
		if (not active_list[user]) then

			if (i>1) then
				query = query .. "&"
			end
			query = query .. var .. "=" .. user

			i = i + 1
			active_list[user] = true
		end

		list[#list] = nil

	until(i>max or #list==0)

	return query

end

function Instance:_updateUserInfos(user_login_list, fnSuccess, fnFail)


	fetch(self, self.host, "/helix/users", {
		query=makeUserQuery(user_login_list, 100, "login")
	
	}):next(jsonify):next(function(obj, resp)

		for i=1, #obj.data do
			local elem = obj.data[i]
			local login = elem.login
			if (not self.user_cache[login]) then
				self.user_cache[login] = {}
			end
			self.user_cache[login].id = elem.id
			self.user_cache[login].profile_image_url = elem.profile_image_url
			self.user_cache[login].title = elem.display_name
			self.user_ids[elem.id] = login
		end

		if (#user_login_list > 0) then
		
			return refetch(resp, {
				query = makeUserQuery(user_login_list, 100, "login")
			})	

		else
			fnSuccess()
		end
		
	end):catch(function()
		fnFail()
	end)

end

function Instance:onRequestSubs()

	self:_requestSubs(nil, 
		function()		-- success
			self.rqSubs:complete({})
		end, 
		function()		-- fail
			self.rqSubs:fail()
		end
	)

end

function Instance:_requestSubs(user_id_list, fnSuccess, fnFail)

	local tblUsers = {}

	local req = {}
	if (user_id_list) then
		req.query = "broadcaster_id=" .. self.userID .. "&" .. makeUserQuery(user_id_list, 100, "user_id", tblUsers) 
	else
		req.query = "broadcaster_id=" .. self.userID .. "&first=100" 
	end

	local total_requests = 0

	fetch(self, self.host, "/helix/subscriptions", req):next(jsonify):next(function(obj, resp)

		for i=1, #obj.data do
			local login = obj.data[i].user_login
			if (login ~= self.login) then		-- We are returned as our own subscriber so filter out

				if (not self.user_cache[login]) then
					self.user_cache[login] = {}
				end

				if (obj.data[i].tier == "1000") then
					self.user_cache[login].sub_tier = 1
				elseif (obj.data[i].tier == "2000") then
					self.user_cache[login].sub_tier = 2
				elseif(obj.data[i].tier == "3000") then
					self.user_cache[login].sub_tier = 3
				end

				if (user_id_list) then
					tblUsers[obj.data[i].user_id] = nil
				end

			end

		end
		
		-- Non-subscribers
		for k,v in pairs(tblUsers) do
			local login = self.user_ids[k]
			self.user_cache[login].sub_tier = 0
		end

		tblUsers = {}

		total_requests = total_requests + 1

		if (#obj.data>=100 and obj.pagination.cursor and total_requests < 3) then

			local req = {}
			if (user_id_list) then
				req.query = "broadcaster_id=" .. self.userID .. "&" .. makeUserQuery(user_id_list, 100, "user_id", tblUsers) 
			else
				req.query = "broadcaster_id=" .. self.userID .. "&after=" .. obj.pagination.cursor .. "&first=100" 
			end

			return refetch(resp, req)

		else
			fnSuccess()
		end

	end):catch(function()
		fnFail()
	end)

end

function Instance:onRequestChatSubs()

	self:queryUserList("Viewers in Chat", function(viewers)

		-- Determine which cached users we do not have sub status
		local unknown_subs_user_logins = {}
		local unknown_subs_user_logins_cp = {}
		for k,v in pairs(viewers) do
			if (not self.user_cache[v].sub_tier) then
				unknown_subs_user_logins[#unknown_subs_user_logins+1] = v
				unknown_subs_user_logins_cp[#unknown_subs_user_logins_cp+1] = v
			end
		end
	
		if (#unknown_subs_user_logins == 0) then
			self.rqChatSubs:complete({})
			return
		end
	
		local fnFail = function()
			self.rqChatSubs:fail()
		end
	
		self:_updateUserInfos(unknown_subs_user_logins, function()

			-- Determine which cached users we do not have sub status
			local unknown_subs_user_ids = {}
			for k,v in pairs(unknown_subs_user_logins_cp) do
				unknown_subs_user_ids[#unknown_subs_user_ids+1] = self.user_cache[v].id
			end

			self:_requestSubs(unknown_subs_user_ids, function()
				self.rqChatSubs:complete({})
			end, fnFail)

		end, fnFail)
	
	end)

end

function Instance:onRequestFollowers()

	self:_requestFollowers( 
		function()		-- success
			self.rqFollowers:complete({})
		end, 
		function()		-- fail
			self.rqFollowers:fail()
		end
	)

end

function Instance:_requestFollowers(fnSuccess, fnFail)

	local total_requests = 0

	fetch(self, self.host, "/helix/channels/followers", {
		query={
			broadcaster_id=self.userID,
			first=100
		}
	}):next(jsonify):next(function(obj, resp)

		for i=1, #obj.data do
			local login = obj.data[i].user_login

			if (not self.user_cache[login]) then
				self.user_cache[login] = {}
			end

			self.user_cache[login].follow = true

		end		
		
		total_requests = total_requests + 1
		if (#obj.data>=100 and obj.pagination.cursor and total_requests < 3) then

			return refetch(resp, {
				query={
					broadcaster_id=self.userID,
					first=100,
					after=obj.pagination.cursor
				}
			})

		else
			fnSuccess()
		end	

	end):catch(function()
		fnFail()
	end)

end

function Instance:requestLeaderboards(range)

	fetch(self, self.host, "/helix/bits/leaderboard", {
		query={
			count=100,
			period=range
		}
	}):next(jsonify):next(function(obj, resp)

		local tbl = {}
		for i=1, #obj.data do
			local login = obj.data[i].user_login
			tbl[#tbl+1] = login
		end
		
		self.rqLeaderboards[range]:complete(tbl)

	end):catch(function()
		self.rqLeaderboards[range]:fail()
	end)

end

function Instance:queryUserList(name, fn)
	
	if (not self.host:isAuthorized()) then
		fn({})
		return
	end

	--self.rqViewers:setUpdateTime(seconds(5))
	if (name == "Viewers in Chat") then
		self.rqViewers:request(function()
			fn(self:_getUsers("viewer"))
		end)
	elseif (name=="VIPs") then
		self.rqVIPs:request(function()
			fn(self:_getUsers("vip"))
		end)
	elseif (name=="Moderators") then
		self.rqMods:request(function()
			fn(self:_getUsers("mod"))
		end)
	elseif (name=="Subscribers in Chat") then
		self.rqChatSubs:request(function()
			fn(self:_getSubscribers(0, true))
		end)
	elseif (name=="Tier 1 Subscribers in Chat") then
		self.rqChatSubs:request(function()
			fn(self:_getSubscribers(1, true))
		end)
	elseif (name=="Tier 2 Subscribers in Chat") then
		self.rqChatSubs:request(function()
			fn(self:_getSubscribers(2, true))
		end)
	elseif (name=="Tier 3 Subscribers in Chat") then
		self.rqChatSubs:request(function()
			fn(self:_getSubscribers(3, true))
		end)
	elseif (name=="Subscribers") then
		self.rqSubs:request(function()
			fn(self:_getSubscribers(0))
		end)
	elseif (name=="Tier 1 Subscribers") then
		self.rqSubs:request(function()
			fn(self:_getSubscribers(1))
		end)
	elseif (name=="Tier 2 Subscribers") then
		self.rqSubs:request(function()
			fn(self:_getSubscribers(2))
		end)
	elseif (name=="Tier 3 Subscribers") then
		self.rqSubs:request(function()
			fn(self:_getSubscribers(3))
		end)
	elseif (name=="Followers") then
		self.rqFollowers:request(function()
			fn(self:_getUsers("follow"))
		end)
	elseif (name=="Followers in Chat") then
		self.rqFollowers:request(function()
			self:queryUserList("Viewers in Chat", function(viewers)
				fn(self:_getUsers("follow", true))
			end)
		end)
	elseif (name=="Top 100 Bits Leaders (Day)") then
		self.rqLeaderboards["day"]:request(fn)
	elseif (name=="Top 100 Bits Leaders (Week)") then
		self.rqLeaderboards["week"]:request(fn)
	elseif (name=="Top 100 Bits Leaders (Month)") then
		self.rqLeaderboards["month"]:request(fn)
	elseif (name=="Top 100 Bits Leaders (Year)") then
		self.rqLeaderboards["year"]:request(fn)
	elseif (name=="Top 100 Bits Leaders (All-time)") then
		self.rqLeaderboards["all"]:request(fn)
	end

end

function Instance:onRequestUserInfo(elements)

	local tbl = {}
	for i=1, #elements do
		tbl[i] = elements[i].login
	end
	
	-- Add extras
	for k,v in pairs(self.user_cache) do
		if (not v.profile_image_url) then
			tbl[#tbl+1] = k
			if (#tbl==100) then
				break
			end
		end
	end

	self:_updateUserInfos(tbl, function()

		for i=1, #elements do
			local elem = elements[i]

			if (self.user_cache[elem.login]) then

				if (not self.user_cache[elem.login].profile_image_url) then
					self.user_cache[elem.login].profile_image_url = ""
				end

				local user_info = {
					profile_image_url = self.user_cache[elem.login].profile_image_url,
					title = self.user_cache[elem.login].title,
					id = self.user_cache[elem.login].id
				}

				elem.fn(user_info)

			else
				elem.fn(nil)
			end
				
		end

	end, function()	end)


end

function Instance:getDisplayName(login)
	return login
end

function Instance:queryUserInfo(login, fn)

	log("[EventSubscriber] queryUserInfo: " .. login .. " with function: " .. tostring(fn))
	if (self.user_cache[login] and self.user_cache[login].profile_image_url) then
		log("[EventSubscriber] queryUserInfo: " .. login .. " already in cache")
		local user_info = {
			profile_image_url = self.user_cache[login].profile_image_url,
			title = self.user_cache[login].title,
			id = self.user_cache[login].id
		}
		fn(user_info)
		return
	end

	self.rpUserInfo:request({login=login,fn=fn})

end

function Instance:enableChat(bEnable)
	if (self.bIsChatEnabled == bEnable) then
		return
	end
	self.bIsChatEnabled = bEnable

	if (bEnable) then
		self.host.twitch:connectToChat(self, self.onChatMsg)
	else
		self.host.twitch:disconnectFromChat(self)
	end

end

function Instance:onChatMsg(tbl)

	if (tbl.msg) then

		-- Strip line feeds
		tbl.msg = tbl.msg:gsub("[\r\n]*", "")

		self.properties.Alerts.onChatMessage:raise({user_name=tbl.user,msg=tbl.msg})

		local msg = tbl.msg:lower()

		local is_broadcaster = false
		for b=1, #tbl.tags.badges do
			if (tbl.tags.badges[b] == "broadcaster") then
				is_broadcaster = true
				break
			end
		end	

		local kit = self.properties.ChatAlerts:getKit()
		for i=1, kit:getObjectCount() do
			local ca = kit:getObjectByIndex(i)
			local command = ca.properties.Command:lower()
			local command_pos = msg:find(command, 1, true)

			if (command_pos) then
				
				local has_privilage = false
				if (is_broadcaster) then
					has_privilage = true
				elseif (ca.properties.Privilege == "anyone") then
					has_privilage = true
				elseif (ca.properties.Privilege == "specific user") then
					if (tbl.user:lower() == ca.properties.User:lower()) then
						has_privilage = true
					end
				else
					for b=1, #tbl.tags.badges do
						if (tbl.tags.badges[b] == "broadcaster" or tbl.tags.badges[b] == ca.properties.Privilege) then
							has_privilage = true
							break
						end
					end
				end

				if (has_privilage) then
					local pay_load = tbl.msg:sub(command_pos + #command+1)

					self:raiseAlertWithProfileUrl(ca.properties.onCommand, tbl.user, {
						user_name=tbl.user, 
						msg=pay_load
					})	
			
				end

			end
		end

	elseif (tbl.tags) then

		if (tbl.tags["msg-id"] == "raid") then
			local viewer_count = tbl.tags["msg-param-viewerCount"]

			self:raiseAlertWithProfileUrl(self.properties.Alerts.Raids.onIncomingRaid, tbl.tags["login"], {
				user_name=tbl.tags["login"],
				viewers=viewer_count
			})
				
		end

	end

end