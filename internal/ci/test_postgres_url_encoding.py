#!/usr/bin/env python3
import sys
from pathlib import Path
from urllib.parse import quote_plus, unquote, urlsplit

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "internal/ci/lib"))
import tfconfig

ROOTS = (
    ("aws", ROOT / "platform/cloud/aws/cluster/outputs.tf"),
    ("gcp", ROOT / "platform/cloud/gcp/cluster/outputs.tf"),
)
ENCODER = 'replace(urlencode(var.db_password), "+", "%20")'
RAW = "${var.db_password}"
NASTY = "p@ss:w/rd?#%x y"
HOST = "db.example.test"


def postgres_url_value(path):
    for entry in tfconfig.load(path).get("output", []):
        for name, body in entry.items():
            if tfconfig.unquote(name) == "postgres_url":
                return body["value"]
    raise SystemExit(
        f"test_postgres_url_encoding: {path.relative_to(ROOT)} has no postgres_url output"
    )


def terraform_urlencode(value):
    return quote_plus(value).replace("+", "%20")


def intended(url):
    parts = urlsplit(url)
    return (parts.hostname, parts.path, unquote(parts.password or ""))


def main():
    problems = []
    for provider, path in ROOTS:
        value = postgres_url_value(path)
        where = path.relative_to(ROOT)
        if ENCODER not in value:
            problems.append(
                f"{where}: postgres_url must percent-encode var.db_password with {ENCODER}"
            )
        if RAW in value:
            problems.append(
                f"{where}: postgres_url interpolates the password raw ({RAW}), so a password "
                "containing @, :, /, ?, # or % changes the URL's meaning"
            )
        encoded = f"postgresql://postgres:{terraform_urlencode(NASTY)}@{HOST}:5432/app"
        if intended(encoded) != (HOST, "/app", NASTY):
            problems.append(
                f"{provider}: the encoder must round-trip a password containing @, :, /, ?, #, "
                "% and a space"
            )
        raw = f"postgresql://postgres:{NASTY}@{HOST}:5432/app"
        if intended(raw) == (HOST, "/app", NASTY):
            problems.append(
                f"{provider}: the unencoded form also parses to the intended target, so this "
                "check would not catch the defect"
            )
    if problems:
        for problem in problems:
            print(f"test_postgres_url_encoding: {problem}", file=sys.stderr)
        return 1
    print("test_postgres_url_encoding: both providers percent-encode POSTGRES_URL's password")
    return 0


if __name__ == "__main__":
    sys.exit(main())
