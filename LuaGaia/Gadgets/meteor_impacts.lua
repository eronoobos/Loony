function gadget:GetInfo()
  return {
    name      = "Loony: Meteor Impacts",
    desc      = "Generates a map of meteor impact craters.",
    author    = "zoggop",
    date      = "February 2015",
    license   = "whatever",
    layer     = -3,
    enabled   = true
   }
end

include("LuaLib/perlin.lua")

-- localization:

local pi = math.pi
local twicePi = math.pi * 2
local piHalf = math.pi / 2
local piEighth = math.pi / 8
local piTwelfth = math.pi / 12
local piSixteenth = math.pi / 16
local twoSqrtTwo = 2 * math.sqrt(2)
local naturalE = math.exp(1)
local radiansPerAngle = math.pi / 180

local mSqrt = math.sqrt
local mRandom = math.random
local mMin = math.min
local mMax = math.max
local mAtan2 = math.atan2
local mExp = math.exp
local mCeil = math.ceil
local mFloor = math.floor
local mAbs = math.abs
local mMix = math.mix
local mSmoothstep = math.smoothstep

local tInsert = table.insert
local tRemove = table.remove
local tSort = table.sort

local spSetHeightMapFunc = Spring.SetHeightMapFunc
local spSetHeightMap = Spring.SetHeightMap
local spAdjustHeightMap = Spring.AdjustHeightMap
local spEcho = Spring.Echo
local spSetMetalAmount = Spring.SetMetalAmount
local spGetMetalAmount = Spring.GetMetalAmount
local spGetGameFrame = Spring.GetGameFrame
local spLevelHeightMap = Spring.LevelHeightMap
local spGetGroundHeight = Spring.GetGroundHeight

-- config:

local bypassSpring = true -- if false, automatically write to spring's height map
local yesMare = false -- send huge melt-floor-generating meteors before a shower?
local fileMaxPacketLength = 1024 -- how many bytes to accumulate in the writeBuffer before sending to unsynced
local doNotStore = false

-- local variables:

local myWorld
local heightMapRuler, metalMapRuler
local gadgetInitialized = false

local diffDistances = {}
local diffDistancesSq = {}
local sqrts = {}
local gaussians = {}
local angles = {}
local writeBuffer = ""
local readBuffer = ""
local readEndFunc

------------------------------------------------------------------------------

local AttributeDict = {
  [0] = { name = "None", rgb = {0,0,0} },
  [1] = { name = "Breccia", rgb = {128,128,128} },
  [2] = { name = "Peak", rgb = {0,255,0} },
  [3] = { name = "Ejecta", rgb = {0,255,255} },
  [4] = { name = "Melt", rgb = {255,0,0} },
  [5] = { name = "EjectaThin", rgb = {0,0,255} },
  [6] = { name = "Ray", rgb = {255,255,255} },
  [7] = { name = "Metal", rgb = {255,0,255} },
  [8] = { name = "Geothermal", rgb = {255,255,0} },
}

local AttributeOverlapExclusions = {
  [0] = {},
  [1] = {[7] = true, [8] = true},
  [2] = {[7] = true, [8] = true},
  [3] = {[7] = true, [8] = true},
  [4] = {[7] = true, [8] = true},
  [5] = {[1] = true, [2] = true, [4] = true, [6] = true, [7] = true, [8] = true},
  [6] = {[7] = true, [8] = true},
  [7] = {},
  [8] = {},
}

local AttributesByName = {}
for i, entry in pairs(AttributeDict) do
  local aRGB = entry.rgb
  local r = string.char(aRGB[1])
  local g = string.char(aRGB[2])
  local b = string.char(aRGB[3])
  local threechars = r .. g .. b
  AttributeDict[i].threechars = threechars
  AttributesByName[entry.name] = { index = i, rgb = aRGB, threechars = threechars}
end

local MirrorTypes = { "reflectionalx", "reflectionalz", "rotational", "none" }
local MirrorNames = {}
for i, name in pairs(MirrorTypes) do
  MirrorNames[name] = i
end

-- for metal spot writing
local metalPixelCoords = {
  [1] = { 0, 0 },
  [2] = { 0, 1 },
  [3] = { 0, -1 },
  [4] = { 1, 0 },
  [5] = { -1, 0 },
  [6] = { 1, 1 },
  [7] = { -1, 1 },
  [8] = { 1, -1 },
  [9] = { -1, -1 },
  [10] = { 2, 0 },
  [11] = { -2, 0 },
  [12] = { 0, 2 },
  [13] = { 0, -2 },
}

local WorldSaveBlackList = {
  "world",
  "values",
  "outValues",
  "renderers",
  "heightBuf",
}

local WSBL = {}
for i, v in pairs(WorldSaveBlackList) do
  WSBL[v] = 1
end

local function OnWorldSaveBlackList(str)
  return WSBL[str]
end

------------------------------------------------------------------------------

-- local functions:

local function uint32little(n)
  return string.char( n%256, (n%65536)/256, (n%16777216)/65536, n/16777216 )
end

local function uint16little(n)
  return string.char( n%256, (n%65536)/256 )
end

local function uint16big(n)
  return string.char( (n%65536)/256, n%256 )
end

local function uint8(n)
  return string.char( n%256 )
end

local function FReadOpen(name, ext, endFunc)
  readBuffer = ""
  readEndFunc = endFunc
  SendToUnsynced("ReadFile", name, ext)
end

local function FReadLine(line)
  readBuffer = readBuffer .. line .. "\n"
end

local function FReadClose()
  -- spEcho(readBuffer)
  readEndFunc(readBuffer)
  readBuffer = ""
end

local function FWriteOpen(name, ext, mode)
  writeBuffer = ""
  SendToUnsynced("BeginFile", name, ext, mode)
end

local function FWrite(...)
  local send = ""
  for i, str in ipairs({...}) do
    send = send .. str
  end
  writeBuffer = writeBuffer .. send
  if writeBuffer:len() >= fileMaxPacketLength then
    SendToUnsynced("PieceFile", writeBuffer)
    writeBuffer = ""
  end
end

local function FWriteClose()
  if writeBuffer:len() > 0 then SendToUnsynced("PieceFile", writeBuffer) end
  SendToUnsynced("EndFile")
  writeBuffer = ""
end

local function serialize(o)
  if type(o) == "number" then
    FWrite(o)
  elseif type(o) == "boolean" then
    FWrite(tostring(o))
  elseif type(o) == "string" then
    FWrite(string.format("%q", o))
  elseif type(o) == "table" then
    FWrite("{")
    for k,v in pairs(o) do
      if not (type(k) == "string" and OnWorldSaveBlackList(k)) then
        local kStr = k
        if type(k) == "number" then kStr = "[" .. k .. "]" end
        FWrite("\n  ", kStr, " = ")
        serialize(v)
        FWrite(",")
      end
    end
    FWrite("}")
  else
    -- spEcho("cannot serialize a " .. type(o))
    FWrite("\"" .. type(o) .. "\"")
  end
end

local function sqrt(number)
  if doNotStore then return mSqrt(number) end
  sqrts[number] = sqrts[number] or mSqrt(number)
  return sqrts[number]
end

local function MinMaxRandom(minimum, maximum)
  return (mRandom() * (maximum - minimum)) + minimum
end

local function RandomVariance(variance)
  return (1-variance) + (mRandom() * variance * 2)
end

local function VaryWithinBounds(value, variance, minimum, maximum)
  if not value then return nil end
  return mMax(mMin(value*RandomVariance(variance), maximum), minimum)
end

local function AngleDXDY(dx, dy)
  if doNotStore then return mAtan2(dy, dx) end
  angles[dx] = angles[dx] or {}
  angles[dx][dy] = angles[dx][dy] or mAtan2(dy, dx)
  return angles[dx][dy]
end

local function AngleAdd(angle1, angle2)
  local angle = angle1 + angle2
  if angle > pi then angle = angle - twicePi end
  if angle < -pi then angle = angle + twicePi end
  return angle
end

local function tDuplicate(sourceTable)
  local duplicate = {}
  for k, v in pairs(sourceTable) do
    tInsert(duplicate, v)
  end
  return duplicate
end

