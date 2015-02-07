--------------------------------------------------------------------------------------------------------
-- Water Level
--------------------------------------------------------------------------------------------------------

local opts = Spring.GetMapOptions()
if opts == nil then return end
if opts.waterlevel == nil then return end

if mapinfo.smf.minheight and mapinfo.smf.maxheight then
	local range = mapinfo.smf.maxheight - mapinfo.smf.minheight
	local depth = 0
	if opts.waterlevel == 'dry' then
		depth = -50
	elseif opts.waterlevel == 'shallow' then
		depth = range * 0.2
	elseif opts.waterlevel == 'deep' then
		depth = range * 0.8
	end
	mapinfo.smf.minheight = -depth
	mapinfo.smf.maxheight = range - depth
else
	Spring.Echo("Error mapinfo.lua: waterlevel selected but smf.minheight and/or smf.maxheight are unset!")
end
