function widget:GetInfo()
	return {
		name	= "Loony: Meteor Impact Command",
		desc	= "sends commands to the meteor impact gadget",
		author  = "zoggop",
		date 	= "February 2015",
		license	= "whatever",
		layer 	= 0,
		enabled	= true
	}
end

local asciis = {}
local clocks = {}
local meteor

local function StartClock(thing)
	clocks[thing] = Spring.GetTimer()
end

local function EndClocks()
	for thing, clock in pairs(clocks) do
 		Spring.Echo(string.format(thing .. " in " .. math.ceil(Spring.DiffTimers(Spring.GetTimer(), clock, true)) .. " ms"))
 	end
 	clocks = {}
end

local function LoonyCommand(command, alreadyLoony)
	StartClock(command)
	local msg = command
	if not alreadyLoony then msg = "loony " .. msg end
	Spring.SendLuaRulesMsg(msg)
end

local function ascii(char)
	asciis[char] = asciis[char] or string.byte(char)
	return asciis[char]
end

local function splitIntoWords(s)
  local words = {}
  for w in s:gmatch("%S+") do table.insert(words, w) end
  return words
end

local function GetMouseGroundPosition()
	local x, y = Spring.GetMouseState()
	local thing, stuff = Spring.TraceScreenRay(x, y)
	if thing == "ground" then
		local gx, gy, gz = math.floor(stuff[1]), math.floor(stuff[2]), math.floor(stuff[3])
		return gx, gy, gz
	end
end

local function BeginMeteor()
	local x, y, z = GetMouseGroundPosition()
	if x then meteor = {x = x, y = y, z = z, radius = 0} end
end

local function EndMeteor()
	if meteor then
		LoonyCommand("meteor " .. meteor.x .. " " .. meteor.z .. " " .. meteor.radius)
		meteor = nil
	end
end

function widget:KeyPress(key, mods, isRepeat)
	if isRepeat == false then
		if key == ascii(",") then
			BeginMeteor()
		elseif key == ascii(".") then
			LoonyCommand("blur")
		elseif key == ascii("/") then
			LoonyCommand("clear")
		elseif key == ascii("'") then
			LoonyCommand("read")
		end
	end
end

function widget:KeyRelease(key)
	if key == ascii(",") then
		EndMeteor()
	end
end

function widget:Update()
	if meteor then
		local x, y, z = GetMouseGroundPosition()
		if x then
			local dx, dz = x - meteor.x, z - meteor.z
			meteor.radius = math.sqrt( (dx*dx) + (dz*dz) )
		end
	end
end

function widget:DrawWorld()
	if not meteor then return end
	gl.DepthTest(false)
	gl.PushMatrix()
	gl.LineWidth(3)
	gl.Color(1, 0, 0, 1)
	gl.DrawGroundCircle(meteor.x, meteor.y, meteor.z, meteor.radius, 8)
	gl.LineWidth(1)
	gl.Color(1, 1, 1, 0.5)
	gl.PopMatrix()
	gl.DepthTest(true)
end

function widget:GameFrame(frame)
	EndClocks()
end

function widget:TextCommand(command)
	if (string.find(command, 'loony') == 1) then
		LoonyCommand(command, true)
	end
end