local function tRemoveRandom(fromTable)
  return tRemove(fromTable, mRandom(1, #fromTable))
end

local function splitIntoWords(s)
  local words = {}
  for w in s:gmatch("%S+") do tInsert(words, w) end
  return words
end

local function Gaussian(x, c)
  if doNotStore then return mExp(  -( (x^2) / (2*(c^2)) )  ) end
  gaussians[x] = gaussians[x] or {}
  gaussians[x][c] = gaussians[x][c] or mExp(  -( (x^2) / (2*(c^2)) )  )
  return gaussians[x][c]
end

local function DiceRoll(dice)
  local n = 0
  for d = 1, dice do
    n = n + (mRandom() / dice)
  end
  return n
end

local function NewSeed()
  return mCeil(mRandom()*1000)
end

function pairsByKeys (t, f)
  local a = {}
  for n in pairs(t) do tInsert(a, n) end
  tSort(a, f)
  local i = 0      -- iterator variable
  local iter = function ()   -- iterator function
    i = i + 1
    if a[i] == nil then return nil
    else return a[i], t[a[i]]
    end
  end
  return iter
end

local function EndCommand(command)
  SendToUnsynced("CompleteCommand", command)
end

local function ClearMetalSquare(x, z, size)
  local halfSize = mCeil(size / 2)
  for ix = x-halfSize, x+halfSize do
    for iz = z-halfSize, z+halfSize do
      spSetMetalAmount(ix, iz, 0)
    end
  end
end

local function ClearMetalMap()
  for x = 0, Game.mapSizeX/16 do
    for z = 0, Game.mapSizeZ/16 do
      spSetMetalAmount(x, z, 0)
    end
  end
end

local function WriteMetalSpot(spot)
    local metal = spot.metal
    local pixels = 5
    if metal <= 1 then
      pixels = 5
    elseif metal <= 2 then
      pixels = 9
    else
      pixels = 13
    end
    local mAmount = (1000 / pixels) * metal
    local x, z = mCeil(spot.x/16)-1, mCeil(spot.z/16)-1
    if(x == nil or z == nil) then spEcho("FATAL ERROR: x or y was nil for index " .. i) end
    for p = 1, pixels do
      spSetMetalAmount(x + metalPixelCoords[p][1], z + metalPixelCoords[p][2], mAmount)
    end
end

local function ClearSpeedupStorage()
  diffDistances = {}
  diffDistancesSq = {}
  sqrts = {}
  gaussians = {}
  angles = {}
end

------------------------------------------------------------------------------

-- Compatible with Lua 5.1 (not 5.0).
function class(base, init)
   local c = {}    -- a new class instance
   if not init and type(base) == 'function' then
      init = base
      base = nil
   elseif type(base) == 'table' then
    -- our new class is a shallow copy of the base class!
      for i,v in pairs(base) do
         c[i] = v
      end
      c._base = base
   end
   -- the class will be the metatable for all its objects,
   -- and they will look up their methods in it.
   c.__index = c

   -- expose a constructor which can be called by <classname>(<args>)
   local mt = {}
   mt.__call = function(class_tbl, ...)
   local obj = {}
   setmetatable(obj,c)
   if init then
      init(obj,...)
   else 
      -- make sure that any stuff from the base class is initialized!
      if base and base.init then
      base.init(obj, ...)
      end
   end
   return obj
   end
   c.init = init
   c.is_a = function(self, klass)
      local m = getmetatable(self)
      while m do 
         if m == klass then return true end
         m = m._base
      end
      return false
   end
   setmetatable(c, mt)
   return c
end

------------------------------------------------------------------------------

-- classes: ------------------------------------------------------------------

World = class(function(a, metersPerElmo, baselevel, gravity, density, mirror)
  a.metersPerElmo = metersPerElmo or 1 -- meters per elmo for meteor simulation model only
  a.metersPerSquare = a.metersPerElmo * Game.squareSize
  spEcho(a.metersPerElmo, a.metersPerSquare)
  a.baselevel = baselevel or 0
  a.gravity = gravity or (Game.gravity / 130) * 9.8
  a.density = density or (Game.mapHardness / 100) * 2500
  a.complexDiameter = 3200 / (a.gravity / 9.8)
  local Dc = a.complexDiameter / 1000
  a.complexDiameterCutoff = ((Dc / 1.17) * (Dc ^ 0.13)) ^ (1/1.13)
  a.complexDiameterCutoff = a.complexDiameterCutoff * 1000
  a.complexDepthScaleFactor = ((a.gravity / 1.6) + 1) / 2
  a.mirror = mirror or "none"
  a.minMetalMeteorDiameter = 2
  a.maxMetalMeteorDiameter = 50
  a.metalMeteorTarget = 20
  a.metalSpotAmount = 2.0
  a.metalRadius = 50 -- elmos, for the attribute map
  a.minGeothermalMeteorDiameter = 20
  a.maxGeothermalMeteorDiameter = 100
  a.geothermalMeteorTarget = 4
  a.geothermalRadius = 30 -- elmos, for the attribute map
  a.metalAttribute = true -- draw metal spots on the attribute map?
  a.geothermalAttribute = true -- draw geothermal vents on the attribute map?
  a.rimTerracing = true
  -- local echostr = ""
  -- for k, v in pairs(a) do echostr = echostr .. tostring(k) .. "=" .. tostring(v) .. " " end
  -- spEcho(echostr)
  a:Clear()
end)

MapRuler = class(function(a, elmosPerPixel, width, height)
  elmosPerPixel = elmosPerPixel or Game.mapSizeX / (width-1)
  width = width or mCeil(Game.mapSizeX / elmosPerPixel)
  height = height or mCeil(Game.mapSizeZ / elmosPerPixel)
  a.elmosPerPixel = elmosPerPixel
  a.width = width
  a.height = height
end)

HeightBuffer = class(function(a, world, mapRuler)
  a.world = world
  a.mapRuler = mapRuler
  a.elmosPerPixel = mapRuler.elmosPerPixel
  a.w, a.h = mapRuler.width, mapRuler.height
  a.heights = {}
  for x = 1, a.w do
    a.heights[x] = {}
    for y = 1, a.h do
      a.heights[x][y] = 0
    end
  end
  a.maxHeight = 0
  a.minHeight = 0
  a.directToSpring = false
  a.antiAlias = false
  spEcho("new height buffer created", a.w, " by ", a.h)
end)

Renderer = class(function(a, world, mapRuler, pixelsPerFrame, renderType, uiCommand, heightBuf, noCraters, radius)
  a.startFrame = spGetGameFrame()
  a.uiCommand = uiCommand or ""
  a.world = world
  a.mapRuler = mapRuler
  a.pixelsPerFrame = pixelsPerFrame
  a.renderType = renderType
  a.heightBuf = heightBuf
  a.radius = radius
  a.craters = {}
  a.totalCraterArea = 0
  if not noCraters then
    for i, m in ipairs(world.meteors) do
      local crater = Crater(m, a)
      tInsert(a.craters, crater)
      a.totalCraterArea = a.totalCraterArea + crater.area
    end
  end
  a.pixelsRendered = 0
  a.pixelsToRenderCount = mapRuler.width * mapRuler.height
  a.totalPixels = a.pixelsToRenderCount+0
  a.PreinitFunc = a[a.renderType .. "Preinit"] or a.EmptyPreinit
  a.InitFunc = a[a.renderType .. "Init"] or a.EmptyInit
  a.FrameFunc = a[a.renderType .. "Frame"] -- if there's no framefunc what's the point
  a.FinishFunc = a[a.renderType .. "Finish"] or a.EmptyFinish
  a:Preinitialize()
end)

-- Crater actually gets rendered. scales horizontal distances to the frame being rendered
Crater = class(function(a, meteor, renderer)
  local world = meteor.world
  local elmosPerPixel = renderer.mapRuler.elmosPerPixel
  a.meteor = meteor
  a.renderer = renderer
  a.x, a.y = renderer.mapRuler:XZtoXY(meteor.sx, meteor.sz)
  a.radius = meteor.craterRadius / elmosPerPixel
  a.falloff = meteor.craterRadius * 1.5 / elmosPerPixel
  a.peakC = (a.radius / 8) ^ 2

  a.totalradius = a.radius + a.falloff
  a.totalradiusSq = a.totalradius * a.totalradius
  a.xmin, a.xmax, a.ymin, a.ymax = renderer.mapRuler:RadiusBounds(a.x, a.y, a.totalradius*(1+meteor.distWobbleAmount))
  a.radiusSq = a.radius * a.radius
  a.falloffSq = a.totalradiusSq - a.radiusSq
  a.falloffSqHalf = a.falloffSq / 2
  a.falloffSqFourth = a.falloffSq / 4
  a.brecciaRadiusSq = (a.radius * 0.85) ^ 2
  a.blastRadius = a.totalradius * 4
  a.blastRadiusSq = a.blastRadius ^ 2
  a.xminBlast, a.xmaxBlast, a.yminBlast, a.ymaxBlast = renderer.mapRuler:RadiusBounds(a.x, a.y, a.blastRadius)

  if meteor.metalSeed and world.metalAttribute then
    a.metalRadius = mCeil(world.metalRadius / elmosPerPixel)
    a.metalNoise = TwoDimensionalNoise(meteor.metalSeed, a.metalRadius*2, 1, 0.5, 3)
    a.metalRadiusSq = a.metalRadius^2
  end
  if meteor.geothermalSeed and world.geothermalAttribute then
    a.geothermalRadius = mCeil(world.geothermalRadius / elmosPerPixel)
    a.geothermalRadiusSq = a.geothermalRadius^2
    a.geothermalNoise = WrapNoise(mCeil(world.geothermalRadius/4), a.geothermalRadiusSq, meteor.geothermalSeed, 1, 1)
  end


  if meteor.complex and meteor.diameterImpactor <= 500 then
    a.peakRadius = a.radius / 5.5
    a.peakRadiusSq = a.peakRadius ^ 2
    a.peakPersistence = 0.3*(meteor.world.complexDiameter/meteor.diameterSimple)^2
    -- spEcho(a.peakPersistence)
    a.peakNoise = TwoDimensionalNoise(meteor.peakSeed, a.peakRadius * 2 * (1+meteor.distWobbleAmount) * (1+meteor.peakRadialNoise.intensity), meteor.craterPeakHeight, a.peakPersistence, 5+(8-elmosPerPixel), 1, 0.5, 1)
  end

  if meteor.terraceSeeds then
    local tmin = a.radiusSq * 0.35
    local tmax = a.radiusSq * 0.8
    local tdif = tmax - tmin
    local terraceWidth = tdif / #meteor.terraceSeeds
    local terraceFlatWidth = terraceWidth * 0.5
    a.terraces = {}
    for i = 1, #meteor.terraceSeeds do
      a.terraces[i] = { max = tmin + (i*terraceWidth), noise = WrapNoise(12, terraceFlatWidth, meteor.terraceSeeds[i], 0.5, 2) }
    end
    a.terraceMin = tmin
  end

  a.width = a.xmax - a.xmin + 1
  a.height = a.ymax - a.ymin + 1
  a.area = a.width * a.height
  a.currentPixel = 0
end)

-- Meteor stores data and does meteor impact model calculations
-- meteor impact model equations based on http://impact.ese.ic.ac.uk/ImpactEffects/effects.pdf
Meteor = class(function(a, world, sx, sz, diameterImpactor, velocityImpactKm, angleImpact, densityImpactor, age, metal, geothermal)
  -- coordinates sx and sz are in spring coordinates (elmos)
  a.world = world
  if not sx then return end
  a.sx, a.sz = mFloor(sx), mFloor(sz)

  a.diameterImpactor = diameterImpactor or 10
  -- spEcho(mFloor(a.diameterImpactor) .. " meter object")
  a.velocityImpactKm = velocityImpactKm or 30
  a.angleImpact = angleImpact or 45
  a.densityImpactor = densityImpactor or 8000
  a.age = age or 0
  a.ageRatio = a.age / 100

  if type(geothermal) == "string" then
    a.geothermal = geothermal == "true"
  else
    if a.diameterImpactor > world.minGeothermalMeteorDiameter and a.diameterImpactor < world.maxGeothermalMeteorDiameter then
      if world.geothermalMeteorCount < world.geothermalMeteorTarget then a.geothermal = true end
    end
  end
  if not a.geothermal then
    if type(metal) == "string" then
      a.metal = metal == "true"
    else
      if a.diameterImpactor > world.minMetalMeteorDiameter and a.diameterImpactor < world.maxMetalMeteorDiameter then
        if world.metalMeteorCount < world.metalMeteorTarget then a.metal = true end
      end
    end
  end
  if a.metal then
    a.metalSeed = NewSeed()
    world.metalMeteorCount = world.metalMeteorCount + 1
  end
  if a.geothermal then
    world.geothermalMeteorCount = world.geothermalMeteorCount + 1
    a.geothermalSeed = NewSeed()
  end

  a.velocityImpact = a.velocityImpactKm * 1000
  a.angleImpactRadians = a.angleImpact * radiansPerAngle
  a.diameterTransient = 1.161 * ((a.densityImpactor / world.density) ^ 0.33) * (a.diameterImpactor ^ 0.78) * (a.velocityImpact ^ 0.44) * (world.gravity ^ -0.22) * (math.sin(a.angleImpactRadians) ^ 0.33)
  a.diameterSimple = a.diameterTransient * 1.25
  a.depthTransient = a.diameterTransient / twoSqrtTwo
  a.rimHeightTransient = a.diameterTransient / 14.1
  a.rimHeightSimple = 0.07 * ((a.diameterTransient ^ 4) / (a.diameterSimple ^ 3))
  a.brecciaVolume = 0.032 * (a.diameterSimple ^ 3)
  a.brecciaDepth = 2.8 * a.brecciaVolume * ((a.depthTransient + a.rimHeightTransient) / (a.depthTransient * a.diameterSimple * a.diameterSimple))
  a.depthSimple = a.depthTransient - a.brecciaDepth

  a.rayWidth = 0.07 -- in radians

  a.craterRimHeight = a.rimHeightSimple / world.metersPerElmo

  a.heightWobbleAmount = MinMaxRandom(0.15, 0.35)
  a.distSeed = NewSeed()
  a.heightSeed = NewSeed()
  a.blastSeed = NewSeed()
  a.rayWobbleAmount = MinMaxRandom(0.3, 0.4)
  a.raySeed = NewSeed()

  a.complex = a.diameterTransient > world.complexDiameterCutoff
  if a.complex then
    a.bowlPower = 3
    local Dtc = a.diameterTransient / 1000
    local Dc = world.complexDiameter / 1000
    a.diameterComplex = 1.17 * ((Dtc ^ 1.13) / (Dc ^ 0.13))
    a.depthComplex = (1.04 / world.complexDepthScaleFactor) * (a.diameterComplex ^ 0.301)
    a.diameterComplex = a.diameterComplex * 1000
    a.depthComplex = a.depthComplex * 1000
    a.craterDepth = (a.depthComplex + a.rimHeightSimple) / world.metersPerElmo
    if world.rimTerracing then
      a.craterDepth = a.craterDepth * 0.6
      local terraceNum = mCeil(a.diameterTransient / world.complexDiameterCutoff)
      a.terraceSeeds = {}
      for i = 1, terraceNum do a.terraceSeeds[i] = NewSeed() end
    end
    a.mass = (pi * (a.diameterImpactor ^ 3) / 6) * a.densityImpactor
    a.energyImpact = 0.5 * a.mass * (a.velocityImpact^2)
    a.meltVolume = 8.9 * 10^(-12) * a.energyImpact * math.sin(a.angleImpactRadians)
    a.meltThickness = (4 * a.meltVolume) / (pi * (a.diameterTransient ^ 2))
    a.craterRadius = (a.diameterComplex / 2) / world.metersPerElmo
    a.craterMeltThickness = a.meltThickness / world.metersPerElmo
    a.meltSurface = a.craterRimHeight + a.craterMeltThickness - a.craterDepth
    -- spEcho(a.energyImpact, a.meltVolume, a.meltThickness)
    a.craterPeakHeight = a.craterDepth * 0.5
    a.peakRadialSeed = NewSeed()
    a.peakRadialNoise = WrapNoise(16, 0.75, a.peakRadialSeed)
    a.peakSeed = NewSeed()
    a.distWobbleAmount = MinMaxRandom(0.1, 0.2)
    a.distNoise = WrapNoise(mMax(mCeil(a.craterRadius / 20), 8), a.distWobbleAmount, a.distSeed, 0.4, 4)
    -- spEcho( mFloor(a.diameterImpactor), mFloor(a.diameterComplex), mFloor(a.depthComplex), a.diameterComplex/a.depthComplex, mFloor(a.diameterTransient), mFloor(a.depthTransient) )
  else
    a.bowlPower = 1
    a.craterDepth = ((a.depthSimple + a.rimHeightSimple)  ) / world.metersPerElmo
    -- a.craterDepth = a.craterDepth * mMin(1-a.ageRatio, 0.5)
    a.craterRadius = (a.diameterSimple / 2) / world.metersPerElmo
    a.craterFalloff = a.craterRadius * 0.66
    a.rayHeight = (a.craterRimHeight / 2)
    a.distWobbleAmount = MinMaxRandom(0.05, 0.15)
    a.distNoise = WrapNoise(mMax(mCeil(a.craterRadius / 35), 8), a.distWobbleAmount, a.distSeed, 0.3, 5)
    a.rayNoise = WrapNoise(24, a.rayWobbleAmount, a.raySeed, 0.5, 3)
  end

  a.heightNoise = WrapNoise(mMax(mCeil(a.craterRadius / 45), 8), a.heightWobbleAmount, a.heightSeed)
  if a.age < 10 then
    a.blastNoise = WrapNoise(mMin(mMax(mCeil(a.craterRadius), 32), 512), 0.5, a.blastSeed, 1, 1)
    -- spEcho(a.blastNoise.length)
  end
end)

WrapNoise = class(function(a, length, intensity, seed, persistence, N, amplitude)
  a.noiseType = "Wrap"
  local values = {}
  a.outValues = {}
  a.absMaxValue = 0
  a.angleDivisor = twicePi / length
  a.length = length
  a.intensity = intensity or 1
  seed = seed or NewSeed()
  a.seed = seed
  a.halfLength = length / 2
  persistence = persistence or 0.25
  N = N or 6
  amplitude = amplitude or 1
  a.persistance = persistance
  a.N = N
  a.amplitude = amplitude
  local radius = mCeil(length / pi)
  local diameter = radius * 2
  local yx = perlin2D( seed, diameter+1, diameter+1, persistence, N, amplitude )
  local i = 1
  local angleIncrement = twicePi / length
  for angle = -pi, pi, angleIncrement do
    local x = mFloor(radius + (radius * math.cos(angle))) + 1
    local y = mFloor(radius + (radius * math.sin(angle))) + 1
    local val = yx[y][x]
    if mAbs(val) > a.absMaxValue then a.absMaxValue = mAbs(val) end
    values[i] = val
    i = i + 1
  end
  for n, v in ipairs(values) do
    a.outValues[n] = (v / a.absMaxValue) * a.intensity
  end
end)

TwoDimensionalNoise = class(function(a, seed, sideLength, intensity, persistence, N, amplitude, blackValue, whiteValue, doNotNormalize)
  a.noiseType = "TwoDimensional"
  a.sideLength = mCeil(sideLength)
  a.halfSideLength = mFloor(a.sideLength / 2)
  a.intensity = intensity or 1
  persistence = persistence or 0.25
  N = N or 5
  amplitude = amplitude or 1
  seed = seed or NewSeed()
  a.yx = perlin2D( seed, sideLength+1, sideLength+1, persistence, N, amplitude )
  blackValue = blackValue or 0
  whiteValue = whiteValue or 1
  a.seed = seed
  a.persistence = persistence
  a.N = N
  a.amplitude = amplitude
  a.blackValue = blackValue
  a.whiteValue = whiteValue
  a.doNotNormalize = doNotNormalize
  if not doNotNormalize then
    local vmin, vmax = 0, 0
    for y, xx in ipairs(a.yx) do
      for x, v in ipairs(xx) do
        if v > vmax then vmax = v end
        if v < vmin then vmin = v end
      end
    end
    local vd = vmax - vmin
    -- spEcho("vmin", vmin, "vmax", vmax, "vd" , vd)
    a.xy = {}
    for y, xx in ipairs(a.yx) do
      for x, v in ipairs(xx) do
        a.xy[x] = a.xy[x] or {}
        local nv = (v - vmin) / vd
        nv = mMax(nv - blackValue, 0) / (1-blackValue)
        nv = mMin(nv, whiteValue) / whiteValue
        a.xy[x][y] = nv * a.intensity
      end
    end
    a.yx = nil
  end
end)

-- end classes ---------------------------------------------------------------

-- class methods: ------------------------------------------------------------

function World:Clear()
  self.heightBuf = HeightBuffer(self, heightMapRuler)
  self.meteors = {}
  self.renderers = {}
  self.metalMeteorCount = 0
  self.geothermalMeteorCount = 0
  SendToUnsynced("ClearMeteors")
  SendToUnsynced("RenderStatus", "none")
  if not bypassSpring then
    spLevelHeightMap(0, 0, Game.mapSizeX, Game.mapSizeZ, self.baselevel)
  end
end

function World:Save(name)
  name = name or ""
  FWriteOpen("world"..name, "lua", "w")
  FWrite("return ")
  serialize(self)
  FWriteClose()
end

function World:Load(luaStr)
  self:Clear()
  local loadWorld = loadstring(luaStr)
  local newWorld = loadWorld()
  for k, v in pairs(newWorld) do
    self[k] = v
  end
  SendToUnsynced("ClearMeteors")
  for i, m in pairs(self.meteors) do
    local newm = Meteor(self)
    for k, v in pairs(m) do
      if k ~= "world" then
        newm[k] = v
      end
    end
    m = newm
    m:BuildNoise()
    self.meteors[i] = m
    m:Pass()
  end
  self.heightBuf.changesPending = true
  spEcho("world loaded with " .. #self.meteors .. " meteors")
end

function World:MeteorShower(number, minDiameter, maxDiameter, minVelocity, maxVelocity, minAngle, maxAngle, minDensity, maxDensity, underlyingMare)
  number = number or 3
  minDiameter = minDiameter or 1
  maxDiameter = maxDiameter or 500
  minVelocity = minVelocity or 10
  maxVelocity = maxVelocity or 72
  -- minDiameter = minDiameter^0.01
  -- maxDiameter = maxDiameter^0.01
  minAngle = minAngle or 30
  maxAngle = maxAngle or 60
  minDensity = minDensity or 4000
  maxDensity = maxDensity or 10000
  if underlyingMare then
    self:AddMeteor(Game.mapSizeX/2, Game.mapSizeZ/2, MinMaxRandom(600, 800), 50, 60, 8000, 100, nil, nil, true)
  end
  local hundredConv = 100 / number
  local diameterDif = maxDiameter - minDiameter
  for n = 1, number do
    -- local diameter = MinMaxRandom(minDiameter, maxDiameter)^100
    local diameter = minDiameter + (mAbs(DiceRoll(65)-0.5) * diameterDif * 2)
    -- spEcho(diameter)
    local velocity = MinMaxRandom(minVelocity, maxVelocity)
    local angle = MinMaxRandom(minAngle, maxAngle)
    local density = MinMaxRandom(minDensity, maxDensity)
    local x = mFloor(mRandom() * Game.mapSizeX)
    local z = mFloor(mRandom() * Game.mapSizeZ)
    self:AddMeteor(x, z, diameter, velocity, angle, density, mFloor((number-n)*hundredConv))
  end
  spEcho(self.metalMeteorCount, self.geothermalMeteorCount)
end

function World:AddMeteor(sx, sz, diameterImpactor, velocityImpactKm, angleImpact, densityImpactor, age, metal, geothermal, doNotMirror)
  local m = Meteor(self, sx, sz, diameterImpactor, velocityImpactKm, angleImpact, densityImpactor, age, metal, geothermal)
  tInsert(self.meteors, m)
  m:Pass()
  if self.mirror ~= "none" and not doNotMirror then
    local nsx, nsz
    if self.mirror == "reflectionalx" then
      nsx = Game.mapSizeX - sx
      nsz = sz+0
    elseif self.mirror == "reflectionalz" then
      nsx = sx+0
      nsz = Game.mapSizeZ - sz
    elseif self.mirror == "rotational" then
      nsx = Game.mapSizeX - sx
      nsz = Game.mapSizeZ - sz
    end
    if nsx then
      self:AddMeteor(nsx, nsz, VaryWithinBounds(diameterImpactor, 0.1, 1, 9999), VaryWithinBounds(velocityImpactKm, 0.1, 1, 120), VaryWithinBounds(angleImpact, 0.1, 1, 89), VaryWithinBounds(densityImpactor, 0.1, 1000, 10000), age, tostring(m.metal), tostring(m.geothermal), true)
    end
  end
  self.heightBuf.changesPending = true
end

function World:RenderHeightSpring(uiCommand)
  if bypassSpring then return end
  if self.heightBuf.changesPending then
    self.heightBuf:Clear()
    local renderer = Renderer(self, heightMapRuler, 4000, "Height", uiCommand, self.heightBuf)
    tInsert(self.renderers, renderer)
  end
  tInsert(self.renderers, Renderer(self, heightMapRuler, 6000, "HeightSpring", uiCommand, self.heightBuf, true))
end

function World:RenderAttributes(uiCommand, mapRuler)
  mapRuler = mapRuler or heightMapRuler
  local renderer = Renderer(self, mapRuler, 8000, "Attributes", uiCommand)
  tInsert(self.renderers, renderer)
end

function World:RenderHeightImage(uiCommand, mapRuler)
  mapRuler = mapRuler or L3DTMapRuler
  doNotStore = true
  ClearSpeedupStorage()
  self.heightBuf = nil
  local tempHeightBuf = HeightBuffer(self, mapRuler)
  tInsert(self.renderers, Renderer(self, mapRuler, 4000, "Height", uiCommand, tempHeightBuf))
  tInsert(self.renderers, Renderer(self, mapRuler, 15000, "HeightImage", uiCommand, tempHeightBuf, true))
end

function World:RenderMetal(uiCommand)
  local renderer = Renderer(self, metalMapRuler, 16000, "Metal", uiCommand, nil, true)
  tInsert(self.renderers, renderer)
end

function World:RenderFeatures(uiCommand)
  FWriteOpen("features", "lua", "w")
  FWrite("local setcfg = {\n\tunitlist = {\n\t},\n\tbuildinglist = {\n\t},\n\tobjectlist = {\n")
  for i, m in pairs(self.meteors) do
    if m.geothermal then
      FWrite("\t\t{ name = 'GeoVent', x = " .. m.sx .. ", z = " .. m.sz .. ", rot = \"180\" },\n")
    end
  end
  FWrite("\t},\n}\nreturn setcfg")
  FWriteClose()
  spEcho("wrote features lua")
end

--------------------------------------

function MapRuler:XZtoXY(x, z)
  if self.elmosPerPixel == 1 then
    return x+1, (Game.mapSizeZ - z)+1
  else
    local hx = mFloor(x / self.elmosPerPixel) + 1
    local hy = mFloor((Game.mapSizeZ - z) / self.elmosPerPixel) + 1
    return hx, hy
  end
end

function MapRuler:XYtoXZ(x, y)
  if self.elmosPerPixel == 1 then
    return x-1, (Game.mapSizeZ - (y-1))
  else
    local sx = mFloor((x-1) * self.elmosPerPixel)
    local sz = mFloor(Game.mapSizeZ - ((y-1) * self.elmosPerPixel))
    -- if y == self.height then spEcho(y, sz, Game.mapSizeZ, self.elmosPerPixel, y-1) end
    return sx, sz
  end
end

function MapRuler:RadiusBounds(x, y, radius)
  local w, h = self.width, self.height
  local xmin = mFloor(x - radius)
  local xmax = mCeil(x + radius)
  local ymin = mFloor(y - radius)
  local ymax = mCeil(y + radius)
  if xmin < 1 then xmin = 1 end
  if xmax > w then xmax = w end
  if ymin < 1 then ymin = 1 end
  if ymax > h then ymax = h end
  return xmin, xmax, ymin, ymax
end

--------------------------------------

function HeightBuffer:CoordsOkay(x, y)
  if not self.heights[x] then
    -- spEcho("no row at ", x)
    return
  end
  if not self.heights[x][y] then
    -- spEcho("no pixel at ", x, y)
    return
  end
  return true
end

function HeightBuffer:MinMaxCheck(height)
  if height > self.maxHeight then self.maxHeight = height end
  if height < self.minHeight then self.minHeight = height end
end

function HeightBuffer:Write(x, y, height)
  if not self.directToSpring then return end
  local sx, sz = self.mapRuler:XYtoXZ(x, y)
  spLevelHeightMap(sx, sz, sx+8, sz-8, self.world.baselevel+height)
end

function HeightBuffer:Add(x, y, height, alpha)
  if not self:CoordsOkay(x, y) then return end
  alpha = alpha or 1
  local newHeight = self.heights[x][y] + (height * alpha)
  self.heights[x][y] = newHeight
  self:MinMaxCheck(newHeight)
  self:Write(x, y, newHeight)
end

function HeightBuffer:Blend(x, y, height, alpha, secondary)
  if not self:CoordsOkay(x, y) then return end
  alpha = alpha or 1
  if alpha < 1 and self.heights[x][y] > height then alpha = alpha * alpha end
  local orig = 1 - alpha
  local newHeight = (self.heights[x][y] * orig) + (height * alpha)
  self.heights[x][y] = newHeight
  self:MinMaxCheck(newHeight)
  self:Write(x, y, newHeight)
  if not secondary and self.antiAlias then
    for xx = -1, 1 do
      for yy = -1, 1 do
        if not (xx == 0 and yy == 0 ) then
          if xx == 0 or yy == 0 then
            self:Blend(x+xx, y+yy, height, alpha*0.5, true)
          else
            -- self:Blend(x+xx, y+yy, height, alpha*0.355, true)
          end
        end
      end
    end
  end
end

function HeightBuffer:Set(x, y, height)
  if not self:CoordsOkay(x, y) then return end
  self.heights[x][y] = height
  self:MinMaxCheck(height)
  self:Write(x, y, height)
end

function HeightBuffer:Get(x, y)
  if not self:CoordsOkay(x, y) then return end
  return self.heights[x][y]
end

function HeightBuffer:GetCircle(x, y, radius)
  local xmin, xmax, ymin, ymax = self.mapRuler:RadiusBounds(x, y, radius)
  local totalHeight = 0
  local totalWeight = 0
  local minHeight = 99999
  local maxHeight = -99999
  for x = xmin, xmax do
    for y = ymin, ymax do
      local height = self:Get(x, y)
      totalHeight = totalHeight + height
      totalWeight = totalWeight + 1
      if height < minHeight then minHeight = height end
      if height > maxHeight then maxHeight = height end
    end
  end
  return totalHeight / totalWeight, minHeight, maxHeight
end

function HeightBuffer:Blur(radius, uiCommand)
  radius = radius or 1
  tInsert(self.world.renderers, Renderer(self.world, self.mapRuler, 2000, "HeightBlur", uiCommand, self, true, radius))
end

function HeightBuffer:WriteToSpring(uiCommand)
  if bypassSpring then return end
  tInsert(self.world.renderers, Renderer(self.world, self.mapRuler, 6000, "HeightSpring", uiCommand, self, true))
end

function HeightBuffer:Read()
  for sx=0,Game.mapSizeX, Game.squareSize do
    for sz=Game.mapSizeZ,0, -Game.squareSize do
      local x, y = XZtoHXHY(sx, sz)
      local height = (spGetGroundHeight(sx, sz) - self.world.baselevel) / 8
      self:Set(x, y, height)
    end
  end
  spEcho("height buffer read from map")
end

function HeightBuffer:SendFile(uiCommand)
  if self.changesPending then
    tInsert(self.world.renderers, Renderer(self.world, self.mapRuler, 4000, "Height", uiCommand, self))
  end
  tInsert(self.world.renderers, Renderer(self.world, self.mapRuler, 15000, "HeightImage", uiCommand, self, true))
end

function HeightBuffer:Clear()
  for x = 1, self.w do
    for y = 1, self.h do
      -- self:Set(x, y, 0)
      self.heights[x][y] = 0
    end
  end
  self.minHeight = 0
  self.maxHeight = 0
end

--------------------------------------

function Renderer:Preinitialize()
  self:PreinitFunc()
  self.preInitialized = true
end

function Renderer:Initialize()
  spEcho("initializing " .. self.renderType)
  self.totalProgress = self.totalPixels
  self:InitFunc()
  self.initialized = true
end

function Renderer:Frame()
  if not self.initialized then self:Initialize() end
  local progress = self:FrameFunc()
  if progress then
    self.progress = (self.progress or 0) + progress
    SendToUnsynced("RenderStatus", self.renderType, self.progress, self.totalProgress)
  else
    SendToUnsynced("RenderStatus", "none")
  end
  if self.progress > self.totalProgress or not progress then
    -- spEcho(self.progress .. " / " .. self.totalProgress)
    self:Finish()
    SendToUnsynced("RenderStatus", "none")
  end
end

function Renderer:Finish()
  self:FinishFunc()
  if not self.dontEndUiCommand then EndCommand(self.uiCommand) end
  local frameDiff = spGetGameFrame() - self.startFrame
  spEcho(self.renderType .. " (" .. self.mapRuler.width .. "x" .. self.mapRuler.height .. ") rendered in " .. frameDiff .. " frames")
  self.complete = true
end

function Renderer:EmptyPreinit()
  return
end

function Renderer:EmptyInit()
  -- spEcho("emptyinit")
  return
end

 function Renderer:EmptyFinish()
  -- spEcho("emptyfinish")
  return
end

function Renderer:HeightInit()
  self.totalProgress = self.totalCraterArea
end

function Renderer:HeightFrame()
  local pixelsRendered = 0
  while pixelsRendered < self.pixelsPerFrame and #self.craters > 0 do
    local c = self.craters[1]
    c:GiveStartingHeight()
    while c.currentPixel <= c.area and pixelsRendered < self.pixelsPerFrame do
      local x, y, height, alpha, add = c:OneHeightPixel()
      if height then
        -- if add then
          -- self.heightBuf:Add(x, y, height, alpha)
        -- else
          self.heightBuf:Blend(x, y, height+c.startingHeight, alpha)
        -- end
        pixelsRendered = pixelsRendered + 1
      end
    end
    if c.currentPixel > c.area then
      c.complete = true
      tRemove(self.craters, 1)
      c = nil
    end
    if pixelsRendered == self.pixelsPerFrame then break end
  end
  return pixelsRendered
end

function Renderer:HeightFinish()
  -- spLevelHeightMap(0, 0, Game.mapSizeX, Game.mapSizeZ, self.world.baselevel)
  if not self.heightBuf.directToSpring then
    -- self.heightBuf:WriteToSpring(self.uiCommand)
    self.dontEndUiCommand = true
  end
  self.heightBuf.changesPending = nil
end

function Renderer:HeightSpringFrame()
  local pixelsThisFrame = mMin(self.pixelsPerFrame, self.pixelsToRenderCount)
  local pMin = self.totalPixels - self.pixelsToRenderCount
  local pMax = pMin + pixelsThisFrame
  spSetHeightMapFunc(function()
    for p = pMin, pMax do
      local x = (p % self.mapRuler.width) + 1
      local y = mFloor(p / self.mapRuler.width) + 1
      local sx, sz = self.mapRuler:XYtoXZ(x, y)
      local height = (self.heightBuf:Get(x, y) or 0) --* self.elmosPerPixel -- because the horizontal is all scaled to the heightmap
      local set = spSetHeightMap(sx, sz, self.world.baselevel+height)
      if not set then spEcho("bad setheightmap coordinate", sx, sz, x, y) end
    end
  end)
  self.pixelsToRenderCount = self.pixelsToRenderCount - pixelsThisFrame - 1
  return pixelsThisFrame + 1
end

function Renderer:HeightSpringFinish()
  spEcho("height buffer written to map")
end

function Renderer:HeightImageInit()
  FWriteOpen("height", "pgm")
  FWrite("P5 " .. tostring(self.mapRuler.width) .. " " .. tostring(self.mapRuler.height) .. " " .. 65535 .. " ")
end

function Renderer:HeightImageFrame()
  local pixelsThisFrame = mMin(self.pixelsPerFrame, self.pixelsToRenderCount)
  local pMin = self.totalPixels - self.pixelsToRenderCount
  local pMax = pMin + pixelsThisFrame
  local heightBuf = self.heightBuf
  local heightDif = (heightBuf.maxHeight - heightBuf.minHeight)
  for p = pMin, pMax do
    local x = (p % self.mapRuler.width) + 1
    local y = self.mapRuler.height - mFloor(p / self.mapRuler.width) --pgm goes backwards y?
    local pixelHeight = heightBuf:Get(x, y) or self.world.baselevel
    local pixelColor = mFloor(((pixelHeight - heightBuf.minHeight) / heightDif) * 65535)
    local twochars = uint16big(pixelColor)
    FWrite(twochars)
  end
  self.pixelsToRenderCount = self.pixelsToRenderCount - pixelsThisFrame - 1
  return pixelsThisFrame + 1
end

function Renderer:HeightImageFinish()
  FWriteClose()
  spEcho("height File sent")
  FWriteOpen("heightrange", "txt", "w")
  FWrite(
    "min: " .. self.heightBuf.minHeight .. "\n\r" ..
    "max: " .. self.heightBuf.maxHeight .. "\n\r" ..
    "range: " .. (self.heightBuf.maxHeight - self.heightBuf.minHeight))
  FWriteClose()
  if self.mapRuler ~= heightMapRuler then
    doNotStore = false
    local world = self.heightBuf.world
    self.heightBuf = nil
    world.heightBuf = HeightBuffer(world, heightMapRuler)
  end
end

function Renderer:HeightBlurInit()
  self.sradius = mCeil(self.radius * 2.57)
  local radiusTwoSq = self.radius * self.radius * 2
  local radiusTwoSqPi = radiusTwoSq * pi
  self.weights = {}
  for dx = -self.sradius, self.sradius do
    self.weights[dx] = {}
    for dy = -self.sradius, self.sradius do
      local distSq = (dx*dx) + (dy*dy)
      local weight = mExp(-distSq / radiusTwoSq) / radiusTwoSqPi
      self.weights[dx][dy] = weight
    end
  end
  self.newHeights = {}
end

function Renderer:HeightBlurFrame()
  local heightBuf = self.heightBuf
  local pixelsThisFrame = mMin(self.pixelsPerFrame, self.pixelsToRenderCount)
  local pMin = self.totalPixels - self.pixelsToRenderCount
  local pMax = pMin + pixelsThisFrame
  for p = pMin, pMax do
    local x = (p % self.mapRuler.width) + 1
    local y = mFloor(p / self.mapRuler.width) + 1
    local center = heightBuf:Get(x, y)
    local totalWeight = 0
    local totalHeight = 0
    local same = true
    for dx = -self.sradius, self.sradius do
      for dy = -self.sradius, self.sradius do
        local h = heightBuf:Get(x+dx, y+dy)
        if h ~= center then
          same = false
          break
        end
      end
      if not same then break end
    end
    local newH
    if same then
      newH = center
    else
      for dx = -self.sradius, self.sradius do
        for dy = -self.sradius, self.sradius do
          local h = heightBuf:Get(x+dx, y+dy)
          if h then
            local weight = self.weights[dx][dy]
            totalHeight = totalHeight + (h * weight)
            totalWeight = totalWeight + weight
          end
        end
      end
      newH = totalHeight / totalWeight
    end
    self.newHeights[x] = self.newHeights[x] or {}
    self.newHeights[x][y] = newH
  end
  self.pixelsToRenderCount = self.pixelsToRenderCount - pixelsThisFrame - 1
  return pixelsThisFrame + 1
end

function Renderer:HeightBlurFinish()
  local heightBuf = self.heightBuf
  for x = 1, self.mapRuler.width do
    for y = 1, self.mapRuler.height do
      heightBuf:Set(x, y, self.newHeights[x][y])
    end
  end
end

function Renderer:AttributesInit()
  FWriteOpen("attrib", "pbm")
  FWrite("P6 " .. tostring(self.mapRuler.width) .. " " .. tostring(self.mapRuler.height) .. " 255 ")
end

function Renderer:AttributesFrame()
  local pixelsThisFrame = mMin(self.pixelsPerFrame, self.pixelsToRenderCount)
  local pMin = self.totalPixels - self.pixelsToRenderCount
  local pMax = pMin + pixelsThisFrame
  for p = pMin, pMax do
    local x = (p % self.mapRuler.width) + 1
    local y = self.mapRuler.height - mFloor(p / self.mapRuler.width) -- pgm is backwards y?
    -- if p < 2000 then spEcho(p, x, y) end
    local attribute = 0
    for i, c in ipairs(self.craters) do
      local a = c:AttributePixel(x, y)
      if a ~= 0 and not AttributeOverlapExclusions[a][attribute] then
        attribute = a
      end
    end
    -- local aRGB = {mFloor((x / self.world.renderWidth) * 255), mFloor((y / self.world.renderHeight) * 255), mFloor((p / self.world.totalPixels) * 255)}
    local threechars = AttributeDict[attribute].threechars
    FWrite(threechars)
  end
  self.pixelsToRenderCount = self.pixelsToRenderCount - pixelsThisFrame - 1
  return pixelsThisFrame + 1
end

function Renderer:AttributesFinish()
  FWriteClose()
  spEcho("attribute File sent")
end

function Renderer:MetalPreinit()
  self.metalSpots = {}
  for i, meteor in pairs(self.world.meteors) do
    if meteor.metal then
      local spot = { x = meteor.sx, z = meteor.sz, metal = self.world.metalSpotAmount }
      tInsert(self.metalSpots, spot)
    end
  end
  spEcho(#self.metalSpots .. " metal spots")
end

function Renderer:MetalInit()
  FWriteOpen("metal", "lua", "w")
  FWrite("return {\n\tspots = {\n")
  ClearMetalMap()
  for i, spot in pairs(self.metalSpots) do
    FWrite("\t\t{x = " .. spot.x .. ", z = " .. spot.z .. ", metal = " .. spot.metal .. "},\n")
    WriteMetalSpot(spot)
  end
  FWrite("\t}\n}")
  FWriteClose()
  spEcho("wrote metal to map and config lua")
  FWriteOpen("metal", "pbm")
  FWrite("P6 " .. tostring(self.mapRuler.width) .. " " .. tostring(self.mapRuler.height) .. " 255 ")
  self.zeroTwoChars = string.char(0) .. string.char(0)
  self.blackThreeChars = string.char(0) .. string.char(0) .. string.char(0)
end

function Renderer:MetalFrame()
  local pixelsThisFrame = mMin(self.pixelsPerFrame, self.pixelsToRenderCount)
  local pMin = self.totalPixels - self.pixelsToRenderCount
  local pMax = pMin + pixelsThisFrame
  for p = pMin, pMax do
    local x = (p % self.mapRuler.width) + 1
    local y = self.mapRuler.height - mFloor(p / self.mapRuler.width) -- pgm is backwards y?
    local threechars = self.blackThreeChars
    local sx, sz = self.mapRuler:XYtoXZ(x, y)
    local mx, mz = mCeil(sx/16)-1, mCeil(sz/16)-1
    local mAmount = spGetMetalAmount(mx, mz)
    if mAmount > 0 then
      -- assumes maxmetal is 1.0
      -- if i knew how to get the map's maxmetal, i would
      threechars = string.char(mAmount) .. self.zeroTwoChars
    end
    FWrite(threechars)
  end
  self.pixelsToRenderCount = self.pixelsToRenderCount - pixelsThisFrame - 1
  return pixelsThisFrame + 1
end

function Renderer:MetalFinish()
  FWriteClose()
  spEcho("metal File sent")
end

--------------------------------------

function Crater:GetDistanceSq(x, y)
  local dx, dy = mAbs(x-self.x), mAbs(y-self.y)
  if doNotStore then return ((dx*dx) + (dy*dy)) end
  diffDistancesSq[dx] = diffDistancesSq[dx] or {}
  diffDistancesSq[dx][dy] = diffDistancesSq[dx][dy] or ((dx*dx) + (dy*dy))
  return diffDistancesSq[dx][dy]
end

function Crater:GetDistance(x, y)
  local dx, dy = mAbs(x-self.x), mAbs(y-self.y)
  if doNotStore then return sqrt((dx*dx) + (dy*dy)) end
  diffDistances[dx] = diffDistances[dx] or {}
  if not diffDistances[dx][dy] then
    local distSq = self:GetDistanceSq(x, y)
    diffDistances[dx][dy] = sqrt(distSq)
  end
  return diffDistances[dx][dy], diffDistancesSq[dx][dy]
end

function Crater:TerraceDistMod(distSq)
  if self.terraces then
    for i, t in ipairs(self.terraces) do
      local here = t.max - t.noise:Radial(angle)
      if distSq <= here then
        local below, belowMax
        if self.terraces[i-1] then
          below = self.terraces[i-1].max - self.terraces[i-1].noise:Radial(angle)
          belowMax = self.terraces[i-1].max
        else
          below = self.terraceMin
          belowMax = self.terraceMin
        end
        if distSq >= below then
          local ratio = mSmoothstep(below, here, distSq)
          distSq = mMix(belowMax, t.max, ratio)
          break
        end
      elseif i == #self.terraces and distSq > here and distSq < self.radiusSq then
        local ratio = mSmoothstep(here, self.radiusSq, distSq)
        distSq = mMix(t.max, self.radiusSq, ratio)
      end
    end
  end
  return distSq
end

function Crater:HeightPixel(x, y)
  local meteor = self.meteor
  local dx, dy = x-self.x, y-self.y
  local angle = AngleDXDY(dx, dy)
  local distWobbly = meteor.distNoise:Radial(angle) + 1
  local realDistSq = self:GetDistanceSq(x, y)
  -- local realRimRatio = realDistSq / radiusSq
  local distSq = realDistSq * distWobbly
  distSq = Crater:TerraceDistMod(distSq)
  local rimRatio = distSq / self.radiusSq
  local heightWobbly = (meteor.heightNoise:Radial(angle) * rimRatio) + 1
  local height = 0
  local alpha = 1
  local rimHeight = meteor.craterRimHeight * heightWobbly
  local rimRatioPower = rimRatio ^ meteor.bowlPower
  local add = false
  if distSq <= self.radiusSq then
    if meteor.age > 0 then
      local smooth = mSmoothstep(0, 1, rimRatio)
      rimRatioPower = mMix(rimRatioPower, smooth, meteor.ageRatio)
    end
    height = rimHeight - ((1 - rimRatioPower)*meteor.craterDepth)
    if meteor.complex then
      if self.peakNoise then
        local distSqPeakWobbled = distSq * (1+meteor.peakRadialNoise:Radial(angle))
        if distSqPeakWobbled < self.peakRadiusSq then
          local peakRatio = 1 - (distSqPeakWobbled / self.peakRadiusSq)
          peakRatio = mSmoothstep(0, 1, peakRatio)
          local px, py = mFloor(dx+self.peakNoise.halfSideLength+3), mFloor(dy+self.peakNoise.halfSideLength+3)
          local peak = self.peakNoise:Get(px, py) * peakRatio
          height = height + peak
        end
      end
      if height < meteor.meltSurface then height = meteor.meltSurface end
    elseif meteor.age < 15 then
      local rayWobbly = meteor.rayNoise:Radial(angle) + 1
      local rayWidth = meteor.rayWidth * rayWobbly
      local rayWidthMult = twicePi / rayWidth
      local rayHeight = mMax(math.sin(rayWidthMult * angle) - 0.75, 0) * meteor.rayHeight * heightWobbly * rimRatio
      height = height - rayHeight
    end
  else
    add = true
    height = rimHeight
    local fallDistSq = distSq - self.radiusSq
    if fallDistSq <= self.falloffSq then
      local gaussDecay = Gaussian(fallDistSq, self.falloffSqFourth)
      -- local gaussDecay = 1 - mSmoothstep(0, self.falloffSq, fallDistSq)
      -- local linearToHalfGrowth = mMin(fallDistSq / self.falloffSqFourth, 1)
      -- local linearToHalfDecay = 1 - linearToHalfGrowth
      local linearGrowth = mMin(fallDistSq / self.falloffSq, 1)
      local linearDecay = 1 - linearGrowth
      local secondDecay = 1 - (linearGrowth^0.5)
      alpha = (gaussDecay * linearGrowth) + (secondDecay * linearDecay)
      if meteor.age > 0 then
        local smooth = mSmoothstep(0, 1, linearDecay)
        alpha = mMix(alpha, smooth, meteor.ageRatio)
      end
      -- height = diameterTransientFourth / (112 * (fallDistSq^1.5))
    else
      alpha = 0
    end
  end
  return height, alpha, add
end

function Crater:OneHeightPixel()
  local p = self.currentPixel
  local x = (p % self.width) + self.xmin
  local y = mFloor(p / self.width) + self.ymin
  self.currentPixel = self.currentPixel + 1
  local height, alpha, add = self:HeightPixel(x, y)
  return x, y, height, alpha, add
end

function Crater:AttributePixel(x, y)
  local meteor = self.meteor
  local mapRuler = self.mapRuler
  if meteor.age >= 10 and (x < self.xmin or x > self.xmax or y < self.ymin or y > self.ymax) then return 0 end 
  if x < self.xminBlast or x > self.xmaxBlast or y < self.yminBlast or y > self.ymaxBlast then return 0 end
  local dx, dy = x-self.x, y-self.y
  local angle = AngleDXDY(dx, dy)
  local distWobbly = meteor.distNoise:Radial(angle) + 1
  local realDistSq = self:GetDistanceSq(x, y)
  -- local realRimRatio = realDistSq / radiusSq
  local distSq = realDistSq * distWobbly
  distSq = Crater:TerraceDistMod(distSq)
  if meteor.age >= 10 and distSq > self.totalradiusSq then return 0 end
  if distSq > self.blastRadiusSq then return 0 end
  local rimRatio = distSq / self.radiusSq
  local heightWobbly = (meteor.heightNoise:Radial(angle) * rimRatio) + 1
  local rimHeight = meteor.craterRimHeight * heightWobbly
  local rimRatioPower = rimRatio ^ meteor.bowlPower
  local height
  if distSq <= self.radiusSq then
    height = rimHeight - ((1 - rimRatioPower)*meteor.craterDepth)
    if self.geothermalNoise and distSq < self.geothermalNoise:Radial(angle) then
      return 8
    end
    if self.metalNoise and distSq <= self.metalRadiusSq then
      local metalRatio = 1 - (distSq / self.metalRadiusSq)
      metalRatio = mSmoothstep(0, 1, metalRatio)
      local mx, my = mFloor(dx+self.metalNoise.halfSideLength+3), mFloor(dy+self.metalNoise.halfSideLength+3)
      local metal = self.metalNoise:Get(mx, my) * metalRatio
      if metal > 0.25 then return 7 end
    end
    if meteor.complex then
      if self.peakNoise then
        local distSqPeakWobbled = distSq * (1+meteor.peakRadialNoise:Radial(angle))
        if distSqPeakWobbled < self.peakRadiusSq then
          local peakRatio = 1 - (distSqPeakWobbled / self.peakRadiusSq)
          peakRatio = mSmoothstep(0, 1, peakRatio)
          local px, py = mFloor(dx+self.peakNoise.halfSideLength+3), mFloor(dy+self.peakNoise.halfSideLength+3)
          local peak = self.peakNoise:Get(px, py) * peakRatio
          if peak > 0 then return 2 end
        end
      end
      if height <= meteor.meltSurface then
        return 4
      end
    elseif meteor.age < 15 then
      local rayWobbly = meteor.rayNoise:Radial(angle) + 1
      local rayWidth = meteor.rayWidth * rayWobbly
      local rayWidthMult = twicePi / rayWidth
      local rayHeight = mMax(math.sin(rayWidthMult * angle) - 0.75, 0) * heightWobbly * rimRatio
      if rayHeight > 0.1 then return 6 end
    end
    return 1
  else
    local alpha = 0
    local fallDistSq = distSq - self.radiusSq
    if fallDistSq <= self.falloffSq then
      local gaussDecay = Gaussian(fallDistSq, self.falloffSqFourth)
      -- local gaussDecay = 1 - mSmoothstep(0, self.falloffSq, fallDistSq)
      -- local linearToHalfGrowth = mMin(fallDistSq / self.falloffSqFourth, 1)
      -- local linearToHalfDecay = 1 - linearToHalfGrowth
      local linearGrowth = mMin(fallDistSq / self.falloffSq, 1)
      local linearDecay = 1 - linearGrowth
      local secondDecay = 1 - (linearGrowth^0.5)
      alpha = (gaussDecay * linearGrowth) + (secondDecay * linearDecay)
      -- height = diameterTransientFourth / (112 * (fallDistSq^1.5))
      if mRandom() < alpha then return 3 end
    end
    if meteor.age < 10 then
      local blastWobbly = meteor.blastNoise:Radial(angle) + 0.5
      local blastRadiusSqWobbled = self.blastRadiusSq * blastWobbly
      local blastRatio = (distSq / blastRadiusSqWobbled)
      if mRandom() * mMax(1-(meteor.ageRatio*10), 0) > blastRatio then return 5 end
    end
  end
  return 0
end

function Crater:GiveStartingHeight()
  if self.startingHeight then return end
  if not self.renderer.heightBuf then return end
  local havg, hmin, hmax = self.renderer.heightBuf:GetCircle(self.x, self.y, self.radius)
  self.startingHeight = havg
end

--------------------------------------

function Meteor:Pass()
  SendToUnsynced("Meteor", self.sx, self.sz, self.diameterImpactor, self.velocityImpactKm, self.angleImpact, self.densityImpactor, self.age, self.craterRadius, self.metal, self.geothermal)
end

function Meteor:BuildNoise()
  for k, v in pairs(self) do
    if type(k) == "string" and string.sub(k, -5) == "Noise" then
      if v.noiseType == "Wrap" then
        v = WrapNoise(v.length, v.intensity, v.seed, v.persistence, v.N, v.amplitude)
      elseif v.noiseType == "TwoDimesnional" then
        v = TwoDimensionalNoise(v.seed, v.sideLength, v.intensity, v.persistence, v.N, v.amplitude, v.blackValue, v.whiteValue, v.doNotNormalize)
      end
      self[k] = v
    end
  end
end

--------------------------------------

function WrapNoise:Regenerate()
  self = WrapNoise(self.length, self.intensity, self.seed, self.persistence, self.N, self.amplitude)
end

function WrapNoise:Smooth(n)
  local n1 = mFloor(n)
  local n2 = mCeil(n)
  if n1 == n2 then return self:Output(n1) end
  local val1, val2 = self:Output(n1), self:Output(n2)
  local d = val2 - val1
  if n2 < n1 then
    -- spEcho(n, n1, n2, self.length)
  end
  return val1 + (mSmoothstep(n1, n2, n) * d)
end

function WrapNoise:Rational(ratio)
  return self:Smooth((ratio * (self.length - 1)) + 1)
end

function WrapNoise:Radial(angle)
  local n = ((angle + pi) / self.angleDivisor) + 1
  return self:Smooth(n)
end

function WrapNoise:Output(n)
  return self.outValues[self:Clamp(n)]
end

function WrapNoise:Dist(n1, n2)
  return mAbs((n1 + self.halfLength - n2) % self.length - self.halfLength)
end

function WrapNoise:Clamp(n)
  if n < 1 then
    n = n + self.length
  elseif n > self.length then
    n = n - self.length
  end
  return n
end

--------------------------------------

function TwoDimensionalNoise:Regenerate()
  self = TwoDimensionalNoise(self.seed, self.sideLength, self.intensity, self.persistence, self.N, self.amplitude, self.blackValue, self.whiteValue, self.doNotNormalize)
end

function TwoDimensionalNoise:Get(x, y)
  x, y = mFloor(x), mFloor(y)
  if self.xy then
    if not self.xy[x] then return 0 end
    if not self.xy[x][y] then return 0 end
    return self.xy[x][y]
  end
  if not self.yx then return 0 end
  if not self.yx[y] then return 0 end
  if not self.yx[y][x] then return 0 end
  return (self.yx[y][x] + 1) * self.intensity
end

-- end classes and class methods ---------------------------------------------

------------------------------------------------------------------------------

if gadgetHandler:IsSyncedCode() then -- BEGIN SYNCED -------------------------

function gadget:Initialize()
  heightMapRuler = MapRuler(nil, (Game.mapSizeX / Game.squareSize) + 1, (Game.mapSizeZ / Game.squareSize) + 1)
  metalMapRuler = MapRuler(16, (Game.mapSizeX / 16), (Game.mapSizeZ / 16))
  L3DTMapRuler = MapRuler(4, (Game.mapSizeX / 4), (Game.mapSizeZ / 4))
  myWorld = World(2.32, 1000)
end

function gadget:Shutdown()
  SendToUnsynced("ClearMeteors")
end

function gadget:RecvLuaMsg(msg, playerID)
  local words = splitIntoWords(msg)
  local where = words[1]
  if where == "loony" then
    local commandWord = words[2]
    local uiCommand = string.sub(msg, 7)
    if commandWord == "meteor" then
      local radius = words[5] / 15
      myWorld:AddMeteor(words[3], words[4], radius*2)
      myWorld:RenderHeightSpring(uiCommand)
    elseif commandWord == "shower" then
      myWorld:MeteorShower(words[3], words[4], words[5], words[6], words[7], words[8], words[9], words[10], words[11], yesMare)
      myWorld:RenderHeightSpring(uiCommand)
    elseif commandWord == "clear" then
      myWorld:Clear()
    elseif commandWord == "blur" then
      local radius = words[3] or 1
      myWorld.heightBuf:Blur(radius, uiCommand)
      myWorld.heightBuf:WriteToSpring(uiCommand)
    elseif commandWord == "read" then
      myWorld.heightBuf:Read()
    elseif commandWord == "height" then
      myWorld.heightBuf:SendFile(uiCommand)
    elseif commandWord == "attributes" then
      myWorld:RenderAttributes(uiCommand)
    elseif commandWord == "attributesl3dt" then
      myWorld:RenderAttributes(uiCommand, L3DTMapRuler)
    elseif commandWord == "heightl3dt" then
      myWorld:RenderHeightImage(uiCommand, L3DTMapRuler)
    elseif commandWord == "metal" then
      myWorld:RenderMetal(uiCommand)
    elseif commandWord == "features" then
      myWorld:RenderFeatures(uiCommand)
    elseif commandWord == "bypasstoggle" then
      bypassSpring = not bypassSpring
      spEcho("bypassSpring is now", tostring(bypassSpring))
      SendToUnsynced("BypassSpring", tostring(bypassSpring))
      myWorld:RenderHeightSpring(uiCommand)
    elseif commandWord == "underlyingmaretoggle" then
      yesMare = not yesMare
      spEcho("yesMare is now", tostring(yesMare))
    elseif commandWord == "mirror" then
      myWorld.mirror = words[3]
      spEcho("mirror: " .. myWorld.mirror)
    elseif commandWord == "mirrornext" then
      local mt = MirrorNames[myWorld.mirror]+1
      if mt == #MirrorTypes+1 then mt = 1 end
      myWorld.mirror = MirrorTypes[mt]
      spEcho("mirror: " .. myWorld.mirror)
    elseif commandWord == "save" then
      myWorld:Save(words[3])
    elseif commandWord == "load" then
      FReadOpen("world" .. (words[3] or ""), "lua", function(str) myWorld:Load(str) end)
    elseif commandWord == "fileline" then
      FReadLine(uiCommand:sub(10))
    elseif commandWord == "fileend" then
      FReadClose()
    elseif commandWord == "renderall" then
      myWorld:RenderFeatures()
      myWorld:RenderMetal()
      myWorld:RenderAttributes()
      myWorld.heightBuf:SendFile(uiCommand)
    elseif commandWord == "renderalll3dt" then
      myWorld:RenderFeatures()
      myWorld:RenderMetal()
      myWorld:RenderAttributes(nil, L3DTMapRuler)
      myWorld:RenderHeightImage(uiCommand, L3DTMapRuler)
    end
  end
end

function gadget:GameFrame(frame)
  local renderer = myWorld.renderers[1]
  if renderer then
    renderer:Frame()
    if renderer.complete then
      -- spEcho(renderer.renderType, "complete", #myWorld.renderers)
      tRemove(myWorld.renderers, 1)
      renderer = nil
    end
  end
  if not gadgetInitialized then 
    -- can't happen in gadget:Initialize() because the sync actions haven't been added yet
    SendToUnsynced("ClearMeteors")
    SendToUnsynced("BypassSpring", tostring(bypassSpring))
    gadgetInitialized = true
  end
end

end -- END SYNCED ------------------------------------------------------------

------------------------------------------------------------------------------

if not gadgetHandler:IsSyncedCode() then -- BEGIN UNSYNCED -------------------
  
local function PieceFileToLuaUI(_, dataString)
  Script.LuaUI.ReceivePieceFile(dataString)
end

local function BeginFileToLuaUI(_, name, ext, mode)
  Script.LuaUI.ReceiveBeginFile(name, ext, mode)
end

local function EndFileToLuaUI(_)
  Script.LuaUI.ReceiveEndFile()
end

local function ReadFileToLuaUI(_, name, ext)
  Script.LuaUI.ReceiveReadFile(name, ext)
end

local function MeteorToLuaUI(_, sx, sz, diameterImpactor, velocityImpactKm, angleImpact, densityImpactor, age, craterRadius, metal, geothermal)
  Script.LuaUI.ReceiveMeteor(sx, sz, diameterImpactor, velocityImpactKm, angleImpact, densityImpactor, age, craterRadius, metal, geothermal)
end

local function BypassSpringToLuaUI(_, stateString)
  Script.LuaUI.ReceiveBypassSpring(stateString)
end

local function ClearMeteorsToLuaUI(_)
  Script.LuaUI.ReceiveClearMeteors()
end

local function CompleteCommandToLuaUI(_, command)
  Script.LuaUI.ReceiveCompleteCommand(command)
end

local function RenderStatusToLuaUI(_, renderType, progress, total)
  Script.LuaUI.ReceiveRenderStatus(renderType, progress, total)
end

function gadget:Initialize()
  gadgetHandler:AddSyncAction('PieceFile', PieceFileToLuaUI)
  gadgetHandler:AddSyncAction('BeginFile', BeginFileToLuaUI)
  gadgetHandler:AddSyncAction('EndFile', EndFileToLuaUI)
  gadgetHandler:AddSyncAction('ReadFile', ReadFileToLuaUI)
  gadgetHandler:AddSyncAction('Meteor', MeteorToLuaUI)
  gadgetHandler:AddSyncAction('BypassSpring', BypassSpringToLuaUI)
  gadgetHandler:AddSyncAction('ClearMeteors', ClearMeteorsToLuaUI)
  gadgetHandler:AddSyncAction('CompleteCommand', CompleteCommandToLuaUI)
  gadgetHandler:AddSyncAction('RenderStatus', RenderStatusToLuaUI)
end

end -- END UNSYNCED ----------------------------------------------------------