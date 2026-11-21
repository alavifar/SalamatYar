fn main() {
    println!("cargo:rerun-if-changed=../../lang.json");
    println!("cargo:rerun-if-changed=../lang-extra.json");
    tauri_build::build()
}
