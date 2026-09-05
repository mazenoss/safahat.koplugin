--[[--
Safahat Library plugin for KOReader
====================================

Lets you browse (by category) and search the free Arabic e-book
catalog at https://www.safahat.org/ (published by the non-profit
Hindawi Foundation), view a book's page (title, author, categories,
word count, description) as a scrollable screen -- styled after the
book-detail screen in github.com/ZlibraryKO/zlibrary.koplugin -- and
download its EPUB straight onto your device.

NOTE: there is deliberately no cover-image display. The site serves
covers as SVG, and rendering an SVG through KOReader's built-in image
viewer crashed the app on a real test device. That crash happens
during KOReader's async paint pass rather than at widget construction
time, so it can't be caught with pcall the way network/parsing errors
elsewhere in this plugin are -- so the feature was removed rather than
shipped behind a safety net that couldn't actually catch it. The book
page (via TextViewer) only ever renders plain text, never images, to
stay clear of that failure mode entirely.

HOW IT WORKS / KNOWN LIMITATIONS
---------------------------------
safahat.org does not publish a documented public JSON API, so this
plugin works by downloading the site's HTML and pattern-matching it.
Two parts of that are now based on confirmed, real markup from the
live site:

  * the category sidebar shown on any /books/... listing page
    (parseCategories) — confirmed
  * a book's detail page, e.g. https://www.safahat.org/books/<id>/
    (parseBookDetail) — confirmed, including title, author,
    categories, word count, description, and the EPUB download link:
        <a ... href="https://downloads.hindawi.org/books/<id>.epub"
           ... id="epub">  * a category page's book grid (parseBookList), e.g.
        <li class="bookCover">
          <a href="/books/<id>/">
            <span class="button big">شاهد التفاصيل</span>
            <span class="link"></span>
            <img src="..." alt="كتاب بعنوان <title>">
          </a>
        </li>
    — confirmed. Note the same /books/<id>/ link can legitimately
    appear more than once on a listing page (e.g. also as a plain
    counter/badge with no title), so parseBookList merges every match
    for a given id rather than trusting only the first one it sees.

One more thing recently confirmed: the search box is a plain HTML
form, <form action="/layout/search/" method="post"><input
name="keyword">, so search now POSTs to that directly instead of
guessing a query-string URL. Its results page is assumed to reuse the
same book-grid markup as a category page -- if that assumption is
wrong, check debug/search_*.txt.

Also unconfirmed: pagination between pages within a category, if a
category has more books than fit on one page (findNextPageUrl).

Every page this plugin fetches is also saved as plain text under
KOReader's data directory, in safahat_debug/ (see getDebugDir()) —
kept separate from the download folder so debug files never clutter
wherever your books end up. This is the fastest way to compare what
the plugin actually received against the patterns below.
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local logger = require("logger")
local socketutil = require("socketutil")
local socket_url = require("socket.url")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen

local lfs
do
    local ok, mod = pcall(require, "libs/libkoreader-lfs")
    if not ok then
        ok, mod = pcall(require, "lfs")
    end
    if ok then lfs = mod end
end

local Safahat = WidgetContainer:extend{
    name = "safahat",
    is_doc_only = false,
}

-- ---------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------

local BASE_URL = "https://www.safahat.org"
local CATALOG_PATH = "/books/"
local USER_AGENT = "Mozilla/5.0 (compatible; KOReader Safahat plugin)"

-- ---------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------

local function absolutize(href)
    if not href then return nil end
    if href:match("^https?://") then
        return href
    end
    local ok, abs = pcall(socket_url.absolute, BASE_URL, href)
    if ok then return abs end
    return href
end

-- Default download folder is the Kindle's own "documents" folder, so
-- books downloaded here also show up in the stock Kindle library, not
-- just inside KOReader. Still user-configurable via the plugin menu.
local DEFAULT_DOWNLOAD_DIR = "/mnt/us/documents/"

