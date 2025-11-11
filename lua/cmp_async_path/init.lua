local cmp = require("cmp")
local IS_WIN = vim.uv.os_uname().sysname == "Windows_NT"
local NAME_REGEX = "\\%([^/\\\\:\\*?<>'\"`\\|]\\)"
local PATH_REGEX ---@type vim.regex
local PATH_SEPARATOR

-- Debug mode (enabled when environment variable CMP_ASYNC_PATH_DEBUG=1)
local DEBUG = vim.env.CMP_ASYNC_PATH_DEBUG == "1"
local DEBUG_LOG_FILE = "/tmp/cmp-async-path-debug.log"

-- Initialize debug log file (only in DEBUG mode)
if DEBUG then
  local log_file = io.open(DEBUG_LOG_FILE, "w")
  if log_file then
    log_file:write(string.format("=== cmp-async-path debug log started at %s ===\n", os.date("%Y-%m-%d %H:%M:%S")))
    log_file:close()
  end
end

local function debug_log(msg)
  if DEBUG then
    vim.schedule(function()
      local log_file = io.open(DEBUG_LOG_FILE, "a")
      if log_file then
        log_file:write(string.format("[%s] %s\n", os.date("%H:%M:%S"), msg))
        log_file:close()
      end
    end)
  end
end

