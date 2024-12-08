-- /page.lua?p=N: single page view

local utils = require('utils')


-- FUNCTIONS

-- Returns a function for formatting n-byte hex values.
function getHexFormatter(byteCount)
    local formatSpec = '%0' .. (2 * byteCount) .. 'X'
    return function(x)
        return string.format(formatSpec, x)
    end
end


-- MAIN SCRIPT

-- Load DB, params
local dbFile, basics = utils.OpenDbAndGetBasics(dbFile)
local pageNumber = nil
for i, it in ipairs(GetParams()) do
    if it[1] == 'p' then
        pageNumber = tonumber(it[2])
    end
end
if pageNumber == nil then
    error('Page number is required on the URL (?p=42)')
end

-- Load the page data
unix.lseek(dbFile, (pageNumber - 1) * basics.PageSize, SEEK_SET)
local pageData = unix.read(dbFile, basics.PageSize)

-- Peel off DB header on page 1
local dbHeaderData = nil
local usablePageData = pageData
if pageNumber == 1 then
    dbHeaderData = string.sub(pageData, 1, 100)
    usablePageData = string.sub(pageData, 101)
end

-- Peel off reserved bytes if any
local pageReservedBytes = nil
if basics.PageEndReservedBytes > 0 then
    local reservedStartOffset = #usablePageData - basics.PageEndReservedBytes + 1
    pageReservedBytes = string.sub(usablePageData, reservedStartOffset)
    usablePageData = string.sub(usablePageData, 1, reservedStartOffset - 1)
end

-- Get page type
local btreeType = string.unpack('B', string.sub(usablePageData, 1, 1))
local isTable = false
local isLeaf = false
local isBtree = false
if (btreeType == 0x02 or btreeType == 0x05 or btreeType == 0x0a or btreeType == 0x0d) then
    isBtree = true
    if (btreeType == 0x05 or btreeType == 0x0d) then
        isTable = true
    end
    if (btreeType == 0x0a or btreeType == 0x0d) then
        isLeaf = true
    end
end
local friendlyType = 'Other'
if isBtree then
    friendlyType = utils.Iif(isTable, 'Table ', 'Index ') .. utils.Iif(isLeaf, 'Leaf', 'Interior')
end

-- Start the HTML page
utils.WritePageHeader(basics.Name, true, pageNumber)
Write('<div class="big">')
utils.WritePrintouts('Page', pageNumber, 'Type', friendlyType)
Write('</div>')


-- Database header: parse & display if present
if dbHeaderData then

    Write('<h2>Database Header (Page 1)</h2>')
    utils.WriteHexDump(dbHeaderData)
    
    function formatVersion(x) if x == 1 then return '1 (Legacy)' end return '2 (WAL)' end
    utils.ParseAndWriteValues(dbHeaderData, {
        { 'Header Magic',                   16,     function(x) return x .. '\\0' end },
        { 'Page Size',                      '>I2',  function(x) if x == 0 then return 65536 end return x end },
        { 'Write Version',                  'B',    formatVersion },
        { 'Read Version',                   'B',    formatVersion },
        { 'Page End Reserved Bytes',        'B',    nil },
        { 'Max Embedded Payload Fraction',  'B',    nil },
        { 'Min Embedded Payload Fraction',  'B',    nil },
        { 'Leaf Embedded Payload Fraction', 'B',    nil },
        { 'File Change Counter',            '>I4',  nil },
        { 'Page Count',                     '>I4',  nil },
        { 'First Freelist Trunk Page',      '>I4',  utils.GetPageLink },
        { 'Freelist Page Count',            '>I4',  nil },
        { 'Schema Cookie',                  '>I4',  nil },
        { 'Schema Format Number',           '>I4',  nil },
        { 'Default Page Cache Size',        '>I4',  nil },
        { 'Auto-Vacuum Largest Root Page', '>I4',   nil },
        { 'Text Encoding',                  '>I4',  function(x) if x == 1 then return x .. ' (UTF-8)' elseif x == 2 then return x .. ' (UTF-16le)' elseif x == 3 then return x .. ' (UTF-16be)' else return x end end },
        { 'User Version',                   '>I4',  nil },
        { 'Incremental Vacuum',             '>I4',  nil },
        { 'Application ID',                 '>I4',  nil },
        { nil,                              20,     nil },
        { 'Version Valid For',              '>I4',  nil },
        { 'SQLite Version',                 '>I4',  nil },
    }, false)
