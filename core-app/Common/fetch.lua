
Exception = {}
Exception.__index = Exception
function throw(exception)
	local tbl = {}
	tbl.exception = exception
	return setmetatable(tbl, Exception)
end

Repromise = {}
Repromise.__index = Repromise
function createRepromise()
	local tbl = {}
	return setmetatable(tbl, Repromise)
end

Promise = {}
Promise.__index = Promise
function createPromise()
	local tbl = {}
	return setmetatable(tbl, Promise)
end

function Promise:next(fnSuccess, fnFail)
	
	local promise = createPromise()
	
	if (fnSuccess) then
		self.fnSuccess = function(...)
			local in_args={...}

			-- Preserve multi-argument returns
			local out_args = table.pack(fnSuccess(table.unpack(in_args)))

			if (#out_args==1) then
				local ret = out_args[1]

				-- Returns exception, call fail callback
				if (getmetatable(ret) == Exception) then
					self.fnFail(ret.exception)
					return

				-- Returns promise, continue the chain on promise fulfillment
				elseif (getmetatable(ret) == Promise) then

					-- Register propegation functions
					ret:next(function(resp)
						if (promise.fnSuccess) then
							promise.fnSuccess(resp)
						end
					end, function(exception)
						promise.fnCatch(exception)
					end):catch(function(exception)
						promise.fnCatch(exception)
					end)

					return

				-- Do nothing, expect this promise to refire (refetch cases)
				elseif (getmetatable(ret) == Repromise) then
					return
				end

			end

			-- Returns a value, propegate up chain
			if (promise.fnSuccess) then
				promise.fnSuccess(table.unpack(out_args))
			end

		end

	end

	self.fnFail = function(exception)
		if (fnFail) then
			fnFail(exception)
		elseif (promise.fnCatch) then
			promise.fnCatch(exception)
		elseif (promise.fnSuccess) then	-- No catch means finally
			promise.fnSuccess()
		end
	end

	-- Propegate
	self.fnCatch = function(exception)
		if (promise.fnCatch) then
			promise.fnCatch(exception)
		end
	end

	return promise

end

function Promise:catch(fn)
	local promise = createPromise()
	self.fnCatch = function(exception)
		local ret = fn(exception)
		if (getmetatable(ret) == Exception) then
			promise.fnCatch(ret.exception)
		else
			-- Finally function
			if (promise.fnSuccess) then
				promise.fnSuccess()
			end
		end
	end

	-- Finally propegation
	self.fnSuccess = function()
		if (promise.fnSuccess) then
			promise.fnSuccess()
		end
	end

	return promise
end

function Promise:finally(fn)
	self.fnSuccess = fn
	self.fnCatch = fn
end

function fetch(obj, host, endpoint, params)

	if (type(endpoint)=="string") then
		if (not params) then
			params = {}
		end
		params.url = "https://" .. host:getHostName() .. endpoint
	else 
		params = endpoint
	end

	if (params.login) then
		params.url = params.url .. "?login=" .. params.login
	end

	local promise = createPromise()
	log("[EventSub] JSON Request " .. json.encode(params))
	host:sendHTTPRequest(params, obj, function(obj, resp)

		if (not resp:isResponseError()) then
			if (promise.fnSuccess) then
				log("[Fetch Success] " .. params.url .. ": " .. tostring(resp:getResponseStatus()) .. " " .. resp:getResponseAsText())
				promise.fnSuccess(resp)
			end
		else
			log("[Fetch Error] " .. params.url .. ": " .. tostring(resp:getResponseStatus()) .. " " .. resp:getResponseAsText())
			if (promise.fnFail) then
				promise.fnFail(resp)
			end
		end

	end)

	return promise

end

function refetch(resp, params)
	resp:setRequest(params)
	resp:submit()
	return createRepromise()
end

function jsonify(resp)
	local obj = json.decode(resp:getResponseAsText())
	if (not obj) then
		return throw("Invalid json data")
	end
	return obj, resp	-- Propegate response for refetching
end

function jsonify_test(value)
	return function(resp) return json.decode(value), resp end
end

function queryStringToTable(str)

	local tblQuery = {}

	local tbl = split(str, "&")
	for i=1,#tbl do
		local tblElement = split(tbl[i], "=")
		tblQuery[tblElement[1]] = tblElement[2]
	end

	return tblQuery

end