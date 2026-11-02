# DECISIONS

Agents record every non-obvious choice here instead of stopping to ask David. Newest entry at the top. Never edit an old entry; if a decision changes, add a new entry that supersedes it and link back.

David can overrule any entry by saying so in the project. The agent then adds a superseding entry and changes the code.

## Entry format

```
### D-NNN: <short title>
- Date: YYYY-MM-DD
- Status: accepted | superseded by D-NNN | reverted
- Phase: <PLAN.md phase>
- Context: why a choice was needed, in one or two sentences.
- Options: what was considered.
- Decision: what was chosen.
- Why: the reason, with evidence (a test, a doc link, a measurement).
- Reversible: yes/no, and what it would take to undo.
- PR: <link>
```

## Entries

### D-001: Drop labels
- Date: 2026-11-02
- Status: accepted
- Phase: 3, 4, 5
- Context: iCloud has no labels. The draft plan copied each labelled message into a `Labels/<name>` folder.
- Options: copy into label folders; keep one copy and write labels to an `X-Keywords` header; drop labels.
- Decision: drop labels. Skip Bridge's `Labels/*` mailboxes and create no label folders. Messages that are only in `All Mail` still go to `Unfiled`.
- Why: David asked for it in the project thread on 2026-11-02. It also avoids duplicates and saves iCloud space.
- Reversible: yes. Teach export to read `Labels/*` and re-run it; the store is resumable, so nothing already exported is fetched again.
- PR: https://github.com/Kex1016/slop-export/pull/1
