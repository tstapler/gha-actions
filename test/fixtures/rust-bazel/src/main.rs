fn main() {
    if std::env::args().any(|a| a == "--version") {
        println!("hello {}", env!("CARGO_PKG_VERSION", "0.0.0"));
    } else {
        println!("hello");
    }
}
