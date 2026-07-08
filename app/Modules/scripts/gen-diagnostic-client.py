#!/usr/bin/env python3
"""Regenerate API/Sources/Middleware/DiagnosticAPIClient.swift.

`DiagnosticAPIClient` is a transparent `APIProtocol` decorator: it forwards every
generated operation to a wrapped client through `DecodingDiagnostics.capture(...)`,
so a response-body decode failure (server/spec drift) is logged with its exact
coding path from ONE place — something a `ClientMiddleware` can't do, because the
typed-body decode happens after the middleware chain returns.

The decorator must mirror `APIProtocol`'s requirements 1:1, and that surface is
itself generated from `openapi.json` by swift-openapi-generator. Rather than
hand-maintain ~70 near-identical forwarding methods, this script reads the
generated `APIProtocol` and emits the wrapper. A stale wrapper simply fails to
compile against the protocol, so drift is caught at build time either way — this
just makes regeneration a one-liner.

Usage (run from the SPM package root, i.e. `Modules/`):

    swift build --target API          # ensure Types.swift is generated/fresh
    python3 scripts/gen-diagnostic-client.py

It locates the generated `Types.swift` under `.build`, extracts each
`func <name>(_ input: Operations.<X>.Input) async throws -> Operations.<X>.Output`
from the `public protocol APIProtocol` block, and rewrites the decorator.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Run from the package root (Modules/); everything below is relative to it.
PACKAGE_ROOT = Path(__file__).resolve().parent.parent
OUTPUT = PACKAGE_ROOT / "API/Sources/Middleware/DiagnosticAPIClient.swift"

# The generated protocol declaration we parse, e.g.
#   func getV1AccountsMe(_ input: Operations.GetV1AccountsMe.Input) async throws -> Operations.GetV1AccountsMe.Output
METHOD_RE = re.compile(
    r"func\s+(?P<name>\w+)\("
    r"_ input: Operations\.(?P<op>\w+)\.Input\)"
    r"\s+async throws\s+->\s+Operations\.\w+\.Output"
)

HEADER = """\
//
//  DiagnosticAPIClient.swift
//  API
//
//  A transparent `APIProtocol` decorator that routes EVERY generated operation
//  through `DecodingDiagnostics.capture`, so a response-body decode failure
//  (server/spec drift) is logged with its exact coding path from ONE place —
//  something a `ClientMiddleware` can't do (decode happens after middleware
//  returns). Call sites stay clean: `GameClient.make()` vends `any APIProtocol`,
//  so domain clients call operations exactly as before and this wrapper catches,
//  logs, and rethrows unchanged.
//
//  GENERATED, then committed: regenerate with `scripts/gen-diagnostic-client.py`
//  (or by hand) if the API surface changes — it mirrors `APIProtocol`'s
//  requirements 1:1, so a stale copy simply fails to compile against the protocol.
//

import OpenAPIRuntime

public struct DiagnosticAPIClient: APIProtocol {
    public let wrapped: any APIProtocol
    public init(wrapped: any APIProtocol) { self.wrapped = wrapped }
"""

METHOD_TEMPLATE = """\
    public func {name}(_ input: Operations.{op}.Input) async throws -> Operations.{op}.Output {{
        try await DecodingDiagnostics.capture("{name}") {{ try await wrapped.{name}(input) }}
    }}"""


def find_generated_types() -> Path:
    """Locate the swift-openapi-generator output for the API target."""
    matches = sorted(
        PACKAGE_ROOT.glob(
            ".build/**/API/**/OpenAPIGenerator/GeneratedSources/Types.swift"
        )
    )
    if not matches:
        sys.exit(
            "error: generated Types.swift not found under .build — run "
            "`swift build --target API` first."
        )
    return matches[0]


def extract_protocol_block(source: str) -> str:
    """Return the body of `public protocol APIProtocol { ... }`."""
    start = source.index("public protocol APIProtocol")
    brace = source.index("{", start)
    depth = 0
    for i in range(brace, len(source)):
        if source[i] == "{":
            depth += 1
        elif source[i] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1 : i]
    sys.exit("error: could not find the end of the APIProtocol declaration.")


def main() -> None:
    types = find_generated_types()
    block = extract_protocol_block(types.read_text())

    methods = [(m.group("name"), m.group("op")) for m in METHOD_RE.finditer(block)]
    if not methods:
        sys.exit("error: no operations parsed from APIProtocol — check the regex.")

    body = "\n".join(
        METHOD_TEMPLATE.format(name=name, op=op) for name, op in methods
    )
    OUTPUT.write_text(f"{HEADER}\n{body}\n}}\n")
    print(f"wrote {OUTPUT.relative_to(PACKAGE_ROOT)} ({len(methods)} operations)")


if __name__ == "__main__":
    main()
