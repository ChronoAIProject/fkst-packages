local h = require("tests.devloop_helpers")
local checkpoint = require("departments.implement.result_checkpoint")

local t = h.t
local version = "ready/consensus/github-devloop/issue/owner/repo/42/intake/123"

return {
  test_receipt_subject_is_bound_to_the_exact_implementation_version = function()
    local subject = checkpoint.subject(version)

    t.is_true(subject:find("fkst: implementation result v1 ", 1, true) == 1)
    t.is_true(subject ~= checkpoint.subject(version .. "/reimplement/2"))
  end,

  test_rehydrate_accepts_only_the_exact_head_receipt = function()
    local progress = {
      base_branch = "dev",
      head_sha = "1111111111111111111111111111111111111111",
    }
    local git = {
      cat_file_pretty = function(head_sha)
        t.eq(head_sha, progress.head_sha)
        return {
          stdout = "tree aaaaaaa\nparent bbbbbbb\n\n" .. checkpoint.subject(version) .. "\n",
          stderr = "",
          exit_code = 0,
        }
      end,
    }

    t.eq(checkpoint.rehydrate(git, progress, version), progress)
    t.eq(checkpoint.rehydrate(git, progress, version .. "/reimplement/2"), nil)
  end,

  test_persist_writes_the_version_receipt_before_returning_its_head = function()
    local head_sha = "2222222222222222222222222222222222222222"
    local git = {
      git_empty_commit = function(worktree, message)
        t.eq(worktree, "/tmp/implementation")
        t.eq(message, checkpoint.subject(version))
        return { stdout = "", stderr = "", exit_code = 0 }
      end,
      git_head_sha = function(worktree)
        t.eq(worktree, "/tmp/implementation")
        return { stdout = head_sha .. "\n", stderr = "", exit_code = 0 }
      end,
    }

    t.eq(checkpoint.persist(git, "/tmp/implementation", version), head_sha)
  end,
}
