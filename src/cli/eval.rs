use crate::cli::checks;
use crate::error::{Error, Result};
use crate::tui::eval::{self, Case, Expect, Scorecard};
use crate::tui::filter::{Classifier, FilterConfig, FilterDecision, Judgement, Strictness};
use clap::Parser;
use std::time::{Duration, Instant};

/// Past this share of good posts hidden, the filter costs more than it saves.
const WRONGLY_HIDDEN_LIMIT: f64 = 0.05;
/// Below this share of rage caught, the filter isn't doing its job.
const CAUGHT_FLOOR: f64 = 0.75;

#[derive(Debug, Parser)]
pub struct Args {
    #[arg(
        long,
        help = "How strict to be: relaxed, balanced or strict (default: the one in filter.toml)"
    )]
    pub strictness: Option<Strictness>,
    #[arg(long, help = "Judge with this model instead of the one in filter.toml")]
    pub model: Option<String>,
    #[arg(long, help = "List every post the model got wrong")]
    pub mistakes: bool,
}

/// Runs the configured model over the bundled made-up posts with the default
/// rules, so models, strictness levels and prompt changes can be compared by
/// numbers: how many good posts it hid, how much rage it caught.
pub async fn run(args: Args) -> Result<()> {
    let mine = checks::load_filter_cfg()?;
    let mut cfg: FilterConfig = toml::from_str(FilterConfig::default_content())
        .map_err(|e| Error::Config(format!("default rules: {e}")))?;
    cfg.llm = mine.llm;
    cfg.strictness = args.strictness.unwrap_or(mine.strictness);
    if let Some(model) = args.model {
        cfg.llm.filter_model = Some(model);
    }
    let mut classifier = Classifier::new(&cfg);
    classifier.init().await?;
    let handle = classifier.handle();
    let cases = eval::cases();
    println!(
        "Judging {} made-up posts against the default rules with {} ({})…",
        cases.len(),
        handle.llm().model,
        cfg.strictness.as_str()
    );

    let warming = Instant::now();
    let first = handle.classify("eval", "@warm_up (Warm Up): hello").await;
    let first_answer = warming.elapsed();
    if first.is_none() {
        return Err(Error::Config(format!(
            "{} didn't answer; `unrager doctor` shows what's wrong",
            handle.llm().model
        )));
    }
    let started = Instant::now();
    let judged: Vec<Option<Judgement>> = futures::future::join_all(cases.iter().map(|case| {
        let handle = handle.clone();
        async move { handle.classify("eval", &case.text).await }
    }))
    .await;
    let elapsed = started.elapsed();

    let verdicts: Vec<Option<FilterDecision>> = judged
        .iter()
        .map(|j| j.as_ref().map(|j| j.decision))
        .collect();
    let card = eval::score(&cases, &verdicts);
    print_card(&card);
    print_speed(cases.len(), first_answer, elapsed);
    print_verdict(&card);
    if args.mistakes {
        print_mistakes(&cases, &judged);
    }
    Ok(())
}

fn percent(share: f64) -> String {
    format!("{:.0}%", share * 100.0)
}

fn print_card(card: &Scorecard) {
    println!();
    println!(
        "  wrongly hidden     {:>3} of {} good posts ({})",
        card.wrongly_hidden,
        card.fine,
        percent(card.wrongly_hidden_share())
    );
    println!(
        "  rage caught        {:>3} of {} ({})",
        card.caught,
        card.rage,
        percent(card.caught_share())
    );
    println!(
        "  borderline hidden  {:>3} of {}",
        card.borderline_hidden, card.borderline
    );
    if card.unanswered > 0 {
        println!(
            "  no answer          {:>3} (left visible, as the filter would)",
            card.unanswered
        );
    }
}

fn print_speed(posts: usize, first_answer: Duration, elapsed: Duration) {
    let per_second = posts as f64 / elapsed.as_secs_f64().max(0.001);
    println!();
    println!(
        "  first answer after {:.1} s, then {posts} posts in {:.1} s ({per_second:.0} a second)",
        first_answer.as_secs_f64(),
        elapsed.as_secs_f64()
    );
}

/// The one-line judgement, wrongly hidden posts first: they're the mistake a
/// user never sees.
fn print_verdict(card: &Scorecard) {
    println!();
    if card.wrongly_hidden_share() > WRONGLY_HIDDEN_LIMIT {
        println!(
            "! Hides too many good posts. Try --strictness relaxed, or another model with --model."
        );
    } else if card.caught_share() < CAUGHT_FLOOR {
        println!(
            "! Lets too much rage through. Try --strictness strict, or another model with --model."
        );
    } else {
        println!("✓ Good enough to filter with.");
    }
}

fn print_mistakes(cases: &[Case], judged: &[Option<Judgement>]) {
    let wrong = |expect: Expect, decision: FilterDecision| {
        cases
            .iter()
            .zip(judged)
            .filter(move |(case, j)| {
                case.expect == expect && j.as_ref().is_some_and(|j| j.decision == decision)
            })
            .collect::<Vec<_>>()
    };
    let hidden = wrong(Expect::Keep, FilterDecision::Hide);
    if !hidden.is_empty() {
        println!();
        println!("Good posts it hid:");
        for (case, judged) in hidden {
            let rule = judged
                .as_ref()
                .and_then(|j| j.reason.as_deref())
                .unwrap_or("no rule named");
            println!("  [{}] {}", case.about, case.text);
            println!("      hidden for: {rule}");
        }
    }
    let missed = wrong(Expect::Hide, FilterDecision::Keep);
    if !missed.is_empty() {
        println!();
        println!("Rage it let through:");
        for (case, _) in missed {
            println!("  [{}] {}", case.about, case.text);
        }
    }
}
