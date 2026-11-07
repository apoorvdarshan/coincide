//! The Diff inspector's document, after Swift's DiffDocumentView: a virtualized,
//! line-numbered diff of several files, unified or side by side. Gutters, headers
//! and notes stay at the visible left edge while text scrolls sideways; the file
//! at the top keeps a floating header that the next file's header pushes away.
use super::DiffPanel;
use coincide_core::workspace_diff::{
    ChangeStatus, DiffLine, FileDiff, GitDiff, LineKind, MAX_DRAWN_LENGTH, Presentation, SplitLine,
};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    component::{
        ActiveTheme as _, Icon,
        scroll::{ScrollableMask, Scrollbar},
        tooltip::Tooltip,
    },
    *,
};
use std::{
    collections::{BTreeSet, HashSet},
    ops::Range,
    rc::Rc,
    sync::Arc,
};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum DiffLayout {
    #[default]
    Unified,
    SideBySide,
}

impl DiffLayout {
    pub(crate) const ALL: [Self; 2] = [Self::Unified, Self::SideBySide];
    pub(crate) fn title(self) -> &'static str {
        match self {
            Self::Unified => "Unified Diff",
            Self::SideBySide => "Side-by-Side Diff",
        }
    }
    /// Swift's `UIState.diffLayout` raw values.
    pub(crate) fn setting(self) -> &'static str {
        match self {
            Self::Unified => "unified",
            Self::SideBySide => "sideBySide",
        }
    }
    pub(crate) fn from_setting(value: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|layout| layout.setting() == value)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum Side {
    Before,
    #[default]
    After,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum Note {
    Binary,
    Unchanged,
    NotLoaded,
}

/// One row of the document.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub(crate) enum Row {
    File(usize),
    Hunk {
        file: usize,
        hunk: usize,
    },
    Line {
        file: usize,
        hunk: usize,
        line: usize,
    },
    Split {
        file: usize,
        hunk: usize,
        pair: SplitLine,
    },
    Note {
        file: usize,
        note: Note,
    },
}

impl Row {
    pub(crate) fn file(&self) -> usize {
        match *self {
            Self::File(file)
            | Self::Hunk { file, .. }
            | Self::Line { file, .. }
            | Self::Split { file, .. }
            | Self::Note { file, .. } => file,
        }
    }
}

/// Rows for the diff, and the row of each file's header.
pub(crate) fn build_rows(
    diff: &GitDiff,
    presentation: &Presentation,
    collapsed: &HashSet<String>,
    layout: DiffLayout,
) -> (Vec<Row>, Vec<usize>) {
    let mut rows = Vec::new();
    let mut file_rows = Vec::with_capacity(diff.files.len());
    for (file_index, file) in diff.files.iter().enumerate() {
        file_rows.push(rows.len());
        rows.push(Row::File(file_index));
        if collapsed.contains(&file.path) {
            continue;
        }
        if file.is_binary {
            rows.push(Row::Note {
                file: file_index,
                note: Note::Binary,
            });
        } else if file.hunks.is_empty() {
            rows.push(Row::Note {
                file: file_index,
                note: if file.additions + file.deletions > 0 {
                    Note::NotLoaded
                } else {
                    Note::Unchanged
                },
            });
        } else {
            for (hunk_index, hunk) in file.hunks.iter().enumerate() {
                rows.push(Row::Hunk {
                    file: file_index,
                    hunk: hunk_index,
                });
                if layout == DiffLayout::SideBySide {
                    let aligned = presentation
                        .split_lines
                        .get(file_index)
                        .and_then(|hunks| hunks.get(hunk_index))
                        .cloned()
                        .unwrap_or_else(|| coincide_core::workspace_diff::align(&hunk.lines));
                    rows.extend(aligned.into_iter().map(|pair| Row::Split {
                        file: file_index,
                        hunk: hunk_index,
                        pair,
                    }));
                } else {
                    rows.extend((0..hunk.lines.len()).map(|line| Row::Line {
                        file: file_index,
                        hunk: hunk_index,
                        line,
                    }));
                }
            }
        }
    }
    (rows, file_rows)
}

pub(crate) fn note_text(note: Note, file: &FileDiff) -> String {
    match note {
        Note::Binary => "Binary file not shown.".into(),
        Note::NotLoaded => "The diff for this file is too large to show.".into(),
        Note::Unchanged => {
            if let Some(mode) = &file.mode_change {
                format!("File mode changed: {mode}")
            } else if file.status == ChangeStatus::Renamed {
                "Renamed without content changes.".into()
            } else {
                "No content changes.".into()
            }
        }
    }
}

/// Fonts and sizes shared by every row.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct Metrics {
    pub font: Pixels,
    pub number_font: Pixels,
    pub char_width: Pixels,
    pub text_height: Pixels,
    pub line_height: Pixels,
    pub number_column: Pixels,
    pub marker: Pixels,
}

impl Metrics {
    /// `char_width` and `number_char_width` are the measured advances of `0`.
    pub(crate) fn new(
        font_size: f32,
        max_line_number: usize,
        char_width: f32,
        number_char_width: f32,
    ) -> Self {
        let font = (font_size - 1.).max(9.);
        let number_font = (font_size - 2.).max(8.);
        let text_height = (font * 1.25).ceil();
        let digits = max_line_number.to_string().len().max(3) as f32;
        Self {
            font: px(font),
            number_font: px(number_font),
            char_width: px(char_width),
            text_height: px(text_height),
            line_height: px(text_height + 4.),
            number_column: px((digits * number_char_width).ceil() + 14.),
            marker: px(char_width.ceil() + 10.),
        }
    }
    pub(crate) fn gutter(&self) -> Pixels {
        self.number_column * 2. + self.marker
    }
    pub(crate) fn single_gutter(&self) -> Pixels {
        self.number_column + self.marker
    }
    pub(crate) fn text_origin(&self) -> Pixels {
        self.gutter() + px(4.)
    }
    pub(crate) fn file_header_height(&self) -> Pixels {
        (self.text_height + px(14.)).max(px(30.))
    }
    pub(crate) fn hunk_height(&self) -> Pixels {
        self.line_height + px(6.)
    }
    pub(crate) fn note_height(&self) -> Pixels {
        self.line_height + px(14.)
    }
    pub(crate) fn row_height(&self, row: &Row) -> Pixels {
        match row {
            Row::File(_) => self.file_header_height(),
            Row::Hunk { .. } => self.hunk_height(),
            Row::Line { .. } | Row::Split { .. } => self.line_height,
            Row::Note { .. } => self.note_height(),
        }
    }
    pub(crate) fn content_width(&self, columns: usize) -> Pixels {
        self.text_origin() + self.char_width * columns as f32 + px(32.)
    }
    /// Width of the scrolled content: one scroller moves every text column, and each
    /// side-by-side half stays pinned within the viewport.
    pub(crate) fn scroll_width(
        &self,
        layout: DiffLayout,
        columns: usize,
        viewport: Pixels,
    ) -> Pixels {
        let content = self.content_width(columns);
        match layout {
            DiffLayout::Unified => content.max(viewport),
            DiffLayout::SideBySide => {
                viewport + (content - self.number_column - viewport / 2.).max(px(0.))
            }
        }
    }
}

