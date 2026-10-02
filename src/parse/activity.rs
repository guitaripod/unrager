//! Post analytics from X's `TweetActivityQuery`: the numbers X's own "Post
//! engagements" view shows on your posts.

use chrono::{DateTime, TimeZone, Utc};
use serde_json::Value;
use std::collections::HashMap;
use unrager_model::PostAnalytics;

const TWITTER_EPOCH_MS: i64 = 1_288_834_974_657;

/// When a post went out, read from its id: X's ids carry their creation time
/// in the bits above the 22nd.
pub fn posted_at(rest_id: &str) -> Option<DateTime<Utc>> {
    let id: u64 = rest_id.parse().ok()?;
    Utc.timestamp_millis_opt((id >> 22) as i64 + TWITTER_EPOCH_MS)
        .single()
}

/// The totals (and the first 48 hours of impressions) in a `TweetActivityQuery`
/// response, or `None` when X sent no metrics: the post isn't the signed-in
/// account's, or too new to have any.
pub fn parse_post_analytics(response: &Value) -> Option<PostAnalytics> {
    let result = response.pointer("/data/tweet_result_by_rest_id/result")?;
    let tweet = result.get("tweet").unwrap_or(result);
    let totals = metric_map(tweet.get("datapoints_grid"));
    if totals.is_empty() {
        return None;
    }
    let video = metric_map(tweet.get("video"));
    let get = |name: &str| totals.get(name).copied().unwrap_or(0);
    Some(PostAnalytics {
        impressions: get("Impressions"),
        engagements: get("Engagements"),
        detail_expands: get("DetailExpands"),
        profile_visits: get("ProfileVisits"),
        link_clicks: get("LinkClicks"),
        follows: get("Follows"),
        video_views: video.get("VideoViews").copied(),
        hourly_impressions: hourly_impressions(tweet.get("organic_metrics_time_series")),
    })
}

/// A short description of a `TweetActivityQuery` response that held no
/// metrics, for the log: the result's type, its keys and any errors X sent.
pub fn describe(response: &Value) -> String {
    let result = response.pointer("/data/tweet_result_by_rest_id/result");
    let keys = result
        .and_then(Value::as_object)
        .map(|o| o.keys().cloned().collect::<Vec<_>>().join(","))
        .unwrap_or_default();
    let typename = result
        .and_then(|r| r.get("__typename"))
        .and_then(Value::as_str)
        .unwrap_or("none");
    let errors = response
        .get("errors")
        .map(|e| e.to_string())
        .unwrap_or_default();
    let mut text = format!("typename={typename} keys=[{keys}] errors={errors}");
    text.truncate(400);
    text
}

fn metric_map(list: Option<&Value>) -> HashMap<String, u64> {
    list.and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|item| {
            let name = item.get("metric_type")?.as_str()?.to_string();
            Some((name, number(item.get("metric_value")?)?))
        })
        .collect()
}

fn hourly_impressions(series: Option<&Value>) -> Vec<u64> {
    series
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|point| {
            metric_map(point.get("metric_values"))
                .get("Impressions")
                .copied()
                .unwrap_or(0)
        })
        .collect()
}

fn number(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| value.as_f64().map(|f| f.max(0.0) as u64))
        .or_else(|| value.as_str().and_then(|s| s.parse().ok()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn posted_at_is_read_from_the_snowflake() {
        let at = posted_at("2105941975761314098").unwrap();
        assert_eq!(at.format("%Y").to_string(), "2026");
        assert!(posted_at("not-a-number").is_none());
    }

    #[test]
    fn totals_video_and_the_hourly_series_are_read() {
        let response = json!({"data": {"tweet_result_by_rest_id": {"result": {
            "__typename": "Tweet",
            "datapoints_grid": [
                {"metric_type": "Impressions", "metric_value": 72},
                {"metric_type": "Engagements", "metric_value": "2"},
                {"metric_type": "DetailExpands", "metric_value": 1},
                {"metric_type": "ProfileVisits", "metric_value": 1}
            ],
            "video": [{"metric_type": "VideoViews", "metric_value": 9}],
            "organic_metrics_time_series": [
                {"metric_values": [{"metric_type": "Impressions", "metric_value": 40}],
                 "timestamp": {"iso8601_time": "2026-10-02T10:00:00Z"}},
                {"metric_values": [{"metric_type": "Impressions", "metric_value": 32}],
                 "timestamp": {"iso8601_time": "2026-10-02T11:00:00Z"}}
            ]
        }}}});
        let analytics = parse_post_analytics(&response).unwrap();
        assert_eq!(analytics.impressions, 72);
        assert_eq!(analytics.engagements, 2);
        assert_eq!(analytics.detail_expands, 1);
        assert_eq!(analytics.profile_visits, 1);
        assert_eq!(analytics.link_clicks, 0);
        assert_eq!(analytics.video_views, Some(9));
        assert_eq!(analytics.hourly_impressions, vec![40, 32]);
    }

    #[test]
    fn a_post_wrapped_for_visibility_is_unwrapped() {
        let response = json!({"data": {"tweet_result_by_rest_id": {"result": {
            "__typename": "TweetWithVisibilityResults",
            "tweet": {"datapoints_grid": [{"metric_type": "Impressions", "metric_value": 5}]}
        }}}});
        assert_eq!(parse_post_analytics(&response).unwrap().impressions, 5);
    }

    #[test]
    fn no_metrics_means_no_analytics() {
        let response = json!({"data": {"tweet_result_by_rest_id": {"result": {
            "__typename": "Tweet", "datapoints_grid": []
        }}}});
        assert!(parse_post_analytics(&response).is_none());
        assert!(parse_post_analytics(&json!({"data": {}})).is_none());
    }
}
