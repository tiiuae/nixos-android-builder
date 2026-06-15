local json = require("pandoc.json")
local utils = require("pandoc.utils")

local cache = nil
local options_json_path = nil

function Meta(meta)
  if meta.options_json then
    options_json_path = utils.stringify(meta.options_json)
  end
  return meta
end

function load_json(path)
  if not cache then
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    if not text or text == "" then return nil end
    local ok, obj = pcall(json.decode, text)
    if not ok then return nil end
    cache = obj
  end
  return cache
end

local function insert_tree(tree, loc, entry)
  local full_name = table.concat(loc, ".")
  tree[full_name] = entry
end

local function render_option(name, entry)
  -- Build the definition body as a list of inlines/blocks
  local body = {}

  if entry.type then
    table.insert(body, pandoc.Para{
      pandoc.Strong{pandoc.Str("Type: ")},
      pandoc.Code(entry.type)
    })
  end

  if entry.default then
    local default_str
    if type(entry.default) == "table" and entry.default._type == "literalExpression" then
      default_str = entry.default.text
    elseif type(entry.default) == "table" then
      default_str = json.encode(entry.default)
    else
      default_str = tostring(entry.default)
    end
    table.insert(body, pandoc.Para{
      pandoc.Strong{pandoc.Str("Default: ")},
      pandoc.Code(default_str)
    })
  end

  if entry.description then
    local desc = tostring(entry.description)
    -- Parse description as Markdown to render inline formatting
    local parsed = pandoc.read(desc, "markdown")
    for _, block in ipairs(parsed.blocks) do
      table.insert(body, block)
    end
  end

  return body
end

local function render_tree(tree)
  local names = {}
  for name, _ in pairs(tree) do
    table.insert(names, name)
  end
  table.sort(names)

  local items = {}
  for _, name in ipairs(names) do
    local entry = tree[name]
    local term = {pandoc.Code(name)}
    local def = render_option(name, entry)
    table.insert(items, {term, {def}})
  end

  return pandoc.DefinitionList(items)
end

function Para(el)
  for i, inline in ipairs(el.content) do
    if inline.t == "Str" and inline.text == "{{nixos-options}}" then
      if not options_json_path then
        return pandoc.Para{pandoc.Str("[missing options_json variable]")}
      end

      local obj = load_json(options_json_path)
      if not obj then
        return pandoc.Para{pandoc.Emph{pandoc.Str("NixOS options will be inserted during the full build.")}}
      end

      local root = {}
      for _, entry in pairs(obj) do
        insert_tree(root, entry.loc, entry)
      end

      return render_tree(root)
    end
  end
end

return {{ Meta = Meta }, { Para = Para }}
