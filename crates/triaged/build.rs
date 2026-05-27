use std::path::Path;

fn main() {
    println!("cargo:rustc-check-cfg=cfg(embed_real_client)");
    println!("cargo:rustc-check-cfg=cfg(embed_packaged_client)");
    println!("cargo:rerun-if-changed=../../flutter/triage_client/build/web/index.html");
    println!("cargo:rerun-if-changed=dist/index.html");

    let packaged_client_path = Path::new("dist/index.html");
    let dev_client_path = Path::new("../../flutter/triage_client/build/web/index.html");

    if packaged_client_path.exists() {
        println!("cargo:rustc-cfg=embed_packaged_client");
    } else if dev_client_path.exists() {
        println!("cargo:rustc-cfg=embed_real_client");
    }
}
