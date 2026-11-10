//! SwiftTerm's ⌘F find bar, matched against the terminal's visible grid.
//!
//! SwiftTerm searches the emulator's own buffer, so a match spans the cells a
//! row really draws: wide (two-cell) characters occupy two columns and their
//! continuation cell is not text. Matching here works on the same cells the
//! renderer paints, so a highlight always covers exactly the matched glyphs.
//!
//! Only the visible page is searched. Core hands the UI one coherent page at a
//! time and never raw scrollback, so searching history would need another
//! engine query; SwiftTerm's own find is likewise limited to what it holds.
use serde_json::Value;

/// How many matches one query may report. A short query in a filled terminal
/// can match thousands of times; the bar counts matches, not a growing list.
pub(super) const MAX_HITS: usize = 2000;

/// One drawn row: its text, and the grid column each character starts at and
/// ends before.
#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Row {
    pub text: String,
    pub starts: Vec<usize>,
    pub ends: Vec<usize>,
}

/// One match, in grid columns so the renderer can highlight cells directly.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Hit {
    pub row: usize,
    pub start: usize,
    pub end: usize,
}

/// The visible grid as searchable rows. A trailing run of blanks is padding,
/// not text, and is trimmed like a terminal's own line copy.
pub(super) fn rows(grid: &Value) -> Vec<Row> {
    let mut out = Vec::new();
    let Some(rows) = grid.as_array() else {
        return out;
    };
    for cells in rows {
        let mut row = Row::default();
        let mut column = 0usize;
        if let Some(cells) = cells.as_array() {
            for (index, cell) in cells.iter().enumerate() {
                let width = cell["width"].as_u64().unwrap_or(1).clamp(1, 2) as usize;
                // The cell after a wide glyph is its right half, not text.
                if cell["continuation"] == true && index > 0 && cells[index - 1]["width"] == 2 {
                    continue;
                }
                let text = cell["text"].as_str().unwrap_or(" ");
                for ch in text.chars() {
                    row.text.push(ch);
                    row.starts.push(column);
                    // Every character of one cell shares that cell's edge, so
                    // a highlight still covers the whole glyph.
                    row.ends.push(column + width);
                }
                column += width;
            }
        }
        while row.text.ends_with(' ') {
            row.text.pop();
            row.starts.pop();
            row.ends.pop();
        }
        out.push(row);
    }
    out
}

/// Case-insensitive matches of `query`, in reading order.
pub(super) fn hits(rows: &[Row], query: &str) -> Vec<Hit> {
    let needle = query.chars().count();
    if needle == 0 {
        return Vec::new();
    }
    let mut out = Vec::new();
    for (row, line) in rows.iter().enumerate() {
        let haystack: Vec<char> = line.text.chars().collect();
        if haystack.len() < needle {
            continue;
        }
        for start in 0..=haystack.len() - needle {
            if !matches_at(&haystack, query, start) {
                continue;
            }
            out.push(Hit {
                row,
                start: line.starts[start],
                end: line.ends[start + needle - 1],
            });
            if out.len() >= MAX_HITS {
                return out;
            }
        }
    }
    out
}

/// Case folding is per character, so a match keeps a one-to-one column map.
fn matches_at(haystack: &[char], query: &str, start: usize) -> bool {
    query
        .chars()
        .zip(&haystack[start..])
        .all(|(a, b)| a.to_lowercase().eq(b.to_lowercase()))
}

/// The next match after `current`, wrapping at either end.
pub(super) fn step(hits: &[Hit], current: Option<usize>, forward: bool) -> Option<usize> {
    if hits.is_empty() {
        return None;
    }
    Some(match (current, forward) {
        (None, _) => 0,
        (Some(index), true) => (index + 1) % hits.len(),
        (Some(index), false) => (index + hits.len() - 1) % hits.len(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn cell(text: &str) -> Value {
        json!({"text": text, "width": 1})
    }
    fn wide(text: &str) -> Value {
        json!({"text": text, "width": 2})
    }
    fn continuation() -> Value {
        json!({"text": "", "width": 1, "continuation": true})
    }
    fn grid(rows: Vec<Vec<Value>>) -> Value {
        Value::Array(rows.into_iter().map(Value::Array).collect())
    }

    #[test]
    fn rows_trim_trailing_blank_padding() {
        let rows = rows(&grid(vec![vec![
            cell("h"),
            cell("i"),
            cell(" "),
            cell(" "),
        ]]));
        assert_eq!(rows[0].text, "hi");
        assert_eq!(rows[0].starts, vec![0, 1]);
        assert_eq!(rows[0].ends, vec![1, 2]);
    }

    #[test]
    fn wide_glyphs_keep_their_two_columns() {
        let rows = rows(&grid(vec![vec![wide("日"), continuation(), cell("x")]]));
        assert_eq!(rows[0].text, "日x");
        assert_eq!(rows[0].starts, vec![0, 2]);
        assert_eq!(rows[0].ends, vec![2, 3]);
    }

    #[test]
    fn matches_are_case_insensitive_and_keep_column_bounds() {
        let rows = rows(&grid(vec![vec![
            cell("E"),
            cell("r"),
            cell("r"),
            cell("o"),
            cell("r"),
        ]]));
        let hits = hits(&rows, "error");
        assert_eq!(
            hits,
            vec![Hit {
                row: 0,
                start: 0,
                end: 5
            }]
        );
    }

    #[test]
    fn every_occurrence_on_a_row_is_reported() {
        let rows = rows(&grid(vec![vec![
            cell("a"),
            cell("b"),
            cell("a"),
            cell("b"),
        ]]));
        assert_eq!(hits(&rows, "ab").len(), 2);
    }

    #[test]
    fn an_empty_query_matches_nothing() {
        let rows = rows(&grid(vec![vec![cell("a")]]));
        assert!(hits(&rows, "").is_empty());
    }

    #[test]
    fn a_query_longer_than_the_line_matches_nothing() {
        let rows = rows(&grid(vec![vec![cell("a")]]));
        assert!(hits(&rows, "ab").is_empty());
    }

    #[test]
    fn stepping_wraps_in_both_directions() {
        let hits = vec![
            Hit {
                row: 0,
                start: 0,
                end: 1,
            },
            Hit {
                row: 1,
                start: 0,
                end: 1,
            },
        ];
        assert_eq!(step(&hits, None, true), Some(0));
        assert_eq!(step(&hits, Some(1), true), Some(0));
        assert_eq!(step(&hits, Some(0), false), Some(1));
        assert_eq!(step(&[], None, true), None);
    }

    #[test]
    fn matches_never_exceed_the_reported_cap() {
        let line = (0..MAX_HITS + 10).map(|_| cell("a")).collect::<Vec<_>>();
        let rows = rows(&grid(vec![line]));
        assert_eq!(hits(&rows, "a").len(), MAX_HITS);
    }
}
