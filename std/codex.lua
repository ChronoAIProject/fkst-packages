-- std.codex: small, dependency-free codex option builders.
local S = {}

function S.judgment_codex_opts(prompt, worktree)
  return {
    prompt = prompt,
    worktree = worktree,
    sandbox = "read-only",
  }
end

return S
