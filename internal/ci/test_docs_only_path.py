import pathlib
import unittest

import yaml

import check_unconditional_guard_tooling as guard


class DocsOnlyPath(unittest.TestCase):
    def setUp(self):
        self.steps = yaml.safe_load(pathlib.Path(guard.WORKFLOW).read_text())["jobs"]["test"]["steps"]

    def test_cached_path_is_lightweight_and_validates(self):
        active = [step for step in self.steps if guard.runs_on(step, True)]
        commands = "\n".join(str(step.get("run", "")) for step in active)
        self.assertIn("pipeline validate", commands)
        self.assertIn("check_ticket_transitions.sh", commands)
        self.assertIn("check_ticket_move.sh", commands)
        for expensive in ("opam", "dune build", "prepare-guard-tools", "test_public_cloud_lifecycle"):
            self.assertNotIn(expensive, commands)
        self.assertFalse(any("setup-ocaml" in step.get("uses", "") for step in active))

    def test_source_use_full_path(self):
        active = [step for step in self.steps if guard.runs_on(step, False)]
        commands = "\n".join(str(step.get("run", "")) for step in active)
        self.assertIn("dune build", commands)
        self.assertIn("test_pipeline_validate.sh", commands)
        self.assertIn("test_unconditional_guard_tooling.sh", commands)
        self.assertTrue(any("setup-ocaml" in step.get("uses", "") for step in active))

    def test_classification_alone_selects_the_suite(self):
        for step in self.steps:
            condition = str(step.get("if", ""))
            if "docs-only" in condition:
                self.assertNotIn(
                    "cache-hit",
                    condition,
                    f"{step.get('name')} couples the classification to the validator cache",
                )

    def test_validator_cache_is_trusted_with_prefix_fallback(self):
        restore = next(step for step in self.steps if step.get("id") == "docs_tooling")
        save = next(step for step in self.steps if step.get("uses") == "actions/cache/save@v4")
        self.assertEqual(restore["with"]["path"], save["with"]["path"])
        self.assertEqual(restore["with"]["key"], save["with"]["key"])
        self.assertEqual(save["if"], "github.event_name == 'push' && github.ref == 'refs/heads/main'")
        self.assertIn("internal/tooling/sol_process/**/*.ml", restore["with"]["key"])
        self.assertTrue(
            str(restore["with"]["restore-keys"]).startswith("soldev-validation-v1-${{ runner.os }}-"),
            "the prefix fallback must stay inside the trusted key namespace",
        )

    def test_workflow_has_no_duplicate_keys(self):
        def inspect(node):
            if isinstance(node, yaml.MappingNode):
                keys = [key.value for key, _ in node.value]
                self.assertEqual(len(keys), len(set(keys)), f"duplicate key near line {node.start_mark.line + 1}")
                for _, value in node.value:
                    inspect(value)
            elif isinstance(node, yaml.SequenceNode):
                for value in node.value:
                    inspect(value)
        inspect(yaml.compose(pathlib.Path(guard.WORKFLOW).read_text()))


if __name__ == "__main__":
    unittest.main()
