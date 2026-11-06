use coincide_core::terminal::{
    SelectionMovement, TerminalPoint, move_selection_boundary, selected_text,
    selection_from_boundaries,
};
use serde_json::{Value, json};

fn point(row: usize, col: usize) -> TerminalPoint {
    TerminalPoint { row, col }
}
fn frame(lines: &[&str], cols: usize) -> Value {
    let grid=lines.iter().map(|line| {
        let mut cells=line.chars().map(|ch|json!({"text":ch.to_string(),"width":1,"continuation":false,"hidden":false,"wrapline":false})).collect::<Vec<_>>();
        cells.resize(cols,json!({"text":" ","width":1,"continuation":false,"hidden":false,"wrapline":false}));cells
    }).collect::<Vec<_>>();
    json!({"rows":lines.len(),"cols":cols,"rowOffset":0,"grid":grid,"revision":4})
}

#[test]
fn copy_uses_inclusive_cell_bounds_handles_reverse_drag_and_preserves_frame() {
    let mut value = frame(&["hello world", "second line"], 12);
    value["grid"][0][1]["bold"] = json!(true);
    value["grid"][0][1]["foreground"] = json!([255, 0, 0]);
    let original = value.clone();
    assert_eq!(
        selected_text(&value, point(0, 1), point(0, 4)).unwrap(),
        "ello"
    );
    assert_eq!(
        selected_text(&value, point(0, 4), point(0, 1)).unwrap(),
        "ello"
    );
    assert_eq!(
        selected_text(&value, point(0, 6), point(1, 5)).unwrap(),
        "world\nsecond"
    );
    assert_eq!(
        selected_text(&value, point(1, 5), point(0, 6)).unwrap(),
        "world\nsecond"
    );
    assert_eq!(value, original);
}

#[test]
fn wide_continuations_copy_one_glyph_and_combining_marks_remain_attached() {
    let mut value = frame(&["abcde"], 5);
    value["grid"][0][0] = json!({"text":"界","width":2,"continuation":false});
    value["grid"][0][1] = json!({"text":"","width":0,"continuation":true});
    value["grid"][0][2]["text"] = json!("e\u{301}");
    assert_eq!(
        selected_text(&value, point(0, 0), point(0, 0)).unwrap(),
        "界"
    );
    assert_eq!(
        selected_text(&value, point(0, 1), point(0, 1)).unwrap(),
        "界"
    );
    assert_eq!(
        selected_text(&value, point(0, 0), point(0, 2)).unwrap(),
        "界e\u{301}"
    );
    assert_eq!(
        selected_text(&value, point(0, 1), point(0, 2)).unwrap(),
        "界e\u{301}"
    );
}

#[test]
fn soft_wrap_joins_rows_while_hard_lines_trim_only_terminal_padding() {
    let mut value = frame(&["abcde", "fg  ", "xyz"], 5);
    value["grid"][0][4]["wrapline"] = json!(true);
    assert_eq!(
        selected_text(&value, point(0, 0), point(2, 4)).unwrap(),
        "abcdefg\nxyz"
    );
    // Explicitly selecting spaces before the final column preserves them.
    assert_eq!(
        selected_text(&value, point(1, 0), point(1, 3)).unwrap(),
        "fg  "
    );
    value["grid"][0][4]["wrapline"] = json!(false);
    assert_eq!(
        selected_text(&value, point(0, 0), point(1, 1)).unwrap(),
        "abcde\nfg"
    );
}

#[test]
fn concealed_cells_never_reveal_their_text_and_controls_are_rejected() {
    let mut value = frame(&["visible"], 7);
    value["grid"][0][1]["text"] = json!("secret");
    value["grid"][0][1]["hidden"] = json!(true);
    assert_eq!(
        selected_text(&value, point(0, 0), point(0, 2)).unwrap(),
        "v s"
    );
    value["grid"][0][2]["text"] = json!("\u{1b}");
    assert!(selected_text(&value, point(0, 0), point(0, 2)).is_err());
}