/// A line as drawn: tabs expanded to four-column stops and very long lines cut,
/// with the highlight's byte range moved to match.
pub(crate) fn display_text(
    text: &str,
    highlight: Option<Range<usize>>,
) -> (String, Option<Range<usize>>) {
    let mut out = String::with_capacity(text.len().min(MAX_DRAWN_LENGTH * 4));
    let mut column = 0;
    let mut start = None;
    let mut end = None;
    let mut cut = false;
    for (count, (offset, ch)) in text.char_indices().enumerate() {
        if count == MAX_DRAWN_LENGTH {
            cut = true;
            break;
        }
        if let Some(range) = &highlight {
            if offset == range.start {
                start = Some(out.len());
            }
            if offset == range.end {
                end = Some(out.len());
            }
        }
        if ch == '\t' {
            let spaces = 4 - column % 4;
            out.extend(std::iter::repeat_n(' ', spaces));
            column += spaces;
        } else {
            out.push(ch);
            column += 1;
        }
    }
    if let Some(range) = &highlight
        && range.end >= text.len()
        && !cut
    {
        end = Some(out.len());
    }
    if start.is_none()
        && highlight
            .as_ref()
            .is_some_and(|range| range.start >= text.len())
        && !cut
    {
        start = Some(out.len());
    }
    if cut {
        out.push_str(" …");
    }
    let range = match (start, end) {
        (Some(start), Some(end)) if start < end => Some(start..end),
        (Some(start), None) if cut => Some(start..out.len() - " …".len()),
        _ => None,
    };
    (out, range)
}

/// Where the top of the view was, by file and row, so a reload keeps it.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Anchor {
    pub path: String,
    pub row: Row,
    pub offset: Pixels,
}

pub(crate) fn anchor(diff: &GitDiff, rows: &[Row], top: ListOffset) -> Option<Anchor> {
    let row = *rows.get(top.item_ix)?;
    Some(Anchor {
        path: diff.files.get(row.file())?.path.clone(),
        row,
        offset: top.offset_in_item,
    })
}

/// The row matching `anchor` in rebuilt rows: the same hunk line, paired across layouts.
pub(crate) fn restore(
    diff: &GitDiff,
    rows: &[Row],
    file_rows: &[usize],
    anchor: &Anchor,
    side: Side,
) -> ListOffset {
    let Some(index) = diff.files.iter().position(|file| file.path == anchor.path) else {
        return ListOffset::default();
    };
    let target = rows.iter().position(|candidate| {
        candidate.file() == index
            && match (anchor.row, *candidate) {
                (Row::File(_), Row::File(_)) => true,
                (Row::Hunk { hunk: a, .. }, Row::Hunk { hunk: b, .. }) => a == b,
                (Row::Line { hunk: a, line, .. }, Row::Split { hunk: b, pair, .. }) => {
                    a == b && (pair.before == Some(line) || pair.after == Some(line))
                }
                (Row::Split { hunk: a, pair, .. }, Row::Line { hunk: b, line, .. }) => {
                    let wanted = match side {
                        Side::Before => pair.before.or(pair.after),
                        Side::After => pair.after.or(pair.before),
                    };
                    a == b && wanted == Some(line)
                }
                (
                    Row::Line {
                        hunk: a, line: x, ..
                    },
                    Row::Line {
                        hunk: b, line: y, ..
                    },
                ) => a == b && x == y,
                (
                    Row::Split {
                        hunk: a, pair: x, ..
                    },
                    Row::Split {
                        hunk: b, pair: y, ..
                    },
                ) => a == b && x == y,
                (Row::Note { .. }, Row::Note { .. }) => true,
                _ => false,
            }
    });
    match target {
        Some(item_ix) => ListOffset {
            item_ix,
            offset_in_item: anchor.offset,
        },
        None => ListOffset {
            item_ix: file_rows.get(index).copied().unwrap_or(0),
            offset_in_item: px(0.),
        },
    }
}

/// The floating header at the top: the top row's file, unless its own header sits
/// exactly at the top, raised by the next header as it arrives.
pub(crate) fn floating_header(
    rows: &[Row],
    file_rows: &[usize],
    metrics: &Metrics,
    top: ListOffset,
) -> Option<(usize, Pixels)> {
    let row = rows.get(top.item_ix)?;
    if matches!(row, Row::File(_)) && top.offset_in_item <= px(0.) {
        return None;
    }
    let file = row.file();
    let height = metrics.file_header_height();
    let Some(&next) = file_rows.get(file + 1) else {
        return Some((file, px(0.)));
    };
    let mut distance = -top.offset_in_item;
    for row in &rows[top.item_ix..next] {
        distance += metrics.row_height(row);
        if distance >= height {
            return Some((file, px(0.)));
        }
    }
    Some((file, (distance - height).min(px(0.))))
}

/// The selected lines' text, in row order, without end-of-file markers.
pub(crate) fn selected_text(
    diff: &GitDiff,
    rows: &[Row],
    selected: &BTreeSet<usize>,
    side: Side,
) -> String {
    selected
        .iter()
        .filter_map(|&index| source_line(diff, rows.get(index)?, side))
        .filter(|line| line.kind != LineKind::NoNewline)
        .map(|line| line.text.as_str())
        .collect::<Vec<_>>()
        .join("\n")
}

fn source_line<'a>(diff: &'a GitDiff, row: &Row, side: Side) -> Option<&'a DiffLine> {
    let (file, hunk, line) = match *row {
        Row::Line { file, hunk, line } => (file, hunk, line),
        Row::Split { file, hunk, pair } => (
            file,
            hunk,
            match side {
                Side::Before => pair.before?,
                Side::After => pair.after?,
            },
        ),
        _ => return None,
    };
    diff.files.get(file)?.hunks.get(hunk)?.lines.get(line)
}

