use serde_json::{Value, json};

pub fn viewer_variables() -> Value {
    json!({
        "withCommunitiesMemberships": true
    })
}

pub fn viewer_features() -> Value {
    json!({
        "responsive_web_graphql_exclude_directive_enabled": true,
        "verified_phone_label_enabled": false,
        "creator_subscriptions_tweet_preview_api_enabled": true,
        "responsive_web_graphql_skip_user_profile_image_extensions_enabled": false,
        "responsive_web_graphql_timeline_navigation_enabled": true
    })
}

pub fn tweet_by_rest_id_variables(tweet_id: &str) -> Value {
    json!({
        "tweetId": tweet_id,
        "withCommunity": false,
        "includePromotedContent": false,
        "withVoice": false
    })
}

pub fn tweet_detail_variables(focal_tweet_id: &str, cursor: Option<&str>) -> Value {
    let mut vars = json!({
        "focalTweetId": focal_tweet_id,
        "with_rux_injections": false,
        "includePromotedContent": false,
        "withCommunity": true,
        "withQuickPromoteEligibilityTweetFields": false,
        "withBirdwatchNotes": false,
        "withVoice": false,
        "withV2Timeline": true
    });
    if let Some(c) = cursor {
        vars["cursor"] = Value::String(c.to_string());
    }
    vars
}

pub fn user_by_screen_name_variables(screen_name: &str) -> Value {
    json!({
        "screen_name": screen_name,
        "withSafetyModeUserFields": true
    })
}

pub fn user_by_screen_name_features() -> Value {
    json!({
        "hidden_profile_subscriptions_enabled": true,
        "profile_label_improvements_pcf_label_in_post_enabled": true,
        "rweb_tipjar_consumption_enabled": true,
        "responsive_web_graphql_exclude_directive_enabled": true,
        "verified_phone_label_enabled": false,
        "subscriptions_verification_info_is_identity_verified_enabled": true,
        "subscriptions_verification_info_verified_since_enabled": true,
        "highlights_tweets_tab_ui_enabled": true,
        "responsive_web_twitter_article_notes_tab_enabled": true,
        "subscriptions_feature_can_gift_premium": true,
        "creator_subscriptions_tweet_preview_api_enabled": true,
        "responsive_web_graphql_skip_user_profile_image_extensions_enabled": false,
        "responsive_web_graphql_timeline_navigation_enabled": true
    })
}

pub fn user_tweets_variables(user_id: &str, count: u32, cursor: Option<&str>) -> Value {
    let mut vars = json!({
        "userId": user_id,
        "count": count,
        "includePromotedContent": false,
        "withQuickPromoteEligibilityTweetFields": true,
        "withVoice": true,
        "withV2Timeline": true
    });
    if let Some(c) = cursor {
        vars["cursor"] = Value::String(c.to_string());
    }
    vars
}

pub fn user_tweets_features() -> Value {
    tweet_read_features()
}

pub fn home_timeline_variables(count: u32, cursor: Option<&str>) -> Value {
    let mut vars = json!({
        "count": count,
        "includePromotedContent": false,
        "latestControlAvailable": true,
        "requestContext": "launch",
        "withCommunity": true,
        "seenTweetIds": []
    });
    if let Some(c) = cursor {
        vars["cursor"] = Value::String(c.to_string());
    }
    vars
}

pub fn home_timeline_features() -> Value {
    tweet_read_features()
}

pub fn search_timeline_variables(
    query: &str,
    count: u32,
    product: &str,
    cursor: Option<&str>,
) -> Value {
    let mut vars = json!({
        "rawQuery": query,
        "count": count,
        "querySource": "typed_query",
        "product": product
    });
    if let Some(c) = cursor {
        vars["cursor"] = Value::String(c.to_string());
    }
    vars
}

pub fn search_timeline_features() -> Value {
    tweet_read_features()
}

pub fn bookmark_search_variables(query: &str, count: u32, cursor: Option<&str>) -> Value {
    let mut vars = json!({
        "rawQuery": query,
        "count": count,
        "includePromotedContent": false
    });
    if let Some(c) = cursor {
        vars["cursor"] = Value::String(c.to_string());
    }
    vars
}

pub fn bookmark_search_features() -> Value {
    json!({
        "rweb_video_screen_enabled": false,
        "profile_label_improvements_pcf_label_in_post_enabled": true,
        "responsive_web_profile_redirect_enabled": true,
        "rweb_tipjar_consumption_enabled": true,
        "verified_phone_label_enabled": false,
        "creator_subscriptions_tweet_preview_api_enabled": true,
        "responsive_web_graphql_timeline_navigation_enabled": true,
        "responsive_web_graphql_skip_user_profile_image_extensions_enabled": false,
        "premium_content_api_read_enabled": false,
        "communities_web_enable_tweet_community_results_fetch": true,
        "c9s_tweet_anatomy_moderator_badge_enabled": true,
        "responsive_web_grok_analyze_button_fetch_trends_enabled": false,
        "responsive_web_grok_analyze_post_followups_enabled": false,
        "responsive_web_jetfuel_frame": false,
        "responsive_web_grok_share_attachment_enabled": false,
        "responsive_web_grok_annotations_enabled": false,
        "articles_preview_enabled": true,
        "responsive_web_edit_tweet_api_enabled": true,
        "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
        "view_counts_everywhere_api_enabled": true,
        "longform_notetweets_consumption_enabled": true,
        "responsive_web_twitter_article_tweet_consumption_enabled": true,
        "content_disclosure_indicator_enabled": false,
        "content_disclosure_ai_generated_indicator_enabled": false,
        "responsive_web_grok_show_grok_translated_post": false,
        "responsive_web_grok_analysis_button_from_backend": false,
        "post_ctas_fetch_enabled": false,
        "freedom_of_speech_not_reach_fetch_enabled": true,
        "standardized_nudges_misinfo": true,
        "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": true,
        "longform_notetweets_rich_text_read_enabled": true,
        "longform_notetweets_inline_media_enabled": true,
        "responsive_web_grok_image_annotation_enabled": false,
        "responsive_web_grok_imagine_annotation_enabled": false,
        "responsive_web_grok_community_note_auto_translation_is_enabled": false,
        "responsive_web_enhance_cards_enabled": false
    })
}

