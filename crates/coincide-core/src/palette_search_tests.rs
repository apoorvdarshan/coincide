//! Swift's `PaletteSearchTests` (cases ported from T3 Code's
//! `paletteSearch.test.ts`). Highlight ranges are UTF-8 byte ranges here.
use super::*;

const NOW: f64 = 800_000_000.0;
const DAY: f64 = 24.0 * 3600.0;

struct Subject {
    title: &'static str,
    branch: &'static str,
    project: &'static str,
    updated: f64,
}
fn thread(title: &'static str) -> Subject {
    full(title, "", "", 30.0)
}
fn full(title: &'static str, branch: &'static str, project: &'static str, days: f64) -> Subject {
    Subject {
        title,
        branch,
        project,
        updated: NOW - days * DAY,
    }
}
fn score_with(query: &str, subject: &Subject, typos: bool, prefix: &str) -> Option<Match> {
    score_thread(
        &Query::new(query),
        &Field::new(subject.title),
        &Field::new(searchable_branch(subject.branch, prefix)),
        &Field::new(subject.project),
        subject.updated,
        NOW,
        typos,
    )
}
fn score(query: &str, subject: &Subject) -> Option<Match> {
    score_with(query, subject, false, "")
}
fn titles_with(query: &str, threads: &[Subject], prefix: &str) -> Vec<&'static str> {
    let query = Query::new(query);
    let fields = threads
        .iter()
        .map(|subject| {
            (
                Field::new(subject.title),
                Field::new(searchable_branch(subject.branch, prefix)),
                Field::new(subject.project),
            )
        })
        .collect::<Vec<_>>();
    rank(&[threads.len()], |_, item, typos| {
        let (title, branch, project) = &fields[item];
        score_thread(
            &query,
            title,
            branch,
            project,
            threads[item].updated,
            NOW,
            typos,
        )
    })
    .into_iter()
    .flat_map(|(_, items)| items.into_iter().map(|(item, _)| threads[item].title))
    .collect()
}
fn titles(query: &str, threads: &[Subject]) -> Vec<&'static str> {
    titles_with(query, threads, "")
}
/// One highlighted byte range.
fn one(start: usize, end: usize) -> Vec<std::ops::Range<usize>> {
    std::iter::once(start..end).collect()
}
fn terms(query: &str, name: &str, keywords: &[&str], typos: bool) -> Option<Match> {
    let keywords = keywords.iter().map(|k| Field::new(k)).collect::<Vec<_>>();
    score_terms(&Query::new(query), &Field::new(name), &keywords, typos)
}