fn selectable(row: &Row) -> bool {
    matches!(row, Row::Line { .. } | Row::Split { .. })
}

/// Retained presentation state for the shown diff.
pub(crate) struct Document {
    pub diff: Arc<GitDiff>,
    pub presentation: Arc<Presentation>,
    pub rows: Rc<Vec<Row>>,
    pub file_rows: Vec<usize>,
    pub collapsed: HashSet<String>,
    pub layout: DiffLayout,
    pub list: ListState,
    pub horizontal: ScrollHandle,
    pub selected: BTreeSet<usize>,
    selection_anchor: Option<usize>,
    pub side: Side,
    pub focus: FocusHandle,
    pub viewport: Size<Pixels>,
    pub metrics: Option<Metrics>,
}

impl Document {
    pub(crate) fn new(layout: DiffLayout, cx: &mut App) -> Self {
        Self {
            diff: Arc::default(),
            presentation: Arc::default(),
            rows: Rc::default(),
            file_rows: Vec::new(),
            collapsed: HashSet::new(),
            layout,
            list: ListState::new(0, ListAlignment::Top, px(200.)),
            horizontal: ScrollHandle::new(),
            selected: BTreeSet::new(),
            selection_anchor: None,
            side: Side::After,
            focus: cx.focus_handle().tab_stop(true),
            viewport: Size::default(),
            metrics: None,
        }
    }

    fn top(&self) -> ListOffset {
        self.list.logical_scroll_top()
    }

    /// The file whose rows are at the top of the view.
    pub(crate) fn visible_file(&self) -> Option<usize> {
        self.rows.get(self.top().item_ix).map(Row::file)
    }

    /// Shows a new diff. With `keep_position`, the row at the top stays where it was.
    pub(crate) fn show(
        &mut self,
        diff: Arc<GitDiff>,
        presentation: Arc<Presentation>,
        keep_position: bool,
    ) {
        let anchor = keep_position
            .then(|| anchor(&self.diff, &self.rows, self.top()))
            .flatten();
        let paths: HashSet<&str> = diff.files.iter().map(|file| file.path.as_str()).collect();
        self.collapsed.retain(|path| paths.contains(path.as_str()));
        self.diff = diff;
        self.presentation = presentation;
        self.rebuild(anchor);
    }

    pub(crate) fn clear(&mut self) {
        self.diff = Arc::default();
        self.presentation = Arc::default();
        self.rebuild(None);
    }

    fn rebuild(&mut self, anchor: Option<Anchor>) {
        let (rows, file_rows) =
            build_rows(&self.diff, &self.presentation, &self.collapsed, self.layout);
        self.rows = Rc::new(rows);
        self.file_rows = file_rows;
        self.selected.clear();
        self.selection_anchor = None;
        match self.metrics {
            Some(metrics) => self
                .list
                .reset_with_uniform_height(self.rows.len(), metrics.line_height),
            None => self.list.reset(self.rows.len()),
        }
        let offset = anchor
            .map(|anchor| restore(&self.diff, &self.rows, &self.file_rows, &anchor, self.side))
            .unwrap_or_default();
        self.list.scroll_to(offset);
    }

    pub(crate) fn set_layout(&mut self, layout: DiffLayout) {
        if layout == self.layout {
            return;
        }
        let anchor = anchor(&self.diff, &self.rows, self.top());
        self.layout = layout;
        self.rebuild(anchor);
        self.horizontal.set_offset(point(px(0.), px(0.)));
    }

    /// Collapses or expands a file, keeping its header where it was on screen.
    pub(crate) fn toggle(&mut self, file: usize) {
        let Some(path) = self.diff.files.get(file).map(|file| file.path.clone()) else {
            return;
        };
        let top = self.top();
        let header = self.file_rows[file];
        if !self.collapsed.remove(&path) {
            self.collapsed.insert(path);
        }
        let floating =
            top.item_ix > header && self.rows.get(top.item_ix).map(Row::file) == Some(file);
        self.rebuild(None);
        // Rows above the header are unchanged, so the top stays; a floating header
        // returns to the top of the view with its file.
        self.list.scroll_to(if floating {
            ListOffset {
                item_ix: header,
                offset_in_item: px(0.),
            }
        } else {
            top
        });
    }

    pub(crate) fn all_collapsed(&self) -> bool {
        !self.diff.files.is_empty() && self.collapsed.len() == self.diff.files.len()
    }

    pub(crate) fn set_all_collapsed(&mut self, collapsed: bool) {
        self.collapsed = if collapsed {
            self.diff
                .files
                .iter()
                .map(|file| file.path.clone())
                .collect()
        } else {
            HashSet::new()
        };
        self.rebuild(None);
    }

    pub(crate) fn scroll_to_file(&mut self, file: usize) {
        if let Some(&item_ix) = self.file_rows.get(file) {
            self.list.scroll_to(ListOffset {
                item_ix,
                offset_in_item: px(0.),
            });
        }
    }

    /// Row selection like a table: click, Shift-click extends, Command/Control-click toggles.
    pub(crate) fn click(&mut self, row: usize, extend: bool, toggle: bool, side: Option<Side>) {
        if !self.rows.get(row).is_some_and(selectable) {
            return;
        }
        if let Some(side) = side {
            self.side = side;
        }
        if extend && let Some(anchor) = self.selection_anchor {
            let (start, end) = (anchor.min(row), anchor.max(row));
            self.selected = (start..=end)
                .filter(|index| self.rows.get(*index).is_some_and(selectable))
                .collect();
        } else if toggle {
            if !self.selected.remove(&row) {
                self.selected.insert(row);
            }
            self.selection_anchor = Some(row);
        } else {
            self.selected = BTreeSet::from([row]);
            self.selection_anchor = Some(row);
        }
    }

    pub(crate) fn selected_text(&self) -> String {
        selected_text(&self.diff, &self.rows, &self.selected, self.side)
    }
}

/// Diff colors from the theme, so they follow light and dark appearances.
#[derive(Clone, Copy)]
struct Colors {
    background: Hsla,
    foreground: Hsla,
    secondary: Hsla,
    tertiary: Hsla,
    separator: Hsla,
    selection: Hsla,
    addition: Hsla,
    deletion: Hsla,
    renamed: Hsla,
    modified: Hsla,
    hunk: Hsla,
    header: Hsla,
    context_gutter: Hsla,
}

