default:
    @just --list

# Run CI gate locally
ci:
    cargo fmt --all -- --check
    cargo clippy --workspace --all-targets -- -D warnings
    cargo test --workspace

# Dev: run the API server
dev-server:
    cargo run -p unrager --features server -- serve --bind 127.0.0.1:7777

# Install release binary
install:
    cargo install -p unrager --path .