local function getDownloadDir()
    local dir = G_reader_settings:readSetting("safahat_download_dir")
    if not dir then
        dir = DEFAULT_DOWNLOAD_DIR
        G_reader_settings:saveSetting("safahat_download_dir", dir)
    end
    if lfs and not lfs.attributes(dir, "mode") then
        util.makePath(dir)
    end
    return dir
end

-- Debug dumps deliberately live in KOReader's own data directory, not
-- inside the (user-facing, possibly Kindle-library) download folder,
-- so they never clutter the place downloaded books show up.
local function getDebugDir()
    local dir = DataStorage:getFullDataDir() .. "/safahat_debug/"
    if lfs and not lfs.attributes(dir, "mode") then
        util.makePath(dir)
    end
    return dir
end

-- Saves raw fetched HTML to <debug dir>/<name>.txt so it can be
-- inspected on-device or copied off the device, to fix parsing patterns
-- that don't match the live site. Best-effort; failures are silent.
local function dumpDebugHtml(name, content)
    local ok = pcall(function()
        local dir = getDebugDir()
        local f = io.open(dir .. name .. ".txt", "w")
        if f then
            f:write(content or "")
            f:close()
        end
    end)
    return ok
end

-- Lua 5.1/LuaJIT (what KOReader runs) uses the global `unpack`,
-- Lua 5.2+ moved it to `table.unpack`. Support either.
local unpack = table.unpack or unpack

-- Wraps a callback so a Lua runtime error becomes a readable dialog
-- (with the error logged) instead of KOReader's crash screen. Use this
-- around any callback that does real work (network + parsing).
local function safe(fn)
    return function(...)
        local args = { ... }
        local ok, err = xpcall(function()
            return fn(unpack(args))
        end, debug.traceback)
        if not ok then
            logger.warn("Safahat: error in callback:", err)
            UIManager:show(InfoMessage:new{
                text = T(_("Safahat ran into an error:\n%1\n\n(Also logged to crash.log)"), tostring(err)),
            })
        end
    end
end

-- ---------------------------------------------------------------------
-- Networking
-- ---------------------------------------------------------------------
--
-- KOReader's bundled LuaSocket/LuaSec does NOT support a "redirect = true"
-- request option (passing it just fails with "redirect not supported",
-- especially across http<->https). safahat.org appears to issue at
-- least one redirect (and possibly sets a cookie as part of that), so
-- we follow redirects ourselves, carrying cookies from Set-Cookie
-- along the way.

local MAX_REDIRECTS = 5

local COOKIE_ATTR_KEYS = {
    path = true, expires = true, domain = true, secure = true,
    httponly = true, samesite = true, ["max-age"] = true, version = true,
}

-- Very small cookie-jar helper: pulls "name=value" pairs out of a
-- Set-Cookie response header, ignoring known attribute keys (Path,
-- Expires, etc). Good enough to keep a locale/session cookie alive
-- across a redirect chain, not a full RFC 6265 implementation.
local function extractCookiePairs(set_cookie_header)
    if not set_cookie_header or set_cookie_header == "" then
        return nil
    end
    local pairs_found = {}
    for name, value in set_cookie_header:gmatch("([%w_%-]+)%s*=%s*([^;,]+)") do
        if not COOKIE_ATTR_KEYS[name:lower()] then
            pairs_found[name] = value
        end
    end
    local parts = {}
    for name, value in pairs(pairs_found) do
        table.insert(parts, name .. "=" .. value)
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "; ")
end

