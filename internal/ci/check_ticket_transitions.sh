#!/usr/bin/env bash
set -euo pipefail

# Validate `git diff --cached --name-status` rows for internal/pipeline/tickets/.
# Ticket files may be created or edited on any PR branch. Deletion is only
# valid as one half of a same-ID state transition.
awk -F'\t' '
  function split_ticket(path, out,    rest, slash) {
    rest = path
    # The ticket root may be reached with or without the repo-internal prefix.
    sub(/^internal\//, "", rest)
    if (rest !~ /^pipeline\/tickets\//) return 0
    # Non-ticket files under the tree (e.g. .gitkeep) carry no state: ignore.
    if (rest !~ /^pipeline\/tickets\/(BACKLOG|READY_FOR_ENGINEERING|DONE)\/[^/]+\.md$/) return -1
    sub(/^pipeline\/tickets\//, "", rest)
    slash = index(rest, "/")
    out["state"] = substr(rest, 1, slash - 1)
    out["id"] = substr(rest, slash + 1)
    return 1
  }
  function transition_ok(from, to) {
    # A same-state rename (including moving the ticket root) is not a deletion.
    return (from == to) || (from == "BACKLOG" && to == "READY_FOR_ENGINEERING") || (from == "READY_FOR_ENGINEERING" && to == "BACKLOG") || (from == "READY_FOR_ENGINEERING" && to == "DONE") || (from == "DONE" && to == "READY_FOR_ENGINEERING")
  }
  /^$/ { next }
  /^R/ {
    delete old; delete new
    o = split_ticket($2, old); n = split_ticket($3, new)
    if (o == -1 || n == -1) next
    if (!o || !n || old["id"] != new["id"] || !transition_ok(old["state"], new["state"])) {
      print "  invalid ticket move: " $2 " -> " $3
      bad = 1
    }
    next
  }
  /^A/ {
    delete ticket
    r = split_ticket($2, ticket)
    if (r == -1) next
    if (!r) {
      print "  invalid ticket path: " $2
      bad = 1
    } else {
      added[ticket["id"]] = ticket["state"]
    }
    next
  }
  /^D/ {
    delete ticket
    r = split_ticket($2, ticket)
    if (r == -1) next
    if (!r) {
      print "  invalid ticket path: " $2
      bad = 1
    } else {
      removed[ticket["id"]] = ticket["state"]
    }
    next
  }
  /^M/ { next }
  {
    print "  unsupported ticket change: " $0
    bad = 1
  }
  END {
    for (id in removed) {
      if (!(id in added)) {
        print "  ticket deletion requires a state move: " id
        bad = 1
      } else if (!transition_ok(removed[id], added[id])) {
        print "  invalid ticket transition: " removed[id] "/" id " -> " added[id] "/" id
        bad = 1
      }
    }
    for (id in added) {
      if (added[id] == "DONE" && !(id in removed)) {
        print "  new tickets must start in BACKLOG or READY_FOR_ENGINEERING: " id
        bad = 1
      }
      if ((id in removed) && !transition_ok(removed[id], added[id])) bad = 1
    }
    exit bad
  }
'
