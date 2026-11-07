//! API list prices, ported from Swift's `UsagePricing`, for estimating what tokens
//! would cost at pay-as-you-go rates. Subscription usage is not billed per token,
//! so Settings › Usage calls the result an API-equivalent estimate. Prices are US
//! dollars per million tokens; newest models come first so a longer id matches
//! before its prefix.
use crate::usage_report::TokenTotals;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LongContext {
    pub input_multiplier: f64,
    pub output_multiplier: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ModelPrice {
    pub input: f64,
    pub output: f64,
    pub cache_read: f64,
    /// Five-minute cache writes; None prices them as `input`.
    pub cache_write: Option<f64>,
    /// One-hour cache writes (Claude); None prices them as `cache_write`.
    pub cache_write_long: Option<f64>,
    /// Above this many input tokens in one request, the whole request is priced at `long_context`.
    pub long_context_threshold: Option<u64>,
    pub long_context: Option<LongContext>,
}

impl ModelPrice {
    /// Anthropic's rates: cache reads as listed, writes at 1.25× input for five minutes and 2× for an hour.
    const fn claude(input: f64, output: f64, cache_read: f64) -> Self {
        Self {
            input,
            output,
            cache_read,
            cache_write: Some(input * 1.25),
            cache_write_long: Some(input * 2.),
            long_context_threshold: None,
            long_context: None,
        }
    }

    /// OpenAI's long-context models: a request above 272K input tokens costs 2× for input and the listed factor for output.
    const fn open_ai(
        input: f64,
        output: f64,
        cache_read: f64,
        cache_write: Option<f64>,
        long_output: Option<f64>,
    ) -> Self {
        let (long_context_threshold, long_context) = match long_output {
            Some(long) => (
                Some(272_000),
                Some(LongContext {
                    input_multiplier: 2.,
                    output_multiplier: long / output,
                }),
            ),
            None => (None, None),
        };
        Self {
            input,
            output,
            cache_read,
            cache_write,
            cache_write_long: None,
            long_context_threshold,
            long_context,
        }
    }

    /// What `tokens` cost, in dollars. `is_long` says the request went past the long-context threshold.
    pub fn cost(&self, tokens: &TokenTotals, is_long: bool) -> f64 {
        let long = if is_long { self.long_context } else { None };
        let input_factor = long.map_or(1., |long| long.input_multiplier);
        let output_factor = long.map_or(1., |long| long.output_multiplier);
        let write = self.cache_write.unwrap_or(self.input) * input_factor;
        let long_write = self
            .cache_write_long
            .or(self.cache_write)
            .unwrap_or(self.input)
            * input_factor;
        let short_writes = tokens.cache_write - tokens.cache_write_long;
        let dollars = tokens.input as f64 * self.input * input_factor
            + tokens.cache_read as f64 * self.cache_read * input_factor
            + short_writes as f64 * write
            + tokens.cache_write_long as f64 * long_write
            + tokens.output as f64 * self.output * output_factor;
        dollars / 1_000_000.
    }
}

const fn claude(
    prefix: &'static str,
    input: f64,
    output: f64,
    read: f64,
) -> (&'static str, ModelPrice) {
    (prefix, ModelPrice::claude(input, output, read))
}

/// Claude models by id prefix (Anthropic's price list).
const CLAUDE: [(&str, ModelPrice); 20] = [
    claude("claude-fable-5-1", 10., 50., 0.25),
    claude("claude-mythos-5-1", 10., 50., 0.25),
    claude("claude-fable-5", 10., 50., 1.),
    claude("claude-mythos-5", 10., 50., 1.),
    claude("claude-opus-5-5", 4., 20., 0.2),
    claude("claude-opus-5", 5., 25., 0.5),
    claude("claude-opus-4-8", 5., 25., 0.5),
    claude("claude-opus-4-7", 5., 25., 0.5),
    claude("claude-opus-4-6", 5., 25., 0.5),
    claude("claude-opus-4-5", 5., 25., 0.5),
    claude("claude-opus-4-1", 15., 75., 1.5),
    claude("claude-opus-4", 15., 75., 1.5),
    claude("claude-sonnet-5-5", 2., 10., 0.2),
    claude("claude-sonnet-5", 2., 10., 0.2),
    claude("claude-sonnet-4-6", 3., 15., 0.3),
    claude("claude-sonnet-4-5", 3., 15., 0.3),
    claude("claude-sonnet-4", 3., 15., 0.3),
    // Claude Haiku 5.5 costs 5× for prompts above 100K tokens.
    (
        "claude-haiku-5-5",
        ModelPrice {
            input: 0.1,
            output: 0.5,
            cache_read: 0.01,
            cache_write: Some(0.125),
            cache_write_long: Some(0.2),
            long_context_threshold: Some(100_000),
            long_context: Some(LongContext {
                input_multiplier: 5.,
                output_multiplier: 5.,
            }),
        },
    ),
    claude("claude-haiku-4-5", 1., 5., 0.1),
    claude("claude-3-5-haiku", 0.8, 4., 0.08),
];

const fn open_ai(
    id: &'static str,
    input: f64,
    output: f64,
    read: f64,
    write: Option<f64>,
    long_output: Option<f64>,
) -> (&'static str, ModelPrice) {
    (
        id,
        ModelPrice::open_ai(input, output, read, write, long_output),
    )
}

/// OpenAI models Codex runs, by exact id (Codex names models without dates).
const OPEN_AI: [(&str, ModelPrice); 22] = [
    open_ai("gpt-6-astra", 10., 50., 1., Some(12.5), Some(75.)),
    open_ai("gpt-6.1-sol", 2., 10., 0.1, Some(2.5), Some(15.)),
    open_ai("gpt-6-sol", 2., 10., 0.2, Some(2.5), Some(15.)),
    open_ai("gpt-6-luna", 0.1, 0.5, 0.01, Some(0.125), Some(0.75)),
    open_ai("gpt-5.6-sol", 4., 20., 0.4, Some(5.), Some(30.)),
    open_ai("gpt-5.6-terra", 2., 12., 0.2, Some(2.5), Some(18.)),
    open_ai("gpt-5.6-luna", 0.2, 1.2, 0.02, Some(0.25), Some(1.8)),
    open_ai("gpt-5.5", 5., 30., 0.5, None, Some(45.)),
    open_ai("gpt-5.4", 2.5, 15., 0.25, None, Some(22.5)),
    open_ai("gpt-5.4-mini", 0.75, 4.5, 0.075, None, None),
    open_ai("gpt-5.4-nano", 0.2, 1.25, 0.02, None, None),
    open_ai("gpt-5.3-codex", 1.75, 14., 0.175, None, None),
    open_ai("gpt-5.2", 1.75, 14., 0.175, None, None),
    open_ai("gpt-5.2-codex", 1.75, 14., 0.175, None, None),
    open_ai("gpt-5.1", 1.25, 10., 0.125, None, None),
    open_ai("gpt-5.1-codex", 1.25, 10., 0.125, None, None),
    open_ai("gpt-5.1-codex-max", 1.25, 10., 0.125, None, None),
    open_ai("gpt-5.1-codex-mini", 0.25, 2., 0.025, None, None),
    open_ai("gpt-5", 1.25, 10., 0.125, None, None),
    open_ai("gpt-5-codex", 1.25, 10., 0.125, None, None),
    open_ai("gpt-5-mini", 0.25, 2., 0.025, None, None),
    open_ai("gpt-5-nano", 0.05, 0.4, 0.005, None, None),
];

/// The price of a model, from its id as a provider logs it: `claude-opus-5-5`,
/// `claude-sonnet-4-5-20250929`, `gpt-6.1-sol`, or OpenCode's
/// `anthropic/claude-sonnet-4-5`. None for a model without a known price.
pub fn price(model: &str) -> Option<ModelPrice> {
    let mut id = model.trim().to_lowercase();
    // OpenCode and others prefix the service: `openai/gpt-5`, `anthropic/claude-…`.
    if let Some(slash) = id.rfind('/') {
        id = id[slash + 1..].to_owned();
    }
    // Bedrock-style `anthropic.claude-…` and `[1m]` context suffixes.
    if let Some(rest) = id.strip_prefix("anthropic.") {
        id = rest.to_owned();
    }
    if let Some(bracket) = id.find('[') {
        id.truncate(bracket);
    }
    if id.starts_with("claude-") {
        // `claude-sonnet-4.5`, as some tools write it.
        let id = id.replace('.', "-");
        return CLAUDE
            .iter()
            .find(|(prefix, _)| id == *prefix || id.starts_with(&format!("{prefix}-")))
            .map(|(_, price)| *price);
    }
    if let Some((_, price)) = OPEN_AI.iter().find(|(key, _)| *key == id) {
        return Some(*price);
    }
    // A dated or suffixed OpenAI id (`gpt-5.4-2026-03-05`) costs what its base model does.
    OPEN_AI
        .iter()
        .filter(|(key, _)| id.starts_with(&format!("{key}-")))
        .max_by_key(|(key, _)| key.len())
        .map(|(_, price)| *price)
}

/// What `tokens` would cost at `model`'s list price, or None for a model without one.
pub fn cost(tokens: &TokenTotals, model: Option<&str>, prompt_tokens: u64) -> Option<f64> {
    let price = price(model?)?;
    let long = price
        .long_context_threshold
        .is_some_and(|threshold| prompt_tokens > threshold);
    Some(price.cost(tokens, long))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tokens(input: u64, read: u64, write: u64, long: u64, output: u64) -> TokenTotals {
        TokenTotals::new(input, read, write, long, output, 0)
    }

    #[test]
    fn ids_match_by_prefix_service_and_suffix_like_swift() {
        assert_eq!(
            price("claude-sonnet-4-5-20250929"),
            price("claude-sonnet-4-5")
        );
        assert_eq!(
            price("anthropic/claude-sonnet-4.5"),
            price("claude-sonnet-4-5")
        );
        assert_eq!(
            price("anthropic.claude-opus-4-1[1m]"),
            price("claude-opus-4-1")
        );
        // `claude-opus-4-1` must not fall back to `claude-opus-4`.
        assert_eq!(price("claude-opus-4-1").unwrap().input, 15.);
        assert_eq!(price("claude-opus-4-5").unwrap().input, 5.);
        assert_eq!(price("gpt-5.4-2026-03-05"), price("gpt-5.4"));
        // The longest base wins: `gpt-5.1-codex-mini-…` is not `gpt-5.1-…`.
        assert_eq!(price("gpt-5.1-codex-mini-2026").unwrap().input, 0.25);
        assert_eq!(price("openai/GPT-5"), price("gpt-5"));
        assert!(price("claude-opusx").is_none());
        assert!(price("grok-4").is_none());
        assert!(price("").is_none());
    }

    #[test]
    fn claude_cache_writes_split_short_and_long_rates() {
        let price = price("claude-sonnet-4-5").unwrap();
        // 1M input $3, 1M read $0.30, 1M short write $3.75, 1M long write $6, 1M output $15.
        let cost = price.cost(
            &tokens(1_000_000, 1_000_000, 2_000_000, 1_000_000, 1_000_000),
            false,
        );
        assert!((cost - (3. + 0.3 + 3.75 + 6. + 15.)).abs() < 1e-9);
    }

    #[test]
    fn long_context_multiplies_only_past_the_threshold() {
        let value = tokens(1_000_000, 0, 0, 0, 1_000_000);
        assert!((cost(&value, Some("gpt-5.4"), 0).unwrap() - 17.5).abs() < 1e-9);
        assert!((cost(&value, Some("gpt-5.4"), 272_001).unwrap() - (5. + 22.5)).abs() < 1e-9);
        // OpenAI writes are priced as input unless a model lists a write price.
        let writes = tokens(0, 0, 1_000_000, 0, 0);
        assert!((cost(&writes, Some("gpt-5.4"), 0).unwrap() - 2.5).abs() < 1e-9);
        assert!((cost(&writes, Some("gpt-6-sol"), 0).unwrap() - 2.5).abs() < 1e-9);
        assert!(cost(&value, None, 0).is_none());
        assert!(cost(&value, Some("unknown-model"), 0).is_none());
    }
}