-- Core request loop: GETs `url`, following redirects (301/302/303/307/308)
-- up to MAX_REDIRECTS times, forwarding cookies as it goes. `sink_provider`
-- is called before *each* attempt (including redirect hops, whose bodies
-- are usually empty/irrelevant) and must return a fresh ltn12 sink to
-- receive that attempt's response body. Returns (true, nil, final_url)
-- on success, or (nil, err) on failure.
local function fetchFollowingRedirects(url, sink_provider, extra_headers)
    local cookie_jar
    local current_url = url
    for _ = 1, MAX_REDIRECTS do
        local ok_sink, sink = pcall(sink_provider)
        if not ok_sink then
            return nil, "local error: " .. tostring(sink)
        end
        local headers = {
            ["User-Agent"] = USER_AGENT,
            ["Accept-Language"] = "ar,en;q=0.8",
        }
        if extra_headers then
            for k, v in pairs(extra_headers) do headers[k] = v end
        end
        if cookie_jar then headers["Cookie"] = cookie_jar end

        local request = {
            url = current_url,
            method = "GET",
            sink = sink,
            headers = headers,
        }
        local requester = current_url:match("^https") and https.request or http.request
        local ok, code, resp_headers = requester(request)
        resp_headers = resp_headers or {}

        local new_cookies = extractCookiePairs(resp_headers["set-cookie"])
        if new_cookies then
            cookie_jar = cookie_jar and (cookie_jar .. "; " .. new_cookies) or new_cookies
        end

        if not ok then
            logger.warn("Safahat: request failed", current_url, code)
            return nil, tostring(code)
        end

        if type(code) == "number" and (code == 301 or code == 302 or code == 303
                or code == 307 or code == 308) then
            local location = resp_headers["location"]
            if not location or location == "" then
                return nil, "redirect with no Location header"
            end
            current_url = absolutize(location)
        elseif type(code) == "number" and code >= 200 and code < 300 then
            return true, nil, current_url
        else
            logger.warn("Safahat: bad status", current_url, code)
            return nil, "HTTP " .. tostring(code)
        end
    end
    return nil, "too many redirects"
end

-- GET a page of HTML/text. Returns (body, nil) or (nil, err).
local function httpGet(url)
    local body_table
    socketutil:set_timeout(15, 60)
    local ok, err = fetchFollowingRedirects(url, function()
        body_table = {}
        return ltn12.sink.table(body_table)
    end)
    socketutil:reset_timeout()
    if not ok then
        return nil, err
    end
    return table.concat(body_table), nil
end

-- Download a URL straight to disk. Returns (true) or (false, err).
local function httpDownload(url, path)
    socketutil:set_timeout(20, 1800)
    local ok, err = fetchFollowingRedirects(url, function()
        local out = io.open(path, "wb")
        if not out then
            error("could not open destination file")
        end
        return ltn12.sink.file(out)
    end)
    socketutil:reset_timeout()
    if not ok then
        return false, err
    end
    return true, nil
end

local function urlEncodeForm(fields)
    local parts = {}
    for k, v in pairs(fields) do
        table.insert(parts, socket_url.escape(tostring(k)) .. "=" .. socket_url.escape(tostring(v)))
    end
    return table.concat(parts, "&")
end

-- POSTs a application/x-www-form-urlencoded form to `url` (confirmed:
-- safahat.org's search box is <form action="/layout/search/"
-- method="post"><input name="keyword">). If the response is itself a
-- redirect (common after a form submit), follows it with a plain GET.
-- Returns (body, nil) or (nil, err).
local function httpPost(url, fields)
    local body = urlEncodeForm(fields)
    local response_table = {}
    socketutil:set_timeout(15, 60)
    local request = {
        url = url,
        method = "POST",
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response_table),
        headers = {
            ["User-Agent"] = USER_AGENT,
            ["Accept-Language"] = "ar,en;q=0.8",
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Content-Length"] = tostring(#body),
        },
    }
    local requester = url:match("^https") and https.request or http.request
    local ok, code, resp_headers = requester(request)
    socketutil:reset_timeout()
    resp_headers = resp_headers or {}

    if not ok then
        logger.warn("Safahat: POST failed", url, code)
        return nil, tostring(code)
    end

    if type(code) == "number" and (code == 301 or code == 302 or code == 303
            or code == 307 or code == 308) then
        local location = resp_headers["location"]
        if not location or location == "" then
            return nil, "redirect with no Location header"
        end
        return httpGet(absolutize(location))
    end

    if type(code) == "number" and code >= 200 and code < 300 then
        return table.concat(response_table), nil
    end

    logger.warn("Safahat: POST bad status", url, code)
    return nil, "HTTP " .. tostring(code)
end

