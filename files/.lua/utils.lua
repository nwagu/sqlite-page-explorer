local utils = {}


-- Inline if, cause I like ternary.
function utils.Iif(condition, resultIfTrue, resultIfFalse)
    if condition then return resultIfTrue else return resultIfFalse end
end


-- Takes a static asset path like "js/shared.js" and returns a relative URL with a modification-time cachebreaker parameter. 
function utils.Static(path)
    local url = '/static/' .. path
    lastModified = GetAssetLastModifiedTime(url)
    if lastModified ~= nil then
        url = url .. '?v=' .. lastModified
    end
    return url
end


-- Returns a dbFile unix descrptor, and Lua table with basic database stats.
function utils.OpenDbAndGetBasics()
    if not g_DbPath then
        error('A SQLite database is required (1st command line argument)')
    end
    local basics = {
        Name = path.basename(g_DbPath),
    }
    local dbFile = unix.open(g_DbPath, O_RANDOM)
    local magic = unix.read(dbFile, 16)
    if magic ~= 'SQLite format 3\0' then
        error('Not a SQLite file.')
    end
    basics.PageSize = string.unpack(">I2", unix.read(dbFile, 2)) or 65536
    unix.lseek(dbFile, 0x14, SEEK_SET)
    basics.PageEndReservedBytes = string.unpack("B", unix.read(dbFile, 1))
    unix.lseek(dbFile, 0x1c, SEEK_SET)
    basics.PageCount = string.unpack(">I4", unix.read(dbFile, 4))
    unix.lseek(dbFile, 0, SEEK_SET)
    return dbFile, basics
end


-- Seeks the dbFile descriptor to the given 1-based SQLite page number.
function utils.SeekToPage(dbFile, dbBasics, pageNumber)
    local pageHeaderOffset = (pageNumber - 1) * dbBasics.PageSize
    if pageHeaderOffset == 0 then
        pageHeaderOffset = 100  -- skip DB header on page 1
    end
    unix.lseek(dbFile, pageHeaderOffset, SEEK_SET)
end


-- Gets a hyperlink to a page.
function utils.GetPageLink(pageNumber)
    if not pageNumber or pageNumber < 1 then
        return pageNumber
    end
    return '<a href="javascript:void(0);" onclick="loadPageDetails(' .. pageNumber .. ')">' .. pageNumber .. '</a>'
end


-- Writes a key/value printouts section, where args are key, value, key, value. Skips nil keys.
function utils.WritePrintouts(...)
    Write('<p class="printouts">')
    local args = {...}
    for i = 1, #{...}, 2 do
        if args[i] ~= nil then
            Write('<span><strong>' .. args[i] .. ':</strong> ' .. args[i + 1] .. ' &nbsp; </span>\n')
        end
    end
    Write('</p>')
end


-- Reads a SQLite varint (1-9 bytes) from the front of string "data". Returns value, bytesRead.
function utils.ReadVarint(data)

    -- Read bytes into a table (little first), strip leading bits on all but the last
    local bs = {}
    for i = 1, 9 do
        local b = string.byte(string.sub(data, i, i))
        if ((b & 0x80) ~= 0 and i ~= 9) then
            table.insert(bs, 1, b & 0x7F)
        else
            table.insert(bs, 1, b)
            break
        end
    end

    -- Assemble into an int
    local result = 0
    local shift = 0
    for i, b in ipairs(bs) do
        result = result | (b << shift)
        shift = shift + 7
        if i == 1 and #bs == 9 then
            shift = shift + 1
        end
    end

    -- Interpret negatives (always 9 bytes, apparently uncommon in this scheme)
    if #bs == 9 and (result & (1 << 63)) ~= 0 then
        local twosComplementBytes = (result & ((1 << 63) - 1)) - (1 << 63)
        result = twosComplementBytes
    end

    return result, #bs
end


