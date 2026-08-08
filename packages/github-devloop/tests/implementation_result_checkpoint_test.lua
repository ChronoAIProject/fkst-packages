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

  test_reseal_reuses_the_exact_head_receipt_without_another_commit = function()
    local progress = {
      branch = "devloop-owner-repo-42",
      head_sha = "1111111111111111111111111111111111111111",
      base_branch = "dev",
    }
    local git = {
      git_head_sha = function(worktree, timeout)
        t.eq(worktree, "/tmp/implementation")
        t.eq(timeout, 30)
        return { stdout = progress.head_sha .. "\n", stderr = "", exit_code = 0 }
      end,
      git_empty_commit = function()
        error("unchanged receipt must not create another commit")
      end,
    }

    t.eq(checkpoint.reseal(git, "/tmp/implementation", progress, version), progress)
  end,

  test_reseal_binds_a_reconciled_head_without_mutating_the_source_fact = function()
    local original_head = "1111111111111111111111111111111111111111"
    local merged_head = "2222222222222222222222222222222222222222"
    local receipt_head = "3333333333333333333333333333333333333333"
    local progress = {
      branch = "devloop-owner-repo-42",
      head_sha = original_head,
      base_branch = "dev",
    }
    local head_reads = 0
    local git = {
      git_head_sha = function()
        head_reads = head_reads + 1
        local head = head_reads == 1 and merged_head or receipt_head
        return { stdout = head .. "\n", stderr = "", exit_code = 0 }
      end,
      is_ancestor = function(ancestor, descendant, timeout)
        t.eq(ancestor, original_head)
        t.eq(descendant, merged_head)
        t.eq(timeout, 30)
        return { stdout = "", stderr = "", exit_code = 0 }
      end,
      git_empty_commit = function(worktree, message, timeout)
        t.eq(worktree, "/tmp/implementation")
        t.eq(message, checkpoint.subject(version))
        t.eq(timeout, 60)
        return { stdout = "", stderr = "", exit_code = 0 }
      end,
    }

    local resealed = checkpoint.reseal(git, "/tmp/implementation", progress, version)

    t.eq(progress.head_sha, original_head)
    t.eq(resealed.branch, progress.branch)
    t.eq(resealed.base_branch, progress.base_branch)
    t.eq(resealed.head_sha, receipt_head)
  end,

  test_reseal_rejects_a_reconciled_head_that_lost_the_completed_receipt = function()
    local progress = {
      branch = "devloop-owner-repo-42",
      head_sha = "1111111111111111111111111111111111111111",
      base_branch = "dev",
    }
    local git = {
      git_head_sha = function()
        return {
          stdout = "2222222222222222222222222222222222222222\n",
          stderr = "",
          exit_code = 0,
        }
      end,
      is_ancestor = function()
        return { stdout = "", stderr = "", exit_code = 1 }
      end,
      git_empty_commit = function()
        error("non-ancestor head must not receive a replacement receipt")
      end,
    }

    local ok, err = pcall(function()
      checkpoint.reseal(git, "/tmp/implementation", progress, version)
    end)

    t.eq(ok, false)
    t.is_true(tostring(err):find("implementation-result-receipt-not-ancestor", 1, true) ~= nil)
  end,
}
