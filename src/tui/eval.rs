//! A fixed set of made-up posts, labelled against the default rules, that
//! `unrager eval` runs a model over. Wrongly hidden posts are the number that
//! matters most: a post hidden by mistake is one the user never learns about,
//! while a missed rage post is at least visible.

use crate::error::{Error, Result};
use crate::tui::filter::FilterDecision;
use serde::{Deserialize, Deserializer};
use sha2::{Digest, Sha256};
use std::path::Path;

const EVAL_SET: &str = include_str!("filter_eval.jsonl");

/// What the default rules say should happen to a post.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Expect {
    Hide,
    Keep,
    /// Reasonable people, and strictness levels, disagree.
    Either,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Case {
    pub expect: Expect,
    /// What the post is, for whoever reads the mistakes.
    #[serde(default)]
    pub about: String,
    /// The post as the classifier sees it: `@handle (Name): text`.
    pub text: String,
    /// For a HIDE post, the numbers of the rules it breaks (one number or a
    /// list), to check the rule a hide names.
    #[serde(default, deserialize_with = "one_or_many")]
    pub rule: Vec<usize>,
    /// Where the post came from (`for_you`, `following`), to break results
    /// down by it.
    #[serde(default)]
    pub source: Option<String>,
    /// The post's language code as X reports it.
    #[serde(default)]
    pub lang: Option<String>,
}

impl Case {
    /// A stable name for the post in saved runs, without storing its text.
    pub fn key(&self) -> String {
        let digest = Sha256::digest(self.text.as_bytes());
        digest[..8].iter().map(|b| format!("{b:02x}")).collect()
    }
}

fn one_or_many<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<Vec<usize>, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Rules {
        One(usize),
        Many(Vec<usize>),
    }
    Ok(match Option::<Rules>::deserialize(d)? {
        None => Vec::new(),
        Some(Rules::One(n)) => vec![n],
        Some(Rules::Many(v)) => v,
    })
}

/// A fingerprint of a whole set, so runs on different sets aren't compared.
pub fn set_hash(cases: &[Case]) -> String {
    let mut hasher = Sha256::new();
    for case in cases {
        hasher.update(case.text.as_bytes());
        hasher.update([0]);
    }
    hasher.finalize()[..8]
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The bundled set. Every line is checked by the tests below.
pub fn cases() -> Vec<Case> {
    parse(EVAL_SET).expect("the bundled eval set parses")
}

/// A set of the user's own labelled posts, in the bundled set's format.
pub fn load(path: &Path) -> Result<Vec<Case>> {
    let raw = std::fs::read_to_string(path)
        .map_err(|e| Error::Config(format!("{}: {e}", path.display())))?;
    let cases = parse(&raw).map_err(|e| Error::Config(format!("{}: {e}", path.display())))?;
    if cases.is_empty() {
        return Err(Error::Config(format!("{} has no posts", path.display())));
    }
    Ok(cases)
}

fn parse(jsonl: &str) -> serde_json::Result<Vec<Case>> {
    jsonl
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(serde_json::from_str)
        .collect()
}

/// How a model did on the set. A `None` verdict is a post the model never
/// answered for.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Scorecard {
    pub fine: usize,
    pub wrongly_hidden: usize,
    pub rage: usize,
    pub caught: usize,
    pub borderline: usize,
    pub borderline_hidden: usize,
    pub unanswered: usize,
}

impl Scorecard {
    pub fn wrongly_hidden_share(&self) -> f64 {
        share(self.wrongly_hidden, self.fine)
    }

    pub fn caught_share(&self) -> f64 {
        share(self.caught, self.rage)
    }
}

fn share(part: usize, whole: usize) -> f64 {
    if whole == 0 {
        0.0
    } else {
        part as f64 / whole as f64
    }
}