-- Parses the given bytes in SQLite's record format and writes it out as an HTML table.
function utils.ParseAndWriteSqliteRecord(record)

    -- Start table
    Write('<table class="record"><tr>')
    
    -- Read header
    local index = 1
    local serialTypes = {}
    
    -- Read the header size
    local headerSize, bytesRead = utils.ReadVarint(record:sub(index))
    index = index + bytesRead

    -- Read serialization types
    while index <= headerSize do
        local serialType, bytesRead = utils.ReadVarint(record:sub(index))
        index = index + bytesRead
        table.insert(serialTypes, serialType)
    end
    
    -- Read & convert serial values
    for _, it in ipairs(serialTypes) do
        local value = ''
        if it == 0 then
            value = 'NULL'
        elseif it >= 1 and it <= 6 then -- 8, 16, 24, 32, 48, or 64 bit int
            local byteCount = it
            if it == 5 then byteCount = 6 elseif it == 6 then byteCount = 8 end
            value = string.unpack('>i' .. byteCount, record:sub(index, index + byteCount - 1))
            index = index + byteCount
        elseif it == 7 then -- 64bit float
            value = string.unpack(">d", record:sub(index, index + 8 - 1))
            index = index + 8
        elseif it == 8 then -- integer 0
            value = 0
        elseif it == 9 then -- integer 1
            value = 1
        elseif it >= 12 and it % 2 == 0 then -- blob
            local length = (it - 12) // 2
            local blob = string.sub(record, index, index + length - 1)
            value = ''
            for i = 1, #blob do
                value = value .. string.format("%02X", blob:byte(i))
            end
            index = index + length
        elseif it >= 13 and it % 2 == 1 then -- string
            local length = (it - 13) // 2
            local blob = record:sub(index, index + length - 1)
            value = blob
            index = index + length
        end

        -- Escape HTML
        value = EscapeHtml(tostring(value))

        Write('<td>' .. value .. '</td>')
    end

    -- Finish table
    Write('</tr></table>')
end


-- Parses and writes out some key/value pairs based on a schema table:
-- { { 'Label', formatSpec, optionalFormatFunc }, ... }
-- Returns the parsed results as a k/v table with label as the keys. Includes a 'ParsedSize' key.
function utils.ParseAndWriteValues(data, schema, skipWrite)

    if not skipWrite then
        Write('<p class="printouts">')
    end

    local offset = 1
    local parsedResults = {}
    for _, it in ipairs(schema) do

        local label, formatSpec, formatFunc = table.unpack(it)

        local byteCount = 1
        local doUnpack = false
        if type(formatSpec) == 'number' then
            byteCount = formatSpec
            doUnpack = false
        elseif formatSpec == '>I4' then
            byteCount = 4
            doUnpack = true
        elseif formatSpec == '>I2' then
            byteCount = 2
            doUnpack = true
        elseif formatSpec == 'B' then
            byteCount = 1
            doUnpack = true
        elseif formatSpec == 'VAR' then
            byteCount = 0
            doUnpack = false
        end

        local value = ''
        local isPrintable = label ~= nil
        if isPrintable then
            if formatSpec == 'VAR' then  -- SQLite varint
                value, byteCount = utils.ReadVarint(string.sub(data, offset))
            else
                value = string.sub(data, offset, offset + byteCount - 1)
            end
        end
        if doUnpack then
            value = string.unpack(formatSpec, value)
        end

        if isPrintable then
            parsedResults[label] = value
        end

        if formatFunc then
            value = formatFunc(value)
        end

        if isPrintable and not skipWrite then
            Write('<span><strong>' .. label .. ':</strong> ' .. value .. ' &nbsp; </span>\n')
        end
        offset = offset + byteCount
    end

    if not skipWrite then
        Write('</p>')
    end
    
    parsedResults['ParsedSize'] = offset - 1
    return parsedResults
end


