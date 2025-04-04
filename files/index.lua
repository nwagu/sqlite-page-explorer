-- /: view of all database pages and details of a selected page

local utils = require('utils')

-- Load DB
local dbFile, basics = utils.OpenDbAndGetBasics(dbFile)

-- Write page top
utils.WritePageHeader(basics.Name, false, nil)

-- Add split-screen container
Write([[
    <div style="display: flex; height: 100vh;">
        <!-- Left side: Page list -->
        <div style="width: 50%; overflow-y: auto; border-right: 1px solid #ccc;">
            <div class="big">
]])
utils.WritePrintouts('Page Size', basics.PageSize, 'Page Count', basics.PageCount)
Write([[
            </div>
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

    -- Write a page link with JavaScript to load details
    Write([[
        <a href="javascript:void(0);" onclick="loadPageDetails(]] .. pageNumber .. [[)" title="Page ]] .. pageNumber .. [[: ]] .. label .. [[" class="]] .. cssClass .. [[">]] .. pageNumber .. [[</a>
    ]])
end

Write([[
            </div>
        </div>

        <!-- Right side: Page details -->
        <div id="page-details" style="width: 50%; overflow-y: auto; padding: 10px;">
            <h2>Select a page to view details</h2>
        </div>
    </div>
]])

-- Write page bottom
utils.WritePageFooter()

-- Clean up
unix.close(dbFile)

-- Add JavaScript for dynamic page loading
Write([[
    <script>
        function loadPageDetails(pageNumber) {
            fetch('/page.lua?p=' + pageNumber)
                .then(response => response.text())
                .then(html => {
                    document.getElementById('page-details').innerHTML = html;
                })
                .catch(error => {
                    console.error('Error loading page details:', error);
                    document.getElementById('page-details').innerHTML = '<p>Error loading page details.</p>';
                });
        }
    </script>
]])