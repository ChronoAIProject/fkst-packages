local dependency_gate = require("devloop.dependency_gate")
local S = {}

function S.install(M)
  M.github_graphql_queries = dependency_gate.github_graphql_queries
  M.render_github_graphql_query = dependency_gate.render_github_graphql_query
  M.github_graphql = dependency_gate.github_graphql
end

return S
