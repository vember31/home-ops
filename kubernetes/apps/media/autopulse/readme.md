### Autopulse Row Cleanup ###

Run the following query in the autopulse postgres database to leave only the most recent 50 rows.

```
DELETE FROM scan_events
WHERE id NOT IN (
    SELECT id
    FROM scan_events
    ORDER BY event_timestamp DESC
    LIMIT 50
);
```