//! Word-start search with typo tolerance, ported from the Swift app's
//! `PaletteSearch` (itself T3 Code's `paletteSearch.ts`). Every query word must
//! start a word somewhere ("sid" finds "Fix sidebar"), may run words together
//! ("vscode" finds "VS Code") and, when nothing matches exactly, may contain one
//! typo. Inside-word hits need four letters and only count in titles, so "del"
//! does not find "model".
//!
//! Swift compares grapheme clusters; this port compares Unicode scalars and
//! drops combining marks while folding, which gives the same result for
//! precomposed and decomposed accents. Ranges are character (scalar) indices
//! into the folded primary field, not UTF-16 offsets.
use std::ops::Range;

const WHOLE_WORD: f64 = 1.0;
const WHOLE_NAME: f64 = 1.5;
const MID_WORD_SCORE: f64 = 0.3;
const TYPO_SCORE: f64 = 0.45;
const JOINED_WORDS_SCORE: f64 = 0.6;
const FILLER_WORDS: [&str; 10] = [
    "a", "an", "and", "for", "in", "of", "on", "the", "to", "with",
];
const RECENCY_HALF_LIFE: f64 = 14. * 24. * 3600.;

fn is_filler(token: &[char]) -> bool {
    let word: String = token.iter().collect();
    FILLER_WORDS.contains(&word.as_str())
}

/// A query folded and split into words once per keystroke.
#[derive(Clone, Debug)]
pub struct Query {
    text: String,
    characters: Vec<char>,
    tokens: Vec<Vec<char>>,
    /// Under four meaningful letters, so hidden keywords must match whole words.
    short: bool,
}

impl Query {
    pub fn new(raw: &str) -> Self {
        let text = normalize(raw);
        let characters = text.chars().collect();
        let tokens: Vec<Vec<char>> = text
            .split(' ')
            .filter(|token| !token.is_empty())
            .map(|token| token.chars().collect())
            .collect();
        // Filler words ("the ci") do not make a short query long.
        let meaningful: Vec<&Vec<char>> = tokens.iter().filter(|token| !is_filler(token)).collect();
        let words = if meaningful.is_empty() {
            tokens.iter().collect()
        } else {
            meaningful
        };
        let letters: usize = words.iter().map(|word| word.len()).sum();
        let short = letters + words.len().saturating_sub(1) < 4;
        Self {
            text,
            characters,
            tokens,
            short,
        }
    }
    /// Folded, with whitespace collapsed; empty when there is nothing to match.
    pub fn text(&self) -> &str {
        &self.text
    }
    pub fn is_empty(&self) -> bool {
        self.tokens.is_empty()
    }
    pub fn is_short(&self) -> bool {
        self.short
    }
}

/// One field a query is matched against.
#[derive(Clone, Copy, Debug, Default)]
pub struct WeightedField<'a> {
    pub value: &'a str,
    pub weight: f64,
    /// Only a whole-word match counts.
    pub whole_words: bool,
    /// Only a word-start match counts, without typos: hidden keywords must not match loosely.
    pub keyword: bool,
    /// Where the item lives (its project): helps a match but never makes it strong.
    pub context: bool,
    /// A word of four or more letters may match inside a word. Titles only.
    pub mid_word: bool,
}