impl Colors {
    fn new(cx: &App) -> Self {
        let theme = cx.theme();
        Self {
            background: theme.background,
            foreground: theme.foreground,
            secondary: theme.muted_foreground,
            tertiary: theme.muted_foreground.opacity(0.65),
            separator: theme.border,
            selection: theme.list_active,
            addition: theme.success,
            deletion: theme.danger,
            renamed: theme.info,
            modified: theme.warning,
            hunk: theme.info.alpha(0.08),
            header: theme.background.blend(theme.foreground.alpha(0.035)),
            context_gutter: theme.foreground.alpha(0.035),
        }
    }
    fn status(&self, status: ChangeStatus) -> Hsla {
        match status {
            ChangeStatus::Added | ChangeStatus::Untracked => self.addition,
            ChangeStatus::Modified => self.modified,
            ChangeStatus::Deleted => self.deletion,
            ChangeStatus::Renamed => self.renamed,
        }
    }
}

/// What each row's renderer needs, shared by the virtualized list for one frame.
struct Frame {
    diff: Arc<GitDiff>,
    presentation: Arc<Presentation>,
    rows: Rc<Vec<Row>>,
    collapsed: HashSet<String>,
    selected: BTreeSet<usize>,
    side: Side,
    metrics: Metrics,
    colors: Colors,
    mono: SharedString,
    horizontal: ScrollHandle,
    viewport: Pixels,
    content_width: Pixels,
    panel: WeakEntity<DiffPanel>,
}

impl Frame {
    /// How far the text has scrolled sideways.
    fn scrolled(&self) -> Pixels {
        (-self.horizontal.offset().x).max(px(0.))
    }
}

/// `dir/` in secondary color followed by the file name, and the old name after a rename.
pub(crate) fn path_label(
    path: &str,
    old_path: Option<&str>,
    size: Pixels,
    foreground: Hsla,
    secondary: Hsla,
    tertiary: Hsla,
) -> Div {
    let (directory, name) = match path.rfind('/') {
        Some(index) => (&path[..=index], &path[index + 1..]),
        None => ("", path),
    };
    div()
        .flex()
        .items_center()
        .min_w_0()
        .overflow_hidden()
        .text_size(size)
        .whitespace_nowrap()
        .when(!directory.is_empty(), |view| {
            view.child(
                div()
                    .min_w_0()
                    .flex_shrink(1.)
                    .truncate()
                    .text_color(secondary)
                    .child(directory.to_owned()),
            )
        })
        .child(
            div()
                .flex_shrink_0()
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(foreground)
                .child(name.to_owned()),
        )
        .when_some(old_path.filter(|old| *old != path), |view, old| {
            let old_name = old.rsplit('/').next().unwrap_or(old);
            view.child(
                div()
                    .min_w_0()
                    .truncate()
                    .text_color(tertiary)
                    .child(format!("  ← {old_name}")),
            )
        })
}

/// `+a −d`, or `Binary`.
pub(crate) fn counts(
    file: &FileDiff,
    size: Pixels,
    addition: Hsla,
    deletion: Hsla,
    secondary: Hsla,
    gap: &str,
) -> Div {
    let view = div()
        .flex()
        .flex_shrink_0()
        .whitespace_nowrap()
        .text_size(size)
        .font_weight(FontWeight::MEDIUM);
    if file.is_binary {
        view.text_color(secondary).child("Binary")
    } else {
        view.child(
            div()
                .text_color(addition)
                .child(format!("+{}", file.additions)),
        )
        .child(gap.to_owned())
        .child(
            div()
                .text_color(deletion)
                .child(format!("−{}", file.deletions)),
        )
    }
}

pub(crate) fn status_badge(status: ChangeStatus, color: Hsla, size: Pixels) -> Div {
    div()
        .flex_shrink_0()
        .size(px(16.))
        .rounded(px(4.))
        .bg(color.alpha(0.16))
        .flex()
        .items_center()
        .justify_center()
        .text_size(size)
        .font_weight(FontWeight::BOLD)
        .text_color(color)
        .child(status.letter())
}

fn header_label(file: &FileDiff, collapsed: bool) -> String {
    format!(
        "{}, {}, {} added, {} removed, {}",
        file.path,
        file.status.name(),
        file.additions,
        file.deletions,
        if collapsed { "collapsed" } else { "expanded" }
    )
}

fn render_header(frame: &Frame, file_index: usize, left: Pixels, floating: bool) -> AnyElement {
    let file = &frame.diff.files[file_index];
    let collapsed = frame.collapsed.contains(&file.path);
    let colors = frame.colors;
    let size = frame.metrics.font + px(1.);
    let panel = frame.panel.clone();
    let tooltip = match &file.old_path {
        Some(old) => format!("{old} → {}", file.path),
        None => file.path.clone(),
    };
    div()
        .id(if floating {
            ElementId::from(SharedString::from("diff-floating-header"))
        } else {
            ElementId::named_usize("diff-file-header", file_index)
        })
        .relative()
        .w(if floating {
            frame.viewport
        } else {
            frame.content_width
        })
        .h(frame.metrics.file_header_height())
        .bg(colors.header)
        .border_t_1()
        .border_b_1()
        .border_color(colors.separator)
        .cursor_pointer()
        .role(Role::Button)
        .aria_label(header_label(file, collapsed))
        .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
        .on_click(move |_, _, cx| {
            let _ = panel.update(cx, |panel, cx| panel.toggle_file(file_index, cx));
        })
        .child(
            div()
                .absolute()
                .top_0()
                .bottom_0()
                .left(left)
                .w(frame.viewport)
                .px(px(10.))
                .flex()
                .items_center()
                .gap(px(8.))
                .child(
                    Icon::new(if collapsed {
                        gpui_kit::assets::IconName::ChevronRight
                    } else {
                        gpui_kit::assets::IconName::ChevronDown
                    })
                    .size(px(10.))
                    .text_color(colors.secondary),
                )
                .child(status_badge(
                    file.status,
                    colors.status(file.status),
                    (frame.metrics.font - px(2.)).max(px(9.)),
                ))
                .child(div().flex_1().min_w_0().child(path_label(
                    &file.path,
                    file.old_path.as_deref(),
                    size - px(1.),
                    colors.foreground,
                    colors.secondary,
                    colors.tertiary,
                )))
                .child(counts(
                    file,
                    size - px(2.),
                    colors.addition,
                    colors.deletion,
                    colors.secondary,
                    "  ",
                )),
        )
        .into_any_element()
}

