use crate::cli::common;
use crate::error::Result;
use crate::gql::endpoints;
use crate::gql::query_ids::Operation;
use crate::parse::viewer;
use clap::Args as ClapArgs;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(long, help = "Emit JSON instead of a pretty summary")]
    pub json: bool,
}

pub async fn run(args: Args) -> Result<()> {
    let client = common::build_gql_client().await?;

    let response = client
        .get(
            Operation::Viewer,
            &endpoints::viewer_variables(),
            &endpoints::viewer_features(),
        )
        .await?;

    let info = viewer::parse(&response)?;

    if args.json {
        let payload = serde_json::json!({
            "user_id": info.user_id,
            "handle": info.handle,
            "name": info.name,
        });
        println!("{}", serde_json::to_string_pretty(&payload)?);
    } else {
        println!("@{} ({})", info.handle, info.name);
        println!("user_id: {}", info.user_id);
    }

    Ok(())
}
