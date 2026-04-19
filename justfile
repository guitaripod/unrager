default:
    @just --list

# Run CI gate locally
ci:
    cargo fmt --all -- --check
    cargo clippy --workspace --all-targets -- -D warnings
    cargo test --workspace

# Build the web client and stage it for rust-embed
web:
    cd crates/unrager-app && dx bundle --platform web --release
    rm -rf crates/unrager-app/dist
    mkdir -p crates/unrager-app/dist
    cp -r target/dx/unrager-app/release/web/public/. crates/unrager-app/dist/
    cp crates/unrager-app/static/* crates/unrager-app/dist/
    echo "Web bundle copied to crates/unrager-app/dist"

# Dev: run the server
dev-server:
    cargo run -p unrager -- serve --bind 127.0.0.1:7777

# Dev: run the web client with HMR
dev-web:
    cd crates/unrager-app && dx serve --platform web

# Install release binary with latest web bundle
install: web
    cargo install -p unrager --path .

# Build bundle for iOS simulator
mobile-ios:
    cd crates/unrager-app && dx bundle --platform ios --release

# Build APK for Android
mobile-android:
    cd crates/unrager-app && dx bundle --platform android --release
