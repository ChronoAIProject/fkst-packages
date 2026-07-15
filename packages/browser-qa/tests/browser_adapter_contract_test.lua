local adapter = require("browser_adapter")
local browser_fake = require("browser_fake")
local t = fkst.test

local viewport = { width = 1280, height = 720 }
local screenshot_digest = string.rep("0123456789abcdef", 4)
local screenshot_path = ".fkst/artifacts/browser-qa/" .. screenshot_digest .. ".png"

local function public_methods(handle)
  local methods = {}
  for key, value in pairs(handle) do
    if type(value) == "function" then
      table.insert(methods, key)
    end
  end
  table.sort(methods)
  return table.concat(methods, ",")
end

return {
  test_production_adapter_decodes_navigation_result_without_launching_browser = function()
    local calls = {}
    local browser = adapter.new(function(spec)
      table.insert(calls, spec)
      return {
        stdout = '{"ok":true,"observation":{"visible_text_chars":0,"visible_visual_count":0},"console_error_count":0,"network_error_count":0,"screenshot_ref":{"kind":"host-worktree","ref":"' .. screenshot_path .. '"}}',
        stderr = "",
        exit_code = 0,
      }
    end)

    local result, err = browser.navigate("http://127.0.0.1:4173/dashboard", viewport)

    t.is_nil(err)
    t.eq(result.blank_render, true)
    t.eq(result.console_error_count, 0)
    t.eq(result.network_error_count, 0)
    t.eq(result.screenshot_ref.kind, "host-worktree")
    t.eq(result.screenshot_ref.ref, screenshot_path)
    t.eq(#calls, 1)
    t.eq(calls[1].argv[1], "node")
    t.eq(calls[1].argv[2], "-e")
    t.eq(type(calls[1].argv[3]), "string")
    t.eq(calls[1].argv[4], "http://127.0.0.1:4173/dashboard")
    t.eq(calls[1].argv[5], "1280")
    t.eq(calls[1].argv[6], "720")
    t.eq(calls[1].argv[7], ".fkst/artifacts/browser-qa")
    t.is_true(calls[1].argv[3]:find('createHash("sha256")', 1, true) ~= nil)
    t.is_true(calls[1].argv[3]:find('flag: "wx"', 1, true) ~= nil)
    t.eq(type(calls[1].timeout), "number")
    t.is_nil(calls[1].cmd)
  end,

  test_production_adapter_propagates_structured_playwright_unavailable = function()
    local browser = adapter.new(function(_spec)
      return {
        stdout = '{"ok":false,"error":{"class":"browser-adapter-unavailable","message":"Playwright is unavailable"}}',
        stderr = "",
        exit_code = 1,
      }
    end)

    local result, err = browser.navigate("http://127.0.0.1:4173/dashboard", viewport)

    t.is_nil(result)
    t.eq(err.class, "browser-adapter-unavailable")
    t.eq(err.operation, "navigate")
    t.eq(err.message, "Playwright is unavailable")
  end,

  test_production_adapter_turns_command_failure_into_structured_error = function()
    local browser = adapter.new(function(_spec)
      return {
        stdout = "not-json",
        stderr = "node failed",
        exit_code = 1,
      }
    end)

    local result, err = browser.navigate("http://127.0.0.1:4173/dashboard", viewport)

    t.is_nil(result)
    t.eq(err.class, "browser-adapter-failed")
    t.eq(err.operation, "navigate")
    t.eq(err.message, "node failed")
  end,

  test_production_adapter_rejects_unaddressed_screenshot_artifact = function()
    local browser = adapter.new(function(_spec)
      return {
        stdout = '{"ok":true,"observation":{"visible_text_chars":0,"visible_visual_count":0},"console_error_count":0,"network_error_count":0,"screenshot_ref":{"kind":"host-worktree","ref":".fkst/artifacts/browser-qa/latest.png"}}',
        stderr = "",
        exit_code = 0,
      }
    end)

    local result, err = browser.navigate("http://127.0.0.1:4173/dashboard", viewport)

    t.is_nil(result)
    t.eq(err.class, "browser-adapter-invalid-result")
    t.eq(err.operation, "navigate")
  end,

  test_production_and_fake_expose_the_same_browser_port_contract = function()
    local production = adapter.new(function(_spec)
      return { stdout = "{}", stderr = "", exit_code = 0 }
    end)
    local fake = browser_fake.new(browser_fake.model())

    t.eq(public_methods(production), "navigate")
    t.eq(public_methods(fake), "navigate")
  end,
}
