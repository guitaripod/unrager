//! A fixed set of made-up posts, labelled against the default rules, that
//! `unrager eval` runs a model over. Wrongly hidden posts are the number that
//! matters most: a post hidden by mistake is one the user never learns about,
//! while a missed rage post is at least visible.

use crate::error::{Error, Result};
use crate::tui::filter::FilterDecision;
use serde::Deserialize;
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
    fn scoring_counts_each_kind_of_post_separately() {
        let case = |expect| Case {
            expect,
            about: "x".into(),
            text: "@a (A): x".into(),
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
