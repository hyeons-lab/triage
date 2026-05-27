use std::path::Path;

fn main() {
    println!("cargo:rustc-check-cfg=cfg(embed_real_client)");
    println!("cargo:rerun-if-changed=../../flutter/triage_client/build/web/index.html");
    // Check if the Flutter web client has been built
    let client_index_path = Path::new("../../flutter/triage_client/build/web/index.html");
    if client_index_path.exists() {
        println!("cargo:rustc-cfg=embed_real_client");
    }
}
