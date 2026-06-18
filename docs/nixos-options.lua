-- SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
-- SPDX-License-Identifier: CC-BY-SA-4.0

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
    local f = assert(io.open(path, "r"))
    local text = f:read("*a")
    f:close()
    local obj = assert(json.decode(text))
    cache = obj
  end
  return cache
end

local function insert_tree(tree, loc, entry)
  local full_name = table.concat(loc, ".")
  tree[full_name] = entry
end

local function render_tree(tree, level)
  local blocks = {}
  local names = {}
  for name, _ in pairs(tree) do
    table.insert(names, name)
  end
  table.sort(names)

  for _, name in ipairs(names) do
    local entry = tree[name]
    table.insert(blocks, pandoc.Header(level, pandoc.Str(name)))

    if entry.type then
      table.insert(blocks, pandoc.Para{pandoc.Strong{pandoc.Str("Type: ")}, pandoc.Code(entry.type)})
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
      table.insert(blocks, pandoc.Para{pandoc.Strong{pandoc.Str("Default: ")}, pandoc.Code(default_str)})
    end
    if entry.description then
      local desc = tostring(entry.description)
      table.insert(blocks, pandoc.Para{pandoc.Str(desc)})
    end
  end
  return blocks
end

function Para(el)
  for i, inline in ipairs(el.content) do
    if inline.t == "Str" and inline.text == "{{nixos-options}}" then
      if not options_json_path then
        return pandoc.Para{pandoc.Str("[missing options_json variable]")}
      end

      local obj = load_json(options_json_path)
      local root = {}

      for _, entry in pairs(obj) do
        insert_tree(root, entry.loc, entry)
      end

      return render_tree(root, 2)
    end
  end
end

return {{ Meta = Meta }, { Para = Para }}
