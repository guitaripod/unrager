use crate::pages::{
    compose::{Compose, Reply},
    home::Home,
    layout::Layout,
    likers::Likers,
    not_found::NotFound,
    profile::Profile,
    settings::Settings,
    source::{SourceBookmarks, SourceHome, SourceMentions, SourceNotifs, SourceSearch, SourceUser},
    tweet::TweetDetail,
};
use dioxus::prelude::*;

#[derive(Clone, Debug, PartialEq, Routable)]
#[rustfmt::skip]
pub enum Route {
    #[layout(Layout)]
        #[route("/")]
        Home {},
        #[route("/source/home")]
        SourceHome {},
        #[route("/source/user/:handle")]
        SourceUser { handle: String },
        #[route("/source/search/:product/:q")]
        SourceSearch { product: String, q: String },
        #[route("/source/mentions")]
        SourceMentions {},
        #[route("/source/bookmarks/:q")]
        SourceBookmarks { q: String },
        #[route("/source/notifications")]
        SourceNotifs {},
        #[route("/tweet/:id")]
        TweetDetail { id: String },
        #[route("/profile/:handle")]
        Profile { handle: String },
        #[route("/likers/:tweet_id")]
        Likers { tweet_id: String },
        #[route("/compose")]
        Compose {},
        #[route("/reply/:tweet_id")]
        Reply { tweet_id: String },
        #[route("/settings")]
        Settings {},
    #[end_layout]
    #[route("/:..segments")]
    NotFound { segments: Vec<String> },
}