-- Codepage 437 lookup table, for hex dumps.
local cp437ToUtf8 = {
    [0x00] = "·", [0x01] = "☺", [0x02] = "☻", [0x03] = "♥",
    [0x04] = "♦", [0x05] = "♣", [0x06] = "♠", [0x07] = "•",
    [0x08] = "◘", [0x09] = "○", [0x0A] = "◙", [0x0B] = "♂",
    [0x0C] = "♀", [0x0D] = "♪", [0x0E] = "♫", [0x0F] = "☼",
    [0x10] = "►", [0x11] = "◄", [0x12] = "↕", [0x13] = "‼",
    [0x14] = "¶", [0x15] = "§", [0x16] = "▬", [0x17] = "↨",
    [0x18] = "↑", [0x19] = "↓", [0x1A] = "→", [0x1B] = "←",
    [0x1C] = "∟", [0x1D] = "↔", [0x1E] = "▲", [0x1F] = "▼",
    [0x20] = " ", [0x7F] = "⌂",
    -- Extended characters mapping (codes 128-255)
    [0x80] = "Ç", [0x81] = "ü", [0x82] = "é", [0x83] = "â",
    [0x84] = "ä", [0x85] = "à", [0x86] = "å", [0x87] = "ç",
    [0x88] = "ê", [0x89] = "ë", [0x8A] = "è", [0x8B] = "ï",
    [0x8C] = "î", [0x8D] = "ì", [0x8E] = "Ä", [0x8F] = "Å",
    [0x90] = "É", [0x91] = "æ", [0x92] = "Æ", [0x93] = "ô",
    [0x94] = "ö", [0x95] = "ò", [0x96] = "û", [0x97] = "ù",
    [0x98] = "ÿ", [0x99] = "Ö", [0x9A] = "Ü", [0x9B] = "¢",
    [0x9C] = "£", [0x9D] = "¥", [0x9E] = "₧", [0x9F] = "ƒ",
    [0xA0] = "á", [0xA1] = "í", [0xA2] = "ó", [0xA3] = "ú",
    [0xA4] = "ñ", [0xA5] = "Ñ", [0xA6] = "ª", [0xA7] = "º",
    [0xA8] = "¿", [0xA9] = "⌐", [0xAA] = "¬", [0xAB] = "½",
    [0xAC] = "¼", [0xAD] = "¡", [0xAE] = "«", [0xAF] = "»",
    [0xB0] = "░", [0xB1] = "▒", [0xB2] = "▓", [0xB3] = "│",
    [0xB4] = "┤", [0xB5] = "Á", [0xB6] = "Â", [0xB7] = "À",
    [0xB8] = "©", [0xB9] = "╣", [0xBA] = "║", [0xBB] = "╗",
    [0xBC] = "╝", [0xBD] = "¢", [0xBE] = "¥", [0xBF] = "┐",
    [0xC0] = "└", [0xC1] = "┴", [0xC2] = "┬", [0xC3] = "├",
    [0xC4] = "─", [0xC5] = "┼", [0xC6] = "ã", [0xC7] = "Ã",
    [0xC8] = "╚", [0xC9] = "╔", [0xCA] = "╩", [0xCB] = "╦",
    [0xCC] = "╠", [0xCD] = "═", [0xCE] = "╬", [0xCF] = "¤",
    [0xD0] = "ð", [0xD1] = "Ð", [0xD2] = "Ê", [0xD3] = "Ë",
    [0xD4] = "È", [0xD5] = "ı", [0xD6] = "Í", [0xD7] = "Î",
    [0xD8] = "Ï", [0xD9] = "┘", [0xDA] = "┌", [0xDB] = "█",
    [0xDC] = "▄", [0xDD] = "¦", [0xDE] = "Ì", [0xDF] = "▀",
    [0xE0] = "Ó", [0xE1] = "ß", [0xE2] = "Ô", [0xE3] = "Ò",
    [0xE4] = "õ", [0xE5] = "Õ", [0xE6] = "µ", [0xE7] = "þ",
    [0xE8] = "Þ", [0xE9] = "Ú", [0xEA] = "Û", [0xEB] = "Ù",
    [0xEC] = "ý", [0xED] = "Ý", [0xEE] = "¯", [0xEF] = "´",
    [0xF0] = "≡", [0xF1] = "±", [0xF2] = "‗", [0xF3] = "¾",
    [0xF4] = "¶", [0xF5] = "§", [0xF6] = "÷", [0xF7] = "¸",
    [0xF8] = "°", [0xF9] = "¨", [0xFA] = "·", [0xFB] = "¹",
    [0xFC] = "³", [0xFD] = "²", [0xFE] = "■", [0xFF] = "·"
}
for i = 0x21, 0x7E do
    cp437ToUtf8[i] = string.char(i) -- Skip control to printable ASCII
end


