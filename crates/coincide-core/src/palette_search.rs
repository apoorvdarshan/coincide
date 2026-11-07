//! Word-start search with typo tolerance for the command palette, ported from
//! Swift's `PaletteSearch` (itself T3's `packages/shared/src/paletteSearch.ts`).
//! Every query word must start a word somewhere ("sid" finds "Fix sidebar"),
//! may run words together ("vscode" finds "VS Code"), and, when nothing matches
//! exactly, may contain one typo. Inside-word hits need four letters and only
//! count in titles, so "del" does not find "model".
//!
//! Characters are grapheme clusters, as Swift's `Character`. Highlight ranges
//! are UTF-8 byte ranges of the primary field's source, for GPUI text runs.
use std::ops::Range;
use unicode_segmentation::UnicodeSegmentation;

const WHOLE_WORD: f64 = 1.0;
const WHOLE_NAME: f64 = 1.5;
const MID_WORD: f64 = 0.3;
const TYPO: f64 = 0.45;
const JOINED_WORDS: f64 = 0.6;
const FILLER_WORDS: [&str; 10] = [
    "a", "an", "and", "for", "in", "of", "on", "the", "to", "with",
];
const RECENCY_HALF_LIFE: f64 = 14.0 * 24.0 * 3600.0;

/// One folded character: a single scalar, or a cluster that folds to no single
/// scalar (an emoji sequence), compared whole.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Ch {
    One(char),
    Many(Box<str>),
}
impl Ch {
    fn first(&self) -> char {
        match self {
            Self::One(c) => *c,
            Self::Many(s) => s.chars().next().unwrap_or('\0'),
        }
    }
    fn is_letter(&self) -> bool {
        self.first().is_alphabetic()
    }
    fn is_number(&self) -> bool {
        self.first().is_numeric()
    }
    fn is_alphanumeric(&self) -> bool {
        self.is_letter() || self.is_number()
    }
    fn is_other_symbol(&self) -> bool {
        is_other_symbol(self.first())
    }
    fn push_to(&self, out: &mut String) {
        match self {
            Self::One(c) => out.push(*c),
            Self::Many(s) => out.push_str(s),
        }
    }
}

/// Unicode's Other Symbol category (emoji, dingbats, arrows, box drawing), by
/// its main blocks; std exposes no general category.
fn is_other_symbol(c: char) -> bool {
    matches!(c as u32,
        0x00A6 | 0x00A9 | 0x00AE | 0x00B0
        | 0x2100..=0x2101 | 0x2103..=0x2106 | 0x2108..=0x2109 | 0x2116..=0x2117
        | 0x211E..=0x2123 | 0x2125 | 0x2127 | 0x2129 | 0x212E | 0x213A..=0x213B
        | 0x2195..=0x2199 | 0x219C..=0x219F | 0x21A1..=0x21A2 | 0x21A4..=0x21A5
        | 0x21A7..=0x21AD | 0x21AF..=0x21CD | 0x21D0..=0x21D1 | 0x21D3 | 0x21D5..=0x21F3
        | 0x2300..=0x2307 | 0x230C..=0x231F | 0x2322..=0x2328 | 0x232B..=0x237B
        | 0x237D..=0x239A | 0x23B4..=0x23DB | 0x23E2..=0x23FF | 0x2400..=0x244A
        | 0x249C..=0x24E9 | 0x2500..=0x25B6 | 0x25B8..=0x25C0 | 0x25C2..=0x25F7
        | 0x2600..=0x266E | 0x2670..=0x2767 | 0x2794..=0x27BF | 0x2800..=0x28FF
        | 0x2B00..=0x2B2F | 0x2B45..=0x2B46 | 0x2B4D..=0x2B73 | 0x2B76..=0x2BFF
        | 0x1F000..=0x1F0FF | 0x1F10D..=0x1F1AD | 0x1F1E6..=0x1F1FF | 0x1F300..=0x1F3FA
        | 0x1F400..=0x1FAFF)
}