#[test]
fn whole_words_rank_over_prefixes_over_newer_mid_word_matches() {
    assert_eq!(
        titles(
            "auth",
            &[
                full("Fix oauth redirect", "", "", 0.0),
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
    let ranges = |query: &str, title: &'static str| score(query, &thread(title)).map(|m| m.ranges);
    assert_eq!(ranges("search", "useThreadSearch hook"), Some(one(9, 15)));
    assert_eq!(ranges("perf", "fix/sidebar-perf"), Some(one(12, 16)));
    assert_eq!(ranges("12", "Upgrade to pnpm12"), Some(one(15, 17)));
    assert_eq!(ranges("sch", "Fix JSONSchema parsing"), Some(one(8, 11)));
    assert_eq!(ranges("ser", "Fix HTTPServer crash"), Some(one(8, 11)));
    assert_eq!(ranges(".ts", "Rename index.ts"), Some(one(12, 15)));
    // A match is whole only where a word ends: "githuba" does not fill "GitHubActions".
    assert!(score("githuba", &thread("GitHubActions setup")).map_or(1.0, |m| m.quality) < 1.0);
    assert_eq!(
        titles(
            ".ts",
            &[thread("Fix parser.tsx"), thread("Rename index.ts")]
        ),
        ["Rename index.ts", "Fix parser.tsx"]
    );
    // Short tokens never match inside a word.
    assert!(score("ci", &thread("Decision log")).is_none());
}

#[test]
fn recent_activity_decides_between_equal_matches() {
    assert_eq!(
        titles(
            "goldbug",
            &[
                full("Goldbug epilogue", "", "", 20.0),
                full("Goldbug processes", "", "", 1.0)
            ]
        ),
        ["Goldbug processes", "Goldbug epilogue"]
    );
}

#[test]
fn inside_word_matches_count_only_in_titles() {
    assert_eq!(
        score("arch", &thread("Research notes")).map(|m| m.quality),
        Some(0.3)
    );
    assert!(
        score(
            "arch",
            &full("Notes", "research-extension-system", "", 30.0)
        )
        .is_none()
    );
    assert!(terms("arch", "Search project contents", &[], false).is_none());
}

#[test]
fn one_typo_is_forgiven_only_when_nothing_matches_exactly() {
    let threads = [
        thread("Hosting alternatives to Railway"),
        thread("Trim MCP model lists"),
    ];
    assert_eq!(
        titles("railwya", &threads),
        ["Hosting alternatives to Railway"]
    );
    assert_eq!(titles("trim mpc", &threads), ["Trim MCP model lists"]);
    assert_eq!(
        titles(
            "drga",
            &[
                thread("Restore drag handles"),
                thread("Organize indicators")
            ]
        ),
        ["Restore drag handles"]
    );
    // Words with digits still forgive one.
    assert_eq!(
        titles("t3coed", &[thread("t3code perf audit"), thread("Other")]),
        ["t3code perf audit"]
    );
    assert_eq!(
        titles("oath2", &[thread("Fix oauth2 redirect")]),
        ["Fix oauth2 redirect"]
    );
    // A typo beats a mid-word accident: "ilde" is "idle", not the middle of "Builder".
    assert_eq!(
        titles(
            "ilde",
            &[
                thread("Typesafe App Builder"),
                thread("De-risk idle tunnel cleanup")
            ]
        ),
        ["De-risk idle tunnel cleanup", "Typesafe App Builder"]
    );
    // "ing" is not "Nightly": a three-letter typo keeps the first letter.
    assert!(titles("ing", &[thread("Nightly build fix")]).is_empty());
    // A short word may miss one letter while it is typed, but not change one.
    assert_eq!(
        titles("srv", &[thread("Server restart"), thread("Other")]),
        ["Server restart"]
    );
    assert_eq!(
        titles("sidb", &[thread("Fix sidebar lag")]),
        ["Fix sidebar lag"]
    );
    assert!(titles("cron", &[thread("Config cleanup")]).is_empty());
    // Typos count across camelCase joins.
    assert_eq!(
        titles("githbu", &[thread("GitHub API usage"), thread("Other")]),
        ["GitHub API usage"]
    );
    assert_eq!(
        titles("macso", &[thread("Fix macOS window"), thread("Other")]),
        ["Fix macOS window"]
    );
    // "enter" is not "external" when the right thread is already there.
    assert_eq!(
        titles(
            "cmd enter",
            &[thread("Fix Cmd+Enter"), thread("Open links external")]
        ),
        ["Fix Cmd+Enter"]
    );
}

#[test]
fn typos_are_forgiven_in_names_but_not_in_hidden_keywords() {
    let query = Query::new("keybindngs");
    let groups = [
        vec![("Open settings", vec!["preferences", "keybindings"])],
        vec![("Keybindings", vec!["General"])],
    ];
    let ranked = rank(&[1, 1], |group, item, typos| {
        let (name, keywords) = &groups[group][item];
        let keywords = keywords.iter().map(|k| Field::new(k)).collect::<Vec<_>>();
        score_terms(&query, &Field::new(name), &keywords, typos)
    });
    assert_eq!(
        ranked.iter().map(|(group, _)| *group).collect::<Vec<_>>(),
        [1]
    );
    assert!(terms("duckdb", "Search engine", &["duckduckgo"], true).is_none());
    assert!(terms("rust", "GitHub sharing", &["trusted"], false).is_none());
    // Filler words do not make a short query long enough for keyword prefixes.
    assert!(terms("the ci", "Context window indicator", &["circle"], false).is_none());
}

#[test]
fn filler_words_are_optional_in_phrases_but_not_alone() {
    assert_eq!(
        titles("fix the sidebar", &[thread("Fix Sidebar Lag")]),
        ["Fix Sidebar Lag"]
    );
    assert!(titles("the", &[thread("Fix sidebar lag")]).is_empty());
}

#[test]
fn quotes_apostrophes_accents_and_marks_fold() {
    assert_eq!(
        titles("don't", &[thread("Don’t merge yet")]),
        ["Don’t merge yet"]
    );
    assert_eq!(
        titles("\"sidebar lag\"", &[thread("Fix sidebar lag")]),
        ["Fix sidebar lag"]
    );
    assert_eq!(
        titles("cafe\u{0301}", &[thread("Café menu")]),
        ["Café menu"]
    );
    assert_eq!(titles("CAFE", &[thread("Le café")]), ["Le café"]);
    assert_eq!(normalize("  \"Fix   the\tbug\"  "), "fix the bug");
}

#[test]
fn queries_that_fold_to_nothing_find_nothing() {
    assert!(titles("#", &[thread("Fix sidebar lag")]).is_empty());
    assert!(titles("´´´", &[thread("Fix sidebar lag")]).is_empty());
    assert!(titles("   ", &[thread("Fix sidebar lag")]).is_empty());
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
    assert_eq!(titles("pnpm12", &threads), ["Upgrade to pnpm 12"]);
    assert_eq!(titles("gpt5", &threads), ["GPT-5 eval"]);
    assert_eq!(titles("ios26", &threads), ["iOS 26 support"]);
    assert!(titles("pnpm13", &threads).is_empty());
}

#[test]
fn whole_words_typed_together_match_but_scattered_letters_do_not() {
    let threads = [
        thread("VS Code extension settings"),
        thread("Fix UI bug in sidebar"),
        thread("I plan to open source all of lakebed in the next few weeks"),
    ];
    assert_eq!(titles("vscode", &threads), ["VS Code extension settings"]);
    assert_eq!(titles("fixuibug", &threads), ["Fix UI bug in sidebar"]);
    assert!(titles("lint", &threads).is_empty());
    // Short words before a mere prefix are a coincidence.
    assert!(titles("inth", &[thread("Show skill names in thread overview")]).is_empty());
    assert!(titles("tos", &[thread("Move Client State to Server")]).is_empty());
    assert_eq!(
        titles("t3co", &[thread("T3 Code vs Gemini")]),
        ["T3 Code vs Gemini"]
    );
    // Three letters of the last word are enough, as it is typed.
    assert_eq!(
        titles("gomod", &[thread("Migrate to Go modules")]),
        ["Migrate to Go modules"]
    );
    // Joined words beat an earlier match inside a word.
    assert_eq!(
        score("vscode", &thread("Fixvscode and VS Code")).map(|m| m.quality),
        Some(0.6)
    );
}

#[test]
fn a_word_and_the_start_of_the_next_highlight_each_part() {
    let threads = [thread("Fix sidebar lag"), thread("Unrelated work")];
    assert_eq!(titles("fixsid", &threads), ["Fix sidebar lag"]);
    assert_eq!(
        titles("fixsid", &[thread("Feature: Fix sidebar lag")]),
        ["Feature: Fix sidebar lag"]
    );
    assert_eq!(
        score("fixsid", &threads[0]).map(|m| m.ranges),
        Some(vec![0..3, 4..7])
    );
    // Initials are not words typed together.
    assert!(titles("fsl", &threads).is_empty());
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
        assert!(titles(query, &threads).is_empty(), "{query}");
    }
}

#[test]
fn emoji_and_chinese_or_japanese_characters_match() {
    assert_eq!(
        titles(
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
    let subject = full("Trim model lists", "trim-mcp-models", "t3code", 30.0);
    for query in ["trim mcp", "models trim", "trim t3code"] {
        assert!(score(query, &subject).is_some(), "{query}");
    }
    assert!(score("trim lakebed", &subject).is_none());
    let title = score("lists", &subject).unwrap();
    let branch = score("mcp", &subject).unwrap();
    let project = score("t3code", &subject).unwrap();
    assert!(title.quality > branch.quality);
    assert!(branch.quality > project.quality);
    // The project only helps a match; it never makes it strong.
    assert!(!project.strong);
    assert!(title.strong && branch.strong);
    // Only the title is highlighted.
    assert!(branch.ranges.is_empty());
}

#[test]
fn the_worktree_branch_prefix_is_not_part_of_what_the_branch_says() {
    let subject = full("Cmd+K search", "coincide/cmdk-search-v2", "", 30.0);
    assert!(score_with("coincide", &subject, false, "coincide/").is_none());
    assert!(score("coincide", &subject).is_some());
    assert!(score_with("cmdk", &subject, false, "coincide/").is_some());
    // A branch that is only the prefix keeps it.
    assert!(
        score_with(
            "coincide",
            &full("x", "coincide/", "", 30.0),
            false,
            "coincide/"
        )
        .is_some()
    );
}

#[test]
fn a_title_holding_the_words_ranks_above_the_worktree_prefix_and_project_name() {
    let busy = full(
        "Diagnose Connect provisioning failures",
        "t3/diagnose-connect",
        "t3code",
        0.0,
    );
    let named = full("T3 Connect Tunnel Lifecycle Review", "", "t3code", 30.0);
    assert_eq!(
        titles_with("t3 connect", &[busy, named], "t3/").first(),
        Some(&"T3 Connect Tunnel Lifecycle Review")
    );
    let sidebar = full("Fix sidebar lag", "t3code/sidebar", "t3code", 0.0);
    let gemini = full("T3 Code vs Gemini Token Volume", "", "slophouse", 30.0);
    assert_eq!(
        titles_with("t3code", &[sidebar, gemini], "t3code/").first(),
        Some(&"T3 Code vs Gemini Token Volume")
    );
}

#[test]
fn groups_are_ordered_by_their_best_match_and_keep_their_order_on_ties() {
    let query = Query::new("settings");
    let groups = [
        vec!["Open settings", "New thread"],
        vec!["Settings sync rewrite", "Thread settings"],
        vec!["Settings app"],
    ];
    let ranked = rank(&[2, 2, 1], |group, item, typos| {
        score_terms(&query, &Field::new(groups[group][item]), &[], typos)
    });
    let names = ranked
        .iter()
        .map(|(group, items)| {
            (
                *group,
                items
                    .iter()
                    .map(|(item, _)| groups[*group][*item])
                    .collect::<Vec<_>>(),
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(
        names,
        [
            (0, vec!["Open settings"]),
            (1, vec!["Settings sync rewrite", "Thread settings"]),
            (2, vec!["Settings app"]),
        ]
    );
}

#[test]
fn a_thread_named_for_the_query_ranks_above_a_command_with_it_as_a_keyword() {
    fn groups(command: (&str, &[&str]), thread: &str, raw: &str) -> Vec<usize> {
        let query = Query::new(raw);
        let keywords = command.1.iter().map(|k| Field::new(k)).collect::<Vec<_>>();
        rank(&[1, 1], |group, _, typos| {
            if group == 0 {
                score_terms(&query, &Field::new(command.0), &keywords, typos)
            } else {
                score_thread(
                    &query,
                    &Field::new(thread),
                    &Field::default(),
                    &Field::default(),
                    NOW,
                    NOW,
                    typos,
                )
            }
        })
        .into_iter()
        .map(|(group, _)| group)
        .collect()
    }
    let named = "Trim MCP model lists";
    assert_eq!(
        groups(("Restart agent session", &["reload", "mcp"]), named, "mcp"),
        [1, 0]
    );
    // A command named for the query stays first.
    assert_eq!(groups(("Reload MCP servers", &[]), named, "mcp"), [0, 1]);
    // A thread titled exactly like a command never lifts its group above the command's.
    assert_eq!(groups(("Settings", &[]), "Settings", "settings"), [0, 1]);
}

#[test]
fn typos_are_tried_only_when_nothing_matches_at_a_word_start() {
    let mut calls = Vec::new();
    rank(&[1], |_, _, typos| {
        calls.push(typos);
        terms("sidebar", "Fix sidebar", &[], typos)
    });
    assert_eq!(calls, [false]);
    calls.clear();
    let ranked = rank(&[1], |_, _, typos| {
        calls.push(typos);
        terms("sidbear", "Fix sidebar", &[], typos)
    });
    assert_eq!(calls, [false, true]);
    assert!(!ranked[0].1[0].1.strong);
}

#[test]
fn keyword_only_matches_rank_below_name_matches_as_a_group() {
    let found = terms("preferences", "Open Settings", &["preferences"], false).unwrap();
    assert!(found.ranges.is_empty());
    assert!(found.group_quality.unwrap() <= 0.65);
}

#[test]
fn match_classes_separate_whole_names_word_starts_typos_and_inside_words() {
    assert_eq!(match_class(1.5), 3);
    assert_eq!(match_class(1.0), 2);
    assert_eq!(match_class(0.7), 2);
    assert_eq!(match_class(0.45), 1);
    assert_eq!(match_class(0.3), 0);
}

#[test]
fn a_whole_name_match_scores_highest() {
    assert_eq!(
        terms("open settings", "Open Settings", &[], false).map(|m| m.quality),
        Some(1.5)
    );
    assert_eq!(
        terms("open settings", "Open Settings Now", &[], false).map(|m| m.quality),
        Some(1.25)
    );
}

#[test]
fn short_queries_need_whole_keywords() {
    assert!(Query::new("co").is_short());
    assert!(Query::new("the ci").is_short());
    assert!(Query::new("a b").is_short());
    assert!(!Query::new("abcd").is_short());
    assert!(!Query::new("ab cd").is_short());
    assert!(terms("co", "Show Diff", &["commit"], false).is_none());
    assert!(terms("git", "Show Diff", &["git"], false).is_some());
}

#[test]
fn highlight_ranges_are_utf8_bytes_and_skip_accented_letters() {
    assert_eq!(
        score("resume", &thread("🎉 Résumé ready")).map(|m| m.ranges),
        Some(one(5, 13))
    );
}
