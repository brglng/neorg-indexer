--- Progress notification for index generation: one notification, animated by replacing it.
---
--- Updates go through `vim.notify` with a stable `id` and `replace` set to the record returned by
--- the previous call (nvim-notify, snacks.nvim and noice.nvim replace the notification). When
--- `vim.notify` returns no record, updates fall back to Neovim's native progress messages
--- (`nvim_echo` with `kind = "progress"`).
local utils = require("neorg.core").utils

local M = {}

M.spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
M.bar_width = 10
-- Renders are throttled to about 10 per second.
M.interval_ms = 100
-- Display time of the final message that replaces the bar.
M.final_timeout_ms = 3000

local Progress = {}
Progress.__index = Progress

--- Create a progress notification. Nothing is shown until `start` and the delay elapsed.
--- @param opts { id: string, enabled: boolean, delay_ms: integer }
--- @return table
function M.new(opts)
    return setmetatable({
        id = opts.id,
        enabled = opts.enabled,
        delay_ms = math.max(0, tonumber(opts.delay_ms) or 0),
        done = 0,
        total = 0,
        -- Provisional count for work whose size is not known yet (files to write).
        estimate = 0,
        percent = 0,
        frame = 0,
        shown = false,
        finished = false,
    }, Progress)
end

--- Start the render timer: the bar first appears after the delay.
function Progress:start()
    if not self.enabled or self.timer then
        return
    end
    local timer = vim.uv.new_timer()
    if not timer then
        return
    end
    self.timer = timer
    timer:start(
        self.delay_ms,
        M.interval_ms,
        vim.schedule_wrap(function()
            if self.finished or self.broken then
                return
            end
            -- A failing notifier stops the animation; the final message is still attempted.
            if not pcall(self.render, self) then
                self.broken = true
                self:stop_timer()
            end
        end)
    )
end

function Progress:stop_timer()
    local timer = self.timer
    if timer then
        self.timer = nil
        timer:stop()
        if not timer:is_closing() then
            timer:close()
        end
    end
end

--- @param n integer
function Progress:add_total(n)
    self.total = self.total + n
end

--- Count `n` provisional items until the real count is added with `settle`. Without it, the bar
--- would reach 100% after reading and stay there while files are written.
--- @param n integer
function Progress:expect(n)
    self.estimate = n
end

--- Replace the provisional count with the real one.
--- @param n integer
function Progress:settle(n)
    self.estimate = 0
    self:add_total(n)
end

--- @param n integer|nil defaults to 1
function Progress:advance(n)
    self.done = self.done + (n or 1)
end

--- Restart counting from zero in the same notification, for a follow-up run.
function Progress:reset()
    self.done = 0
    self.total = 0
    self.estimate = 0
    self.percent = 0
end

--- Percentage of the work done, never lower than a previously rendered one.
--- @return integer percent
--- @return integer done
function Progress:measure()
    local total = self.total + self.estimate
    local done = math.min(self.done, total)
    local percent = total > 0 and math.floor(done * 100 / total) or 0
    self.percent = math.max(self.percent, percent)
    return self.percent, done, total
end

function Progress:render()
    self.frame = self.frame % #M.spinner + 1
    local percent, done, total = self:measure()
    local filled = math.floor(percent * M.bar_width / 100)
    local message = string.format(
        "%s Indexing notes ▕%s%s▏ %d%% (%d/%d)",
        M.spinner[self.frame],
        string.rep("█", filled),
        string.rep("░", M.bar_width - filled),
        percent,
        done,
        total
    )
    self:emit(message, vim.log.levels.INFO, false)
    self.shown = true
end

--- Show a message in the progress notification.
--- @param message string
--- @param level integer|nil
--- @param final boolean
function Progress:emit(message, level, final)
    if self.mode ~= "echo" then
        local opts = { title = "Neorg", id = self.id, replace = self.record }
        if not final then
            -- Keep the bar open while running.
            opts.timeout = false
            opts.hide_from_history = true
        else
            -- nvim-notify inherits unset options from the replaced notification, so the final
            -- message would never close and would be left out of the history.
            opts.timeout = M.final_timeout_ms
            opts.hide_from_history = false
        end
        local record = vim.notify(message, level, opts)
        if record ~= nil then
            self.mode = "notify"
            self.record = record
            return
        end
        if self.mode == "notify" then
            return
        end
        -- No record to replace: this message was shown by `vim.notify`, later ones are native
        -- progress messages.
        self.mode = "echo"
        return
    end
    local status = "running"
    if final then
        status = level == vim.log.levels.ERROR and "failed" or "success"
    end
    local ok, id = pcall(vim.api.nvim_echo, { { message } }, final, {
        kind = "progress",
        id = self.echo_id,
        title = "Neorg",
        status = status,
        percent = status == "success" and 100 or self.percent,
    })
    if ok then
        if id ~= -1 then
            self.echo_id = id
        end
    elseif final then
        -- Native progress messages are not supported (Neovim < 0.12).
        utils.notify(message, level)
    end
end

--- Stop the animation and show the final message. It replaces the bar if the bar was shown.
--- @param message string
--- @param level integer|nil
function Progress:finish(message, level)
    self.finished = true
    self:stop_timer()
    if self.shown and not self.broken then
        local failed = level == vim.log.levels.ERROR
        if pcall(self.emit, self, (failed and "✗ " or "✓ ") .. message, level, true) then
            return
        end
    end
    pcall(utils.notify, message, level)
end

return M
