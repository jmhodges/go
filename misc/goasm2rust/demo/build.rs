fn main() {
    cc::Build::new().file("goxor.S").compile("goxor");
    println!("cargo:rerun-if-changed=goxor.S");
    println!("cargo:rerun-if-changed=body.inc");
}