end 

-- Determine page type
local pageStart = (pageNumber - 1) * basics.PageSize
local pageEnd = pageStart + basics.PageSize
local pageType = 'unknown'
if 1073741824 >= pageStart and 1073742335 < pageEnd then
    pageType = 'lockbyte'
elseif isBtree then
    pageType = 'btree'
end

-- Lock-byte page: just display raw data (single page in > 1 TB databases so probably will never be seen)
if pageType == 'lockbyte' then
    Write('<h2>Lock-Byte Page Data</h2>')
    utils.WriteHexDump(usablePageData)
    
-- B-tree page: 
elseif pageType == 'btree' then

    -- Show B-tree header
    Write('<h2>B-Tree Page Header</h2>')
    local headerSize = utils.Iif(isLeaf, 8, 12)
    local btreeHeaderData = string.sub(usablePageData, 1, headerSize)
    utils.WriteHexDump(btreeHeaderData, true)
    local schema = {
        { 'B-Tree Page Type',       'B',     function(x) return getHexFormatter(1)(x) .. ' (' .. friendlyType .. ')' end },
        { 'First Freeblock Offset', '>I2',   getHexFormatter(2) },
        { 'Cell Count',             '>I2',   nil },
        { 'Cell Start Offset',      '>I2',   getHexFormatter(2) },
        { 'Fragmented Free Bytes',  'B',     nil },
    }
    if not isLeaf then
        schema[#schema + 1] = { 'Rightmost Pointer', '>I4', utils.GetPageLink }
    end
    local btreeHeader = utils.ParseAndWriteValues(btreeHeaderData, schema, false)

    -- If there are cells... 
    local cellArray = {}
    local toHex16 = getHexFormatter(2)
    if btreeHeader['Cell Count'] > 0 then

        -- Parse & show cell pointer array
        Write('<h2>Cell Pointer Array</h2>')
        local headerOffset = headerSize + 1
        local cellArrayData = string.sub(usablePageData, headerOffset, headerOffset + btreeHeader['Cell Count'] * 2 - 1)
        utils.WriteHexDump(cellArrayData)
        Write('<p>\n[')
        for i = 1, #cellArrayData, 2 do
            local cellOffset = string.unpack('>I2', string.sub(cellArrayData, i, i + 1))
            cellArray[(i + 1) // 2] = cellOffset
            local hexOffset = toHex16(cellOffset)
            Write('<a href="#' .. hexOffset .. '">' .. hexOffset .. '</a>')
            if i + 1 < #cellArrayData then
                Write(', ')
            end
        end
        Write(']</p>\n')
    end
    
    -- Find & show unallocated region
    local unallocatedStart = 1 + headerSize + btreeHeader['Cell Count'] * 2
    if pageNumber == 1 then
        unallocatedStart = unallocatedStart + 100
    end
    local unallocatedEnd = btreeHeader['Cell Start Offset']
    local unallocatedData = string.sub(pageData, unallocatedStart, unallocatedEnd)
    if #unallocatedData > 0 then
        Write('<h2>Unallocated Region</h2>')
        utils.WriteHexDump(unallocatedData)
    end

    -- If there are cells... 
    if #cellArray > 0 then
        Write('<h2>Cells</h2>')

        -- Calculate common payload metrics
        local u = basics.PageSize - basics.PageEndReservedBytes
        local x = 0
        if isLeaf and isTable then
            x = u - 35
        elseif not isTable then
            x = ((u - 12) * 64 // 255) - 23
        end
        local m = ((u - 12) * 32 // 255) - 23
        
        -- For each cell...
        for _, cellOffset in ipairs(cellArray) do

            -- Show heading / anchor
            local hexOffset = toHex16(cellOffset)
            Write([[
                <a class="anchor" id="]] .. hexOffset .. [["></a>
                <h3>Cell: Offset ]] .. hexOffset .. [[</h3>
            ]])

            -- Cell header: choose what to read 
            local cellToEnd = string.sub(pageData, cellOffset + 1)
            local schema = {}
            local hasPayload = false
            if not isLeaf then  -- interior cells: left pointer
                schema[#schema + 1] = { 'Left Pointer', '>I4', utils.GetPageLink }
            end
            if not (isTable and not isLeaf) then -- all except table interior: payload size
                hasPayload = true
                schema[#schema + 1] = { 'Payload Size', 'VAR', nil }
            end
            if isTable then -- table interior & leaf: row ID
                schema[#schema + 1] = { 'RowId', 'VAR', nil }
            end
            local cellHeader = utils.ParseAndWriteValues(cellToEnd, schema, true)
            local cellHeaderData = string.sub(cellToEnd, 1, cellHeader['ParsedSize'])
            utils.WriteHexDump(cellHeaderData, true)
            local cellHeader = utils.ParseAndWriteValues(cellToEnd, schema, false) -- have to parse again for proper hex/friendly display order, hacky but whatever...

            -- Check if there's overflow
            local onPagePayloadSizeAfterOverflow = nil
            if not (isTable and not isLeaf) then   -- all except table interior...
                local onPageSize = nil
                if cellHeader['Payload Size'] > x then
                    local k = m + ((cellHeader['Payload Size'] - m) % (u - 4))
                    onPageSize = utils.Iif(k <= x, k, m)
                end
                if onPageSize and cellHeader['Payload Size'] > onPageSize then
                    onPagePayloadSizeAfterOverflow = onPageSize
                end
            end

            -- If there's a payload...
            if hasPayload then
                
                -- Extract it & dump hex
                -- ... overflowed cells: just dump hex and show link to next overflow page
                if onPagePayloadSizeAfterOverflow then
                    local cellPayloadData = string.sub(cellToEnd, cellHeader['ParsedSize'] + 1)
                    local onPagePayloadData = string.sub(cellPayloadData, 1, onPagePayloadSizeAfterOverflow + 1)
                    utils.WriteHexDump(onPagePayloadData)
                    utils.ParseAndWriteValues(string.sub(cellPayloadData, onPagePayloadSizeAfterOverflow + 1, onPagePayloadSizeAfterOverflow + 4 + 1), {{ 'Overflows To Page', '>I4', utils.GetPageLink }}, false)
                -- ... normal cells: display hex dump & parsed SQLite record format
                else
                    local cellPayloadData = string.sub(cellToEnd, cellHeader['ParsedSize'] + 1)
                    cellPayloadData = string.sub(cellPayloadData, 1, cellHeader['Payload Size'])
                    utils.WriteHexDump(cellPayloadData, true)
                    utils.ParseAndWriteSqliteRecord(cellPayloadData)
                end
            end
            
        end -- next cell
        
    end -- if cells

-- Other page types: just show hexdump
else
    Write('<h2>Other Page (Overflow / Freelist / Ptrmap)</h2>')
    utils.WriteHexDump(usablePageData)
end

-- Show reserved end bytes if present
if pageReservedBytes then
    Write('<h2>Page End Reserved Bytes</h2>')
    utils.WriteHexDump(pageReservedBytes, false)
end

-- Finish page
Write([[
    </div>
]])
utils.WritePageFooter()

-- Clean up
unix.close(dbFile)