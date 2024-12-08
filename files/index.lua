-- /: view of all database pages

local utils = require('utils')


-- Load DB
local dbFile, basics = utils.OpenDbAndGetBasics(dbFile)


-- Write page top
utils.WritePageHeader(basics.Name, false, nil)
Write('<div class="big">')
utils.WritePrintouts('Page Size', basics.PageSize, 'Page Count', basics.PageCount)
Write('</div>')
Write([[
    <div class="page-map">
]])

    -- For each page...
    for pageNumber = 1, basics.PageCount do

        -- Seek to it, get page type
        utils.SeekToPage(dbFile, basics, pageNumber)
        local pageType = string.unpack("B", unix.read(dbFile, 1))
        local isBTree = (pageType == 0x02 or pageType == 0x05 or pageType == 0x0a or pageType == 0x0d)
        local isTable = (pageType == 0x05 or pageType == 0x0d)
        local isLeaf = (pageType == 0x0a or pageType == 0x0d)
        local cssClass = ''
        local label = 'other (overflow / freelist / ptrmap)'
        if isBTree then
            cssClass = utils.Iif(isTable, 'table ', 'index ') .. utils.Iif(isLeaf, 'leaf', 'interior')
            label = cssClass
        end
        
        -- Write a page link
        Write([[
            <a href="/page.lua?p=]] .. pageNumber .. [[" title="Page ]] .. pageNumber .. [[: ]] .. label .. [[" class="]] .. cssClass .. [[">]] .. pageNumber .. [[</a>
        ]])

    end  -- next page
    
-- Write page bottom
Write([[
    </div>
]])
utils.WritePageFooter()

-- Clean up
unix.close(dbFile)