-- ---------------------------------------------------------------------
-- HTML parsing (the part most likely to need adjusting, see header)
-- ---------------------------------------------------------------------

-- Strips HTML tags and collapses whitespace, for pulling a plausible
-- title out of an anchor's own text content as a last resort.
local function stripTags(s)
    if not s then return "" end
    s = s:gsub("<[^>]+>", " ")
    s = s:gsub("&nbsp;", " ")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- Like stripTags, but keeps paragraph breaks -- used for the book
-- description, where multiple <p> paragraphs should stay visually
-- separated rather than being collapsed into one line.
local function stripTagsKeepParagraphs(s)
    if not s then return "" end
    s = s:gsub("</p>", "</p>\n\n")
    s = s:gsub("<br%s*/?>", "\n")
    s = s:gsub("<[^>]+>", " ")
    s = s:gsub("&nbsp;", " ")
    s = s:gsub("[ \t]+", " ")
    s = s:gsub(" *\n *", "\n")
    s = s:gsub("\n\n\n+", "\n\n")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- Tries several strategies to pull a title out of the HTML block
-- belonging to one book (the block from just after its /books/<id>/
-- link's opening tag up to its closing </a>). Returns "" if nothing
-- plausible was found.
local function guessTitleFromBlock(inner)
    -- 1) an <img alt="..."> containing the site's known prefix
    local alt = inner:match('alt="([^"]*)"')
    if alt then
        local title = alt:gsub("^%s*كتاب بعنوان%s*", "")
        title = title:gsub("^%s+", ""):gsub("%s+$", "")
        if title ~= "" then return title end
    end
    -- 2) a title="..." attribute anywhere in the block
    local title_attr = inner:match('title="([^"]+)"')
    if title_attr and title_attr ~= "" then
        return title_attr
    end
    -- 3) common heading/class wrappers used for card titles
    for _, pat in ipairs({
        '<h%d[^>]*>(.-)</h%d>',
        'class="[^"]-title[^"]-"[^>]*>(.-)<',
        'class="[^"]-book%-name[^"]-"[^>]*>(.-)<',
    }) do
        local m = inner:match(pat)
        if m then
            local t = stripTags(m)
            if t ~= "" then return t end
        end
    end
    -- 4) fall back to whatever text is directly inside the block, but
    -- only if it's not just digits (a view-count/word-count badge
    -- sharing the same book link would otherwise look like a title)
    local t = stripTags(inner)
    if t ~= "" and #t < 200 and t:match("%D") then
        return t
    end
    return ""
end

