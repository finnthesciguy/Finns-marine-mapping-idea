"""How many selected cells were issued per week (from the catalog's isdt)."""
from __future__ import annotations

from datetime import date, timedelta


def weekly_issue_counts(cells, weeks: int, today: date) -> list[dict]:
    """Per ISO week (Mon-Sun), going back `weeks` weeks from `today`'s week:
    number of cells whose latest issue date (isdt) falls in that week, and
    their zipped size. isdt is the issue date of the newest edition or update
    of the cell, so a cell counts once, in the week of its latest change.
    """
    start_this = today - timedelta(days=today.weekday())
    rows = []
    for i in range(weeks):
        ws = start_this - timedelta(weeks=i)
        we = ws + timedelta(days=6)
        hit = [c for c in cells if c.isdt and ws.isoformat() <= c.isdt <= we.isoformat()]
        rows.append({
            "week_start": ws.isoformat(),
            "cells": len(hit),
            "zip_bytes": sum(c.zipfile_size for c in hit),
            "names": sorted(c.name for c in hit),
        })
    return rows
