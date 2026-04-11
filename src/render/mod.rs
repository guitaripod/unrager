use serde::Serialize;

pub enum Output {
    Pretty,
    Json,
}

pub fn emit<T: Serialize>(mode: Output, value: &T, pretty_fmt: impl FnOnce(&T) -> String) {
    match mode {
        Output::Json => {
            match serde_json::to_string_pretty(value) {
                Ok(s) => println!("{s}"),
                Err(e) => eprintln!("error serializing json: {e}"),
            }
        }
        Output::Pretty => println!("{}", pretty_fmt(value)),
    }
}
