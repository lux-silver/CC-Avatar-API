-- Market Display v12.6 (Blue Cyber Terminal Edition)
-- Fixed Notification Loop + Integrated 8x Micro-Avatar Inspector Engine

local PROTOCOL    = "cloud_ui"
local REFRESH_INT = 15    
local SCROLL_SPD  = 0.08  
local TICKER_SPD  = 0.05  
local RESUME_TIME = 8.0   
local SYSTEM_FILE = "market_v4_cache.dat"

-- ── TEMPO DE INATIVIDADE DO PAINEL DE INSPEÇÃO (Em Segundos) ──
local OVERLAY_TIMEOUT = 10.0

-- ── CUSTOM ALERTS INDIVIDUAL TIMERS (In Seconds) ──
local TIME_ALERT_INFO = 20   
local TIME_ALERT_NEW  = 25.0  
local TIME_ALERT_WARN = 25.0  

-- ── CONFIGURAÇÃO DE LAYOUT ORIGINAL ──────────────────────────────────────────
local NUM_COLUMNS = 2     
local MON_SCALE   = 0.5   
-- ──────────────────────────────────────────────────────────────────────────────

local modemSide = nil
for _, s in ipairs({"top","bottom","left","right","front","back"}) do
    if peripheral.getType(s) == "modem" then modemSide = s break end
end
if not modemSide then error("No modem found") end
rednet.open(modemSide)

local mon = nil
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then mon = peripheral.wrap(name) break end
end
if not mon then error("No monitor found") end

mon.setTextScale(MON_SCALE)  
local W, H = mon.getSize()
local termW, termH = term.getSize()

-- Paleta de cores atualizada (Janelas em tons de azul e ciano)
local C = {
    bg        = colors.black,
    header    = colors.blue,       
    headerTx  = colors.white,
    newBadge  = colors.lime,
    itemTx    = colors.cyan,        
    sellerTx  = colors.lightGray,
    tickerBg  = colors.gray,       
    tickerTx  = colors.white,
    scrollBg  = colors.black,      
    scrollBar = colors.blue,       
}

local serverId     = nil
local listings     = {}
local newItems     = {}   
local priceHistory = {}   
local stockTracker = {}   
local priceTracker = {}   
local boostTracker = {}   
local itemStatus   = {}   
local notificationQueue = {} 

local knownItemsCache = {}
local rainbowColors = { colors.red, colors.orange, colors.yellow, colors.lime, colors.green, colors.cyan, colors.lightBlue, colors.magenta }

local HEADER_H   = 2
local TICKER_H   = 2 
local CARDS_TOP  = HEADER_H + 1
local CARDS_BOT  = H - TICKER_H
local CARDS_H    = CARDS_BOT - CARDS_TOP + 1
local CARD_H     = 4 
local SCROLL_W   = 1 

local scrollOff    = 0    
local tickerText   = ""
local tickerPos    = W    
local shimmerPh    = 0    
local statusText   = "STANDBY"

local currentSeq   = 0
local netTimer     = nil
local userTouchTimer = nil
local overlayTimer   = nil  
local priceGroups  = {}

local overlayAtivo = false
local itemSelecionadoOverlay = nil

-- ── BLINDAGEM DE FUNÇÕES GRÁFICAS ─────────────────────────────────────────────
local function mWrite(x, y, text, fg, bg)
    if y >= 1 and y <= H then
        mon.setCursorPos(x, y)
        if bg then mon.setBackgroundColor(bg) end
        if fg then mon.setTextColor(fg) end
        local avail = W - x + 1
        if avail > 0 then mon.write(tostring(text):sub(1, avail)) end
    end
    if y >= 1 and y <= termH and x <= termW then
        term.setCursorPos(x, y)
        if bg then term.setBackgroundColor(bg) end
        if fg then term.setTextColor(fg) end
        local termAvail = termW - x + 1
        if termAvail > 0 then term.write(tostring(text):sub(1, termAvail)) end
    end
end

local function mLine(x1, y, x2, bg)
    if y >= 1 and y <= H then
        mon.setCursorPos(x1, y)
        mon.setBackgroundColor(bg or C.bg)
        mon.write(string.rep(" ", x2 - x1 + 1))
    end
    if y >= 1 and y <= termH then
        local targetX2 = math.min(x2, termW)
        if x1 <= targetX2 then
            term.setCursorPos(x1, y)
            term.setBackgroundColor(bg or C.bg)
            term.write(string.rep(" ", targetX2 - x1 + 1))
        end
    end
end

