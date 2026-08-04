local h = require("tests.devloop_helpers")
local restart_edges = require("devloop.restart_edges")

local t = h.t

local function valid_entry()
  return {
    semantic_variant = "site",
    owner = "owner",
    row_id = "reviewing",
    kind = "entry",
    source = { state = nil, boundary = "owner.queue" },
    target = "reviewing",
    provenance = {
      owner = "owner",
      row = "reviewing",
      field = "entry_inventory.site",
    },
  }
end

local function assert_extract_fails(selected_owner, inventory, rows)
  local ok = pcall(function()
    restart_edges.extract_entry_edges(selected_owner, inventory, rows)
  end)
  t.eq(ok, false)
end


return {
  test_entry_edge_extractor_fails_closed_on_invalid_inventory = function()
    assert_extract_fails("", { valid_entry() }, {})
    assert_extract_fails("owner", nil, {})
    assert_extract_fails("owner", { valid_entry() }, nil)
    assert_extract_fails("owner", { "not-an-edge" }, {})

    local edge = valid_entry()
    edge.semantic_variant = ""
    assert_extract_fails("owner", { edge }, {})

    edge = valid_entry()
    edge.semantic_variant = "qualified/site"
    assert_extract_fails("owner", { edge }, {})

    edge = valid_entry()
    edge.owner = "other-owner"
    assert_extract_fails("owner", { edge }, {})

    edge = valid_entry()
    edge.row_id = ""
    assert_extract_fails("owner", { edge }, {})

    edge = valid_entry()
    edge.kind = "autonomous"
    assert_extract_fails("owner", { edge }, {})

    edge = valid_entry()
    edge.source.state = "unmanaged"
    assert_extract_fails("owner", { edge }, {})

    edge = valid_entry()
    edge.source.boundary = ""
    assert_extract_fails("owner", { edge }, {})

    edge = valid_entry()
    edge.target = ""
    assert_extract_fails("owner", { edge }, {})

    edge = valid_entry()
    edge.provenance.owner = ""
    assert_extract_fails("owner", { edge }, {})

    edge = valid_entry()
    edge.provenance.owner = "other-owner"
    assert_extract_fails("owner", { edge }, {})

    edge = valid_entry()
    edge.provenance.row = ""
    assert_extract_fails("owner", { edge }, {})

    edge = valid_entry()
    edge.provenance.field = ""
    assert_extract_fails("owner", { edge }, {})

    assert_extract_fails("owner", { valid_entry(), valid_entry() }, {})
  end,
}