/// The 95% Wilson interval of `k` out of `n`, as shares.
pub fn wilson(k: usize, n: usize) -> (f64, f64) {
    if n == 0 {
        return (0.0, 1.0);
    }
    let z = 1.96_f64;
    let (k, n) = (k as f64, n as f64);
    let p = k / n;
    let d = 1.0 + z * z / n;
    let centre = (p + z * z / (2.0 * n)) / d;
    let half = z * (p * (1.0 - p) / n + z * z / (4.0 * n * n)).sqrt() / d;
    ((centre - half).max(0.0), (centre + half).min(1.0))
}

/// The exact two-sided McNemar p-value for two runs over the same posts:
/// how likely a split this lopsided is when the runs are equally good.
/// `only_a` and `only_b` are the posts only one of them hid.
pub fn mcnemar(only_a: usize, only_b: usize) -> f64 {
    let n = only_a + only_b;
    if n == 0 {
        return 1.0;
    }
    let ln_choose =
        |n: usize, k: usize| -> f64 { (1..=k).map(|i| ((n - k + i) as f64 / i as f64).ln()).sum() };
    let tail: f64 = (0..=only_a.min(only_b))
        .map(|i| (ln_choose(n, i) - n as f64 * std::f64::consts::LN_2).exp())
        .sum();
    (2.0 * tail).min(1.0)
}

/// The chance a random rage post scores above a random good one (ties count
/// half): 1.0 separates them perfectly, 0.5 is a coin toss.
pub fn auc(good: &[f64], rage: &[f64]) -> f64 {
    if good.is_empty() || rage.is_empty() {
        return 0.5;
    }
    let wins: f64 = rage
        .iter()
        .map(|r| {
            good.iter()
                .map(|g| match r.partial_cmp(g) {
                    Some(std::cmp::Ordering::Greater) => 1.0,
                    Some(std::cmp::Ordering::Equal) => 0.5,
                    _ => 0.0,
                })
                .sum::<f64>()
        })
        .sum();
    wins / (good.len() * rage.len()) as f64
}

/// The share of rage a model would catch if it hid only the posts it was
/// surest about, stopping before `budget` of the good posts were hidden.
pub fn caught_at(good: &[f64], rage: &[f64], budget: f64) -> f64 {
    if rage.is_empty() {
        return 0.0;
    }
    let mut sorted = good.to_vec();
    sorted.sort_by(|a, b| b.total_cmp(a));
    let allowed = (budget * sorted.len() as f64).floor() as usize;
    let cut = sorted.get(allowed).copied().unwrap_or(f64::NEG_INFINITY);
    rage.iter().filter(|&&r| r > cut).count() as f64 / rage.len() as f64
}

