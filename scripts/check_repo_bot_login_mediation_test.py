#!/usr/bin/env python3
"""Tests for the G-BOT-LOGIN-MEDIATION zero-bypass ratchet."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from script_test_support import load_module


scripts_dir = Path(__file__).resolve().parent
mediation = load_module(
    "check_repo_bot_login_mediation",
    scripts_dir / "check_repo_bot_login_mediation.py",
)


class BotLoginMediationTest(unittest.TestCase):
    def kinds(self, source: str) -> set[str]:
        return {
            site.kind
            for site in mediation.source_sites("libraries/devloop/example.lua", source)
        }

    def test_detects_each_removed_legacy_normalizer(self) -> None:
        self.assertEqual(
            self.kinds("return devloop_base.strip_bot_login_suffix(author)"),
            {"legacy-normalizer"},
        )
        self.assertEqual(
            self.kinds("return content_filter.canon_login(author)"),
            {"legacy-normalizer"},
        )

    def test_detects_raw_login_comparisons_on_accessors_and_identity_names(self) -> None:
        accessor = "return issue_author_login(issue) == devloop_base.trusted_bot_login()"
        multiline = """
return parsers_misc._comment_author_login(issue)
  ~= bot_login
"""
        locals_only = "return author ~= owner"

        self.assertIn("raw-login-comparison", self.kinds(accessor))
        self.assertIn("raw-login-comparison", self.kinds(multiline))
        self.assertIn("raw-login-comparison", self.kinds(locals_only))

    def test_accepts_canonical_comparisons_and_non_identity_shape_checks(self) -> None:
        source = """
local canonical_author = forge_strings.canonical_login(author_login)
local owner = parsers_misc.canonical_login(trusted_login)
local payload = {
  owner = owner,
}
if canonical_author == nil or canonical_author == "" then return false end
if bot_login == "" or login ~= "" then return false end
if type(issue.author) == "table" and issue.author.login ~= nil then return true end
if canonical_author ~= owner then return false end
return forge_strings.canonical_login(author)
  == forge_strings.canonical_login(parsers_misc.trusted_bot_login())
"""

        self.assertEqual(mediation.source_sites("libraries/devloop/example.lua", source), set())

    def test_rejects_canonical_looking_operands_without_canonical_origin(self) -> None:
        aliases = """
local canonical_author = author
local normalized_owner = owner
return canonical_author == normalized_owner
"""
        reassigned = """
local canonical_author = forge_strings.canonical_login(author)
canonical_author = author
return canonical_author == trusted_login
"""
        lookalike_helper = "return identity.canonical_login(author) == identity.canonical_login(owner)"

        self.assertIn("raw-login-comparison", self.kinds(aliases))
        self.assertIn("raw-login-comparison", self.kinds(reassigned))
        self.assertIn("raw-login-comparison", self.kinds(lookalike_helper))

    def test_detects_raw_identity_comparisons_through_neutral_aliases(self) -> None:
        source = """
local left = author_login
local right = bot_login
local indirect = left
return indirect == right
"""

        self.assertIn("raw-login-comparison", self.kinds(source))

    def test_inner_canonical_bindings_do_not_canonicalize_outer_raw_bindings(self) -> None:
        source = """
local canonical_author = author_login
local normalized_owner = bot_login
if false then
  local canonical_author = forge_strings.canonical_login(author_login)
  local normalized_owner = forge_strings.canonical_login(bot_login)
end
return canonical_author == normalized_owner
"""

        self.assertIn("raw-login-comparison", self.kinds(source))

    def test_function_parameters_shadow_outer_canonical_bindings(self) -> None:
        source = """
local canonical_author = forge_strings.canonical_login(author_login)
local normalized_owner = forge_strings.canonical_login(bot_login)
local function raw_comparison(canonical_author, normalized_owner)
  return canonical_author == normalized_owner
end
"""

        self.assertIn("raw-login-comparison", self.kinds(source))

    def test_accepts_canonical_whitelist_membership(self) -> None:
        source = """
local canonical = forge_strings.canonical_login(author)
return canonical ~= nil and trusted_logins[canonical] == true
"""

        self.assertEqual(mediation.source_sites("packages/example/core.lua", source), set())

    def test_detects_raw_trust_set_membership(self) -> None:
        source = """
local author = issue.author_login
if trusted_logins[author] then return true end
return whitelist[comment_author_login(comment)] == true
"""

        sites = mediation.source_sites("packages/example/core.lua", source)

        self.assertEqual(
            {site.surface for site in sites if site.kind == "raw-login-membership"},
            {"trusted_logins[author]", "whitelist[comment_author_login(comment)]"},
        )

    def test_ignores_comments_strings_tests_and_the_canonical_helper_definition(self) -> None:
        source = """
-- return author == owner
local note = "strip_bot_login_suffix(author) == bot_login"
function S.canonical_login(login)
  return login
end
"""
        self.assertEqual(mediation.source_sites("libraries/forge/strings.lua", source), set())
        self.assertEqual(
            mediation.source_sites(
                "libraries/devloop/example.lua",
                '-- return trusted_logins[author]\nlocal note = "author == owner"\n',
            ),
            set(),
        )
        self.assertEqual(
            mediation.source_sites(
                "packages/example/tests/identity_test.lua",
                "return author == owner",
            ),
            set(),
        )

    def test_repository_scan_covers_library_and_package_production_lua(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            root = Path(raw_root)
            library = root / "libraries/devloop/example.lua"
            package = root / "packages/example/core.lua"
            test = root / "packages/example/tests/core_test.lua"
            for path in (library, package, test):
                path.parent.mkdir(parents=True, exist_ok=True)
            library.write_text("return author == owner\n", encoding="utf-8")
            package.write_text("return comment_author_login(comment) == bot_login\n", encoding="utf-8")
            test.write_text("return author == owner\n", encoding="utf-8")

            sites = mediation.repository_sites(root)

        self.assertEqual({site.path for site in sites}, {
            "libraries/devloop/example.lua",
            "packages/example/core.lua",
        })

    def test_zero_inventory_rejects_new_sites_and_stale_or_growing_allowlist(self) -> None:
        site = next(iter(mediation.source_sites(
            "libraries/devloop/example.lua",
            "return author == owner",
        )))
        self.assertIn("outside forge_strings.canonical_login", mediation.ratchet_messages({site}, set())[0])
        self.assertIn("prune the stale entry", mediation.ratchet_messages(set(), {site})[0])
        self.assertIn(
            "grows the bot-login mediation allowlist",
            mediation.ratchet_messages({site}, {site}, base_allowlist=set())[0],
        )


if __name__ == "__main__":
    unittest.main()
