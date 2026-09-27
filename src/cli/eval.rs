use crate::cli::checks;
use crate::error::{Error, Result};
use crate::tui::eval::{self, Case, Expect, Scorecard};
use crate::tui::filter::{
    Classifier, ClassifierHandle, FilterConfig, FilterDecision, Scored, Strictness,
    answer_is_readable,
};
use clap::Parser;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// Past this share of good posts hidden, the filter costs more than it saves.
const WRONGLY_HIDDEN_LIMIT: f64 = 0.05;
/// Below this share of rage caught, the filter isn't doing its job.
const CAUGHT_FLOOR: f64 = 0.75;
/// The shares of good posts hidden at which models are compared by how much
/// rage they would catch.
const BUDGETS: [f64; 2] = [0.02, 0.05];
/// A slice with fewer posts than this says nothing and isn't printed.
const SLICE_MIN: usize = 20;

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
    #[arg(
        long,
        value_name = "FILE",
        help = "Judge your own labelled posts against your rules instead: JSON Lines like the bundled set, one {\"expect\": \"hide\"|\"keep\"|\"either\", \"text\": \"@handle (Name): …\"} per line, optionally with \"rule\" (the number or numbers a hide breaks), \"source\" and \"lang\""
    )]
    pub posts: Option<PathBuf>,
    #[arg(
        long,
        value_name = "N",
        default_value_t = 1,
        help = "Judge every post N times, count the verdicts that change and score the majority"
    )]
    pub repeat: usize,
    #[arg(
        long,
        value_name = "FILE",
        help = "Save this run's verdicts, to compare a later run against"
    )]
    pub save: Option<PathBuf>,
    #[arg(
        long,
        value_name = "FILE",
        help = "Compare post by post with a run saved by --save on the same posts"
    )]
    pub against: Option<PathBuf>,
}

/// What a saved run records about itself.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct RunInfo {
    model: String,
    strictness: String,
    rubric: String,
    set: String,
    posts: usize,
    repeat: usize,
    version: String,
    date: String,
}

/// One post's verdict in a saved run.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct SavedVerdict {
    key: String,
    expect: String,
    hidden: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    rule: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    hide_probability: Option<f64>,
    answer: String,
}

#[derive(Debug, Deserialize)]
struct SavedHeader {
    run: RunInfo,
}

/// A post's verdict over all repeats: the majority decision (a tie keeps the
/// post), whether the repeats disagreed, and the first run that agrees with
/// the majority for the rule and answer.
struct Outcome {
    decision: Option<FilterDecision>,
    flipped: bool,
    rule: Option<usize>,
    reason: Option<String>,
    answer: String,
    hide_probability: Option<f64>,
    elapsed: Vec<Duration>,
}

impl Outcome {
    fn from_runs(runs: Vec<Option<Scored>>) -> Self {
        let answered: Vec<Scored> = runs.into_iter().flatten().collect();
        let hides = answered
            .iter()
            .filter(|s| s.judgement.decision == FilterDecision::Hide)
            .count();
        let decision = (!answered.is_empty()).then(|| {
            if hides * 2 > answered.len() {
                FilterDecision::Hide
            } else {
                FilterDecision::Keep
            }
        });
        let probabilities: Vec<f64> = answered.iter().filter_map(|s| s.hide_probability).collect();
        let hide_probability = (!probabilities.is_empty())
            .then(|| probabilities.iter().sum::<f64>() / probabilities.len() as f64);
        let elapsed = answered.iter().map(|s| s.elapsed).collect();
        let flipped = hides != 0 && hides != answered.len();
        let pick = answered
            .into_iter()
            .find(|s| Some(s.judgement.decision) == decision);
        Self {
            decision,
            flipped,
            rule: pick.as_ref().and_then(|s| s.rule),
            reason: pick
                .as_ref()
                .and_then(|s| s.judgement.reason.as_deref().map(str::to_string)),
            answer: pick.map(|s| s.answer).unwrap_or_default(),
            hide_probability,
            elapsed,
        }
    }

