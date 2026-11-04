"""Syntax-only verification; this does not replace Xcode/Skip compilation."""
from pathlib import Path
import sys

root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(root / ".tools" / "python"))
from tree_sitter import Language, Parser
import tree_sitter_swift

parser = Parser(Language(tree_sitter_swift.language()))
files = [root / "Package.swift"]
for folder in ("Sources", "tests/BahaCoreTests", "Darwin/Sources"):
    files.extend((root / folder).rglob("*.swift"))
errors = []
for file in files:
    source = file.read_bytes()
    tree = parser.parse(source)
    if tree.root_node.has_error:
        stack = [tree.root_node]
        while stack:
            node = stack.pop()
            if node.type == "ERROR" or node.is_missing:
                errors.append(f"{file.relative_to(root)}:{node.start_point.row + 1}: {node.type}")
            stack.extend(reversed(node.children))
if errors:
    print("\n".join(errors))
    raise SystemExit(1)
print(f"Swift syntax: {len(files)} files passed. Type checking / native linking not performed.")
