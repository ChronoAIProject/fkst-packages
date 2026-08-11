local verified_satisfaction = require("core.verified_satisfaction")

local t = fkst.test

local checkout = {
  root = "/tmp/worktree",
  head_sha = "1111111111111111111111111111111111111111",
  tree = "2222222222222222222222222222222222222222",
  clean = true,
}

local function ancestry_result(exit_code)
  local calls = {}
  local deps = {
    git = {
      is_ancestor_worktree = function(root, ancestor, descendant, timeout)
        calls[#calls + 1] = {
          root = root,
          ancestor = ancestor,
          descendant = descendant,
          timeout = timeout,
        }
        if exit_code == "missing" then
          return nil
        end
        return { exit_code = exit_code, stdout = "", stderr = "" }
      end,
    },
  }
  return deps, calls
end

local function assert_ancestry_error(exit_code, needle)
  local deps = ancestry_result(exit_code)
  local ok, err = pcall(function()
    verified_satisfaction.is_ancestor(
      deps,
      checkout,
      "3333333333333333333333333333333333333333",
      checkout.head_sha
    )
  end)
  t.eq(ok, false)
  t.is_true(tostring(err):find(needle, 1, true) ~= nil)
end

local function checkout_git(overrides)
  local selected = overrides or {}
  return {
    status_porcelain = selected.status_porcelain or function()
      return { exit_code = 0, stdout = "", stderr = "" }
    end,
    head_sha = selected.head_sha or function()
      return { exit_code = 0, stdout = checkout.head_sha .. "\n", stderr = "" }
    end,
    head_tree = selected.head_tree or function()
      return { exit_code = 0, stdout = checkout.tree .. "\n", stderr = "" }
    end,
  }
end

local function assert_checkout_error(deps, needle)
  local ok, err = pcall(function()
    verified_satisfaction.current_checkout(deps)
  end)
  t.eq(ok, false)
  t.is_true(tostring(err):find(needle, 1, true) ~= nil)
end

return {
  test_ancestry_exit_zero_is_true = function()
    local deps, calls = ancestry_result(0)

    t.eq(verified_satisfaction.is_ancestor(
      deps,
      checkout,
      "3333333333333333333333333333333333333333",
      checkout.head_sha
    ), true)
    t.eq(#calls, 1)
    t.eq(calls[1].root, checkout.root)
    t.eq(calls[1].timeout, 30)
  end,

  test_ancestry_exit_one_is_false = function()
    local deps = ancestry_result(1)

    t.eq(verified_satisfaction.is_ancestor(
      deps,
      checkout,
      "3333333333333333333333333333333333333333",
      checkout.head_sha
    ), false)
  end,

  test_ancestry_command_error_is_not_a_negative_claim = function()
    assert_ancestry_error(128, "verified-satisfaction-ancestry-command-failed")
  end,

  test_missing_ancestry_result_is_not_a_negative_claim = function()
    assert_ancestry_error("missing", "verified-satisfaction-ancestry-result-invalid")
  end,

  test_checkout_status_command_error_is_not_a_dirty_checkout = function()
    assert_checkout_error({
      git = checkout_git({
        status_porcelain = function()
          return { exit_code = 128, stdout = "", stderr = "status failed" }
        end,
      }),
    }, "verified-satisfaction-checkout-command-failed")
  end,

  test_missing_checkout_status_result_is_not_a_clean_checkout = function()
    assert_checkout_error({
      git = checkout_git({
        status_porcelain = function()
          return nil
        end,
      }),
    }, "verified-satisfaction-checkout-result-invalid")
  end,

  test_checkout_status_without_stdout_is_not_a_clean_checkout = function()
    assert_checkout_error({
      git = checkout_git({
        status_porcelain = function()
          return { exit_code = 0, stderr = "" }
        end,
      }),
    }, "verified-satisfaction-checkout-result-invalid")
  end,

  test_checkout_head_command_error_is_not_nonverification = function()
    assert_checkout_error({
      git = checkout_git({
        head_sha = function()
          return { exit_code = 128, stdout = "", stderr = "head failed" }
        end,
      }),
    }, "verified-satisfaction-checkout-command-failed")
  end,

  test_malformed_checkout_head_is_not_nonverification = function()
    assert_checkout_error({
      git = checkout_git({
        head_sha = function()
          return { exit_code = 0, stdout = "not-a-sha\n", stderr = "" }
        end,
      }),
    }, "verified-satisfaction-checkout-result-invalid")
  end,

  test_checkout_tree_command_error_is_not_nonverification = function()
    assert_checkout_error({
      git = checkout_git({
        head_tree = function()
          return { exit_code = 128, stdout = "", stderr = "tree failed" }
        end,
      }),
    }, "verified-satisfaction-checkout-command-failed")
  end,

  test_malformed_checkout_tree_is_not_nonverification = function()
    assert_checkout_error({
      git = checkout_git({
        head_tree = function()
          return { exit_code = 0, stdout = "not-a-sha\n", stderr = "" }
        end,
      }),
    }, "verified-satisfaction-checkout-result-invalid")
  end,

  test_missing_injected_checkout_is_not_nonverification = function()
    assert_checkout_error({
      current_checkout = function()
        return nil
      end,
    }, "verified-satisfaction-checkout-result-invalid")
  end,

  test_malformed_injected_checkout_is_not_nonverification = function()
    assert_checkout_error({
      current_checkout = function()
        return {
          head_sha = "not-a-sha",
          tree = checkout.tree,
          clean = true,
        }
      end,
    }, "verified-satisfaction-checkout-result-invalid")
  end,

  test_dirty_checkout_cannot_be_verified = function()
    local current = verified_satisfaction.current_checkout({
      current_checkout = function()
        return {
          head_sha = checkout.head_sha,
          tree = checkout.tree,
          clean = false,
        }
      end,
    })

    t.is_nil(current)
  end,
}