pub fn score(cases: &[Case], verdicts: &[Option<FilterDecision>]) -> Scorecard {
    let mut card = Scorecard::default();
    for (case, verdict) in cases.iter().zip(verdicts) {
        let Some(verdict) = verdict else {
            card.unanswered += 1;
            continue;
        };
        let hidden = *verdict == FilterDecision::Hide;
        match case.expect {
            Expect::Keep => {
                card.fine += 1;
                card.wrongly_hidden += usize::from(hidden);
            }
            Expect::Hide => {
                card.rage += 1;
                card.caught += usize::from(hidden);
            }
            Expect::Either => {
                card.borderline += 1;
                card.borderline_hidden += usize::from(hidden);
            }
        }
    }
    card
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn the_bundled_set_is_balanced_and_well_formed() {
        let cases = cases();
        let count = |expect| cases.iter().filter(|c| c.expect == expect).count();
        assert!(count(Expect::Hide) >= 50, "{}", count(Expect::Hide));
        assert!(count(Expect::Keep) >= 90, "{}", count(Expect::Keep));
        assert!(count(Expect::Either) >= 20, "{}", count(Expect::Either));
        let mut texts = HashSet::new();
        for case in &cases {
            assert!(texts.insert(&case.text), "duplicate: {}", case.text);
            assert!(
                case.text.starts_with('@') && case.text.contains("): "),
                "{}",
                case.text
            );
            assert!(!case.about.is_empty(), "{}", case.text);
        }
    }

    #[test]
    fn a_users_own_posts_load_without_the_about_field() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("mine.jsonl");
        std::fs::write(
            &path,
            "{\"expect\": \"hide\", \"text\": \"@a (A): x\", \"id\": \"1\"}\n\n{\"expect\": \"either\", \"text\": \"@b (B): y\"}\n",
        )
        .unwrap();
        let cases = load(&path).unwrap();
        assert_eq!(cases.len(), 2);
        assert_eq!(cases[0].expect, Expect::Hide);
        assert!(cases[1].about.is_empty());
        std::fs::write(&path, "\n").unwrap();
        assert!(load(&path).is_err());
        std::fs::write(&path, "{\"expect\": \"maybe\", \"text\": \"@a (A): x\"}").unwrap();
        assert!(load(&path).is_err());
    }

    #[test]
    fn a_post_can_name_one_rule_or_several() {
        let cases = parse(
            "{\"expect\": \"hide\", \"text\": \"@a (A): x\", \"rule\": 3, \"source\": \"for_you\"}\n{\"expect\": \"hide\", \"text\": \"@b (B): y\", \"rule\": [1, 14]}\n{\"expect\": \"keep\", \"text\": \"@c (C): z\", \"rule\": null}",
        )
        .unwrap();
        assert_eq!(cases[0].rule, vec![3]);
        assert_eq!(cases[0].source.as_deref(), Some("for_you"));
        assert_eq!(cases[1].rule, vec![1, 14]);
        assert!(cases[2].rule.is_empty());
        assert_ne!(cases[0].key(), cases[1].key());
        assert_eq!(cases[0].key(), cases[0].clone().key());
    }

    #[test]
    fn intervals_and_paired_tests_match_known_values() {
        let (lo, hi) = wilson(42, 845);
        assert!(
            (lo - 0.0369).abs() < 0.001 && (hi - 0.0666).abs() < 0.001,
            "{lo} {hi}"
        );
        assert_eq!(wilson(0, 0), (0.0, 1.0));
        assert!(
            (mcnemar(5, 29) - 0.0000386).abs() < 0.000001,
            "{}",
            mcnemar(5, 29)
        );
        assert!(
            (mcnemar(22, 28) - 0.4799).abs() < 0.001,
            "{}",
            mcnemar(22, 28)
        );
        assert_eq!(mcnemar(0, 0), 1.0);
        assert_eq!(mcnemar(3, 3), 1.0);
    }

    #[test]
    fn ranking_numbers_reward_rage_scored_above_good_posts() {
        let good = [0.0, 0.1, 0.2, 0.9];
        let rage = [0.95, 0.8, 0.1];
        assert!((auc(&good, &rage) - (4.0 + 3.0 + 1.5) / 12.0).abs() < 1e-9);
        assert_eq!(auc(&[0.0], &[1.0]), 1.0);
        assert_eq!(caught_at(&good, &rage, 0.0), 1.0 / 3.0);
        assert_eq!(caught_at(&good, &rage, 0.25), 2.0 / 3.0);
        assert_eq!(caught_at(&good, &rage, 1.0), 1.0);
    }

    #[test]
    fn scoring_counts_each_kind_of_post_separately() {
        let case = |expect| Case {
            expect,
            about: "x".into(),
            text: "@a (A): x".into(),
            rule: Vec::new(),
            source: None,
            lang: None,
        };
        let cases = [
            case(Expect::Keep),
            case(Expect::Keep),
            case(Expect::Hide),
            case(Expect::Hide),
            case(Expect::Either),
            case(Expect::Keep),
        ];
        let verdicts = [
            Some(FilterDecision::Hide),
            Some(FilterDecision::Keep),
            Some(FilterDecision::Hide),
            Some(FilterDecision::Keep),
            Some(FilterDecision::Hide),
            None,
        ];
        let card = score(&cases, &verdicts);
        assert_eq!(
            card,
            Scorecard {
                fine: 2,
                wrongly_hidden: 1,
                rage: 2,
                caught: 1,
                borderline: 1,
                borderline_hidden: 1,
                unanswered: 1,
            }
        );
        assert_eq!(card.wrongly_hidden_share(), 0.5);
        assert_eq!(Scorecard::default().caught_share(), 0.0);
    }
}