    fn hidden(&self) -> bool {
        self.decision == Some(FilterDecision::Hide)
    }
}

/// Runs the configured model over the bundled made-up posts with the default
/// rules, or over the user's own labelled posts with their rules, so models,
/// strictness levels and prompt changes can be compared by numbers: how many
/// good posts it hid, how much rage it caught, with how much certainty, and
/// post by post against an earlier run.
pub async fn run(args: Args) -> Result<()> {
    let mine = checks::load_filter_cfg()?;
    let (mut cfg, cases, what) = match &args.posts {
        Some(path) => {
            let cases = eval::load(path)?;
            let what = format!("posts from {} against your rules", path.display());
            (mine.clone(), cases, what)
        }
        None => {
            let mut cfg: FilterConfig = toml::from_str(FilterConfig::default_content())
                .map_err(|e| Error::Config(format!("default rules: {e}")))?;
            cfg.llm = mine.llm.clone();
            let what = "made-up posts against the default rules".to_string();
            (cfg, eval::cases(), what)
        }
    };
    cfg.strictness = args.strictness.unwrap_or(mine.strictness);
    if let Some(model) = &args.model {
        cfg.llm.filter_model = Some(model.clone());
    }
    let against = args.against.as_deref().map(load_saved).transpose()?;
    let repeat = args.repeat.max(1);
    let mut classifier = Classifier::new(&cfg);
    classifier.init().await?;
    let handle = classifier.handle();
    let times = if repeat > 1 {
        format!(", {repeat} times each")
    } else {
        String::new()
    };
    println!(
        "Judging {} {what} with {} ({}){times}…",
        cases.len(),
        handle.llm().model,
        cfg.strictness.as_str()
    );

    let warming = Instant::now();
    if handle
        .classify_scored("@warm_up (Warm Up): hello")
        .await
        .is_none()
    {
        return Err(Error::Config(format!(
            "{} didn't answer; `unrager doctor` shows what's wrong",
            handle.llm().model
        )));
    }
    let first_answer = warming.elapsed();
    let started = Instant::now();
    let mut runs: Vec<Vec<Option<Scored>>> = vec![Vec::with_capacity(repeat); cases.len()];
    for _ in 0..repeat {
        for (post, verdict) in runs.iter_mut().zip(judge_all(&handle, &cases).await) {
            post.push(verdict);
        }
    }
    let elapsed = started.elapsed();
    let outcomes: Vec<Outcome> = runs.into_iter().map(Outcome::from_runs).collect();

    let verdicts: Vec<Option<FilterDecision>> = outcomes.iter().map(|o| o.decision).collect();
    let card = eval::score(&cases, &verdicts);
    print_card(&card, &outcomes, repeat);
    print_ranking(&cases, &outcomes);
    print_rules(&cases, &outcomes);
    print_slices(&cases, &outcomes);
    print_speed(cases.len() * repeat, first_answer, elapsed, &outcomes);
    print_verdict(&card);
    if let Some((info, saved)) = &against {
        print_against(&cases, &outcomes, info, saved);
    }
    if let Some(path) = &args.save {
        let info = RunInfo {
            model: handle.llm().model.clone(),
            strictness: cfg.strictness.as_str().to_string(),
            rubric: cfg.rubric_hash(),
            set: eval::set_hash(&cases),
            posts: cases.len(),
            repeat,
            version: env!("CARGO_PKG_VERSION").to_string(),
            date: chrono::Utc::now().format("%Y-%m-%d %H:%M").to_string(),
        };
        save(path, &info, &cases, &outcomes)?;
        println!();
        println!("Saved to {}", path.display());
    }
    if args.mistakes {
        print_mistakes(&cases, &outcomes);
    }
    Ok(())
}

async fn judge_all(handle: &ClassifierHandle, cases: &[Case]) -> Vec<Option<Scored>> {
    futures::future::join_all(cases.iter().map(|case| {
        let handle = handle.clone();
        async move { handle.classify_scored(&case.text).await }
    }))
    .await
}