fn text_element(frame: &Frame, line: &DiffLine, highlight: Option<Range<usize>>, x: Pixels) -> Div {
    let colors = frame.colors;
    let (text, color, highlight) = if line.kind == LineKind::NoNewline {
        (
            "No newline at end of file".to_owned(),
            colors.tertiary,
            None,
        )
    } else {
        let (text, range) = display_text(&line.text, highlight);
        (text, colors.foreground, range)
    };
    let tint = if line.kind == LineKind::Addition {
        colors.addition.alpha(0.38)
    } else {
        colors.deletion.alpha(0.38)
    };
    let styled = StyledText::new(text).with_highlights(highlight.map(|range| {
        (
            range,
            HighlightStyle {
                background_color: Some(tint),
                ..HighlightStyle::default()
            },
        )
    }));
    div()
        .absolute()
        .left(x)
        .top((frame.metrics.line_height - frame.metrics.text_height) / 2.)
        .h(frame.metrics.text_height)
        .whitespace_nowrap()
        .font_family(frame.mono.clone())
        .text_size(frame.metrics.font)
        .line_height(frame.metrics.text_height)
        .text_color(color)
        .child(styled)
}

fn line_tint(
    colors: &Colors,
    kind: Option<LineKind>,
) -> (Option<Hsla>, Hsla, Option<(&'static str, Hsla)>) {
    match kind {
        Some(LineKind::Addition) => (
            Some(colors.addition.alpha(0.16)),
            colors.addition.alpha(0.24),
            Some(("+", colors.addition)),
        ),
        Some(LineKind::Deletion) => (
            Some(colors.deletion.alpha(0.16)),
            colors.deletion.alpha(0.24),
            Some(("−", colors.deletion)),
        ),
        Some(LineKind::Context | LineKind::NoNewline) => (None, colors.context_gutter, None),
        // A spacer opposite an unpaired line.
        None => (Some(colors.header), colors.context_gutter, None),
    }
}

/// The pinned gutter: line numbers, then the `+`/`−` marker.
fn gutter(
    frame: &Frame,
    numbers: &[Option<usize>],
    marker: Option<(&'static str, Hsla)>,
    tint: Hsla,
    left: Pixels,
) -> Div {
    let metrics = frame.metrics;
    let width = metrics.number_column * numbers.len() as f32 + metrics.marker;
    let mut view = div()
        .absolute()
        .top_0()
        .bottom_0()
        .left(left)
        .w(width)
        .bg(frame.colors.background)
        .font_family(frame.mono.clone())
        .child(div().absolute().inset_0().bg(tint));
    for (column, number) in numbers.iter().enumerate() {
        if let Some(number) = number {
            view = view.child(
                div()
                    .absolute()
                    .top_0()
                    .bottom_0()
                    .left(metrics.number_column * column as f32)
                    .w(metrics.number_column - px(7.))
                    .flex()
                    .items_center()
                    .justify_end()
                    .text_size(metrics.number_font)
                    .text_color(frame.colors.tertiary)
                    .child(number.to_string()),
            );
        }
    }
    if let Some((marker, color)) = marker {
        view = view.child(
            div()
                .absolute()
                .left(width - metrics.marker + px(5.))
                .top((metrics.line_height - metrics.text_height) / 2.)
                .font_family(frame.mono.clone())
                .text_size(metrics.font)
                .line_height(metrics.text_height)
                .text_color(color)
                .child(marker),
        );
    }
    view
}

fn line_label(line: &DiffLine, side: Option<Side>) -> String {
    match line.kind {
        LineKind::Addition => format!("Added line {}: {}", line.new_line.unwrap_or(0), line.text),
        LineKind::Deletion => format!("Removed line {}: {}", line.old_line.unwrap_or(0), line.text),
        LineKind::Context => format!(
            "Line {}: {}",
            if side == Some(Side::Before) {
                line.old_line
            } else {
                line.new_line
            }
            .unwrap_or(0),
            line.text
        ),
        LineKind::NoNewline => "No newline at end of file".into(),
    }
}

fn click_handler(
    frame: &Frame,
    row: usize,
    split: bool,
) -> impl Fn(&MouseDownEvent, &mut Window, &mut App) + 'static {
    let panel = frame.panel.clone();
    let horizontal = frame.horizontal.clone();
    move |event, window, cx| {
        let side = split.then(|| {
            let bounds = horizontal.bounds();
            if event.position.x < bounds.origin.x + bounds.size.width / 2. {
                Side::Before
            } else {
                Side::After
            }
        });
        let extend = event.modifiers.shift;
        let toggle = event.modifiers.secondary(cx);
        let _ = panel.update(cx, |panel, cx| {
            panel.click_row(row, extend, toggle, side, window, cx)
        });
    }
}

fn render_line(
    frame: &Frame,
    index: usize,
    file: usize,
    hunk: usize,
    line_index: usize,
) -> AnyElement {
    let line = &frame.diff.files[file].hunks[hunk].lines[line_index];
    let highlight = frame
        .presentation
        .highlights
        .get(&(file, hunk, line_index))
        .cloned();
    let (background, tint, marker) = line_tint(&frame.colors, Some(line.kind));
    let scrolled = frame.scrolled();
    div()
        .id(ElementId::named_usize("diff-row", index))
        .relative()
        .w(frame.content_width)
        .h(frame.metrics.line_height)
        .when(frame.selected.contains(&index), |view| {
            view.bg(frame.colors.selection)
        })
        .when_some(background, |view, color| {
            view.child(div().absolute().inset_0().bg(color))
        })
        .role(Role::Label)
        .aria_label(line_label(line, None))
        .on_mouse_down(MouseButton::Left, click_handler(frame, index, false))
        .child(text_element(
            frame,
            line,
            highlight,
            frame.metrics.text_origin(),
        ))
        .child(gutter(
            frame,
            &[line.old_line, line.new_line],
            marker,
            tint,
            scrolled,
        ))
        .into_any_element()
}

fn render_half(
    frame: &Frame,
    index: usize,
    file: usize,
    hunk: usize,
    line_index: Option<usize>,
    side: Side,
) -> Div {
    let lines = &frame.diff.files[file].hunks[hunk].lines;
    let line = line_index.and_then(|ix| lines.get(ix));
    let (background, tint, marker) = line_tint(&frame.colors, line.map(|line| line.kind));
    let half = frame.viewport / 2.;
    let left = frame.scrolled()
        + match side {
            Side::Before => px(0.),
            Side::After => half,
        };
    let selected = frame.selected.contains(&index) && frame.side == side;
    let mut view = div()
        .absolute()
        .top_0()
        .bottom_0()
        .left(left)
        .w(half)
        .overflow_hidden()
        .when(selected, |view| view.bg(frame.colors.selection))
        .when_some(background, |view, color| {
            view.child(div().absolute().inset_0().bg(color))
        });
    if let Some(line) = line {
        let highlight = line_index
            .and_then(|ix| frame.presentation.highlights.get(&(file, hunk, ix)))
            .cloned();
        let number = match side {
            Side::Before => line.old_line,
            Side::After => line.new_line,
        };
        view = view
            .child(text_element(
                frame,
                line,
                highlight,
                frame.metrics.single_gutter() + px(4.) - frame.scrolled(),
            ))
            .child(gutter(frame, &[number], marker, tint, px(0.)));
    }
    view
}

fn render_split(
    frame: &Frame,
    index: usize,
    file: usize,
    hunk: usize,
    pair: SplitLine,
) -> AnyElement {
    let lines = &frame.diff.files[file].hunks[hunk].lines;
    let label = [(pair.before, Side::Before), (pair.after, Side::After)]
        .iter()
        .filter_map(|(line, side)| {
            line.and_then(|ix| lines.get(ix))
                .map(|line| line_label(line, Some(*side)))
        })
        .collect::<Vec<_>>()
        .join(". ");
    div()
        .id(ElementId::named_usize("diff-row", index))
        .relative()
        .w(frame.content_width)
        .h(frame.metrics.line_height)
        .role(Role::Label)
        .aria_label(label)
        .on_mouse_down(MouseButton::Left, click_handler(frame, index, true))
        .child(render_half(
            frame,
            index,
            file,
            hunk,
            pair.before,
            Side::Before,
        ))
        .child(render_half(
            frame,
            index,
            file,
            hunk,
            pair.after,
            Side::After,
        ))
        .child(
            div()
                .absolute()
                .top_0()
                .bottom_0()
                .left(frame.scrolled() + frame.viewport / 2.)
                .w(px(1.))
                .bg(frame.colors.separator),
        )
        .into_any_element()
}

fn render_hunk(frame: &Frame, index: usize, file: usize, hunk: usize) -> AnyElement {
    let header = frame.diff.files[file].hunks[hunk].header();
    let metrics = frame.metrics;
    let scrolled = frame.scrolled();
    let y = (metrics.hunk_height() - metrics.text_height) / 2.;
    div()
        .id(ElementId::named_usize("diff-row", index))
        .relative()
        .w(frame.content_width)
        .h(metrics.hunk_height())
        .bg(frame.colors.hunk)
        .font_family(frame.mono.clone())
        .text_size(metrics.font)
        .line_height(metrics.text_height)
        .whitespace_nowrap()
        .role(Role::Label)
        .aria_label(format!("Hunk {header}"))
        .child(
            div()
                .absolute()
                .top(y)
                .left(scrolled + metrics.number_column - px(18.))
                .text_color(frame.colors.tertiary)
                .child("⋯"),
        )
        .child(
            div()
                .absolute()
                .top(y)
                .left(scrolled + metrics.text_origin())
                .text_color(frame.colors.secondary)
                .child(header),
        )
        .into_any_element()
}

fn render_note(frame: &Frame, index: usize, file: usize, note: Note) -> AnyElement {
    let text = note_text(note, &frame.diff.files[file]);
    div()
        .relative()
        .w(frame.content_width)
        .h(frame.metrics.note_height())
        .child(
            div()
                .id(ElementId::named_usize("diff-row", index))
                .absolute()
                .top_0()
                .bottom_0()
                .left(frame.scrolled() + frame.metrics.text_origin())
                .flex()
                .items_center()
                .whitespace_nowrap()
                .text_size(frame.metrics.font)
                .text_color(frame.colors.secondary)
                .role(Role::Label)
                .aria_label(text.clone())
                .child(text),
        )
        .into_any_element()
}

fn render_row(frame: &Frame, index: usize) -> AnyElement {
    match frame.rows[index] {
        Row::File(file) => render_header(frame, file, frame.scrolled(), false),
        Row::Hunk { file, hunk } => render_hunk(frame, index, file, hunk),
        Row::Line { file, hunk, line } => render_line(frame, index, file, hunk, line),
        Row::Split { file, hunk, pair } => render_split(frame, index, file, hunk, pair),
        Row::Note { file, note } => render_note(frame, index, file, note),
    }
}

/// Measures `0` in `family` at `size`, falling back to a typical monospace advance.
fn advance(window: &Window, family: &SharedString, size: Pixels) -> f32 {
    let font_id = window.text_system().resolve_font(&font(family.clone()));
    window
        .text_system()
        .advance(font_id, size, '0')
        .map(|advance| f32::from(advance.width))
        .unwrap_or(f32::from(size) * 0.6)
}

impl DiffPanel {
    pub(crate) fn render_document(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let mono = cx.theme().mono_font_family.clone();
        let font_size = self.font_size;
        let code = px((font_size - 1.).max(9.));
        let numbers = px((font_size - 2.).max(8.));
        let metrics = Metrics::new(
            font_size,
            self.document.presentation.max_line_number,
            advance(window, &mono, code),
            advance(window, &mono, numbers),
        );
        if self.document.metrics != Some(metrics) {
            let first = self.document.metrics.is_none();
            self.document.metrics = Some(metrics);
            if first {
                // Unmeasured rows take a line's height, so the scrollbar spans the diff.
                let top = self.document.list.logical_scroll_top();
                self.document
                    .list
                    .reset_with_uniform_height(self.document.rows.len(), metrics.line_height);
                self.document.list.scroll_to(top);
            } else {
                self.document.list.remeasure();
            }
        }
        let document = &self.document;
        let viewport = if document.viewport.width > px(0.) {
            document.viewport.width
        } else {
            px(480.)
        };
        let content_width =
            metrics.scroll_width(document.layout, document.presentation.max_columns, viewport);
        let frame = Rc::new(Frame {
            diff: document.diff.clone(),
            presentation: document.presentation.clone(),
            rows: document.rows.clone(),
            collapsed: document.collapsed.clone(),
            selected: document.selected.clone(),
            side: document.side,
            metrics,
            colors: Colors::new(cx),
            mono,
            horizontal: document.horizontal.clone(),
            viewport,
            content_width,
            panel: cx.entity().downgrade(),
        });
        let floating = floating_header(
            &document.rows,
            &document.file_rows,
            &metrics,
            document.list.logical_scroll_top(),
        );
        let list_frame = frame.clone();
        let panel = cx.entity().downgrade();
        let side_labels = document.layout == DiffLayout::SideBySide;
        div()
            .id("diff-document")
            .flex_1()
            .min_h_0()
            .min_w_0()
            .flex()
            .flex_col()
            .bg(frame.colors.background)
            .track_focus(&document.focus)
            .key_context("DiffDocument")
            .role(Role::Document)
            .aria_label("Diff")
            .on_action(cx.listener(|this, _: &gpui_kit::base::input::Copy, _, cx| {
                let text = this.document.selected_text();
                if text.is_empty() {
                    cx.propagate();
                } else {
                    cx.write_to_clipboard(ClipboardItem::new_string(text));
                }
            }))
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                let modifiers = event.keystroke.modifiers;
                if this.document.layout != DiffLayout::SideBySide || modifiers.modified() {
                    return;
                }
                let side = match event.keystroke.key.as_str() {
                    "left" => Side::Before,
                    "right" => Side::After,
                    _ => return,
                };
                this.document.side = side;
                cx.stop_propagation();
                cx.notify();
            }))
            .when(side_labels, |view| {
                view.child(
                    div()
                        .relative()
                        .flex_shrink_0()
                        .h(metrics.hunk_height())
                        .border_t_1()
                        .border_color(frame.colors.separator)
                        .bg(frame.colors.header)
                        .text_size((metrics.font - px(1.)).max(px(9.)))
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(frame.colors.secondary)
                        .flex()
                        .items_center()
                        .child(
                            div()
                                .w_1_2()
                                .pl(px(10.))
                                .pr(px(8.))
                                .truncate()
                                .child("Before Change"),
                        )
                        .child(
                            div()
                                .absolute()
                                .top_0()
                                .bottom_0()
                                .left(relative(0.5))
                                .w(px(1.))
                                .bg(frame.colors.separator),
                        )
                        .child(
                            div()
                                .w_1_2()
                                .pl(px(10.))
                                .pr(px(8.))
                                .truncate()
                                .child("After Change"),
                        ),
                )
            })
            .child(
                div()
                    .id("diff-body")
                    .relative()
                    .flex_1()
                    .min_h_0()
                    .min_w_0()
                    .child(
                        div()
                            .id("diff-horizontal")
                            .size_full()
                            .overflow_x_hidden()
                            .track_scroll(&document.horizontal)
                            .child(
                                list(document.list.clone(), move |index, _, _| {
                                    render_row(&list_frame, index)
                                })
                                .w(content_width)
                                .h_full(),
                            ),
                    )
                    .child(
                        ScrollableMask::new(Axis::Horizontal, &document.horizontal)
                            .id("diff-horizontal-wheel"),
                    )
                    .when_some(floating, |view, (file, y)| {
                        view.child(
                            div()
                                .absolute()
                                .left_0()
                                .top(y)
                                .w(viewport)
                                .child(render_header(&frame, file, px(0.), true)),
                        )
                    })
                    .child(
                        div()
                            .absolute()
                            .inset_0()
                            .child(Scrollbar::vertical(&document.list).viewport_from_layout()),
                    )
                    .child(Scrollbar::horizontal(&document.horizontal))
                    .child(
                        canvas(
                            move |bounds, _, cx| {
                                let _ = panel.update(cx, |panel, cx| {
                                    if panel.document.viewport != bounds.size {
                                        panel.document.viewport = bounds.size;
                                        cx.notify();
                                    }
                                });
                            },
                            |_, _, _, _| {},
                        )
                        .absolute()
                        .size_full(),
                    ),
            )
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use coincide_core::workspace_diff::{DiffHunk, FileDiff};

    fn line(kind: LineKind, text: &str) -> DiffLine {
        DiffLine {
            kind,
            text: text.into(),
            old_line: Some(1),
            new_line: Some(1),
        }
    }

    fn fixture() -> GitDiff {
        let mut first = FileDiff::new("src/a.rs", ChangeStatus::Modified);
        first.hunks.push(DiffHunk {
            old_start: 1,
            old_count: 2,
            new_start: 1,
            new_count: 2,
            section: String::new(),
            lines: vec![
                line(LineKind::Context, "keep"),
                line(LineKind::Deletion, "old"),
                line(LineKind::Addition, "new"),
            ],
        });
        let mut binary = FileDiff::new("b.png", ChangeStatus::Added);
        binary.is_binary = true;
        let mut mode = FileDiff::new("run.sh", ChangeStatus::Modified);
        mode.mode_change = Some("100644 → 100755".into());
        let mut large = FileDiff::new("large.txt", ChangeStatus::Modified);
        large.additions = 3;
        GitDiff {
            files: vec![first, binary, mode, large],
            is_truncated: false,
            base_label: Some("HEAD".into()),
        }
    }

    fn metrics() -> Metrics {
        Metrics::new(13., 120, 7., 6.)
    }

    #[::core::prelude::v1::test]
    fn rows_follow_layout_collapse_and_notes_like_swift() {
        let diff = fixture();
        let presentation = Presentation::make(&diff);
        let (rows, file_rows) =
            build_rows(&diff, &presentation, &HashSet::new(), DiffLayout::Unified);
        assert_eq!(file_rows, [0, 5, 7, 9]);
        assert_eq!(rows[1], Row::Hunk { file: 0, hunk: 0 });
        assert_eq!(
            rows[4],
            Row::Line {
                file: 0,
                hunk: 0,
                line: 2
            }
        );
        assert_eq!(
            rows[6],
            Row::Note {
                file: 1,
                note: Note::Binary
            }
        );
        assert_eq!(
            rows[8],
            Row::Note {
                file: 2,
                note: Note::Unchanged
            }
        );
        assert_eq!(
            rows[10],
            Row::Note {
                file: 3,
                note: Note::NotLoaded
            }
        );
        assert_eq!(
            note_text(Note::Unchanged, &diff.files[2]),
            "File mode changed: 100644 → 100755"
        );
        let (split, _) = build_rows(
            &diff,
            &presentation,
            &HashSet::new(),
            DiffLayout::SideBySide,
        );
        assert_eq!(
            split[3],
            Row::Split {
                file: 0,
                hunk: 0,
                pair: SplitLine {
                    before: Some(1),
                    after: Some(2)
                }
            }
        );
        assert_eq!(split.len(), rows.len() - 1);
        let collapsed = HashSet::from(["src/a.rs".to_owned()]);
        let (rows, file_rows) = build_rows(&diff, &presentation, &collapsed, DiffLayout::Unified);
        assert_eq!(file_rows[..2], [0, 1]);
        assert_eq!(rows[1], Row::File(1));
    }

    #[::core::prelude::v1::test]
    fn anchors_survive_reloads_and_layout_changes() {
        let diff = fixture();
        let presentation = Presentation::make(&diff);
        let (unified, unified_files) =
            build_rows(&diff, &presentation, &HashSet::new(), DiffLayout::Unified);
        let (split, split_files) = build_rows(
            &diff,
            &presentation,
            &HashSet::new(),
            DiffLayout::SideBySide,
        );
        let top = ListOffset {
            item_ix: 4,
            offset_in_item: px(3.),
        };
        let kept = anchor(&diff, &unified, top).unwrap();
        assert_eq!(kept.path, "src/a.rs");
        let restored = restore(&diff, &split, &split_files, &kept, Side::After);
        assert_eq!((restored.item_ix, restored.offset_in_item), (3, px(3.)));
        let back = anchor(&diff, &split, restored).unwrap();
        let before = restore(&diff, &unified, &unified_files, &back, Side::Before);
        assert_eq!(before.item_ix, 3);
        let after = restore(&diff, &unified, &unified_files, &back, Side::After);
        assert_eq!(after.item_ix, 4);
        let mut fewer = diff.clone();
        fewer.files.remove(0);
        let (rows, files) = build_rows(
            &fewer,
            &Presentation::make(&fewer),
            &HashSet::new(),
            DiffLayout::Unified,
        );
        let gone = restore(&fewer, &rows, &files, &kept, Side::After);
        assert_eq!(gone.item_ix, 0);
        let note = anchor(
            &diff,
            &unified,
            ListOffset {
                item_ix: 6,
                offset_in_item: px(0.),
            },
        )
        .unwrap();
        let mut grown = diff.clone();
        grown.files[1].is_binary = false;
        grown.files[1].additions = 1;
        let (rows, files) = build_rows(
            &grown,
            &Presentation::make(&grown),
            &HashSet::new(),
            DiffLayout::Unified,
        );
        assert_eq!(
            restore(&grown, &rows, &files, &note, Side::After).item_ix,
            6
        );
    }

    #[::core::prelude::v1::test]
    fn floating_header_tracks_the_top_file_and_is_pushed_by_the_next() {
        let diff = fixture();
        let presentation = Presentation::make(&diff);
        let (rows, file_rows) =
            build_rows(&diff, &presentation, &HashSet::new(), DiffLayout::Unified);
        let m = metrics();
        let at = |item_ix, offset: f32| ListOffset {
            item_ix,
            offset_in_item: px(offset),
        };
        assert_eq!(floating_header(&rows, &file_rows, &m, at(0, 0.)), None);
        assert_eq!(
            floating_header(&rows, &file_rows, &m, at(0, 4.)),
            Some((0, px(0.)))
        );
        assert_eq!(
            floating_header(&rows, &file_rows, &m, at(1, 0.)),
            Some((0, px(0.)))
        );
        // One line row remains above the next header: the floating header moves up.
        let visible = m.line_height - px(5.);
        let expected = visible - m.file_header_height();
        assert_eq!(
            floating_header(&rows, &file_rows, &m, at(4, 5.)),
            Some((0, expected))
        );
        assert_eq!(
            floating_header(&rows, &file_rows, &m, at(10, 0.)),
            Some((3, px(0.)))
        );
        assert_eq!(floating_header(&[], &[], &m, at(0, 0.)), None);
    }

    #[::core::prelude::v1::test]
    fn display_text_expands_tabs_cuts_long_lines_and_moves_highlights() {
        assert_eq!(
            display_text("a\tb", Some(2..3)),
            ("a   b".into(), Some(4..5))
        );
        assert_eq!(display_text("\tx", None), ("    x".into(), None));
        assert_eq!(display_text("abc", Some(1..3)), ("abc".into(), Some(1..3)));
        assert_eq!(
            display_text("café!", Some(3..5)),
            ("café!".into(), Some(3..5))
        );
        let long = "x".repeat(MAX_DRAWN_LENGTH + 5);
        let (cut, range) = display_text(&long, Some(10..MAX_DRAWN_LENGTH + 2));
        assert!(cut.ends_with(" …"));
        assert_eq!(cut.chars().count(), MAX_DRAWN_LENGTH + 2);
        assert_eq!(range, Some(10..MAX_DRAWN_LENGTH));
        assert_eq!(display_text("abc", Some(3..3)), ("abc".into(), None));
    }

    #[::core::prelude::v1::test]
    fn selection_copies_chosen_side_without_eof_markers() {
        let mut diff = fixture();
        diff.files[0].hunks[0]
            .lines
            .push(line(LineKind::NoNewline, "\\ No newline at end of file"));
        let presentation = Presentation::make(&diff);
        let (rows, _) = build_rows(&diff, &presentation, &HashSet::new(), DiffLayout::Unified);
        let selected = BTreeSet::from([0, 2, 3, 4, 5]);
        assert_eq!(
            selected_text(&diff, &rows, &selected, Side::After),
            "keep\nold\nnew"
        );
        let (split, _) = build_rows(
            &diff,
            &presentation,
            &HashSet::new(),
            DiffLayout::SideBySide,
        );
        let selected = BTreeSet::from([2, 3]);
        assert_eq!(
            selected_text(&diff, &split, &selected, Side::Before),
            "keep\nold"
        );
        assert_eq!(
            selected_text(&diff, &split, &selected, Side::After),
            "keep\nnew"
        );
    }

    #[::core::prelude::v1::test]
    fn metrics_follow_swift_sizes_and_scroll_widths() {
        let m = metrics();
        assert_eq!(m.font, px(12.));
        assert_eq!(m.number_font, px(11.));
        assert_eq!(m.number_column, px(32.));
        assert_eq!(m.marker, px(17.));
        assert_eq!(m.gutter(), px(81.));
        assert_eq!(m.file_header_height(), px(30.));
        assert_eq!(m.scroll_width(DiffLayout::Unified, 10, px(600.)), px(600.));
        assert_eq!(m.content_width(100), px(817.));
        assert_eq!(
            m.scroll_width(DiffLayout::SideBySide, 100, px(600.)),
            px(600.) + (px(817.) - px(32.) - px(300.))
        );
        assert_eq!(
            DiffLayout::from_setting("sideBySide"),
            Some(DiffLayout::SideBySide)
        );
        assert_eq!(DiffLayout::from_setting("other"), None);
    }
}
