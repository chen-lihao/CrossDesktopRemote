use std::path::PathBuf;

fn main() {
    let manifest_dir =
        PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR must be set"));
    let proto_root = manifest_dir.join("../../proto");
    let proto_files = [
        "common.proto",
        "capability.proto",
        "device.proto",
        "session.proto",
        "signaling.proto",
    ]
    .map(|name| proto_root.join("crossdesktop/v1").join(name));

    for proto_file in &proto_files {
        println!("cargo:rerun-if-changed={}", proto_file.display());
    }

    prost_build::Config::new()
        .compile_protos(&proto_files, &[proto_root])
        .expect("protocol definitions must compile");
}