fn percent(share: f64) -> String {
    format!("{:.0}%", share * 100.0)
}

/// A share with its 95% interval: "4.3%, 3.1–5.9%". Small shares keep a
/// decimal so the interval stays readable.
fn share_with_interval(k: usize, n: usize) -> String {
    let (lo, hi) = eval::wilson(k, n);
    let share = if n == 0 { 0.0 } else { k as f64 / n as f64 };
    let digits = if hi < 0.1 { 1 } else { 0 };
    format!(
        "{:.digits$}%, {:.digits$}–{:.digits$}%",
        share * 100.0,
        lo * 100.0,
        hi * 100.0
    )
}

fn print_card(card: &Scorecard, outcomes: &[Outcome], repeat: usize) {
    println!();
    println!(
        "  wrongly hidden     {:>3} of {} good posts ({})",
        card.wrongly_hidden,
        card.fine,
        share_with_interval(card.wrongly_hidden, card.fine)
    );
    println!(
        "  rage caught        {:>3} of {} ({})",
        card.caught,
        card.rage,
        share_with_interval(card.caught, card.rage)
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
    let unreadable = outcomes
        .iter()
        .filter(|o| o.decision.is_some() && !answer_is_readable(&o.answer))
        .count();
    if unreadable > 0 {
        println!(
            "  unreadable         {unreadable:>3} (answered neither HIDE nor KEEP, counted as kept)"
        );
    }
    if repeat > 1 {
        let flipped = outcomes.iter().filter(|o| o.flipped).count();
        println!(
            "  changed verdict    {flipped:>3} between the {repeat} runs (scored by majority)"
        );
    }
}

/// How well the model ranks rage above good posts, whatever its answer:
/// the rage it would catch if it hid only what it was surest about, at a
/// fixed share of good posts hidden. Needs a server that reports logprobs.
fn print_ranking(cases: &[Case], outcomes: &[Outcome]) {
    let scores = |expect: Expect| -> Option<Vec<f64>> {
        cases
            .iter()
            .zip(outcomes)
            .filter(|(c, o)| c.expect == expect && o.decision.is_some())
            .map(|(_, o)| o.hide_probability)
            .collect()
    };
    let (Some(good), Some(rage)) = (scores(Expect::Keep), scores(Expect::Hide)) else {
        return;
    };
    if good.is_empty() || rage.is_empty() {
        return;
    }
    let at = BUDGETS
        .iter()
        .map(|&b| {
            format!(
                "{} at {}",
                percent(eval::caught_at(&good, &rage, b)),
                percent(b)
            )
        })
        .collect::<Vec<_>>()
        .join(", ");
    println!();
    println!(
        "  ranked by how sure it was: rage caught {at} of good posts hidden (AUC {:.3})",
        eval::auc(&good, &rage)
    );
}

/// Whether hides name a rule the labels agree with, and which rules the
/// wrong hides blame: that points at the rule text to rewrite.
fn print_rules(cases: &[Case], outcomes: &[Outcome]) {
    let labelled: Vec<(&Case, &Outcome)> = cases
        .iter()
        .zip(outcomes)
        .filter(|(c, o)| c.expect == Expect::Hide && !c.rule.is_empty() && o.hidden())
        .collect();
    let mut wrong: BTreeMap<String, usize> = BTreeMap::new();
    for (_, o) in cases
        .iter()
        .zip(outcomes)
        .filter(|(c, o)| c.expect == Expect::Keep && o.hidden())
    {
        let reason = o.reason.clone().unwrap_or_else(|| "no rule named".into());
        *wrong.entry(reason).or_default() += 1;
    }
    if labelled.is_empty() && wrong.is_empty() {
        return;
    }
    println!();
    if !labelled.is_empty() {
        let right = labelled
            .iter()
            .filter(|(c, o)| o.rule.is_some_and(|r| c.rule.contains(&r)))
            .count();
        println!(
            "  names the right rule for {right} of the {} rage posts it caught",
            labelled.len()
        );
    }
    if !wrong.is_empty() {
        let mut by_count: Vec<(String, usize)> = wrong.into_iter().collect();
        by_count.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        println!("  good posts hidden for:");
        for (reason, n) in by_count.iter().take(5) {
            println!("    {n:>3}  {}", short(reason, 70));
        }
    }
}

fn short(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        text.to_string()
    } else {
        format!("{}…", text.chars().take(max - 1).collect::<String>())
    }
}

