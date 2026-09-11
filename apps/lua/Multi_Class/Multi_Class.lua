local driverCount                 = 0
local allDriversStartingPos       = {}
local raceHasStarted              = false
local firstFrame                  = true
local leaderboardOpened           = false
local lastSessionIndex            = nil
local lastSessionStarted          = nil

local driverClass                 = {}
local classOrder                  = {}
local releaseClasses              = {}
local manualDriverClass           = {}
local classAddInput               = ""
local classAddError               = nil
local carClassCache               = {}
local uiSourceCache               = {}

local storedSettings              = ac.storage({ enduranceEnabled = true })

local enduranceEnabled           = true

local mMin = math.min
local sFormat = string.format
local getCar = ac.getCar
local setAITopSpeed = physics.setAITopSpeed
local setAICaution = physics.setAICaution
local setAIThrottleLimit = physics.setAIThrottleLimit

local DEBUG_ENABLED = false
local debugLogFile = nil
local function Log(msg)
  if not DEBUG_ENABLED then return end
  pcall(function()
    if not debugLogFile then
      local path = "debug.log"
      if type(ac.dirname) == "function" then
        path = ac.dirname() .. "/debug.log"
      elseif type(io.relative) == "function" then
        path = io.relative("debug.log")
      end
      debugLogFile = io.open(path, "a")
    end
    if debugLogFile then
      debugLogFile:write(msg .. "\n")
      debugLogFile:flush()
    end
  end)
end

local function SaveCarClass(carID, cls)
  if not carID then return end
  pcall(function()
    ac.storage["carclass_" .. carID] = cls or ""
  end)
end

local function LoadCarClass(carID)
  if not carID then return nil end
  local ok, v = pcall(function()
    return ac.storage["carclass_" .. carID]
  end)
  if ok and v and v ~= "" then
    return v
  end
  return nil
end

