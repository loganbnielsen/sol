#!/usr/bin/env python3
"""Structural transaction evidence for the application qualification row.

The row establishes a worker effect by POSTing an operation and then reading the
service back until the effect is visible. The in-cluster HTTP path (a Job whose
log is captured) and the qualification-transport path (a port-forward) obtain
the same bodies, so whether the effect is established is the same semantic
question. This module owns that question for both:

  * an operation response must decode to a JSON object whose identity field is a
    nonempty string, and
  * a read-back must decode to the expected shape and contain an entry whose
    identity matches exactly and whose domain status is a success value.

Textual substring matching is deliberately not used. An empty identity is a
substring of every response, so it would read success out of nothing, and
alternate JSON formatting would change the answer for the same body. This
module never learns how a body was obtained, so sharing it between the two
paths does not share transport authority.

Usage (bodies are read from stdin):
    transaction.py charge-id
    transaction.py charge-effect CHARGE_ID
    transaction.py order-id
    transaction.py order-effect ORDER_ID
"""

from __future__ import annotations

import json
import sys

ORDER_SUCCESS_STATUSES = ("fulfilled", "confirmed")


class EvidenceError(Exception):
    """A response could not establish the property it was read for."""


def _decode(text: str, what: str) -> object:
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise EvidenceError(f"{what} is not JSON: {exc}") from exc


def _object(text: str, what: str) -> dict:
    value = _decode(text, what)
    if not isinstance(value, dict):
        raise EvidenceError(f"{what} is not a JSON object")
    return value


def _array(text: str, what: str) -> list:
    value = _decode(text, what)
    if not isinstance(value, list):
        raise EvidenceError(f"{what} is not a JSON array")
    return value


def _identity(body: dict, key: str, what: str) -> str:
    value = body.get(key)
    if not isinstance(value, str) or value == "":
        raise EvidenceError(f"{what} has no nonempty {key!r} string")
    return value


def charge_id(text: str) -> str:
    return _identity(_object(text, "the charge response"), "id", "the charge response")


def charge_effect_visible(text: str, charge_id: str) -> bool:
    rows = _array(text, "the notifications read-back")
    return any(isinstance(row, dict) and row.get("charge_id") == charge_id for row in rows)


def order_id(text: str) -> str:
    return _identity(_object(text, "the order response"), "order_id", "the order response")


def order_effect_visible(text: str, order_id: str) -> bool:
    order = _object(text, "the order read-back")
    if order.get("order_id") != order_id:
        return False
    status = order.get("status")
    return isinstance(status, str) and status in ORDER_SUCCESS_STATUSES


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    command = argv[1]
    text = sys.stdin.read()
    try:
        if command == "charge-id":
            print(charge_id(text))
            return 0
        if command == "order-id":
            print(order_id(text))
            return 0
        if command == "charge-effect" and len(argv) == 3:
            return 0 if charge_effect_visible(text, argv[2]) else 1
        if command == "order-effect" and len(argv) == 3:
            return 0 if order_effect_visible(text, argv[2]) else 1
    except EvidenceError as exc:
        print(f"transaction: {exc}", file=sys.stderr)
        return 2
    print(f"transaction: unknown command {argv[1:]!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