/// The card again for each source and for non-English posts, when the set
/// says where posts came from.
fn print_slices(cases: &[Case], outcomes: &[Outcome]) {
    let mut slices: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    for (i, case) in cases.iter().enumerate() {
        if let Some(source) = &case.source {
            slices.entry(source.replace('_', " ")).or_default().push(i);
        }
        if case
            .lang
            .as_deref()
            .is_some_and(|l| l.len() == 2 && l != "en")
        {
            slices.entry("not English".into()).or_default().push(i);
        }
    }
    let rows: Vec<String> = slices
        .into_iter()
        .filter(|(_, idx)| idx.len() >= SLICE_MIN)
        .map(|(name, idx)| {
            let count = |expect: Expect, hidden: bool| {
                idx.iter()
                    .filter(|&&i| cases[i].expect == expect && (!hidden || outcomes[i].hidden()))
                    .count()
            };
            format!(
                "  {name:<18} wrongly hidden {} of {}, rage caught {} of {}",
                count(Expect::Keep, true),
                count(Expect::Keep, false),
                count(Expect::Hide, true),
                count(Expect::Hide, false)
            )
        })
        .collect();
    if !rows.is_empty() {
        println!();
        for row in rows {
            println!("{row}");
        }
    }
}

fn print_speed(requests: usize, first_answer: Duration, elapsed: Duration, outcomes: &[Outcome]) {
    let per_second = requests as f64 / elapsed.as_secs_f64().max(0.001);
    let mut ms: Vec<f64> = outcomes
        .iter()
        .flat_map(|o| o.elapsed.iter().map(|d| d.as_secs_f64() * 1000.0))
        .collect();
    ms.sort_by(f64::total_cmp);
    let at = |q: f64| {
        ms.get(((ms.len() as f64 - 1.0) * q).round() as usize)
            .copied()
            .unwrap_or(0.0)
    };
    println!();
    println!(
        "  first answer after {:.1} s, then {requests} answers in {:.1} s ({per_second:.0} a second)",
        first_answer.as_secs_f64(),
        elapsed.as_secs_f64()
    );
    println!(
        "  each took {:.0} ms, {:.0} ms for the slowest 1 in 20",
        at(0.5),
        at(0.95)
    );
}

/// The one-line judgement, wrongly hidden posts first: they're the mistake a
/// user never sees. It only passes or fails a model when the 95% intervals
/// clear the limits; otherwise the set is too small to tell.
fn print_verdict(card: &Scorecard) {
    let (hidden_lo, hidden_hi) = eval::wilson(card.wrongly_hidden, card.fine);
    let (caught_lo, caught_hi) = eval::wilson(card.caught, card.rage);
    println!();
    if hidden_lo > WRONGLY_HIDDEN_LIMIT {
        println!(
            "! Hides too many good posts. Try --strictness relaxed, or another model with --model."
        );
    } else if caught_hi < CAUGHT_FLOOR {
        println!(
            "! Lets too much rage through. Try --strictness strict, or another model with --model."
        );
    } else if hidden_hi <= WRONGLY_HIDDEN_LIMIT && caught_lo >= CAUGHT_FLOOR {
        println!("✓ Good enough to filter with.");
    } else {
        println!(
            "~ Close to the line ({} good posts hidden, {} rage caught): more labelled posts would settle it.",
            percent(WRONGLY_HIDDEN_LIMIT),
            percent(CAUGHT_FLOOR)
        );
    }
}

