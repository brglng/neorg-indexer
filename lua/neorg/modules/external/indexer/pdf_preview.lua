--- Image previews of PDFs: the first page is rasterized with ImageMagick into a cached PNG, which
--- image.nvim draws in the preview window.
local M = {}

M.default_density = 110
--- Conversions taking longer than this (in milliseconds) are killed and fall back to text.
M.timeout = 30000

--- Pending conversions: PNG path -> callbacks waiting for it.
local pending = {}
local converter
local warned = false
--- Set when image.nvim cannot draw images, for example because it is not set up.
local disabled = false

--- Preview options from `search.pdf_preview`.
--- @param value any `true`, `false`, or a table `{ enabled = boolean, density = number }`
--- @return table|nil options `{ density = number }`, or nil when previews are disabled
function M.options(value)
    if value == false or (type(value) == "table" and value.enabled == false) then
        return nil
    end
    local density = type(value) == "table" and tonumber(value.density) or nil
    return { density = density and density > 0 and density or M.default_density }
end

--- Directory of the cached PNGs.
function M.cache_dir()
    return vim.fn.stdpath("cache") .. "/neorg-indexer/pdf-preview"
end

--- Cached PNG of the first page of a PDF, keyed by its absolute path, modification time, size,
--- and the rasterization density.
--- @param pdf string absolute path of the PDF
--- @param stat table `vim.uv.fs_stat` result of the PDF
--- @param density number
--- @return string path
function M.cache_path(pdf, stat, density)
    local key = table.concat({ pdf, stat.mtime.sec, stat.mtime.nsec, stat.size, density }, "\n")
    return M.cache_dir() .. "/" .. vim.fn.sha256(key) .. ".png"
end

--- The ImageMagick command (`magick`, or `convert` of ImageMagick 6), or nil when missing.
function M.converter()
    if converter == nil then
        converter = false
        for _, name in ipairs({ "magick", "convert" }) do
            -- Windows has an unrelated convert.exe.
            if vim.fn.executable(name) == 1 and (name == "magick" or vim.fn.has("win32") == 0) then
                converter = name
                break
            end
        end
    end
    return converter or nil
end

--- Command that renders the first page of a PDF on a white background into a PNG.
--- @param command string ImageMagick command
--- @param pdf string
--- @param png string output path
--- @param density number
--- @return string[]
function M.command(command, pdf, png, density)
    return {
        command,
        "-density",
        tostring(density),
        pdf .. "[0]",
        "-background",
        "white",
        "-alpha",
        "remove",
        "png:" .. png,
    }
end

--- The image.nvim module when PDF previews can be drawn: image.nvim and ImageMagick are installed.
--- @return table|nil
function M.available()
    if disabled or not M.converter() then
        return nil
    end
    local ok, image = pcall(require, "image")
    if ok and type(image) == "table" and type(image.from_file) == "function" then
        return image
    end
end

--- Report the first preview failure of the session.
--- @param err any
function M.warn(err)
    if not warned then
        warned = true
        vim.notify("Neorg indexer: cannot preview PDF, showing text instead: " .. tostring(err), vim.log.levels.WARN)
    end
end

--- Rasterize the first page of a PDF asynchronously, reusing the cache.
--- @param pdf string absolute path of the PDF
--- @param options table see `M.options`
--- @param callback fun(png: string|nil, err: string|nil) called on the main loop, never synchronously
function M.rasterize(pdf, options, callback)
    local function reply(png, err)
        vim.schedule(function()
            callback(png, err)
        end)
    end
    local command = M.converter()
    local stat = vim.uv.fs_stat(pdf)
    if not command then
        return reply(nil, "ImageMagick is not installed")
    elseif not stat then
        return reply(nil, "cannot read " .. pdf)
    end
    local png = M.cache_path(pdf, stat, options.density)
    local cached = vim.uv.fs_stat(png)
    if cached and cached.size > 0 then
        return reply(png)
    elseif pending[png] then
        table.insert(pending[png], callback)
        return
    end
    pending[png] = { callback }
    local function finish(err)
        local callbacks = pending[png]
        pending[png] = nil
        for _, waiting in ipairs(callbacks) do
            waiting(not err and png or nil, err)
        end
    end
    vim.fn.mkdir(M.cache_dir(), "p")
    -- Write to a temporary file so a failed or interrupted conversion never leaves a
    -- partial PNG in the cache; failures are not remembered, so the next preview retries.
    local tmp = png .. "." .. vim.uv.os_getpid() .. ".tmp"
    local ok, err = pcall(
        vim.system,
        M.command(command, pdf, tmp, options.density),
        { text = true, timeout = M.timeout },
        function(result)
            vim.schedule(function()
                local written = result.code == 0 and vim.uv.fs_stat(tmp)
                local renamed = written and written.size > 0 and os.rename(tmp, png)
                if renamed then
                    finish(nil)
                else
                    os.remove(tmp)
                    os.remove(png)
                    local message = vim.trim(result.stderr or "")
                    finish(message ~= "" and message or ("ImageMagick exited with code " .. result.code))
                end
            end)
        end
    )
    if not ok then
        vim.schedule(function()
            finish(tostring(err))
        end)
    end
end

--- Draw a PNG with image.nvim, fitted into a window showing a buffer.
--- @param image table image.nvim module
--- @param png string
--- @param win integer
--- @param buf integer
--- @return table|nil image, string|nil err
function M.show(image, png, win, buf)
    local ok, img = pcall(image.from_file, png, {
        window = win,
        buffer = buf,
        x = 0,
        y = 0,
        width = vim.api.nvim_win_get_width(win),
        height = vim.api.nvim_win_get_height(win),
    })
    if not ok then
        -- image.nvim throws when it is not set up; do not retry in this session.
        disabled = true
        return nil, tostring(img)
    elseif not img then
        -- Do not keep a PNG that image.nvim cannot read in the cache.
        os.remove(png)
        return nil, "image.nvim cannot read " .. png
    end
    local rendered, err = pcall(img.render, img)
    if not rendered then
        pcall(img.clear, img)
        os.remove(png)
        return nil, tostring(err)
    end
    return img
end

--- Reset the session state, for tests.
function M.reset()
    pending, converter, warned, disabled = {}, nil, false, false
end

return M
