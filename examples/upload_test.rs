use std::time::Duration;
use unrager::api::media::{MediaFile, MediaUploader};
use unrager::auth::oauth;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter("unrager=debug,warn")
        .with_writer(std::io::stderr)
        .compact()
        .init();

    let path = std::env::args()
        .nth(1)
        .ok_or_else(|| anyhow::anyhow!("usage: upload_test <path-to-media>"))?;

    let file = MediaFile::from_path(&path)?;
    println!("file:      {}", file.path.display());
    println!("mime:      {}", file.mime);
    println!("size:      {} bytes", file.size);
    println!("category:  {}", file.category.as_api());
    println!("strategy:  {:?}", file.strategy());
    println!();

    let tokens = oauth::load_or_authorize().await?;
    println!(
        "token loaded, scope: {}",
        tokens.scope.as_deref().unwrap_or("-")
    );

    let http = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(120))
        .build()?;

    let uploader = MediaUploader::new(&http, &tokens.access_token);
    println!();
    println!("uploading...");
    let media_id = uploader.upload(&file).await?;
    println!();
    println!("✓ media_id: {media_id}");
    println!("(unused media ids expire after ~24h; no tweet created)");
    Ok(())
}
