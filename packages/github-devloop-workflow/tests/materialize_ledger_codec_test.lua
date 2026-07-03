local ledger_codec = require("core.materialize.ledger_codec")
local t = fkst.test

local tests = {
  test_generated_spec_codec_round_trips_with_newlines = function()
    local spec = {
      title = "Generated: title",
      body = "line one\nline two\n<!-- marker-like text -->",
    }
    local decoded = ledger_codec.decode_generated_spec_block("prefix\n" .. ledger_codec.encode_generated_spec(spec) .. "\nsuffix")
    t.eq(decoded.title, spec.title)
    t.eq(decoded.body, spec.body)
  end,

  test_generated_spec_codec_fails_closed_on_malformed_payload = function()
    t.is_nil(ledger_codec.decode_generated_spec_block("ordinary body"))
    t.is_nil(ledger_codec.decode_generated_spec_block(ledger_codec.GENERATED_SPEC_BEGIN .. "\nfield:title\nbad\nx\n"))
    t.is_nil(ledger_codec.decode_generated_spec_block(
      ledger_codec.GENERATED_SPEC_BEGIN
        .. "\nfield:title\n5\nabc\nfield:body\n1\nx\n"
        .. ledger_codec.GENERATED_SPEC_END
    ))
  end,
}

return tests