if IS_WIN then
  PATH_REGEX =
    vim.regex(([[\%(\%([/\\."]PAT*[^/\\\\:\\*?<>\'"`\\| .~]\)\|\%([/\\]\.\.  \)\)*[/\\.\"]\zePAT*$]]):gsub("PAT", NAME_REGEX))
  PATH_SEPARATOR = "[/\\]"
else
  PATH_REGEX = vim.regex(([[\%(\%([/\."]PAT*[^/\\\\:\\*?<>\'"`\\| .~]\)\|\%([/\.]\.\.  \)\)*[/\."]\zePAT*$]]):gsub("PAT", NAME_REGEX))
  PATH_SEPARATOR = "/"
end

local source = {}

local constants = { max_lines = 20 }

---@class cmp_path.Option
---@field public trailing_slash boolean
---@field public label_trailing_slash boolean
---@field public get_cwd fun(table): string
---@field public show_hidden_files_by_default boolean

---@type cmp_path.Option
local defaults = {
  trailing_slash = false,
  label_trailing_slash = true,
  get_cwd = function(params)
    return vim.fn.expand(("#%d:p:h"):format(params.context.bufnr))
  end,
  show_hidden_files_by_default = false,
}

source.new = function()
  return setmetatable({}, { __index = source })
end

source.get_trigger_characters = function()
  if IS_WIN then
    return { "/", ".", "\\" }
  else
    return { "/", "." }
  end
end

source.get_keyword_pattern = function(_, _)
  -- Don't include / in keyword pattern since it functions as a trigger character
  -- This ensures that when typing "lua/", the offset is correctly positioned after "/"
  return NAME_REGEX .. "*"
end

---@param params cmp.SourceCompletionApiParams
---@param callback fun(response: lsp.CompletionResponse|nil)
function source:complete(params, callback)
  local option = self:_validate_option(params)

  debug_log(string.format("[cmp-async-path] complete called with input: '%s', offset: %d", params.context.cursor_before_line, params.offset))

  local dirname = self:_dirname(params, option)

  debug_log(string.format("[cmp-async-path] _dirname returned: %s", dirname or "nil"))

  if not dirname then
    return callback()
  end

  -- Determine whether to show dot-prefixed (hidden) files
  -- 1. show_hidden_files_by_default is true
  -- 2. Character at current position is . (e.g., ".lo" with offset=1)
  -- 3. Previous character is . (e.g., "." with offset=2, or "lua/." with offset=6)
  local include_hidden = option.show_hidden_files_by_default
    or string.sub(params.context.cursor_before_line, params.offset, params.offset) == "."
    or string.sub(params.context.cursor_before_line, params.offset - 1, params.offset - 1) == "."
  debug_log(string.format("[cmp-async-path] calling _candidates with dirname: '%s', include_hidden: %s, offset: %d", dirname, include_hidden, params.offset))
  self:_candidates(
    dirname,
    include_hidden,
    option,
    ---@param err nil|string
    ---@param candidates lsp.CompletionResponse|nil
    function(err, candidates)
      if err then
        debug_log(string.format("[cmp-async-path] _candidates returned error: %s", err))
        return callback()
      end
      debug_log(string.format("[cmp-async-path] _candidates returned %d candidates", candidates and #candidates or 0))
      callback(candidates)
    end
  )
end

--- get documentation in separate thread
---@param completion_item lsp.CompletionItem
---@param callback fun(completion_item: lsp.CompletionItem|nil)
function source:resolve(completion_item, callback)
  local data = completion_item.data or {}
  if not data.stat or data.stat.type ~= "file" then
    -- return right away with no changes / no added docs
    callback(completion_item)
    return
  end

  local work
  work = vim.uv.new_work(
    --- Read file in thread
    ---@param filepath string
    ---@param count number max line count (-1 if no max)
    ---@return string|nil, string (error, serialized_table) either some error or the serialized table
    function(filepath, count)
      local ok, binary = pcall(io.open, filepath, "rb")
      if not ok or binary == nil then
        ---@diagnostic disable-next-line: redundant-return-value
        return nil,
          vim.json.encode({
            kind = "binary",
            contents = "« cannot read this file »",
          })
      end
      local first_kb = binary:read(1024)
      if first_kb == nil or first_kb == "" then
        ---@diagnostic disable-next-line: redundant-return-value
        return nil, vim.json.encode({ kind = "binary", contents = "« empty file »" })
      end

      if first_kb:find("\0") then
        ---@diagnostic disable-next-line: redundant-return-value
        return nil, vim.json.encode({ kind = "binary", contents = "binary file" })
      end

      local contents = {}
      for content in first_kb:gmatch("[^\r\n]+") do
        table.insert(contents, content)
        if count > -1 and #contents >= count then
          break
        end
      end
      ---@diagnostic disable-next-line: redundant-return-value
      return nil, vim.json.encode({ contents = contents })
    end,
    --- deserialize doc and call callback(…)
    ---@param serialized_fileinfo string
    function(worker_error, serialized_fileinfo)
      if worker_error then
        error(string.format("Worker error while fetching file doc: %s", worker_error))
      end

      local read_ok, file_info =
        pcall(vim.json.decode, serialized_fileinfo, { luanil = { object = true, array = true } })
      if not read_ok then
        error(string.format("Unexpected problem de-serializing item info: «%s»", serialized_fileinfo))
      end
      if file_info.kind == "binary" then
        completion_item.documentation = {
          kind = cmp.lsp.MarkupKind.PlainText,
          value = file_info.contents,
        }
      else
        local contents = file_info.contents
        local filetype = vim.filetype.match({ contents = contents })
        if not filetype then
          completion_item.documentation = {
            kind = cmp.lsp.MarkupKind.PlainText,
            value = table.concat(contents, "\n"),
          }
        else
          table.insert(contents, 1, "```" .. filetype)
          table.insert(contents, "```")
          completion_item.documentation = {
            kind = cmp.lsp.MarkupKind.Markdown,
            value = table.concat(contents, "\n"),
          }
        end
      end

      callback(completion_item)
    end
  )
  work:queue(data.path, constants.max_lines or -1, cmp.lsp.MarkupKind.Markdown)
end

--- Try to match a path before cursor and return its dirname
--- Try to work around non-literal paths, like resolving env vars
---@param params cmp.SourceCompletionApiParams
---@param option cmp_path.Option
function source:_dirname(params, option)
  local s = PATH_REGEX:match_str(params.context.cursor_before_line)

  local buf_dirname = option.get_cwd(params)
  if vim.api.nvim_get_mode().mode == "c" then
    buf_dirname = vim.fn.getcwd()
  end

  if not s then
    -- PATH_REGEX did not match
    local input = params.context.cursor_before_line
    debug_log(string.format("[cmp-async-path] PATH_REGEX not matched, input: '%s'", input))

    -- Check if path separator is included (e.g., input like "lua/")
    local separator_pattern = IS_WIN and "[/\\]" or "/"
    if input:match(separator_pattern) then
      -- Get the path up to the last separator
      local path_part = input:match("^(.*" .. separator_pattern .. ")")
      debug_log(string.format("[cmp-async-path] path_part: '%s'", path_part or "nil"))
      if path_part then
        -- Resolve as relative path (e.g., "lua/" -> "/path/to/cwd/lua/")
        local resolved = vim.fn.resolve(buf_dirname .. "/" .. path_part)
        debug_log(string.format("[cmp-async-path] resolved path: '%s'", resolved))
        return resolved
      end
    end

    -- If no path separator is included, return current directory
    -- This allows completion of current directory files even with input like "REA"
    debug_log(string.format("[cmp-async-path] returning buf_dirname: '%s'", buf_dirname))
    return buf_dirname
  end

  local dirname = string.gsub(string.sub(params.context.cursor_before_line, s + 2), "%a*$", "") -- exclude '/'
  local prefix = string.sub(params.context.cursor_before_line, 1, s + 1) -- include '/'

  local input = params.context.cursor_before_line

  -- Handle single "." input (for showing hidden files)
  if input == "." then
    debug_log(string.format("[cmp-async-path] dot only input detected, returning buf_dirname"))
    return buf_dirname
  end

  -- Handle dot-prefixed relative paths like ".git/"
  -- Check the full input since PATH_REGEX may not match correctly
  if input:match("^%.") and input:match("/$") then
    local dot_rel_path = input:match("^(.*)/$") -- Remove trailing / (e.g., ".git/" -> ".git")
    debug_log(string.format("[cmp-async-path] dot relative path detected: '%s'", dot_rel_path))
    -- Don't use dirname (PATH_REGEX parsing may be inaccurate)
    return vim.fn.resolve(buf_dirname .. "/" .. dot_rel_path)
  end

  if prefix:match("%.%." .. PATH_SEPARATOR .. "$") then
    return vim.fn.resolve(buf_dirname .. "/../" .. dirname)
  end
  if prefix:match("%." .. PATH_SEPARATOR .. "$") or prefix:match('"$') or prefix:match("'$") then
    return vim.fn.resolve(buf_dirname .. "/" .. dirname)
  end
  if prefix:match("~" .. PATH_SEPARATOR .. "$") then
    return vim.fn.resolve(vim.fn.expand("~") .. "/" .. dirname)
  end
  local env_var_name = prefix:match("%$([%a_]+)" .. PATH_SEPARATOR .. "$")
  if env_var_name then
    local env_var_value = vim.fn.getenv(env_var_name)
    if env_var_value ~= vim.NIL then
      return vim.fn.resolve(env_var_value .. "/" .. dirname)
    end
  end
  if IS_WIN then
    local driver = prefix:match("(%a:)[/\\]$")
    if driver then
      return vim.fn.resolve(driver .. "/" .. dirname)
    end
  end
  -- Handle relative paths without ./ prefix (e.g., "lua/", "src/foo/")
  -- Treat paths that don't start with /, ~, or $ as relative paths
  if prefix:match("/$") and not prefix:match("^[/~$]") and not prefix:match("^%a+://") then
    -- Get the part excluding the trailing / (e.g., "lua/" -> "lua")
    local rel_path = string.sub(prefix, 1, -2)
    debug_log(string.format("[cmp-async-path] relative path detected: '%s'", rel_path))
    return vim.fn.resolve(buf_dirname .. "/" .. rel_path .. "/" .. dirname)
  end
  if prefix:match("/$") then
    local accept = true
    -- Ignore URL components
    accept = accept and not prefix:match("%a/$")
    -- Ignore URL scheme
    accept = accept and not prefix:match("%a+:/$") and not prefix:match("%a+://$")
    -- Ignore HTML closing tags
    accept = accept and not prefix:match("</$")
    -- Ignore math calculation
    accept = accept and not prefix:match("[%d%)]%s*/$")
    -- Ignore / comment
    accept = accept and (not prefix:match("^[%s/]*$") or not self:_is_slash_comment_p())
    if accept then
      return vim.fn.resolve("/" .. dirname)
    end
  end
  return nil
end

--- call cmp's callback(entries) after retrieving entries in a separate thread
---@param dirname string
---@param include_hidden boolean
---@param option cmp_path.Option
---@param callback function(err:nil|string, candidates:lsp.CompletionResponse|nil)
function source:_candidates(dirname, include_hidden, option, callback)
  debug_log(string.format("[cmp-async-path] _candidates called with dirname: '%s'", dirname))
  local entries, err = vim.uv.fs_scandir(dirname)
  if err then
    debug_log(string.format("[cmp-async-path] fs_scandir error: %s", err))
    return callback(err, nil)
  end
  debug_log(string.format("[cmp-async-path] fs_scandir success, entries: %s", entries))

  local work
  work = vim.uv.new_work(
    --- Collect path entries, serialize them and return them
    --- This function is called in a separate thread, so errors are caught and serialized
    ---@param _entries uv.uv_fs_t
    ---@param _dirname string see vim.fn.resolve()
    ---@param _include_hidden boolean
    ---@param label_trailing_slash boolean
    ---@param trailing_slash boolean
    ---@param file_kind table<string,number> see cmp.lsp.CompletionItemKind.Filee
    ---@param folder_kind table<string,number> see cmp.lsp.CompletionItemKind.Folder
    ---@return string|nil, string (error, serialized_results) "error text", nil or nil, "serialized items"
    function(_entries, _dirname, _include_hidden, label_trailing_slash, trailing_slash, file_kind, folder_kind)
      local items = {}

      local function create_item(name, fs_type)
        if not (_include_hidden or string.sub(name, 1, 1) ~= ".") then
          return
        end

        local path = _dirname .. "/" .. name
        local stat = vim.uv.fs_stat(path)
        local lstat = nil
        if stat then
          fs_type = stat.type
        elseif fs_type == "link" then
          ---@diagnostic disable-next-line: missing-parameter
          lstat = vim.uv.fs_lstat(_dirname)
          if not lstat then
            -- Broken symlink
            return
          end
        else
          return
        end

        local item = {
          label = name,
          filterText = name,
          insertText = name,
          kind = file_kind,
          data = { path = path, type = fs_type, stat = stat, lstat = lstat },
        }
        if fs_type == "directory" then
          item.kind = folder_kind
          if label_trailing_slash then
            item.label = name .. "/"
          else
            item.label = name
          end
          item.insertText = name .. "/"
          if not trailing_slash then
            item.word = name
          end
        end

        table.insert(items, item)
      end

      while true do
        local name, fs_type, e = vim.uv.fs_scandir_next(_entries)
        if e then
          ---@diagnostic disable-next-line: redundant-return-value
          return fs_type, ""
        end
        if not name then
          break
        end
        create_item(name, fs_type)
      end

      ---@diagnostic disable-next-line: redundant-return-value
      return nil, vim.json.encode(items)
    end,
    --- Receive serialiazed entries, deserialize them, call callback(entries)
    --- This function is called in the main thread
    ---@param worker_error string|nil non-nil if some error happened in worker thread
    ---@param serialized_items string array-of-items serialized as string
    function(worker_error, serialized_items)
      debug_log(string.format("[cmp-async-path] worker callback called, error: %s", worker_error or "nil"))
      if worker_error then
        callback(err, nil)
        return
      end
      local read_ok, items = pcall(vim.json.decode, serialized_items, { luanil = { object = true, array = true } })
      if not read_ok then
        debug_log("[cmp-async-path] JSON decode failed")
        callback("Problem de-serializing file entries", nil)
      end
      debug_log(string.format("[cmp-async-path] worker returned %d items", items and #items or 0))
      if DEBUG and items then
        for i, item in ipairs(items) do
          debug_log(string.format("  [%d] label='%s', filterText='%s', word='%s'",
            i, item.label or "", item.filterText or "", item.word or "nil"))
        end
      end
      callback(nil, items)
    end
  )

  work:queue(
    entries,
    dirname,
    include_hidden,
    option.label_trailing_slash,
    option.trailing_slash,
    cmp.lsp.CompletionItemKind.File,
    cmp.lsp.CompletionItemKind.Folder
  )
end

--- using «/» as comment in current buffer?
function source:_is_slash_comment_p()
  local commentstring = vim.bo.commentstring or ""
  local no_filetype = vim.bo.filetype == ""
  local is_slash_comment = false
  ---@diagnostic disable-next-line: assign-type-mismatch
  is_slash_comment = is_slash_comment or commentstring:match("/%*") or commentstring:match("//")
  return is_slash_comment and not no_filetype
end

---@param params cmp.SourceCompletionApiParams
---@return cmp_path.Option
function source:_validate_option(params)
  local option = assert(vim.tbl_deep_extend("keep", params.option, defaults))
  local validations = {
    trailing_slash = { option.trailing_slash, "boolean" },
    label_trailing_slash = { option.label_trailing_slash, "boolean" },
    get_cwd = { option.get_cwd, "function" },
    show_hidden_files_by_default = { option.show_hidden_files_by_default, "boolean" },
    ---@diagnostic disable-next-line: missing-parameter
  }
  if vim.fn.has("nvim-0.11") == 1 then
    for name, t in pairs(validations) do
      local value, type = unpack(t)
      vim.validate(name, value, type)
    end
  else
    vim.validate(validations)
  end
  return option
end

return source