impl<'a> WeightedField<'a> {
    pub fn new(value: &'a str, weight: f64) -> Self {
        Self {
            value,
            weight,
            ..Self::default()
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
    /// Matched character ranges in the first field.
    pub ranges: Vec<Range<usize>>,
}

struct Field {
    /// Case- and accent-folded, one entry per character of the source.
    text: Vec<char>,
    word_starts: Vec<bool>,
}

fn field(source: &str) -> Field {
    let characters: Vec<char> = source.chars().filter(|c| !is_combining_mark(*c)).collect();
    let mut text = Vec::with_capacity(characters.len());
    let mut word_starts = Vec::with_capacity(characters.len());
    for (index, &character) in characters.iter().enumerate() {
        text.push(fold(character));
        word_starts.push(is_word_start(
            index.checked_sub(2).map(|i| characters[i]),
            index.checked_sub(1).map(|i| characters[i]),
            character,
            characters.get(index + 1).copied(),
        ));
    }
    Field { text, word_starts }
}

/// The query folded and with whitespace collapsed; empty when there is nothing to match.
pub fn normalize(query: &str) -> String {
    let quotes = ['"', '\'', '`', '“', '”', '‘', '’'];
    let trimmed = query.trim().trim_matches(|c| quotes.contains(&c));
    let folded: String = trimmed
        .chars()
        .filter(|c| !is_combining_mark(*c))
        .map(fold)
        .collect();
    folded.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn is_combining_mark(c: char) -> bool {
    matches!(c as u32, 0x0300..=0x036F | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF | 0xFE20..=0xFE2F)
}

/// One character as searches compare it; None for a combining mark.
pub(crate) fn fold_char(character: char) -> Option<char> {
    (!is_combining_mark(character)).then(|| fold(character))
}

fn fold(character: char) -> char {
    if character.is_ascii() {
        return character.to_ascii_lowercase();
    }
    if character == '‘' || character == '’' {
        return '\'';
    }
    // Letters that fold to more than one character ("ẞ") stay as they are.
    let mut lower = character.to_lowercase();
    let lowered = match (lower.next(), lower.next()) {
        (Some(single), None) => single,
        _ => character,
    };
    strip_diacritic(lowered)
}

/// Foundation's diacritic-insensitive folding for the Latin letters that
/// decompose canonically; letters of their own (ø, ł, đ) keep their form.
fn strip_diacritic(c: char) -> char {
    match c {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' | 'ǎ' => 'a',
        'ç' | 'ć' | 'ĉ' | 'ċ' | 'č' => 'c',
        'ď' => 'd',
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ĕ' | 'ė' | 'ę' | 'ě' => 'e',
        'ĝ' | 'ğ' | 'ġ' | 'ģ' => 'g',
        'ĥ' => 'h',
        'ì' | 'í' | 'î' | 'ï' | 'ĩ' | 'ī' | 'ĭ' | 'į' | 'ǐ' => 'i',
        'ĵ' => 'j',
        'ķ' => 'k',
        'ĺ' | 'ļ' | 'ľ' => 'l',
        'ñ' | 'ń' | 'ņ' | 'ň' => 'n',
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ō' | 'ŏ' | 'ő' | 'ǒ' => 'o',
        'ŕ' | 'ŗ' | 'ř' => 'r',
        'ś' | 'ŝ' | 'ş' | 'š' | 'ș' => 's',
        'ţ' | 'ť' | 'ț' => 't',
        'ù' | 'ú' | 'û' | 'ü' | 'ũ' | 'ū' | 'ŭ' | 'ů' | 'ű' | 'ų' | 'ǔ' => 'u',
        'ŵ' => 'w',
        'ý' | 'ÿ' | 'ŷ' => 'y',
        'ź' | 'ż' | 'ž' => 'z',
        other => other,
    }
}

fn is_alphanumeric(character: Option<char>) -> bool {
    character.is_some_and(char::is_alphanumeric)
}

/// Unicode's Other Symbol category for the blocks names use: emoji,
/// pictographs, dingbats and technical symbols.
fn is_other_symbol(character: char) -> bool {
    matches!(character as u32,
        0x00A6 | 0x00A9 | 0x00AE | 0x00B0 | 0x2100..=0x214F | 0x2300..=0x23FF | 0x2460..=0x24FF
        | 0x2500..=0x27BF | 0x2B00..=0x2BFF | 0x1F000..=0x1FAFF)
}

fn is_cjk(character: char) -> bool {
    matches!(character as u32, 0x3040..=0x30FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xF900..=0xFAFF)
}

/// After a non-letter, at a camelCase or digit boundary, or at any Chinese or Japanese character.
fn is_word_start(
    before_previous: Option<char>,
    previous: Option<char>,
    character: char,
    next: Option<char>,
) -> bool {
    if !(character.is_alphanumeric() || is_other_symbol(character)) {
        return false;
    }
    // "Julius’s": a possessive does not start a word.
    if matches!(previous, Some('\'' | '’')) && is_alphanumeric(before_previous) {
        return false;
    }
    let Some(previous) = previous.filter(|previous| previous.is_alphanumeric()) else {
        return true;
    };
    if previous.is_lowercase() && character.is_uppercase() {
        return true;
    }
    if previous.is_uppercase() && character.is_uppercase() && next.is_some_and(char::is_lowercase) {
        return true;
    }
    if previous.is_numeric() != character.is_numeric() {
        return true;
    }
    is_cjk(character)
}

#[derive(Clone, Debug)]
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
fn occurrence(token: &[char], text: &[char], start: usize) -> Option<usize> {
    if token.is_empty() || token.len() > text.len() || start > text.len() - token.len() {
        return None;
    }
    (start..=text.len() - token.len()).find(|&index| text[index..index + token.len()] == *token)
}

fn match_token(
    field: &Field,
    token: &[char],
    typos: bool,
    primary: bool,
    mid_word: bool,
) -> Option<TokenMatch> {
    let &first = token.first()?;
    let text = &field.text;
    let mut best: Option<TokenMatch> = None;
    // A token that opens with punctuation (".ts") brings its own boundary.
    let own_boundary = !first.is_alphanumeric() && !is_other_symbol(first);
    let mut next = occurrence(token, text, 0);
    while let Some(index) = next {
        next = occurrence(token, text, index + 1);
        let end = index + token.len();
        if field.word_starts[index] || own_boundary {
            let whole = end >= text.len() || field.word_starts[end] || !text[end].is_alphanumeric();
            let mut run_end = end;
            while run_end < text.len() && text[run_end].is_alphanumeric() {
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
            best = Some(TokenMatch::new(MID_WORD_SCORE, index, end));
        }
    }
    if best
        .as_ref()
        .is_none_or(|best| best.score <= MID_WORD_SCORE)
        && primary
        && let Some(joined) = match_joined_words(field, token)
    {
        return Some(joined);
    }
    if best
        .as_ref()
        .is_some_and(|best| best.score > MID_WORD_SCORE)
    {
        return best;
    }
    if !typos || token.len() < 3 || !token.iter().any(|c| c.is_alphabetic()) {
        return best;
    }
    // A typo keeps the first letter, unless it swaps the first two of a longer word.
    for index in 0..text.len() {
        if !field.word_starts[index] {
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
        while run_end < text.len() && text[run_end].is_alphanumeric() {
            run_end += 1;
        }
        let short = token.len() <= 4;
        let lengths = if short {
            vec![token.len(), token.len() + 1]
        } else {
            vec![token.len(), token.len() - 1, token.len() + 1]
        };
        for length in lengths {
            if length > run_end - index {
                continue;
            }
            if within_one_edit(
                token,
                &text[index..index + length],
                short && length == token.len(),
            ) {
                return Some(TokenMatch::new(TYPO_SCORE, index, index + length));
            }
        }
    }
    best
}

/// One substitution, insertion, deletion or swap of neighbours; with `swap_only`, only a swap.
fn within_one_edit(left: &[char], right: &[char], swap_only: bool) -> bool {
    if left.len().abs_diff(right.len()) > if swap_only { 0 } else { 1 } {
        return false;
    }
    let common = left.iter().zip(right).take_while(|(a, b)| a == b).count();
    let rest_left = &left[common..];
    let rest_right = &right[common..];
    let tail =
        |slice: &'_ [char], from: usize| -> Vec<char> { slice.get(from..).unwrap_or(&[]).to_vec() };
    let swapped = rest_left.len() > 1
        && rest_right.len() > 1
        && rest_left[0] == rest_right[1]
        && rest_left[1] == rest_right[0]
        && tail(rest_left, 2) == tail(rest_right, 2);
    if swap_only {
        return swapped;
    }
    swapped
        || rest_left == rest_right
        || tail(rest_left, 1) == tail(rest_right, 1)
        || tail(rest_left, 1) == rest_right
        || rest_left == tail(rest_right, 1).as_slice()
}

fn word_end(field: &Field, index: usize) -> usize {
    let mut end = index + 1;
    while end < field.text.len() && !field.word_starts[end] && field.text[end].is_alphanumeric() {
        end += 1;
    }
    end
}

/// Words typed together: "vscode" for "VS Code". Short fragments only count at the start of the
/// name, before three letters, or as a whole word, so "inth" does not find "in thread".
fn match_joined_words(field: &Field, token: &[char]) -> Option<TokenMatch> {
    let text = &field.text;
    let first_word = field.word_starts.iter().position(|start| *start);
    for start in 0..text.len() {
        if !field.word_starts[start] || text[start] != token[0] {
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
                while at < text.len() && !field.word_starts[at] {
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
                score: JOINED_WORDS_SCORE,
                start,
                end: last.end,
                letters: Some(runs),
            });
        }
    }
    None
}

/// Every query word must match some field. Quality is the mean of each word's best weighted
/// match, plus a bonus when the first field equals or contains the whole query.
pub fn match_fields(query: &Query, fields: &[WeightedField<'_>], typos: bool) -> Option<Match> {
    let tokens = &query.tokens;
    if tokens.is_empty() {
        return None;
    }
    let prepared: Vec<(Field, &WeightedField<'_>)> = fields
        .iter()
        .filter(|spec| !spec.value.is_empty())
        .map(|spec| (field(spec.value), spec))
        .collect();
    let has_primary = fields.first().is_some_and(|spec| !spec.value.is_empty());
    let filler_optional = tokens.iter().any(|token| !is_filler(token));
    let mut ranges: Vec<Range<usize>> = Vec::new();
    let mut total = 0.;
    let mut counted = 0usize;
    let mut strong = true;
    for token in tokens {
        let mut best: f64 = 0.;
        let mut best_primary: Option<TokenMatch> = None;
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
                0.
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
        if best == 0. {
            if filler_optional && is_filler(token) {
                continue;
            }
            return None;
        }
        strong = strong && at_word_start;
        if let Some(primary) = best_primary {
            match primary.letters {
                Some(letters) => ranges.extend(letters),
                None => ranges.push(primary.start..primary.end),
            }
        }
        total += best;
        counted += 1;
    }
    if counted == 0 {
        return None;
    }
    let mut quality = total / counted as f64;
    if has_primary && let Some((primary, _)) = prepared.first() {
        if primary.text == query.characters {
            quality += WHOLE_NAME - WHOLE_WORD;
        } else if tokens.len() > 1 && occurrence(&query.characters, &primary.text, 0).is_some() {
            quality += 0.25;
        }
    }
    Some(Match {
        quality,
        score: quality,
        group_quality: None,
        strong,
        ranges: if has_primary {
            merge(ranges)
        } else {
            Vec::new()
        },
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

/// A thread: its title counts fully, its branch less, its project least.
/// Recently active threads rank higher among matches of the same quality.
/// `updated_at` and `now` are seconds on any one clock.
#[allow(clippy::too_many_arguments)]
pub fn score_thread(
    query: &Query,
    title: &str,
    branch: Option<&str>,
    project: Option<&str>,
    updated_at: f64,
    typos: bool,
    branch_prefix: &str,
    now: f64,
) -> Option<Match> {
    let mut fields = vec![WeightedField {
        mid_word: true,
        ..WeightedField::new(title, 1.)
    }];
    if let Some(mut branch) = branch.filter(|branch| !branch.is_empty()) {
        if !branch_prefix.is_empty()
            && branch.starts_with(branch_prefix)
            && branch.chars().count() > branch_prefix.chars().count()
        {
            branch = &branch[branch_prefix.len()..];
        }
        fields.push(WeightedField::new(branch, 0.6));
    }
    if let Some(project) = project.filter(|project| !project.is_empty()) {
        fields.push(WeightedField {
            context: true,
            ..WeightedField::new(project, 0.25)
        });
    }
    let mut found = match_fields(query, &fields, typos)?;
    let recency = 2f64.powf(-(now - updated_at).max(0.) / RECENCY_HALF_LIFE);
    found.score = found.quality * 3f64.min(1. + recency);
    // A thread titled like a command never lifts its group above that command.
    found.group_quality = Some(found.quality.min(WHOLE_NAME - 0.01));
    Some(found)
}

/// A command or project: its name, plus keywords that count less.
pub fn score_terms(query: &Query, name: &str, keywords: &[&str], typos: bool) -> Option<Match> {
    // Short queries need whole keywords, or "co" would list most commands.
    let short = query.short;
    let mut fields = vec![WeightedField::new(name, 1.)];
    fields.extend(keywords.iter().map(|keyword| WeightedField {
        whole_words: short,
        keyword: true,
        ..WeightedField::new(keyword, if short { 0.8 } else { 0.6 })
    }));
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

/// Ranks every group's items and orders the groups by their best match class, keeping their
/// given order on ties. Typos are only tried when nothing matches at a word start.
pub fn rank<G: Clone, I: Clone>(
    groups: &[(G, Vec<I>)],
    mut score: impl FnMut(&I, bool) -> Option<Match>,
) -> Vec<(G, Vec<(I, Match)>)> {
    let mut run = |typos: bool| -> Vec<(G, Vec<(I, Match)>)> {
        groups
            .iter()
            .map(|(group, items)| {
                (
                    group.clone(),
                    items
                        .iter()
                        .filter_map(|item| score(item, typos).map(|found| (item.clone(), found)))
                        .collect(),
                )
            })
            .collect()
    };
    let mut ranked = run(false);
    if !ranked
        .iter()
        .any(|(_, items)| items.iter().any(|(_, found)| found.strong))
    {
        ranked = run(true);
    }
    let mut ordered: Vec<_> = ranked
        .into_iter()
        .enumerate()
        .filter(|(_, (_, items))| !items.is_empty())
        .map(|(order, (group, mut items))| {
            let best = items
                .iter()
                .map(|(_, found)| match_class(found.group_quality.unwrap_or(found.quality)))
                .max()
                .unwrap_or(0);
            // Stable, as Swift's sort keeps equal items in their given order here.
            items.sort_by(|(_, left), (_, right)| {
                let (left_class, right_class) =
                    (match_class(left.quality), match_class(right.quality));
                right_class
                    .min(2)
                    .cmp(&left_class.min(2))
                    .then(right_class.cmp(&left_class))
                    .then(right.score.total_cmp(&left.score))
            });
            (best, order, group, items)
        })
        .collect();
    ordered.sort_by(|left, right| right.0.cmp(&left.0).then(left.1.cmp(&right.1)));
    ordered
        .into_iter()
        .map(|(_, _, group, items)| (group, items))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    const NOW: f64 = 800_000_000.;
    const DAY: f64 = 24. * 3600.;

    #[derive(Clone)]
    struct Subject {
        title: &'static str,
        branch: Option<&'static str>,
        project: Option<&'static str>,
        updated_at: f64,
    }
    fn thread(title: &'static str) -> Subject {
        aged(title, 30.)
    }
    fn aged(title: &'static str, days_ago: f64) -> Subject {
        Subject {
            title,
            branch: None,
            project: None,
            updated_at: NOW - days_ago * DAY,
        }
    }
    fn spans(found: Option<Match>) -> Vec<(usize, usize)> {
        found
            .unwrap()
            .ranges
            .into_iter()
            .map(|range| (range.start, range.end))
            .collect()
    }
    fn score(query: &str, subject: &Subject) -> Option<Match> {
        score_with(query, subject, false, "")
    }
    fn score_with(query: &str, subject: &Subject, typos: bool, prefix: &str) -> Option<Match> {
        score_thread(
            &Query::new(query),
            subject.title,
            subject.branch,
            subject.project,
            subject.updated_at,
            typos,
            prefix,
            NOW,
        )
    }
    fn rank_titles(query: &str, threads: &[Subject]) -> Vec<&'static str> {
        rank_prefixed(query, threads, "")
    }
    fn rank_prefixed(query: &str, threads: &[Subject], prefix: &str) -> Vec<&'static str> {
        let parsed = Query::new(query);
        rank(&[("threads", threads.to_vec())], |subject, typos| {
            score_thread(
                &parsed,
                subject.title,
                subject.branch,
                subject.project,
                subject.updated_at,
                typos,
                prefix,
                NOW,
            )
        })
        .into_iter()
        .flat_map(|(_, items)| items.into_iter().map(|(item, _)| item.title))
        .collect()
    }

    #[test]
    fn whole_words_rank_over_prefixes_over_newer_mid_word_matches() {
        assert_eq!(
            rank_titles(
                "auth",
                &[
                    aged("Fix oauth redirect", 0.),
                    thread("Authentication cleanup"),
                    thread("Share auth across worktrees"),
                ]
            ),
            [
                "Share auth across worktrees",
                "Authentication cleanup",
                "Fix oauth redirect"
            ]
        );
    }

    #[test]
    fn camel_case_kebab_path_and_digit_boundaries_start_words() {
        assert_eq!(
            spans(score("search", &thread("useThreadSearch hook"))),
            [(9, 15)]
        );
        assert_eq!(
            spans(score("perf", &thread("fix/sidebar-perf"))),
            [(12, 16)]
        );
        assert_eq!(spans(score("12", &thread("Upgrade to pnpm12"))), [(15, 17)]);
        assert_eq!(
            spans(score("sch", &thread("Fix JSONSchema parsing"))),
            [(8, 11)]
        );
        assert_eq!(
            spans(score("ser", &thread("Fix HTTPServer crash"))),
            [(8, 11)]
        );
        assert_eq!(spans(score(".ts", &thread("Rename index.ts"))), [(12, 15)]);
        assert!(score("githuba", &thread("GitHubActions setup")).map_or(1., |m| m.quality) < 1.);
        assert_eq!(
            rank_titles(
                ".ts",
                &[thread("Fix parser.tsx"), thread("Rename index.ts")]
            ),
            ["Rename index.ts", "Fix parser.tsx"]
        );
        assert!(score("ci", &thread("Decision log")).is_none());
    }

    #[test]
    fn recent_activity_decides_between_equal_matches() {
        assert_eq!(
            rank_titles(
                "goldbug",
                &[aged("Goldbug epilogue", 20.), aged("Goldbug processes", 1.)]
            ),
            ["Goldbug processes", "Goldbug epilogue"]
        );
    }

    #[test]
    fn inside_word_matches_count_only_in_titles() {
        assert_eq!(
            score("arch", &thread("Research notes")).unwrap().quality,
            0.3
        );
        let branch = Subject {
            branch: Some("research-extension-system"),
            ..thread("Notes")
        };
        assert!(score("arch", &branch).is_none());
        assert!(score_terms(&Query::new("arch"), "Search project contents", &[], false).is_none());
    }

    #[test]
    fn one_typo_is_forgiven_only_when_nothing_matches_exactly() {
        let threads = [
            thread("Hosting alternatives to Railway"),
            thread("Trim MCP model lists"),
        ];
        assert_eq!(
            rank_titles("railwya", &threads),
            ["Hosting alternatives to Railway"]
        );
        assert_eq!(rank_titles("trim mpc", &threads), ["Trim MCP model lists"]);
        assert_eq!(
            rank_titles(
                "drga",
                &[
                    thread("Restore drag handles"),
                    thread("Organize indicators")
                ]
            ),
            ["Restore drag handles"]
        );
        assert_eq!(
            rank_titles("t3coed", &[thread("t3code perf audit"), thread("Other")]),
            ["t3code perf audit"]
        );
        assert_eq!(
            rank_titles("oath2", &[thread("Fix oauth2 redirect")]),
            ["Fix oauth2 redirect"]
        );
        assert_eq!(
            rank_titles(
                "ilde",
                &[
                    thread("Typesafe App Builder"),
                    thread("De-risk idle tunnel cleanup")
                ]
            ),
            ["De-risk idle tunnel cleanup", "Typesafe App Builder"]
        );
        assert!(rank_titles("ing", &[thread("Nightly build fix")]).is_empty());
        assert_eq!(
            rank_titles("srv", &[thread("Server restart"), thread("Other")]),
            ["Server restart"]
        );
        assert_eq!(
            rank_titles("sidb", &[thread("Fix sidebar lag")]),
            ["Fix sidebar lag"]
        );
        assert!(rank_titles("cron", &[thread("Config cleanup")]).is_empty());
        assert_eq!(
            rank_titles("githbu", &[thread("GitHub API usage"), thread("Other")]),
            ["GitHub API usage"]
        );
        assert_eq!(
            rank_titles("macso", &[thread("Fix macOS window"), thread("Other")]),
            ["Fix macOS window"]
        );
        assert_eq!(
            rank_titles(
                "cmd enter",
                &[thread("Fix Cmd+Enter"), thread("Open links external")]
            ),
            ["Fix Cmd+Enter"]
        );
    }

    #[test]
    fn typos_are_forgiven_in_names_but_not_in_hidden_keywords() {
        let query = Query::new("keybindngs");
        let groups = vec![
            (
                "actions",
                vec![("Open settings", vec!["preferences", "keybindings"])],
            ),
            ("settings", vec![("Keybindings", vec!["General"])]),
        ];
        let ranked = rank(&groups, |(name, keywords), typos| {
            score_terms(&query, name, keywords, typos)
        });
        assert_eq!(
            ranked.iter().map(|(group, _)| *group).collect::<Vec<_>>(),
            ["settings"]
        );
        assert!(
            score_terms(
                &Query::new("duckdb"),
                "Search engine",
                &["duckduckgo"],
                true
            )
            .is_none()
        );
        assert!(score_terms(&Query::new("rust"), "GitHub sharing", &["trusted"], false).is_none());
        assert!(
            score_terms(
                &Query::new("the ci"),
                "Context window indicator",
                &["circle"],
                false
            )
            .is_none()
        );
    }

    #[test]
    fn filler_words_are_optional_in_phrases_but_not_alone() {
        assert_eq!(
            rank_titles("fix the sidebar", &[thread("Fix Sidebar Lag")]),
            ["Fix Sidebar Lag"]
        );
        assert!(rank_titles("the", &[thread("Fix sidebar lag")]).is_empty());
    }

    #[test]
    fn quotes_apostrophes_accents_and_marks_fold() {
        assert_eq!(
            rank_titles("don't", &[thread("Don’t merge yet")]),
            ["Don’t merge yet"]
        );
        assert_eq!(
            rank_titles("\"sidebar lag\"", &[thread("Fix sidebar lag")]),
            ["Fix sidebar lag"]
        );
        assert_eq!(
            rank_titles("cafe\u{0301}", &[thread("Café menu")]),
            ["Café menu"]
        );
        assert_eq!(rank_titles("CAFE", &[thread("Le café")]), ["Le café"]);
        assert_eq!(normalize("  \"Fix   the\tbug\"  "), "fix the bug");
    }

    #[test]
    fn queries_that_fold_to_nothing_find_nothing() {
        for query in ["#", "´´´", "   "] {
            assert!(
                rank_titles(query, &[thread("Fix sidebar lag")]).is_empty(),
                "{query}"
            );
        }
        assert!(Query::new("  ").is_empty());
    }

    #[test]
    fn letters_and_numbers_typed_together_match_without_forgiving_number_typos() {
        let threads = [
            thread("Upgrade to pnpm 12"),
            thread("GPT-5 eval"),
            thread("iOS 26 support"),
            thread("Other"),
        ];
        assert_eq!(rank_titles("pnpm12", &threads), ["Upgrade to pnpm 12"]);
        assert_eq!(rank_titles("gpt5", &threads), ["GPT-5 eval"]);
        assert_eq!(rank_titles("ios26", &threads), ["iOS 26 support"]);
        assert!(rank_titles("pnpm13", &threads).is_empty());
    }

    #[test]
    fn whole_words_typed_together_match_but_scattered_letters_do_not() {
        let threads = [
            thread("VS Code extension settings"),
            thread("Fix UI bug in sidebar"),
            thread("I plan to open source all of lakebed in the next few weeks"),
        ];
        assert_eq!(
            rank_titles("vscode", &threads),
            ["VS Code extension settings"]
        );
        assert_eq!(rank_titles("fixuibug", &threads), ["Fix UI bug in sidebar"]);
        assert!(rank_titles("lint", &threads).is_empty());
        assert!(rank_titles("inth", &[thread("Show skill names in thread overview")]).is_empty());
        assert!(rank_titles("tos", &[thread("Move Client State to Server")]).is_empty());
        assert_eq!(
            rank_titles("t3co", &[thread("T3 Code vs Gemini")]),
            ["T3 Code vs Gemini"]
        );
        assert_eq!(
            rank_titles("gomod", &[thread("Migrate to Go modules")]),
            ["Migrate to Go modules"]
        );
        assert_eq!(
            score("vscode", &thread("Fixvscode and VS Code"))
                .unwrap()
                .quality,
            0.6
        );
    }

    #[test]
    fn a_word_and_the_start_of_the_next_highlight_each_part() {
        let threads = [thread("Fix sidebar lag"), thread("Unrelated work")];
        assert_eq!(rank_titles("fixsid", &threads), ["Fix sidebar lag"]);
        assert_eq!(
            rank_titles("fixsid", &[thread("Feature: Fix sidebar lag")]),
            ["Feature: Fix sidebar lag"]
        );
        assert_eq!(spans(score("fixsid", &threads[0])), [(0, 3), (4, 7)]);
        assert!(rank_titles("fsl", &threads).is_empty());
    }

    #[test]
    fn nothing_is_found_rather_than_an_unrelated_thread() {
        let threads = [
            thread("Projectless threads without Git"),
            thread("Concern about connection setup"),
            thread("Simplify worktree thread creation"),
            thread("Start a new conversation"),
            thread("Setting up the sentinel"),
            thread("I plan to open source all of lakebed in the next few weeks"),
            thread("Design notes"),
            thread("Link pull request to thread"),
        ];
        for query in ["posthog", "cron", "stripe", "gpu", "fxsb", "lint", "deno"] {
            assert!(rank_titles(query, &threads).is_empty(), "{query}");
        }
    }

    #[test]
    fn emoji_and_chinese_or_japanese_characters_match() {
        assert_eq!(
            rank_titles(
                "🚀",
                &[thread("🚀 Launch checklist"), thread("Launch notes")]
            ),
            ["🚀 Launch checklist"]
        );
        assert!(score("搜索", &thread("实现全文搜索")).is_some());
        assert!(score("検索", &thread("新しい検索機能")).is_some());
    }

    #[test]
    fn branches_and_projects_match_but_count_less_than_titles() {
        let subject = Subject {
            branch: Some("trim-mcp-models"),
            project: Some("t3code"),
            ..thread("Trim model lists")
        };
        for query in ["trim mcp", "models trim", "trim t3code"] {
            assert!(score(query, &subject).is_some(), "{query}");
        }
        assert!(score("trim lakebed", &subject).is_none());
        let title = score("lists", &subject).unwrap();
        let branch = score("mcp", &subject).unwrap();
        let project = score("t3code", &subject).unwrap();
        assert!(title.quality > branch.quality);
        assert!(branch.quality > project.quality);
        assert!(!project.strong);
        assert!(title.strong && branch.strong);
        assert!(branch.ranges.is_empty());
    }

    #[test]
    fn the_worktree_branch_prefix_is_not_part_of_what_the_branch_says() {
        let subject = Subject {
            branch: Some("coincide/cmdk-search-v2"),
            ..thread("Cmd+K search")
        };
        assert!(score_with("coincide", &subject, false, "coincide/").is_none());
        assert!(score("coincide", &subject).is_some());
        assert!(score_with("cmdk", &subject, false, "coincide/").is_some());
        let only = Subject {
            branch: Some("coincide/"),
            ..thread("x")
        };
        assert!(score_with("coincide", &only, false, "coincide/").is_some());
    }

    #[test]
    fn a_title_holding_the_words_ranks_above_the_worktree_prefix_and_project_name() {
        let busy = Subject {
            branch: Some("t3/diagnose-connect"),
            project: Some("t3code"),
            ..aged("Diagnose Connect provisioning failures", 0.)
        };
        let named = Subject {
            project: Some("t3code"),
            ..thread("T3 Connect Tunnel Lifecycle Review")
        };
        assert_eq!(
            rank_prefixed("t3 connect", &[busy, named], "t3/")
                .first()
                .copied(),
            Some("T3 Connect Tunnel Lifecycle Review")
        );
        let sidebar = Subject {
            branch: Some("t3code/sidebar"),
            project: Some("t3code"),
            ..aged("Fix sidebar lag", 0.)
        };
        let gemini = Subject {
            project: Some("slophouse"),
            ..thread("T3 Code vs Gemini Token Volume")
        };
        assert_eq!(
            rank_prefixed("t3code", &[sidebar, gemini], "t3code/")
                .first()
                .copied(),
            Some("T3 Code vs Gemini Token Volume")
        );
    }

    #[test]
    fn groups_are_ordered_by_their_best_match_and_keep_their_order_on_ties() {
        let query = Query::new("settings");
        let ranked = rank(
            &[
                ("actions", vec!["Open settings", "New thread"]),
                ("threads", vec!["Settings sync rewrite", "Thread settings"]),
                ("projects", vec!["Settings app"]),
            ],
            |name, typos| score_terms(&query, name, &[], typos),
        );
        assert_eq!(
            ranked.iter().map(|(group, _)| *group).collect::<Vec<_>>(),
            ["actions", "threads", "projects"]
        );
        assert_eq!(
            ranked
                .iter()
                .map(|(_, items)| items.iter().map(|(item, _)| *item).collect::<Vec<_>>())
                .collect::<Vec<_>>(),
            vec![
                vec!["Open settings"],
                vec!["Settings sync rewrite", "Thread settings"],
                vec!["Settings app"]
            ]
        );
    }

    #[test]
    fn typos_are_tried_only_when_nothing_matches_at_a_word_start() {
        let mut calls = Vec::new();
        rank(&[("g", vec!["Fix sidebar"])], |name, typos| {
            calls.push(typos);
            score_terms(&Query::new("sidebar"), name, &[], typos)
        });
        assert_eq!(calls, [false]);
        calls.clear();
        let ranked = rank(&[("g", vec!["Fix sidebar"])], |name, typos| {
            calls.push(typos);
            score_terms(&Query::new("sidbear"), name, &[], typos)
        });
        assert_eq!(calls, [false, true]);
        assert!(!ranked[0].1[0].1.strong);
    }

    #[test]
    fn keyword_only_matches_rank_below_name_matches_as_a_group() {
        let found = score_terms(
            &Query::new("preferences"),
            "Open Settings",
            &["preferences"],
            false,
        )
        .unwrap();
        assert!(found.ranges.is_empty());
        assert!(found.group_quality.unwrap() <= 0.65);
    }

    #[test]
    fn match_classes_whole_names_and_short_queries() {
        assert_eq!([1.5, 1.0, 0.7, 0.45, 0.3].map(match_class), [3, 2, 2, 1, 0]);
        let exact = score_terms(&Query::new("open settings"), "Open Settings", &[], false).unwrap();
        assert_eq!(exact.quality, 1.5);
        let contained = score_terms(
            &Query::new("open settings"),
            "Open Settings Now",
            &[],
            false,
        )
        .unwrap();
        assert_eq!(contained.quality, 1.25);
        assert!(Query::new("co").is_short());
        assert!(Query::new("the ci").is_short());
        assert!(Query::new("a b").is_short());
        assert!(!Query::new("abcd").is_short());
        assert!(!Query::new("ab cd").is_short());
        assert!(score_terms(&Query::new("co"), "Show Diff", &["commit"], false).is_none());
        assert!(score_terms(&Query::new("git"), "Show Diff", &["git"], false).is_some());
    }
}