pub fn bookmarks_variables(count: u32, cursor: Option<&str>) -> Value {
    let mut vars = json!({
        "count": count,
        "includePromotedContent": false
    });
    if let Some(c) = cursor {
        vars["cursor"] = Value::String(c.to_string());
    }
    vars
}

pub fn bookmarks_features() -> Value {
    let mut f = tweet_read_features();
    if let Value::Object(ref mut m) = f {
        m.insert(
            "graphql_timeline_v2_bookmark_timeline".into(),
            Value::Bool(true),
        );
    }
    f
}

pub fn tweet_read_features() -> Value {
    json!({
        "creator_subscriptions_tweet_preview_api_enabled": true,
        "communities_web_enable_tweet_community_results_fetch": true,
        "c9s_tweet_anatomy_moderator_badge_enabled": true,
        "articles_preview_enabled": true,
        "responsive_web_edit_tweet_api_enabled": true,
        "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
        "view_counts_everywhere_api_enabled": true,
        "longform_notetweets_consumption_enabled": true,
        "responsive_web_twitter_article_tweet_consumption_enabled": true,
        "tweet_awards_web_tipping_enabled": false,
        "creator_subscriptions_quote_tweet_preview_enabled": false,
        "freedom_of_speech_not_reach_fetch_enabled": true,
        "standardized_nudges_misinfo": true,
        "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": true,
        "rweb_video_timestamps_enabled": true,
        "longform_notetweets_rich_text_read_enabled": true,
        "longform_notetweets_inline_media_enabled": true,
        "profile_label_improvements_pcf_label_in_post_enabled": true,
        "rweb_tipjar_consumption_enabled": true,
        "responsive_web_graphql_exclude_directive_enabled": true,
        "verified_phone_label_enabled": false,
        "responsive_web_graphql_skip_user_profile_image_extensions_enabled": false,
        "responsive_web_graphql_timeline_navigation_enabled": true,
        "responsive_web_enhance_cards_enabled": false
    })
}

pub fn favoriters_variables(tweet_id: &str, count: u32, cursor: Option<&str>) -> Value {
    let mut vars = json!({
        "tweetId": tweet_id,
        "count": count,
        "includePromotedContent": false,
    });
    if let Some(c) = cursor {
        vars["cursor"] = Value::String(c.to_string());
    }
    vars
}

pub fn favoriters_features() -> Value {
    json!({
        "rweb_video_screen_enabled": false,
        "profile_label_improvements_pcf_label_in_post_enabled": true,
        "rweb_tipjar_consumption_enabled": true,
        "responsive_web_graphql_exclude_directive_enabled": true,
        "verified_phone_label_enabled": false,
        "creator_subscriptions_tweet_preview_api_enabled": true,
        "responsive_web_graphql_timeline_navigation_enabled": true,
        "responsive_web_graphql_skip_user_profile_image_extensions_enabled": false,
        "premium_content_api_read_enabled": false,
        "communities_web_enable_tweet_community_results_fetch": true,
        "c9s_tweet_anatomy_moderator_badge_enabled": true,
        "responsive_web_grok_analyze_button_fetch_trends_enabled": false,
        "responsive_web_grok_analyze_post_followups_enabled": false,
        "responsive_web_jetfuel_frame": false,
        "responsive_web_grok_share_attachment_enabled": false,
        "responsive_web_grok_analysis_button_from_backend": false,
        "responsive_web_grok_image_annotation_enabled": false,
        "responsive_web_grok_imagine_annotation_enabled": false,
        "responsive_web_grok_community_note_auto_translation_is_enabled": false,
        "responsive_web_grok_show_grok_translated_post": false,
        "articles_preview_enabled": true,
        "responsive_web_edit_tweet_api_enabled": true,
        "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
        "view_counts_everywhere_api_enabled": true,
        "longform_notetweets_consumption_enabled": true,
        "responsive_web_twitter_article_tweet_consumption_enabled": true,
        "post_ctas_fetch_enabled": false,
        "freedom_of_speech_not_reach_fetch_enabled": true,
        "standardized_nudges_misinfo": true,
        "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": true,
        "longform_notetweets_rich_text_read_enabled": true,
        "longform_notetweets_inline_media_enabled": true,
        "responsive_web_enhance_cards_enabled": false,
        "content_disclosure_indicator_enabled": false,
        "content_disclosure_ai_generated_indicator_enabled": false
    })
}
