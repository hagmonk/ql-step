//! Prints the unique vertex colors foxtrot extracts from a STEP file,
//! with vertex counts — used to verify style/color resolution coverage.

use std::collections::HashMap;

use step::step_file::StepFile;
use triangulate::triangulate::triangulate;

fn main() {
    let path = std::env::args().nth(1).expect("usage: dump_colors <file.step>");
    let data = std::fs::read(&path).expect("read failed");
    let flat = StepFile::strip_flatten(&data);
    let entities = StepFile::parse(&flat);
    let (mesh, _stats) = triangulate(&entities);

    let mut counts: HashMap<(u32, u32, u32), usize> = HashMap::new();
    for v in &mesh.verts {
        let key = (
            (v.color.x * 255.0).round() as u32,
            (v.color.y * 255.0).round() as u32,
            (v.color.z * 255.0).round() as u32,
        );
        *counts.entry(key).or_default() += 1;
    }

    let mut sorted: Vec<_> = counts.into_iter().collect();
    sorted.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
    println!("{} verts, {} unique colors", mesh.verts.len(), sorted.len());
    for ((r, g, b), n) in sorted {
        println!("  rgb({r:3},{g:3},{b:3})  x{n}");
    }
}