/// Post by post against a saved run: the posts only one of the two hid,
/// and how likely a split that lopsided is by chance (exact McNemar).
fn print_against(
    cases: &[Case],
    outcomes: &[Outcome],
    info: &RunInfo,
    saved: &HashMap<String, SavedVerdict>,
) {
    println!();
    println!(
        "Against {} ({}, {}):",
        info.model, info.strictness, info.date
    );
    if info.set != eval::set_hash(cases) {
        println!("  (that run judged a different set of posts; only the posts both judged count)");
    }
    for (expect, label) in [
        (Expect::Keep, "good posts hidden"),
        (Expect::Hide, "rage caught"),
    ] {
        let pairs: Vec<(bool, bool)> = cases
            .iter()
            .zip(outcomes)
            .filter(|(c, o)| c.expect == expect && o.decision.is_some())
            .filter_map(|(c, o)| {
                let other = saved.get(&c.key())?.hidden?;
                Some((o.hidden(), other))
            })
            .collect();
        let here = pairs.iter().filter(|p| p.0).count();
        let there = pairs.iter().filter(|p| p.1).count();
        let only_here = pairs.iter().filter(|p| p.0 && !p.1).count();
        let only_there = pairs.iter().filter(|p| !p.0 && p.1).count();
        let p = eval::mcnemar(only_here, only_there);
        let odds = if p < 0.001 {
            "p<0.001".to_string()
        } else if p < 0.05 {
            format!("p={p:.3}")
        } else {
            format!("p={p:.2}, could be chance")
        };
        println!(
            "  {label:<18} {here:>3} vs {there:>3}: {only_here} only here, {only_there} only there ({odds})"
        );
    }
}

fn save(path: &Path, info: &RunInfo, cases: &[Case], outcomes: &[Outcome]) -> Result<()> {
    let mut lines = vec![serde_json::json!({ "run": info }).to_string()];
    for (case, o) in cases.iter().zip(outcomes) {
        let verdict = SavedVerdict {
            key: case.key(),
            expect: format!("{:?}", case.expect).to_lowercase(),
            hidden: o.decision.map(|d| d == FilterDecision::Hide),
            rule: o.rule,
            hide_probability: o.hide_probability,
            answer: o.answer.clone(),
        };
        lines.push(serde_json::to_string(&verdict).map_err(|e| Error::Config(e.to_string()))?);
    }
    std::fs::write(path, lines.join("\n") + "\n")
        .map_err(|e| Error::Config(format!("{}: {e}", path.display())))
}

fn load_saved(path: &Path) -> Result<(RunInfo, HashMap<String, SavedVerdict>)> {
    let err = |e: String| Error::Config(format!("{}: {e}", path.display()));
    let raw = std::fs::read_to_string(path).map_err(|e| err(e.to_string()))?;
    let mut lines = raw.lines().filter(|l| !l.trim().is_empty());
    let header: SavedHeader = serde_json::from_str(lines.next().unwrap_or_default())
        .map_err(|e| err(format!("not a run saved by --save ({e})")))?;
    let verdicts = lines
        .map(|l| serde_json::from_str::<SavedVerdict>(l).map(|v| (v.key.clone(), v)))
        .collect::<std::result::Result<HashMap<_, _>, _>>()
        .map_err(|e| err(e.to_string()))?;
    Ok((header.run, verdicts))
}

fn print_mistakes(cases: &[Case], outcomes: &[Outcome]) {
    let wrong = |expect: Expect, hidden: bool| {
        cases
            .iter()
            .zip(outcomes)
            .filter(move |(case, o)| {
                case.expect == expect && o.decision.is_some() && o.hidden() == hidden
            })
            .collect::<Vec<_>>()
    };
    let hidden = wrong(Expect::Keep, true);
    if !hidden.is_empty() {
        println!();
        println!("Good posts it hid:");
        for (case, o) in hidden {
            println!("  [{}] {}", case.about, case.text);
            println!(
                "      hidden for: {}",
                o.reason.as_deref().unwrap_or("no rule named")
            );
        }
    }
    let missed = wrong(Expect::Hide, false);
    if !missed.is_empty() {
        println!();
        println!("Rage it let through:");
        for (case, _) in missed {
            println!("  [{}] {}", case.about, case.text);
        }
    }
}