#[test]
fn displayed_page_bounds_and_malformed_cells_fail_closed() {
    let mut value = frame(&["page one", "page two"], 8);
    value["rowOffset"] = json!(10);
    value["rows"] = json!(24);
    assert_eq!(
        selected_text(&value, point(10, 0), point(11, 7)).unwrap(),
        "page one\npage two"
    );
    for (start, end) in [
        (point(9, 0), point(10, 0)),
        (point(10, 0), point(12, 0)),
        (point(10, 8), point(10, 8)),
        (point(usize::MAX, 0), point(10, 0)),
    ] {
        assert!(selected_text(&value, start, end).is_err());
    }
    value["grid"][0][0]["width"] = json!(900);
    assert!(selected_text(&value, point(10, 0), point(10, 1)).is_err());
    value["grid"][0][0]["width"] = json!(1);
    value["grid"][0][0]["text"] = json!("x".repeat(18));
    assert!(selected_text(&value, point(10, 0), point(10, 1)).is_err());
    value["grid"][0] = json!([]);
    assert!(selected_text(&value, point(10, 0), point(10, 1)).is_err());
}

#[test]
fn copy_size_is_bounded_even_for_maximum_combining_cells() {
    let text = format!("x{}", "\u{1d185}".repeat(16));
    let cell = json!({"text":text,"width":1,"continuation":false,"hidden":false,"wrapline":true});
    let value =
        json!({"rows":40,"cols":500,"rowOffset":0,"grid":vec![vec![cell;500];40],"revision":1});
    assert!(
        selected_text(&value, point(0, 0), point(39, 499))
            .unwrap_err()
            .to_string()
            .contains("1 MiB")
    );
}

#[test]
fn keyboard_shift_arrows_use_exclusive_boundaries_not_inclusive_cursor_cells() {
    let value = frame(&["abc def"], 8);
    let left = move_selection_boundary(3, SelectionMovement::Left, 1, 8).unwrap();
    let (start, end) = selection_from_boundaries(3, left, 0, 1, 8)
        .unwrap()
        .unwrap();
    assert_eq!(selected_text(&value, start, end).unwrap(), "c");
    let right = move_selection_boundary(1, SelectionMovement::Right, 1, 8).unwrap();
    let (start, end) = selection_from_boundaries(1, right, 0, 1, 8)
        .unwrap()
        .unwrap();
    assert_eq!(selected_text(&value, start, end).unwrap(), "b");
    let reversed = move_selection_boundary(left, SelectionMovement::Right, 1, 8).unwrap();
    assert!(
        selection_from_boundaries(3, reversed, 0, 1, 8)
            .unwrap()
            .is_none()
    );
    assert_eq!(
        move_selection_boundary(0, SelectionMovement::Left, 1, 8).unwrap(),
        0
    );
    assert_eq!(
        move_selection_boundary(8, SelectionMovement::Right, 1, 8).unwrap(),
        8
    );
}

#[test]
fn keyboard_boundaries_cross_rows_and_respect_page_home_end_limits() {
    let mut value = frame(&["abcdefgh", "ijklmnop"], 8);
    value["rows"] = json!(24);
    value["rowOffset"] = json!(10);
    let left = move_selection_boundary(8, SelectionMovement::Left, 2, 8).unwrap();
    let (start, end) = selection_from_boundaries(8, left, 10, 2, 8)
        .unwrap()
        .unwrap();
    assert_eq!((start, end), (point(10, 7), point(10, 7)));
    assert_eq!(selected_text(&value, start, end).unwrap(), "h");
    assert_eq!(
        move_selection_boundary(11, SelectionMovement::Home, 2, 8).unwrap(),
        8
    );
    assert_eq!(
        move_selection_boundary(11, SelectionMovement::End, 2, 8).unwrap(),
        16
    );
    assert_eq!(
        move_selection_boundary(16, SelectionMovement::Home, 2, 8).unwrap(),
        8
    );
    assert_eq!(
        move_selection_boundary(11, SelectionMovement::Up, 2, 8).unwrap(),
        3
    );
    assert_eq!(
        move_selection_boundary(11, SelectionMovement::Down, 2, 8).unwrap(),
        16
    );
    assert!(selection_from_boundaries(0, 17, 10, 2, 8).is_err());
    assert!(selection_from_boundaries(0, 1, usize::MAX, 2, 8).is_err());
}
