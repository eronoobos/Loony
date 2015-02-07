function gadget:GetInfo()
  return {
    name      = "Loony: Heightmap Test",
    desc      = "Tries to adjust the heightmap.",
    author    = "zoggop",
    date      = "January 2015",
    license   = "whatever",
    layer     = 10,
    enabled   = true
   }
end

-- synced --------------------------------------------------------------------

if gadgetHandler:IsSyncedCode() then 

function gadget:UnitCreated()
  Spring.Echo(Spring.GetGroundExtremes())
end

end

-- unsynced ------------------------------------------------------------------

if not gadgetHandler:IsSyncedCode() then

end