local function NormalizeClassName(name)
  local n = (name or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("[=\n]", " ")
  if n:sub(1, 1) == "#" then
    n = n:sub(2):gsub("^%s+", ""):gsub("%s+$", "")
  end
  return n
end

local function GetCarUISource(carIndex)
  local cached = uiSourceCache[carIndex]
  if cached then return cached end
  local out = { tags = {}, class = nil, badge = nil }
  local okId, carID = pcall(function()
    return ac.getCarID and ac.getCarID(carIndex)
  end)
  local folder = nil
  local okFolder = pcall(function()
    folder = ac.getFolder and ac.getFolder(ac.FolderID and ac.FolderID.ContentCars)
  end)
  if okId and carID and okFolder and folder and folder ~= "" then
    local uiDir = folder .. "/" .. carID .. "/ui"
    local path = uiDir .. "/ui_car.json"
    local data = nil
    local okLoad = pcall(function()
      data = io.load and io.load(path)
    end)
    if okLoad and data and type(data) == "string" and #data > 0 then
      local cls = data:match('"class"%s*:%s*"([^"]*)"')
      if cls then
        out.class = cls
      end
      local tagsSection = data:match('"tags"%s*:%s*%[(.-)%]')
      if tagsSection then
        for q in tagsSection:gmatch('"([^"]*)"') do
          out.tags[#out.tags + 1] = q
        end
      end
    end
    local okBadge = pcall(function()
      local files = io.scanDir and io.scanDir(uiDir, "badge*")
      if files and #files > 0 then
        out.badge = uiDir .. "/" .. files[1]
      end
    end)
  end
  uiSourceCache[carIndex] = out
  return out
end

local function GetCarTags(carIndex)
  local ok, tags = pcall(function()
    return ac.getCarTags and ac.getCarTags(carIndex)
  end)
  if not ok then tags = nil end
  local out = {}
  local function collect(t)
    if type(t) ~= "table" then return end
    for _, val in ipairs(t) do
      if type(val) == "string" then
        local tt = val:gsub("^%s+", ""):gsub("%s+$", "")
        if tt:sub(1, 1) == "#" then
          tt = tt:sub(2)
        end
        if tt ~= "" then
          out[#out + 1] = tt
        end
      end
    end
  end
  if tags then
    collect(tags)
  end
  collect(GetCarUISource(carIndex).tags)
  return out
end

local GetCarClassCached

GetCarClassCached = function(carIndex)
  local cached = carClassCache[carIndex]
  if cached ~= nil then
    return (cached ~= "") and cached or nil
  end
  local cls = nil
  local ui = GetCarUISource(carIndex)
  if ui.class then
    local v = ui.class:gsub("^%s+", ""):gsub("%s+$", "")
    if v ~= "" then
      cls = v
    end
  end
  if not cls then
    local ok, config = pcall(function()
      return ac.INIConfig and ac.INIConfig.carData(carIndex, 'car.ini')
    end)
    if ok and config then
      local ok2, val = pcall(function()
        return config:get('BASIC', 'CLASS', '')
      end)
      if ok2 and type(val) == "string" then
        local v = val:gsub("^%s+", ""):gsub("%s+$", "")
        if v ~= "" then
          cls = v
        end
      end
    end
  end
  carClassCache[carIndex] = cls or ""
  return cls
end

local function TagMatchesWord(lowerTag, lowerClass)
  if lowerClass == "" then return false end
  if lowerTag == lowerClass then return true end
  local esc = lowerClass:gsub("([^%w])", "%%%1")
  if lowerTag:find("^" .. esc .. "%f[%A]") then return true end
  if lowerTag:find("%f[%w]" .. esc .. "%f[%A]") then return true end
  if lowerTag:find("%f[%w]" .. esc .. "$") then return true end
  return false
end

local function EditDistance(a, b)
  local m, n = #a, #b
  if m == 0 then return n end
  if n == 0 then return m end
  local d = {}
  for i = 0, m do
    d[i * (n + 1)] = i
  end
  for j = 0, n do
    d[j] = j
  end
  for i = 1, m do
    for j = 1, n do
      local cost = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
      local row = i * (n + 1)
      d[row + j] = mMin(d[row - (n + 1) + j] + 1, d[row + j - 1] + 1, d[row - (n + 1) + j - 1] + cost)
    end
  end
  return d[m * (n + 1) + n]
end

local function CarMatchesClass(carIndex, lowerClass)
  for _, tt in ipairs(GetCarTags(carIndex)) do
    if TagMatchesWord(string.lower(tt), lowerClass) then
      return true
    end
  end
  local cc = GetCarClassCached(carIndex)
  if cc and TagMatchesWord(string.lower(cc), lowerClass) then
    return true
  end
  local carName = ac.getCarName and ac.getCarName(carIndex)
  if carName and string.lower(carName:gsub("^%s+", ""):gsub("%s+$", "")) == lowerClass then
    return true
  end
  local carID = ac.getCarID and ac.getCarID(carIndex)
  if carID and string.lower(carID:gsub("^%s+", ""):gsub("%s+$", "")) == lowerClass then
    return true
  end
  return false
end

local function GetAvailableClassNames()
  local out = {}
  local seen = {}
  for i = 0, driverCount - 1 do
    for _, tt in ipairs(GetCarTags(i)) do
      local k = string.lower(tt)
      if not seen[k] then
        seen[k] = true
        out[#out + 1] = tt
      end
    end
    local cc = GetCarClassCached(i)
    if cc then
      local k = string.lower(cc)
      if not seen[k] then
        seen[k] = true
        out[#out + 1] = cc
      end
    end
  end
  return out
end

local VerifyClassAssignments
local BuildClassInfo
local RemoveReleaseClass

local function SaveClassNames()
  pcall(function()
    ac.storage["releaseClassNames"] = table.concat(releaseClasses, "|")
  end)
end

local function LoadClassNames()
  local ok, v = pcall(function()
    return ac.storage["releaseClassNames"]
  end)
  if ok and type(v) == "string" and v ~= "" then
    return v
  end
  return nil
end

local function AddReleaseClass(name)
  local n = NormalizeClassName(name)
  Log(sFormat("AddReleaseClass: name='%s' normalized='%s' driverCount=%d", tostring(name), n, driverCount))
  if n == "" then
    classAddError = "Enter a class name first."
    return
  end

  local lower = string.lower(n)
  for i = 1, #releaseClasses do
    if string.lower(releaseClasses[i]) == lower then
      classAddError = "Class '" .. n .. "' is already added."
      return
    end
  end

  local matched = 0
  for i = 0, driverCount - 1 do
    local m
    local ok = pcall(function()
      m = CarMatchesClass(i, lower)
    end)
    if not ok then m = false end
    if m then
      manualDriverClass[i] = n
      SaveCarClass(ac.getCarID and ac.getCarID(i), n)
      matched = matched + 1
    end
  end

  if matched == 0 then
    local avail = GetAvailableClassNames()
    local availText = (#avail > 0) and table.concat(avail, ", ") or "(none)"
    local suggestion = nil
    local bestDist = 3
    for _, an in ipairs(avail) do
      local dist = EditDistance(string.lower(an), lower)
      if dist < bestDist then
        bestDist = dist
        suggestion = an
      end
    end
    Log(sFormat("AddReleaseClass FAIL: matched=0 driverCount=%d avail=%d tags_sample={}", driverCount, #avail))
    classAddError = "No cars match '" .. n .. "'. Available tags/classes: " .. availText .. " (case is ignored). [debug: driverCount=" .. driverCount .. "]"
    if suggestion then
      classAddError = classAddError .. " Did you mean '" .. suggestion .. "'?"
    end
    return
  end

  releaseClasses[#releaseClasses + 1] = n
  classAddError = nil
  classAddInput = ""
  SaveClassNames()
  BuildClassInfo()
  VerifyClassAssignments()
end

VerifyClassAssignments = function()
  local cars = {}
  local tlist = {}
  for i = 0, driverCount - 1 do
    local cls = manualDriverClass[i]
    if not cls or cls == "" then
      local carName = ac.getCarName and ac.getCarName(i)
      local carID = ac.getCarID and ac.getCarID(i)
      cars[#cars + 1] = carName or carID or sFormat("Car %d", i + 1)
      local tags = GetCarTags(i)
      tlist[#tlist + 1] = (#tags > 0) and table.concat(tags, ", ") or "(no tag)"
    end
  end

  if #cars == 0 then
    ui.toast(ui.Icons.Play, sFormat("All %d car(s) on the grid belong to an added class.", driverCount))
  else
    local details = {}
    for j = 1, #cars do
      details[#details + 1] = cars[j] .. " (" .. tlist[j] .. ")"
    end
    ui.toast(ui.Icons.Warning, sFormat("%d car(s) are not assigned to any class: %s", #cars, table.concat(details, ", ")))
  end
end

RemoveReleaseClass = function(idx)
  local n = releaseClasses[idx]
  if not n then return end
  table.remove(releaseClasses, idx)
  for i = 0, driverCount - 1 do
    if manualDriverClass[i] == n then
      manualDriverClass[i] = ""
      SaveCarClass(ac.getCarID and ac.getCarID(i), "")
    end
  end
  classAddError = nil
  SaveClassNames()
  BuildClassInfo()
end

BuildClassInfo = function()
  Log(sFormat("BuildClassInfo: dc=%d entries=%d", driverCount, #manualDriverClass))
  driverClass = {}
  classOrder = {}

  if driverCount == 0 then return end

  local classMinPos = {}

  for i = 0, driverCount - 1 do
    local raw = manualDriverClass[i]
    local key
    if raw and raw ~= "" then
      key = "class" .. string.lower(raw)
    end

    driverClass[i] = key

    if key then
      local pos = allDriversStartingPos[i] or (i + 1)
      if not classMinPos[key] or pos < classMinPos[key] then
        classMinPos[key] = pos
      end
    end
  end

  for key, _ in pairs(classMinPos) do
    classOrder[#classOrder + 1] = key
  end

  local classBestLapMs = {}
  for _, key in ipairs(classOrder) do
    local best = nil
    for i = 0, driverCount - 1 do
      if driverClass[i] == key then
        local ok, car = pcall(getCar, i)
        if ok and car then
          local okBt, btMs = pcall(function() return car.bestLapTimeMs end)
          if okBt and btMs and type(btMs) == "number" and btMs > 0 then
            if best == nil or btMs < best then
              best = btMs
            end
          end
        end
      end
    end
    classBestLapMs[key] = best
  end

  table.sort(classOrder, function(a, b)
    if classBestLapMs[a] and classBestLapMs[b] then
      return classBestLapMs[a] < classBestLapMs[b]
    end
    if classBestLapMs[a] then return true end
    if classBestLapMs[b] then return false end
    return classMinPos[a] < classMinPos[b]
  end)

  Log(sFormat("BuildClassInfo DONE: %d classes order={%s}", #classOrder, table.concat(classOrder, ",")))

end

local function LoadManualClassesFromStorage()
  Log(sFormat("LoadManualClassesFromStorage: START driverCount=%d", driverCount))
  releaseClasses = {}
  local seen = {}
  local anyLoaded = false
  for i = 0, driverCount - 1 do
    local okID, carID = pcall(function() return ac.getCarID and ac.getCarID(i) end)
    if okID and carID then
      local cls = LoadCarClass(carID)
      if type(cls) == "string" and cls ~= "" then
        manualDriverClass[i] = cls
        anyLoaded = true
        if not seen[cls] then
          seen[cls] = true
          releaseClasses[#releaseClasses + 1] = cls
        end
      else
        manualDriverClass[i] = ""
      end
    else
      Log(sFormat("LoadManualClassesFromStorage: car %d ac.getCarID failed okID=%s carID=%s", i, tostring(okID), tostring(carID)))
    end
  end
  Log(sFormat("LoadManualClassesFromStorage: DONE anyLoaded=%s releaseClasses=%d classes={%s}", tostring(anyLoaded), #releaseClasses, table.concat(releaseClasses, ",")))
  if not anyLoaded then
    local savedNames = LoadClassNames()
    if savedNames and savedNames ~= "" then
      Log(sFormat("LoadManualClassesFromStorage: per-car storage empty, re-detecting from saved class names: %s", savedNames))
      for name in savedNames:gmatch("[^|]+") do
        local lower = string.lower(name)
        local matched = 0
        for i = 0, driverCount - 1 do
          local m
          local ok = pcall(function() m = CarMatchesClass(i, lower) end)
          if not ok then m = false end
          if m then
            manualDriverClass[i] = name
            SaveCarClass(ac.getCarID and ac.getCarID(i), name)
            matched = matched + 1
          end
        end
        if matched > 0 then
          releaseClasses[#releaseClasses + 1] = name
        end
        Log(sFormat("LoadManualClassesFromStorage: re-detected class '%s' matched %d cars", name, matched))
      end
    end
  end
  if storedSettings.enduranceEnabled ~= nil then
    enduranceEnabled = storedSettings.enduranceEnabled
  end
  BuildClassInfo()
end

local function GetSessionNameLower()
  local sim = ac.getSim()
  local ok, name = pcall(function() return ac.getSessionName(sim.currentSessionIndex) end)
  if not ok or not name then return "" end
  return string.lower(name)
end

local function IsRaceMode()
  return GetSessionNameLower():find("race") ~= nil
end

local function IsEnduranceMode()
  return enduranceEnabled and IsRaceMode()
end

local function CheckSessionValidity()
  local sim = ac.getSim()

  if ac.getPatchVersionCode() < 3334 then
    return false, "Please update your Custom Shaders Patch (CSP) to version 0.2.7 or higher!"
  end

  local sn = GetSessionNameLower()
  if not (sn:find("race") or sn:find("practice") or sn:find("qualifying") or sn:find("hotlap")) then
    return false, "This app works in Race, Practice, or Qualifying sessions!"
  end

  if sim.isOnlineRace then
    return false, "This app only works for Offline/Single-player sessions!"
  end

  return true, nil
end

local function RecordStartingPositions()
  allDriversStartingPos = {}
  for i = 0, driverCount - 1 do
    local car = getCar(i)
    if car then
      allDriversStartingPos[i] = car.racePosition
    end
  end
  BuildClassInfo()
end

local function ReorderGridByClass()
  if #classOrder == 0 or driverCount == 0 then return end

  local function getBestLap(idx)
    local ok, car = pcall(getCar, idx)
    if ok and car then
      local okBt, bt = pcall(function() return car.bestLapTimeMs end)
      if okBt and bt and type(bt) == "number" and bt > 0 then return bt end
    end
    return 999999999
  end

  local classSlots = {}
  for ci, key in ipairs(classOrder) do
    classSlots[key] = {}
  end
  local noClass = {}

  for i = 0, driverCount - 1 do
    local cls = driverClass[i]
    if cls and classSlots[cls] then
      classSlots[cls][#classSlots[cls] + 1] = i
    else
      noClass[#noClass + 1] = i
    end
  end

  for _, key in ipairs(classOrder) do
    table.sort(classSlots[key], function(a, b)
      return getBestLap(a) < getBestLap(b)
    end)
  end
  table.sort(noClass, function(a, b)
    return getBestLap(a) < getBestLap(b)
  end)

  local ordered = {}
  for _, key in ipairs(classOrder) do
    for _, idx in ipairs(classSlots[key]) do
      ordered[#ordered + 1] = idx
    end
  end
  for _, idx in ipairs(noClass) do
    ordered[#ordered + 1] = idx
  end

  local pos = 1
  for _, idx in ipairs(ordered) do
    allDriversStartingPos[idx] = pos
    pos = pos + 1
  end

  Log(sFormat("ReorderGridByClass: reordered=%d drivers, classes={%s}", driverCount, table.concat(classOrder, ",")))
end

local function ReleaseAllCars()
  for i = 0, driverCount - 1 do
    setAITopSpeed(i, 999999.0)
    setAIThrottleLimit(i, 1.0)
    setAICaution(i, 1.0)
    physics.setAIStopCounter(i, 0.0)
  end
end

local function ManageAIClassRelease(dt)
  if not raceHasStarted then
    for i = 0, driverCount - 1 do
      local c = getCar(i)
      if c and c.speedKmh > 2.0 then
        raceHasStarted = true
        break
      end
    end
  end
  if not raceHasStarted then return end

  for i = 0, driverCount - 1 do
    local car = getCar(i)
    if car and i ~= 0 then
      setAITopSpeed(i, 999999.0)
      setAIThrottleLimit(i, 1.0)
      setAICaution(i, 1.0)
      physics.setAIStopCounter(i, 0.0)
    end
  end
end

local function LeaderboardProgress(carIndex)
  local car = getCar(carIndex)
  if not car then return 0 end
  return (car.sessionLapCount or 0) + (car.splinePosition or 0)
end

local function GetPlayerPositions()
  local sim = ac.getSim()
  local trackLength = sim.trackLengthM
  local playerCar = getCar(0)

  local totalLaps = 0
  local session = ac.getSession(sim.currentSessionIndex)
  if session then
    totalLaps = session.laps or 0
  end
  local lapRaw = 1
  if playerCar then
    lapRaw = playerCar.lapCount + 1
  end
  local currentLap = totalLaps > 0 and math.min(totalLaps, lapRaw) or lapRaw

  local overallPos = 1
  local classPos = 1
  local classTotal = 0
  local totalCars = 0
  local gapFront = nil
  local gapBehind = nil

  local playerClass = driverClass[0]

  local allCars = {}
  local classCars = {}

  for i = 0, driverCount - 1 do
    local car = getCar(i)
    if car then
      local prog = LeaderboardProgress(i)
      totalCars = totalCars + 1
      allCars[#allCars + 1] = { idx = i, prog = prog }

      if driverClass[i] == playerClass then
        classTotal = classTotal + 1
        classCars[#classCars + 1] = { idx = i, prog = prog }
      end
    end
  end

  table.sort(allCars, function(a, b) return a.prog > b.prog end)
  table.sort(classCars, function(a, b) return a.prog > b.prog end)

  for i, car in ipairs(allCars) do
    if car.idx == 0 then
      overallPos = i
      break
    end
  end

  for i, car in ipairs(classCars) do
    if car.idx == 0 then
      classPos = i
      if i > 1 then
        gapFront = ac.getGapBetweenCars(0, classCars[i - 1].idx)
      end
      if i < #classCars then
        gapBehind = ac.getGapBetweenCars(0, classCars[i + 1].idx)
      end
      break
    end
  end

  if not sim.isSessionStarted then
    gapFront = nil
    gapBehind = nil
  end

  return overallPos, totalCars, classPos, classTotal, gapFront, gapBehind, currentLap, totalLaps
end

local hasDWrite = (type(ui.pushDWriteFont) == "function" and type(ui.dwriteText) == "function")

local function MeasureBoldText(text, fontSize)
  if hasDWrite then
    ui.pushDWriteFont("Segoe UI;Weight=Bold")
    local s = ui.measureDWriteText(text, fontSize)
    ui.popDWriteFont()
    return s
  end
  return ui.measureText(text)
end

local function DrawBoldText(text, centerX, centerY, fontSize, color)
  if not hasDWrite then
    local size = ui.measureText(text)
    ui.setCursor(vec2(centerX - size.x / 2, centerY - size.y / 2))
    if color then
      ui.textColored(text, color)
    else
      ui.text(text)
    end
    return size.y
  end
  ui.pushDWriteFont("Segoe UI;Weight=Bold")
  local size = ui.measureDWriteText(text, fontSize)
  ui.setCursor(vec2(centerX - size.x / 2, centerY - size.y / 2))
  if color then
    ui.dwriteText(text, fontSize, color)
  else
    ui.dwriteText(text, fontSize)
  end
  ui.popDWriteFont()
  return size.y
end

function script.clLeaderboard(dt)
  local sim = ac.getSim()
  local w = ui.windowWidth()
  local h = ui.windowHeight()

  local overallPos, totalCars, classPos, classTotal, gapFront, gapBehind, currentLap, totalLaps = GetPlayerPositions()

  local padX = 12
  local gap = 16
  local panelW = (w - 2 * padX - 2 * gap) / 3
  local panelTop = 8

  local gapPanelH = 46
  local hasGap = classTotal > 1 and sim.isSessionStarted
  local gapPanelTop = h - 8 - gapPanelH

  local columnBottom = h - 8
  if hasGap then
    columnBottom = gapPanelTop - 10
  end
  local panelH = columnBottom - panelTop

  local function DrawPanel(x, title, bigText, totalText, color)
    local cx = x + panelW / 2

    ui.drawRectFilled(vec2(x, panelTop), vec2(x + panelW, columnBottom), rgbm(0.08, 0.10, 0.15, 0.6), 8)
    ui.drawRect(vec2(x, panelTop), vec2(x + panelW, columnBottom), rgbm(0.3, 0.3, 0.36, 0.7), 8, nil, 1.5)

    DrawBoldText(title, cx, panelTop + 8 + MeasureBoldText(title, 13).y / 2, 13, rgbm(0.7, 0.7, 0.8, 1))

    local bigCy = panelTop + panelH * 0.42
    local bigSize = math.max(12, math.floor(panelH * 0.5))
    local bigW = MeasureBoldText(bigText, bigSize).x
    if bigW > panelW * 0.9 then
      bigSize = math.max(12, math.floor(bigSize * (panelW * 0.9) / bigW))
    end
    local bigH = MeasureBoldText(bigText, bigSize).y
    local bigMaxHalf = panelH * 0.22
    if bigH / 2 > bigMaxHalf then
      bigSize = math.max(12, math.floor(bigSize * bigMaxHalf / (bigH / 2)))
    end
    local drawnBigH = DrawBoldText(bigText, cx, bigCy, bigSize, color)

    local sepW = panelW * 0.5
    local sepY = bigCy + drawnBigH / 2 + 10
    ui.drawRectFilled(vec2(cx - sepW / 2, sepY), vec2(cx + sepW / 2, sepY + 2), rgbm(0.5, 0.5, 0.6, 0.9))

    if totalText then
      local totalSize = MeasureBoldText(totalText, 16)
      local totalCy = math.min(sepY + 8 + totalSize.y / 2, columnBottom - totalSize.y / 2 - 8)
      DrawBoldText(totalText, cx, totalCy, 16, rgbm(0.7, 0.7, 0.8, 1))
    end
  end

  local lapTotalText = (totalLaps or 0) > 0 and sFormat("%d", totalLaps) or nil
  DrawPanel(padX, "LAP", sFormat("%d", math.max(1, currentLap)), lapTotalText, rgbm(0.95, 0.95, 1, 1))
  DrawPanel(padX + panelW + gap, "OVERALL", sFormat("%d", overallPos), sFormat("%d", totalCars), rgbm(0.95, 0.95, 1, 1))
  DrawPanel(padX + 2 * (panelW + gap), "CLASS", sFormat("%d", classPos), sFormat("%d", classTotal), rgbm(0.35, 0.95, 0.45, 1))

  if hasGap then
    local gapStr = ""
    if gapFront and gapBehind then
      gapStr = sFormat("+%.1fs / -%.1fs", math.abs(gapFront), math.abs(gapBehind))
    elseif gapFront then
      gapStr = sFormat("+%.1fs", math.abs(gapFront))
    elseif gapBehind then
      gapStr = sFormat("-%.1fs", math.abs(gapBehind))
    end

    if gapStr ~= "" then
      local gapPanelRight = w - padX
      ui.drawRectFilled(vec2(padX, gapPanelTop), vec2(gapPanelRight, h - 8), rgbm(0.08, 0.10, 0.15, 0.6), 8)
      ui.drawRect(vec2(padX, gapPanelTop), vec2(gapPanelRight, h - 8), rgbm(0.3, 0.3, 0.36, 0.7), 8, nil, 1.5)

      local gFs = 20
      local gSize = MeasureBoldText(gapStr, gFs)
      if gSize.x > (w - 2 * padX - 24) then
        gFs = math.max(12, math.floor(gFs * (w - 2 * padX - 24) / gSize.x))
      end
      DrawBoldText(gapStr, w / 2, gapPanelTop + gapPanelH / 2, gFs, rgbm(0.7, 0.8, 0.9, 1))
    end
  end
end

function script.update(dt)
  local sim = ac.getSim()
  driverCount = sim.carsCount or 0

  local sessionChanged = false
  if lastSessionIndex ~= nil and lastSessionIndex ~= sim.currentSessionIndex then
    sessionChanged = true
  end
  if lastSessionStarted ~= nil and lastSessionStarted == true and sim.isSessionStarted == false then
    sessionChanged = true
  end
  if lastSessionStarted ~= nil and lastSessionStarted == false and sim.isSessionStarted == true and lastSessionIndex ~= nil then
    sessionChanged = true
  end
  if sessionChanged then
    firstFrame = true
    carClassCache = {}
    uiSourceCache = {}
  end
  lastSessionIndex = sim.currentSessionIndex
  lastSessionStarted = sim.isSessionStarted

  if firstFrame then
    Log(sFormat("FIRSTFRAME: idx=%s race=%s dc=%d rc=%d", tostring(sim.currentSessionIndex), tostring(IsRaceMode()), driverCount, #releaseClasses))
    leaderboardOpened = false
    raceHasStarted   = false
    allDriversStartingPos = {}
    if driverCount > 0 then
      LoadManualClassesFromStorage()
      if IsEnduranceMode() then
        RecordStartingPositions()
        ReorderGridByClass()
        ReleaseAllCars()
      end
    end
    firstFrame = false
    Log(sFormat("FIRSTFRAME DONE: rc=%d classes={%s}", #releaseClasses, table.concat(releaseClasses, ",")))
  end

  if #releaseClasses == 0 and driverCount > 0 then
    LoadManualClassesFromStorage()
    if #releaseClasses > 0 then
      BuildClassInfo()
      if IsEnduranceMode() then
        RecordStartingPositions()
        ReorderGridByClass()
      end
    end
  end

  if sim.isInMainMenu == true then
    ac.setWindowOpen("cl_config", true)
  end

  local valid, _ = CheckSessionValidity()
  if not valid then return end

  if not leaderboardOpened and sim.isInMainMenu ~= true then
    ac.setWindowOpen("cl_leaderboard", true)
    leaderboardOpened = true
  end

  if IsEnduranceMode() and not sim.isSessionStarted then
    for i = 0, driverCount - 1 do
      local car = getCar(i)
      if car then
        allDriversStartingPos[i] = car.racePosition
      end
    end
    ReorderGridByClass()
  end

  if IsEnduranceMode() then
    ManageAIClassRelease(dt)
  end
end

function script.clConfig()
  local valid, err = CheckSessionValidity()
  local sim = ac.getSim()
  local w = ui.windowWidth()
  local h = ui.windowHeight()

  local colX = 24

  ui.pushStyleVar(ui.StyleVar.FramePadding, vec2(6, 6))

  ui.drawRectFilled(vec2(0, 0), vec2(w, h), rgbm(0.04, 0.05, 0.07, 0.85), 0)
  ui.drawRect(vec2(0, 0), vec2(w, h), rgbm(0.18, 0.18, 0.20, 0.6), 0, nil, 1)

  if valid then
    ui.pushFont(ui.Font.Title)
    local titleText = "Multiple Class Race Configuration"
    local titleSize = ui.measureText(titleText)
    local titleX = (w - titleSize.x) / 2
    ui.setCursor(vec2(titleX, 12))
    ui.text(titleText)
    ui.popFont()

    local separatorY = ui.getCursor().y + 10
    ui.drawLine(vec2(colX, separatorY), vec2(w - 24, separatorY), rgbm(0.25, 0.25, 0.28, 0.5), 1)
    ui.setCursor(vec2(colX, separatorY + 12))

    if ui.checkbox("Enable Multiple Class Race", enduranceEnabled) then
      enduranceEnabled = not enduranceEnabled
      storedSettings.enduranceEnabled = enduranceEnabled
    end

    if enduranceEnabled then

      if driverCount > 0 then
        ui.setCursor(vec2(colX, ui.getCursor().y))
        ui.text("Add Class (auto-assign by car tag):")
        ui.setCursor(vec2(colX, ui.getCursor().y + 4))
        ui.pushItemWidth(w - 48)
        classAddInput = ui.inputText("##NewReleaseClass", classAddInput or "")
        ui.popItemWidth()
        ui.setCursor(vec2(colX, ui.getCursor().y + 6))
        if ui.button("Add Class", vec2(w - 48, 28)) then
          local addOk, addErr = pcall(function()
            AddReleaseClass(classAddInput)
          end)
          if not addOk then
            classAddError = "Error adding class: " .. tostring(addErr)
          end
        end
        ui.setCursor(vec2(colX, ui.getCursor().y + 6))
        if ui.button("Verify", vec2(w - 48, 28)) then
          pcall(VerifyClassAssignments)
        end
        if ui.itemHovered() then
          ui.setTooltip("Use 'Add Class' first to assign cars by tag, then 'Verify' to check every car belongs to an added class.")
        end

        if classAddError then
          ui.setCursor(vec2(colX, ui.getCursor().y + 8))
          ui.pushFont(ui.Font.Small)
          ui.textColored(classAddError, rgbm.colors.red)
          ui.popFont()
        end

        if #releaseClasses > 0 then
          ui.setCursor(vec2(colX, ui.getCursor().y + 12))
          ui.text("Classes:")
          for ci = 1, #releaseClasses do
            local clsName = releaseClasses[ci]
            local carList = {}
            local count = 0
            for i = 0, driverCount - 1 do
              if manualDriverClass[i] == clsName then
                count = count + 1
                local cn = ac.getCarName and ac.getCarName(i) or sFormat("Car %d", i + 1)
                carList[#carList + 1] = cn
              end
            end
            ui.setCursor(vec2(colX + 8, ui.getCursor().y + 2))
            ui.text(sFormat("%s (%d car%s)", clsName, count, count == 1 and "" or "s"))
            if count > 0 then
              if ui.itemHovered() then
                ui.setTooltip("Cars: " .. table.concat(carList, ", "))
              end
            end
            ui.sameLine()
            ui.pushStyleVar(ui.StyleVar.FramePadding, vec2(6, 2))
            ui.pushStyleVar(ui.StyleVar.ButtonTextAlign, vec2(0.5, 0.5))
            if ui.button("Remove##removeclass" .. ci, vec2(64, 20)) then
              RemoveReleaseClass(ci)
            end
            ui.popStyleVar(2)
          end
        end

      else
        ui.setCursor(vec2(colX, ui.getCursor().y))
        ui.pushFont(ui.Font.Small)
        ui.textColored("Waiting for car data to load...", rgbm(0.6, 0.7, 0.9, 1))
        ui.popFont()
      end

    ui.dummy(vec2(0, 8))
    end

  else
    ui.pushFont(ui.Font.Title)
    local errTitle = "Multiple Class Race Disabled"
    local errTitleSize = ui.measureText(errTitle)
    local errTitleX = (w - errTitleSize.x) / 2
    ui.setCursor(vec2(errTitleX, 12))
    ui.text(errTitle)
    ui.popFont()

    local separatorY = ui.getCursor().y + 10
    ui.drawLine(vec2(24, separatorY), vec2(w - 24, separatorY), rgbm(0.25, 0.25, 0.28, 0.5), 1)
    ui.setCursor(vec2(24, separatorY + 16))

    ui.pushItemWidth(w - 48)
    ui.textWrapped(err or "Class-based mode cannot be enabled under current conditions!")
    ui.popItemWidth()
    ui.dummy(vec2(0, 8))
  end

  ui.popStyleVar()
end

ac.onSessionStart(function()
  firstFrame          = true
  raceHasStarted      = false
  carClassCache       = {}
  allDriversStartingPos = {}
  uiSourceCache       = {}
  Log("onSessionStart: firstFrame=true")
end)

Log("=== APP LOADED ===")
