use crate::error::Result;
use crate::server;
use clap::Args as ClapArgs;
use std::net::SocketAddr;

#[derive(Debug, ClapArgs)]
pub struct Args {
    #[arg(long, default_value = "127.0.0.1:7777", value_name = "ADDR:PORT")]
    pub bind: String,

    #[arg(
        long,
        help = "Open the web client in the default browser after starting"
    )]
    pub open: bool,
}

pub async fn run(args: Args) -> Result<()> {
    let addr: SocketAddr = args
        .bind
        .parse()
        .map_err(|e| crate::error::Error::Config(format!("invalid --bind {}: {e}", args.bind)))?;
    server::serve(addr, args.open).await
}