fn is_cjk(c: char) -> bool {
    matches!(c as u32, 0x3040..=0x30FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF)
}

fn is_combining_mark(c: char) -> bool {
    matches!(c as u32, 0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F)
}

/// The base letter of a precomposed Latin letter whose accent folds away, as
/// Foundation's diacritic-insensitive folding does. Letters without a canonical
/// decomposition (ø, đ, ł, æ) stay as they are.
fn strip_latin_diacritic(c: char) -> char {
    match c as u32 {
        0xC0..=0xC5 => 'A',
        0xC7 => 'C',
        0xC8..=0xCB => 'E',
        0xCC..=0xCF => 'I',
        0xD1 => 'N',
        0xD2..=0xD6 => 'O',
        0xD9..=0xDC => 'U',
        0xDD => 'Y',
        0xE0..=0xE5 => 'a',
        0xE7 => 'c',
        0xE8..=0xEB => 'e',
        0xEC..=0xEF => 'i',
        0xF1 => 'n',
        0xF2..=0xF6 => 'o',
        0xF9..=0xFC => 'u',
        0xFD | 0xFF => 'y',
        0x100..=0x105 => ['A', 'a'][(c as usize) & 1],
        0x106..=0x10D => ['C', 'c'][(c as usize) & 1],
        0x10E..=0x10F => ['D', 'd'][(c as usize) & 1],
        0x112..=0x11B => ['E', 'e'][(c as usize) & 1],
        0x11C..=0x123 => ['G', 'g'][(c as usize) & 1],
        0x124..=0x125 => ['H', 'h'][(c as usize) & 1],
        0x128..=0x12F => ['I', 'i'][(c as usize) & 1],
        0x130 => 'i',
        0x134..=0x135 => ['J', 'j'][(c as usize) & 1],
        0x136..=0x137 => ['K', 'k'][(c as usize) & 1],
        0x139..=0x13E => ['l', 'L'][(c as usize) & 1],
        0x143..=0x148 => ['n', 'N'][(c as usize) & 1],
        0x14C..=0x151 => ['O', 'o'][(c as usize) & 1],
        0x154..=0x159 => ['R', 'r'][(c as usize) & 1],
        0x15A..=0x161 => ['S', 's'][(c as usize) & 1],
        0x162..=0x165 => ['T', 't'][(c as usize) & 1],
        0x168..=0x173 => ['U', 'u'][(c as usize) & 1],
        0x174..=0x175 => ['W', 'w'][(c as usize) & 1],
        0x176..=0x177 => ['Y', 'y'][(c as usize) & 1],
        0x178 => 'Y',
        0x179..=0x17E => ['z', 'Z'][(c as usize) & 1],
        _ => c,
    }
}

fn fold(grapheme: &str) -> Ch {
    let mut scalars = grapheme.chars();
    let first = scalars.next().unwrap_or('\0');
    if grapheme.len() == 1 {
        return Ch::One(first.to_ascii_lowercase());
    }
    if grapheme == "‘" || grapheme == "’" {
        return Ch::One('\'');
    }
    let base = grapheme
        .chars()
        .filter(|c| !is_combining_mark(*c))
        .collect::<Vec<_>>();
    match base.as_slice() {
        [only] => {
            let stripped = strip_latin_diacritic(*only);
            let mut lower = stripped.to_lowercase();
            match (lower.next(), lower.next()) {
                (Some(c), None) => Ch::One(c),
                _ => Ch::One(stripped),
            }
        }
        // A lone combining mark has nothing to fold onto and stays as it is.
        [] if scalars.next().is_none() => Ch::One(first),
        _ => Ch::Many(grapheme.into()),
    }
}

