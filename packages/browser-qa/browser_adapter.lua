local classifier = require("render_classifier")

local M = {}

local command_timeout_seconds = 60
local artifact_root = ".fkst/artifacts/browser-qa"

local playwright_script = [=[
const fs = require("fs");
const crypto = require("crypto");
const path = require("path");

function emit(value) {
  process.stdout.write(JSON.stringify(value));
}

function unavailable(message) {
  emit({ ok: false, error: { class: "browser-adapter-unavailable", message } });
  process.exitCode = 1;
}

async function main() {
  let chromium;
  try {
    ({ chromium } = require("playwright"));
  } catch (_error) {
    unavailable("Playwright is unavailable");
    return;
  }

  const url = process.argv[1];
  const width = Number(process.argv[2]);
  const height = Number(process.argv[3]);
  const artifactRoot = process.argv[4];
  let browser;
  try {
    browser = await chromium.launch({ headless: true });
    const page = await browser.newPage({ viewport: { width, height } });
    let consoleErrorCount = 0;
    let networkErrorCount = 0;
    page.on("console", message => {
      if (message.type() === "error") consoleErrorCount += 1;
    });
    page.on("requestfailed", () => {
      networkErrorCount += 1;
    });
    await page.goto(url, { waitUntil: "load", timeout: 30000 });
    const observation = await page.evaluate(() => {
      const body = document.body;
      if (!body) return { visible_text_chars: 0, visible_visual_count: 0 };

      const visibleTextChars = (body.innerText || "").replace(/\s/g, "").length;

      const isVisible = element => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) return false;
        if (rect.width <= 0 || rect.height <= 0) return false;
        return true;
      };

      const visualTags = new Set([
        "IMG", "SVG", "CANVAS", "VIDEO", "IFRAME", "INPUT", "BUTTON", "SELECT", "TEXTAREA",
      ]);
      const visibleVisualCount = [...body.querySelectorAll("*")].filter(element => {
        if (!isVisible(element)) return false;
        if (visualTags.has(element.tagName)) return true;
        return getComputedStyle(element).backgroundImage !== "none";
      }).length;

      return {
        visible_text_chars: visibleTextChars,
        visible_visual_count: visibleVisualCount,
      };
    });
    const screenshot = await page.screenshot({ fullPage: false, type: "png" });
    const digest = crypto.createHash("sha256").update(screenshot).digest("hex");
    const screenshotPath = path.join(artifactRoot, `${digest}.png`);
    fs.mkdirSync(artifactRoot, { recursive: true });
    try {
      fs.writeFileSync(screenshotPath, screenshot, { flag: "wx" });
    } catch (error) {
      if (!error || error.code !== "EEXIST") throw error;
    }
    emit({
      ok: true,
      observation,
      console_error_count: consoleErrorCount,
      network_error_count: networkErrorCount,
      screenshot_ref: {
        kind: "host-worktree",
        ref: `${artifactRoot}/${digest}.png`,
      },
    });
  } catch (error) {
    const message = String(error && error.message || error || "Playwright navigation failed");
    const missingExecutable = message.includes("Executable doesn't exist")
      || message.includes("playwright install");
    emit({
      ok: false,
      error: {
        class: missingExecutable ? "browser-adapter-unavailable" : "browser-adapter-failed",
        message,
      },
    });
    process.exitCode = 1;
  } finally {
    if (browser) await browser.close();
  }
}

main().catch(error => {
  emit({
    ok: false,
    error: { class: "browser-adapter-failed", message: String(error && error.message || error) },
  });
  process.exitCode = 1;
});
]=]

local function viewport_dimension(value)
  local number = tonumber(value)
  if number == nil or number < 1 or number > 4096 or number % 1 ~= 0 then
    return nil
  end
  return number
end

local function structured_error(class, message)
  return {
    class = class,
    operation = "navigate",
    message = tostring(message or class),
  }
end

local function decode_result(stdout)
  local ok, decoded = pcall(json.decode, stdout or "")
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

local function nonnegative_integer(value)
  local number = tonumber(value)
  if number == nil or number < 0 or number % 1 ~= 0 then
    return nil
  end
  return number
end

local function screenshot_ref(value)
  if type(value) ~= "table" or value.kind ~= "host-worktree" or type(value.ref) ~= "string" then
    return nil
  end
  local digest = value.ref:match("^%.fkst/artifacts/browser%-qa/([0-9a-f]+)%.png$")
  if digest == nil or #digest ~= 64 then
    return nil
  end
  return {
    kind = value.kind,
    ref = value.ref,
  }
end

function M.new(run)
  assert(type(run) == "function", "browser-qa: browser adapter requires an exec_argv runner")
  local handle = {}

  function handle.navigate(url, viewport)
    local width = viewport_dimension(type(viewport) == "table" and viewport.width or nil)
    local height = viewport_dimension(type(viewport) == "table" and viewport.height or nil)
    if type(url) ~= "string" or url == "" or width == nil or height == nil then
      return nil, structured_error("browser-adapter-invalid-request", "navigate requires a URL and bounded viewport")
    end

    local ok, command_or_error = pcall(run, {
      argv = {
        "node",
        "-e",
        playwright_script,
        url,
        tostring(width),
        tostring(height),
        artifact_root,
      },
      timeout = command_timeout_seconds,
    })
    if not ok then
      return nil, structured_error("browser-adapter-unavailable", command_or_error)
    end
    if type(command_or_error) ~= "table" then
      return nil, structured_error("browser-adapter-failed", "browser command returned no result")
    end

    local decoded = decode_result(command_or_error.stdout)
    if command_or_error.exit_code ~= 0 or decoded == nil or decoded.ok ~= true then
      local detail = decoded and decoded.error or nil
      return nil, structured_error(
        type(detail) == "table" and detail.class or "browser-adapter-failed",
        type(detail) == "table" and detail.message or command_or_error.stderr or "browser command failed"
      )
    end

    local console_error_count = nonnegative_integer(decoded.console_error_count)
    local network_error_count = nonnegative_integer(decoded.network_error_count)
    local artifact = screenshot_ref(decoded.screenshot_ref)
    local classified, blank_render = pcall(classifier.blank_render, decoded.observation)
    if not classified
      or console_error_count == nil
      or network_error_count == nil
      or artifact == nil then
      return nil, structured_error("browser-adapter-invalid-result", "browser command returned an invalid navigation result")
    end
    return {
      blank_render = blank_render,
      console_error_count = console_error_count,
      network_error_count = network_error_count,
      screenshot_ref = artifact,
    }, nil
  end

  return handle
end

return M
