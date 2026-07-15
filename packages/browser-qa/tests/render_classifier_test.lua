local classifier = require("render_classifier")
local t = fkst.test

return {
  test_decoratively_painted_empty_shell_is_blank = function()
    t.eq(classifier.blank_render({
      visible_text_chars = 0,
      visible_visual_count = 0,
      decorative_paint_count = 3,
    }), true)
  end,

  test_visible_text_or_meaningful_visual_is_not_blank = function()
    t.eq(classifier.blank_render({
      visible_text_chars = 4,
      visible_visual_count = 0,
    }), false)
    t.eq(classifier.blank_render({
      visible_text_chars = 0,
      visible_visual_count = 1,
    }), false)
  end,
}
