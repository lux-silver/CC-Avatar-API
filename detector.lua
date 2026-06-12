-- ======================================================================
--  COMBINED SKIN SERVER: 4x3 GRID, SIDE SLIDER & LIVE RENDER WITH NAMES
-- ======================================================================

package.loaded["api_avatar"] = nil
local api = dofile("api_avatar.lua")

local DIRECTORY_BASE = "cache/skin"

-- Peripherals Setup
local detector = peripheral.find("playerDetector") or peripheral.find("player_detector")
local monitor = peripheral.find("monitor")
local modem = peripheral.find("modem")

if not detector then error("[!] Error: Player Detector peripheral not found.") end
if not monitor then error("[!] Error: Monitor required for the UI.") end

monitor.setTextScale(0.5)
monitor.setBackgroundColor(colors.black)
monitor.clear()

if modem then rednet.open(peripheral.getName(modem)) end

-- Global State Control
local waitingQueue = {}
local isDownloading = false     
local activeDownloadMatrix = nil
local currentDownloadStatus = ""
local activeDownloadPlayer = "" -- Guarda o nome do jogador atual do download

-- UI Navigation Control
local currentMode = "LIST" 
local scrollOffset = 0  
local playerList = {}
local selectedPlayer = ""
local currentSliderIndex = 1

-- Configurações da Grade 4x3
local ICON_SIZE = 16
local PADDING_X = 5
local PADDING_Y = 5
local COLS = 4 
local ROWS = 3 

local sizeSteps = {8, 16, 32, 64}
local allFormats = {"face", "face_layer", "head", "bust", "front", "frontfull", "full"}
local sliderFormats = {
    {modo = "face", tamanho = 32}, {modo = "face_layer", tamanho = 32},
    {modo = "head", tamanho = 32}, {modo = "bust", tamanho = 32},
    {modo = "front", tamanho = 32}, {modo = "full", tamanho = 32},
    {modo = "frontfull", tamanho = 64}, {modo = "full", tamanho = 64}
}

-- Scans storage to populate player data
local function scanCachedPlayers()
    playerList = {}
    local path = DIRECTORY_BASE .. "/16x"
    if fs.exists(path) then
        local folders = fs.list(path)
        for _, name in ipairs(folders) do table.insert(playerList, name) end
    end
end

local function serializeTable(tab)
    local result = "return {\n"
    for _, line in ipairs(tab) do result = result .. '    "' .. line .. '",\n' end
    return result .. "}"
end

