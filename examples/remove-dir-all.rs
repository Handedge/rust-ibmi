// remove_dir_all under PASE: failed (EINVAL) before libpaseat
use std::fs;
use std::path::Path;
fn main() {
    let base = "/tmp/rmA";
    let _ = fs::create_dir_all(format!("{base}/a/b"));
    fs::write(format!("{base}/a/f.txt"), "x").unwrap();
    fs::write(format!("{base}/a/b/g.txt"), "y").unwrap();
    println!("{base}: remove_dir_all -> {:?}", fs::remove_dir_all(base));
    println!("  still exists: {}", Path::new(base).exists());
}