-- Renderizador de matrizes locais (.lua) adaptado para posições relativas
local function drawMatrixFromFile(filePath, startX, startY)
    if not fs.exists(filePath) then return false end
    local chunk = loadfile(filePath)
    if not chunk then return false end
    local matrix = chunk()
    for i, colorLine in ipairs(matrix) do
        mon.setCursorPos(startX, startY + i - 1)
        mon.blit(string.rep(" ", #colorLine), colorLine, colorLine)
    end
    return true
end

-- Desenha o fallback clássico de barras de TV ("NO SIGNAL") em formato 8x8
local function drawNoSignal(startX, startY)
    local bars = {
        "eeeeeeee", -- Branco (e)
        "11111111", -- Laranja / Amarelo (1)
        "99999999", -- Ciano (9)
        "dbbbbbbd", -- Verde / Rosa misto (d, b)
        "ffffffff", -- Rosa / Magenta (f)
        "eeeeeeee", -- Vermelho (e)
        "44444444", -- Azul (4)
        "ffffffff"  -- Preto alternativo (f)
    }
    for i = 1, 8 do
        mon.setCursorPos(startX, startY + i - 1)
        mon.blit("        ", bars[i], bars[i])
    end
end

local function getTruncatedItemName(l, colW)
    local rightReserved = 1
    local now = os.epoch("utc")
    local isNew = newItems[l.id] and (now - newItems[l.id] < 60000)
    local merchantKey = (l.seller or "unknown") .. "_" .. l.item_name
    local liveStatus = itemStatus[merchantKey]

    if liveStatus and (now - liveStatus.ts < 60000) then
        if liveStatus.status == "SOLD" then rightReserved = rightReserved + 8
        elseif liveStatus.status == "RESTOCK" then rightReserved = rightReserved + 11 end
    elseif isNew then
        rightReserved = rightReserved + 6
    end

    local maxNameLen = colW - rightReserved - 2
    local name = l.display_name or l.item_name
    if #name > maxNameLen then 
        name = name:sub(1, math.max(1, maxNameLen - 2)) .. ".." 
    end
    return name
end

local function getSellerColor(sellerName)
    if not sellerName or sellerName == "" then return colors.white end
    local sum = 0
    for i = 1, #sellerName do
        sum = sum + string.byte(sellerName, i)
    end
    local availableColors = { colors.orange, colors.magenta, colors.lightBlue, colors.yellow, colors.lime, colors.pink, colors.cyan, colors.purple, colors.blue, colors.green, colors.red }
    return availableColors[(sum % #availableColors) + 1]
end

local function getGlobalRainbowColor()
    local now = os.epoch("utc")
    local idx = (math.floor(now / 700) % #rainbowColors) + 1
    return rainbowColors[idx]
end

local function loadSystemData()
    if fs.exists(SYSTEM_FILE) then
        local f = fs.open(SYSTEM_FILE, "r")
        local content = f.readAll()
        f.close()
        local ok, data = pcall(textutils.unserialize, content)
        if ok and type(data) == "table" then
            priceHistory = data.priceHistory or priceHistory
            listings     = data.listings or listings
            newItems     = data.newItems or newItems
            serverId     = data.serverId or serverId
            stockTracker = data.stockTracker or stockTracker
            priceTracker = data.priceTracker or priceTracker
            boostTracker = data.boostTracker or boostTracker
            return
        end
    end
end

local function saveSystemData()
    local dataToSave = {
        priceHistory = priceHistory,
        listings = listings,
        newItems = newItems,
        serverId = serverId,
        stockTracker = stockTracker,
        priceTracker = priceTracker,
        boostTracker = boostTracker
    }
    local f = fs.open(SYSTEM_FILE, "w")
    f.write(textutils.serialize(dataToSave))
    f.close()
end

loadSystemData()

if listings then
    for _, entry in ipairs(listings) do
        if entry.item_name then knownItemsCache[entry.item_name] = true end
    end
end

local function rebuildPriceGroups()
    priceGroups = {}
    for _, l in ipairs(listings) do
        local key = l.item_name
        if not priceGroups[key] then
            priceGroups[key] = { min = math.huge, max = -math.huge, count = 0 }
        end
        local unitPrice = l.price / l.lot_size
        if unitPrice < priceGroups[key].min then priceGroups[key].min = unitPrice end
        if unitPrice > priceGroups[key].max then priceGroups[key].max = unitPrice end
        local pgCount = priceGroups[key].count or 0
        priceGroups[key].count = pgCount + 1
    end
end

local function logPriceChange(itemName, unitPrice)
    if type(priceHistory[itemName]) ~= "table" then
        priceHistory[itemName] = {}
    end
    local history = priceHistory[itemName]
    if #history == 0 or history[#history].price ~= unitPrice then
        table.insert(history, {
            price = unitPrice,
            time = os.date("%H:%M:%S")
        })
        if #history > 25 then table.remove(history, 1) end
    end
end

local function addNotification(text, color, txColor, catColor, isRainbow, customDuration)
    for i = #notificationQueue, 1, -1 do
        if notificationQueue[i].text == text then
            table.remove(notificationQueue, i)
        end
    end
    
    local isNewItemAlert = text:find("%[NEW ITEM LISTED%]") ~= nil or text:find("%[NEW MARKET INBOUND%]") ~= nil
    
    local entry = { 
        text = text:upper(), 
        color = color, 
        txColor = txColor or colors.white,
        catColor = catColor or color, 
        isRainbow = isRainbow or false, 
        ts = os.epoch("utc"),
        lifespan = customDuration or TIME_ALERT_INFO,
        isNewItem = isNewItemAlert
    }

    if isNewItemAlert then
        table.insert(notificationQueue, 1, entry)
    else
        table.insert(notificationQueue, entry)
    end

    if #notificationQueue > 15 then table.remove(notificationQueue) end
end

local function scanForNewItems(newListings)
    if not newListings or #newListings == 0 then return end
    
    local foundInbound = {}
    for _, item in ipairs(newListings) do
        if item.item_name and not knownItemsCache[item.item_name] then
            local cleanName = item.display_name or item.item_name:match(":(.+)$") or item.item_name
            local priceStr = tostring(item.price or 0)
            local sellerStr = (item.seller or "UNKNOWN"):upper()
            
            local data = {
                name = cleanName:upper(),
                price = priceStr,
                seller = sellerStr
            }
            table.insert(foundInbound, data)
            knownItemsCache[item.item_name] = true
        end
    end

    if #foundInbound > 0 then
        tickerPos = W
        if #foundInbound == 1 then
            local item = foundInbound[1]
            local alertString = "[NEW ITEM LISTED] ITEM: " .. item.name .. " | PRICE: " .. item.price .. " SP | MERCHANT: " .. item.seller
            addNotification(alertString, colors.lime, colors.white, colors.white, false, TIME_ALERT_NEW)
        else
            local alertString = "[NEW MARKET INBOUND] " .. #foundInbound .. " NEW ITEMS HAVE ARRIVED AT THE ECOSYSTEM!"
            addNotification(alertString, colors.lime, colors.white, colors.white, false, TIME_ALERT_NEW)
        end
    end
end

local function buildTicker()
    local now = os.epoch("utc")
    if #listings == 0 then
        tickerText = ""
        return
    end

    local boostedStrings = {}
    for _, l in ipairs(listings) do
        if l.boost_ts and l.boost_ts > now then
            local name = l.display_name or l.item_name:match(":(.+)$") or l.item_name
            local priceStr = tostring(l.price)
            local sellerStr = l.seller or "?"
            table.insert(boostedStrings, string.format("%s (%s SP) BY %s", name:upper(), priceStr, sellerStr:upper()))
        end
    end

    if #boostedStrings > 0 then
        tickerText = " ★ WELCOME NEW BOOSTED ITEM: ~[" .. table.concat(boostedStrings, " | ") .. "]~ ★ "
    else
        tickerText = ""
    end
end

if #listings > 0 then rebuildPriceGroups() buildTicker() end

local function handleNetworkMessage(sender, msg)
    if type(msg) ~= "table" or not msg.ok then return end
    if netTimer then os.cancelTimer(netTimer) end
    
    serverId = sender
    local now = os.epoch("utc")
    local newList = msg.listings or {}

    scanForNewItems(newList)

    for _, l in ipairs(newList) do
        if not newItems[l.id] then newItems[l.id] = now end
        local unitPrice = l.price / l.lot_size
        logPriceChange(l.item_name, unitPrice)

        local merchantKey = (l.seller or "unknown") .. "_" .. l.item_name
        local oldStock = stockTracker[merchantKey]
        local currentStock = l.stock or 0
        local name = l.display_name or l.item_name:match(":(.+)$") or l.item_name

        if l.boost_ts and l.boost_ts > now then
            if not boostTracker[merchantKey] or boostTracker[merchantKey] < l.boost_ts then
                local thankYouMsg = string.format("THANK YOU FOR THE BOOST! %s FOR %d SP BY %s IS NOW FEATURED", name, l.price, (l.seller or "?"))
                addNotification(thankYouMsg, colors.black, colors.white, colors.purple, true, TIME_ALERT_WARN)
                boostTracker[merchantKey] = l.boost_ts
            end
        end

        if oldStock then
            if currentStock < oldStock then
                local qtdVendida = oldStock - currentStock
                local txt = string.format("★ SUCCESSFUL SALE: %dx %s SOLD BY %s", qtdVendida, name, (l.seller or "?"))
                addNotification(txt, colors.orange, colors.black, colors.yellow, false, TIME_ALERT_INFO)
                itemStatus[merchantKey] = { status = "SOLD", ts = now }
            elseif currentStock > oldStock then
                local qtdRestock = currentStock - oldStock
                local txt = string.format("▲ INVENTORY RESTOCK: +%dx %s ADDED", qtdRestock, name)
                addNotification(txt, colors.cyan, colors.black, colors.blue, false, TIME_ALERT_INFO)
                itemStatus[merchantKey] = { status = "RESTOCK", ts = now }
            end
        end

        local oldPrice = priceTracker[merchantKey]
        if oldPrice and oldPrice > 0 and l.price ~= oldPrice then
            local delta = l.price - oldPrice
            if delta > 0 then
                local txt = string.format("📈 MARKET ALERT: %s RAISED %s BY +%d SP", (l.seller or "?"), name, delta)
                addNotification(txt, colors.red, colors.white, colors.orange, false, TIME_ALERT_WARN)
                itemStatus[merchantKey .. "_price"] = { type = "UP", diff = delta, ts = now }
            else
                local txt = string.format("📉 MARKET ALERT: %s DISCOUNTED %s BY -%d SP", (l.seller or "?"), name, math.abs(delta))
                addNotification(txt, colors.green, colors.white, colors.lime, false, TIME_ALERT_WARN)
                itemStatus[merchantKey .. "_price"] = { type = "DOWN", diff = math.abs(delta), ts = now }
            end
        end

        stockTracker[merchantKey] = currentStock
        priceTracker[merchantKey] = l.price
    end
    
    for oldKey, _ in pairs(stockTracker) do
        local safeKey = tostring(oldKey)
        if safeKey:find("_") then
            local aindaExiste = false
            for _, l in ipairs(newList) do
                local currentKey = (l.seller or "unknown") .. "_" .. l.item_name
                if currentKey == safeKey then aindaExiste = true break end
            end
            if not aindaExiste then
                stockTracker[oldKey] = 0
                priceTracker[oldKey] = nil
                boostTracker[oldKey] = nil
            end
        else
            stockTracker[oldKey] = nil
        end
    end

    table.sort(newList, function(a, b)
        local aBoost = (a.boost_ts and a.boost_ts > now and (a.stock or 0) > 0) and 1 or 0
        local bBoost = (b.boost_ts and b.boost_ts > now and (b.stock or 0) > 0) and 1 or 0
        if aBoost ~= bBoost then return aBoost > bBoost end
        return (a.price / a.lot_size) < (b.price / b.lot_size)
    end)

    listings = newList
    rebuildPriceGroups()
    saveSystemData() 
    statusText = "ONLINE"
end

local function drawCardBox(l, x, y, colW)
    if y > CARDS_BOT or y + CARD_H - 1 < CARDS_TOP then return end
    local isOOS = (l.stock or 0) <= 0
    local now   = os.epoch("utc")
    
    local hasBoost = l.boost_ts and l.boost_ts > now and not isOOS
    local cardBg = hasBoost and getGlobalRainbowColor() or C.bg
    local cardTx = hasBoost and colors.black or C.itemTx
    
    local isNew = newItems[l.id] and (now - newItems[l.id] < 60000)
    local merchantKey = (l.seller or "unknown") .. "_" .. l.item_name
    local liveStatus = itemStatus[merchantKey]
    
    local badgeText, badgeFg, badgeBg = nil, nil, nil
    local rightReserved = 1

    if liveStatus and (now - liveStatus.ts < 60000) then
        if liveStatus.status == "SOLD" then
            badgeText = " SOLD "
            badgeFg   = colors.black
            badgeBg   = (shimmerPh % 2 == 0) and colors.orange or colors.yellow
            rightReserved = rightReserved + 8
        elseif liveStatus.status == "RESTOCK" then
            badgeText = " RESTOCK "
            badgeFg   = colors.white
            badgeBg   = (shimmerPh % 2 == 0) and colors.cyan or colors.blue
            rightReserved = rightReserved + 11
        end
    elseif isNew then
        badgeText, badgeFg, badgeBg = " NEW ", colors.black, C.newBadge
        rightReserved = rightReserved + 6
    end

    local ownerColor = getSellerColor(l.seller)

    for offset = 0, 3 do
        local cy = y + offset
        if cy >= CARDS_TOP and cy <= CARDS_BOT then
            mLine(x, cy, x + colW - 1, cardBg)
            
            if offset == 0 then
                local name = getTruncatedItemName(l, colW)
                mWrite(x + 1, cy, name, cardTx, cardBg)
                if badgeText then mWrite(x + colW - rightReserved + 1, cy, badgeText, badgeFg, badgeBg) end

            elseif offset == 1 then
                local avatarIcon = "[☺]"
                mWrite(x + 1, cy, avatarIcon, ownerColor, cardBg)
                
                local sellerText = " Merchant: " .. (l.seller or "??")
                if #sellerText > colW - 6 then sellerText = sellerText:sub(1, colW - 7) .. "." end
                mWrite(x + 1 + #avatarIcon, cy, sellerText, hasBoost and colors.black or C.sellerTx, cardBg)

            elseif offset == 2 then
                local unitPrice = l.price / l.lot_size
                local priceColor = hasBoost and colors.black or colors.yellow
                
                if not hasBoost then
                    if priceHistory[l.item_name] and type(priceHistory[l.item_name]) == "table" and #priceHistory[l.item_name] > 0 and unitPrice <= priceHistory[l.item_name][#priceHistory[l.item_name]].price then
                        priceColor = colors.cyan
                    else
                        local grp = priceGroups[l.item_name]
                        if grp and grp.count > 1 then
                            if grp.max == grp.min then priceColor = colors.yellow
                            elseif unitPrice == grp.min then priceColor = colors.lime      
                            elseif unitPrice == grp.max then priceColor = colors.red       
                            else priceColor = colors.orange end
                        end
                    end
                end

                local pricing = l.price .. " SP (x" .. l.lot_size .. ")"
                mWrite(x + 1, cy, pricing, priceColor, cardBg)
                
                local priceStatus = itemStatus[merchantKey .. "_price"]
                local currentCursorX = x + 1 + #pricing + 1
                
                if priceStatus and (now - priceStatus.ts < 60000) then
                    local inlineText, pBadgeFg, pBadgeBg = "", colors.white, nil
                    if priceStatus.type == "UP" then
                        inlineText = " [+" .. priceStatus.diff .. " SP UP] "
                        pBadgeBg   = colors.red     
                    elseif priceStatus.type == "DOWN" then
                        inlineText = " [-" .. priceStatus.diff .. " SP DOWN] "
                        pBadgeBg   = colors.green   
                    end
                    mWrite(currentCursorX, cy, inlineText, pBadgeFg, pBadgeBg)
                end
                
                local stockStr = isOOS and "OUT OF STOCK" or ("Stock: " .. l.stock)
                local stockCol = isOOS and colors.red or (hasBoost and colors.black or colors.green)
                mWrite(x + colW - #stockStr - 1, cy, stockStr, stockCol, cardBg)
            end
        end
    end
end

local function drawHeader()
    mLine(1, 1, W, C.header)
    mWrite(2, 1, " ◆ LIVE STREAM TERMINAL PANEL", C.headerTx, C.header)
    mWrite(W - 12, 1, #listings .. " ITEMS ", C.headerTx, C.header)
    
    mLine(1, 2, W, C.bg)
    local sStr = serverId and ("SERVER ID: " .. serverId) or "LOCAL CACHE MODE"
    mWrite(2, 2, sStr .. " | MONITOR MIRROR: ACTIVE", C.sellerTx, C.bg)
    
    if statusText == "ONLINE" or statusText == "STANDBY" then
        mWrite(W - 9, 2, "["..statusText.."]", colors.green, C.bg)
    else
        mWrite(W - #statusText - 1, 2, "[" .. statusText .. "]", colors.red, C.bg)
    end
end

local function drawScrollBar(totalRows)
    local scrollX = W
    if totalRows <= CARDS_H then
        for row = CARDS_TOP, CARDS_BOT do mLine(scrollX, row, scrollX, C.bg) end
        return
    end
    for row = CARDS_TOP, CARDS_BOT do mLine(scrollX, row, scrollX, C.scrollBg) end
    local barSize = math.max(2, math.floor((CARDS_H / totalRows) * CARDS_H))
    local maxScroll = totalRows - CARDS_H
    local scrollPct = scrollOff / maxScroll
    local barTop = CARDS_TOP + math.floor(scrollPct * (CARDS_H - barSize))
    for row = barTop, barTop + barSize - 1 do
        if row >= CARDS_TOP and row <= CARDS_BOT then mLine(scrollX, row, scrollX, C.scrollBar) end
    end
end

local function drawCards()
    if #listings == 0 then
        for row = CARDS_TOP, CARDS_BOT do mLine(1, row, W, C.bg) end
        local loading = "STATUS: " .. statusText
        mWrite(math.floor((W-#loading)/2)+1, math.floor((CARDS_TOP+CARDS_BOT)/2), loading, colors.orange, C.bg)
        return
    end

    local printableW = W - SCROLL_W
    local colW = math.floor((printableW - (NUM_COLUMNS - 1)) / NUM_COLUMNS)
    local numRows   = math.ceil(#listings / NUM_COLUMNS)
    local totalRows = numRows * CARD_H
    local maxScroll = math.max(0, totalRows - CARDS_H)
    if scrollOff > maxScroll then scrollOff = maxScroll end

    for row = CARDS_TOP, CARDS_BOT do mLine(1, row, W - SCROLL_W, C.bg) end

    for i, l in ipairs(listings) do
        local colIdx  = (i - 1) % NUM_COLUMNS
        local itemRow = math.floor((i - 1) / NUM_COLUMNS)
        local cardTop = CARDS_TOP + (itemRow * CARD_H) - scrollOff
        drawCardBox(l, 1 + (colIdx * (colW + 1)), cardTop, colW)
    end
    drawScrollBar(totalRows)
end

local function drawTicker()
    local now = os.epoch("utc")
    
    for i = #notificationQueue, 1, -1 do
        if now - notificationQueue[i].ts > (notificationQueue[i].lifespan * 1000) then
            table.remove(notificationQueue, i)
        end
    end

    local activeText   = tickerText
    local activeBg     = C.tickerBg  
    local activeColor  = C.tickerTx
    local categoryColor = nil
    local isAlertRainbow = false
    
    if #notificationQueue > 0 then
        local chosenAlert = notificationQueue[1]
        if not chosenAlert.isNewItem then
            local displayIdx = (math.floor(now / 5500) % #notificationQueue) + 1
            chosenAlert = notificationQueue[displayIdx]
        end
        
        activeText     = " ▪  " .. chosenAlert.text .. "  ★  "
        activeBg       = chosenAlert.color    
        activeColor    = chosenAlert.txColor  
        categoryColor  = chosenAlert.catColor
        isAlertRainbow = chosenAlert.isRainbow
    end

    if activeText == "" then
        mLine(1, H - 1, W, C.bg)
        mLine(1, H, W, C.bg)
        return
    end

    local currentBgColor = activeBg
    if activeText:find("WELCOME NEW BOOSTED") then
        currentBgColor = colors.black
    end

    mLine(1, H - 1, W, currentBgColor)
    mLine(1, H, W, currentBgColor)

    local cleanText = ""
    local rainbowMap = {}
    local inRainbowZone = false
    local textPtr = 1

    while textPtr <= #activeText do
        if activeText:sub(textPtr, textPtr + 1) == "~[" then
            inRainbowZone = true
            textPtr = textPtr + 2
        elseif activeText:sub(textPtr, textPtr + 1) == "~]" then
            inRainbowZone = false
            textPtr = textPtr + 2
        else
            local char = activeText:sub(textPtr, textPtr)
            cleanText = cleanText .. char
            table.insert(rainbowMap, inRainbowZone)
            textPtr = textPtr + 1
        end
    end

    if #cleanText == 0 then return end 

    local tx = math.floor(tickerPos)
    for i = 1, W do
        local textIdx = ((i - tx - 1) % #cleanText) + 1
        local ch = cleanText:sub(textIdx, textIdx)
        local currentCharColor = activeColor
        
        if isAlertRainbow or (activeText:find("WELCOME NEW BOOSTED") and ch ~= "★" and ch ~= "▪") then
            local cIdx = (textIdx % #rainbowColors) + 1
            currentCharColor = rainbowColors[cIdx]
        elseif rainbowMap[textIdx] then
            local cIdx = ((textIdx + math.floor(now / 150)) % #rainbowColors) + 1
            currentCharColor = rainbowColors[cIdx]
        elseif categoryColor and ch == "▪" then
            currentCharColor = categoryColor
        end
        mWrite(i, H, ch, currentCharColor, currentBgColor)
    end
end

-- ── PAINEL INSPECTOR REESTRUTURADO COM SUPORTE A MICRO-AVATAR 8X ────────────────
local function drawIntegratedOverlay(l)
    if not l then return end
    local now = os.epoch("utc")

    local ow, oh = 38, 13
    local ox = math.floor((W - ow) / 2) + 1
    local oy = math.floor((H - oh) / 2) + 1

    for row = oy - 1, oy + oh do mLine(ox - 1, row, ox + ow, colors.black) end
    for row = oy, oy + oh - 1 do mLine(ox, row, ox + ow - 1, colors.gray) end

    local function oRow(label, val, valCol)
        local rY = oy + 1 + (oRowIdx or 0)
        mWrite(ox + 12, rY, label, colors.white, colors.gray)
        mWrite(ox + 12 + #label, rY, val, valCol or colors.lightGray, colors.gray)
        oRowIdx = (oRowIdx or 0) + 1
    end
    oRowIdx = 0

    mLine(ox, oy, ox + ow - 1, colors.blue)
    local title = " ITEM INSPECTOR "
    mWrite(ox + math.floor((ow - #title)/2), oy, title, colors.white, colors.blue)

    -- ── ENGINE DE AVATAR INTEGRADO 8X ──
    local avatarX = ox + 2
    local avatarY = oy + 2
    local pName = l.seller or "unknown"
    local formattedPlayer = pName:sub(1,1):upper() .. pName:sub(2)
    local iconPath = string.format("%s/8x/%s/face_layer.lua", DIRECTORY_BASE, formattedPlayer)

    if not drawMatrixFromFile(iconPath, avatarX, avatarY) then
        drawNoSignal(avatarX, avatarY) 
    end
    -- ───────────────────────────────────

    local cleanName = l.display_name or l.item_name:match(":(.+)$") or l.item_name
    oRow("Item:    ", cleanName:upper(), colors.yellow)
    oRow("Seller:  ", pName:upper(), colors.white)
    oRow("Stock:   ", tostring(l.stock or 0), (l.stock or 0) > 0 and colors.green or colors.red)
    oRow("Lot:     ", l.lot_size.." un", colors.lightBlue)
    
    local uPrice = l.price / l.lot_size
    oRow("Unit P.: ", uPrice.." SP", colors.yellow)

    local grp = priceGroups[l.item_name]
    if grp and grp.count > 1 then
        oRow("Range:   ", grp.min.."-"..grp.max.." SP", colors.lightGray)
    else
        oRow("Market:  ", "Monopoly", colors.cyan)
    end

    if l.boost_ts and l.boost_ts > now then
        oRow("Boost:   ", "FEATURED", colors.magenta)
    end

    local dRow = oy + oh - 2
    mLine(ox + 1, dRow, ox + ow - 2, colors.black)
    local hint = "Touch anywhere to close"
    mWrite(ox + math.floor((ow - #hint)/2), oy + oh - 1, hint, colors.lightGray, colors.gray)
end

-- ── LOOP DO PROCESSO MARKET LIVE PRINCIPAL ──────────────────────────────────
local function mainMarketLoop()
    mon.setBackgroundColor(C.bg)
    mon.clear()
    term.setBackgroundColor(C.bg)
    term.clear()

    local scrollTimer  = os.startTimer(SCROLL_SPD)
    local tickerTimer  = os.startTimer(TICKER_SPD)
    local refreshTimer = os.startTimer(0.5) 
    local shimmerTimer = os.startTimer(0.4)
    local autoScroll   = true
    local autoScrollDir = 1

    local function sendListRequest()
        currentSeq = currentSeq + 1
        statusText = "LISTENING"
        rednet.broadcast({type="market_public_list", _seq=currentSeq}, PROTOCOL)
        if netTimer then os.cancelTimer(netTimer) end
        netTimer = os.startTimer(2.0)
    end

    while true do
        if not overlayAtivo then
            drawHeader()
            drawCards()
            drawTicker()
        else
            drawIntegratedOverlay(itemSelecionadoOverlay)
        end

        local ev, p1, p2, p3 = os.pullEvent()

        if ev == "timer" then
            if p1 == scrollTimer then
                if autoScroll and #listings > 0 and not overlayAtivo then
                    local numRows   = math.ceil(#listings / NUM_COLUMNS)
                    local totalRows = numRows * CARD_H
                    local maxScroll = math.max(0, totalRows - CARDS_H)
                    scrollOff = scrollOff + autoScrollDir
                    if scrollOff >= maxScroll then autoScrollDir = -1
                    elseif scrollOff <= 0 then autoScrollDir = 1 end
                end
                scrollTimer = os.startTimer(SCROLL_SPD)
            elseif p1 == tickerTimer then
                if (tickerText ~= "" or #notificationQueue > 0) and not overlayAtivo then
                    tickerPos = tickerPos - 1
                    if tickerPos < -500 then tickerPos = W end 
                end
                tickerTimer = os.startTimer(TICKER_SPD)
            elseif p1 == refreshTimer then
                sendListRequest()
                refreshTimer = os.startTimer(REFRESH_INT)
            elseif p1 == shimmerTimer then
                shimmerPh = (shimmerPh + 1) % 4
                shimmerTimer = os.startTimer(0.4)
            elseif p1 == netTimer then
                statusText = (#listings > 0) and "ONLINE" or "TIMEOUT"
                netTimer = nil
            elseif p1 == userTouchTimer then
                autoScroll = true
                userTouchTimer = nil
            elseif p1 == overlayTimer then
                if overlayAtivo then
                    overlayAtivo = false
                    itemSelecionadoOverlay = nil
                    overlayTimer = nil
                    mon.setBackgroundColor(C.bg)
                    mon.clear()
                end
            end
        elseif ev == "rednet_message" and p3 == PROTOCOL then
            handleNetworkMessage(p1, p2)
            buildTicker()
        elseif ev == "monitor_touch" then
            local mx, my = p2, p3
            
            if overlayAtivo then
                if overlayTimer then os.cancelTimer(overlayTimer) overlayTimer = nil end
                overlayAtivo = false
                itemSelecionadoOverlay = nil
                mon.setBackgroundColor(C.bg)
                mon.clear()
            elseif my >= CARDS_TOP and my <= CARDS_BOT then
                autoScroll = false
                if userTouchTimer then os.cancelTimer(userTouchTimer) end
                userTouchTimer = os.startTimer(RESUME_TIME)

                local printableW = W - SCROLL_W
                local colW = math.floor((printableW - (NUM_COLUMNS - 1)) / NUM_COLUMNS)

                local colIdx = 0
                if mx > colW + 1 then colIdx = 1 end

                local cardStartX = 1 + (colIdx * (colW + 1))
                local cliqueRealY = my + scrollOff - CARDS_TOP
                local itemRow = math.floor(cliqueRealY / CARD_H)
                
                local linhaInternaCard = cliqueRealY % CARD_H

                local itemIdx = (itemRow * NUM_COLUMNS) + colIdx + 1
                local itemSelecionado = listings[itemIdx]

                local clicouNoNomeText = false
                if itemSelecionado and linhaInternaCard == 0 then
                    local nameText = getTruncatedItemName(itemSelecionado, colW)
                    local maxNomeX = cardStartX + 1 + #nameText - 1
                    
                    if mx >= (cardStartX + 1) and mx <= maxNomeX then
                        clicouNoNomeText = true
                    end
                end

                if clicouNoNomeText then
                    overlayAtivo = true
                    itemSelecionadoOverlay = itemSelecionado
                    if overlayTimer then os.cancelTimer(overlayTimer) end
                    overlayTimer = os.startTimer(OVERLAY_TIMEOUT)
                else
                    if my < (CARDS_TOP + CARDS_BOT) / 2 then
                        scrollOff = math.max(0, scrollOff - CARD_H)
                    else
                        local numRows   = math.ceil(#listings / NUM_COLUMNS)
                        local totalRows = numRows * CARD_H
                        scrollOff = math.min(math.max(0, totalRows - CARDS_H), scrollOff + CARD_H)
                    end
                end
            end
        elseif ev == "key" and p1 == keys.q then
            break
        end
    end

    if overlayTimer then os.cancelTimer(overlayTimer) end
    mon.setBackgroundColor(colors.black) mon.clear()
    term.setBackgroundColor(colors.black) term.clear()
    term.setCursorPos(1,1)
end

-- ── EXECUÇÃO ───────────────────────────────────────────────────────────────
local threads = { mainMarketLoop }
local bCount = 1

for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" and name ~= peripheral.getName(mon) then
        local monitorName = name
        local brokerIndex = bCount
        
        table.insert(threads, function()
            shell.run("broker_display", monitorName, tostring(brokerIndex))
        end)
        
        bCount = bCount + 1
    end
end

parallel.waitForAny(table.unpack(threads))