/// After a non-letter, at a camelCase or digit boundary, or at any Chinese or
/// Japanese character.
fn is_word_start(
    before_previous: Option<&str>,
    previous: Option<&str>,
    character: &str,
    next: Option<&str>,
) -> bool {
    let first = |s: &str| s.chars().next().unwrap_or('\0');
    let alnum = |s: Option<&str>| s.is_some_and(|s| first(s).is_alphanumeric());
    let current = first(character);
    if !(current.is_alphanumeric() || is_other_symbol(current)) {
        return false;
    }
    // "Julius’s": a possessive does not start a word.
    if let Some(previous) = previous
        && (previous == "'" || previous == "’")
        && alnum(before_previous)
    {
        return false;
    }
    let Some(previous) = previous.filter(|p| first(p).is_alphanumeric()) else {
        return true;
    };
    let previous = first(previous);
    if previous.is_lowercase() && current.is_uppercase() {
        return true;
    }
    if previous.is_uppercase()
        && current.is_uppercase()
        && next.is_some_and(|next| first(next).is_lowercase())
    {
        return true;
    }
    if previous.is_numeric() != current.is_numeric() {
        return true;
    }
    is_cjk(current)
}

/// A searchable string, folded once.
#[derive(Clone, Debug, Default)]
pub struct Field {
    /// Case- and accent-folded, one entry per grapheme of the source.
    text: Vec<Ch>,
    starts: Vec<bool>,
    /// Byte offset of each grapheme in the source, plus its length.
    offsets: Vec<usize>,
}
impl Field {
    pub fn new(source: &str) -> Self {
        let graphemes = source.grapheme_indices(true).collect::<Vec<_>>();
        let mut field = Self {
            text: Vec::with_capacity(graphemes.len()),
            starts: Vec::with_capacity(graphemes.len()),
            offsets: Vec::with_capacity(graphemes.len() + 1),
        };
        for (index, (offset, grapheme)) in graphemes.iter().enumerate() {
            let at = |i: usize| graphemes.get(i).map(|(_, g)| *g);
            field.text.push(fold(grapheme));
            field.starts.push(is_word_start(
                index.checked_sub(2).and_then(at),
                index.checked_sub(1).and_then(at),
                grapheme,
                at(index + 1),
            ));
            field.offsets.push(*offset);
        }
        field.offsets.push(source.len());
        field
    }
    pub fn is_empty(&self) -> bool {
        self.text.is_empty()
    }
    fn len(&self) -> usize {
        self.text.len()
    }
    fn alnum(&self, index: usize) -> bool {
        self.text[index].is_alphanumeric()
    }
}

/// A query folded and split into words once per keystroke.
#[derive(Clone, Debug)]
pub struct Query {
    characters: Vec<Ch>,
    tokens: Vec<Vec<Ch>>,
    /// Under four meaningful letters, so hidden keywords must match whole words.
    short: bool,
}
impl Query {
    pub fn new(raw: &str) -> Self {
        let tokens = normalized_tokens(raw);
        let mut characters = Vec::new();
        for (index, token) in tokens.iter().enumerate() {
            if index > 0 {
                characters.push(Ch::One(' '));
            }
            characters.extend(token.iter().cloned());
        }
        // Filler words ("the ci") do not make a short query long.
        let meaningful = tokens
            .iter()
            .filter(|token| !is_filler(token))
            .collect::<Vec<_>>();
        let words = if meaningful.is_empty() {
            tokens.iter().collect()
        } else {
            meaningful
        };
        let short =
            words.iter().map(|word| word.len()).sum::<usize>() + words.len().saturating_sub(1) < 4;
        Self {
            characters,
            tokens,
            short,
        }
    }
    pub fn is_empty(&self) -> bool {
        self.tokens.is_empty()
    }
    pub fn is_short(&self) -> bool {
        self.short
    }
}

fn is_filler(token: &[Ch]) -> bool {
    let mut text = String::new();
    for ch in token {
        ch.push_to(&mut text);
    }
    FILLER_WORDS.contains(&text.as_str())
}