-- Writes a hex dump.
function utils.WriteHexDump(data, skipSize)
    Write('<pre>')
    if not skipSize then
        Write(#data .. ' bytes')
    end
    Write('<div>\n')
    for i = 1, #data, 32 do
        local chunk = data:sub(i, i + 31)
        local parts = {chunk:sub(1, 16), chunk:sub(17, 32)}

        local line_hex = {}
        local line_cp437 = {}

        for _, part in ipairs(parts) do
            local hex = {}
            local cp437 = {}

            for j = 1, #part do
                local byte = part:byte(j)
                table.insert(hex, string.format("%02X", byte))
                table.insert(cp437, cp437ToUtf8[byte] or ".")
            end
            
            table.insert(line_hex, table.concat(hex, " "))
            table.insert(line_cp437, table.concat(cp437))
        end

        local formatted_hex = string.format("%-48s  %-48s", line_hex[1] or "", line_hex[2] or "")
        local formatted_cp437 = string.format("%-16s  %-16s", line_cp437[1] or "", line_cp437[2] or "")
        if i == 1 and (#line_hex[1] + #line_hex[2]) < 94 then
            formatted_hex = (formatted_hex:gsub("^%s*(.-)%s*$", "%1")) .. '     '
        end

        Write(EscapeHtml(string.format("%s  %s\n", formatted_hex, formatted_cp437)))
    end
    Write('</div></pre>')
end


-- Writes common page header.
function utils.WritePageHeader(databaseName, isPagePage, pageNumber) 
    local heading = EscapeHtml(databaseName)
    local optionalHexCheckbox = ''
    local titlePrefix = 'Top'
    if isPagePage then
        heading = '<a href="/" title="Back to top">' .. heading .. '</a>'
        optionalHexCheckbox = [[
            <div class="checkbox-outer">
                <input type="checkbox" id="ShowHex" />
                <label for="ShowHex">Show Hexdumps</label>
            </div>
        ]]
        titlePrefix = 'Page ' .. pageNumber
    end
    Write([[
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <meta charset="utf-8" />
            <title>]] .. titlePrefix .. [[ - ]] .. databaseName .. [[ - SQLite Page Explorer</title>
            <link rel="stylesheet" href="]] .. utils.Static('css/reset.css') .. [[" />
            <link rel="stylesheet" href="]] .. utils.Static('css/screen.css') .. [[" />
        </head>
        <body>

            <div class="page-container">

                <div class="top-area">
                    <h1>]] .. heading .. [[</h1>
                    ]] .. optionalHexCheckbox .. [[
                    <a class="sqlite-link" href="https://sqlite.com/fileformat2.html" target="sqlite">Format Reference</a>
                </div>
    ]]) 
end


-- Writes common page footer.
function utils.WritePageFooter() 
    Write([[
            </div>

            <script>

                // On load...
                document.addEventListener('DOMContentLoaded', function() {
                    
                    // Wire up the "Show Hexdumps" checkbox to toggle .hex-visible on <body>, and save / load the preference to local storage
                    var showHex = document.getElementById('ShowHex');
                    if (showHex) {
                        function updateHexVisibility() {
                            var isShown = showHex.checked;
                            document.body.classList.toggle('hex-visible', isShown);
                            try { localStorage.setItem('showHex', isShown ? '1' : '0'); } catch(err) {}
                        }
                        showHex.addEventListener('input', function(e) {
                            e.preventDefault();
                            updateHexVisibility();
                        });
                        showHex.addEventListener('change', function(e) {
                            e.preventDefault();
                            updateHexVisibility();
                        });
                        try {
                            showHex.checked = localStorage.getItem('showHex') === '1';
                        } catch(err) {}
                        updateHexVisibility();
                    }
                    
                    // Hyperlink the page number on any records that look like sqlite_schema rows
                    document.querySelectorAll('table.record').forEach(function(table) {
                        const cells = table.rows[0].cells;
                        if (cells.length != 5) {
                            return;
                        }
                        const integer = parseInt(cells[3].textContent, 10);
                        const fifthCellText = cells[4].textContent.trim().toLowerCase();
                        if (!isNaN(integer) && fifthCellText.startsWith('create')) {
                            cells[3].innerHTML = `<a href="javascript:void(0);" onclick="loadPageDetails(${integer})">${integer}</a>`;
                        }
                    });
                });
            </script>

        </body>
        </html>
    ]]) 
end

return utils