local function drawMatrixFromFile(filePath, startX, startY)
    if not fs.exists(filePath) then return false end
    local chunk = loadfile(filePath)
    if not chunk then return false end
    local matrix = chunk()
    
    -- Proteção contra tabelas vazias ou corrompidas que causam index out of bounds
    if not matrix or type(matrix) ~= "table" or #matrix == 0 then return false end
    
    for i, colorLine in ipairs(matrix) do
        if type(colorLine) == "string" and colorLine ~= "" then
            monitor.setCursorPos(startX, startY + i - 1)
            monitor.blit(string.rep(" ", #colorLine), colorLine, colorLine)
        end
    end
    return true
end

-- ======================================================================
--  DYNAMIC RENDER ENGINE
-- ======================================================================
local function renderScreen()
    local mWidth, mHeight = monitor.getSize()
    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    -- 1. TELA DE INSTALAÇÃO ATIVA (Mostrando Fila, Player Atual e Imagem)
    if isDownloading then
        if activeDownloadMatrix then
            api.draw(monitor, 1, 1, activeDownloadMatrix)
        end
        
        -- Rodapé completo e dinâmico com todas as informações solicitadas
        local w, h = monitor.getSize()
        monitor.setCursorPos(1, h)
        monitor.setTextColor(colors.yellow)
        monitor.setBackgroundColor(colors.gray)
        
        local queueCount = #waitingQueue
        local statusText = string.format(" [File: %d] Installing: %s | %s", queueCount, activeDownloadPlayer, currentDownloadStatus)
        monitor.write(string.format(" %-" .. (w-2) .. "s ", statusText))
        
        monitor.setBackgroundColor(colors.black)
        return
    end

    -- 2. MAIN LIST (GRADE 4x3)
    if currentMode == "LIST" then
        monitor.setCursorPos(1, 1)
        monitor.setBackgroundColor(colors.blue)
        monitor.setTextColor(colors.white)
        monitor.write(string.format(" SKIN GALLERY PANEL - 4x3 GRID (%d Registered) ", #playerList))
        monitor.setBackgroundColor(colors.black)

        local slotWidth = ICON_SIZE + PADDING_X
        local slotHeight = ICON_SIZE + PADDING_Y + 2

        local startIdx = (scrollOffset * COLS) + 1
        local maxDisplayable = COLS * ROWS
        local endIdx = math.min(startIdx + maxDisplayable - 1, #playerList)

        for i = startIdx, endIdx do
            local relativeIdx = i - startIdx
            local row = math.floor(relativeIdx / COLS)
            local col = relativeIdx % COLS

            local posX = 4 + (col * slotWidth)
            local posY = 4 + (row * slotHeight)

            local pName = playerList[i]
            local iconPath = string.format("%s/16x/%s/face.lua", DIRECTORY_BASE, pName)

            if not drawMatrixFromFile(iconPath, posX, posY) then
                for yOffset = 0, 15 do
                    monitor.setCursorPos(posX, posY + yOffset)
                    monitor.setBackgroundColor(colors.lightGray)
                    monitor.write(string.rep(" ", ICON_SIZE))
                end
            end

            monitor.setCursorPos(posX, posY + ICON_SIZE)
            monitor.setTextColor(colors.yellow)
            monitor.write(string.sub(pName, 1, ICON_SIZE))
        end

    -- 3. SLIDER CAROUSEL (MUDANÇA LATERAIS)
    elseif currentMode == "SLIDER" then
        monitor.setCursorPos(1, 1)
        monitor.setBackgroundColor(colors.orange)
        monitor.setTextColor(colors.white)
        monitor.write(string.format("  PLAYER: %s  ", selectedPlayer:upper()))
        
        monitor.setCursorPos(2, mHeight)
        monitor.setBackgroundColor(colors.red)
        monitor.write(" [ BACK TO GALLERY LIST ] ")
        monitor.setBackgroundColor(colors.black)

        local config = sliderFormats[currentSliderIndex]
        local filePath = string.format("%s/%dx/%s/%s.lua", DIRECTORY_BASE, config.tamanho, selectedPlayer, config.modo)
        
        monitor.setCursorPos(2, 3)
        monitor.setTextColor(colors.cyan)
        monitor.write(string.format("Style: %s (%dx%d)", config.modo:upper(), config.tamanho, config.tamanho))

        local centerX = math.floor((mWidth / 2) - (config.tamanho / 2))
        local centerY = math.floor((mHeight / 2) - (config.tamanho / 2))
        if centerX < 1 then centerX = 12 end
        if centerY < 4 then centerY = 4 end
        
        if not drawMatrixFromFile(filePath, centerX, centerY) then
            monitor.setCursorPos(centerX, centerY + 2)
            monitor.setTextColor(colors.lightGray)
            monitor.write("[ Rendering Asset... ]")
        end
    end
end

-- ======================================================================
--  DOWNLOAD PIPELINE (EXIBE RENDER LIVE + PLAYER NAME)
-- ======================================================================
local function runDownloadPipeline()
    while true do
        if #waitingQueue > 0 then
            isDownloading = true 
            local activePlayer = table.remove(waitingQueue, 1)
            activeDownloadPlayer = activePlayer:sub(1,1):upper() .. activePlayer:sub(2)
            
            for _, size in ipairs(sizeSteps) do
                local targetDir = string.format("%s/%dx/%s", DIRECTORY_BASE, size, activeDownloadPlayer)
                for _, format in ipairs(allFormats) do
                    if not (size <= 16 and (format ~= "face" and format ~= "face_layer")) then
                        
                        currentDownloadStatus = string.format("[%dx] Updating %s...", size, format)
                        
                        if not fs.exists(targetDir) then fs.makeDir(targetDir) end
                        local localFilePath = string.format("%s/%s.lua", targetDir, format)
                        
                        local pixelMatrix = api.fetchRender(activePlayer, format, size)
                        if pixelMatrix then
                            activeDownloadMatrix = pixelMatrix 
                            renderScreen() 
                            
                            local file = fs.open(localFilePath, "w")
                            file.write(serializeTable(pixelMatrix))
                            file.close()
                        end
                        sleep(0.15) 
                    end
                end
            end
            
            isDownloading = false 
            activeDownloadMatrix = nil
            activeDownloadPlayer = ""
            scanCachedPlayers()   
            renderScreen()        
        end
        sleep(0.5)
    end
end

-- ======================================================================
--  INTERACTIVE TOUCH & EVENTS LISTENER
-- ======================================================================
local function runInputListener()
    scanCachedPlayers()
    renderScreen()

    while true do
        local eventData = { os.pullEvent() }
        local event = eventData[1]

        if event == "playerClick" or event == "playerJoin" then
            local user = eventData[2]
            local duplicate = false
            for _, n in ipairs(waitingQueue) do
                if n:lower() == user:lower() then duplicate = true break end
            end
            if not duplicate then
                table.insert(waitingQueue, user)
                if isDownloading then renderScreen() end 
            end

        elseif event == "monitor_touch" and not isDownloading then
            local side, x, y = eventData[2], eventData[3], eventData[4]
            local mWidth, mHeight = monitor.getSize()

            -- LAYOUT CONFIG A: MODO GRADE (Scroll Dividido Cima / Baixo)
            if currentMode == "LIST" then
                local slotWidth = ICON_SIZE + PADDING_X
                local slotHeight = ICON_SIZE + PADDING_Y + 2
                
                local startIdx = (scrollOffset * COLS) + 1
                local maxDisplayable = COLS * ROWS
                local endIdx = math.min(startIdx + maxDisplayable - 1, #playerList)
                local clickedIcon = false

                for i = startIdx, endIdx do
                    local relativeIdx = i - startIdx
                    local row = math.floor(relativeIdx / COLS)
                    local col = relativeIdx % COLS

                    local posX = 4 + (col * slotWidth)
                    local posY = 4 + (row * slotHeight)

                    if x >= posX and x <= (posX + ICON_SIZE) and y >= posY and y <= (posY + slotHeight) then
                        selectedPlayer = playerList[i]
                        currentSliderIndex = 1
                        currentMode = "SLIDER"
                        clickedIcon = true
                        renderScreen()
                        break
                    end
                end

                if not clickedIcon then
                    local totalRowsNeeded = math.ceil(#playerList / COLS)
                    if y <= math.floor(mHeight / 2) then
                        if scrollOffset > 0 then 
                            scrollOffset = scrollOffset - 1 
                            renderScreen() 
                        end
                    else
                        if (scrollOffset + ROWS) < totalRowsNeeded then 
                            scrollOffset = scrollOffset + 1 
                            renderScreen() 
                        end
                    end
                end

            -- LAYOUT CONFIG B: MODO SLIDER (Mudança pelas laterais Esquerda / Direita)
            elseif currentMode == "SLIDER" then
                if y >= mHeight - 1 and x <= 30 then
                    currentMode = "LIST"
                    renderScreen()
                else
                    if x <= math.floor(mWidth / 2) then
                        currentSliderIndex = currentSliderIndex > 1 and currentSliderIndex - 1 or #sliderFormats
                    else
                        currentSliderIndex = currentSliderIndex < #sliderFormats and currentSliderIndex + 1 or 1
                    end
                    renderScreen()
                end
            end

        elseif event == "rednet_message" then
            local senderID, payload, msgProtocol = eventData[2], eventData[3], eventData[4]
            


parallel.waitForAny(runDownloadPipeline, runInputListener)