-- Parses the category sidebar (present on any /books/... listing page)
-- into { name, count, url } entries, including the "all books" link.
-- Quote-agnostic: the site inconsistently uses '...' or "..." for the
-- same kind of attribute depending on the page, so every pattern here
-- matches either via a back-reference (['"])...%1.
local function parseCategories(html)
    local cats, seen = {}, {}
    for _, href, inner in html:gmatch("<a href=(['\"])(/books/[^'\"]-)%1[^>]*>(.-)</a>") do
        if not seen[href] and (href == "/books/" or href:match("^/books/categories/")) then
            seen[href] = true
            local name = inner:match("^(.-)<span") or inner
            name = stripTags(name)
            local count = inner:match('aria%-label="[^"]-(%d+)"')
            if name ~= "" then
                table.insert(cats, { name = name, count = count, url = absolutize(href) })
            end
        end
    end
    return cats
end

-- Parses a catalog/listing page into a list of
-- { id, title, cover, url } book entries.
--
-- A book's id (from its /books/<id>/ link) can legitimately appear
-- more than once on a listing page -- e.g. a card's cover/title block
-- (<li class="bookCover"><a href="/books/<id>/"><img alt="كتاب بعنوان
-- ...">) plus, elsewhere, a plain counter/badge reusing the same link
-- with no title in it. Taking only the *first* match risks picking
-- the badge instead of the real title, so instead every match for a
-- given id is merged, keeping the best title/cover seen for it.
--
-- Also quote-agnostic (see parseCategories above) -- confirmed the
-- live site renders the same link as href='/books/<id>/' on some
-- pages and href="/books/<id>/" on others.
local function parseBookList(html)
    local by_id, order = {}, {}
    for id, quote, inner in html:gmatch("/books/(%d+)/(['\"])[^>]*>(.-</a>)") do
        local entry = by_id[id]
        if not entry then
            entry = { id = id, title = "", cover = nil, url = BASE_URL .. "/books/" .. id .. "/" }
            by_id[id] = entry
            table.insert(order, id)
        end

        local title = guessTitleFromBlock(inner)
        if title ~= "" and entry.title == "" then
            entry.title = title
        end

        if not entry.cover then
            local cover = inner:match('src="([^"]+)"')
            if cover then entry.cover = absolutize(cover) end
        end
    end

    local books = {}
    for _, id in ipairs(order) do
        local entry = by_id[id]
        if entry.title == "" then
            entry.title = _("Untitled") .. " (" .. id .. ")"
        end
        table.insert(books, entry)
    end
    return books
end

-- Parses a single book's detail page (e.g. https://www.safahat.org/books/<id>/)
-- into { title, author, cover, categories, word_count, description,
-- epub_url }. Based on confirmed markup:
--   <article class="book">
--     <div class="cover"><img src="..."></div>
--     <div class="details">
--       <h2>Title</h2>
--       <div class="author"><a href="...">Author</a></div>
--       <ul class="tags">
--         <li><a href="/books/categories/<slug>/">Category</a></li>
--         <li><span>NNN كلمة</span></li>   -- word count, no link
--       </ul>
--       <div class="content">
--         <div><p>...paragraph...</p><p>...paragraph...</p></div>
--         <br>
--         <div>legal/licensing note</div>
--       </div>
--   ...
--   <div class="downloadBook">
--     <a ... href="https://downloads.hindawi.org/books/<id>.epub" ... id="epub">
--
-- `fallback` (optional) supplies title/cover already known from the
-- listing page, used only if this page's own markup doesn't match.
local function parseBookDetail(html, fallback)
    fallback = fallback or {}

    local title = html:match('<div class="details">.-<h2>%s*(.-)%s*</h2>')
    title = title and stripTags(title) or nil
    if not title or title == "" then
        title = fallback.title
    end

    local cover = html:match('<div class="cover">.-<img src="([^"]+)"')
    cover = absolutize(cover) or fallback.cover

    local author = html:match('<div class="author">.-<a[^>]*>%s*(.-)%s*</a>')
    author = author and stripTags(author) or nil
    if author == "" then author = nil end

    -- Category tags + word count both live in <ul class="tags">; the
    -- word count is the one <li> with a bare <span> (no <a>).
    local categories = {}
    local word_count
    local tags_block = html:match('<ul class="tags">(.-)</ul>')
    if tags_block then
        for cat in tags_block:gmatch('<a[^>]*>(.-)</a>') do
            local c = stripTags(cat)
            if c ~= "" then table.insert(categories, c) end
        end
        word_count = tags_block:match('<span>%s*(.-)%s*</span>')
        if word_count then word_count = stripTags(word_count) end
        if word_count == "" then word_count = nil end
    end

    -- Description + legal note: everything in <div class="content">
    -- up to the following <div class="shareActions">, paragraph breaks
    -- preserved.
    local description
    local content_block = html:match('<div class="content">(.-)<div class="shareActions">')
    if content_block then
        description = stripTagsKeepParagraphs(content_block)
        if description == "" then description = nil end
    end

    -- The EPUB link specifically (id="epub" in the confirmed markup);
    -- matching on the ".epub" extension directly is simpler and just
    -- as reliable, and doesn't depend on attribute order.
    local epub_url = html:match('href="([^"]-%.epub)"')

    return {
        title = (title and title ~= "") and title or _("Untitled"),
        author = author,
        cover = cover,
        categories = categories,
        word_count = word_count,
        description = description,
        epub_url = epub_url,
    }
end

-- Looks for a "next page" link in a catalog page.
local function findNextPageUrl(html)
    local href = html:match('rel="next"[^>]-href="([^"]+)"')
        or html:match('href="([^"]+)"[^>]-rel="next"')
        or html:match('href="([^"]+)"[^>]*>%s*التالي')
        or html:match('href="([^"]+)"[^>]*>%s*&raquo;')
        or html:match('href="([^"]+)"[^>]*>%s*»')
    return absolutize(href)
end

-- ---------------------------------------------------------------------
-- Downloading + opening books
-- ---------------------------------------------------------------------

local function fixExtensionByMagic(path, dir, safe_title)
    local f = io.open(path, "rb")
    if not f then return nil end
    local head = f:read(8) or ""
    f:close()
    local new_ext
    if head:sub(1, 4) == "%PDF" then
        new_ext = "pdf"
    elseif head:sub(1, 2) == "PK" then
        new_ext = "epub" -- epub files are zip archives; best guess
    end
    if not new_ext then return nil end
    local new_path = dir .. safe_title .. "." .. new_ext
    if new_path ~= path then
        os.rename(path, new_path)
        return new_path
    end
    return path
end

function Safahat:openDownloadedFile(path)
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance then
        ReaderUI.instance:switchDocument(path)
    else
        ReaderUI:showReader(path)
    end
end

function Safahat:doDownload(book, link)
    local dir = getDownloadDir()
    local ext = (link.format ~= "unknown") and link.format or "pdf"
    local safe_title = book.title:gsub('[/\\:%*%?"<>|]', "_")
    local filename = safe_title .. "." .. ext
    local path = dir .. filename

    local msg = InfoMessage:new{ text = _("Downloading…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local ok, err = httpDownload(link.url, path)
    UIManager:close(msg)

    if not ok then
        os.remove(path)
        UIManager:show(InfoMessage:new{ text = T(_("Download failed:\n%1"), err) })
        return
    end

    if link.format == "unknown" then
        local fixed = fixExtensionByMagic(path, dir, safe_title)
        if fixed then path = fixed end
    end

    UIManager:show(ConfirmBox:new{
        text = T(_("Downloaded:\n%1\n\nOpen it now?"), path),
        ok_text = _("Open"),
        cancel_text = _("Later"),
        ok_callback = function()
            self:openDownloadedFile(path)
        end,
    })
end

function Safahat:confirmDownload(detail)
    UIManager:show(ConfirmBox:new{
        text = T(_("Download \"%1\" as EPUB?"), detail.title),
        ok_text = _("Download"),
        ok_callback = function()
            self:doDownload({ title = detail.title }, { url = detail.epub_url, format = "epub" })
        end,
    })
end

-- Shows a book's full info (title/author/categories/word count/
-- description) as a scrollable "book page", with a Download EPUB
-- action button alongside the built-in close button.
--
-- Uses KOReader's built-in TextViewer widget rather than a hand-built
-- layout -- it's the same widget KOReader's own OPDS catalog browser
-- uses to show a book's description, it's RTL-aware (important for
-- Arabic), and it handles long/short text and scrolling on its own.
-- This deliberately still doesn't render the cover image: the site's
-- covers are SVG, and rendering one through KOReader's image viewer
-- crashed on a real device/build during testing -- and since that
-- crash happens during the async paint pass rather than at widget
-- construction time, it can't be caught with pcall from here, so the
-- feature stays out rather than risk shipping something that can
-- crash the app. TextViewer here only ever renders plain text.
function Safahat:presentBookDetail(detail)
    local lines = {}
    if detail.author then
        table.insert(lines, detail.author)
    end
    local meta = {}
    if detail.categories and #detail.categories > 0 then
        table.insert(meta, table.concat(detail.categories, " · "))
    end
    if detail.word_count then
        table.insert(meta, detail.word_count)
    end
    if #meta > 0 then
        table.insert(lines, table.concat(meta, "  —  "))
    end
    if #lines > 0 then
        table.insert(lines, "") -- blank line before the description
    end
    if detail.description then
        table.insert(lines, detail.description)
    end

    local ok, viewer_or_err = pcall(function()
        local TextViewer = require("ui/widget/textviewer")
        return TextViewer:new{
            title = detail.title,
            text = table.concat(lines, "\n"),
            para_direction_rtl = true,
            auto_para_direction = true,
            buttons_table = {
                {
                    {
                        text = _("Download EPUB"),
                        callback = safe(function()
                            self:confirmDownload(detail)
                        end),
                    },
                },
            },
        }
    end)

    if ok and viewer_or_err then
        UIManager:show(viewer_or_err)
    else
        -- Fall back to the simple dialog if TextViewer isn't available
        -- or fails to build, so a book can always still be downloaded.
        logger.warn("Safahat: TextViewer failed, falling back:", viewer_or_err)
        self:presentBookDetailFallback(detail)
    end
end

-- Minimal fallback for presentBookDetail, used only if TextViewer
-- fails to construct. Same proven ButtonDialog approach used before.
function Safahat:presentBookDetailFallback(detail)
    local title_lines = { detail.title }
    if detail.author then
        table.insert(title_lines, detail.author)
    end

    local dialog
    local buttons = {
        {
            {
                text = _("Download EPUB"),
                callback = safe(function()
                    UIManager:close(dialog)
                    self:confirmDownload(detail)
                end),
            },
        },
        {
            {
                text = _("‹ Back"),
                callback = function() UIManager:close(dialog) end,
            },
        },
    }

    dialog = ButtonDialog:new{
        title = table.concat(title_lines, "\n"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Safahat:showBookDetail(book)
    local msg = InfoMessage:new{ text = _("Loading book page…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local html, err = httpGet(book.url)
    UIManager:close(msg)

    if not html then
        UIManager:show(InfoMessage:new{ text = T(_("Could not load book page:\n%1"), err) })
        return
    end
    dumpDebugHtml("book_" .. tostring(book.id), html)

    local detail = parseBookDetail(html, book)
    detail.id = book.id

    if not detail.epub_url then
        UIManager:show(InfoMessage:new{
            text = _("No EPUB download was found for this book. It may only be offered in other formats, or the plugin's parser may need updating."),
        })
        return
    end

    self:presentBookDetail(detail)
end

-- ---------------------------------------------------------------------
-- Browsing / searching the catalog
-- ---------------------------------------------------------------------

function Safahat:browseCategories()
    local msg = InfoMessage:new{ text = _("Loading…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local html, err = httpGet(BASE_URL .. CATALOG_PATH)
    UIManager:close(msg)

    if not html then
        UIManager:show(InfoMessage:new{ text = T(_("Could not load page:\n%1"), err) })
        return
    end
    dumpDebugHtml("categories_" .. tostring(os.time()), html)

    local cats = parseCategories(html)
    if #cats == 0 then
        -- Couldn't find the category sidebar; fall back to the flat
        -- book listing rather than leaving the user stuck.
        self:browse(BASE_URL .. CATALOG_PATH)
        return
    end

    local item_table = {}
    local menu
    table.insert(item_table, {
        text = _("‹ Back"),
        callback = function() UIManager:close(menu) end,
    })
    for _, cat in ipairs(cats) do
        local label = cat.name
        if cat.count then
            label = label .. "  (" .. cat.count .. ")"
        end
        table.insert(item_table, {
            text = label,
            callback = safe(function()
                self:browse(cat.url)
            end),
        })
    end

    menu = Menu:new{
        title = _("Safahat — التصنيفات"),
        item_table = item_table,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        close_callback = function()
            UIManager:close(menu)
        end,
    }
    UIManager:show(menu)
end

-- Renders a parsed listing page (from either browsing a category/page
-- or a search) as a scrollable Menu. Shared by browse() and doSearch()
-- so both go through identical, already-tested list/pagination logic.
function Safahat:renderBookListPage(html, title)
    local books = parseBookList(html)
    local next_url = findNextPageUrl(html)

    if #books == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No books found on this page. The site's layout may differ from what this plugin expects; see the notes at the top of main.lua."),
        })
        return
    end

    local item_table = {}
    local menu
    table.insert(item_table, {
        text = _("‹ Back"),
        callback = function() UIManager:close(menu) end,
    })
    for _, book in ipairs(books) do
        table.insert(item_table, {
            text = book.title,
            callback = safe(function()
                self:showBookDetail(book)
            end),
        })
    end
    if next_url then
        table.insert(item_table, {
            text = _("Next page »"),
            callback = safe(function()
                self:browse(next_url)
            end),
        })
    end

    menu = Menu:new{
        title = title or _("Safahat"),
        item_table = item_table,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        close_callback = function()
            UIManager:close(menu)
        end,
    }
    UIManager:show(menu)
end

function Safahat:browse(url)
    local msg = InfoMessage:new{ text = _("Loading…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local html, err = httpGet(url)
    UIManager:close(msg)

    if not html then
        UIManager:show(InfoMessage:new{ text = T(_("Could not load page:\n%1"), err) })
        return
    end
    dumpDebugHtml("catalog_" .. tostring(os.time()), html)

    self:renderBookListPage(html, _("Safahat"))
end

-- Search: confirmed the site's search box is a plain HTML form,
-- <form action="/layout/search/" method="post"><input name="keyword">,
-- so this POSTs to it directly rather than guessing a query string.
-- The results page is assumed to reuse the same book-grid markup as a
-- category page (parseBookList); if the response looks different,
-- check debug/search_*.txt.
function Safahat:doSearch(keyword)
    local msg = InfoMessage:new{ text = _("Searching…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local html, err = httpPost(BASE_URL .. "/layout/search/", { keyword = keyword })
    UIManager:close(msg)

    if not html then
        UIManager:show(InfoMessage:new{ text = T(_("Search failed:\n%1"), err) })
        return
    end
    dumpDebugHtml("search_" .. tostring(os.time()), html)

    self:renderBookListPage(html, T(_("Search: %1"), keyword))
end

function Safahat:promptSearch()
    local dialog
    dialog = InputDialog:new{
        title = _("Search Safahat"),
        input_hint = _("Title or keyword…"),
        buttons = {
            {
                {
                    text = _("‹ Back"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = safe(function()
                        local q = dialog:getInputText()
                        UIManager:close(dialog)
                        if q and q ~= "" then
                            self:doSearch(q)
                        end
                    end),
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Safahat:promptDownloadDir()
    local dialog
    dialog = InputDialog:new{
        title = _("Download folder"),
        input = getDownloadDir(),
        buttons = {
            {
                {
                    text = _("‹ Back"),
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local new_dir = dialog:getInputText()
                        UIManager:close(dialog)
                        if new_dir and new_dir ~= "" then
                            if new_dir:sub(-1) ~= "/" then new_dir = new_dir .. "/" end
                            G_reader_settings:saveSetting("safahat_download_dir", new_dir)
                            if lfs and not lfs.attributes(new_dir, "mode") then
                                util.makePath(new_dir)
                            end
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Safahat:openHome()
    local dialog
    dialog = ButtonDialog:new{
        title = _("Safahat Library (صفحات)"),
        buttons = {
            {
                {
                    text = _("Browse catalog"),
                    callback = safe(function()
                        self:browseCategories()
                    end),
                },
            },
            {
                {
                    text = _("Search"),
                    callback = safe(function()
                        self:promptSearch()
                    end),
                },
            },
            {
                {
                    text = _("Download folder…"),
                    callback = function()
                        self:promptDownloadDir()
                    end,
                },
            },
            {
                {
                    text = _("‹ Back"),
                    callback = function() UIManager:close(dialog) end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- ---------------------------------------------------------------------
-- Plugin registration
-- ---------------------------------------------------------------------

function Safahat:init()
    self.ui.menu:registerToMainMenu(self)
end

function Safahat:addToMainMenu(menu_items)
    menu_items.safahat_library = {
        text = _("Safahat Library"),
        sorting_hint = "search",
        callback = function()
            self:openHome()
        end,
    }
end

return Safahat