fn normalized_tokens(raw: &str) -> Vec<Vec<Ch>> {
    const QUOTES: [char; 7] = ['"', '\'', '`', '“', '”', '‘', '’'];
    let trimmed = raw.trim().trim_matches(|c| QUOTES.contains(&c));
    let mut tokens = Vec::new();
    let mut current = Vec::new();
    for grapheme in trimmed.graphemes(true) {
        let folded = fold(grapheme);
        if folded.first().is_whitespace() {
            if !current.is_empty() {
                tokens.push(std::mem::take(&mut current));
            }
        } else {
            current.push(folded);
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
}

/// The query folded and with whitespace collapsed; empty when there is nothing
/// to match.
pub fn normalize(query: &str) -> String {
    let mut text = String::new();
    for (index, token) in normalized_tokens(query).iter().enumerate() {
        if index > 0 {
            text.push(' ');
        }
        for ch in token {
            ch.push_to(&mut text);
        }
    }
    text
}

#[derive(Clone, Copy, Debug)]
struct Spec {
    weight: f64,
    /// Only a whole-word match counts.
    whole_words: bool,
    /// Only a word-start match counts, without typos: hidden keywords must not
    /// match loosely.
    keyword: bool,
    /// Where the item lives (its project): helps a match but never makes it strong.
    context: bool,
    /// A word of four or more letters may match inside a word. Titles only.
    mid_word: bool,
}
impl Spec {
    fn weight(weight: f64) -> Self {
        Self {
            weight,
            whole_words: false,
            keyword: false,
            context: false,
            mid_word: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Match {
    /// Roughly 0.3 (inside a word) to 1.5 (the whole name).
    pub quality: f64,
    /// What results sort by within a match class: quality times recent use.
    pub score: f64,
    /// The class the item's group ranks by, when lower than its own.
    pub group_quality: Option<f64>,
    /// Every word matched at a word start, without a typo.
    pub strong: bool,
    /// Matched byte ranges in the first field's source, for highlighting.
    pub ranges: Vec<Range<usize>>,
}

struct TokenMatch {
    score: f64,
    start: usize,
    end: usize,
    /// Separate ranges, for words typed together.
    letters: Option<Vec<Range<usize>>>,
}
impl TokenMatch {
    fn new(score: f64, start: usize, end: usize) -> Self {
        Self {
            score,
            start,
            end,
            letters: None,
        }
    }
}

/// Where `token` next occurs in `text` at or after `start`.
fn occurrence(token: &[Ch], text: &[Ch], start: usize) -> Option<usize> {
    if token.is_empty() || token.len() > text.len() || start > text.len() - token.len() {
        return None;
    }
    (start..=text.len() - token.len()).find(|&index| text[index..index + token.len()] == *token)
}

fn match_token(
    field: &Field,
    token: &[Ch],
    typos: bool,
    primary: bool,
    mid_word: bool,
) -> Option<TokenMatch> {
    let first = token.first()?;
    let text = &field.text;
    let mut best: Option<TokenMatch> = None;
    // A token that opens with punctuation (".ts") brings its own boundary.
    let own_boundary = !first.is_alphanumeric() && !first.is_other_symbol();
    let mut next = occurrence(token, text, 0);
    while let Some(index) = next {
        next = occurrence(token, text, index + 1);
        let end = index + token.len();
        if field.starts[index] || own_boundary {
            let whole = end >= text.len() || field.starts[end] || !field.alnum(end);
            let mut run_end = end;
            while run_end < text.len() && field.alnum(run_end) {
                run_end += 1;
            }
            let score = if whole {
                WHOLE_WORD
            } else {
                0.7 + 0.2 * token.len() as f64 / (run_end - index) as f64
            };
            if best.as_ref().is_none_or(|best| score > best.score) {
                best = Some(TokenMatch::new(score, index, end));
            }
            if score == WHOLE_WORD {
                return best;
            }
        } else if mid_word && token.len() >= 4 && best.is_none() {
            best = Some(TokenMatch::new(MID_WORD, index, end));
        }
    }
    if best.as_ref().is_none_or(|best| best.score <= MID_WORD)
        && primary
        && let Some(joined) = match_joined_words(field, token)
    {
        return Some(joined);
    }
    if best.as_ref().is_some_and(|best| best.score > MID_WORD) {
        return best;
    }
    if !typos || token.len() < 3 || !token.iter().any(Ch::is_letter) {
        return best;
    }
    // A typo keeps the first letter, unless it swaps the first two of a longer word.
    for index in 0..text.len() {
        if !field.starts[index] {
            continue;
        }
        let first_kept = text[index] == token[0]
            || (token.len() > 3
                && text[index] == token[1]
                && index + 1 < text.len()
                && text[index + 1] == token[0]);
        if !first_kept {
            continue;
        }
        let mut run_end = index + 1;
        while run_end < text.len() && field.alnum(run_end) {
            run_end += 1;
        }
        let short = token.len() <= 4;
        let lengths: &[usize] = if short {
            &[token.len(), token.len() + 1]
        } else {
            &[token.len(), token.len() - 1, token.len() + 1]
        };
        for &length in lengths {
            if length > run_end - index {
                continue;
            }
            if within_one_edit(
                token,
                &text[index..index + length],
                short && length == token.len(),
            ) {
                return Some(TokenMatch::new(TYPO, index, index + length));
            }
        }
    }
    best
}

/// One substitution, insertion, deletion or swap of neighbours; with
/// `swap_only`, only a swap.
fn within_one_edit(left: &[Ch], right: &[Ch], swap_only: bool) -> bool {
    if left.len().abs_diff(right.len()) > usize::from(!swap_only) {
        return false;
    }
    let common = left.iter().zip(right).take_while(|(l, r)| l == r).count();
    let rest_left = &left[common..];
    let rest_right = &right[common..];
    let tail = |s: &[Ch], n: usize| -> std::ops::RangeFrom<usize> { n.min(s.len()).. };
    let swapped = rest_left.len() > 1
        && rest_right.len() > 1
        && rest_left[0] == rest_right[1]
        && rest_left[1] == rest_right[0]
        && rest_left[2..] == rest_right[2..];
    if swap_only {
        return swapped;
    }
    swapped
        || rest_left == rest_right
        || rest_left[tail(rest_left, 1)] == rest_right[tail(rest_right, 1)]
        || rest_left[tail(rest_left, 1)] == *rest_right
        || *rest_left == rest_right[tail(rest_right, 1)]
}

fn word_end(field: &Field, index: usize) -> usize {
    let mut end = index + 1;
    while end < field.len() && !field.starts[end] && field.alnum(end) {
        end += 1;
    }
    end
}

/// Words typed together: "vscode" for "VS Code". Short fragments only count at
/// the start of the name, before three letters, or as a whole word, so "inth"
/// does not find "in thread".
fn match_joined_words(field: &Field, token: &[Ch]) -> Option<TokenMatch> {
    let text = &field.text;
    let first_word = field.starts.iter().position(|start| *start);
    for start in 0..text.len() {
        if !field.starts[start] || text[start] != token[0] {
            continue;
        }
        let mut runs: Vec<Range<usize>> = Vec::new();
        let mut at = start;
        let mut rest = token;
        while !rest.is_empty() && at < text.len() {
            let end = word_end(field, at);
            if rest.len() <= end - at && text[at..at + rest.len()] == *rest {
                runs.push(at..at + rest.len());
                rest = &[];
            } else if rest.starts_with(&text[at..end]) {
                runs.push(at..end);
                rest = &rest[end - at..];
                at = end;
                while at < text.len() && !field.starts[at] {
                    at += 1;
                }
            } else {
                break;
            }
        }
        let Some(last) = runs.last().cloned() else {
            continue;
        };
        if !rest.is_empty() || runs.len() < 2 {
            continue;
        }
        if last.end == word_end(field, last.start)
            || last.len() >= 3
            || Some(start) == first_word
            || runs[..runs.len() - 1].iter().all(|run| run.len() >= 3)
        {
            return Some(TokenMatch {
                score: JOINED_WORDS,
                start,
                end: last.end,
                letters: Some(runs),
            });
        }
    }
    None
}

/// Every query word must match some field. Quality is the mean of each word's
/// best weighted match, plus a bonus when the first field equals or contains
/// the whole query.
fn match_fields(query: &Query, fields: &[(&Field, Spec)], typos: bool) -> Option<Match> {
    if query.tokens.is_empty() {
        return None;
    }
    let has_primary = fields.first().is_some_and(|(field, _)| !field.is_empty());
    let prepared = fields
        .iter()
        .filter(|(field, _)| !field.is_empty())
        .collect::<Vec<_>>();
    let filler_optional = query.tokens.iter().any(|token| !is_filler(token));
    let mut ranges = Vec::new();
    let mut total = 0.0;
    let mut counted = 0;
    let mut strong = true;
    for token in &query.tokens {
        let mut best = 0.0f64;
        let mut best_primary = None;
        let mut at_word_start = false;
        for (index, (field, spec)) in prepared.iter().enumerate() {
            let primary = has_primary && index == 0;
            if best >= spec.weight && !primary && at_word_start {
                continue;
            }
            let Some(found) =
                match_token(field, token, typos && !spec.keyword, primary, spec.mid_word)
            else {
                continue;
            };
            let minimum = if spec.whole_words {
                WHOLE_WORD
            } else if spec.keyword {
                0.7
            } else {
                0.0
            };
            if found.score < minimum {
                continue;
            }
            if found.score >= 0.7 && !spec.context {
                at_word_start = true;
            }
            best = best.max(found.score * spec.weight);
            if primary {
                best_primary = Some(found);
            }
        }
        if best == 0.0 {
            if filler_optional && is_filler(token) {
                continue;
            }
            return None;
        }
        strong = strong && at_word_start;
        if let Some(found) = best_primary {
            match found.letters {
                Some(letters) => ranges.extend(letters),
                None => ranges.push(found.start..found.end),
            }
        }
        total += best;
        counted += 1;
    }
    if counted == 0 {
        return None;
    }
    let mut quality = total / f64::from(counted);
    let primary = has_primary.then(|| prepared[0].0);
    if let Some(primary) = primary {
        if primary.text == query.characters {
            quality += WHOLE_NAME - WHOLE_WORD;
        } else if query.tokens.len() > 1
            && occurrence(&query.characters, &primary.text, 0).is_some()
        {
            quality += 0.25;
        }
    }
    let ranges = primary
        .map(|field| {
            merge(ranges)
                .into_iter()
                .map(|range| field.offsets[range.start]..field.offsets[range.end])
                .collect()
        })
        .unwrap_or_default();
    Some(Match {
        quality,
        score: quality,
        group_quality: None,
        strong,
        ranges,
    })
}

fn merge(mut ranges: Vec<Range<usize>>) -> Vec<Range<usize>> {
    ranges.sort_by_key(|range| range.start);
    let mut merged: Vec<Range<usize>> = Vec::new();
    for range in ranges {
        match merged.last_mut() {
            Some(last) if range.start <= last.end => last.end = last.end.max(range.end),
            _ => merged.push(range),
        }
    }
    merged
}

/// The branch as the palette searches it: without the worktree prefix, unless
/// the branch is only that prefix.
pub fn searchable_branch<'a>(branch: &'a str, prefix: &str) -> &'a str {
    match branch.strip_prefix(prefix) {
        Some(rest) if !prefix.is_empty() && !rest.is_empty() => rest,
        _ => branch,
    }
}

/// A thread: its title counts fully, its branch less, its project least.
/// Recently active threads rank higher among matches of the same quality.
/// `updated_at` and `now` are seconds on the same clock.
pub fn score_thread(
    query: &Query,
    title: &Field,
    branch: &Field,
    project: &Field,
    updated_at: f64,
    now: f64,
    typos: bool,
) -> Option<Match> {
    let fields = [
        (
            title,
            Spec {
                mid_word: true,
                ..Spec::weight(1.0)
            },
        ),
        (branch, Spec::weight(0.6)),
        (
            project,
            Spec {
                context: true,
                ..Spec::weight(0.25)
            },
        ),
    ];
    let mut found = match_fields(query, &fields, typos)?;
    let recency = 2f64.powf(-(now - updated_at).max(0.0) / RECENCY_HALF_LIFE);
    found.score = found.quality * (1.0 + recency).min(3.0);
    // A thread titled like a command never lifts its group above that command.
    found.group_quality = Some(found.quality.min(WHOLE_NAME - 0.01));
    Some(found)
}

/// A command or project: its name, plus keywords that count less.
pub fn score_terms(query: &Query, name: &Field, keywords: &[Field], typos: bool) -> Option<Match> {
    // Short queries need whole keywords, or "co" would list most commands.
    let short = query.short;
    let keyword = Spec {
        whole_words: short,
        keyword: true,
        ..Spec::weight(if short { 0.8 } else { 0.6 })
    };
    let fields = std::iter::once((name, Spec::weight(1.0)))
        .chain(keywords.iter().map(|field| (field, keyword)))
        .collect::<Vec<_>>();
    let mut found = match_fields(query, &fields, typos)?;
    if found.ranges.is_empty() {
        found.group_quality = Some(found.quality.min(0.65));
    }
    Some(found)
}

/// Whole names, word starts, typos and inside-word hits.
pub fn match_class(quality: f64) -> u8 {
    if quality >= WHOLE_NAME {
        3
    } else if quality >= 0.7 {
        2
    } else if quality >= 0.4 {
        1
    } else {
        0
    }
}

/// One group's ranked items: its index and each matching item's index with its
/// match, best first.
pub type RankedGroup = (usize, Vec<(usize, Match)>);

/// Ranks every group's items and orders the groups by their best match class,
/// keeping their given order on ties. Typos are only tried when nothing matches
/// at a word start. `score` receives (group, item, typos).
pub fn rank(
    sizes: &[usize],
    mut score: impl FnMut(usize, usize, bool) -> Option<Match>,
) -> Vec<RankedGroup> {
    let mut run = |typos: bool| -> Vec<Vec<(usize, Match)>> {
        sizes
            .iter()
            .enumerate()
            .map(|(group, &size)| {
                (0..size)
                    .filter_map(|item| score(group, item, typos).map(|found| (item, found)))
                    .collect()
            })
            .collect()
    };
    let mut ranked = run(false);
    if !ranked
        .iter()
        .any(|items| items.iter().any(|(_, found)| found.strong))
    {
        ranked = run(true);
    }
    let mut ordered = ranked
        .into_iter()
        .enumerate()
        .filter(|(_, items)| !items.is_empty())
        .map(|(group, mut items)| {
            let best = items
                .iter()
                .map(|(_, found)| match_class(found.group_quality.unwrap_or(found.quality)))
                .max()
                .unwrap_or(0);
            items.sort_by(|(_, left), (_, right)| {
                let (l, r) = (match_class(left.quality), match_class(right.quality));
                r.min(2)
                    .cmp(&l.min(2))
                    .then(r.cmp(&l))
                    .then(right.score.total_cmp(&left.score))
            });
            (best, group, items)
        })
        .collect::<Vec<_>>();
    ordered.sort_by(|left, right| right.0.cmp(&left.0).then(left.1.cmp(&right.1)));
    ordered
        .into_iter()
        .map(|(_, group, items)| (group, items))
        .collect()
}

#[cfg(test)]
#[path = "palette_search_tests.rs"]
mod tests;

/// One character as message search compares it; None for a combining mark.
pub(crate) fn fold_char(character: char) -> Option<char> {
    if is_combining_mark(character) {
        return None;
    }
    if character.is_ascii() {
        return Some(character.to_ascii_lowercase());
    }
    if character == '‘' || character == '’' {
        return Some('\'');
    }
    let mut lower = character.to_lowercase();
    let lowered = match (lower.next(), lower.next()) {
        (Some(single), None) => single,
        _ => character,
    };
    Some(strip_latin_diacritic(lowered).to_ascii_lowercase())
}
